#!/usr/bin/env bash
# ec2-bootstrap.sh — prepare a fresh EC2 instance for Prabhix.
#
# Supports Ubuntu/Debian (apt) and Amazon Linux 2023 (dnf). Run as root:
#   sudo bash deploy/ec2-bootstrap.sh
#
# Idempotent: safe to re-run after a partial failure.
set -euo pipefail

MAIL_PORTS="${ENABLE_MAIL_PORTS:-false}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.32.4}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root: sudo bash deploy/ec2-bootstrap.sh" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
echo "==> Detected ${PRETTY_NAME:-$OS_ID}"

case "$OS_ID" in
  ubuntu | debian) PKG=apt ;;
  amzn) PKG=dnf ;;
  *)
    echo "Unsupported distribution '$OS_ID'. Supported: ubuntu, debian, amzn." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Packages and Docker
# ---------------------------------------------------------------------------
if [ "$PKG" = apt ]; then
  echo "==> Updating system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y

  echo "==> Installing Docker Engine + Compose plugin"
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
    ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "==> Updating system packages"
  dnf update -y

  # Amazon Linux 2023 ships Docker in its own repo. It does NOT package the Compose v2
  # plugin, so that is installed as a CLI plugin binary below.
  echo "==> Installing Docker Engine"
  dnf install -y docker

  echo "==> Installing Docker Compose plugin ${COMPOSE_VERSION}"
  install -m 0755 -d /usr/libexec/docker/cli-plugins
  if ! docker compose version >/dev/null 2>&1; then
    arch="$(uname -m)"
    case "$arch" in
      x86_64) compose_arch=x86_64 ;;
      aarch64 | arm64) compose_arch=aarch64 ;;
      *) echo "Unsupported architecture $arch" >&2; exit 1 ;;
    esac
    curl -fsSL \
      "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${compose_arch}" \
      -o /usr/libexec/docker/cli-plugins/docker-compose
    chmod 0755 /usr/libexec/docker/cli-plugins/docker-compose
  fi
fi

systemctl enable --now docker

# ---------------------------------------------------------------------------
# Application user
# ---------------------------------------------------------------------------
echo "==> Creating prabhix system user"
if ! id prabhix &>/dev/null; then
  useradd -m -s /bin/bash prabhix
fi
# The docker group exists only after Docker installs.
usermod -aG docker prabhix

# The GitHub Actions deploy workflow connects as `prabhix`, but the instance key only
# authorizes the AMI's default user. Copy those keys across, or that deploy fails with
# "Permission denied (publickey)" and the cause is not obvious from the workflow log.
echo "==> Authorizing existing SSH keys for prabhix"
for default_user in ec2-user ubuntu admin; do
  src="/home/${default_user}/.ssh/authorized_keys"
  if [ -f "$src" ]; then
    install -d -m 0700 -o prabhix -g prabhix /home/prabhix/.ssh
    # Append rather than overwrite, de-duplicated, so re-runs do not pile up entries.
    touch /home/prabhix/.ssh/authorized_keys
    cat "$src" /home/prabhix/.ssh/authorized_keys | sort -u > /home/prabhix/.ssh/authorized_keys.new
    mv /home/prabhix/.ssh/authorized_keys.new /home/prabhix/.ssh/authorized_keys
    chown prabhix:prabhix /home/prabhix/.ssh/authorized_keys
    chmod 0600 /home/prabhix/.ssh/authorized_keys
    echo "    copied from ${default_user}"
    break
  fi
done

# ---------------------------------------------------------------------------
# Swap — mandatory on 1–2 GB instances or the JVM gets OOM-killed mid-deploy
# ---------------------------------------------------------------------------
echo "==> Configuring swap (${SWAP_SIZE})"
if [ ! -f /swapfile ]; then
  fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
# Prefer RAM but allow spillover instead of the OOM killer.
sysctl -w vm.swappiness=10 >/dev/null
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

# ---------------------------------------------------------------------------
# Unattended security updates
# ---------------------------------------------------------------------------
echo "==> Enabling automatic security updates"
if [ "$PKG" = apt ]; then
  apt-get install -y unattended-upgrades
  dpkg-reconfigure -plow unattended-upgrades || true
else
  dnf install -y dnf-automatic
  sed -i 's/^upgrade_type.*/upgrade_type = security/' /etc/dnf/automatic.conf || true
  sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf || true
  systemctl enable --now dnf-automatic.timer
fi

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
if [ "$PKG" = apt ]; then
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
else
  # Amazon Linux 2023 has no ufw and starts with no host firewall. It cannot simply be ignored,
  # though: the fail2ban package below depends on fail2ban-firewalld, which installs firewalld
  # and leaves it *enabled*. It is inactive until the next boot, so a host that works today
  # silently stops answering :80/:443 after the first reboot. Configure it explicitly instead.
  echo "==> Configuring firewalld"
  dnf install -y firewalld >/dev/null
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=ssh >/dev/null
  firewall-cmd --permanent --add-service=http >/dev/null
  firewall-cmd --permanent --add-service=https >/dev/null
  if [ "$MAIL_PORTS" = "true" ]; then
    firewall-cmd --permanent --add-port=25/tcp >/dev/null
    firewall-cmd --permanent --add-port=587/tcp >/dev/null
    firewall-cmd --permanent --add-port=993/tcp >/dev/null
  fi
  firewall-cmd --reload >/dev/null
  echo "    open: $(firewall-cmd --list-services)"
  echo "    NOTE: the EC2 security group must allow the same ports; it is the outer gate."
fi

# ---------------------------------------------------------------------------
# fail2ban — best effort; not in the Amazon Linux 2023 default repos
# ---------------------------------------------------------------------------
echo "==> Installing fail2ban"
if [ "$PKG" = apt ]; then
  apt-get install -y fail2ban
  systemctl enable --now fail2ban
else
  if dnf install -y fail2ban 2>/dev/null; then
    systemctl enable --now fail2ban
  else
    echo "    fail2ban unavailable on this release — skipped (SSH is key-only, so this is"
    echo "    a hardening nicety rather than a requirement)"
  fi
fi

# ---------------------------------------------------------------------------
# Docker log rotation
# ---------------------------------------------------------------------------
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

TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
echo ""
echo "Bootstrap complete on ${PRETTY_NAME:-$OS_ID}."
if [ "$TOTAL_MB" -lt 1800 ]; then
  echo ""
  echo "  WARNING: ${TOTAL_MB} MB RAM detected. The full stack (Postgres, PgBouncer, Redis,"
  echo "  Spring Boot, Next.js, nginx, Caddy) needs roughly 1.5-2 GB. Swap is configured so it"
  echo "  will start, but the JVM will thrash. t3.small is the practical minimum; t3.medium is"
  echo "  comfortable."
fi
echo ""
echo "Next steps:"
echo "  1. Clone the repo to /opt/prabhix as user prabhix"
echo "  2. cp deploy/.env.prod.example deploy/.env.prod and fill in secrets"
echo "  3. bash deploy/deploy.sh"
echo ""
echo "For self-hosted mail, re-run with ENABLE_MAIL_PORTS=true."
