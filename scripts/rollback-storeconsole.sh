#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:?environment required: production|staging|dev}"
REASON="${2:-manual rollback}"

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

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
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

case "$ENVIRONMENT" in
  production|staging|dev) ;;
  *) echo "invalid environment: $ENVIRONMENT" >&2; exit 1 ;;
esac

set -a
source "$COMMON_DIR/.env"
source "$APP_DIR/.env"
set +a

[ -f "$RUNTIME_LIB" ] || { echo "missing runtime helper: $RUNTIME_LIB" >&2; exit 1; }
source "$RUNTIME_LIB"

touch "$MARKER_FILE"
trap 'rm -f "$MARKER_FILE"' EXIT

ACTIVE_COLOR="$(resolve_active_color "$ENVIRONMENT")"
if [[ "$ACTIVE_COLOR" == "blue" ]]; then
  PREVIOUS_COLOR="green"
else
  PREVIOUS_COLOR="blue"
fi

PAYLOAD_START=$(mktemp)
cat > "$PAYLOAD_START" <<JSON
{"environment":"${ENVIRONMENT}","reason":"${REASON}","active_color":"${ACTIVE_COLOR}","target_color":"${PREVIOUS_COLOR}","status":"rollback_started"}
JSON
send_alert "rollback_started" "warning" "[STORECONSOLE][ROLLBACK STARTED] ${ENVIRONMENT}" "$PAYLOAD_START"
rm -f "$PAYLOAD_START"

log "Starting previous color container"
(
  cd "$APP_DIR"
  docker compose up -d "web-${PREVIOUS_COLOR}" queue scheduler
)

cat > "$NGINX_UPSTREAM_DIR/storeconsole-${ENVIRONMENT}-active.conf" <<UPSTREAM
upstream storeconsole_${ENVIRONMENT}_active {
    server storeconsole-${ENVIRONMENT}-web-${PREVIOUS_COLOR}:9000 max_fails=3 fail_timeout=10s;
    keepalive 16;
}
UPSTREAM

docker exec nginx-gateway nginx -t
docker exec nginx-gateway nginx -s reload

sync_active_runtime_marker "$ENVIRONMENT" "$PREVIOUS_COLOR"

docker exec "storeconsole-${ENVIRONMENT}-web-${PREVIOUS_COLOR}" php artisan queue:restart || true
docker exec "storeconsole-${ENVIRONMENT}-web-${PREVIOUS_COLOR}" php artisan pulse:restart >/dev/null 2>&1 || true

PAYLOAD_SUCCESS=$(mktemp)
cat > "$PAYLOAD_SUCCESS" <<JSON
{"environment":"${ENVIRONMENT}","reason":"${REASON}","old_color":"${ACTIVE_COLOR}","new_color":"${PREVIOUS_COLOR}","status":"rollback_success"}
JSON
send_alert "rollback_success" "warning" "[STORECONSOLE][ROLLBACK] ${ENVIRONMENT}" "$PAYLOAD_SUCCESS"
rm -f "$PAYLOAD_SUCCESS"

log "Rollback complete"
