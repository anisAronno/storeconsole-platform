#!/usr/bin/env bash
set -euo pipefail

EMAIL="${1:?usage: issue-focus-certificates.sh <email>}"
BASE_DIR="/opt/storeconsole-platform"

DOMAINS=(
  focus-backend.anichur.com
  focus-frontend.anichur.com
  focus-web.anichur.com
)

mkdir -p "${BASE_DIR}/_proxy/nginx/certs" "${BASE_DIR}/_shared/certbot-www"

args=()
for d in "${DOMAINS[@]}"; do
  if getent ahosts "$d" >/dev/null 2>&1; then
    args+=("-d" "$d")
  else
    echo "Skipping unresolved domain: $d"
  fi
done

if [[ "${#args[@]}" -eq 0 ]]; then
  echo "No resolvable focus domains found for certificate request." >&2
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

echo "Focus certificates issued and nginx reloaded"
