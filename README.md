# Store Console Platform — Operations Guide

Complete reference for the server infrastructure, CI/CD pipeline, and zero-downtime deployment system.

---

## Table of Contents

- [Store Console Platform — Operations Guide](#store-console-platform--operations-guide)
  - [Table of Contents](#table-of-contents)
  - [Architecture Overview](#architecture-overview)
  - [Server Layout](#server-layout)
  - [Docker Network Topology](#docker-network-topology)
    - [Tenant Separation](#tenant-separation)
  - [CI/CD Pipeline — Zero-Downtime Deploy](#cicd-pipeline--zero-downtime-deploy)
  - [Blue-Green Deployment Flow](#blue-green-deployment-flow)
    - [Rollback](#rollback)
  - [Environment Configuration](#environment-configuration)
  - [Redis DB Isolation](#redis-db-isolation)
  - [PostgreSQL User Isolation](#postgresql-user-isolation)
  - [Queue Workers and Cron](#queue-workers-and-cron)
  - [Nginx Gateway Routing](#nginx-gateway-routing)
  - [TLS Certificates](#tls-certificates)
  - [Monitoring (Beszel)](#monitoring-beszel)
  - [Backup Strategy](#backup-strategy)
  - [Hermes Runbook — Manual Server Commands](#hermes-runbook--manual-server-commands)
    - [Activate dev.storeconsole.com workspace (one-time setup)](#activate-devstoreconsolecom-workspace-one-time-setup)
    - [Fresh migrations + seed (all environments)](#fresh-migrations--seed-all-environments)
    - [Run embeddings on production](#run-embeddings-on-production)
    - [Check queue/cron status](#check-queuecron-status)
    - [Apply Redis DB fix to running environments](#apply-redis-db-fix-to-running-environments)
    - [Prune disk space manually](#prune-disk-space-manually)
    - [Restart a specific environment (graceful)](#restart-a-specific-environment-graceful)
    - [View nginx access/error logs](#view-nginx-accesserror-logs)
  - [Troubleshooting](#troubleshooting)
    - [Site returning 502 Bad Gateway](#site-returning-502-bad-gateway)
    - [dev.storeconsole.com returns 502](#devstoreconsolecom-returns-502)
    - [High load average (Beszel red dot)](#high-load-average-beszel-red-dot)
    - [Migrations failing ("relation already exists")](#migrations-failing-relation-already-exists)
    - [Redis memory full](#redis-memory-full)

---

## Architecture Overview

```
Internet
   │
   ▼
┌─────────────────────────────────────────────────┐
│  Server: 135.125.131.135 (8 CPU, 8GB + 4GB swap) │
│                                                  │
│  ┌──────────────────────────────────────────┐   │
│  │  nginx-gateway  (port 80 + 443)          │   │
│  │  Routes by Host header → upstreams       │   │
│  └───────────┬──────────────────────────────┘   │
│              │ private_backend network           │
│   ┌──────────┼──────────────────────┐            │
│   │          │                      │            │
│   ▼          ▼                      ▼            │
│ production  staging               dev            │
│ (PHP-FPM)  (PHP-FPM)           (PHP-FPM)        │
│                                                  │
│  Shared: postgres + pgbouncer + redis + reverb   │
│  Monitor: beszel-hub (monitor.storeconsole.com)  │
│  Dev workspace: storeconsole (8084)   │
└─────────────────────────────────────────────────┘
```

---

## Server Layout

```
/opt/storeconsole-platform/          ← synced from deploy/ by CI
├── _proxy/
│   └── nginx/
│       ├── nginx.conf
│       ├── conf.d/
│       │   ├── 00-http-redirect.conf       # catch-all HTTP → HTTPS redirect
│       │   ├── 05-include-tenants.conf     # include /etc/nginx/conf.d.tenants/*.conf
│       │   └── 10-storeconsole.conf        # storeconsole vhosts
│       ├── upstreams/               # Written per deploy
│       │   ├── storeconsole-production-active.conf
│       │   ├── storeconsole-staging-active.conf
│       │   └── storeconsole-dev-active.conf
│       ├── auth/                    # htpasswd files (gitignored)
│       └── certs/                   # Let's Encrypt certs (gitignored)
├── _shared/
│   ├── docker-compose.common.yml    # Postgres, Redis, PgBouncer, Reverb, Nginx
│   │                                #   nginx-gateway mounts _proxy/nginx/conf.d as /etc/nginx/conf.d
│   │                                #   and gulfgym nginx/conf.d as /etc/nginx/conf.d.tenants
│   ├── .env                         # Shared secrets (gitignored)
│   ├── postgres/
│   ├── pgbouncer/
│   ├── redis/
│   ├── backups/
│   └── logs/nginx/
├── storeconsole.com/                # Production (blue-green Docker)
│   ├── docker-compose.yml
│   ├── .env                         # gitignored — written by render-secrets.sh
│   ├── .env.example
│   ├── active_color                 # "blue" | "green"
│   ├── active -> blue/
│   ├── blue/public/
│   └── green/public/
├── staging.storeconsole.com/        # Same structure, git-pull deploy
├── dev.storeconsole.com/ # Dev environment (blue-green CI deploy + optional HMR workspace)
│   ├── docker-compose.yml           # blue-green CI deploy (same pattern as production)
│   ├── docker-compose.workspace.yml # workspace mode: nginx:8084, php-fpm, vite:5174
│   ├── nginx.conf
│   ├── .env                         # gitignored — written by render-secrets.sh
│   └── storage/                     # gitignored — persistent logs/cache/sessions
├── scripts/
│   ├── deploy-storeconsole.sh
│   ├── render-secrets.sh            # generates htpasswd + updates per-env .env
│   ├── start-workspace.sh           # starts storeconsole or gulfgym workspace
│   ├── issue-certificates.sh
│   ├── backup-postgres.sh
│   ├── apply-common-stack.sh
│   ├── setup-server.sh
│   └── lib-runtime.sh
└── ACCESS.dev.md                  # gitignored

/opt/gulfgym-platform/               ← gulfgym repo owns this via CI
├── gulfgym.anichur.com/
│   ├── common/docker-compose.gulfgym.yml   # php-fpm, horizon, scheduler
│   ├── .env                                # gitignored
│   ├── public/                             # extracted assets
│   ├── shared-storage/                     # uploads, logs
│   └── scripts/
├── gulfgym-dev.anichur.com/       # gulfgym workspace (HMR)
│   ├── docker-compose.workspace.yml # nginx:8085, php-fpm, vite:5175
│   ├── nginx.conf
│   ├── .env                         # gitignored
│   └── storage/
└── nginx/conf.d/                    # gulfgym owns these; included by nginx-gateway
    ├── 20-gulfgym.conf              # production HTTPS vhost
    └── 25-gulfgym-workspace.conf    # workspace vhost (deployed when cert SAN present)

/opt/apps/                               # live code mounts for workspace containers
├── workspace/storeconsole-dev/codes/    # storeconsole Laravel app (git clone develop)
├── storeconsole-staging/codes/          # staging code
└── workspace/gulfgym-dev/codes/         # gulfgym Laravel app (git clone develop)
```

---

## Docker Network Topology

```
┌─────────────────── public_edge ──────────────────┐
│  nginx-gateway (port 80 + 443)                   │
│  loads conf.d/*.conf + conf.d.tenants/*.conf     │
└───────────────────────────────────────────────────┘
         │
┌─────── private_backend ──────────────────────────┐
│  nginx-gateway    postgres    pgbouncer           │
│  redis            reverb      beszel-hub          │
│  storeconsole-production-web-{blue,green}        │
│  storeconsole-production-{queue,scheduler,ssr}   │
│  storeconsole-staging-*  (same pattern)          │
│  storeconsole-dev-*      (same pattern)          │
│  gulfgym-php-fpm  gulfgym-workers  gulfgym-scheduler │
│  storeconsole-workspace-{nginx,php}              │
│  gulfgym-workspace-{nginx,php}                   │
└───────────────────────────────────────────────────┘
         │
┌─────── monitoring_internal ──────────────────────┐
│  nginx-gateway    beszel-hub    beszel-agent      │
│  docker-event-mailer                             │
└───────────────────────────────────────────────────┘

┌─────── storeconsole-workspace-net ───────────────┐
│  storeconsole-workspace-nginx (port 8084)        │
│  storeconsole-workspace-php (PHP-FPM live mount) │
│  storeconsole-workspace-vite (Vite HMR, 5174)   │
│  nginx-gateway proxies dev.storeconsole.com    │
│    → 172.17.0.1:8084                            │
└───────────────────────────────────────────────────┘

┌─────── gulfgym-workspace-net ────────────────────┐
│  gulfgym-workspace-nginx (port 8085)             │
│  gulfgym-workspace-php   (PHP-FPM live mount)    │
│  gulfgym-workspace-vite  (Vite HMR, 5175)       │
│  nginx-gateway proxies gulfgym-dev.anichur.com │
│    → 172.17.0.1:8085                            │
└───────────────────────────────────────────────────┘
```

### Tenant Separation

nginx-gateway includes tenant nginx confs from `/etc/nginx/conf.d.tenants/` (mapped from `/opt/gulfgym-platform/nginx/conf.d/` on host). Each project owns its own nginx vhosts:

- **storeconsole** owns `_proxy/nginx/conf.d/` — synced by storeconsole CI
- **gulfgym** owns `/opt/gulfgym-platform/nginx/conf.d/` — synced by gulfgym CI

---

## CI/CD Pipeline — Zero-Downtime Deploy

```
Developer pushes to GitHub
         │
         ▼
┌─────────────────────────────────────────────────────┐
│  GitHub Actions (.github/workflows/storeconsole-deploy.yml)
│                                                     │
│  trigger: push to develop / staging / master        │
│  OR:      workflow_dispatch (manual, choose branch) │
│                                                     │
│  Branch → Environment mapping:                      │
│    develop → dev      → dev.storeconsole.com        │
│    staging → staging  → staging.storeconsole.com    │
│    master  → production → storeconsole.com          │
└─────────────────────────────────────────────────────┘
         │
         ▼
Step 1: Resolve branch + environment + commit SHA
         │
         ▼
Step 2: Validate required GitHub Secrets exist
  DEPLOY_SSH_HOST / DEPLOY_SSH_USER / DEPLOY_SSH_PRIVATE_KEY
  REVERB_APP_KEY  (baked into JS bundle at build time)
         │
         ▼
Step 3: Login to GHCR (GitHub Container Registry)
  ghcr.io/anisaronno/storeconsole
         │
         ▼
Step 4: Docker Buildx — Build & Push image
  FROM: docker/app/app.deploy.Dockerfile
  Platform: linux/amd64
  Build args (baked at build time, NOT runtime):
    VITE_REVERB_APP_KEY   ← from GitHub Secrets
    VITE_REVERB_HOST      ← per-environment domain
    VITE_REVERB_PORT=443
    VITE_REVERB_SCHEME=https
  Tags pushed:
    :master / :staging / :develop    (branch tag)
    :<git-sha>                        (immutable, used for deploy)
    :production / :staging / :dev    (env alias)
    :latest-production / ...          (latest alias)
  Cache: GitHub Actions cache (type=gha)
         │
         ▼
Step 5: Sync ops bundle to server (rsync over SSH)
  Syncs deploy/ → /opt/storeconsole-platform/
  Excluded (server-side only, never overwritten):
    .env files, active/active_color, backups, logs, auth/, certs/, upstreams/
  After sync: runs render-secrets.sh to update per-env .env files
         │
         ▼
Step 6: Deploy over SSH → deploy-storeconsole.sh
  args: environment  sha  branch  sha  actor
```

---

## Blue-Green Deployment Flow

```
Server state BEFORE deploy (e.g., current active = blue):

  nginx-gateway ──FastCGI──▶ storeconsole-production-web-BLUE (active)
                             storeconsole-production-web-green (stopped)

─────────────────────── DEPLOY STARTS ───────────────────────

Step 1: Ensure disk space for pull
  → docker image prune -af if < 8GB free

Step 2: Pull new image (SHA-tagged, immutable)
  → docker pull ghcr.io/anisaronno/storeconsole:<sha>

Step 3: Extract public assets (CSS/JS/media) to INACTIVE slot
  → docker run --rm → copy /var/www/html/public → ./green/public/

Step 4: Prepare shared storage layout
  → ensure storage/app, storage/logs, storage/framework dirs exist

Step 5: Start INACTIVE web container (green)
  → docker compose up -d web-green
  → wait for PHP-FPM healthcheck (up to ~20s)

Step 6: Clear Laravel caches on inactive container
  → php artisan optimize:clear (config, cache, compiled, events, routes, views)

Step 7: Run pre-migration DB backup (production only)
  → backup-postgres.sh

Step 8: Run migrations (on inactive container)
  → php artisan migrate --force  (all environments)
  → Migration status recorded for deploy alert

Step 9: Run warmup commands on inactive container
  → php artisan config:cache
  → php artisan route:cache
  → php artisan view:cache
  → php artisan event:cache
  → php artisan storage:link

Step 10: Update nginx upstream pointer → GREEN
  → write upstreams/storeconsole-production-active.conf:
      upstream storeconsole_production_active {
          server storeconsole-production-web-green:9000 max_fails=3 fail_timeout=10s;
          keepalive 16;
      }
  → docker exec nginx-gateway nginx -s reload
  → Traffic now routes to GREEN (zero downtime)
  → active_color file updated: echo "green" > active_color
  → active symlink updated: ln -sfn green active

Step 11: External healthcheck
  → curl https://storeconsole.com/up  (or /health, or / → 200/301)
  → If fails → automatic rollback to blue

Step 12: Grace period (10s) then stop old container
  → docker rm -f storeconsole-production-web-blue

Step 13: Prune old Docker images (keep last 24h)
  → docker image prune -af --filter "until=24h"

Step 14: Send deploy success alert email

─────────────────────── DEPLOY COMPLETE ───────────────────────

Server state AFTER deploy:

  nginx-gateway ──FastCGI──▶ storeconsole-production-web-GREEN (active)
                             storeconsole-production-web-blue  (stopped/removed)
```

### Rollback

If any step fails after nginx is switched:

```
  rollback_on_failure() auto-triggers:
  1. Restore upstream pointer → BLUE
  2. nginx -s reload
  3. Send failure alert email
  4. Deploy exits with code 1 (CI marks as failed)
```

---

## Environment Configuration

| Variable | Production | Staging | Dev |
|----------|-----------|---------|-----|
| `APP_ENV` | production | staging | development |
| `APP_DEBUG` | false | false | false |
| `APP_URL` | https://storeconsole.com | https://staging.storeconsole.com | https://dev.storeconsole.com |
| `DB_HOST` | pgbouncer | pgbouncer | pgbouncer |
| `DB_DATABASE` | storeconsole_production | storeconsole_staging | storeconsole_dev |
| `SSR_ENABLED` | true | false | false |
| `REDIS_PREFIX` | storeconsole_prod | storeconsole_staging | storeconsole_dev |

All secrets (`DB_PASSWORD`, `REDIS_PASSWORD`, AI keys, etc.) are stored ONLY on the server in `common/.env` and injected per-environment by `render-secrets.sh` during each deploy.

---

## Redis DB Isolation

All apps share 4 fixed Redis databases. **Key-space isolation is provided entirely by the unique `REDIS_PREFIX` per app/environment.** This approach supports unlimited future apps (hrm, accounting, etc.) without hitting the 16-DB limit.

```
┌───────────────────────────────────────────────────────────────┐
│  Single Redis instance  (shared, password-protected)          │
│                                                               │
│  PRODUCTION — DEDICATED (never shared with other apps):       │
│  DB 0  general/default   prefix: storeconsole_prod_           │
│  DB 1  cache             prefix: storeconsole_prod_           │
│  DB 2  sessions          prefix: storeconsole_prod_           │
│  DB 3  queue/horizon     prefix: storeconsole_prod_           │
│                                                               │
│  NON-PROD — SHARED (prefix prevents cross-contamination):     │
│  DB 4  general/default   storeconsole_staging_ | _dev_        │
│  DB 5  cache             storeconsole_staging_ | _dev_        │
│  DB 6  sessions          storeconsole_staging_ | _dev_        │
│  DB 7  queue/horizon     storeconsole_staging_ | _dev_        │
│                                                               │
│  Future new app (e.g. hrm.storeconsole.com):                  │
│  DB 8-11  hrm_prod_ (dedicated)                               │
│  DB 12-13 hrm_staging_ / hrm_dev_ (shared non-prod)           │
│                                                               │
│  Strategy: production always gets dedicated DBs; all other    │
│  environments share a block with unique prefixes.             │
└───────────────────────────────────────────────────────────────┘
```

Key naming example:
- `storeconsole_prod_:cache:product:123` ← production cache key
- `storeconsole_staging_:cache:product:123` ← staging cache key
- `hrm_prod_:cache:employee:99` ← future HRM app

To flush only one environment's cache safely:
```bash
# Flush production cache keys in DB 1
docker exec redis redis-cli -a "$REDIS_PASSWORD" -n 1 \
  --scan --pattern "storeconsole_prod_*" \
  | xargs -r docker exec -i redis redis-cli -a "$REDIS_PASSWORD" -n 1 DEL
```

---

## PostgreSQL User Isolation

Each environment connects with its own restricted PgSQL user via pgbouncer.

```
┌────────────────────────────────────────────────────────────┐
│  pgbouncer (transaction-pool mode, max 500 connections)    │
│                                                            │
│  storeconsole_production → user: storeconsole_prod_user    │
│  storeconsole_staging    → user: storeconsole_staging_user │
│  storeconsole_dev        → user: storeconsole_dev_user     │
│  pulse_production        → user: pulse_prod_user           │
│  pulse_staging           → user: pulse_staging_user        │
│  pulse_dev               → user: pulse_dev_user            │
│                                                            │
│  Each user: SELECT/INSERT/UPDATE/DELETE on own schema only │
│  No user can read another environment's data               │
└────────────────────────────────────────────────────────────┘
```

Credentials are rendered by `render-secrets.sh` from `common/.env` on every deploy — never committed to git.

---

## Queue Workers and Cron

Every environment runs independent queue and scheduler containers.

```
storeconsole-production-queue     ← php artisan horizon
storeconsole-production-scheduler ← schedule:run every 60s loop
storeconsole-production-ssr       ← inertia:start-ssr (production ONLY)

storeconsole-staging-queue        ← php artisan horizon
storeconsole-staging-scheduler    ← schedule:run every 60s loop
(staging: no SSR — saves ~0.20 CPU + 192MB; not needed for testing)

storeconsole-dev-queue            ← php artisan horizon
storeconsole-dev-scheduler        ← schedule:run every 60s loop
(dev: no SSR, no pulse-check — saves ~0.30 CPU + 288MB)

storeconsole workspace (dev.storeconsole.com):
storeconsole-workspace-nginx  ← nginx → PHP-FPM (port 8084)
storeconsole-workspace-php    ← PHP-FPM (live code mount from /opt/apps/workspace/storeconsole-dev/codes)
storeconsole-workspace-vite   ← Vite HMR dev server (port 5174, docker-cli for wayfinder:generate)

gulfgym workspace (gulfgym-dev.anichur.com):
gulfgym-workspace-nginx  ← nginx → PHP-FPM (port 8085)
gulfgym-workspace-php    ← PHP-FPM (live code mount from /opt/apps/workspace/gulfgym-dev/codes)
gulfgym-workspace-vite   ← Vite HMR dev server (port 5175)

Start workspaces:
  bash /opt/storeconsole-platform/scripts/start-workspace.sh storeconsole
  bash /opt/storeconsole-platform/scripts/start-workspace.sh gulfgym
  bash /opt/storeconsole-platform/scripts/start-workspace.sh all
```

All containers use `restart: unless-stopped` — they restart automatically after server reboots or Docker daemon restarts.

Check queue health on server:
```bash
docker exec storeconsole-production-queue php artisan horizon:status
docker logs storeconsole-production-queue --tail=50
docker logs storeconsole-production-scheduler --tail=20
```

---

## Nginx Gateway Routing

```
Request arrives at nginx-gateway (port 443):
  │
  ├─ Host: storeconsole.com
  │   └─ FastCGI → storeconsole_production_active upstream
  │                (server: storeconsole-production-web-{blue|green}:9000)
  │
  ├─ Host: staging.storeconsole.com   [basic auth: staging.htpasswd]
  │   └─ FastCGI → storeconsole_staging_active upstream
  │
  ├─ Host: dev.storeconsole.com       [basic auth: dev.htpasswd]
  │   └─ FastCGI → storeconsole_dev_active upstream   (blue-green CI deploy)
  │      OR HTTP proxy → http://host-gateway:8084      (workspace mode, port 8084)
  │
  ├─ Host: monitor.storeconsole.com
  │   └─ HTTP proxy → beszel-hub:8090
  │
  └─ Host: www.storeconsole.com
      └─ 301 → storeconsole.com
```

The active upstream is rewritten on every deploy by the deploy script. nginx reloads gracefully — zero dropped connections.

---

## TLS Certificates

Managed by Let's Encrypt via `certbot` (webroot challenge). Certificate covers:

- `storeconsole.com`
- `www.storeconsole.com`
- `staging.storeconsole.com`
- `dev.storeconsole.com`
- `monitor.storeconsole.com`

To issue or expand the certificate (run on server):
```bash
/opt/storeconsole-platform/scripts/issue-certificates.sh your@email.com
```

Auto-renewal: add to server crontab:
```bash
0 3 * * * docker run --rm \
  -v /opt/storeconsole-platform/_proxy/nginx/certs:/etc/letsencrypt \
  -v /opt/storeconsole-platform/_shared/certbot-www:/var/www/certbot \
  certbot/certbot renew --quiet \
  && docker exec nginx-gateway nginx -s reload
```

---

## Monitoring (Beszel)

Access: https://monitor.storeconsole.com  
Basic auth: `monitor.htpasswd`

Beszel monitors:
- CPU, RAM, disk, network, load average per system
- Docker container health per server
- Alert via email on threshold breach

Red dot in Beszel = load average > number of CPU cores. Normal causes after a fresh deploy:
- Queue workers processing backlog (embeddings, notifications)
- PHP-FPM warming up opcode cache
- SSR compilation

If load stays high → check `docker stats` to find the offending container.

---

## Backup Strategy

```bash
/opt/storeconsole-platform/scripts/backup-postgres.sh
```

- Runs daily at 17:00 Asia/Dhaka
- Creates compressed `.sql.gz` dumps for all databases
- Uploads to Cloudflare R2: `s3://storeconsole/storeconsole.com/<env>/YYYY/MM/DD/`
- Retention cleanup at 17:45
- Pre-migration snapshot on every production deploy

Restore procedure: see `RESTORE.md`.

---

## Hermes Runbook — Manual Server Commands

### Activate dev.storeconsole.com workspace (one-time setup)

```bash
# 1. Create dev.htpasswd (copies dev credentials; run once)
cp /opt/storeconsole-platform/_proxy/nginx/auth/dev.htpasswd \
   /opt/storeconsole-platform/_proxy/nginx/auth/dev.htpasswd

# 2. Recreate nginx-gateway with extra_hosts for host-gateway resolution
cd /opt/storeconsole-platform/common
docker compose up -d --force-recreate nginx-gateway

# 3. Wait 10 seconds for nginx to start, then expand TLS cert
sleep 10
/opt/storeconsole-platform/scripts/issue-certificates.sh anis904692@gmail.com
```

After this, `https://dev.storeconsole.com` proxies to the storeconsole workspace on port 8084.

### Fresh migrations + seed (all environments)

```bash
# Production (safe — only runs seeders if ALLOW_STORECONSOLE_DEMO_SEED=true)
docker exec storeconsole-production-web-$(cat /opt/storeconsole-platform/storeconsole.com/active_color) \
  php artisan migrate --force

# Staging
docker exec storeconsole-staging-web-$(cat /opt/storeconsole-platform/staging.storeconsole.com/active_color) \
  php artisan migrate --force

# Dev (fresh with seed)
docker exec storeconsole-dev-web-$(cat /opt/storeconsole-platform/dev.storeconsole.com/active_color) \
  php artisan migrate:fresh --seed --no-interaction
```

### Run embeddings on production

```bash
docker exec storeconsole-production-web-$(cat /opt/storeconsole-platform/storeconsole.com/active_color) \
  php artisan db:seed --class="AnisAronno\\Intelligence\\Database\\Seeders\\EmbeddingBackfillSeeder" --no-interaction
```

### Check queue/cron status

```bash
# Horizon status
docker exec storeconsole-production-queue php artisan horizon:status

# Live queue tail
docker logs -f storeconsole-production-queue

# Scheduler last runs
docker logs storeconsole-production-scheduler --tail=30

# All container health
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"
```

### Apply Redis DB fix to running environments

After the next CI deploy, Redis DBs will be correctly isolated. To apply immediately without deploying:

```bash
for env in production staging dev; do
  /opt/storeconsole-platform/scripts/render-secrets.sh
  docker exec storeconsole-${env}-web-$(cat /opt/storeconsole-platform/storeconsole.com/active_color) \
    php artisan config:clear
done
```

### Prune disk space manually

```bash
docker image prune -af --filter "until=48h"
docker system prune -f
df -h /
```

### Restart a specific environment (graceful)

```bash
# Trigger a new deploy from GitHub Actions (preferred — zero downtime)
gh workflow run storeconsole-deploy.yml --field target_branch=master

# Or restart containers directly (brief interruption)
cd /opt/storeconsole-platform/storeconsole.com
docker compose restart
```

### View nginx access/error logs

```bash
tail -f /opt/storeconsole-platform/_shared/logs/nginx/access.log
tail -f /opt/storeconsole-platform/_shared/logs/nginx/error.log
```

---

## Troubleshooting

### Site returning 502 Bad Gateway

```bash
# Check if PHP-FPM container is running
docker ps | grep storeconsole-production-web

# Check nginx upstream config
cat /opt/storeconsole-platform/_proxy/nginx/upstreams/storeconsole-production-active.conf

# Restart PHP-FPM (will cause brief interruption — prefer redeploy)
cd /opt/storeconsole-platform/storeconsole.com
docker compose restart web-$(cat active_color)
```

### dev.storeconsole.com returns 502

```bash
# Check if workspace container is running
docker ps | grep storeconsole-web

# Start workspace if stopped
cd ~/projects/storeconsole  # workspace dir
docker compose -f docker/docker-compose.dev.yml up -d

# Check if nginx-gateway has host-gateway in extra_hosts
docker inspect nginx-gateway | grep -A5 "ExtraHosts"
# If empty → run: docker compose up -d --force-recreate nginx-gateway
```

### High load average (Beszel red dot)

```bash
# Find CPU-hungry containers
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Common causes after deploy:
# - Horizon processing embedding jobs → normal, subsides in minutes
# - SSR warming up → normal, subsides after first requests
# - Postgres autovacuum → check with: docker exec postgres psql -U postgres -c "SELECT * FROM pg_stat_activity WHERE state='active';"
```

### Migrations failing ("relation already exists")

All Create migrations have `Schema::hasTable()` guards — they skip if the table exists. If a migration fails:

```bash
docker exec storeconsole-production-web-green \
  php artisan migrate:status | grep -v "Ran"
```

### Redis memory full

```bash
docker exec redis redis-cli -a "$REDIS_PASSWORD" INFO memory
docker exec redis redis-cli -a "$REDIS_PASSWORD" DBSIZE

# Flush a specific environment's cache (staging = DB 5)
docker exec redis redis-cli -a "$REDIS_PASSWORD" -n 5 FLUSHDB
```
