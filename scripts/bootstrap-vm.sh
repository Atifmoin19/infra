#!/usr/bin/env bash
# One-time (idempotent) setup of the Oracle Cloud Ampere A1 VM, Ubuntu 22.04/24.04 ARM64.
#   sudo bash bootstrap-vm.sh
# Optional env:
#   DEPLOY_USER=deploy        non-root user that owns /srv and runs docker
#   INFRA_REPO=git@github.com:you/infra.git           cloned to /srv/infra
#   PORTFOLIO_REPO=... PORTFOLIO_BRANCH=main            cloned to /srv/src/portfolio
#   EXPENSE_REPO=...   EXPENSE_BRANCH=revive            cloned to /srv/src/expense
#   SWAP_SIZE=2G
# Safe to re-run: every step checks before changing anything.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

log() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || { echo "Ubuntu only (found ${ID:-unknown})" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

log "Base packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git ufw fail2ban python3-systemd \
  unattended-upgrades apt-listchanges >/dev/null

log "Docker Engine + compose plugin"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null

log "Docker + journald log limits"
DAEMON_JSON='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}'
if [ ! -f /etc/docker/daemon.json ]; then
  printf '%s\n' "$DAEMON_JSON" > /etc/docker/daemon.json
  systemctl restart docker
elif ! grep -q '"max-size"' /etc/docker/daemon.json; then
  echo "WARN: /etc/docker/daemon.json exists without log limits; edit it by hand" >&2
fi
mkdir -p /etc/systemd/journald.conf.d
JOURNAL_CONF=/etc/systemd/journald.conf.d/10-size.conf
if [ ! -f "$JOURNAL_CONF" ]; then
  printf '[Journal]\nSystemMaxUse=200M\nSystemKeepFree=1G\n' > "$JOURNAL_CONF"
  systemctl restart systemd-journald
fi

log "Deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
# Let the admin who ran this script SSH in as the deploy user with the same key.
if [ ! -s "$DEPLOY_HOME/.ssh/authorized_keys" ] && [ -n "${SUDO_USER:-}" ]; then
  SRC_KEYS="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
  if [ -s "$SRC_KEYS" ]; then
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SRC_KEYS" "$DEPLOY_HOME/.ssh/authorized_keys"
  fi
fi

log "Firewall (ufw: 22/tcp, 80/tcp, 443/tcp, 443/udp)"
# Oracle's Ubuntu images ship iptables rules (netfilter-persistent) ending in a REJECT that
# blocks 80/443 even when ufw allows them. Drop only those REJECT lines; keep the rest
# (incl. the InstanceServices OUTPUT rules protecting the metadata service).
RULES=/etc/iptables/rules.v4
if [ -f "$RULES" ] && grep -q -- '-j REJECT --reject-with icmp-host-prohibited' "$RULES"; then
  cp -n "$RULES" "$RULES.oracle-orig"
  sed -i '/-A INPUT -j REJECT --reject-with icmp-host-prohibited/d; /-A FORWARD -j REJECT --reject-with icmp-host-prohibited/d' "$RULES"
  iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
  iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true
fi
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null
# Note: Docker-published ports bypass ufw; only Caddy publishes ports (80/443), so that's fine.

log "fail2ban (sshd)"
JAIL=/etc/fail2ban/jail.d/sshd.local
if [ ! -f "$JAIL" ]; then
  printf '[sshd]\nenabled = true\nbackend = systemd\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n' > "$JAIL"
fi
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban

log "unattended-upgrades (security updates, no auto-reboot)"
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades >/dev/null

log "Swap ($SWAP_SIZE)"
if [ -z "$(swapon --show --noheadings)" ]; then
  [ -f /swapfile ] || { fallocate -l "$SWAP_SIZE" /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; }
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -q vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
fi

log "/srv layout"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /srv/src
clone() { # url dir [branch]
  local url="$1" dir="$2" branch="${3:-}"
  [ -n "$url" ] || return 0
  if [ -d "$dir/.git" ]; then echo "exists: $dir"; return 0; fi
  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$dir"
  sudo -u "$DEPLOY_USER" -H git clone ${branch:+--branch "$branch"} "$url" "$dir"
}
clone "${INFRA_REPO:-}" /srv/infra
clone "${PORTFOLIO_REPO:-}" /srv/src/portfolio "${PORTFOLIO_BRANCH:-main}"
clone "${EXPENSE_REPO:-}" /srv/src/expense "${EXPENSE_BRANCH:-revive}"
# clone "${TASKBOARD_REPO:-}" /srv/src/taskboard "${TASKBOARD_BRANCH:-main}"   # part 2b
if [ -d /srv/infra ]; then
  install -d -o 70 -g 70 /srv/infra/backups /srv/infra/backups/expense
fi

log "Done"
docker --version
docker compose version
ufw status | sed -n '1,12p'
swapon --show
echo "Next: log in as $DEPLOY_USER and follow docs/GO_LIVE.md (env files, secrets, first up)."
