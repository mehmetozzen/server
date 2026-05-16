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

RUN a2enmod rewrite expires headers deflate filter

COPY docker/app/php.ini /usr/local/etc/php/conf.d/kaltura.ini
COPY docker/app/apache-kaltura.conf /etc/apache2/sites-available/000-default.conf

COPY docker/app/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/kaltura/app

ENTRYPOINT ["/entrypoint.sh"]
