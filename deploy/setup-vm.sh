#!/usr/bin/env bash
# One-time preparation of the Ubuntu VM that hosts the travel planner.
# Run once as:  sudo bash setup-vm.sh
# Installs updates, Docker, Tailscale and the Hyper-V guest services, and
# closes the firewall except for SSH. It starts no application and opens
# nothing to the internet.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo starten: sudo bash $0" >&2
  exit 1
fi
OWNER="${SUDO_USER:-kristian}"
export DEBIAN_FRONTEND=noninteractive

echo "== Updates =="
apt-get update
apt-get -y upgrade
apt-get -y install ca-certificates curl git ufw unattended-upgrades

echo "== Hyper-V guest services (lets the host see the VM's address, clean shutdown) =="
apt-get -y install linux-cloud-tools-virtual || apt-get -y install hyperv-daemons || echo "Guest services not available, skipping."

echo "== Docker from the official repository =="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
if apt-get update && apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
  :
else
  # A brand-new Ubuntu release may not be in Docker's repository yet.
  rm -f /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get -y install docker.io docker-compose-v2 docker-buildx
fi
usermod -aG docker "$OWNER"
systemctl enable --now docker

echo "== Tailscale =="
curl -fsSL https://tailscale.com/install.sh | sh

echo "== Firewall: SSH only; Tailscale traffic is allowed on its own interface =="
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow in on tailscale0
ufw --force enable

echo "== Automatic security updates =="
systemctl enable --now unattended-upgrades

mkdir -p /srv/reisen
chown "$OWNER":"$OWNER" /srv/reisen

echo
echo "Fertig. Als Nächstes: sudo tailscale up   (zeigt einen Link zum Anmelden)"
