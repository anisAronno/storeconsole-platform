#!/usr/bin/env bash
# deploy-demo.sh — single-container image deploy for demo.storeconsole.com
# No blue/green: demo isn't zero-downtime-critical, so this stays deliberately
# simple rather than reusing deploy-storeconsole.sh's color-switching machinery.
# Usage: deploy-demo.sh <image-tag> <branch> <git-sha> <actor>
set -euo pipefail

IMAGE_TAG_INPUT="${1:?image tag required}"
BRANCH="${2:-unknown}"
GIT_SHA="${3:-unknown}"
ACTOR="${4:-unknown}"

BASE_DIR="/opt/storeconsole-platform"
APP_DIR="${BASE_DIR}/demo.storeconsole.com"
COMMON_DIR="${BASE_DIR}/_shared"
SCRIPTS_DIR="${BASE_DIR}/scripts"
IMAGE_NAME="ghcr.io/anisaronno/storeconsole"
MIN_DOCKER_PULL_FREE_KB="${MIN_DOCKER_PULL_FREE_KB:-8388608}"
RUN_DB_SEED="${RUN_DB_SEED:-false}"
SEED_CLASS="${SEED_CLASS:-StoreConsoleDemoSeeder}"
WEB_CONTAINER="storeconsole-demo-web"

log() { printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

[[ -d "$APP_DIR" ]] || fail "missing app dir: ${APP_DIR}"
[[ -f "$APP_DIR/.env" ]] || fail ".env missing at ${APP_DIR}/.env — render it first."
[[ -f "$COMMON_DIR/.env" ]] || fail "missing ${COMMON_DIR}/.env"

log "Demo deploy started — branch=${BRANCH} sha=${GIT_SHA} actor=${ACTOR} image_tag=${IMAGE_TAG_INPUT}"

ensure_docker_pull_space() {
  local docker_path="/var/lib/docker"
  local available_kb
  [[ -d "$docker_path" ]] || docker_path="/"
  available_kb="$(df -Pk "$docker_path" | awk 'NR==2 {print $4}')"
  if [[ -n "$available_kb" && "$available_kb" -lt "$MIN_DOCKER_PULL_FREE_KB" ]]; then
    log "Docker free space below threshold; pruning unused images before pull"
    docker container prune -f >/dev/null 2>&1 || true
    docker image prune -af >/dev/null 2>&1 || true
  fi
}

APP_IMAGE_REF="${IMAGE_NAME}:${IMAGE_TAG_INPUT}"

log "Pulling image ${APP_IMAGE_REF}"
CURRENT_STEP="image_pull"
ensure_docker_pull_space
docker pull "$APP_IMAGE_REF" >/dev/null

log "Updating APP_IMAGE in ${APP_DIR}/.env"
CURRENT_STEP="update_app_env"
if grep -q '^APP_IMAGE=' "$APP_DIR/.env"; then
  sed -i.bak "s|^APP_IMAGE=.*|APP_IMAGE=${APP_IMAGE_REF}|" "$APP_DIR/.env"
else
  echo "APP_IMAGE=${APP_IMAGE_REF}" >> "$APP_DIR/.env"
fi
rm -f "$APP_DIR/.env.bak"
export APP_IMAGE="$APP_IMAGE_REF"

log "Extracting public assets"
CURRENT_STEP="extract_public_assets"
mkdir -p "$APP_DIR/public"
docker run --rm -v "$APP_DIR/public:/target" alpine:3.20 sh -lc "rm -rf /target/*" >/dev/null
EXTRACT_C="storeconsole-extract-demo-$$"
docker create --name "$EXTRACT_C" "$APP_IMAGE_REF" true >/dev/null
docker cp "$EXTRACT_C":/var/www/html/public/. "$APP_DIR/public/"
docker rm -f "$EXTRACT_C" >/dev/null
docker run --rm -v "$APP_DIR/public:/target" alpine:3.20 \
  sh -lc "chown -R 1000:1000 /target && chmod -R u+rwX,g+rwX /target" >/dev/null

log "Preparing shared storage layout"
CURRENT_STEP="prepare_shared_storage"
mkdir -p "$APP_DIR/shared-storage/app/public" \
         "$APP_DIR/shared-storage/framework/cache/data" \
         "$APP_DIR/shared-storage/framework/sessions" \
         "$APP_DIR/shared-storage/framework/views" \
         "$APP_DIR/shared-storage/framework/testing" \
         "$APP_DIR/shared-storage/logs"
docker run --rm -v "$APP_DIR/shared-storage:/target" alpine:3.20 \
  sh -lc "chown -R 1000:1000 /target && chmod -R u+rwX,g+rwX /target" >/dev/null

log "Recreating containers"
CURRENT_STEP="recreate_containers"
(
  cd "$APP_DIR"
  docker compose up -d --force-recreate --remove-orphans
)

log "Waiting for web container health"
CURRENT_STEP="wait_health"
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
  fail "web container failed health state (running=${running_state}, health=${health_state})"
fi

log "Clearing optimized caches"
CURRENT_STEP="clear_optimized_cache"
docker exec "$WEB_CONTAINER" php artisan optimize:clear

log "Running migrations"
CURRENT_STEP="migrate"
docker exec "$WEB_CONTAINER" php artisan migrate --force

if [[ "$RUN_DB_SEED" == "true" ]]; then
  log "Running database seeder (${SEED_CLASS})"
  CURRENT_STEP="db_seed"
  docker exec -e ALLOW_STORECONSOLE_DEMO_SEED="${ALLOW_STORECONSOLE_DEMO_SEED:-false}" "$WEB_CONTAINER" php artisan db:seed --class="${SEED_CLASS}" --force
fi

log "Rebuilding caches"
CURRENT_STEP="warmup_commands"
docker exec "$WEB_CONTAINER" php artisan config:cache
docker exec "$WEB_CONTAINER" php artisan route:cache
docker exec "$WEB_CONTAINER" php artisan view:cache || true
docker exec "$WEB_CONTAINER" php artisan event:cache || true
docker exec "$WEB_CONTAINER" php artisan storage:link || true

echo "${IMAGE_TAG_INPUT}" > "$APP_DIR/last_deploy_sha"

log "Demo deploy complete"
