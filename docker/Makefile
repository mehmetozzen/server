# Kaltura CE — Docker stack management.
#
# Run from the repo root with:   make -C docker <target>
# or from this directory with:   make <target>
# List everything with:          make            (or make help)

# Resolve paths from this Makefile's own location, so targets work no matter
# where `make` is invoked from. ROOT is the repo root (bind-mounted as the app).
MAKEFILE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT         := $(abspath $(MAKEFILE_DIR)/..)
CONF         := $(MAKEFILE_DIR)/kaltura.conf
# Analytics (Druid + Kafka) rides the "analytics" compose profile. A config
# written before that switch existed has no COMPOSE_PROFILES line at all, and
# an absent profile means OFF to compose — so upgrading a running host would
# silently drop its whole analytics stack. Default it ON when the key is
# missing; an explicit COMPOSE_PROFILES (set, or empty to disable) always wins.
PROFILE_FLAG := $(if $(shell grep -qE '^COMPOSE_PROFILES=' $(CONF) 2>/dev/null && echo set),,--profile analytics)
# Entry media mounted from the host (see docker-compose.media.yml). Added only
# when KALTURA_MEDIA_DIR is set: without it media stays in the kaltura_web
# volume, and mounting over that path would hide what the volume holds.
MEDIA_FLAG   := $(if $(shell grep -qE '^KALTURA_MEDIA_DIR=.+' $(CONF) 2>/dev/null && echo set),-f $(MAKEFILE_DIR)/docker-compose.media.yml)
# Target directory of a Local remote-storage profile (see
# docker-compose.storage.yml), mounted at the same path. Added only when
# KALTURA_STORAGE_DIR is set.
STORAGE_DIR  := $(shell sed -n 's/^KALTURA_STORAGE_DIR=//p' $(CONF) 2>/dev/null | tail -1)
STORAGE_FLAG := $(if $(STORAGE_DIR),-f $(MAKEFILE_DIR)/docker-compose.storage.yml)
# Named volumes kept in a host directory (see docker-compose.data.yml). Added
# only when KALTURA_DATA_DIR is set: without it they stay in Docker's own
# storage. scripts/data-dir.sh creates the subdirectories and refuses volumes
# that already exist elsewhere (DATA_SH prepare, before every `up`).
DATA_FLAG    := $(if $(shell grep -qE '^KALTURA_DATA_DIR=.+' $(CONF) 2>/dev/null && echo set),-f $(MAKEFILE_DIR)/docker-compose.data.yml)
DATA_SH      := KALTURA_CONF=$(CONF) $(MAKEFILE_DIR)/scripts/data-dir.sh
# Host with no internet (see docker-compose.offline.yml): images come from
# `make import-images`, so nothing may be pulled or built.
OFFLINE      := $(shell grep -qE '^KALTURA_OFFLINE=1' $(CONF) 2>/dev/null && echo 1)
OFFLINE_FLAG := $(if $(OFFLINE),-f $(MAKEFILE_DIR)/docker-compose.offline.yml)
COMPOSE      := docker compose --env-file $(CONF) $(PROFILE_FLAG) -f $(MAKEFILE_DIR)/docker-compose.yml $(MEDIA_FLAG) $(STORAGE_FLAG) $(DATA_FLAG) $(OFFLINE_FLAG)

# Core = everything except the Druid analytics stack (for low-RAM hosts).
# analytics-receiver is CORE, not Druid: live-rtmp's on_publish auth callback
# targets it (fail-closed — without it every publish is refused). Its Druid
# writes simply queue/drop when Druid is down; live orchestration still works.
CORE_SERVICES  := mysql memcache sphinx bundler kaltura packager batch scheduler \
                  live-rtmp analytics-receiver
DRUID_SERVICES := druid-postgres druid-zookeeper druid-coordinator druid-broker \
                  druid-historical druid-middlemanager druid-router

.DEFAULT_GOAL := help
.PHONY: help config check-config data-dirs build up core-up realtime-up start stop restart down \
        destroy reset druid-up druid-down logs ps shell mysql verify doctor reindex backup restore \
        export-images import-images

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ── Setup ──────────────────────────────────────────────────────────────────────
config: ## Create docker/kaltura.conf from the example (generates strong random secrets)
	@test -f $(CONF) || { \
		sed \
			-e "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$$(openssl rand -hex 16)|" \
			-e "s|^DB1_PASS=.*|DB1_PASS=$$(openssl rand -hex 16)|" \
			-e "s|^ADMIN_CONSOLE_PASSWORD=.*|ADMIN_CONSOLE_PASSWORD=Adm1n_$$(openssl rand -hex 8)|" \
			-e "s|^LIVE_PUBLISH_TOKEN=.*|LIVE_PUBLISH_TOKEN=$$(openssl rand -hex 16)|" \
			-e "s|^LIVE_CB_SECRET=.*|LIVE_CB_SECRET=$$(openssl rand -hex 16)|" \
			$(MAKEFILE_DIR)/kaltura.conf.example > $(CONF); \
		echo "Created docker/kaltura.conf with random secrets — edit domain/SSL/SMTP before 'make up'."; }

check-config:
	@test -f $(CONF) || { echo "Missing $(CONF). Run 'make config' and edit it first."; exit 1; }
	@# Mounted at the same path inside the containers: a value under the
	@# product tree (/opt/kaltura, or / itself) would hide the app's own files.
	@case "$(STORAGE_DIR)" in \
	  ""|/*) ;; \
	  *) echo "KALTURA_STORAGE_DIR must be an absolute path, got '$(STORAGE_DIR)'"; exit 1 ;; \
	esac; \
	case "$(STORAGE_DIR)" in \
	  /|/opt|/opt/|/opt/kaltura|/opt/kaltura/*) echo "KALTURA_STORAGE_DIR=$(STORAGE_DIR) would cover the product tree — use the storage's own directory (e.g. /kvd)"; exit 1 ;; \
	esac

# Before anything creates a volume (see DATA_FLAG).
data-dirs: check-config
	@$(DATA_SH) prepare

build: check-config ## Build all locally-built images (cached layers make this fast)
	@test -z "$(OFFLINE)" || { echo "KALTURA_OFFLINE=1: images come from 'make import-images', there is nothing to build from"; exit 1; }
	$(COMPOSE) build

# ── Hosts without internet ─────────────────────────────────────────────────────
export-images: check-config ## Build + pack all images (analytics included) into one tar — x86_64 host WITH internet; OUT=dir
	@KALTURA_CONF=$(CONF) OUT="$(OUT)" $(MAKEFILE_DIR)/scripts/export-images.sh

import-images: check-config ## Verify and load that tar on the offline host:  make import-images IMAGES=.../kaltura-images.tar
	@test -n "$(IMAGES)" || { echo "Usage: make -C docker import-images IMAGES=<path to kaltura-images.tar>"; exit 1; }
	@KALTURA_CONF=$(CONF) $(MAKEFILE_DIR)/scripts/import-images.sh "$(IMAGES)"

# ── Lifecycle ──────────────────────────────────────────────────────────────────
up: data-dirs ## Start the stack (analytics included unless COMPOSE_PROFILES is commented out in kaltura.conf)
	$(COMPOSE) up -d

core-up: data-dirs ## Start without analytics regardless of kaltura.conf (low-RAM hosts; live and VOD still work)
	$(COMPOSE) up -d $(CORE_SERVICES)

# Kept as an alias: analytics (Druid + Kafka) is on by default now, so this is
# just `up`. Retained so existing runbooks and muscle memory keep working.
realtime-up: up ## Alias for `up` (analytics is enabled by default)

start: ## Start previously-stopped containers
	$(COMPOSE) start

stop: ## Stop containers but keep them and the data
	$(COMPOSE) stop

restart: ## Restart just the kaltura app container
	$(COMPOSE) restart kaltura

down: ## Stop and remove containers (KEEPS volumes / data)
	$(COMPOSE) down

destroy: ## Stop and remove containers AND volumes (DELETES ALL DATA)
	$(COMPOSE) down -v
	@$(DATA_SH) wipe

reset: check-config ## Clean reinstall: wipe volumes + generated config, rebuild, start
	$(COMPOSE) down -v
	@$(DATA_SH) wipe
	rm -f $(ROOT)/.kaltura_installed $(ROOT)/configurations/.docker_secrets.env
	@for f in $(ROOT)/configurations/*.template.ini $(ROOT)/configurations/*.ini.template; do \
		[ -e "$$f" ] || continue; \
		rm -f "$${f%.template.ini}.ini" "$${f%.ini.template}.ini"; \
	done
	$(if $(OFFLINE),,$(COMPOSE) build)
	@$(DATA_SH) prepare
	$(COMPOSE) up -d
	@echo "Stack starting. Follow init with:  make -C docker logs S=kaltura"

# ── Analytics (Druid) only ──────────────────────────────────────────────────────
druid-up: data-dirs ## Start only the Druid analytics stack
	$(COMPOSE) up -d $(DRUID_SERVICES)

druid-down: ## Stop only the Druid analytics stack (reclaims ~4 GB)
	$(COMPOSE) stop $(DRUID_SERVICES)

# ── Verify & diagnose ───────────────────────────────────────────────────────────
verify: check-config ## End-to-end smoke test (upload→transcode→playback→search→live→mail)
	@KALTURA_CONF=$(CONF) $(MAKEFILE_DIR)/scripts/verify.sh

doctor: check-config ## Health, permission and configuration diagnostics (read-only)
	@KALTURA_CONF=$(CONF) $(MAKEFILE_DIR)/scripts/doctor.sh

reindex: ## Rebuild all Sphinx search indexes from the database
	@$(MAKEFILE_DIR)/scripts/reindex.sh

# ── Backup & restore ────────────────────────────────────────────────────────────
backup: check-config ## Back up databases, media, config and secrets (to ~/kaltura-backups)
	@KALTURA_CONF=$(CONF) $(MAKEFILE_DIR)/scripts/backup.sh

restore: ## Restore from a backup:  make restore B=~/kaltura-backups/kaltura-...
	@test -n "$(B)" || { echo "Usage: make -C docker restore B=<backup directory>"; exit 1; }
	@KALTURA_CONF=$(CONF) $(MAKEFILE_DIR)/scripts/restore.sh "$(B)"

# ── Inspect ─────────────────────────────────────────────────────────────────────
logs: ## Follow logs; one service with  make logs S=kaltura
	$(COMPOSE) logs -f $(S)

ps: ## Show container status
	$(COMPOSE) ps

shell: ## Open a bash shell in the kaltura app container
	docker exec -it kaltura_app bash

mysql: ## Open a MySQL root shell
	docker exec -it kaltura_mysql sh -c 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD"'
