# BU WordPress - Optimized Multi-Stage Build
# This Dockerfile uses three stages to maximize build cache efficiency

# -----------------------------------------------------------
#       Build Arguments (Global Scope)
# -----------------------------------------------------------
# WordPress base image - can be overridden to test newer versions
# Examples: wordpress:5.9-php7.4-apache, wordpress:6.4-php8.1-apache
ARG WORDPRESS_BASE_IMAGE=wordpress:5.7.2-php7.4-apache

# EOL Debian workaround - set to false for Debian 11+ (Bullseye and newer)
# Required for Debian 10 (Buster) which is EOL and needs archive.debian.org
ARG NEEDS_EOL_WORKAROUND=true

# -----------------------------------------------------------
#       STAGE 1: System Base (Rarely Changes)
# -----------------------------------------------------------
FROM ${WORDPRESS_BASE_IMAGE} AS wordpress-system

# Set ARG for architecture
ARG TARGETARCH

# Re-declare to use inside this stage
ARG NEEDS_EOL_WORKAROUND

# Workaround for EOL Debian repositories (conditional)
# Only needed for Debian 10 (Buster) and older
RUN if [ "$NEEDS_EOL_WORKAROUND" = "true" ]; then \
      sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g; s|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list && \
      echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until; \
    fi

# Install client utils & tools
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y curl less git vim dos2unix ssl-cert util-linux jq unzip groff && \
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp && \
    apt-get install -y $(apt-cache search mysql-client | head -1 | awk '{print $1}') && \
    docker-php-ext-install pdo pdo_mysql

# Install AWS CLI (architecture aware)
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"; \
    else \
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"; \
    fi && \
    unzip -q awscliv2.zip && \
    ./aws/install && \
    aws --version && \
    rm awscliv2.zip && rm -rf aws/

# Install Igbinary extension
RUN mkdir -p /usr/src/php/ext && \
    cd /usr/src/php/ext && \
    curl -fsSL https://github.com/igbinary/igbinary/archive/master.tar.gz -o igbinary.tar.gz && \
    mkdir -p igbinary && \
    tar -xf igbinary.tar.gz -C igbinary --strip-components=1 && \
    rm igbinary.tar.gz && \
    docker-php-ext-install igbinary

# Install Redis extension with igbinary support
RUN cd /tmp && \
    git clone https://github.com/phpredis/phpredis.git && \
    cd phpredis && \
    phpize && \
    ./configure --enable-redis-igbinary && \
    make && make install

# Link Apache SSL logs to Docker stdout/stderr
RUN ln -sf /dev/stdout /var/log/apache2/ssl-access.log && \
    ln -sf /dev/stderr /var/log/apache2/ssl-error.log

# Modules
#   1) Install and enable modules
RUN a2enmod auth_basic headers rewrite ssl proxy proxy_http env

#   2) Copy and adjust files
COPY --chmod=777 wordpress-baseline/docker-entrypoint-baseline.sh /usr/local/bin/
COPY wordpress-baseline/wordpress.conf /etc/apache2/sites-enabled/
COPY wordpress-baseline/healthcheck.htm /usr/src/wordpress/
RUN rm /etc/apache2/sites-enabled/000-default.conf

# Add error pages, htaccess and PHP upload limits
COPY --chmod=766 wordpress-baseline/_s3proxy-custom-errors /var/www/html/_s3proxy-custom-errors
COPY --chmod=766 wordpress-baseline/.htaccess /var/www/html/
COPY --chmod=766 wordpress-baseline/uploads.ini /usr/local/etc/php/conf.d/

# Add S3 proxy configuration
COPY --chmod=766 wordpress-baseline/s3proxy.conf /etc/apache2/sites-available/

# Configure entrypoint script base
RUN sed -i "/exec "$@"/i\source docker-entrypoint-baseline.sh \$@" /usr/local/bin/docker-entrypoint.sh

# -----------------------------------------------------------
#       STAGE 2: WordPress Code (Changes Frequently)
# -----------------------------------------------------------
FROM debian:13-slim AS wp-code-builder

ARG GIT_USER
ARG GIT_PAT
ARG MANIFEST_INI_FILE
ARG REPOS
ARG CACHEBUST=1

# Add cachebust argument to force rebuild when needed
# This line changes with every build when CACHEBUST is modified
RUN echo "Cache bust: $CACHEBUST"

# Install dependencies for WordPress code acquisition
RUN apt update -y && \
    apt upgrade -y && \
    apt install git wget dos2unix xxd -y && \
    mkdir -p /tmp/repos

# Copy and run build script
COPY wordpress-build/wp-build.sh /usr/local/bin/
RUN bash /usr/local/bin/wp-build.sh 2>&1 | tee /tmp/repos/build-output.txt

# -----------------------------------------------------------
#       STAGE 3: Final Assembly (Quick)
# -----------------------------------------------------------
FROM wordpress-system AS final

# Copy WordPress code from code builder stage
COPY --from=wp-code-builder /tmp/repos/ /usr/src/wordpress/

# No additional entrypoint needed - S3 proxy setup is now integrated into the baseline entrypoint
