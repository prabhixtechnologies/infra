#!/usr/bin/env bash
# ec2-bootstrap.sh — prepare a fresh Ubuntu 24.04 EC2 instance for Prabhix.
# Run as root: curl -fsSL ... | bash   OR   sudo bash deploy/ec2-bootstrap.sh
set -euo pipefail

MAIL_PORTS="${ENABLE_MAIL_PORTS:-false}"

echo "==> Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "==> Installing Docker Engine + Compose plugin"
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Creating prabhix system user"
if ! id prabhix &>/dev/null; then
  useradd -m -s /bin/bash -G docker prabhix
fi

echo "===> Configuring swap (2G) for small instances"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> Enabling unattended security upgrades"
apt-get install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades || true

echo "==> Configuring UFW"
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
if [ "$MAIL_PORTS" = "true" ]; then
  ufw allow 25/tcp comment 'SMTP inbound'
  ufw allow 587/tcp comment 'SMTP submission'
  ufw allow 993/tcp comment 'IMAPS'
fi
ufw --force enable

echo "==> Installing fail2ban"
apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

echo "==> Docker log rotation"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}
EOF
systemctl restart docker

echo "==> Application directory"
mkdir -p /opt/prabhix
chown prabhix:prabhix /opt/prabhix

echo ""
echo "Bootstrap complete. Next steps:"
echo "  1. Clone the repo to /opt/prabhix as user prabhix"
echo "  2. Copy deploy/.env.prod.example to deploy/.env.prod and fill secrets"
echo "  3. Run deploy/deploy.sh"
echo ""
echo "For self-hosted mail, re-run with ENABLE_MAIL_PORTS=true before enabling UFW mail rules."
