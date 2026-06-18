#!/usr/bin/env bash
# start-workspace.sh — Set up and start the storeconsole local workspace
# Usage: start-workspace.sh [storeconsole|gulfgym|all]
set -euo pipefail

TARGET="${1:-all}"
BASE_DIR="/opt/storeconsole-platform"
GULFGYM_BASE_DIR="/opt/gulfgym-platform"
SHARED_ENV="${BASE_DIR}/_shared/.env"

log() { printf '[%s] [workspace] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

[ -f "$SHARED_ENV" ] || fail "Shared env not found at $SHARED_ENV"
set -a; source "$SHARED_ENV"; set +a

# ── storeconsole workspace ────────────────────────────────────────────────────

start_storeconsole_workspace() {
  WS_DIR="${BASE_DIR}/local.storeconsole.com"
  CODE_DIR="/opt/apps/workspace/storeconsole-dev/codes"
  STORAGE_DIR="${WS_DIR}/storage"
  COMPOSE="${WS_DIR}/docker-compose.workspace.yml"

  [ -f "$COMPOSE" ] || fail "Compose file not found: $COMPOSE"

  log "Ensuring storeconsole code exists at ${CODE_DIR}..."
  if [ ! -d "${CODE_DIR}/vendor" ]; then
    log "vendor/ missing — ensure storeconsole-dev branch is deployed first (run deploy-storeconsole.sh dev ...)"
    fail "Code not ready at ${CODE_DIR}. Run a dev deploy first."
  fi

  log "Setting up storage dirs..."
  mkdir -p \
    "${STORAGE_DIR}/app/public" \
    "${STORAGE_DIR}/framework/cache/data" \
    "${STORAGE_DIR}/framework/sessions" \
    "${STORAGE_DIR}/framework/views" \
    "${STORAGE_DIR}/framework/testing" \
    "${STORAGE_DIR}/logs"
  docker run --rm \
    -v "${STORAGE_DIR}:/target" \
    alpine:3.20 sh -lc "chown -R 1000:1000 /target && chmod -R ug+rwX /target" >/dev/null

  if [ ! -f "${WS_DIR}/.env" ]; then
    log "Creating workspace .env from dev env..."
    cp "${BASE_DIR}/dev.storeconsole.com/.env" "${WS_DIR}/.env"
    sed -i "s|^APP_ENV=.*|APP_ENV=local|" "${WS_DIR}/.env"
    sed -i "s|^APP_URL=.*|APP_URL=https://local.storeconsole.com|" "${WS_DIR}/.env"
    sed -i "s|^APP_DEBUG=.*|APP_DEBUG=true|" "${WS_DIR}/.env"
    sed -i "s|^MAIL_MAILER=.*|MAIL_MAILER=log|" "${WS_DIR}/.env"
    # Remove pre-built image reference — workspace uses live code
    sed -i '/^APP_IMAGE=/d' "${WS_DIR}/.env"
    log "Workspace .env created. Review ${WS_DIR}/.env if needed."
  fi

  log "Pulling storeconsole dev image..."
  WS_IMAGE="${STORECONSOLE_WS_IMAGE:-ghcr.io/anisaronno/storeconsole:latest-dev}"
  if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin >/dev/null
  fi
  docker pull "$WS_IMAGE" || true

  log "Starting storeconsole workspace..."
  STORECONSOLE_WS_IMAGE="$WS_IMAGE" docker compose -f "$COMPOSE" up -d --remove-orphans

  log "Waiting for PHP container..."
  sleep 5

  log "Fixing bootstrap/cache permissions..."
  docker run --rm -v "${CODE_DIR}:/app" alpine:3.20 sh -c \
    "mkdir -p /app/bootstrap/cache && chown -R 1000:1000 /app/bootstrap/cache && chmod -R 775 /app/bootstrap/cache" >/dev/null

  log "Running artisan optimize:clear..."
  docker exec storeconsole-workspace-php php artisan optimize:clear 2>/dev/null || true
  docker exec storeconsole-workspace-php php artisan storage:link 2>/dev/null || true

  log "Storeconsole workspace running at https://local.storeconsole.com"
}

# ── gulfgym workspace ─────────────────────────────────────────────────────────

start_gulfgym_workspace() {
  WS_DIR="${GULFGYM_BASE_DIR}/local.gulfgym.anichur.com"
  CODE_DIR="/opt/apps/workspace/gulfgym-dev/codes"
  STORAGE_DIR="${WS_DIR}/storage"
  COMPOSE="${WS_DIR}/docker-compose.workspace.yml"

  [ -f "$COMPOSE" ] || fail "Gulfgym compose not found: $COMPOSE"

  log "Ensuring gulfgym code exists at ${CODE_DIR}..."
  if [ ! -d "${CODE_DIR}" ]; then
    log "Cloning gulfgym repo..."
    GULFGYM_REPO_URL="${GULFGYM_REPO_URL:-}"
    [ -n "$GULFGYM_REPO_URL" ] || fail "Set GULFGYM_REPO_URL in shared .env"
    REPO_PARENT="$(dirname "$(dirname "$CODE_DIR")")"
    mkdir -p "$REPO_PARENT"
    git clone --branch main --depth 50 "$GULFGYM_REPO_URL" "${REPO_PARENT}/gulfgym-dev"
    cd "$CODE_DIR"
    docker run --rm -v "${CODE_DIR}:/app" -w /app composer:2 install --no-dev --no-interaction --optimize-autoloader --no-scripts --ignore-platform-reqs
    docker run --rm -v "${CODE_DIR}:/app" -w /app node:22-alpine sh -c "npm ci --silent"
  fi

  log "Setting up storage dirs..."
  mkdir -p \
    "${STORAGE_DIR}/app/public" \
    "${STORAGE_DIR}/framework/cache/data" \
    "${STORAGE_DIR}/framework/sessions" \
    "${STORAGE_DIR}/framework/views" \
    "${STORAGE_DIR}/framework/testing" \
    "${STORAGE_DIR}/logs"
  docker run --rm \
    -v "${STORAGE_DIR}:/target" \
    alpine:3.20 sh -lc "chown -R 1000:1000 /target && chmod -R ug+rwX /target" >/dev/null

  if [ ! -f "${WS_DIR}/.env" ]; then
    log "Creating gulfgym workspace .env from gulfgym env..."
    cp "${GULFGYM_BASE_DIR}/gulfgym.anichur.com/.env" "${WS_DIR}/.env"
    sed -i "s|^APP_ENV=.*|APP_ENV=local|" "${WS_DIR}/.env"
    sed -i "s|^APP_URL=.*|APP_URL=https://local.gulfgym.anichur.com|" "${WS_DIR}/.env"
    sed -i "s|^APP_DEBUG=.*|APP_DEBUG=true|" "${WS_DIR}/.env"
    sed -i "s|^MAIL_MAILER=.*|MAIL_MAILER=log|" "${WS_DIR}/.env"
    log "Gulfgym workspace .env created."
  fi

  log "Pulling gulfgym image..."
  GULFGYM_WS_IMAGE="${GULFGYM_IMAGE:-ghcr.io/anisaronno/gulfgym:latest}"
  docker pull "$GULFGYM_WS_IMAGE" || true

  log "Starting gulfgym workspace..."
  GULFGYM_WS_IMAGE="$GULFGYM_WS_IMAGE" docker compose -f "$COMPOSE" up -d --remove-orphans

  log "Fixing bootstrap/cache permissions..."
  docker run --rm -v "${CODE_DIR}:/app" alpine:3.20 sh -c \
    "mkdir -p /app/bootstrap/cache && chown -R 1000:1000 /app/bootstrap/cache && chmod -R 775 /app/bootstrap/cache" >/dev/null

  sleep 5
  docker exec gulfgym-workspace-php php /var/www/html/artisan optimize:clear 2>/dev/null || true
  docker exec gulfgym-workspace-php php /var/www/html/artisan storage:link 2>/dev/null || true

  log "GulfGym workspace running at https://local.gulfgym.anichur.com"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$TARGET" in
  storeconsole) start_storeconsole_workspace ;;
  gulfgym)      start_gulfgym_workspace ;;
  all)
    start_storeconsole_workspace
    start_gulfgym_workspace
    ;;
  *) fail "Unknown target: $TARGET (use: storeconsole|gulfgym|all)" ;;
esac

log "Workspace(s) started."
