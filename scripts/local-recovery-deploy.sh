#!/usr/bin/env bash
set -euo pipefail

SERVER="${DEPLOY_SSH_HOST:-135.125.131.135}"
SSH_USER="${DEPLOY_SSH_USER:-deployer}"
SSH_PORT="${DEPLOY_SSH_PORT:-22}"
REMOTE="${SSH_USER}@${SERVER}"
BASE_DIR="${BASE_DIR:-/opt/storeconsole-platform}"
IMAGE_NAME="${IMAGE_NAME:-ghcr.io/anisaronno/storeconsole}"
GHCR_USERNAME="${GHCR_USERNAME:-anisaronno}"
ACTOR="${USER:-local}"
SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short=12 HEAD)"
STAMP="$(date -u +%Y%m%d%H%M%S)"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

ssh_run() {
  ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE" "$@"
}

remote_env_value() {
  local key="$1"
  ssh_run "awk -F= -v key='$key' '\$1 == key {sub(/^[^=]*=/, \"\"); gsub(/^\"|\"$/, \"\"); print; exit}' \
    ${BASE_DIR}/_shared/.env \
    ${BASE_DIR}/storeconsole.com/.env \
    ${BASE_DIR}/staging.storeconsole.com/.env \
    ${BASE_DIR}/dev.storeconsole.com/.env 2>/dev/null || true"
}

require_tools() {
  command -v ssh >/dev/null 2>&1 || fail "ssh is required"
  command -v tar >/dev/null 2>&1 || fail "tar is required"
  command -v docker >/dev/null 2>&1 || fail "docker is required"
  docker buildx version >/dev/null 2>&1 || fail "docker buildx is required"
}

check_remote() {
  log "Checking SSH to ${REMOTE}"
  ssh_run "test -d '$BASE_DIR' && echo ok" >/dev/null
}

sync_ops() {
  log "Syncing ops files without overwriting secrets, certs, auth, backups, or logs"
  tar \
    --exclude='./ACCESS.local.md' \
    --exclude='./_shared/.env' \
    --exclude='./_shared/backups' \
    --exclude='./_shared/logs' \
    --exclude='./_proxy/nginx/certs' \
    --exclude='./_proxy/nginx/auth' \
    --exclude='./storeconsole.com/.env' \
    --exclude='./staging.storeconsole.com/.env' \
    --exclude='./dev.storeconsole.com/.env' \
    -C deploy \
    -czf - . \
    | ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$REMOTE" \
      "mkdir -p '$BASE_DIR' && tar -xzf - -C '$BASE_DIR' && chmod +x '$BASE_DIR'/scripts/*.sh"
}

docker_login_if_token_present() {
  if [[ -n "${GHCR_TOKEN:-}" ]]; then
    log "Logging in to GHCR using GHCR_TOKEN from environment"
    printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin >/dev/null
  else
    log "GHCR_TOKEN not set locally; using existing Docker login if present"
  fi
}

build_push_env() {
  local environment="$1"
  local domain="$2"
  local reverb_key="$3"
  local tag="manual-${environment}-${SHORT_SHA}-${STAMP}"

  log "Building and pushing ${environment} image ${IMAGE_NAME}:${tag}"
  docker buildx build \
    --platform linux/amd64 \
    -f docker/app/app.deploy.Dockerfile \
    --build-arg BUILD_MODE=prod \
    --build-arg TIMEZONE=UTC \
    --build-arg VITE_REVERB_APP_KEY="$reverb_key" \
    --build-arg VITE_REVERB_HOST="$domain" \
    --build-arg VITE_REVERB_PORT=443 \
    --build-arg VITE_REVERB_SCHEME=https \
    -t "${IMAGE_NAME}:${tag}" \
    -t "${IMAGE_NAME}:latest-${environment}" \
    --push \
    .

  printf '%s' "$tag"
}

deploy_and_seed_env() {
  local environment="$1"
  local branch="$2"
  local tag="$3"

  log "Deploying ${environment} from image tag ${tag}"
  ssh_run "cd '$BASE_DIR' && scripts/deploy-storeconsole.sh '$environment' '$tag' '$branch' '$SHA' '$ACTOR'"

  log "Running safe demo seed for ${environment}"
  ssh_run "cd '$BASE_DIR' && scripts/seed-storeconsole-demo.sh '$environment'"
}

refresh_access_doc() {
  local output="deploy/ACCESS.local.md"
  log "Writing exact server env values to ${output}"
  umask 077
  {
    printf '# Store Console Private Access And Operations\n\n'
    printf 'Generated: %s UTC\n' "$(date -u +'%Y-%m-%d %H:%M:%S')"
    printf 'Source: %s:%s\n\n' "$REMOTE" "$BASE_DIR"
    printf 'This file is gitignored and must never be committed.\n\n'
    printf '## Server Environment Values\n\n'
    ssh_run "for f in \
      '$BASE_DIR/_shared/.env' \
      '$BASE_DIR/storeconsole.com/.env' \
      '$BASE_DIR/staging.storeconsole.com/.env' \
      '$BASE_DIR/dev.storeconsole.com/.env'; do \
        echo '### '\"\$f\"; \
        if [ -f \"\$f\" ]; then sed -n '/^[A-Za-z_][A-Za-z0-9_]*=/p' \"\$f\"; else echo 'MISSING'; fi; \
        echo; \
      done"
    printf '\n## Fixed Access\n\n'
    printf -- '- Production: https://storeconsole.com\n'
    printf -- '- Staging: https://staging.storeconsole.com\n'
    printf -- '- Dev: https://dev.storeconsole.com\n'
    printf -- '- Monitor: https://monitor.storeconsole.com\n'
    printf -- '- Dev Basic Auth: devadmin / vtLmbMv5PCkb5bvG3wn9cg2aBUDhRlDK\n'
    printf -- '- Demo users seeded with password: password\n'
  } > "$output"
}

main() {
  require_tools
  check_remote
  sync_ops
  docker_login_if_token_present

  local reverb_key
  reverb_key="$(remote_env_value REVERB_APP_KEY)"
  [[ -n "$reverb_key" ]] || fail "REVERB_APP_KEY missing on server; run ${BASE_DIR}/scripts/render-secrets.sh on server first"

  local prod_tag staging_tag dev_tag
  prod_tag="$(build_push_env production storeconsole.com "$reverb_key")"
  staging_tag="$(build_push_env staging staging.storeconsole.com "$reverb_key")"
  dev_tag="$(build_push_env dev dev.storeconsole.com "$reverb_key")"

  deploy_and_seed_env production master "$prod_tag"
  deploy_and_seed_env staging staging "$staging_tag"
  deploy_and_seed_env dev develop "$dev_tag"

  refresh_access_doc

  log "Recovery deployment completed. Verify with:"
  log "  https://storeconsole.com/shop"
  log "  https://storeconsole.com/blog"
  log "  https://storeconsole.com/docs"
}

main "$@"
