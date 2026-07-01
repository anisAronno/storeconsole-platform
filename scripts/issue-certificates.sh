#!/usr/bin/env bash
set -euo pipefail

EMAIL="${1:?usage: issue-certificates.sh <email>}"
BASE_DIR="/opt/storeconsole-platform"

DOMAINS=(
  storeconsole.com
  www.storeconsole.com
  staging.storeconsole.com
  dev.storeconsole.com
  demo.storeconsole.com
  monitor.storeconsole.com
)

mkdir -p "${BASE_DIR}/_proxy/nginx/certs" "${BASE_DIR}/_shared/certbot-www"

existing_fullchain="${BASE_DIR}/_proxy/nginx/certs/live/storeconsole.com/fullchain.pem"
existing_key="${BASE_DIR}/_proxy/nginx/certs/live/storeconsole.com/privkey.pem"
if [[ -f "$existing_fullchain" && -f "$existing_key" ]]; then
  if openssl x509 -in "$existing_fullchain" -noout -issuer 2>/dev/null | grep -q "CN = storeconsole.com"; then
    rm -rf "${BASE_DIR}/_proxy/nginx/certs/live/storeconsole.com"
    rm -rf "${BASE_DIR}/_proxy/nginx/certs/archive/storeconsole.com"
    rm -f "${BASE_DIR}/_proxy/nginx/certs/renewal/storeconsole.com.conf"
  fi
fi

args=()
for d in "${DOMAINS[@]}"; do
  if getent ahosts "$d" >/dev/null 2>&1; then
    args+=("-d" "$d")
  else
    echo "Skipping unresolved domain: $d"
  fi
done

if [[ "${#args[@]}" -eq 0 ]]; then
  echo "No resolvable domains found for certificate request." >&2
  exit 1
fi

docker run --rm \
  -v "${BASE_DIR}/_proxy/nginx/certs:/etc/letsencrypt" \
  -v "${BASE_DIR}/_shared/certbot-www:/var/www/certbot" \
  certbot/certbot certonly --webroot \
  -w /var/www/certbot \
  "${args[@]}" \
  --email "$EMAIL" --agree-tos --no-eff-email --non-interactive

docker exec nginx-gateway nginx -t
docker exec nginx-gateway nginx -s reload

echo "Certificates issued and nginx reloaded"
