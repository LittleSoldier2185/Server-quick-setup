# Ubuntu / Proxmox Quick Setup

One script for base server setup and network changes (Ubuntu Server 22.04 / 24.04, Proxmox / Debian).

## Usage

```bash
git clone https://github.com/LittleSoldier2185/Server-quick-setup.git
cd Server-quick-setup
chmod +x quick-setup.sh
sudo ./quick-setup.sh
```

## Menu

```
1) Normal setup            timezone + static IP + packages + firewall   (Ubuntu, Netplan)
2) Interface via Netplan   static IP / DHCP / VLAN tag inside the VM    (Ubuntu)
3) /etc/network/interfaces show / backup / restore / static IP / VLAN-aware bridge  (Proxmox, Debian)
4) Show network status     interfaces, routes, ARP, gateway / internet / DNS test
5) Quit
```

Skip the menu with `--normal`, `--interface`, `--ifupdown`, `--status`. Add `--yes` to skip the final y/n.
Change firewall ports with `PORTS="80 443 8080" sudo -E ./quick-setup.sh`.

### Option 3: /etc/network/interfaces

Used by **Proxmox hosts and Debian**. Ubuntu Server uses Netplan, so this file is empty there; that is normal.

| Sub-option | What it does |
|---|---|
| Show | prints the file and lists backups |
| Backup | saves `/etc/network/interfaces.bak.<date-time>` |
| Restore | pick a backup; the current file is backed up first |
| Static IP | replaces the file with a plain NIC + static IP |
| VLAN-aware bridge | replaces the file with `vmbr0` + `bridge-vlan-aware yes` + `bridge-vids` |
| VLAN-aware on/off | edits only the chosen bridge stanza in place; everything else is kept |

**Be careful on a Proxmox host.** A bad bridge config cuts the host and all VMs off the network.
The script backs up first and restores automatically if the gateway stops answering, but run it
from the physical console, not over SSH, and prefer the in-place on/off option over replacing the file.

## Safety checks

- Gateway must be inside the network of the IP (e.g. `192.168.20.50/24` with `192.168.10.1` is refused).
- If the current gateway is on another network/VLAN, it suggests `x.y.z.1` for the new one.
- Every network change is backed up, applied, tested (ping gateway / DHCP address) and rolled back on failure.
- If the VM has no internet yet, packages are installed *after* the network is applied.
- Keeps running if the SSH session drops; logs to `/var/log/quick-setup.log`.

## VLANs (Proxmox)

The VLAN is normally set on the Proxmox side, not inside the VM:

1. VM -> Hardware -> Network Device (net0) -> **VLAN Tag** = your VLAN (e.g. `20`).
2. The switch port to Proxmox must be a **trunk** allowing that VLAN.
3. The router must have that VLAN and route it (gateway e.g. `192.168.20.1`).

Use Netplan option 2 -> "VLAN tag inside this VM" only if Proxmox does **not** tag the NIC, otherwise the tag is applied twice.

## Notes

- Old Netplan file: `/etc/netplan/50-cloud-init.yaml.bak.<timestamp>`.
- On Proxmox, enable **Options -> QEMU Guest Agent** and fully stop/start the VM for the agent to work.
- Take a snapshot before running it on an important VM.

## Windows line endings

If you edit on Windows and get `bad interpreter` errors:

```bash
sed -i 's/\r$//' quick-setup.sh
```
