#!/usr/bin/env bash
# quick-setup.sh v3 - base setup / network tool for Ubuntu Server and Proxmox/Debian
#
# Menu:
#   1) Normal setup           : timezone + static IP + packages + firewall (Ubuntu, Netplan)
#   2) Interface via Netplan  : static IP / DHCP / VLAN tag inside the VM (Ubuntu)
#   3) /etc/network/interfaces: show, backup, restore, static IP, VLAN-aware bridge (Proxmox/Debian)
#   4) Show network status
#
# Every network change is backed up, checked, and rolled back automatically if it does not work.
#
# Usage:
#   sudo ./quick-setup.sh               show the menu
#   sudo ./quick-setup.sh --normal      skip the menu, normal setup
#   sudo ./quick-setup.sh --interface   skip the menu, Netplan interface tool (alias: --network-only)
#   sudo ./quick-setup.sh --ifupdown    skip the menu, /etc/network/interfaces tool
#   sudo ./quick-setup.sh --status      skip the menu, show status
#   sudo ./quick-setup.sh --yes         skip the final y/n question
#
# Optional: PORTS="80 443 8080" sudo -E ./quick-setup.sh   (firewall ports)
set -uo pipefail

NETPLAN_FILE=/etc/netplan/50-cloud-init.yaml
LOG=/var/log/quick-setup.log
PORTS=${PORTS:-"80 443 2222 5000 8080 9443"}
CHOICE=""
ASSUME_YES=0
LOGGING=0

# Values filled in by the questions
IFACE="" ; NET_MODE="static" ; IP="" ; GW="" ; DNS="8.8.8.8, 1.1.1.1"
VID="" ; TIMEZONE="Asia/Bangkok"

for arg in "$@"; do
  case "$arg" in
    --normal)                    CHOICE=1 ;;
    --interface|--network-only)  CHOICE=2 ;;
    --ifupdown)                  CHOICE=3 ;;
    --status)                    CHOICE=4 ;;
    --yes|-y)                    ASSUME_YES=1 ;;
    -h|--help)                   sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo: sudo ./quick-setup.sh"
  exit 1
fi

# =====================================================================
# helpers
# =====================================================================
die() { echo "ERROR: $*" >&2; exit 1; }

has_internet() { ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; }

# same_subnet <ip/mask> <address> : 0 if address is inside the network of ip/mask, 2 if invalid
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

start_logging() {
  [ "$LOGGING" -eq 1 ] && return 0
  LOGGING=1
  # keep running even if the SSH session drops, and log everything
  trap '' HUP
  exec > >(tee --output-error=warn -a "$LOG") 2>&1
  echo "---- quick-setup started $(date) ----"
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

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ok
  read -rp "Continue? (y/n): " ok
  [ "$ok" = "y" ] || { echo "Cancelled."; exit 0; }
}

# =====================================================================
# questions
# =====================================================================
detect_defaults() {
  DEF_IFACE=$(ip -o -4 route show default | awk '{print $5}' | head -n1)
  if [ -z "$DEF_IFACE" ]; then
    DEF_IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' | cut -d@ -f1)
  fi
  DEF_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
}

ask_iface() {
  echo "Network interfaces on this machine:"
  ip -br a
  echo
  local in
  read -rp "Network interface [${DEF_IFACE}]: " in
  IFACE=${in:-$DEF_IFACE}
  [ -n "$IFACE" ] || die "Interface is required."
  ip link show "$IFACE" >/dev/null 2>&1 || die "Interface $IFACE does not exist (check: ip -br a)."
}

ask_static() {   # ask_static [nodns]
  local in rc suggest
  read -rp "Static IP with mask (e.g. 192.168.10.50/24): " IP
  [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
    || die "Invalid IP format. Use something like 192.168.10.50/24"
  same_subnet "$IP" "${IP%/*}"; rc=$?
  [ "$rc" -eq 2 ] && die "Invalid IP address: $IP"

  # Suggest a gateway: the detected one if it is in the same subnet, otherwise x.y.z.1
  suggest=$(echo "${IP%/*}" | awk -F. '{print $1"."$2"."$3".1"}')
  if [ -n "${DEF_GW:-}" ] && same_subnet "$IP" "$DEF_GW"; then
    suggest=$DEF_GW
  elif [ -n "${DEF_GW:-}" ]; then
    echo "Note: the current gateway ($DEF_GW) is not in the same subnet as $IP."
  fi
  read -rp "Gateway [${suggest}]: " in
  GW=${in:-$suggest}
  same_subnet "$IP" "$GW" \
    || die "Gateway $GW is not inside the network of $IP. Check the IP, mask, and gateway (VLAN?)."

  [ "${1:-}" = "nodns" ] && return 0
  read -rp "DNS servers, comma separated [8.8.8.8, 1.1.1.1]: " in
  DNS=${in:-8.8.8.8, 1.1.1.1}
}

ask_vlan_id() {
  echo "Use this only if Proxmox does NOT already tag this NIC (otherwise the tag is applied twice)."
  read -rp "VLAN ID (1-4094): " VID
  [[ "$VID" =~ ^[0-9]+$ ]] && [ "$VID" -ge 1 ] && [ "$VID" -le 4094 ] || die "Invalid VLAN ID."
}

ask_timezone() {
  local in
  read -rp "Timezone [Asia/Bangkok]: " in
  TIMEZONE=${in:-Asia/Bangkok}
}

# =====================================================================
# netplan
# =====================================================================
render_netplan() {
  case "$NET_MODE" in
static)
cat <<EOF
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
;;
dhcp)
cat <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: true
EOF
;;
vlan)
cat <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
  vlans:
    ${IFACE}.${VID}:
      id: ${VID}
      link: ${IFACE}
      addresses: [${IP}]
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses: [${DNS}]
EOF
;;
  esac
}

print_diagnostics() {
  if [ "$NET_MODE" = "dhcp" ]; then
    cat <<EOF

The interface $IFACE did not get an IPv4 address from DHCP, so the old settings were restored.
Check: Proxmox net0 (bridge / VLAN tag / Disconnect), the switch port, and the DHCP server.
Log: $LOG
EOF
  else
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
  fi
}

apply_netplan() {
  echo "==> Applying network config (mode: $NET_MODE)"
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

  render_netplan > "$NETPLAN_FILE"
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

  echo "Applying (an SSH session will disconnect if the IP changes;"
  echo "the script keeps running and logs to $LOG)"
  netplan apply

  if [ "$NET_MODE" = "dhcp" ]; then
    local i
    for i in $(seq 1 30); do
      if ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q inet; then
        echo "DHCP address received:"
        ip -4 -br a show dev "$IFACE"
        return 0
      fi
      sleep 1
    done
    echo "No DHCP address received. Rolling back..."
    rollback
    print_diagnostics
    return 1
  fi

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

# =====================================================================
# menu actions
# =====================================================================
show_status() {
  echo "== Interfaces ==";        ip -br a
  echo; echo "== Routes ==";       ip route
  echo; echo "== Neighbors (ARP) =="; ip neigh show
  echo; echo "== Netplan files =="; ls -l /etc/netplan/ 2>/dev/null
  local gw
  gw=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
  echo; echo "== Connectivity =="
  if [ -z "$gw" ]; then
    echo "No default route: this machine does not know where to send non-local traffic."
  else
    if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then echo "Gateway $gw: reachable"; else echo "Gateway $gw: NOT reachable"; fi
    if has_internet; then echo "Internet (1.1.1.1): reachable"; else echo "Internet (1.1.1.1): NOT reachable"; fi
    if getent hosts google.com >/dev/null 2>&1; then echo "DNS (google.com): works"; else echo "DNS (google.com): FAILED"; fi
  fi
  if command -v ufw >/dev/null 2>&1; then echo; echo "== Firewall =="; ufw status | head -n 20; fi
}

run_normal() {
  detect_defaults
  ask_iface
  NET_MODE=static
  ask_static
  ask_timezone

  echo
  echo "About to apply (normal setup):"
  echo "  Interface : $IFACE"
  echo "  IP        : $IP"
  echo "  Gateway   : $GW"
  echo "  DNS       : $DNS"
  echo "  Timezone  : $TIMEZONE"
  confirm
  start_logging

  echo "==> Timezone"
  timedatectl set-timezone "$TIMEZONE"

  local pkgs_done=0
  if has_internet; then
    install_packages && pkgs_done=1
    setup_firewall
  else
    echo "No internet right now; packages will be installed after the network is applied."
  fi

  apply_netplan || exit 1

  if [ "$pkgs_done" -eq 0 ]; then
    if has_internet; then
      install_packages
      setup_firewall
    else
      echo "WARNING: the gateway works but there is no internet (check router NAT / VLAN routing)."
      echo "Run again later:  sudo ./quick-setup.sh --normal"
    fi
  fi

  echo
  echo "Done. Reconnect with: ssh ${SUDO_USER:-youruser}@${IP%/*}"
  echo "Check: ip -br a ; ip route ; sudo ufw status"
}

run_interface() {
  detect_defaults
  echo "Interface settings:"
  echo "  1) Static IP"
  echo "  2) DHCP (automatic IP)"
  echo "  3) Static IP on a VLAN tag inside this VM (advanced)"
  echo "  4) Back / quit"
  local sub
  read -rp "Choose [1]: " sub
  sub=${sub:-1}
  case "$sub" in
    1) NET_MODE=static ;;
    2) NET_MODE=dhcp ;;
    3) NET_MODE=vlan ;;
    *) echo "Bye."; exit 0 ;;
  esac

  ask_iface
  [ "$NET_MODE" = "vlan" ] && ask_vlan_id
  [ "$NET_MODE" != "dhcp" ] && ask_static

  echo
  echo "About to apply (interface only):"
  echo "  Mode      : $NET_MODE"
  echo "  Interface : $IFACE${VID:+.$VID (VLAN $VID)}"
  if [ "$NET_MODE" != "dhcp" ]; then
    echo "  IP        : $IP"
    echo "  Gateway   : $GW"
    echo "  DNS       : $DNS"
  fi
  confirm
  start_logging

  apply_netplan || exit 1

  echo
  if [ "$NET_MODE" = "dhcp" ]; then
    echo "Done. Find the new IP with: ip -br a"
  else
    echo "Done. Reconnect with: ssh ${SUDO_USER:-youruser}@${IP%/*}"
  fi
  echo "Check: ip -br a ; ip route"
}

# =====================================================================
# /etc/network/interfaces  (Proxmox host / Debian, ifupdown)
# =====================================================================
IF_FILE=${IF_FILE:-/etc/network/interfaces}
IF_BACKUP=""
CHECK_GW=""

if_backup() {
  [ -f "$IF_FILE" ] || { IF_BACKUP=""; return 0; }
  IF_BACKUP="${IF_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$IF_FILE" "$IF_BACKUP"
  echo "Backup saved: $IF_BACKUP"
}

if_reload() {
  if command -v ifreload >/dev/null 2>&1; then
    ifreload -a
  else
    systemctl restart networking
  fi
}

if_rollback() {
  if [ -n "$IF_BACKUP" ] && [ -f "$IF_BACKUP" ]; then
    cp -a "$IF_BACKUP" "$IF_FILE"
    if_reload || true
    echo "Restored $IF_FILE from $IF_BACKUP"
  else
    echo "No backup to restore."
  fi
}

# if_commit : reload the network, then check the gateway; roll back if it fails
if_commit() {
  echo "Applying (an SSH session will disconnect if the IP changes;"
  echo "the script keeps running and logs to $LOG)"
  if ! if_reload; then
    echo "Reload failed. Rolling back..."
    if_rollback
    return 1
  fi
  sleep 5
  if [ -z "$CHECK_GW" ]; then
    echo "No gateway to test (no default route before the change). Please check manually: ip -br a ; ip route"
    return 0
  fi
  if ping -c 3 -W 2 "$CHECK_GW" >/dev/null 2>&1; then
    echo "Gateway $CHECK_GW reachable. Network OK."
    return 0
  fi
  echo "Gateway $CHECK_GW is NOT reachable. Rolling back..."
  if_rollback
  return 1
}

if_warn() {
  cat <<EOF

WARNING: this changes the live network of THIS machine.
 - Best done from the console (Proxmox: physical screen / IPMI), not over SSH.
 - The current file is backed up first and restored automatically if the gateway stops answering.
EOF
}

if_show() {
  echo "==== $IF_FILE ===="
  if [ -s "$IF_FILE" ]; then
    cat "$IF_FILE"
  else
    echo "(missing or empty)"
    command -v netplan >/dev/null 2>&1 && echo "This machine uses Netplan (Ubuntu). Use menu option 2 instead; /etc/network/interfaces is not used."
  fi
  echo "==== backups ===="
  ls -1t "${IF_FILE}".bak.* 2>/dev/null || echo "(none)"
}

if_restore() {
  local baks=() i=1 n
  mapfile -t baks < <(ls -1t "${IF_FILE}".bak.* 2>/dev/null)
  [ "${#baks[@]}" -gt 0 ] || { echo "No backups found."; return 0; }
  for b in "${baks[@]}"; do echo "  $i) $b"; i=$((i+1)); done
  read -rp "Restore which backup number? " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#baks[@]}" ] || die "Invalid number."
  CHECK_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
  if_warn
  echo "Will restore: ${baks[$((n-1))]}"
  confirm
  start_logging
  if_backup                                   # keep the current file too
  local cur_backup=$IF_BACKUP
  cp -a "${baks[$((n-1))]}" "$IF_FILE"
  IF_BACKUP=$cur_backup
  if_commit || exit 1
  echo "Restored."
}

ask_nic() {
  echo "Physical network cards:"
  local n nics=""
  for n in /sys/class/net/*; do
    [ -e "$n/device" ] && nics="$nics $(basename "$n")"
  done
  echo " ${nics:- (none found)}"
  ip -br a
  echo
  local def=${nics# }; def=${def%% *}
  local in
  read -rp "Physical NIC [${def}]: " in
  IFACE=${in:-$def}
  [ -n "$IFACE" ] || die "NIC is required."
  ip link show "$IFACE" >/dev/null 2>&1 || die "Interface $IFACE does not exist."
}

if_static() {
  detect_defaults
  ask_iface
  ask_static nodns
  CHECK_GW=$GW
  echo
  echo "About to REPLACE $IF_FILE with:"
  echo "  auto $IFACE / static $IP via $GW"
  if_warn
  confirm
  start_logging
  if_backup
  cat > "$IF_FILE" <<EOF
auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet static
        address ${IP}
        gateway ${GW}
EOF
  if_commit || { print_if_diag; exit 1; }
  echo "Done. Reconnect with: ssh ${SUDO_USER:-youruser}@${IP%/*}"
}

if_bridge() {
  detect_defaults
  ask_nic
  local br vids in
  read -rp "Bridge name [vmbr0]: " br; br=${br:-vmbr0}
  ask_static nodns
  read -rp "Allowed VLAN IDs [2-4094]: " vids; vids=${vids:-2-4094}
  CHECK_GW=$GW
  echo
  echo "About to REPLACE $IF_FILE with a VLAN-aware bridge:"
  echo "  NIC $IFACE -> $br, address $IP, gateway $GW, VLANs $vids"
  echo "  (any other bridges/interfaces in the current file are NOT kept; they stay in the backup)"
  if_warn
  confirm
  start_logging
  if_backup
  cat > "$IF_FILE" <<EOF
auto lo
iface lo inet loopback

iface ${IFACE} inet manual

auto ${br}
iface ${br} inet static
        address ${IP}
        gateway ${GW}
        bridge-ports ${IFACE}
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids ${vids}
EOF
  if_commit || { print_if_diag; exit 1; }
  echo "Done. In Proxmox, VM net0 -> VLAN Tag = your VLAN ID."
}

# bridge_set_vlan_aware <file> <bridge> <yes|no>  (edits the stanza in place)
bridge_set_vlan_aware() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required for this option."
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, br, val = sys.argv[1:4]
lines = open(path).read().split('\n')
start = next((i for i, l in enumerate(lines)
              if re.match(r'^iface\s+' + re.escape(br) + r'\s+inet', l)), None)
if start is None:
    sys.exit(3)
end = start + 1
while end < len(lines) and lines[end].startswith((' ', '\t')):
    end += 1
body = [l for l in lines[start + 1:end]
        if not re.match(r'\s*(bridge-vlan-aware|bridge-vids)\b', l)]
if val == 'yes':
    body += ['        bridge-vlan-aware yes', '        bridge-vids 2-4094']
lines[start + 1:end] = body
open(path, 'w').write('\n'.join(lines))
PY
}

if_vlan_toggle() {
  [ -s "$IF_FILE" ] || die "$IF_FILE is missing or empty."
  echo "Bridges in $IF_FILE:"
  grep -E '^iface[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+inet' "$IF_FILE" | awk '{print "  " $2}'
  local br val
  read -rp "Bridge name [vmbr0]: " br; br=${br:-vmbr0}
  read -rp "VLAN-aware yes or no? [yes]: " val; val=${val:-yes}
  [ "$val" = "yes" ] || [ "$val" = "no" ] || die "Answer yes or no."
  CHECK_GW=$(ip -o -4 route show default | awk '{print $3}' | head -n1)
  echo
  echo "About to set bridge-vlan-aware=$val on $br in $IF_FILE."
  echo "Note: if VMs already use Proxmox VLAN tags, the bridge may need a reload; check VMs afterwards."
  if_warn
  confirm
  start_logging
  if_backup
  if ! bridge_set_vlan_aware "$IF_FILE" "$br" "$val"; then
    echo "Bridge $br not found in $IF_FILE. Nothing changed."
    return 1
  fi
  echo "New stanza:"
  awk -v b="$br" '$0 ~ "^iface[ \t]+"b"[ \t]+inet"{p=1; print; next} p&&/^[ \t]/{print; next} {p=0}' "$IF_FILE"
  if_commit || { print_if_diag; exit 1; }
  echo "Done. Check: bridge vlan show ; ip -br a"
}

print_if_diag() {
  cat <<EOF

The network change did not work and $IF_FILE was restored.
Check the NIC name (ip -br a), the gateway address, and the switch port / VLAN.
Log: $LOG
EOF
}

run_ifupdown() {
  echo "/etc/network/interfaces (Proxmox / Debian style):"
  echo "  1) Show current file and backups"
  echo "  2) Backup now"
  echo "  3) Restore a backup"
  echo "  4) Static IP on a plain NIC     (replaces the file)"
  echo "  5) VLAN-aware bridge, e.g. vmbr0 (replaces the file)"
  echo "  6) VLAN-aware ON/OFF on an existing bridge (edits in place)"
  echo "  7) Back / quit"
  local sub
  read -rp "Choose [1]: " sub
  sub=${sub:-1}
  case "$sub" in
    1) if_show ;;
    2) if_backup ;;
    3) if_restore ;;
    4) if_static ;;
    5) if_bridge ;;
    6) if_vlan_toggle ;;
    *) echo "Bye."; exit 0 ;;
  esac
}

# =====================================================================
# main
# =====================================================================
if [ -z "$CHOICE" ]; then
  echo "What do you want to do?"
  echo "  1) Normal setup            (timezone + static IP + packages + firewall; Ubuntu)"
  echo "  2) Interface via Netplan   (static IP / DHCP / VLAN tag in the VM; Ubuntu)"
  echo "  3) /etc/network/interfaces (show / backup / restore / static IP / VLAN-aware bridge; Proxmox, Debian)"
  echo "  4) Show network status"
  echo "  5) Quit"
  read -rp "Choose [1]: " CHOICE
  CHOICE=${CHOICE:-1}
fi

case "$CHOICE" in
  1) run_normal ;;
  2) run_interface ;;
  3) run_ifupdown ;;
  4) show_status ;;
  *) echo "Bye."; exit 0 ;;
esac
