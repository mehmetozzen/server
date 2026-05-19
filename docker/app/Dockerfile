FROM php:8.1-apache

RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libxml2-dev \
    libzip-dev \
    libldap2-dev \
    libssl-dev \
    libicu-dev \
    libonig-dev \
    default-mysql-client \
    openssl \
    curl \
    unzip \
    imagemagick \
    libmemcached-dev \
    && rm -rf /var/lib/apt/lists/*

ARG KMCNG_VERSION=v7.20.0
RUN mkdir -p /opt/kaltura/apps/kmcng && \
    curl -fsSL "https://github.com/kaltura/kmc-ng/releases/download/${KMCNG_VERSION}/kmc-ng-${KMCNG_VERSION}.zip" \
        -o /tmp/kmcng.zip && \
    unzip -q /tmp/kmcng.zip -d /tmp/kmcng_extract && \
    INNER=$(find /tmp/kmcng_extract -maxdepth 2 -name "index.html" | head -1 | xargs dirname) && \
    mv "$INNER" /opt/kaltura/apps/kmcng/${KMCNG_VERSION} && \
    ln -s /opt/kaltura/apps/kmcng/${KMCNG_VERSION} /opt/kaltura/apps/kmcng/latest && \
    rm -rf /tmp/kmcng.zip /tmp/kmcng_extract

# thumbnail-embed.js is loaded by playerWrapper.html from an external CDN
# (https://static.kaltura.com). Download it at build time and patch the reference
# so the Share & Embed preview works in fully local environments.
RUN curl -sL "https://static.kaltura.com/content/static/player-scripts/thumbnail-embed.js" \
        -o /tmp/thumbnail-embed.js \
    && cp /tmp/thumbnail-embed.js /opt/kaltura/apps/kmcng/${KMCNG_VERSION}/public/thumbnail-embed.js \
    && rm /tmp/thumbnail-embed.js \
    && sed -i \
        's|https://static\.kaltura\.com/content/static/player-scripts/thumbnail-embed\.js|thumbnail-embed.js|g' \
        /opt/kaltura/apps/kmcng/${KMCNG_VERSION}/public/playerWrapper.html

# Placeholder pages for analytics sub-apps that require external backends (Druid/Kanalony).
# Without these, KMC NG loads Apache 404 inside its iframe.
RUN for dir in \
        /opt/kaltura/apps/liveanalytics/v2.7.3 \
        /opt/kaltura/apps/liveDashboard/v1.5.7 \
        /opt/kaltura/apps/usage-dashboard/v2.0.1 \
        /opt/kaltura/apps/kmc-analytics/v3.4.2; do \
    mkdir -p "$dir" && \
    printf '<!DOCTYPE html><html><body></body></html>\n' > "$dir/index.html"; \
    done

RUN LDAP_LIBDIR=$(find /usr/lib -name "libldap.so" | head -1 | xargs dirname | sed 's|/usr/||') \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure ldap --with-libdir="$LDAP_LIBDIR" \
    && docker-php-ext-install \
        pdo_mysql \
        mbstring \
        gd \
        xml \
        zip \
        opcache \
        ldap \
        exif \
        gettext \
        sockets \
        intl

RUN pecl install apcu && docker-php-ext-enable apcu
RUN pecl install memcache && docker-php-ext-enable memcache

# Kaltura's PHP client SDK is generated from the live API schema by a separate
# Kaltura repo (clients-generator). The server's generator/generate.php loads
# clients-generator/exec.php via ../../clients-generator relative path, so the
# repo must sit at /opt/kaltura/clients-generator.
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && git clone --depth 1 https://github.com/kaltura/clients-generator.git /opt/kaltura/clients-generator \
    && apt-get purge -y git && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# html5lib (mwEmbed V2 player) — stored OUTSIDE the kaltura_web volume so the
# named volume cannot shadow it. entrypoint.sh copies it in on first run.
ARG HTML5LIB_VERSION=v2.7.4
RUN curl -fsSL "https://github.com/kaltura/mwEmbed/archive/refs/heads/master.tar.gz" \
        -o /tmp/mwembed.tar.gz \
    && mkdir -p /opt/kaltura/html5lib_image \
    && tar -xzf /tmp/mwembed.tar.gz -C /tmp \
    && mv /tmp/mwEmbed-master /opt/kaltura/html5lib_image/${HTML5LIB_VERSION} \
    && rm -f /tmp/mwembed.tar.gz

RUN a2enmod rewrite expires headers deflate filter

COPY docker/app/php.ini /usr/local/etc/php/conf.d/kaltura.ini
COPY docker/app/apache-kaltura.conf /etc/apache2/sites-available/000-default.conf

COPY docker/app/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/kaltura/app

ENTRYPOINT ["/entrypoint.sh"]
