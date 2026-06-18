#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/storeconsole-platform"
ENV_FILE="${BASE_DIR}/_shared/.env"
EXAMPLE_FILE="${BASE_DIR}/_shared/.env.example"
BESZEL_KEY_DIR="${BASE_DIR}/_shared/monitoring/beszel"

[[ -f "$ENV_FILE" ]] || cp "$EXAMPLE_FILE" "$ENV_FILE"

rand_pass() {
  openssl rand -base64 36 | tr -d '=+/\n' | cut -c1-32
}

set_value() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

set_value_quoted() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s#^${key}=.*#${key}=\"${value}\"#" "$ENV_FILE"
  else
    echo "${key}=\"${value}\"" >> "$ENV_FILE"
  fi
}

fill_if_placeholder() {
  local key="$1"
  local current
  current=$(grep -E "^${key}=" "$ENV_FILE" | cut -d'=' -f2- || true)
  if [[ -z "$current" || "$current" == SET_* ]]; then
    set_value "$key" "$(rand_pass)"
  fi
}

fill_if_placeholder "POSTGRES_SUPERPASS"
fill_if_placeholder "REDIS_PASSWORD"
fill_if_placeholder "STORECONSOLE_PROD_PASSWORD"
fill_if_placeholder "STORECONSOLE_STAGING_PASSWORD"
fill_if_placeholder "STORECONSOLE_DEV_PASSWORD"
fill_if_placeholder "PULSE_PROD_PASSWORD"
fill_if_placeholder "PULSE_STAGING_PASSWORD"
fill_if_placeholder "PULSE_DEV_PASSWORD"
fill_if_placeholder "DEV_BASIC_AUTH_PASS"
fill_if_placeholder "STAGING_BASIC_AUTH_PASS"
fill_if_placeholder "MONITOR_BASIC_AUTH_PASS"
fill_if_placeholder "GULFGYM_DEV_BASIC_AUTH_PASS"
fill_if_placeholder "BESZEL_AGENT_TOKEN"

mkdir -p "$BESZEL_KEY_DIR"
if ! grep -q '^BESZEL_AGENT_KEY="\?ssh-' "$ENV_FILE"; then
  if [[ ! -f "${BESZEL_KEY_DIR}/agent_ssh_key" ]]; then
    ssh-keygen -t ed25519 -N '' -f "${BESZEL_KEY_DIR}/agent_ssh_key" >/dev/null
  fi
  pubkey=$(awk '{print $1" "$2}' "${BESZEL_KEY_DIR}/agent_ssh_key.pub")
  set_value_quoted "BESZEL_AGENT_KEY" "$pubkey"
fi

if grep -q '^DEV_BASIC_AUTH_USER=SET_.*$' "$ENV_FILE" || ! grep -q '^DEV_BASIC_AUTH_USER=' "$ENV_FILE"; then
  set_value "DEV_BASIC_AUTH_USER" "devadmin"
fi
if grep -q '^STAGING_BASIC_AUTH_USER=SET_.*$' "$ENV_FILE" || ! grep -q '^STAGING_BASIC_AUTH_USER=' "$ENV_FILE"; then
  set_value "STAGING_BASIC_AUTH_USER" "stagingadmin"
fi
if grep -q '^MONITOR_BASIC_AUTH_USER=SET_.*$' "$ENV_FILE" || ! grep -q '^MONITOR_BASIC_AUTH_USER=' "$ENV_FILE"; then
  set_value "MONITOR_BASIC_AUTH_USER" "monitoradmin"
fi
if grep -q '^GULFGYM_DEV_BASIC_AUTH_USER=SET_.*$' "$ENV_FILE" || ! grep -q '^GULFGYM_DEV_BASIC_AUTH_USER=' "$ENV_FILE"; then
  set_value "GULFGYM_DEV_BASIC_AUTH_USER" "gulfgymdev"
fi

echo "Initialized ${ENV_FILE}. Review Brevo and GHCR values before production deploy."
