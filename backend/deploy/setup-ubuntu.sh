#!/usr/bin/env bash
# One-time setup of a fresh Ubuntu 24.04 server (tested target: Oracle Cloud Ampere A1) and
# first start of the stack. Safe to run again: it skips what is already done and never
# overwrites an existing .env.
#
#   ./setup-ubuntu.sh collar.example.com
#   ./setup-ubuntu.sh 203-0-113-7.sslip.io      # no domain of your own (DEPLOY-ORACLE.md)
set -euo pipefail

domain="${1:-}"
if [ -z "$domain" ]; then
  echo "usage: $0 <domain pointing at this server>" >&2
  exit 1
fi
cd "$(dirname "$0")"

echo "== Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sudo sh
fi
sudo usermod -aG docker "$USER"

echo "== Firewall: allow 80 and 443"
# Oracle's Ubuntu images ship iptables rules that reject everything but SSH. Ports also have
# to be open in the cloud console (Security List), see DEPLOY-ORACLE.md.
allow() {
  sudo iptables -C INPUT -p "$1" --dport "$2" -j ACCEPT 2>/dev/null ||
    sudo iptables -I INPUT 1 -p "$1" --dport "$2" -j ACCEPT
}
allow tcp 80
allow tcp 443
allow udp 443
if command -v netfilter-persistent >/dev/null; then sudo netfilter-persistent save; fi

echo "== Automatic security updates"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades
# kernel and libc fixes only apply after a reboot; do it at night when one is pending
# (the containers come back on their own: restart: unless-stopped)
sudo tee /etc/apt/apt.conf.d/52collar-reboot >/dev/null <<'APT'
// Smart Collar: reboot at 07:00 UTC (04:00 in Brazil) when an update needs it
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "07:00";
APT

echo "== .env"
if [ -f .env ]; then
  echo ".env already exists, left untouched"
else
  cp .env.example .env
  chmod 600 .env
  sed -i "s|^DOMAIN=.*|DOMAIN=${domain}|" .env
  sed -i "s|^POSTGRES_PASSWORD=$|POSTGRES_PASSWORD=$(openssl rand -hex 32)|" .env
  sed -i "s|^JWT_SECRET=$|JWT_SECRET=$(openssl rand -hex 32)|" .env
  echo ".env written with new random secrets (never commit it)"
fi

echo "== Start"
mkdir -p backups secrets
sudo docker compose up -d --build
echo
echo "Waiting for the HTTPS certificate (up to 2 minutes)..."
for _ in $(seq 1 24); do
  if curl -fsS "https://${domain}/health" >/dev/null 2>&1; then
    echo "OK: https://${domain}/health answers. Use https://${domain} as the server in the app."
    exit 0
  fi
  sleep 5
done
echo "Not answering yet. Check: sudo docker compose logs caddy   (ports 80/443 open? DNS right?)"
exit 1
