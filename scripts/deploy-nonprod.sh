#!/usr/bin/env bash
# deploy-nonprod.sh — Git-pull deploy for non-prod apps (staging, dev)
# Usage: deploy-nonprod.sh <app> <branch> <git_sha> <actor> [repo_url]
# Example: deploy-nonprod.sh storeconsole-staging staging abc1234 github-bot
set -euo pipefail

APP="${1:?app required: storeconsole-staging|storeconsole-dev}"
BRANCH="${2:-unknown}"
GIT_SHA="${3:-unknown}"
ACTOR="${4:-unknown}"
REPO_URL="${5:-}"

APP_DIR="/opt/apps/${APP}"
APP_CODE_DIR="${APP_DIR}/codes"
BASE_DIR="/opt/storeconsole-platform"
COMMON_ENV="${BASE_DIR}/_shared/.env"
START_TS="$(date +%s)"

log() { printf '[%s] [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$APP" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

log "Deploy started — branch=${BRANCH} sha=${GIT_SHA} actor=${ACTOR}"

# ── Step 0: Initial clone if needed ─────────────────────────────────────────
if [[ ! -d "${APP_DIR}/.git" ]]; then
  if [[ -z "$REPO_URL" ]] && [[ -f "$COMMON_ENV" ]]; then
    REPO_URL="$(grep '^GITHUB_REPO_URL=' "$COMMON_ENV" | cut -d= -f2- | tr -d '"' || true)"
  fi
  [[ -n "$REPO_URL" ]] || fail "App dir ${APP_DIR} has no .git and no REPO_URL provided. Set GITHUB_REPO_URL in _shared/.env or pass as 5th arg."
  log "Cloning repo ${REPO_URL} → ${APP_DIR}..."
  rm -rf "${APP_DIR}"
  git clone --branch "$BRANCH" --depth 50 "$REPO_URL" "$APP_DIR"
fi

[[ -f "${APP_CODE_DIR}/.env" ]] || fail ".env missing at ${APP_CODE_DIR}/.env — run render-secrets.sh first."

# ── Step 1: Pull latest code ────────────────────────────────────────────────
log "Pulling latest code..."
git -C "$APP_DIR" fetch --quiet origin "$BRANCH"
git -C "$APP_DIR" checkout --quiet "$BRANCH"
git -C "$APP_DIR" reset --hard "origin/$BRANCH"
log "Code at: $(git -C "$APP_DIR" rev-parse HEAD)"

# ── Step 2: Install PHP dependencies ────────────────────────────────────────
log "Running composer install..."
docker exec shared-php-fpm \
  sh -c "cd ${APP_CODE_DIR} && composer install --no-dev --no-interaction --optimize-autoloader --quiet" \
  || fail "composer install failed"

# ── Step 3: Build frontend assets ───────────────────────────────────────────
if [[ -f "${APP_CODE_DIR}/package.json" ]]; then
  log "Building frontend assets..."
  cd "$APP_CODE_DIR"
  npm ci --silent 2>&1 | tail -3
  npm run build 2>&1 | tail -5
  cd - > /dev/null
fi

# ── Step 4: Run migrations ──────────────────────────────────────────────────
log "Running migrations..."
docker exec shared-php-fpm \
  sh -c "cd ${APP_CODE_DIR} && php artisan migrate --force --no-interaction" \
  || fail "migrations failed"

# ── Step 5: Cache optimization ─────────────────────────────────────────────
log "Optimizing caches..."
docker exec shared-php-fpm \
  sh -c "cd ${APP_CODE_DIR} && php artisan optimize:clear && php artisan config:cache && php artisan route:cache && php artisan view:cache && php artisan event:cache"

# ── Step 6: Reload PHP-FPM pool (graceful) ──────────────────────────────────
log "Reloading PHP-FPM pool ${APP}..."
docker exec shared-php-fpm kill -USR2 1 2>/dev/null || true

# ── Step 7: Restart Horizon for this app ────────────────────────────────────
log "Restarting Horizon worker..."
docker exec shared-workers \
  sh -c "supervisorctl restart ${APP}-horizon" 2>/dev/null || true

# ── Done ─────────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TS ))
log "Deploy complete in ${ELAPSED}s"
