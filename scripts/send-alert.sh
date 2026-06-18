#!/usr/bin/env bash
set -euo pipefail

EVENT_TYPE="${1:-generic}"
SEVERITY="${2:-info}"
SUBJECT="${3:-[STORECONSOLE][INFO] Event}"
PAYLOAD_INPUT="${4:-{}}"

ALERT_TO_EMAIL="${ALERT_TO_EMAIL:-hello@anichur.com}"
ALERT_FROM_EMAIL="${ALERT_FROM_EMAIL:?ALERT_FROM_EMAIL is required}"
ALERT_FROM_NAME="${ALERT_FROM_NAME:-Store Console Server}"
BREVO_SMTP_HOST="${BREVO_SMTP_HOST:-smtp-relay.brevo.com}"
BREVO_SMTP_PORT="${BREVO_SMTP_PORT:-587}"
BREVO_SMTP_USERNAME="${BREVO_SMTP_USERNAME:?BREVO_SMTP_USERNAME is required}"
BREVO_SMTP_PASSWORD="${BREVO_SMTP_PASSWORD:?BREVO_SMTP_PASSWORD is required}"

SERVER_NAME="${SERVER_NAME:-$(hostname)}"
SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}') }"
TS_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ "$BREVO_SMTP_USERNAME" == SET_* || "$BREVO_SMTP_USERNAME" == "<"* || "$BREVO_SMTP_USERNAME" == "CHANGE_ME"* ]]; then
  echo "Alert skipped: BREVO_SMTP_USERNAME is placeholder"
  exit 0
fi

if [[ "$BREVO_SMTP_PASSWORD" == SET_* || "$BREVO_SMTP_PASSWORD" == "<"* || "$BREVO_SMTP_PASSWORD" == "CHANGE_ME"* ]]; then
  echo "Alert skipped: BREVO_SMTP_PASSWORD is placeholder"
  exit 0
fi

if [[ -f "$PAYLOAD_INPUT" ]]; then
  PAYLOAD_CONTENT="$(cat "$PAYLOAD_INPUT")"
else
  PAYLOAD_CONTENT="$PAYLOAD_INPUT"
fi

TMP_MAIL="$(mktemp)"
trap 'rm -f "$TMP_MAIL"' EXIT

cat > "$TMP_MAIL" <<MAIL
From: ${ALERT_FROM_NAME} <${ALERT_FROM_EMAIL}>
To: ${ALERT_TO_EMAIL}
Subject: ${SUBJECT}
Date: $(LC_ALL=C date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

Store Console Alert
===================
Event Type: ${EVENT_TYPE}
Severity: ${SEVERITY}
Server: ${SERVER_NAME}
Server IP: ${SERVER_IP}
Timestamp UTC: ${TS_UTC}

Payload:
${PAYLOAD_CONTENT}
MAIL

curl --silent --show-error --fail \
  --connect-timeout 10 \
  --max-time 30 \
  --url "smtp://${BREVO_SMTP_HOST}:${BREVO_SMTP_PORT}" \
  --ssl-reqd \
  --user "${BREVO_SMTP_USERNAME}:${BREVO_SMTP_PASSWORD}" \
  --mail-from "${ALERT_FROM_EMAIL}" \
  --mail-rcpt "${ALERT_TO_EMAIL}" \
  --upload-file "$TMP_MAIL" >/dev/null

echo "Alert sent: ${SUBJECT}"
