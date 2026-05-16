FROM ubuntu:focal

RUN apt-get update && apt-get install -y \
    sphinxsearch \
    default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/sphinx/logs/sphinx/data /opt/sphinx/sphinx /etc/sphinxsearch

COPY docker/sphinx/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9312

ENTRYPOINT ["/entrypoint.sh"]
