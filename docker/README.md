# Kaltura CE — Docker Compose Stack

A self-contained Docker Compose deployment of Kaltura Community Edition
(Venus 22.20.0) for multi-tenant development and testing. The stack brings up
the full video platform — ingest, transcoding, playback, KMC, Studio — plus an
optional Apache Druid analytics backend.

> **Engineering rule of this fork:** no modifications to original Kaltura source
> code. Everything is solved in the Docker / configuration layer
> (`docker/app/entrypoint.sh`, config templates, this compose file). The fork
> stays public (AGPL v3).

---

## 1. What comes up — 15 services

`docker compose ... up -d` starts **15 containers** in four functional groups.

### Group A — Core Kaltura (required, ~1.8 GB RAM)

| Service | Container | Image / Build | Ports | What it does |
|---|---|---|---|---|
| `kaltura` | `kaltura_app` | build `docker/app` (PHP 8.1 + Apache) | 80, 443 | The platform. Serves the `/api_v3` API, KMC NG, Admin Console, Studio, player embeds. On first boot `entrypoint.sh` initialises the DB, generates client SDKs, loads the DWH schema, and renders every `*.ini` from templates. |
| `batch` | `kaltura_batch` | build `docker/batch` (PHP CLI) | — | The batch worker pool (`KGenericBatchMgr`). Runs conversion, import, bulk-upload, thumbnail, and scheduling jobs. Talks back to the API over HTTPS. |
| `scheduler` | `kaltura_scheduler` | build `docker/batch` (cron entrypoint) | — | The host-cron jobs of a bare-metal install: log rotation (logrotate, adapted with `copytruncate` for daemon-held logs), API cache cleanup (`clear_cache.sh`), and deleted/old content cleanup (`deleteOldContent.php`). Without it logs grow unbounded. |
| `live-rtmp` | `kaltura_live_rtmp` | build `docker/live-rtmp` (nginx + rtmp module) | 1935 (RTMP ingest) | Live media server — Kaltura's official FOSS live path. Encoders push `rtmp://<host>:1935/kLive/<stream>`; HLS comes out at `/hlsme/<stream>.m3u8` (Apache-proxied), consumed by a KMC "Manual Live Stream" entry. |
| `mysql` | `kaltura_mysql` | `mysql:5.7` | 3306 | Operational database (`kaltura`, `kaltura_sphinx_log`) **and** the DWH databases (`kalturadw`, `kalturadw_ds`, `kalturadw_bisources`, `kalturalog`). Tuned via `docker/mysql/my.cnf`. |
| `sphinx` | `kaltura_sphinx` | build `docker/sphinx` (Sphinx 2.2.11) | 9312 | Full-text search index for entries, categories, users, cue points, etc. KMC search routes here (Elasticsearch is intentionally disabled). |
| `memcache` | `kaltura_memcache` | `memcached:1.6-alpine` | 11211 | `kConf` configuration cache and API query cache. Flush it (`flush_all`) after changing `.ini` files at runtime. |

### Group B — Media helpers (required for playback)

| Service | Container | Image / Build | Ports | What it does |
|---|---|---|---|---|
| `packager` | `kaltura_packager` | build `docker/packager` (nginx-vod-module) | 88 | Repackages stored MP4 flavors into HLS/DASH on the fly. Apache proxies `/hls/` and `/dash/` here. |
| `bundler` | `kaltura_bundler` | build `docker/bundler` (Node.js) | 8080 | Builds and serves the V7 PlayKit JS player bundle (`kaltura-ovp-player.js`). The app fetches the player version and bundle from here. |

### Group C — Analytics / Apache Druid (optional, ~4.3 GB RAM)

Druid is the **KAVA analytics backend**. Kaltura's `kKavaReportsMgr` POSTs native
JSON queries to the broker at `/druid/v2/`. Without this group, the modern
analytics views (Engagement, Audience, Technology, Geo) cannot return data.

> Single-container `nano-quickstart` is **not** usable here: the slim
> `apache/druid` image has no `perl`, which its `supervise` launcher requires.
> We therefore run the documented split-service topology, each role launched via
> the sh-based `/druid.sh <role>` entrypoint.

| Service | Container | Image | Ports | What it does |
|---|---|---|---|---|
| `druid-postgres` | `kaltura_druid_postgres` | `postgres:15-alpine` | — | Druid metadata store (segments, tasks, config). |
| `druid-zookeeper` | `kaltura_druid_zookeeper` | `zookeeper:3.8` | — | Druid cluster coordination / leader election. |
| `druid-coordinator` | `kaltura_druid_coordinator` | `apache/druid:30.0.1` | 8081 | Coordinator **and** Overlord (`asOverlord`). Manages segment balancing and accepts ingestion tasks at `/druid/indexer/v1/task`. |
| `druid-broker` | `kaltura_druid_broker` | `apache/druid:30.0.1` | 8082 | Query broker. **This is the `druid_url` target** — Kaltura queries `http://druid-broker:8082/druid/v2/`. |
| `druid-historical` | `kaltura_druid_historical` | `apache/druid:30.0.1` | — | Loads and serves immutable historical segments from deep storage. |
| `druid-middlemanager` | `kaltura_druid_middlemanager` | `apache/druid:30.0.1` | — | Runs ingestion tasks (peons) that build new segments. |
| `druid-router` | `kaltura_druid_router` | `apache/druid:30.0.1` | 8888 | Optional web console (Druid UI) at `http://localhost:8888`. |

### Group D — Analytics ingestion

| Service | Container | Image / Build | Ports | What it does |
|---|---|---|---|---|
| `kafka` | `kaltura_kafka` | `apache/kafka:3.8.0` (KRaft) | — | Streaming bus for the Real-Time analytics tab: the receiver produces every beacon to the `player-events-realtime` topic and a Druid kafka supervisor indexes it within seconds. Optional — skip on low-RAM hosts and only the Real-Time tab stays empty. |
| `analytics-receiver` | `kaltura_analytics_receiver` | build `docker/analytics-receiver` (Node.js) | 9999 (internal) | Stand-in for the closed-source SaaS **Kanalony** pipeline. Apache proxies player analytics beacons (`?service=analytics&action=trackEvent`) here. It maps the numeric KAVA `eventType` to the string dimensions `kKavaBase.php` expects, builds the full Druid row (dimensions, metrics, `uniqueUserIds`/`uniqueSessionId` HLL sketches) and batch-appends to the `player-events-historical` datasource. |

---

## 2. Prerequisites

- **Docker Engine + Docker Compose v2** (`docker compose`, not `docker-compose`).
- **RAM:**
  - Core + media (Groups A, B): **~2 GB** → runs on a 4 GB host.
  - Full stack incl. Druid (Groups A–D): **~6 GB** → needs a host with **≥ 8 GB**
    allocated to Docker. A 3.7 GB host cannot run Druid.
- **Disk:** ~15 GB for images + volumes.
- **Architecture:** images are `linux/amd64`. On Apple Silicon they run under
  emulation (functional but slower); on x86-64 they run natively.

---

## 3. Configuration

All runtime configuration lives in one git-ignored file: `docker/kaltura.conf`.

```bash
cp docker/kaltura.conf.example docker/kaltura.conf
# then edit docker/kaltura.conf
```

| Key | Meaning |
|---|---|
| `WWW_HOST` | Public hostname (e.g. `test.example.com`). |
| `PROTOCOL` | `http` or `https`. |
| `SSL_CRT_FILE` / `SSL_KEY_FILE` | Cert paths **inside** the container (`/opt/kaltura/certs/...`). |
| `DB1_*`, `MYSQL_ROOT_PASSWORD` | Database name / user / passwords. |
| `ADMIN_CONSOLE_ADMIN_MAIL`, `ADMIN_CONSOLE_PASSWORD` | First admin-console login. |
| `TIME_ZONE` | e.g. `UTC`, `Europe/Istanbul`. |

`kaltura.conf` is consumed two ways:
- `--env-file ./kaltura.conf` → YAML-level variable substitution (mysql user/pass).
- `env_file:` on the `kaltura` and `batch` services → environment variables that
  `entrypoint.sh` reads to render config and compute `SERVICE_URL`.

### HTTPS / certificates

Put cert files in `docker/certs/` (git-ignored). For local development with
[mkcert](https://github.com/FiloSottile/mkcert):

```bash
mkdir -p docker/certs
mkcert -cert-file docker/certs/server.crt -key-file docker/certs/server.key test.example.com
cp "$(mkcert -CAROOT)/rootCA.pem" docker/certs/rootCA.pem   # auto-trusted in-container
```

Add the host to `/etc/hosts` so the browser resolves it locally:

```bash
echo "127.0.0.1 test.example.com" | sudo tee -a /etc/hosts
```

---

## 4. Bring the stack up (fresh install)

From the repository root:

```bash
# 1. configure
cp docker/kaltura.conf.example docker/kaltura.conf      # then edit it

# 2. build the locally-built images
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml build

# 3. start everything
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml up -d
```

**First boot takes 3–5 minutes.** `entrypoint.sh` runs a one-time initialisation
(guarded by the `/opt/kaltura/app/.kaltura_installed` marker):

1. Generate per-deployment secrets and render every `configurations/*.ini`.
2. Load the SQL schema and run `insertDefaults` / `insertPermissions`.
3. Start Apache temporarily, generate the PHP client SDKs, run `insertContent`.
4. Load the DWH schema into `kalturadw` (MySQL-5.7-compatible).
5. Deploy UI confs, create KMC NG player records, finalise `batch.ini`.
6. Start Apache in the foreground and serve.

The `batch` container will log `API not ready, retrying...` during this window —
that is expected; it connects once the app finishes init and Apache is serving.

### Core-only (no Druid) on a small host

If the host has < 8 GB RAM, start only Groups A and B (analytics will be
unavailable):

```bash
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml up -d \
  mysql memcache sphinx bundler kaltura packager batch
```

---

## 5. Reset (wipe everything and reinstall)

`down -v` removes **all volumes** (databases, web content, Druid segments):

```bash
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml down -v
rm -f .kaltura_installed configurations/.docker_secrets.env
# remove generated .ini files so they regenerate from templates
for tmpl in configurations/*.template.ini configurations/*.ini.template; do
  rm -f "${tmpl%.template.ini}.ini" "${tmpl%.ini.template}.ini"
done
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml \
  build kaltura batch packager analytics-receiver
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml up -d
```

After a reset the Druid datasource is empty — analytics fills in again as videos
are played.

---

## 6. Ports

| Port | Service | Purpose |
|---|---|---|
| 80 / 443 | kaltura | HTTP / HTTPS — API, KMC, Admin Console, Studio |
| 3306 | mysql | MySQL |
| 9312 | sphinx | Sphinx search |
| 11211 | memcache | Memcached |
| 88 | packager | nginx-vod (HLS/DASH) |
| 8080 | bundler | Player bundle service |
| 8081 | druid-coordinator | Coordinator/Overlord API |
| 8082 | druid-broker | Druid native query endpoint (`druid_url`) |
| 8888 | druid-router | Druid web console |
| 9999 | analytics-receiver | Beacon ingest (internal; reached via Apache proxy) |

---

## 7. Volumes

| Volume | Mounted by | Holds |
|---|---|---|
| `mysql_data` | mysql | All databases |
| `kaltura_web` | kaltura, batch | Content, flavors, thumbnails, generated UI confs |
| `kaltura_log` | kaltura, batch | Application + Apache logs |
| `kaltura_tmp` | kaltura, batch | Temp / conversion workspace |
| `sphinx_data` | sphinx | Search indexes |
| `druid_shared` | druid coord/historical/middle | Deep storage (segments) + indexing logs |
| `druid_pgdata` | druid-postgres | Druid metadata |
| `druid_*_var` | each druid role | Per-service working dirs |

The repository root is bind-mounted into `kaltura` and `batch` at
`/opt/kaltura/app`, so source edits are picked up on container restart.
**`entrypoint.sh` is baked into the image** (`COPY` at build time), so changes to
it require a `build`, not just a restart.

---

## 8. Logs

```bash
# follow a service
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml logs -f kaltura

# app/Apache logs (inside the kaltura_web/kaltura_log volume)
docker exec kaltura_app tail -f /opt/kaltura/log/kaltura_api_v3.log
docker exec kaltura_app tail -f /opt/kaltura/log/apache_error.log
docker exec kaltura_app tail -f /opt/kaltura/log/batch/*.log     # batch peons
```

`entrypoint.sh` prints clear `[kaltura] ...` progress lines; the batch worker
prints `[batch] ...` lines. Druid services log JVM startup and then go quiet.

---

## 9. Verifying the stack

```bash
# all containers healthy?
docker compose --env-file docker/kaltura.conf -f docker/docker-compose.yml ps

# API alive
curl -sk "https://test.example.com/api_v3/?service=system&action=ping"

# Druid broker healthy + datasources
curl -s http://localhost:8082/status/health
curl -s http://localhost:8081/druid/coordinator/v1/datasources
```

- **KMC NG:** `https://<WWW_HOST>/index.php/kmcng`
- **Admin Console:** `https://<WWW_HOST>/admin_console`
- **Druid console:** `http://localhost:8888`

---

## 10. Resource usage (idle, full stack)

| Group | RAM |
|---|---|
| Core Kaltura (A) | ~1.8 GB |
| Druid (B/C) | ~4.3 GB |
| **Total** | **~6 GB** |

CPU is near-idle when no jobs/queries run. Druid is the dominant consumer; stop
Groups C/D to reclaim ~4.3 GB when analytics is not needed.

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Bind for 0.0.0.0:443 failed: port is already allocated` | Another stack (or a previous run) holds the port. `docker ps`, then stop the conflicting container or `down` the other compose project. |
| `batch: API not ready, retrying...` for minutes | Normal during first-boot init. The app is still running schema/SDK/DWH steps; batch connects when Apache starts serving. |
| MySQL exits with code 137 | OOM kill — the host/Docker has too little RAM. Increase Docker memory; the full stack needs ~6 GB. |
| Analytics shows red "Internal server error" | Druid is down or `druid_url` not set. Check `druid-broker` health and `grep druid_url configurations/local.ini`. |
| Analytics empty after playing | Data is timestamped today; the default range may exclude today. Pick a range that includes the current day. Also confirm beacons reach the receiver: `docker logs kaltura_analytics_receiver`. |
| Config change to an `.ini` not taking effect | Flush memcache: `docker exec kaltura_memcache sh -c 'echo flush_all | nc localhost 11211'`, then `docker exec kaltura_app apache2ctl graceful`. |

---

## 12. Service dependency / startup order

```
mysql ─┬─(healthy)─┐
sphinx ┤           │
memcache           ├─► kaltura ─► packager
bundler ─(healthy)─┘        └─► (serves API, KMC, Studio)
mysql, sphinx, memcache ──► batch

druid-postgres ─(healthy)─┐
druid-zookeeper ──────────┴─► druid-coordinator ─┬─► druid-broker (query)
                                                 ├─► druid-historical
                                                 ├─► druid-middlemanager
                                                 └─► druid-router
analytics-receiver ──► (ingests to druid-coordinator)
```

Kaltura does **not** hard-depend on Druid — the app boots and serves even while
Druid is still starting; analytics queries simply return empty until the broker
is up.
