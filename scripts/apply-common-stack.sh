#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/storeconsole-platform"
SHARED_DIR="${BASE_DIR}/_shared"
SCRIPTS_DIR="${BASE_DIR}/scripts"

"${SCRIPTS_DIR}/init-common-env.sh"
"${SCRIPTS_DIR}/render-secrets.sh"

set -a
source "${SHARED_DIR}/.env"
set +a

mkdir -p "${SHARED_DIR}/certbot-www"
mkdir -p "${SHARED_DIR}/logs/nginx"
touch "${SHARED_DIR}/logs/nginx/access.log" "${SHARED_DIR}/logs/nginx/error.log"
chown -R root:root "${SHARED_DIR}/logs/nginx" 2>/dev/null || true
chmod 755 "${SHARED_DIR}/logs/nginx"
chmod 644 "${SHARED_DIR}/logs/nginx/"*.log 2>/dev/null || true

CERT_DIR="${BASE_DIR}/_proxy/nginx/certs/live/storeconsole.com"
if [[ ! -f "${CERT_DIR}/fullchain.pem" || ! -f "${CERT_DIR}/privkey.pem" ]]; then
  mkdir -p "${CERT_DIR}"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -days 30 \
    -subj "/CN=storeconsole.com" \
    -keyout "${CERT_DIR}/privkey.pem" \
    -out "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1
fi

(
  cd "$SHARED_DIR"
  docker compose -f docker-compose.common.yml pull
  docker compose -f docker-compose.common.yml up -d
)

docker ps --format 'table {{.Names}}\t{{.Status}}' | sed -n '1,20p'

echo "Common stack applied."
