#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:?environment required: production|staging|dev}"
IMAGE_TAG_INPUT="${2:?image tag required}"
BRANCH="${3:-unknown}"
GIT_SHA="${4:-unknown}"
ACTOR="${5:-unknown}"

BASE_DIR="/opt/storeconsole-platform"
COMMON_DIR="${BASE_DIR}/_shared"
case "$ENVIRONMENT" in
  production) APP_DIR="${BASE_DIR}/storeconsole.com" ;;
  staging)    APP_DIR="${BASE_DIR}/staging.storeconsole.com" ;;
  dev)        APP_DIR="${BASE_DIR}/dev.storeconsole.com" ;;
esac
SCRIPTS_DIR="${BASE_DIR}/scripts"
NGINX_UPSTREAM_DIR="${BASE_DIR}/_proxy/nginx/upstreams"
RUNTIME_LIB="${SCRIPTS_DIR}/lib-runtime.sh"
MARKER_FILE="/tmp/storeconsole-deploying"
LOCK_FILE="/tmp/storeconsole-deploy.lock"
START_TS="$(date +%s)"
CURRENT_STEP="init"
MIGRATION_STATUS="not_run"
HEALTHCHECK_STATUS="pending"
SKIP_IMAGE_PULL="${SKIP_IMAGE_PULL:-false}"
SKIP_EXTERNAL_HEALTHCHECK="${SKIP_EXTERNAL_HEALTHCHECK:-false}"
ACTIVE_EXISTS="false"
RUN_DB_SEED="${RUN_DB_SEED:-false}"
SEED_CLASS="${SEED_CLASS:-StoreConsoleDemoSeeder}"
MIN_DOCKER_PULL_FREE_KB="${MIN_DOCKER_PULL_FREE_KB:-8388608}"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

validate_env() {
  case "$ENVIRONMENT" in
    production|staging|dev) ;;
    *) fail "invalid environment: ${ENVIRONMENT}" ;;
  esac
}

send_alert() {
  local etype="$1"
  local severity="$2"
  local subject="$3"
  local payload="$4"
  if [[ -z "${ALERT_FROM_EMAIL:-}" || -z "${BREVO_SMTP_USERNAME:-}" || -z "${BREVO_SMTP_PASSWORD:-}" ]]; then
    log "Alert skipped (${etype}): missing alert credentials"
    return 0
  fi

  if [[ "${BREVO_SMTP_USERNAME}" == SET_* || "${BREVO_SMTP_USERNAME}" == "<"* || "${BREVO_SMTP_USERNAME}" == "CHANGE_ME"* ]]; then
    log "Alert skipped (${etype}): placeholder BREVO_SMTP_USERNAME"
    return 0
  fi

  if [[ "${BREVO_SMTP_PASSWORD}" == SET_* || "${BREVO_SMTP_PASSWORD}" == "<"* || "${BREVO_SMTP_PASSWORD}" == "CHANGE_ME"* ]]; then
    log "Alert skipped (${etype}): placeholder BREVO_SMTP_PASSWORD"
    return 0
  fi

  if [[ "${ALERT_FROM_EMAIL}" == SET_* || "${ALERT_FROM_EMAIL}" == "<"* || "${ALERT_FROM_EMAIL}" == "alerts@example.com" ]]; then
    log "Alert skipped (${etype}): missing alert credentials"
    return 0
  fi
  SERVER_NAME="${SERVER_NAME:-$(hostname)}" \
  SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}') }" \
  ALERT_TO_EMAIL="${ALERT_TO_EMAIL:-hello@anichur.com}" \
  ALERT_FROM_EMAIL="${ALERT_FROM_EMAIL}" \
  ALERT_FROM_NAME="${ALERT_FROM_NAME:-Store Console Server}" \
  BREVO_SMTP_HOST="${BREVO_SMTP_HOST:-smtp-relay.brevo.com}" \
  BREVO_SMTP_PORT="${BREVO_SMTP_PORT:-587}" \
  BREVO_SMTP_USERNAME="${BREVO_SMTP_USERNAME}" \
  BREVO_SMTP_PASSWORD="${BREVO_SMTP_PASSWORD}" \
  "${SCRIPTS_DIR}/send-alert.sh" "$etype" "$severity" "$subject" "$payload" || true
}

ensure_docker_pull_space() {
  local docker_path="/var/lib/docker"
  local available_kb

  if [[ ! -d "$docker_path" ]]; then
    docker_path="/"
  fi

  available_kb="$(df -Pk "$docker_path" | awk 'NR==2 {print $4}')"
  if [[ -n "$available_kb" && "$available_kb" -lt "$MIN_DOCKER_PULL_FREE_KB" ]]; then
    log "Docker free space below threshold; pruning unused Docker images before pull"
    docker container prune -f >/dev/null 2>&1 || true
    docker image prune -af >/dev/null 2>&1 || true
  fi
}

cleanup_marker() {
  rm -f "$MARKER_FILE"
}

trap cleanup_marker EXIT

rollback_on_failure() {
  local exit_code=$?
  local rollback_status="not_started"
  local rollback_error=""

  if [[ "${ACTIVE_EXISTS:-false}" == "true" && -n "${INACTIVE_COLOR:-}" && -n "${ENVIRONMENT:-}" ]]; then
    rollback_status="started"
    {
      if [[ "$ENVIRONMENT" == "dev" ]]; then
        cat > "${NGINX_UPSTREAM_DIR}/storeconsole-${ENVIRONMENT}-active.conf" <<UPSTREAM
upstream storeconsole_${ENVIRONMENT}_active {
    server storeconsole-workspace-php:9000 max_fails=3 fail_timeout=10s;
    keepalive 16;
}
UPSTREAM
      else
        cat > "${NGINX_UPSTREAM_DIR}/storeconsole-${ENVIRONMENT}-active.conf" <<UPSTREAM
upstream storeconsole_${ENVIRONMENT}_active {
    server storeconsole-${ENVIRONMENT}-web-${ACTIVE_COLOR}:9000 max_fails=3 fail_timeout=10s;
    keepalive 16;
}
UPSTREAM
      fi
      docker exec nginx-gateway nginx -t
      docker exec nginx-gateway nginx -s reload
      sync_active_runtime_marker "$ENVIRONMENT" "$ACTIVE_COLOR"
      rollback_status="success"
    } || {
      rollback_status="failed"
      rollback_error="automatic upstream rollback failed"
    }
  fi

  payload_file=$(mktemp)
  cat > "$payload_file" <<JSON
{
  "app": "storeconsole",
  "environment": "${ENVIRONMENT}",
  "branch": "${BRANCH}",
  "sha": "${GIT_SHA}",
  "image": "${APP_IMAGE_REF:-unknown}",
  "failed_step": "${CURRENT_STEP}",
  "rollback_status": "${rollback_status}",
  "rollback_error": "${rollback_error}",
  "active_color": "${ACTIVE_COLOR:-unknown}",
  "next_manual_command": "bash ${SCRIPTS_DIR}/rollback-storeconsole.sh ${ENVIRONMENT} manual",
  "status": "failed",
  "exit_code": ${exit_code}
}
JSON
  send_alert "deploy_failed" "critical" "[STORECONSOLE][DEPLOY FAILED] ${ENVIRONMENT} ${GIT_SHA}" "$payload_file"
  rm -f "$payload_file"

  exit "$exit_code"
}

trap rollback_on_failure ERR

validate_env

exec 9>"$LOCK_FILE"
if ! flock -w "${DEPLOY_LOCK_TIMEOUT:-2700}" 9; then
  fail "another Store Console deployment is still running"
fi

[ -d "$APP_DIR" ] || fail "missing app dir: $APP_DIR"
[ -f "$APP_DIR/docker-compose.yml" ] || fail "missing compose file in $APP_DIR"
[ -f "$APP_DIR/.env" ] || fail "missing app env file in $APP_DIR"
[ -f "$COMMON_DIR/.env" ] || fail "missing common env file in $COMMON_DIR"
[ -f "$RUNTIME_LIB" ] || fail "missing runtime helper: $RUNTIME_LIB"

source "$RUNTIME_LIB"

set -a
source "$COMMON_DIR/.env"
source "$APP_DIR/.env"
set +a

if [[ "$SKIP_IMAGE_PULL" != "true" ]]; then
  [[ -n "${GHCR_USERNAME:-}" ]] || fail "GHCR_USERNAME missing in common env"
  [[ -n "${GHCR_TOKEN:-}" ]] || fail "GHCR_TOKEN missing in common env"
  if [[ "${GHCR_TOKEN}" == SET_* || "${GHCR_TOKEN}" == "<"* || "${GHCR_TOKEN}" == "CHANGE_ME"* ]]; then
    fail "GHCR_TOKEN is placeholder; set a valid token before deploy"
  fi
fi

touch "$MARKER_FILE"

ACTIVE_COLOR="$(resolve_active_color "$ENVIRONMENT")"
sync_active_runtime_marker "$ENVIRONMENT" "$ACTIVE_COLOR"
if [[ "$ACTIVE_COLOR" == "blue" ]]; then
  INACTIVE_COLOR="green"
else
  INACTIVE_COLOR="blue"
fi
ACTIVE_WEB="storeconsole-${ENVIRONMENT}-web-${ACTIVE_COLOR}"
if docker ps -a --format '{{.Names}}' | grep -Fxq "$ACTIVE_WEB"; then
  ACTIVE_EXISTS="true"
fi

if [[ "$IMAGE_TAG_INPUT" == ghcr.io/* ]]; then
  APP_IMAGE_REF="$IMAGE_TAG_INPUT"
else
  APP_IMAGE_REF="ghcr.io/anisaronno/storeconsole:${IMAGE_TAG_INPUT}"
fi

PAYLOAD_START=$(mktemp)
cat > "$PAYLOAD_START" <<JSON
{
  "app": "storeconsole",
  "environment": "${ENVIRONMENT}",
  "branch": "${BRANCH}",
  "sha": "${GIT_SHA}",
  "image": "${APP_IMAGE_REF}",
  "actor": "${ACTOR}",
  "active_color": "${ACTIVE_COLOR}",
  "next_color": "${INACTIVE_COLOR}",
  "status": "started"
}
JSON
send_alert "deploy_started" "info" "[STORECONSOLE][DEPLOY STARTED] ${ENVIRONMENT} ${GIT_SHA}" "$PAYLOAD_START"
rm -f "$PAYLOAD_START"

if [[ "$SKIP_IMAGE_PULL" == "true" ]]; then
  log "SKIP_IMAGE_PULL=true; using local image: $APP_IMAGE_REF"
  docker image inspect "$APP_IMAGE_REF" >/dev/null 2>&1 || fail "local image not found: $APP_IMAGE_REF"
else
  log "Logging in to GHCR"
  CURRENT_STEP="ghcr_login"
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin >/dev/null

  log "Pulling image: $APP_IMAGE_REF"
  CURRENT_STEP="image_pull"
  ensure_docker_pull_space
  docker pull "$APP_IMAGE_REF" >/dev/null
fi

log "Updating APP_IMAGE in ${APP_DIR}/.env"
CURRENT_STEP="update_app_env"
if grep -q '^APP_IMAGE=' "$APP_DIR/.env"; then
  sed -i.bak "s|^APP_IMAGE=.*|APP_IMAGE=${APP_IMAGE_REF}|" "$APP_DIR/.env"
else
  echo "APP_IMAGE=${APP_IMAGE_REF}" >> "$APP_DIR/.env"
fi

if [[ -n "${REVERB_APP_KEY:-}" ]]; then
  if grep -q '^VITE_REVERB_APP_KEY=' "$APP_DIR/.env"; then
    sed -i.bak "s|^VITE_REVERB_APP_KEY=.*|VITE_REVERB_APP_KEY=${REVERB_APP_KEY}|" "$APP_DIR/.env"
  else
    echo "VITE_REVERB_APP_KEY=${REVERB_APP_KEY}" >> "$APP_DIR/.env"
  fi
  export VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
fi

rm -f "$APP_DIR/.env.bak"
export APP_IMAGE="$APP_IMAGE_REF"

log "Extracting public assets to ${INACTIVE_COLOR}"
CURRENT_STEP="extract_public_assets"
mkdir -p "$APP_DIR/${INACTIVE_COLOR}/public"
docker run --rm \
  -v "$APP_DIR/${INACTIVE_COLOR}/public:/target" \
  alpine:3.20 \
  sh -lc "rm -rf /target/*" >/dev/null
EXTRACT_C="storeconsole-extract-${ENVIRONMENT}-$$"
docker create --name "$EXTRACT_C" "$APP_IMAGE_REF" true >/dev/null
docker cp "$EXTRACT_C":/var/www/html/public/. "$APP_DIR/${INACTIVE_COLOR}/public/"
docker rm -f "$EXTRACT_C" >/dev/null
# docker cp writes files as root via daemon; normalize ownership for runtime user in container.
docker run --rm \
  -v "$APP_DIR/${INACTIVE_COLOR}/public:/target" \
  alpine:3.20 \
  sh -lc "chown -R 1000:1000 /target && chmod -R u+rwX,g+rwX /target" >/dev/null

log "Preparing shared storage layout"
CURRENT_STEP="prepare_shared_storage"
mkdir -p "$APP_DIR/shared-storage/app/public"
mkdir -p "$APP_DIR/shared-storage/framework/cache/data"
mkdir -p "$APP_DIR/shared-storage/framework/sessions"
mkdir -p "$APP_DIR/shared-storage/framework/views"
mkdir -p "$APP_DIR/shared-storage/framework/testing"
mkdir -p "$APP_DIR/shared-storage/logs"
docker run --rm \
  -v "$APP_DIR/shared-storage:/target" \
  alpine:3.20 \
  sh -lc "chown -R 1000:1000 /target && chmod -R u+rwX,g+rwX /target" >/dev/null

log "Starting inactive web container"
CURRENT_STEP="start_inactive_web"
WEB_CONTAINER="storeconsole-${ENVIRONMENT}-web-${INACTIVE_COLOR}"
if docker ps -a --format '{{.Names}}' | grep -Fxq "$WEB_CONTAINER"; then
  docker rm -f "$WEB_CONTAINER" >/dev/null 2>&1 || true
fi
(
  cd "$APP_DIR"
  docker compose up -d --no-deps --force-recreate "web-${INACTIVE_COLOR}"
)

log "Waiting for inactive web container health"
CURRENT_STEP="wait_inactive_health"
for _ in $(seq 1 30); do
  health_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$WEB_CONTAINER" 2>/dev/null || echo starting)"
  running_state="$(docker inspect --format '{{.State.Running}}' "$WEB_CONTAINER" 2>/dev/null || echo false)"
  if [[ "$running_state" == "true" && ( "$health_state" == "healthy" || "$health_state" == "none" ) ]]; then
    break
  fi
  sleep 2
done

health_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$WEB_CONTAINER" 2>/dev/null || echo unknown)"
running_state="$(docker inspect --format '{{.State.Running}}' "$WEB_CONTAINER" 2>/dev/null || echo false)"
if [[ "$running_state" != "true" || ( "$health_state" != "healthy" && "$health_state" != "none" ) ]]; then
  fail "inactive web container failed health state (running=${running_state}, health=${health_state})"
fi

log "Clearing Laravel optimized caches on inactive container"
CURRENT_STEP="clear_optimized_cache"
docker exec "$WEB_CONTAINER" php artisan optimize:clear

docker exec "$WEB_CONTAINER" php -m >/dev/null
docker exec "$WEB_CONTAINER" php --ini >/dev/null
if docker exec "$WEB_CONTAINER" php -m | grep -q '^yourloader$'; then
  log "Custom loader extension detected"
else
  log "Custom loader extension not present (placeholder mode)"
fi

if [[ "$ENVIRONMENT" == "production" ]]; then
  log "Running pre-migration backup"
  CURRENT_STEP="pre_migration_backup"
  "$SCRIPTS_DIR/backup-postgres.sh" production

  log "Running production migrations"
  CURRENT_STEP="migrate_production"
  docker exec "$WEB_CONTAINER" php artisan migrate --force
  MIGRATION_STATUS="ok"
else
  log "Running non-production migrations"
  CURRENT_STEP="migrate_non_production"
  docker exec "$WEB_CONTAINER" php artisan migrate --force
  MIGRATION_STATUS="ok"
fi

if [[ "$RUN_DB_SEED" == "true" ]]; then
  log "Running database seeder (${SEED_CLASS})"
  CURRENT_STEP="db_seed"
  docker exec -e ALLOW_STORECONSOLE_DEMO_SEED="${ALLOW_STORECONSOLE_DEMO_SEED:-false}" "$WEB_CONTAINER" php artisan db:seed --class="${SEED_CLASS}" --force
fi

log "Running Laravel warmup commands on inactive container"
CURRENT_STEP="warmup_commands"
docker exec "$WEB_CONTAINER" php artisan config:cache
docker exec "$WEB_CONTAINER" php artisan route:cache
docker exec "$WEB_CONTAINER" php artisan view:cache || true
docker exec "$WEB_CONTAINER" php artisan event:cache || true
docker exec "$WEB_CONTAINER" php artisan storage:link || true

docker exec "$WEB_CONTAINER" php artisan about >/dev/null
docker exec "$WEB_CONTAINER" php artisan migrate:status >/dev/null || true

log "Switching upstream to ${INACTIVE_COLOR}"
CURRENT_STEP="switch_upstream"
if [[ "$ENVIRONMENT" == "dev" ]]; then
cat > "$NGINX_UPSTREAM_DIR/storeconsole-${ENVIRONMENT}-active.conf" <<UPSTREAM
upstream storeconsole_${ENVIRONMENT}_active {
    server storeconsole-workspace-php:9000 max_fails=3 fail_timeout=10s;
    keepalive 16;
}
UPSTREAM
else
cat > "$NGINX_UPSTREAM_DIR/storeconsole-${ENVIRONMENT}-active.conf" <<UPSTREAM
upstream storeconsole_${ENVIRONMENT}_active {
    server storeconsole-${ENVIRONMENT}-web-${INACTIVE_COLOR}:9000 max_fails=3 fail_timeout=10s;
    keepalive 16;
}
UPSTREAM
fi

docker exec nginx-gateway nginx -t

docker exec nginx-gateway nginx -s reload

log "Updating active color marker"
sync_active_runtime_marker "$ENVIRONMENT" "$INACTIVE_COLOR"

log "Starting/restarting worker services"
CURRENT_STEP="restart_workers"

# Determine which services exist in this environment's compose file
_compose_services="$(cd "$APP_DIR" && docker compose config --services 2>/dev/null || true)"
_has_ssr="$(echo "$_compose_services" | grep -q '^ssr$' && echo true || echo false)"
_has_pulse="$(echo "$_compose_services" | grep -q '^pulse-check$' && echo true || echo false)"

(
  cd "$APP_DIR"
  docker compose up -d queue scheduler 2>/dev/null || true
  if [[ "$_has_ssr" == "true" ]]; then
    docker compose up -d ssr 2>/dev/null || true
  fi
)

SSR_CONTAINER="storeconsole-${ENVIRONMENT}-ssr"
if [[ "$_has_ssr" == "true" ]]; then
  log "Waiting for SSR container health"
  for _ in $(seq 1 30); do
    ssr_running="$(docker inspect --format '{{.State.Running}}' "$SSR_CONTAINER" 2>/dev/null || echo false)"
    ssr_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$SSR_CONTAINER" 2>/dev/null || echo starting)"
    if [[ "$ssr_running" == "true" && ( "$ssr_health" == "healthy" || "$ssr_health" == "none" ) ]]; then
      break
    fi
    sleep 2
  done

  ssr_running="$(docker inspect --format '{{.State.Running}}' "$SSR_CONTAINER" 2>/dev/null || echo false)"
  ssr_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$SSR_CONTAINER" 2>/dev/null || echo unknown)"
  if [[ "$ssr_running" != "true" || ( "$ssr_health" != "healthy" && "$ssr_health" != "none" ) ]]; then
    fail "SSR container failed health state (running=${ssr_running}, health=${ssr_health})"
  fi
fi

if [[ "$_has_pulse" == "true" ]] && docker exec "$WEB_CONTAINER" php artisan list | grep -q 'pulse:check'; then
  (
    cd "$APP_DIR"
    docker compose up -d pulse-check 2>/dev/null || true
  )
  docker exec "storeconsole-${ENVIRONMENT}-pulse-check" php artisan pulse:restart >/dev/null 2>&1 || true
fi

if [[ "${REVERB_ENABLED:-false}" == "true" || "${BROADCAST_CONNECTION:-}" == "reverb" ]]; then
  REVERB_CONTAINER="storeconsole-reverb"
  if [[ "$ENVIRONMENT" == "production" ]]; then
    if grep -q '^STORECONSOLE_REVERB_IMAGE=' "$COMMON_DIR/.env"; then
      sed -i.bak "s|^STORECONSOLE_REVERB_IMAGE=.*|STORECONSOLE_REVERB_IMAGE=${APP_IMAGE_REF}|" "$COMMON_DIR/.env"
    else
      echo "STORECONSOLE_REVERB_IMAGE=${APP_IMAGE_REF}" >> "$COMMON_DIR/.env"
    fi
    rm -f "$COMMON_DIR/.env.bak"
  fi

  (
    cd "$COMMON_DIR"
    docker compose -f docker-compose.common.yml up -d reverb
  )

  for _ in $(seq 1 20); do
    reverb_running="$(docker inspect --format '{{.State.Running}}' "$REVERB_CONTAINER" 2>/dev/null || echo false)"
    reverb_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$REVERB_CONTAINER" 2>/dev/null || echo starting)"
    if [[ "$reverb_running" == "true" && ( "$reverb_health" == "healthy" || "$reverb_health" == "none" ) ]]; then
      break
    fi
    sleep 2
  done

  reverb_running="$(docker inspect --format '{{.State.Running}}' "$REVERB_CONTAINER" 2>/dev/null || echo false)"
  reverb_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$REVERB_CONTAINER" 2>/dev/null || echo unknown)"
  if [[ "$reverb_running" != "true" || ( "$reverb_health" != "healthy" && "$reverb_health" != "none" ) ]]; then
    fail "central reverb container is not healthy: ${REVERB_CONTAINER} (running=${reverb_running}, health=${reverb_health})"
  fi

  for legacy_reverb in storeconsole-production-reverb storeconsole-staging-reverb storeconsole-dev-reverb; do
    if docker inspect "$legacy_reverb" >/dev/null 2>&1; then
      docker rm -f "$legacy_reverb" >/dev/null 2>&1 || true
    fi
  done
fi

docker exec "$WEB_CONTAINER" php artisan queue:restart || true
docker exec "storeconsole-${ENVIRONMENT}-queue" php artisan horizon:terminate >/dev/null 2>&1 || true
if [[ "$_has_ssr" == "true" ]]; then
  docker exec "$WEB_CONTAINER" php artisan inertia:check-ssr >/dev/null 2>&1 || fail "SSR healthcheck failed from ${WEB_CONTAINER}"
fi

log "External healthcheck"
CURRENT_STEP="external_healthcheck"
DOMAIN="storeconsole.com"
AUTH_ARGS=()
case "$ENVIRONMENT" in
  staging) DOMAIN="staging.storeconsole.com" ;;
  dev) DOMAIN="dev.storeconsole.com" ;;
esac

if [[ "$ENVIRONMENT" == "staging" ]]; then
  AUTH_ARGS=(-u "${STAGING_BASIC_AUTH_USER}:${STAGING_BASIC_AUTH_PASS}")
elif [[ "$ENVIRONMENT" == "dev" ]]; then
  AUTH_ARGS=(-u "${DEV_BASIC_AUTH_USER}:${DEV_BASIC_AUTH_PASS}")
fi

if [[ "$SKIP_EXTERNAL_HEALTHCHECK" == "true" ]]; then
  HEALTHCHECK_STATUS="skipped"
else
  if ! curl -fsS --max-time 20 "${AUTH_ARGS[@]}" "https://${DOMAIN}/up" >/dev/null; then
    if ! curl -fsS --max-time 20 "${AUTH_ARGS[@]}" "https://${DOMAIN}/health" >/dev/null; then
      root_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "${AUTH_ARGS[@]}" "https://${DOMAIN}/" || echo 000)"
      if [[ "$root_code" != "200" && "$root_code" != "301" && "$root_code" != "302" ]]; then
        fail "external healthcheck failed for ${DOMAIN} (/up,/health,/ -> ${root_code})"
      fi
    fi
  fi
  HEALTHCHECK_STATUS="ok"
fi

log "Stopping previous color web container after grace period"
CURRENT_STEP="finalize_old_color"
sleep 10
if [[ "${ACTIVE_EXISTS}" == "true" ]]; then
  OLD_WEB="storeconsole-${ENVIRONMENT}-web-${ACTIVE_COLOR}"
  docker rm -f "$OLD_WEB" >/dev/null 2>&1 || true
fi

log "Pruning unused Docker images to reclaim disk space"
docker image prune -af --filter "until=24h" >/dev/null 2>&1 || true

DURATION="$(( $(date +%s) - START_TS ))"
PAYLOAD_SUCCESS=$(mktemp)
cat > "$PAYLOAD_SUCCESS" <<JSON
{
  "app": "storeconsole",
  "environment": "${ENVIRONMENT}",
  "branch": "${BRANCH}",
  "sha": "${GIT_SHA}",
  "image": "${APP_IMAGE_REF}",
  "domain": "${DOMAIN}",
  "old_color": "${ACTIVE_COLOR}",
  "new_color": "${INACTIVE_COLOR}",
  "migration": "${MIGRATION_STATUS}",
  "healthcheck": "${HEALTHCHECK_STATUS}",
  "duration_seconds": ${DURATION},
  "actor": "${ACTOR}",
  "status": "success"
}
JSON
send_alert "deploy_success" "info" "[STORECONSOLE][DEPLOY SUCCESS] ${ENVIRONMENT} ${GIT_SHA}" "$PAYLOAD_SUCCESS"
rm -f "$PAYLOAD_SUCCESS"

echo "${GIT_SHA}" > "${APP_DIR}/last_deploy_sha"

trap - ERR

log "Deployment successful"
