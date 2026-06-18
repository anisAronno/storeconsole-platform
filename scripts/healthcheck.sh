#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/storeconsole-platform"
SCRIPTS_DIR="${BASE_DIR}/scripts"
COMMON_ENV="${BASE_DIR}/_shared/.env"
RUNTIME_LIB="${SCRIPTS_DIR}/lib-runtime.sh"

if [[ -f "$RUNTIME_LIB" ]]; then
  source "$RUNTIME_LIB"
fi

set -a
source "$COMMON_ENV"
set +a

FAILURES=()

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[OK] ${name}"
  else
    echo "[FAIL] ${name}"
    FAILURES+=("${name}")
  fi
}

check_app_endpoint() {
  local label="$1"
  shift
  local url_base="$1"
  shift
  local auth_args=("$@")

  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${auth_args[@]}" "${url_base}/up" || echo 000)"
  if [[ "$code" == "200" ]]; then
    echo "[OK] ${label} (/up)"
    return 0
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${auth_args[@]}" "${url_base}/health" || echo 000)"
  if [[ "$code" == "200" ]]; then
    echo "[OK] ${label} (/health)"
    return 0
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${auth_args[@]}" "${url_base}/" || echo 000)"
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    echo "[OK] ${label} (/) -> ${code}"
    return 0
  fi

  echo "[FAIL] ${label} -> up/health/root failed (${code})"
  FAILURES+=("${label}")
  return 1
}

check "nginx container" docker ps --filter name=^nginx-gateway$ --filter status=running
check "postgres container" docker ps --filter name=^postgres$ --filter status=running
check "pgbouncer container" docker ps --filter name=^pgbouncer$ --filter status=running
check "redis container" docker ps --filter name=^redis$ --filter status=running
check "beszel-hub container" docker ps --filter name=^beszel-hub$ --filter status=running
check "docker-event-mailer container" docker ps --filter name=^docker-event-mailer$ --filter status=running
check "production ssr container" docker ps --filter name=^storeconsole-production-ssr$ --filter status=running
check "staging ssr container" docker ps --filter name=^storeconsole-staging-ssr$ --filter status=running
check "dev ssr container" docker ps --filter name=^storeconsole-dev-ssr$ --filter status=running

check "postgres is ready" docker exec postgres pg_isready -U "$POSTGRES_SUPERUSER" -d "${POSTGRES_SUPERDB:-postgres}"
check "pgbouncer is ready" docker exec pgbouncer nc -z 127.0.0.1 5432
check "redis ping" docker exec redis redis-cli -a "$REDIS_PASSWORD" PING
check "nginx config test" docker exec nginx-gateway nginx -t

check_app_endpoint "production app" "https://storeconsole.com"
check_app_endpoint "staging app" "https://staging.storeconsole.com" -u "${STAGING_BASIC_AUTH_USER:-}:${STAGING_BASIC_AUTH_PASS:-}"
check_app_endpoint "dev app" "https://dev.storeconsole.com" -u "${DEV_BASIC_AUTH_USER:-}:${DEV_BASIC_AUTH_PASS:-}"
gulfgym_dev_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -u "${GULFGYM_DEV_BASIC_AUTH_USER:-}:${GULFGYM_DEV_BASIC_AUTH_PASS:-}" https://gulfgym-dev.anichur.com/ || echo 000)"
if [[ "$gulfgym_dev_code" == "200" || "$gulfgym_dev_code" == "401" ]]; then
  echo "[OK] gulfgym dev (/) -> ${gulfgym_dev_code}"
else
  echo "[FAIL] gulfgym dev -> / failed (${gulfgym_dev_code})"
  FAILURES+=("gulfgym dev")
fi
check_app_endpoint "focus backend" "https://focus-backend.anichur.com"
check_app_endpoint "focus frontend" "https://focus-frontend.anichur.com"
check_app_endpoint "focus web" "https://focus-web.anichur.com"
check "monitor endpoint" curl -fsS --max-time 15 -u "${MONITOR_BASIC_AUTH_USER}:${MONITOR_BASIC_AUTH_PASS}" https://monitor.storeconsole.com

for env in production staging dev; do
  if [[ "$env" == "dev" ]] && ! docker inspect storeconsole-dev-ssr >/dev/null 2>&1; then
    echo "[SKIP] dev inertia ssr (no legacy SSR container)"
    continue
  fi
  if declare -F resolve_active_color >/dev/null 2>&1; then
    active_color="$(resolve_active_color "$env")"
  else
    active_color="$(cat "$(env_app_dir "${env}")/active_color" 2>/dev/null || echo blue)"
  fi
  web_container="storeconsole-${env}-web-${active_color}"
  check "${env} inertia ssr" docker exec "$web_container" php artisan inertia:check-ssr
done

mem_used_pct=$(free | awk '/Mem:/ {printf("%.0f", $3/$2*100)}')
disk_used_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')

if (( mem_used_pct > 85 )); then
  FAILURES+=("memory ${mem_used_pct}%")
fi

if (( disk_used_pct > 85 )); then
  FAILURES+=("disk ${disk_used_pct}%")
fi

if (( ${#FAILURES[@]} > 0 )); then
  payload=$(mktemp)
  {
    echo "{"
    echo "  \"failures\": $(printf '%s\n' "${FAILURES[@]}" | jq -R . | jq -s .),"
    echo "  \"memory_percent\": ${mem_used_pct},"
    echo "  \"disk_percent\": ${disk_used_pct},"
    echo "  \"timestamp_utc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    echo "}"
  } > "$payload"

  ALERT_FROM_EMAIL="${ALERT_FROM_EMAIL}" \
  ALERT_FROM_NAME="${ALERT_FROM_NAME}" \
  ALERT_TO_EMAIL="${ALERT_TO_EMAIL}" \
  BREVO_SMTP_HOST="${BREVO_SMTP_HOST}" \
  BREVO_SMTP_PORT="${BREVO_SMTP_PORT}" \
  BREVO_SMTP_USERNAME="${BREVO_SMTP_USERNAME}" \
  BREVO_SMTP_PASSWORD="${BREVO_SMTP_PASSWORD}" \
  "$SCRIPTS_DIR/send-alert.sh" "healthcheck_failure" "critical" "[STORECONSOLE][CRITICAL] Healthcheck failure" "$payload" || true
  rm -f "$payload"
  exit 1
fi

echo "Healthcheck OK"
