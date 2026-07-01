#!/usr/bin/env bash
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deployer}"
BASE_DIR="/opt/storeconsole-platform"
ENABLE_DOCKER_USERNS_REMAP="${ENABLE_DOCKER_USERNS_REMAP:-false}"

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root or with sudo" >&2
    exit 1
  fi
}

install_prerequisites() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban unattended-upgrades apt-transport-https jq apache2-utils awscli
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
    return
  fi

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

configure_docker() {
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<JSON
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "icc": false,
  "no-new-privileges": true
}
JSON

  if [[ "$ENABLE_DOCKER_USERNS_REMAP" == "true" ]]; then
    jq '. + {"userns-remap":"default"}' /etc/docker/daemon.json > /etc/docker/daemon.json.tmp
    mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
  fi

  systemctl daemon-reload
  systemctl enable docker
  systemctl restart docker
}

create_deploy_user() {
  if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
  fi

  usermod -aG sudo,docker "$DEPLOY_USER"

  mkdir -p "/home/${DEPLOY_USER}/.ssh"
  chmod 700 "/home/${DEPLOY_USER}/.ssh"

  if [[ -f /home/ubuntu/.ssh/authorized_keys ]]; then
    cp /home/ubuntu/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    chown -R "$DEPLOY_USER":"$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
  fi
}

harden_ssh() {
  cat > /etc/ssh/sshd_config.d/00-storeconsole-hardening.conf <<CONF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
AllowUsers ubuntu ${DEPLOY_USER}
CONF

  rm -f /etc/ssh/sshd_config.d/99-storeconsole-hardening.conf

  sshd -t
  systemctl restart ssh
}

configure_firewall() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
}

configure_fail2ban() {
  mkdir -p /opt/storeconsole-platform/_shared/logs/nginx
  touch /opt/storeconsole-platform/_shared/logs/nginx/access.log
  touch /opt/storeconsole-platform/_shared/logs/nginx/error.log

  cat > /etc/fail2ban/jail.d/storeconsole.conf <<CONF
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-http-auth]
enabled = true
port = http,https
logpath = /opt/storeconsole-platform/_shared/logs/nginx/error.log
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-botsearch]
enabled = true
port = http,https
logpath = /opt/storeconsole-platform/_shared/logs/nginx/access.log
maxretry = 3
findtime = 10m
bantime = 2h

[nginx-bad-request]
enabled = true
port = http,https
logpath = /opt/storeconsole-platform/_shared/logs/nginx/error.log
maxretry = 5
findtime = 10m
bantime = 1h
CONF

  systemctl enable fail2ban
  systemctl restart fail2ban
}

configure_unattended_upgrades() {
  dpkg-reconfigure -f noninteractive unattended-upgrades
  systemctl enable unattended-upgrades
  systemctl restart unattended-upgrades
}

prepare_directories() {
  mkdir -p "$BASE_DIR"/{_proxy/nginx/{conf.d,upstreams,certs,auth},_shared/{postgres,pgbouncer,redis,monitoring/{beszel,docker-event-mailer,pulse-shared},backups},storeconsole.com/{blue,green},staging.storeconsole.com,dev.storeconsole.com,scripts}
  mkdir -p "$BASE_DIR/_shared/logs/nginx"
  chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$BASE_DIR"
  touch "$BASE_DIR/_shared/logs/nginx/access.log" "$BASE_DIR/_shared/logs/nginx/error.log"
  chown -R root:root "$BASE_DIR/_shared/logs/nginx"
  chmod 755 "$BASE_DIR/_shared/logs/nginx"
  chmod 644 "$BASE_DIR/_shared/logs/nginx/"*.log
}

create_networks() {
  docker network create public_edge >/dev/null 2>&1 || true
  docker network create private_backend >/dev/null 2>&1 || true
  docker network create monitoring_internal >/dev/null 2>&1 || true
}

install_crons() {
  cat > /etc/cron.d/storeconsole-backup <<CRON
CRON_TZ=Asia/Dhaka
0 17 * * * root ${BASE_DIR}/scripts/backup-postgres.sh all >> /var/log/storeconsole-backup.log 2>&1
45 17 * * * root ${BASE_DIR}/scripts/backup-postgres.sh cleanup >> /var/log/storeconsole-backup-cleanup.log 2>&1
CRON

  cat > /etc/cron.d/storeconsole-health <<CRON
*/10 * * * * root ${BASE_DIR}/scripts/healthcheck.sh >> /var/log/storeconsole-health.log 2>&1
CRON

  chmod 644 /etc/cron.d/storeconsole-backup /etc/cron.d/storeconsole-health
}

require_root
install_prerequisites
install_docker
configure_docker
create_deploy_user
harden_ssh
configure_firewall
configure_fail2ban
configure_unattended_upgrades
prepare_directories
create_networks
install_crons

log "Server bootstrap completed"
