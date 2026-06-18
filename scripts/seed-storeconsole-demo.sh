#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:?environment required: production|staging|dev}"
BASE_DIR="/opt/storeconsole-platform"
COMMON_DIR="${BASE_DIR}/_shared"
case "$ENVIRONMENT" in
  production) APP_DIR="${BASE_DIR}/storeconsole.com" ;;
  staging)    APP_DIR="${BASE_DIR}/staging.storeconsole.com" ;;
  dev)        APP_DIR="${BASE_DIR}/dev.storeconsole.com" ;;
esac
SCRIPTS_DIR="${BASE_DIR}/scripts"
RUNTIME_LIB="${SCRIPTS_DIR}/lib-runtime.sh"
CURRENT_STEP="init"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

send_alert() {
  local etype="$1"
  local severity="$2"
  local subject="$3"
  local payload="$4"

  if [[ -x "${SCRIPTS_DIR}/send-alert.sh" ]]; then
    "${SCRIPTS_DIR}/send-alert.sh" "$etype" "$severity" "$subject" "$payload" || true
  fi
}

case "$ENVIRONMENT" in
  production|staging|dev) ;;
  *) fail "invalid environment: ${ENVIRONMENT}" ;;
esac

[[ -f "${COMMON_DIR}/.env" ]] || fail "missing ${COMMON_DIR}/.env"
[[ -f "${APP_DIR}/.env" ]] || fail "missing ${APP_DIR}/.env"
[[ -f "$RUNTIME_LIB" ]] || fail "missing runtime helper: $RUNTIME_LIB"

source "$RUNTIME_LIB"

set -a
source "${COMMON_DIR}/.env"
source "${APP_DIR}/.env"
set +a

ACTIVE_COLOR="$(resolve_active_color "$ENVIRONMENT")"
WEB_CONTAINER="storeconsole-${ENVIRONMENT}-web-${ACTIVE_COLOR}"
if ! docker ps --format '{{.Names}}' | grep -Fxq "$WEB_CONTAINER"; then
  fail "active web container is not running: ${WEB_CONTAINER}"
fi

payload_start="$(mktemp)"
cat > "$payload_start" <<JSON
{"environment":"${ENVIRONMENT}","container":"${WEB_CONTAINER}","status":"started"}
JSON
send_alert "demo_seed_started" "info" "[STORECONSOLE][DEMO SEED STARTED] ${ENVIRONMENT}" "$payload_start"
rm -f "$payload_start"

trap 'status=$?; if [[ $status -ne 0 ]]; then payload=$(mktemp); printf "{\"environment\":\"%s\",\"failed_step\":\"%s\",\"status\":\"failed\"}\n" "$ENVIRONMENT" "$CURRENT_STEP" > "$payload"; send_alert "demo_seed_failed" "critical" "[STORECONSOLE][DEMO SEED FAILED] ${ENVIRONMENT}" "$payload"; rm -f "$payload"; fi' EXIT

log "Running pre-seed backup for ${ENVIRONMENT}"
CURRENT_STEP="backup"
"${SCRIPTS_DIR}/backup-postgres.sh" "$ENVIRONMENT"

log "Clearing Laravel optimized cache"
CURRENT_STEP="optimize_clear"
docker exec "$WEB_CONTAINER" php artisan optimize:clear

log "Running migrations"
CURRENT_STEP="migrate"
docker exec "$WEB_CONTAINER" php artisan migrate --force

log "Running StoreConsoleDemoSeeder"
CURRENT_STEP="seed"
docker exec -e ALLOW_STORECONSOLE_DEMO_SEED=true "$WEB_CONTAINER" php artisan db:seed --class=StoreConsoleDemoSeeder --force

log "Rebuilding Laravel caches"
CURRENT_STEP="cache_rebuild"
docker exec "$WEB_CONTAINER" php artisan config:cache
docker exec "$WEB_CONTAINER" php artisan route:cache
docker exec "$WEB_CONTAINER" php artisan view:cache || true
docker exec "$WEB_CONTAINER" php artisan event:cache || true
docker exec "$WEB_CONTAINER" php artisan storage:link || true

log "Checking SSR from active web"
CURRENT_STEP="ssr_check"
docker exec "$WEB_CONTAINER" php artisan inertia:check-ssr >/dev/null

payload_success="$(mktemp)"
cat > "$payload_success" <<JSON
{"environment":"${ENVIRONMENT}","container":"${WEB_CONTAINER}","status":"success"}
JSON
send_alert "demo_seed_success" "info" "[STORECONSOLE][DEMO SEED SUCCESS] ${ENVIRONMENT}" "$payload_success"
rm -f "$payload_success"

trap - EXIT
log "Store Console demo seed completed for ${ENVIRONMENT}"
