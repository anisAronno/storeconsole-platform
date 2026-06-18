#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/storeconsole-platform"
FAILURES=()
WARNINGS=()

ok() {
  printf '[OK] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES+=("$1")
}

warn() {
  printf '[WARN] %s\n' "$1"
  WARNINGS+=("$1")
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root (or sudo)." >&2
    exit 1
  fi
}

check_sshd_hardening() {
  if sshd -T | grep -q '^permitrootlogin no$'; then
    ok "root ssh login disabled"
  else
    fail "root ssh login is not disabled"
  fi

  if sshd -T | grep -q '^passwordauthentication no$'; then
    ok "password ssh login disabled"
  else
    fail "password ssh login is not disabled"
  fi
}

check_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    fail "ufw is not installed"
    return
  fi

  if ufw status | head -n1 | grep -qi "Status: active"; then
    ok "ufw is active"
  else
    fail "ufw is not active"
  fi

  mapfile -t allow_ports < <(ufw status | awk '/ALLOW/ {print $1}' | sed 's#/tcp##g' | sort -u)
  expected="22 80 443"
  actual="$(printf '%s\n' "${allow_ports[@]}" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"
  if [[ "$actual" == "$expected" ]]; then
    ok "ufw allowed ports are 22,80,443 only"
  else
    fail "ufw allowed ports mismatch (found: ${actual:-none})"
  fi
}

check_fail2ban() {
  if ! systemctl is-active --quiet fail2ban; then
    fail "fail2ban service not active"
    return
  fi
  ok "fail2ban service active"

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    fail "fail2ban-client missing"
    return
  fi

  jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')"
  if echo "$jails" | grep -qw sshd; then
    ok "fail2ban sshd jail enabled"
  else
    fail "fail2ban sshd jail missing"
  fi

  if echo "$jails" | grep -qw nginx-http-auth; then
    ok "fail2ban nginx-http-auth jail enabled"
  else
    warn "fail2ban nginx-http-auth jail missing"
  fi
}

check_unattended_upgrades() {
  if systemctl is-enabled --quiet unattended-upgrades && systemctl is-active --quiet unattended-upgrades; then
    ok "unattended-upgrades enabled and active"
  else
    warn "unattended-upgrades not fully enabled/active"
  fi
}

check_docker_daemon_log_rotation() {
  local daemon_file="/etc/docker/daemon.json"
  if [[ ! -f "$daemon_file" ]]; then
    fail "docker daemon.json missing"
    return
  fi

  if jq -e '.["log-driver"]=="json-file"' "$daemon_file" >/dev/null 2>&1 \
    && jq -e '.["log-opts"]["max-size"]=="10m"' "$daemon_file" >/dev/null 2>&1 \
    && jq -e '.["log-opts"]["max-file"]=="3"' "$daemon_file" >/dev/null 2>&1; then
    ok "docker daemon log rotation configured"
  else
    fail "docker daemon log rotation not set to json-file/10m/3"
  fi
}

check_listening_ports() {
  mapfile -t exposed < <(ss -tuln | awk '/LISTEN/ && ($5 ~ /0\.0\.0\.0:/ || $5 ~ /\[::\]:/) {print $5}' | sed 's/.*://g' | sort -u)
  actual="$(printf '%s\n' "${exposed[@]}" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"
  if [[ "$actual" == "22 80 443" ]]; then
    ok "public listeners restricted to 22,80,443"
  else
    fail "unexpected public listeners detected (${actual:-none})"
  fi
}

check_docker_public_exposure() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker command unavailable"
    return
  fi

  local bad=0
  while IFS=$'\t' read -r name ports; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "nginx-gateway" ]]; then
      if echo "$ports" | grep -qE '0\.0\.0\.0:80->80|0\.0\.0\.0:443->443'; then
        ok "nginx-gateway exposes 80/443"
      else
        fail "nginx-gateway missing 80/443 exposure"
      fi
      continue
    fi

    if [[ -n "${ports// }" ]]; then
      fail "container ${name} has host port exposure (${ports})"
      bad=1
    fi
  done < <(docker ps --format '{{.Names}}{{"\t"}}{{.Ports}}')

  if [[ "$bad" -eq 0 ]]; then
    ok "non-gateway containers do not expose host ports"
  fi
}

check_env_permissions() {
  local files=(
    "${BASE_DIR}/_shared/.env"
    "${BASE_DIR}/storeconsole.com/.env"
    "${BASE_DIR}/staging.storeconsole.com/.env"
    "${BASE_DIR}/dev.storeconsole.com/.env"
  )

  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      fail "missing env file ${f}"
      continue
    fi
    mode="$(stat -c '%a' "$f")"
    if [[ "$mode" -le 640 ]]; then
      ok "permissions ok for ${f}"
    else
      fail "permissions too open for ${f} (${mode})"
    fi
  done
}

check_nginx_cloudflare_real_ip() {
  local conf="${BASE_DIR}/_proxy/nginx/nginx.conf"
  if [[ ! -f "$conf" ]]; then
    fail "nginx.conf missing"
    return
  fi

  if grep -q 'real_ip_header CF-Connecting-IP' "$conf" && grep -q 'set_real_ip_from' "$conf"; then
    ok "cloudflare real ip settings configured"
  else
    fail "cloudflare real ip settings missing"
  fi
}

check_deploy_marker() {
  if [[ -f /tmp/storeconsole-deploying ]]; then
    warn "deploy marker exists: /tmp/storeconsole-deploying"
  else
    ok "deploy marker not present"
  fi
}

main() {
  require_root
  check_sshd_hardening
  check_ufw
  check_fail2ban
  check_unattended_upgrades
  check_docker_daemon_log_rotation
  check_listening_ports
  check_docker_public_exposure
  check_env_permissions
  check_nginx_cloudflare_real_ip
  check_deploy_marker

  echo
  if (( ${#FAILURES[@]} > 0 )); then
    echo "Security audit failed with ${#FAILURES[@]} issue(s)."
    exit 1
  fi

  if (( ${#WARNINGS[@]} > 0 )); then
    echo "Security audit passed with ${#WARNINGS[@]} warning(s)."
  else
    echo "Security audit passed with no warnings."
  fi
}

main "$@"
