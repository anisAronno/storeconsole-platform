#!/bin/sh
set -eu

ALERT_SCRIPT="${ALERT_SCRIPT:-/opt/scripts/send-alert.sh}"
SERVER_NAME="${SERVER_NAME:-unknown-server}"
SERVER_IP="${SERVER_IP:-0.0.0.0}"
MARKER_FILE="${MARKER_FILE:-/tmp/storeconsole-deploying}"

is_expected_deploy_shutdown() {
  action="$1"
  name="$2"

  [ -f "$MARKER_FILE" ] || return 1

  case "$action" in
    die|stop|destroy|kill)
      echo "$name" | grep -Eq '^storeconsole-(production|staging|dev)-web-(blue|green)$'
      ;;
    *)
      return 1
      ;;
  esac
}

critical_action() {
  case "$1" in
    die|stop|destroy|oom|restart|kill|health_status:unhealthy|health_status:_unhealthy) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_environment() {
  case "$1" in
    storeconsole-production-*) echo "production" ;;
    storeconsole-staging-*) echo "staging" ;;
    storeconsole-dev-*) echo "dev" ;;
    *) echo "unknown" ;;
  esac
}

smtp_configured() {
  case "${BREVO_SMTP_USERNAME:-}" in
    ""|SET_*|"<"*|CHANGE_ME*) return 1 ;;
  esac
  case "${BREVO_SMTP_PASSWORD:-}" in
    ""|SET_*|"<"*|CHANGE_ME*) return 1 ;;
  esac
  case "${ALERT_FROM_EMAIL:-}" in
    ""|alerts@example.com|SET_*|"<"*|CHANGE_ME*) return 1 ;;
  esac
  return 0
}

docker events --format '{{json .}}' | while IFS= read -r event_json; do
  [ -n "$event_json" ] || continue

  action=$(echo "$event_json" | jq -r '.Action // empty')
  action_normalized=$(printf '%s' "$action" | tr ' ' '_')
  ctype=$(echo "$event_json" | jq -r '.Type // empty')
  cname=$(echo "$event_json" | jq -r '.Actor.Attributes.name // "unknown"')

  [ "$ctype" = "container" ] || continue
  critical_action "$action_normalized" || continue

  if is_expected_deploy_shutdown "$action_normalized" "$cname"; then
    echo "suppressed deploy event: ${action_normalized} ${cname}"
    continue
  fi

  image=$(docker inspect --format '{{.Config.Image}}' "$cname" 2>/dev/null || echo "unknown")
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$cname" 2>/dev/null || echo "n/a")
  logs=$(docker logs --tail 50 "$cname" 2>&1 || true)
  ts_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  app_env=$(resolve_environment "$cname")
  payload_file=$(mktemp)
  cat > "$payload_file" <<JSON
{
  "server_name": "${SERVER_NAME}",
  "server_ip": "${SERVER_IP}",
  "environment": "${app_env}",
  "container": "${cname}",
  "image": "${image}",
  "event": "${action_normalized}",
  "timestamp_utc": "${ts_utc}",
  "health": "${health}",
  "suggested_next_command": "docker ps -a --filter name=${cname} && docker logs --tail 200 ${cname}",
  "logs_tail_50": $(printf '%s' "$logs" | jq -Rs .)
}
JSON

  echo "critical event: ${action_normalized} ${cname}"
  if smtp_configured; then
    if ! "$ALERT_SCRIPT" "container_critical_event" "critical" "[STORECONSOLE][CRITICAL] Container ${action}: ${cname}" "$payload_file"; then
      echo "alert send failed for ${cname}"
    fi
  else
    echo "smtp not configured; skipping alert for ${cname}"
  fi
  rm -f "$payload_file"
done
