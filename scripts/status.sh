#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/storeconsole-platform"
SCRIPTS_DIR="${BASE_DIR}/scripts"
RUNTIME_LIB="${SCRIPTS_DIR}/lib-runtime.sh"

if [[ -f "$RUNTIME_LIB" ]]; then
  source "$RUNTIME_LIB"
fi

echo "== Docker Containers =="
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "== Active Blue/Green =="
for env in production staging dev; do
  if [[ "$env" == "dev" ]] && docker inspect storeconsole-workspace-php >/dev/null 2>&1; then
    echo "${env}: workspace"
    continue
  fi
  if declare -F resolve_active_color >/dev/null 2>&1; then
    active_color="$(resolve_active_color "$env")"
  else
    active_color="$(cat "$(env_app_dir "${env}")/active_color" 2>/dev/null || echo unknown)"
  fi
  echo "${env}: ${active_color}"
done

echo
echo "== Resource Usage =="
free -h

echo
echo "== Disk Usage =="
df -h /

echo
echo "== Health Endpoints =="
COMMON_ENV="${BASE_DIR}/_shared/.env"
if [[ -f "$COMMON_ENV" ]]; then
  set -a
  source "$COMMON_ENV"
  set +a
fi

resolve_code() {
  local base_url="$1"
  shift
  local args=("$@")
  local code

  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "${args[@]}" "${base_url}/up" || echo 000)
  if [[ "$code" == "200" ]]; then
    printf '%s' "$code (/up)"
    return
  fi

  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "${args[@]}" "${base_url}/health" || echo 000)
  if [[ "$code" == "200" ]]; then
    printf '%s' "$code (/health)"
    return
  fi

  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 "${args[@]}" "${base_url}/" || echo 000)
  printf '%s' "$code (/)"
}

prod_code=$(resolve_code "https://storeconsole.com")
staging_code=$(resolve_code "https://staging.storeconsole.com" -u "${STAGING_BASIC_AUTH_USER:-}:${STAGING_BASIC_AUTH_PASS:-}")
dev_code=$(resolve_code "https://dev.storeconsole.com" -u "${DEV_BASIC_AUTH_USER:-}:${DEV_BASIC_AUTH_PASS:-}")
gulfgym_dev_code=$(resolve_code "https://gulfgym-dev.anichur.com" -u "${GULFGYM_DEV_BASIC_AUTH_USER:-}:${GULFGYM_DEV_BASIC_AUTH_PASS:-}")
monitor_code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 -u "${MONITOR_BASIC_AUTH_USER:-}:${MONITOR_BASIC_AUTH_PASS:-}" https://monitor.storeconsole.com || echo 000)

echo "https://storeconsole.com -> ${prod_code}"
echo "https://staging.storeconsole.com -> ${staging_code}"
echo "https://dev.storeconsole.com -> ${dev_code}"
echo "https://gulfgym-dev.anichur.com -> ${gulfgym_dev_code}"
echo "https://monitor.storeconsole.com -> ${monitor_code}"

echo
echo "== SSR Status =="
for env in production staging dev; do
  if [[ "$env" == "dev" ]] && docker inspect storeconsole-workspace-php >/dev/null 2>&1; then
    echo "${env}: workspace"
    continue
  fi
  if declare -F resolve_active_color >/dev/null 2>&1; then
    active_color="$(resolve_active_color "$env")"
  else
    active_color="$(cat "$(env_app_dir "${env}")/active_color" 2>/dev/null || echo blue)"
  fi
  web_container="storeconsole-${env}-web-${active_color}"
  if docker exec "$web_container" php artisan inertia:check-ssr >/dev/null 2>&1; then
    echo "${env}: ok"
  else
    echo "${env}: failed"
  fi
done

echo
echo "== Latest Deploy Markers =="
for env in production staging dev; do
  marker="$(env_app_dir "${env}")/last_deploy_sha"
  if [[ -f "$marker" ]]; then
    echo "${env}: $(cat "$marker")"
  else
    echo "${env}: n/a"
  fi
done
