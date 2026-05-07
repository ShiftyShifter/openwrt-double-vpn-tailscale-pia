# OpenWrt Native Double-VPN Setup

This project provides a clean, native OpenWrt routing architecture that allows you to use your router as a **Tailscale Exit Node** while forcing all exit-node and LAN traffic through a **Private Internet Access (PIA) VPN** tunnel.

## Goals Achieved
1.  **Isolated Private LAN**: Creates a secure subnet (`192.168.2.0/24`) behind your main ISP hub, keeping hardwired devices private.
2.  **Double VPN Protection**: Traffic from your mobile device flows through Tailscale -> OpenWrt -> PIA VPN -> Internet.
3.  **VPN Bypass for Tailscale Stability**: Tailscale's own encrypted background traffic automatically bypasses the PIA VPN to maintain a stable P2P connection to other nodes.
4.  **Subnet Access**: Allows you to access your hardwired LAN devices remotely via the Tailscale network.

## Scripts

### 1. `pia_vpn_manager.sh`
Maintains the WireGuard connection to Private Internet Access. This is the refactored and documented version of the original `pia_wg.sh`.
- **Location**: `/opt/scripts/pia_vpn_manager.sh`
- **Action**: Handles authentication, region selection, and ensures the `wg_pia` interface remains healthy and connected.

### 2. `setup_native_double_vpn.sh`
Configures the complex routing and firewall rules natively within OpenWrt (no third-party PBR packages required).
- **Location**: `/opt/scripts/setup_native_double_vpn.sh`
- **Key Features**:
    - Creates a `wan_direct` routing table for VPN bypass.
    - Adds IP rules to handle Tailscale's `fwmark 0x80000` traffic.
    - Sets up firewall zones (`tailscale`, `pia_exit`) and forwarding.
    - Automatically advertises the router as an exit node and exposes the LAN subnet.

## Installation & Setup

1.  **Prepare the Router**:
    Ensure `tailscale`, `wireguard-tools`, and `curl` are installed.
2.  **Configure PIA**:
    Run `/opt/scripts/pia_vpn_manager.sh configure` to set up your credentials and choose a region. Then run `/opt/scripts/pia_vpn_manager.sh start` to connect.
3.  **Run the Native Setup**:
    Execute the setup script:
    ```bash
    chmod +x /opt/scripts/setup_native_double_vpn.sh
    /opt/scripts/setup_native_double_vpn.sh
    ```
4.  **Tailscale Admin Console**:
    Log in to your [Tailscale Admin Console](https://login.tailscale.com/admin/machines) and:
    - **Approve the Exit Node** for the OpenWrt machine.
    - **Approve the Advertised Route** (`192.168.2.0/24`).

## Architecture Details

### Routing Logic
The script uses **Policy Based Routing (PBR)** built directly into the Linux kernel:
- **Priority 1900**: Allows Tailscale to "see" local LAN subnets.
- **Priority 2000**: Catches Tailscale's encrypted tunnel traffic (`0x80000`) and sends it out via the physical WAN gateway.
- **Main Table**: The default gateway is set to `wg_pia`, ensuring all regular traffic (Exit Node payload, LAN devices) goes through the VPN.

### Firewall Security
- **LAN Isolation**: The WAN interface is set to `REJECT` incoming traffic, effectively hiding your private devices from the rest of the house.
- **Forwarding**: Explicit rules allow `Tailscale -> PIA` and `Tailscale -> LAN`.

## Maintenance
## Backup & Recovery

This setup is designed to be highly portable and backup-friendly.

### What to Include in Your Backup
To ensure a full recovery, include the following files and directories in your backup strategy:
- **UCI Configurations**: `/etc/config/network`, `/etc/config/firewall`, `/etc/config/dhcp`, and `/etc/config/pia_wg`.
- **Routing Tables**: `/etc/iproute2/rt_tables` (defines the `wan_direct` table name).
- **Scripts**: `/opt/scripts/` (contains all automation logic).
- **Tailscale State**: `/var/lib/tailscale/` (Optional: preserves your router's Tailscale identity).

### Recovery Steps
1. **Fresh Install**: Install OpenWrt and the necessary packages:
   ```bash
   opkg update && opkg install tailscale wireguard-tools curl jq-full ip-full openssh-sftp-server
   ```
2. **Restore Files**: Restore the backed-up configurations and scripts to their original locations.
3. **Re-establish VPN**: Run `/opt/scripts/pia_vpn_manager.sh start` to initialize the VPN interface and keys.
4. **Apply Routing**: Run `/opt/scripts/setup_native_double_vpn.sh` to re-apply the native double-VPN routing and firewall rules.
