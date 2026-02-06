#!/usr/bin/env bash

WORDPRESS_CONF='/etc/apache2/sites-enabled/wordpress.conf'
S3PROXY_CONF='/etc/apache2/sites-available/s3proxy.conf'

# Duplicate the wordpress.conf with as a new virtual host (different ServerName directive) with added shibboleth configurations. 
setVirtualHost() {
  echo "setVirtualHost..."

  sed -i "s|localhost|${SERVER_NAME:-"localhost"}|g" $WORDPRESS_CONF

  sed -i "s|UTC|${TZ:-"UTC"}|g" $WORDPRESS_CONF
}

# Look for an indication the last step of initialization was run or not.
uninitialized_baseline() {
  [ -n "$(grep 'localhost' $WORDPRESS_CONF)" ] && true || false
}

check_mu_plugin_loader() {
  # Use WP_PATH set in main execution block (defaults to /var/www/html if not set)
  local wp_path="${WP_PATH:-/var/www/html}"
  local mu_plugin_loader="${wp_path}/wp-content/mu-plugins/loader.php"
  
  if [ -f "$mu_plugin_loader" ] ; then
    echo "mu_plugin_loader already generated..."
  else
    echo "generate_mu_plugin_loader..."
    wp bu-core generate-mu-plugin-loader \
      --path="$wp_path" \
      --require="${wp_path}/wp-content/mu-plugins/bu-core/src/wp-cli.php"
  fi
}

check_wordpress_install() {

    if ! wp core is-installed 2>/dev/null; then
      # WP is not installed. Let's try installing it.
      echo "installing multisite..."
      wp core multisite-install --title="local root site" \
        --url="http://${SERVER_NAME:-localhost}" \
        --admin_user="admin" \
        --admin_email="no-use-admin@bu.edu"

      else
        # WP is already installed.
        echo "WordPress is already installed. No need to create a new database."
    fi
}

setup_redis() {
  # Use WP_PATH set in main execution block (defaults to /var/www/html if not set)
  local wp_path="${WP_PATH:-/var/www/html}"
  
  # If there is a REDIS_HOST and REDIS_PORT available in the environment, add them as wp config values.
  if [ -n "${REDIS_HOST:-}" ] && [ -n "${REDIS_PORT:-}" ] ; then
    echo "Redis host detected, setting up Redis..."
    wp config set WP_REDIS_HOST $REDIS_HOST --add --type=constant --path="$wp_path"
    wp config set WP_REDIS_PORT $REDIS_PORT --add --type=constant --path="$wp_path"

    # If there is a REDIS_PASSWORD available in the environment, add it as a wp config value.
    if [ -n "${REDIS_PASSWORD:-}" ] ; then
      wp config set WP_REDIS_PASSWORD $REDIS_PASSWORD --add --type=constant --path="$wp_path"
    fi

    # If the redis-cache plugin is available, create the object-cache.php file and network activate the plugin.
    if wp plugin is-installed redis-cache --path="$wp_path" ; then
      echo "redis-cache plugin detected, setting up object cache..."
      wp plugin activate redis-cache --path="$wp_path"
      wp redis update-dropin --path="$wp_path"
    fi

  fi
}

# Replace a placeholder in s3proxy.conf with the actual s3proxy host value.
setS3ProxyHost() {
  echo "setS3ProxyHost..."
  sed -i 's|S3PROXY_HOST_PLACEHOLDER|'${S3PROXY_HOST}'|g' $S3PROXY_CONF
}

# Append an include statement for s3proxy.conf as a new line in wordpress.conf directly below a placeholder.
includeS3ProxyConfig() {
  echo "includeS3ProxyConfig..."
  sed -i 's|# PROXY_PLACEHOLDER|Include '${S3PROXY_CONF}'|' $WORDPRESS_CONF
}


# Setup xdebug if the XDEBUG environment variable is set to 'true'.
# This is currently customized for use with local docker and may be macOS specific.
setup_xdebug() {
  if [ "${XDEBUG:-}" == 'true' ] ; then
    if [ -z "$(pecl list | grep xdebug-3.1.6)" ] ; then
      pecl install xdebug-3.1.6
    fi
    docker-php-ext-enable xdebug
    echo 'xdebug.start_with_request=yes' >> /usr/local/etc/php/php.ini
    echo 'xdebug.mode=debug' >> /usr/local/etc/php/php.ini
    echo 'xdebug.client_host="host.docker.internal"' >> /usr/local/etc/php/php.ini
  fi
}


if [ "${SHELL:-}" == 'true' ] ; then
  # Keeps the container running, but apache is not started.
  tail -f /dev/null
else

  # JOB_PROCESSOR_MODE: Ephemeral containers running WP-CLI job processing tasks.
  # In job mode, WordPress files remain in /usr/src/wordpress (never copied to /var/www/html)
  # because parent entrypoint only copies files when running Apache/PHP-FPM.
  if [ "${JOB_PROCESSOR_MODE:-}" == 'true' ] ; then
    WP_PATH="/usr/src/wordpress"
    
    # Fix hardcoded /var/www/html paths in WORDPRESS_CONFIG_EXTRA environment variable.
    # The wp-config.php uses getenv_docker() to read this at runtime, so we must fix
    # the environment variable itself, not the config file.
    if [ -n "${WORDPRESS_CONFIG_EXTRA:-}" ]; then
      echo "Fixing paths in WORDPRESS_CONFIG_EXTRA for job processor mode..."
      export WORDPRESS_CONFIG_EXTRA=$(echo "$WORDPRESS_CONFIG_EXTRA" | sed 's|/var/www/html|/usr/src/wordpress|g')
    fi
    
    # Job mode needs wp-config.php but parent entrypoint skips creation for WP-CLI commands.
    # Generate it from wp-config-docker.php template if WORDPRESS_* env vars are present.
    cd "$WP_PATH"
    if [ ! -s wp-config.php ] && [ -n "${WORDPRESS_DB_HOST:-}" ]; then
      if [ -s wp-config-docker.php ]; then
        echo "Creating wp-config.php from environment variables for job processor..."
        awk '
          /put your unique phrase here/ {
            cmd = "head -c1m /dev/urandom | sha1sum | cut -d\\  -f1"
            cmd | getline str
            close(cmd)
            gsub("put your unique phrase here", str)
          }
          { print }
        ' wp-config-docker.php > wp-config.php
      fi
    fi
  else
    WP_PATH="/var/www/html"
  fi

  # Skip WordPress installation check in job mode to avoid slow multisite-install.
  # Database is already initialized by persistent WordPress containers.
  # All other setup is preserved because:
  #   - check_mu_plugin_loader: site-manager plugin loads through MU loader
  #   - setup_redis: Jobs need Redis for cache flushing operations
  #   - setVirtualHost: WP-CLI needs multisite URL context
  if [ "${JOB_PROCESSOR_MODE:-}" != 'true' ] ; then
    check_wordpress_install
  fi

  check_mu_plugin_loader

  setup_redis

  # Configure S3 proxy if the config values are provided (assumes that if the bucket name is provided, the other config values are as well).
  if [ -n "${S3PROXY_HOST}" ]; then
    setS3ProxyHost

    includeS3ProxyConfig
  fi

  ## XDebug should not be enabled in production environments.
  ## It is only intended for local development environments.
  setup_xdebug

  if uninitialized_baseline ; then

    setVirtualHost
  fi
fi
