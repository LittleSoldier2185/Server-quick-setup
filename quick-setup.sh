#!/usr/bin/env bash
# quick-setup.sh - base setup for a fresh Ubuntu Server (tested on 22.04 / 24.04)
# Sets: timezone, static IP (Netplan), packages, SSH, UFW firewall.
# Usage: sudo ./quick-setup.sh
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo: sudo ./quick-setup.sh"
  exit 1
fi

# ---- Detect defaults from the current network ----
DEF_IFACE=$(ip -o -4 route show default | awk '{print $5}' | head -n1 || true)
DEF_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1 || true)

# ---- Ask questions ----
read -rp "Network interface [${DEF_IFACE}]: " IN
IFACE=${IN:-$DEF_IFACE}

read -rp "Static IP with mask (e.g. 192.168.10.50/24): " IP
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  echo "Invalid IP format. Use something like 192.168.10.50/24"
  exit 1
fi

read -rp "Gateway [${DEF_GW}]: " IN
GW=${IN:-$DEF_GW}

read -rp "Timezone [Asia/Bangkok]: " IN
TIMEZONE=${IN:-Asia/Bangkok}

read -rp "DNS servers, comma separated [8.8.8.8, 1.1.1.1]: " IN
DNS=${IN:-8.8.8.8, 1.1.1.1}

if [ -z "$IFACE" ] || [ -z "$GW" ]; then
  echo "Interface and gateway are required."
  exit 1
fi

# ---- Confirm ----
echo
echo "About to apply:"
echo "  Interface : $IFACE"
echo "  IP        : $IP"
echo "  Gateway   : $GW"
echo "  DNS       : $DNS"
echo "  Timezone  : $TIMEZONE"
read -rp "Continue? (y/n): " OK
[ "$OK" = "y" ] || { echo "Cancelled."; exit 0; }

# ---- Timezone ----
echo "==> Timezone"
timedatectl set-timezone "$TIMEZONE"

# ---- Packages (done first, while network still works) ----
echo "==> Packages"
apt update
DEBIAN_FRONTEND=noninteractive apt upgrade -y
DEBIAN_FRONTEND=noninteractive apt install -y \
  openssh-server ufw qemu-guest-agent unattended-upgrades

systemctl enable --now ssh

# ---- Firewall ----
echo "==> Firewall (UFW)"
ufw allow OpenSSH
for p in 80 443 2222 5000 8080 9443; do
  ufw allow "${p}/tcp"
done
ufw --force enable

# ---- Static IP ----
echo "==> Static IP"
# Stop cloud-init from overwriting the network config on boot
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Back up the current config
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
  cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak
fi

cat > /etc/netplan/50-cloud-init.yaml <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${IP}]
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses: [${DNS}]
EOF
chmod 600 /etc/netplan/50-cloud-init.yaml

echo "==> Validating Netplan"
netplan generate

echo "==> Applying network (SSH will disconnect if the IP changes)"
echo "Reconnect with: ssh ${SUDO_USER:-youruser}@${IP%/*}"
netplan apply
