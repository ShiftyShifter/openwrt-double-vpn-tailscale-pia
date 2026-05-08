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

## 2. Initial Installation

Once the files are on the router, log in via SSH and run the bootstrap script. This will install all necessary packages (curl, jq, wireguard, tailscale) and apply the initial network configuration.

```bash
ssh root@192.168.1.1
cd /opt/scripts
sh bootstrap_router.sh
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

### `bootstrap_router.sh`
The "Master" installer. It installs dependencies from `requirements.txt`, sets correct file permissions, and triggers the initial network/routing setup.

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

---

## 5. Security Note
Your PIA credentials are stored in `/etc/config/pia_wg`. This file is ignored by the `.gitignore` in this repository to ensure you don't accidentally push your private keys or passwords to a public server.
