# Pinned by digest as well as tag: tags move. Update deliberately with
#   docker buildx imagetools inspect <image>:<tag> | awk '/^Digest:/{print $2}'
FROM php:8.1-apache@sha256:72f0c0134922985022d55a39b0390d35dc7a10e961aa6c44fa35b4c3102f4268

RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libxml2-dev \
    libxslt1-dev \
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
    ffmpeg \
    libmemcached-dev \
    msmtp \
    msmtp-mta \
    && rm -rf /var/lib/apt/lists/*

# KMC is built from our own fork: several sections it exposes have no working
# backend here (Rooms needs Newrow; DVR, Preview Mode and Low Latency need the
# Live Packager) and none of them can be switched off by a partner permission,
# so the only place to remove them is the app itself. The fork's release
# workflow produces the same bundle shape as Kaltura's, so nothing below
# changes. Point KMCNG_REPO back at kaltura/kmc-ng for a stock console.
ARG KMCNG_REPO=mehmetozzen/kmc-ng
ARG KMCNG_VERSION=v7.20.0-mn.1
# The directory name is NOT the release tag. kmcngAction.class.php builds the
# path as /apps/kmcng/<kmcng_version>/ straight from configurations/base.ini, so
# a directory named after the fork's tag makes it read a file that is not there
# and answer "KMC currently unavailable" — with the real reason only in a
# KalturaLog::warning. deploy/config.ini and the ui_conf rows are keyed on the
# same upstream version, so the fork tag stays a packaging detail; the marker
# file records which build actually landed.
ARG KMCNG_DEPLOY_VERSION=v7.20.0
RUN mkdir -p /opt/kaltura/apps/kmcng && \
    curl -fsSL "https://github.com/${KMCNG_REPO}/releases/download/${KMCNG_VERSION}/kmc-ng-${KMCNG_VERSION}.zip" \
        -o /tmp/kmcng.zip && \
    unzip -q /tmp/kmcng.zip -d /tmp/kmcng_extract && \
    INNER=$(find /tmp/kmcng_extract -maxdepth 2 -name "index.html" | head -1 | xargs dirname) && \
    mv "$INNER" /opt/kaltura/apps/kmcng/${KMCNG_DEPLOY_VERSION} && \
    ln -s /opt/kaltura/apps/kmcng/${KMCNG_DEPLOY_VERSION} /opt/kaltura/apps/kmcng/latest && \
    echo "${KMCNG_REPO} ${KMCNG_VERSION}" > /opt/kaltura/apps/kmcng/${KMCNG_DEPLOY_VERSION}/.build && \
    rm -rf /tmp/kmcng.zip /tmp/kmcng_extract

ARG STUDIO_VERSION=v2.2.3
ENV STUDIO_VERSION=${STUDIO_VERSION}
RUN mkdir -p /opt/kaltura/apps/studio && \
    curl -fsSL "https://github.com/kaltura/player-studio/releases/download/${STUDIO_VERSION}/studio_${STUDIO_VERSION}.zip" \
        -o /tmp/studio.zip && \
    unzip -q /tmp/studio.zip -d /tmp/studio_extract && \
    INNER=$(find /tmp/studio_extract -maxdepth 2 -name "index.html" | head -1 | xargs dirname) && \
    mv "$INNER" /opt/kaltura/apps/studio/${STUDIO_VERSION} && \
    ln -s /opt/kaltura/apps/studio/${STUDIO_VERSION} /opt/kaltura/apps/studio/latest && \
    rm -rf /tmp/studio.zip /tmp/studio_extract

ARG STUDIO_V3_VERSION=v3.18.0
ENV STUDIO_V3_VERSION=${STUDIO_V3_VERSION}
RUN mkdir -p /opt/kaltura/apps/studioV3 && \
    curl -fsSL "https://github.com/kaltura/player-studio/releases/download/${STUDIO_V3_VERSION}/studio_${STUDIO_V3_VERSION}.zip" \
        -o /tmp/studiov3.zip && \
    unzip -q /tmp/studiov3.zip -d /tmp/studiov3_extract && \
    INNER=$(find /tmp/studiov3_extract -maxdepth 2 -name "index.html" | head -1 | xargs dirname) && \
    mv "$INNER" /opt/kaltura/apps/studioV3/${STUDIO_V3_VERSION} && \
    ln -s /opt/kaltura/apps/studioV3/${STUDIO_V3_VERSION} /opt/kaltura/apps/studioV3/latest && \
    rm -rf /tmp/studiov3.zip /tmp/studiov3_extract

# thumbnail-embed.js is loaded by playerWrapper.html from an external CDN
# (https://static.kaltura.com). Download it at build time and patch the reference
# so the Share & Embed preview works in fully local environments.
RUN curl -sL "https://static.kaltura.com/content/static/player-scripts/thumbnail-embed.js" \
        -o /tmp/thumbnail-embed.js \
    && cp /tmp/thumbnail-embed.js /opt/kaltura/apps/kmcng/${KMCNG_DEPLOY_VERSION}/public/thumbnail-embed.js \
    && rm /tmp/thumbnail-embed.js \
    && sed -i \
        's|https://static\.kaltura\.com/content/static/player-scripts/thumbnail-embed\.js|thumbnail-embed.js|g' \
        /opt/kaltura/apps/kmcng/${KMCNG_DEPLOY_VERSION}/public/playerWrapper.html

# Placeholder pages for analytics sub-apps that require external backends (Druid/Kanalony).
# Without these, KMC NG loads Apache 404 inside its iframe.
RUN for dir in \
        /opt/kaltura/apps/liveanalytics/v2.7.3 \
        /opt/kaltura/apps/liveDashboard/v1.5.7 \
        /opt/kaltura/apps/usage-dashboard/v2.0.1; do \
    mkdir -p "$dir" && \
    printf '<!DOCTYPE html><html><body></body></html>\n' > "$dir/index.html"; \
    done

ARG ANALYTICS_VERSION=v3.4.2
ENV ANALYTICS_VERSION=${ANALYTICS_VERSION}
RUN mkdir -p /opt/kaltura/apps/kmc-analytics && \
    curl -fsSL "https://github.com/kaltura/analytics-front-end/releases/download/${ANALYTICS_VERSION}/kmcAnalytics_${ANALYTICS_VERSION}.zip" \
        -o /tmp/analytics.zip && \
    unzip -q /tmp/analytics.zip -d /tmp/analytics_extract && \
    INNER=$(find /tmp/analytics_extract -maxdepth 2 -name "index.html" | head -1 | xargs dirname) && \
    mv "$INNER" /opt/kaltura/apps/kmc-analytics/${ANALYTICS_VERSION} && \
    ln -s /opt/kaltura/apps/kmc-analytics/${ANALYTICS_VERSION} /opt/kaltura/apps/kmc-analytics/latest && \
    rm -rf /tmp/analytics.zip /tmp/analytics_extract

# xsl: content distribution builds every provider's field values by running
# an XSLT over the entry MRSS (ConfigurableDistributionProfile), so without
# it XSLTProcessor is undefined and submitting an entry dies with a fatal
# error -- the distribution row sticks at SUBMITTING and no job is queued.
RUN LDAP_LIBDIR=$(find /usr/lib -name "libldap.so" | head -1 | xargs dirname | sed 's|/usr/||') \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure ldap --with-libdir="$LDAP_LIBDIR" \
    && docker-php-ext-install \
        pdo_mysql \
        mysqli \
        mbstring \
        gd \
        xml \
        xsl \
        zip \
        opcache \
        ldap \
        exif \
        gettext \
        sockets \
        intl

# Pinned: an unpinned `pecl install` picks up whatever is current, including a
# new major, on a rebuild months from now.
RUN pecl install apcu-5.1.28 && docker-php-ext-enable apcu
RUN pecl install memcache-8.2 && docker-php-ext-enable memcache

# Kaltura's PHP client SDK is generated from the live API schema by a separate
# Kaltura repo (clients-generator). The server's generator/generate.php loads
# clients-generator/exec.php via ../../clients-generator relative path, so the
# repo must sit at /opt/kaltura/clients-generator.
ARG CLIENTS_GENERATOR_VERSION=Venus-22.20.0-rel
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && git clone --depth 1 --branch "${CLIENTS_GENERATOR_VERSION}" \
        https://github.com/kaltura/clients-generator.git /opt/kaltura/clients-generator \
    && apt-get purge -y git && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# kaltura/dwh DDL — stored in image so entrypoint.sh can load schema on first run.
# Orion-15.1.0 is the last released DWH branch; no Venus-tagged release exists.
# Fetched by COMMIT, not by branch name: refs/heads/<branch> is a moving target,
# so the same Dockerfile would produce different DDL over time.
# Update: curl -s https://api.github.com/repos/kaltura/dwh/commits/Orion-15.1.0 | grep -m1 '"sha"'
ARG DWH_COMMIT=c642531c6bd8c7e9af35c489a70ea48b949bafd0
RUN curl -fsSL "https://github.com/kaltura/dwh/archive/${DWH_COMMIT}.tar.gz" \
        -o /tmp/dwh.tar.gz \
    && mkdir -p /opt/kaltura/dwh_ddl \
    && tar -xzf /tmp/dwh.tar.gz -C /tmp \
    && mv /tmp/dwh-${DWH_COMMIT}/ddl /opt/kaltura/dwh_ddl/ddl \
    && mv /tmp/dwh-${DWH_COMMIT}/setup /opt/kaltura/dwh_ddl/setup \
    && rm -rf /tmp/dwh.tar.gz /tmp/dwh-${DWH_COMMIT}

# html5lib (mwEmbed V2 player) — stored OUTSIDE the kaltura_web volume so the
# named volume cannot shadow it. entrypoint.sh copies it in on first run.
# ENV (not just ARG) so entrypoint.sh can resolve the version at runtime instead
# of hardcoding it — bumping this arg must not silently break the runtime patches.
# HTML5LIB_VERSION is only the directory LABEL Kaltura serves this player under
# (appVersions.ini html5_version) — kaltura/mwEmbed has no v2.7.4 tag, so the
# content comes from master. That download used to be refs/heads/master, i.e.
# whatever master happened to be at build time, while entrypoint.sh applies
# LINE-NUMBERED patches to these files (`sed -n '462p'`). One upstream commit
# was enough to make those patches silently miss and break the V2 player with
# a PHP 8 parse error. Pinned to a commit so the tree is identical every build.
# Update: curl -s https://api.github.com/repos/kaltura/mwEmbed/commits/master | grep -m1 '"sha"'
ARG HTML5LIB_VERSION=v2.7.4
ARG MWEMBED_COMMIT=edfa709f5d8ace7310115a7ddea40c892f29ef91
ENV HTML5LIB_VERSION=${HTML5LIB_VERSION}
RUN curl -fsSL "https://github.com/kaltura/mwEmbed/archive/${MWEMBED_COMMIT}.tar.gz" \
        -o /tmp/mwembed.tar.gz \
    && mkdir -p /opt/kaltura/html5lib_image \
    && tar -xzf /tmp/mwembed.tar.gz -C /tmp \
    && mv /tmp/mwEmbed-${MWEMBED_COMMIT} /opt/kaltura/html5lib_image/${HTML5LIB_VERSION} \
    && rm -f /tmp/mwembed.tar.gz

RUN a2enmod rewrite expires headers deflate filter proxy proxy_http

COPY docker/app/php.ini /usr/local/etc/php/conf.d/kaltura.ini
COPY docker/app/apache-kaltura.conf /etc/apache2/kaltura-vhost-body.template
COPY docker/common/setup-msmtp.sh /opt/kaltura/setup-msmtp.sh

COPY docker/app/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/kaltura/app

ENTRYPOINT ["/entrypoint.sh"]
