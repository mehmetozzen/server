# Pinned by digest as well as tag: tags move. Update deliberately with
#   docker buildx imagetools inspect <image>:<tag> | awk '/^Digest:/{print $2}'
FROM ubuntu:focal@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214

RUN apt-get update && apt-get install -y \
    sphinxsearch \
    default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/sphinx/logs/sphinx/data /opt/sphinx/sphinx /etc/sphinxsearch

COPY docker/sphinx/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9312

ENTRYPOINT ["/entrypoint.sh"]
