# Pinned: `latest` (ffmpeg 8.x) ships libx264 assembly that SIGILLs (exit 132,
# "Illegal instruction") under Apple Virtualization on Apple Silicon — every
# transcode fails and entries stay source-only. 7.1 encodes cleanly. Pinning
# also makes builds reproducible (an ffmpeg major bump can change encoder
# defaults across every conversion profile).
FROM mwader/static-ffmpeg:7.1 AS ffmpeg-source

FROM php:8.1-cli

# System libs required for PHP extensions
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
    libmemcached-dev \
    && rm -rf /var/lib/apt/lists/*

# Runtime tools and media processing (no ffmpeg from apt — using static build below)
# cron + logrotate serve the scheduler service, which reuses this image with
# its own entrypoint (docker/scheduler/entrypoint.sh).
RUN apt-get update && apt-get install -y \
    default-mysql-client \
    openssl \
    curl \
    unzip \
    gosu \
    imagemagick \
    mediainfo \
    cron \
    logrotate \
    msmtp \
    msmtp-mta \
    && rm -rf /var/lib/apt/lists/*

# Document ingestion (PDF / PPT / DOC entries). KAsyncConvertPdfLinux shells out
# to `lowriter`, which comes from libreoffice-writer; impress and calc cover
# presentations and spreadsheets. ghostscript renders the resulting PDF into the
# page images the thumbnail worker turns into slide previews.
# Only the individual components, with --no-install-recommends: the libreoffice
# metapackage pulls in a desktop stack and roughly triples the cost.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libreoffice-writer \
    libreoffice-impress \
    libreoffice-calc \
    ghostscript \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# mwader/static-ffmpeg ships native ARM64 + amd64 static builds, but omits
# libfdk_aac (non-free license). Kaltura's KDLOperatorFfmpeg1_1_1 hardcodes
# -c:a libfdk_aac, so we install the real binary as ffmpeg-real and put a
# wrapper at /usr/bin/ffmpeg that rewrites libfdk_aac → aac on the fly.
# Kaltura source stays AGPL-pristine; the translation is at the OS tool layer.
COPY --from=ffmpeg-source /ffmpeg /usr/bin/ffmpeg-real
COPY --from=ffmpeg-source /ffprobe /usr/bin/ffprobe
COPY docker/batch/ffmpeg-wrapper.sh /usr/bin/ffmpeg
COPY docker/batch/qt-faststart.sh /usr/bin/qt-faststart
RUN chmod +x /usr/bin/ffmpeg /usr/bin/qt-faststart

# PHP extensions (no configure needed)
RUN docker-php-ext-install \
    pdo_mysql \
    mbstring \
    xml \
    zip \
    opcache \
    exif \
    gettext \
    sockets \
    intl \
    pcntl

# PHP extensions that require configure (gd + ldap)
RUN LDAP_LIBDIR=$(find /usr/lib -name "libldap.so" | head -1 | xargs dirname | sed 's|/usr/||') \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure ldap --with-libdir="$LDAP_LIBDIR" \
    && docker-php-ext-install gd ldap

RUN pecl install apcu && docker-php-ext-enable apcu
RUN pecl install memcache && docker-php-ext-enable memcache

# Kaltura expects ffmpeg-aux as a separate binary
RUN ln -sf /usr/bin/ffmpeg /usr/bin/ffmpeg-aux

# Kaltura batch spawns workers via /usr/bin/php; php:8.1-cli installs at /usr/local/bin/php
RUN ln -s /usr/local/bin/php /usr/bin/php

# Kaltura batch templates hardcode /opt/kaltura/bin/mediainfo
RUN mkdir -p /opt/kaltura/bin && ln -sf /usr/bin/mediainfo /opt/kaltura/bin/mediainfo

COPY docker/app/php.ini /usr/local/etc/php/conf.d/kaltura.ini
COPY docker/common/setup-msmtp.sh /opt/kaltura/setup-msmtp.sh
COPY docker/batch/batch.ini.template /opt/kaltura/docker/batch/batch.ini.template
COPY docker/batch/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/kaltura/app

ENTRYPOINT ["/entrypoint.sh"]
