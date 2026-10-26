#!/usr/bin/env bash
# quick-setup.sh v2 - base setup for a fresh Ubuntu Server (tested target: 22.04 / 24.04)
#
# Sets: timezone, static IP (Netplan), packages, SSH, UFW firewall.
# Safe network change: checks the gateway is in the same subnet as the IP,
# and rolls back automatically if the gateway is unreachable after applying.
#
# Usage:
#   sudo ./quick-setup.sh                 full setup
#   sudo ./quick-setup.sh --network-only  only timezone + static IP (no packages / firewall)
#   sudo ./quick-setup.sh --yes           skip the final y/n question
#
# Optional: PORTS="80 443 8080" sudo -E ./quick-setup.sh   (firewall ports)
set -uo pipefail

NETPLAN_FILE=/etc/netplan/50-cloud-init.yaml
LOG=/var/log/quick-setup.log
PORTS=${PORTS:-"80 443 2222 5000 8080 9443"}
NETWORK_ONLY=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --network-only) NETWORK_ONLY=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    -h|--help)      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo: sudo ./quick-setup.sh"
  exit 1
fi

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }

has_internet() { ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; }

# same_subnet <ip/mask> <address> : 0 if address is inside the network of ip/mask
same_subnet() {
  command -v python3 >/dev/null 2>&1 || return 0   # cannot check, assume ok
  python3 - "$1" "$2" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_interface(sys.argv[1]).network
    sys.exit(0 if ipaddress.ip_address(sys.argv[2]) in net else 1)
except ValueError:
    sys.exit(2)
PY
}

install_packages() {
  echo "==> Packages"
  apt-get update || { echo "apt update failed (no internet?)"; return 1; }
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server ufw qemu-guest-agent unattended-upgrades
  systemctl enable --now ssh || true
}

setup_firewall() {
  command -v ufw >/dev/null 2>&1 || { echo "ufw not installed, skipping firewall"; return 0; }
  echo "==> Firewall (UFW)"
  ufw allow OpenSSH
  for p in $PORTS; do ufw allow "${p}/tcp"; done
  ufw --force enable
}

print_diagnostics() {
  cat <<EOF

The gateway $GW did not answer, so the old network settings were restored.
Check, in this order:
  1. Gateway address: is $GW really the gateway for this network/VLAN?
  2. Proxmox VM -> Hardware -> Network Device (net0): is the VLAN Tag correct
     (e.g. 20 for VLAN 20)? No tag = traffic goes out on the untagged VLAN.
  3. Switch port to Proxmox: must be a trunk that allows this VLAN.
  4. Router / firewall: the VLAN must exist and be routed.
Tip: from another machine, try  ping $GW  to see if the gateway is alive.
Log: $LOG
EOF
}

apply_network() {
  echo "==> Static IP"
  mkdir -p /etc/netplan
  local backup=""
  if [ -f "$NETPLAN_FILE" ]; then
    backup="${NETPLAN_FILE}.bak.$(date +%s)"
    cp -a "$NETPLAN_FILE" "$backup"
    echo "Backup: $backup"
  fi

  # Other netplan files can conflict with ours
  local other
  other=$(find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name "$(basename "$NETPLAN_FILE")" 2>/dev/null)
  if [ -n "$other" ]; then
    echo "WARNING: other Netplan files exist and may conflict:"
    echo "$other"
  fi

  # Stop cloud-init from overwriting the network config on reboot
  if [ -d /etc/cloud/cloud.cfg.d ]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  fi

  cat > "$NETPLAN_FILE" <<EOF
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
  chmod 600 "$NETPLAN_FILE"

  rollback() {
    if [ -n "$backup" ]; then cp -a "$backup" "$NETPLAN_FILE"; else rm -f "$NETPLAN_FILE"; fi
    netplan apply || true
  }

  if ! netplan generate; then
    echo "Netplan file is invalid."
    rollback
    return 1
  fi

  echo "Applying network (an SSH session will disconnect if the IP changes;"
  echo "the script keeps running and logs to $LOG)"
  netplan apply
  sleep 5

  if ping -c 3 -W 2 "$GW" >/dev/null 2>&1; then
    echo "Gateway $GW reachable. Network OK."
    return 0
  fi

  echo "Gateway $GW is NOT reachable. Rolling back..."
  rollback
  print_diagnostics
  return 1
}

# ---------- detect defaults ----------
DEF_IFACE=$(ip -o -4 route show default | awk '{print $5}' | head -n1)
if [ -z "$DEF_IFACE" ]; then
  DEF_IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' | cut -d@ -f1)
fi
DEF_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1)

# ---------- questions ----------
read -rp "Network interface [${DEF_IFACE}]: " IN
IFACE=${IN:-$DEF_IFACE}

read -rp "Static IP with mask (e.g. 192.168.10.50/24): " IP
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  die "Invalid IP format. Use something like 192.168.10.50/24"
fi
same_subnet "$IP" "${IP%/*}"
[ $? -eq 2 ] && die "Invalid IP address: $IP"

# Suggest a gateway: the detected one if it is in the same subnet, otherwise x.y.z.1
SUGGEST_GW=$(echo "${IP%/*}" | awk -F. '{print $1"."$2"."$3".1"}')
if [ -n "$DEF_GW" ] && same_subnet "$IP" "$DEF_GW"; then
  SUGGEST_GW=$DEF_GW
elif [ -n "$DEF_GW" ]; then
  echo "Note: the current gateway ($DEF_GW) is not in the same subnet as $IP."
fi
read -rp "Gateway [${SUGGEST_GW}]: " IN
GW=${IN:-$SUGGEST_GW}

if ! same_subnet "$IP" "$GW"; then
  die "Gateway $GW is not inside the network of $IP. Check the IP, mask, and gateway (VLAN?)."
fi

read -rp "Timezone [Asia/Bangkok]: " IN
TIMEZONE=${IN:-Asia/Bangkok}

read -rp "DNS servers, comma separated [8.8.8.8, 1.1.1.1]: " IN
DNS=${IN:-8.8.8.8, 1.1.1.1}

[ -n "$IFACE" ] || die "Interface is required."
ip link show "$IFACE" >/dev/null 2>&1 || die "Interface $IFACE does not exist (check: ip -br a)."

# ---------- confirm ----------
echo
echo "About to apply:"
echo "  Interface : $IFACE"
echo "  IP        : $IP"
echo "  Gateway   : $GW"
echo "  DNS       : $DNS"
echo "  Timezone  : $TIMEZONE"
[ "$NETWORK_ONLY" -eq 1 ] && echo "  Mode      : network only (no packages / firewall)"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -rp "Continue? (y/n): " OK
  [ "$OK" = "y" ] || { echo "Cancelled."; exit 0; }
fi

# From here on: keep running even if the SSH session drops, and log everything
trap '' HUP
exec > >(tee --output-error=warn -a "$LOG") 2>&1
echo "---- quick-setup started $(date) ----"

# ---------- run ----------
echo "==> Timezone"
timedatectl set-timezone "$TIMEZONE"

PKGS_DONE=0
if [ "$NETWORK_ONLY" -eq 0 ]; then
  if has_internet; then
    install_packages && PKGS_DONE=1
    setup_firewall
  else
    echo "No internet right now; packages will be installed after the network is applied."
  fi
fi

apply_network || exit 1

if [ "$NETWORK_ONLY" -eq 0 ] && [ "$PKGS_DONE" -eq 0 ]; then
  if has_internet; then
    install_packages
    setup_firewall
  else
    echo "WARNING: the gateway works but there is no internet (check router NAT / VLAN routing)."
    echo "Run again later:  sudo ./quick-setup.sh"
  fi
fi

echo
echo "Done. Reconnect with: ssh ${SUDO_USER:-youruser}@${IP%/*}"
echo "Check: ip -br a ; ip route ; sudo ufw status"
