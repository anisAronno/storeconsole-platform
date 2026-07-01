# Focus Platform — Deployment Guide

Focus University Admission Coaching — 3-project workspace deployment on `135.125.131.135`.

## Architecture

```
Internet → Cloudflare (focus-*.anichur.com)
   │
   ▼
nginx-gateway (storeconsole-platform, port 443)
   │
   ├── focus-backend.anichur.com  → focus_admission_backend_web:80   (Laravel API)
   ├── focus-frontend.anichur.com → focus-university-admission-frontend-web:3000 (Next.js)
   └── focus-web.anichur.com      → focus_university_admission_web_app_web:80  (Laravel)
   │
   ▼
private_backend Docker network
   ├── focus-mysql (MySQL 8.0)
   │   ├── focus_backend
   │   ├── focus_web_app
   │   └── focus_old_web
   └── storeconsole postgres/redis (shared, untouched)
```

## Directory Layout

```
/opt/focus-platform/                          ← this directory
├── nginx/conf.d/                             ← mounted to nginx-gateway
│   ├── 30-focus-backend.conf
│   ├── 31-focus-frontend.conf
│   └── 32-focus-web.conf
├── shared/
│   ├── docker-compose.mysql.yml
│   └── mysql/init/
└── .env.shared                               ← secrets (gitignored)

/opt/apps/workspace/focus/                    ← git clones
├── focus-university-admission-backend/
├── focus-university-admission-frontend/
└── focus-university-admission-web-app/
```

## One-Time Setup

```bash
# 1. Create .env.shared with real secrets
cd /opt/focus-platform
cp .env.shared.example .env.shared
nano .env.shared    # fill in passwords and app keys

# 2. Start MySQL
cd shared
set -a; source ../.env.shared; set +a
docker compose -f docker-compose.mysql.yml up -d

# 3. Clone repos
mkdir -p /opt/apps/workspace/focus
cd /opt/apps/workspace/focus
git clone git@github.com:BS23/focus-university-admission-backend.git
git clone git@github.com:BS23/focus-university-admission-frontend.git
git clone git@github.com:BS23/focus-university-admission-web-app.git

# 4. Configure and start each project (see below)

# 5. Mount nginx configs (edit storeconsole docker-compose.common.yml)
#    Add volume: /opt/focus-platform/nginx/conf.d:/etc/nginx/conf.d.focus:ro
#    Add include: include /etc/nginx/conf.d.focus/*.conf;
#    Then: docker compose -f /opt/storeconsole-platform/_shared/docker-compose.common.yml up -d nginx-gateway
```

## Per-Project Setup

Each project uses its existing `docker/docker-compose.yml` + override.
Key change: set `EXTERNAL_NETWORK_NAME=private_backend` so the nginx-gateway can route to them.

### Backend (Laravel API)

```bash
cd /opt/apps/workspace/focus/focus-university-admission-backend/docker
# Copy .env.example → .env, then edit:
#   EXTERNAL_NETWORK_NAME=private_backend
#   DB_HOST=focus-mysql
#   DB_DATABASE=focus_backend
bash prepare.sh --mode dev
docker compose up -d
```

### Frontend (Next.js)

```bash
cd /opt/apps/workspace/focus/focus-university-admission-frontend/docker
# The docker-compose.yml already publishes port 7003
# Just need to ensure it's on private_backend:
# Edit docker-compose.yml: change common-net to private_backend
# OR add a docker-compose.override.yml that overrides networks
docker compose up -d
```

### Web App (Laravel)

```bash
cd /opt/apps/workspace/focus/focus-university-admission-web-app/docker
bash prepare.sh --mode dev
# Edit .env: EXTERNAL_NETWORK_NAME=private_backend
docker compose up -d
```

## Domains

| Domain | Project | Container |
|--------|---------|-----------|
| focus-backend.anichur.com | Backend (API) | focus_admission_backend_web |
| focus-frontend.anichur.com | Frontend (Next.js) | focus-university-admission-frontend-web |
| focus-web.anichur.com | Web App (Laravel) | focus_university_admission_web_app_web |

All domains are behind Cloudflare (orange cloud / proxied).
TLS: wildcard cert on `anichur.com` covers all subdomains.
