#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1

SUBCOMMAND_DIR=$(dirname "${BASH_SOURCE[0]}")

source "${SUBCOMMAND_DIR}"/include

## configure command defaults
REQUIRED_FILES=("${WARDEN_ENV_PATH}/auth.json")
DB_DUMP=
DB_IMPORT=1
AUTO_PULL=1
MEDIA_SYNC=1
COMPOSER_INSTALL=1
BASE_ENV=staging
APP_DOMAIN="${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}"
URL_FRONT="https://${APP_DOMAIN}/"
URL_ADMIN="https://${APP_DOMAIN}/admin/"

## argument parsing
## parse arguments
while (( "$#" )); do
    case "$1" in
        --skip-db-import)
            DB_IMPORT=
            shift
            ;;
        --skip-media-sync)
            MEDIA_SYNC=
            shift
            ;;
        --skip-composer-install)
            COMPOSER_INSTALL=
            shift
            ;;
        --no-pull)
            AUTO_PULL=
            shift
            ;;
        --db-dump=*)
            DB_DUMP="${1#*=}"
            shift
            ;;
        --environment=*)
            BASE_ENV=$(echo "${1#*=}" | tr '[:upper:]' '[:lower:]')
            shift
            ;;
        *)
            echo "Unrecognized argument '$1'"
            exit 0
            ;;
    esac
done

if [ ! -f "${WARDEN_ENV_PATH}/app/etc/env.php" ]; then
    cat <<EOT > "${WARDEN_ENV_PATH}/app/etc/env.php"
<?php
return [
    'backend' => [
        'frontName' => 'admin'
    ],
    'crypt' => [
        'key' => '00000000000000000000000000000000'
    ],
    'db' => [
        'table_prefix' => '',
        'connection' => [
            'default' => [
                'host' => 'db',
                'dbname' => 'magento',
                'username' => 'magento',
                'password' => 'magento',
                'active' => '1'
            ]
        ]
    ],
    'resource' => [
        'default_setup' => [
            'connection' => 'default'
        ]
    ],
    'x-frame-options' => 'SAMEORIGIN',
    'MAGE_MODE' => 'developer',
    'session' => [
        'save' => 'files'
    ],
    'cache_types' => [
        'config' => 1,
        'layout' => 1,
        'block_html' => 0,
        'collections' => 1,
        'reflection' => 1,
        'db_ddl' => 1,
        'eav' => 1,
        'customer_notification' => 1,
        'config_integration' => 1,
        'config_integration_api' => 1,
        'full_page' => 0,
        'translate' => 1,
        'config_webservice' => 1,
        'compiled_config' => 1
    ],
    'install' => [
        'date' => 'Sun, 01 Jan 2020 00:00:00 +0000'
    ]
];

EOT
fi

## include check for DB_DUMP file only when database import is expected
[[ ${DB_IMPORT} ]] && [[ "$DB_DUMP" ]] && REQUIRED_FILES+=("${DB_DUMP}")

:: Verifying configuration
INIT_ERROR=

## attempt to install mutagen if not already present
if [[ $OSTYPE =~ ^darwin ]] && ! which mutagen >/dev/null 2>&1 && which brew >/dev/null 2>&1; then
    warning "Mutagen could not be found; attempting install via brew."
    brew install havoc-io/mutagen/mutagen
fi

## check for presence of host machine dependencies
for DEP_NAME in den mutagen docker-compose pv; do
  if [[ "${DEP_NAME}" = "mutagen" ]] && [[ ! $OSTYPE =~ ^darwin ]]; then
    continue
  fi

  if ! which "${DEP_NAME}" 2>/dev/null >/dev/null; then
    error "Command '${DEP_NAME}' not found. Please install."
    INIT_ERROR=1
  fi
done

## verify mutagen version constraint
MUTAGEN_VERSION=$(mutagen version 2>/dev/null) || true
MUTAGEN_REQUIRE=0.11.4
if [[ $OSTYPE =~ ^darwin ]] && ! test "$(version "${MUTAGEN_VERSION}")" -ge "$(version "${MUTAGEN_REQUIRE}")"; then
  error "Mutagen ${MUTAGEN_REQUIRE} or greater is required (version ${MUTAGEN_VERSION} is installed)"
  INIT_ERROR=1
fi

## check for presence of local configuration files to ensure they exist
for REQUIRED_FILE in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "${REQUIRED_FILE}" ]]; then
    error "Missing local file: ${REQUIRED_FILE}"
    INIT_ERROR=1
  fi
done

## exit script if there are any missing dependencies or configuration files
[[ ${INIT_ERROR} ]] && exit 1

:: Starting Den
den svc up
if [[ ! -f ~/.den/ssl/certs/${TRAEFIK_DOMAIN}.crt.pem ]]; then
    den sign-certificate ${TRAEFIK_DOMAIN}
fi

:: Initializing environment
if [[ $AUTO_PULL ]]; then
  den env pull --ignore-pull-failures || true
  den env build --pull
else
  den env build
fi
den env up -d

## wait for mariadb to start listening for connections
den shell -c "while ! nc -z db 3306 </dev/null; do sleep 2; done"

if [[ $COMPOSER_INSTALL ]]; then
    :: Installing dependencies
    if [[ ${COMPOSER_VERSION} == 1 ]]; then
      den env exec php-fpm bash \
        -c '[[ $(composer -V | cut -d\  -f3 | cut -d. -f1) == 2 ]] || composer global require hirak/prestissimo'
    fi
    den env exec php-fpm composer install
fi

## import database only if --skip-db-import is not specified
if [[ ${DB_IMPORT} ]]; then
    if [[ -z "$DB_DUMP" ]]; then
        DB_DUMP="${WARDEN_ENV_NAME}_${BASE_ENV}-`date +%Y%m%dT%H%M%S`.sql.gz"
        :: Get database
        den db-dump --environment=${BASE_ENV} --file="${DB_DUMP}"
    fi

    if [[ "$DB_DUMP" ]]; then
        :: Importing database
        den import-db --file="${DB_DUMP}"
    fi
fi

den set-config

if [[ "$WARDEN_VARNISH" -eq "1" ]]; then
    :: Configuring Varnish
    den env exec php-fpm bin/magento config:set --lock-env system/full_page_cache/varnish/backend_host varnish
    den env exec php-fpm bin/magento config:set --lock-env system/full_page_cache/varnish/backend_port 80
    den env exec php-fpm bin/magento config:set --lock-env system/full_page_cache/caching_application 2
    den env exec php-fpm bin/magento config:set --lock-env system/full_page_cache/ttl 604800
else
    den env exec php-fpm bin/magento config:set --lock-env system/full_page_cache/caching_application 1
fi

if [[ "$WARDEN_ELASTICSEARCH" -eq "1" ]] || [[ "$WARDEN_OPENSEARCH" -eq "1" ]]; then
    if [[ "$WARDEN_OPENSEARCH" ]]; then
        :: Configuring OpenSearch
        ELASTICSEARCH_HOSTNAME="opensearch"
    else
        :: Configuring ElasticSearch
        ELASTICSEARCH_HOSTNAME="elasticsearch"
    fi

    den env exec php-fpm bin/magento config:set --lock-env catalog/search/engine elasticsearch7
    den env exec php-fpm bin/magento config:set --lock-env catalog/search/elasticsearch7_server_hostname $ELASTICSEARCH_HOSTNAME
    den env exec php-fpm bin/magento config:set --lock-env catalog/search/elasticsearch7_server_port 9200
    den env exec php-fpm bin/magento config:set --lock-env catalog/search/elasticsearch7_index_prefix magento2
    den env exec php-fpm bin/magento config:set --lock-env catalog/search/elasticsearch7_enable_auth 0
    den env exec php-fpm bin/magento config:set --lock-env catalog/search/elasticsearch7_server_timeout 15
fi

if [[ "$WARDEN_REDIS" -eq "1" ]]; then
    :: Configuring Redis
    den env exec php-fpm bin/magento setup:config:set --cache-backend=redis --cache-backend-redis-server=redis --cache-backend-redis-db=0 --cache-backend-redis-port=6379 --no-interaction
    den env exec php-fpm bin/magento setup:config:set --page-cache=redis --page-cache-redis-server=redis --page-cache-redis-db=1 --page-cache-redis-port=6379 --no-interaction
    den env exec php-fpm bin/magento setup:config:set --session-save=redis --session-save-redis-host=redis --session-save-redis-max-concurrency=20 --session-save-redis-db=2 --session-save-redis-port=6379 --no-interaction
fi

:: Configuring application

den env exec php-fpm bin/magento config:set --lock-env web/unsecure/base_url "${URL_FRONT}"
den env exec php-fpm bin/magento config:set --lock-env web/secure/base_url "${URL_FRONT}"

den env exec php-fpm bin/magento config:set --lock-env web/secure/offloader_header X-Forwarded-Proto || true
den env exec php-fpm bin/magento config:set --lock-env klaviyo_reclaim_general/general/enable 0 || true
den env exec php-fpm bin/magento config:set --lock-env klaviyo_reclaim_webhook/klaviyo_webhooks/using_product_delete_before_webhook 0 || true
den env exec php-fpm bin/magento config:set --lock-env paypal/wpp/sandbox_flag 1 || true
den env exec php-fpm bin/magento config:set --lock-env web/cookie/cookie_domain "${APP_DOMAIN}" || true
den env exec php-fpm bin/magento config:set --lock-env payment/checkmo/active 1 || true
den env exec php-fpm bin/magento config:set --lock-env payment/stripe_payments/active 0 || true
den env exec php-fpm bin/magento config:set --lock-env payment/stripe_payments_basic/stripe_mode test || true

:: Flushing cache
den env exec php-fpm bin/magento cache:flush

:: Creating admin user
den env exec php-fpm bin/magento admin:user:create \
    --admin-password=Admin123 \
    --admin-user=magento2docker \
    --admin-firstname=Admin \
    --admin-lastname=Admin \
    --admin-email="magento2docker@${APP_DOMAIN}"

if [[ $MEDIA_SYNC ]]; then
    :: Sync Media
    den sync-media --environment="${BASE_ENV}"
fi

echo "Configuration done."
echo "Frontend: ${URL_FRONT}"
echo "Admin:    ${URL_ADMIN}"
echo "Username: magento2docker"
echo "Password: Admin123"
