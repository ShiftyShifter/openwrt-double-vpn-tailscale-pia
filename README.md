# OpenWrt Native Double-VPN (Tailscale + PIA)

This project provides a robust, native OpenWrt routing architecture that turns your router into a **Tailscale Exit Node** while forcing all traffic through a **Private Internet Access (PIA) VPN** tunnel.

## Key Features
- **Double VPN Protection**: Mobile devices connected via Tailscale exit through your home router and out via PIA VPN.
- **VPN Bypass for Stability**: Tailscale's control traffic automatically bypasses the VPN to maintain a stable connection.
- **Subnet Exposure**: Access your private LAN devices remotely via the Tailscale network.
- **Self-Healing**: Built-in watchdog ensures the VPN connection stays alive.
- **Pure Native Routing**: Uses built-in Linux IP rules and UCI, avoiding heavy/unstable PBR packages.

---

## 1. Getting Started: Transferring the Scripts

If you have just flashed OpenWrt, you need to get these scripts onto the router. The recommended location is `/opt/scripts/`.

### From your computer (Linux/Mac/WSL):
Open a terminal in this project folder and run:

```bash
# 1. Create the directory on the router
ssh root@192.168.1.1 "mkdir -p /opt/scripts"

# 2. Copy the scripts and the package list
scp opt/scripts/* root@192.168.1.1:/opt/scripts/
```

---

## 2. Initial Installation (Double-VPN Setup)

Once the files are on the router, log in via SSH and run the Double-VPN setup script. This will install all necessary packages (curl, jq, wireguard, tailscale) and apply the initial network configuration.

```bash
ssh root@192.168.1.1
cd /opt/scripts
sh setup_double_vpn.sh
```

**Note:** During this process, the router's LAN IP will change to `192.168.2.1`. You will need to reconnect your computer to the new IP once the script finishes.


---

## 3. Configuration & Activation

### Step A: Configure PIA VPN
Set up your credentials and choose your preferred server region.
```bash
sh /opt/scripts/pia_vpn_manager.sh configure
sh /opt/scripts/pia_vpn_manager.sh start
```

### Step B: Tailscale Approval (CRITICAL)
The setup script automatically initiates Tailscale, but you **must** manually approve it in the web console:
1.  Log in to the [Tailscale Admin Console](https://login.tailscale.com/admin/machines).
2.  Find your OpenWrt machine.
3.  Click the **"..."** menu and select **"Edit route settings"**.
4.  Enable **"Use as exit node"** and **Approve** the advertised `192.168.2.0/24` subnet.

---

## 4. Script Documentation

### `setup_double_vpn.sh`
The "Double-VPN Master" installer. It installs dependencies from `requirements.txt`, sets correct file permissions, and triggers the initial double-vpn network/routing setup via `setup_native_double_vpn.sh`.

### `setup_single_vpn.sh`
The "Single-VPN Master" installer. It installs dependencies from `requirements.txt`, sets correct file permissions, and triggers the clean tailscale-only network setup, completely bypassing PIA VPN.

### `pia_vpn_manager.sh`
Handles the lifecycle of the PIA WireGuard tunnel.
- `configure`: Interactive setup for user/password and region.
- `start`: Connects the VPN and installs a **Watchdog** (checks connection every 1 minute).
- `stop`: Disconnects and removes the watchdog.
- `status`: Shows a detailed report including external IP, data usage, and handshake time.

### `setup_native_double_vpn.sh`
The "Engine" of the project. It configures:
- **Routing Tables**: Creates `wan_direct` for Tailscale underlay traffic.
- **Firewall Zones**: Sets up `tailscale`, `lan`, `wan`, and `pia_exit`.
- **IP Rules**: Ensures specific traffic (like Tailscale management) bypasses the VPN.
- **Bridge Config**: Manages `br-extender` (WAN side) and `br-lan` (Private side).

### `revert_single_vpn.sh`
The "Reverter". Safely removes the Double-VPN routing logic, PIA network interface, and active watchdogs while keeping Tailscale running and preserving your physical/hardware bridge configurations.

---

## 5. Reverting to Single-VPN (Tailscale Only)

If you find that the Double-VPN setup is too complex or causing routing issues, you can easily revert the active router configuration to a simpler state. This keeps Tailscale functioning as an exit node and remote bridge to your LAN, but routes all traffic directly through your physical ISP/WAN rather than PIA.

### Option A: Reverting an existing Double-VPN Router
If you are running the reversion on a router that has already been bootstrapped, your LAN IP is already `192.168.2.1`. Run:
```bash
# SSH into your router's configured LAN IP
ssh root@192.168.2.1

# Run the revert script
cd /opt/scripts
sh revert_single_vpn.sh
```

This script will safely clean up the firewall rules, routing tables, and interface definitions without disrupting your local subnet IP (`192.168.2.1`) or custom hardware bridge ports.

### Option B: Setting up Single-VPN directly after a Factory Reset
If you perform a factory reset in the future, the router will reset to the default OpenWrt IP `192.168.1.1`. To set up the **Single-VPN (Tailscale-only)** architecture directly from scratch without ever installing or configuring the PIA VPN elements:
```bash
# 1. SSH into the factory default IP
ssh root@192.168.1.1

# 2. Go to scripts directory and run the direct single-vpn script
cd /opt/scripts
sh setup_single_vpn.sh
```
This will automatically install all dependencies, configure your bridges, IP address `192.168.2.1`, and set up your Tailscale exit node routing directly in one command!

---

## 6. Security Note
Your PIA credentials are stored in `/etc/config/pia_wg`. This file is ignored by the `.gitignore` in this repository to ensure you don't accidentally push your private keys or passwords to a public server.

