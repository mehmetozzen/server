#!/bin/bash
set -e

BASE_DIR=/opt/sphinx
LOG_DIR=/opt/sphinx/logs

mkdir -p "$LOG_DIR/sphinx/data" "$BASE_DIR/sphinx"

sed \
    -e "s|@BASE_DIR@|$BASE_DIR|g" \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    /opt/kaltura/app/configurations/sphinx/kaltura.conf.template \
    > /etc/sphinxsearch/kaltura.conf

exec searchd --nodetach --config /etc/sphinxsearch/kaltura.conf
