# Pinned by digest as well as tag: tags move. Update deliberately with
#   docker buildx imagetools inspect <image>:<tag> | awk '/^Digest:/{print $2}'
FROM ubuntu:22.04@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc AS builder

ENV NGINX_VERSION=1.25.3
ENV NGX_VOD_VERSION=1.33

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    libpcre3-dev \
    zlib1g-dev \
    libxml2-dev \
    libxslt-dev \
    wget \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" && \
    tar xf "nginx-${NGINX_VERSION}.tar.gz" && \
    rm "nginx-${NGINX_VERSION}.tar.gz"

RUN wget -q "https://github.com/kaltura/nginx-vod-module/archive/refs/tags/${NGX_VOD_VERSION}.tar.gz" \
        -O nginx-vod-module.tar.gz && \
    tar xf nginx-vod-module.tar.gz && \
    rm nginx-vod-module.tar.gz

RUN cd "nginx-${NGINX_VERSION}" && \
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --with-http_ssl_module \
        --with-file-aio \
        --with-threads \
        --add-module=../nginx-vod-module-${NGX_VOD_VERSION} && \
    make -j"$(nproc)" && \
    make install

# ── Runtime image ─────────────────────────────────────────────────────────────
FROM ubuntu:22.04@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libpcre3 libxml2 libxslt1.1 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/nginx /var/cache/nginx

COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /etc/nginx      /etc/nginx

COPY docker/packager/nginx.conf /etc/nginx/nginx.conf

EXPOSE 88

HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
    CMD nginx -t 2>/dev/null && kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null

CMD ["nginx", "-g", "daemon off;"]
