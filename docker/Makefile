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
COMPOSE      := docker compose --env-file $(CONF) -f $(MAKEFILE_DIR)/docker-compose.yml

# Core = everything except the Druid analytics stack (for low-RAM hosts).
CORE_SERVICES  := mysql memcache sphinx bundler kaltura packager batch scheduler
DRUID_SERVICES := druid-postgres druid-zookeeper druid-coordinator druid-broker \
                  druid-historical druid-middlemanager druid-router analytics-receiver

.DEFAULT_GOAL := help
.PHONY: help config build up core-up start stop restart down destroy reset \
        druid-up druid-down logs ps shell mysql

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ── Setup ──────────────────────────────────────────────────────────────────────
config: ## Create docker/kaltura.conf from the example if it is missing
	@test -f $(CONF) || { cp $(MAKEFILE_DIR)/kaltura.conf.example $(CONF); \
		echo "Created docker/kaltura.conf — edit it (domain, passwords, SSL) before 'make up'."; }

check-config:
	@test -f $(CONF) || { echo "Missing $(CONF). Run 'make config' and edit it first."; exit 1; }

build: check-config ## Build all locally-built images (cached layers make this fast)
	$(COMPOSE) build

# ── Lifecycle ──────────────────────────────────────────────────────────────────
up: check-config ## Start the full stack (Kaltura + Druid analytics)
	$(COMPOSE) up -d

core-up: check-config ## Start without Druid (low-RAM hosts; analytics disabled)
	$(COMPOSE) up -d $(CORE_SERVICES)

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

reset: check-config ## Clean reinstall: wipe volumes + generated config, rebuild, start
	$(COMPOSE) down -v
	rm -f $(ROOT)/.kaltura_installed $(ROOT)/configurations/.docker_secrets.env
	@for f in $(ROOT)/configurations/*.template.ini $(ROOT)/configurations/*.ini.template; do \
		[ -e "$$f" ] || continue; \
		rm -f "$${f%.template.ini}.ini" "$${f%.ini.template}.ini"; \
	done
	$(COMPOSE) build
	$(COMPOSE) up -d
	@echo "Stack starting. Follow init with:  make -C docker logs S=kaltura"

# ── Analytics (Druid) only ──────────────────────────────────────────────────────
druid-up: ## Start only the Druid analytics stack
	$(COMPOSE) up -d $(DRUID_SERVICES)

druid-down: ## Stop only the Druid analytics stack (reclaims ~4 GB)
	$(COMPOSE) stop $(DRUID_SERVICES)

# ── Inspect ─────────────────────────────────────────────────────────────────────
logs: ## Follow logs; one service with  make logs S=kaltura
	$(COMPOSE) logs -f $(S)

ps: ## Show container status
	$(COMPOSE) ps

shell: ## Open a bash shell in the kaltura app container
	docker exec -it kaltura_app bash

mysql: ## Open a MySQL root shell
	docker exec -it kaltura_mysql sh -c 'mysql -uroot -p"$$MYSQL_ROOT_PASSWORD"'
