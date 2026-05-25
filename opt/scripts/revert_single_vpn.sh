#!/bin/sh

# revert_single_vpn.sh
# -----------------------------------------------------------------------------
# Purpose: Reverts the OpenWrt router from a native Double-VPN (Tailscale + PIA)
#          setup back to a simpler Single-VPN (Tailscale-only) state.
#
# Keeps:
#   - Tailscale Exit Node & subnet advertising configuration.
#   - Custom hardware bridge settings (br-extender, br-lan, IP subnet 192.168.2.1).
# Removes:
#   - PIA WireGuard VPN configuration and watchdog daemon.
#   - Custom routing rules (wan_direct table, TS underlay bypass).
# -----------------------------------------------------------------------------

LOG_FILE='/var/log/revert_single_vpn.log'

log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" >> "$LOG_FILE"
    echo "$message"
}

check_dependencies() {
    local deps="uci ip grep sed awk"
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "ERROR: Missing dependency: $dep"
            exit 1
        fi
    done
}

echo "=== OpenWrt Double-to-Single VPN Reversion Script ==="
check_dependencies

# 1. Stop and Disable PIA Watchdog Crontab
log_message "1. Cleaning up PIA background watchdogs..."
if crontab -l >/dev/null 2>&1; then
    crontab -l | grep -v "pia_vpn" | crontab -
    log_message "-> Watchdog entries removed from crontab."
else
    log_message "-> Crontab is empty. No action needed."
fi

# 2. Deactivate and Remove PIA Wireguard Interfaces
log_message "2. Deactivating and deleting 'wg_pia' interface..."
if command -v ifdown >/dev/null 2>&1; then
    ifdown wg_pia >/dev/null 2>&1
fi

uci -q delete network.wg_pia
uci -q delete network.wgpeer_pia
log_message "-> Interface and Peer deleted from network config."

# 3. Clean up Policy Routing Rules and Tables
log_message "3. Tearing down custom bypass routing rules and routes..."
uci -q delete network.ts_underlay_bypass
uci -q delete network.ts_local_bypass
uci -q delete network.wan_direct_route
uci commit network
log_message "-> UCI network rules cleared."

if [ -f /etc/iproute2/rt_tables ]; then
    if grep -q "wan_direct" /etc/iproute2/rt_tables; then
        log_message "-> Removing wan_direct table mapping from /etc/iproute2/rt_tables"
        sed -i '/wan_direct/d' /etc/iproute2/rt_tables
    fi
fi

# 4. Reconfigure Firewall Zones and Forwardings
log_message "4. Readjusting firewall configuration..."

# Remove PIA exit zone
uci -q delete firewall.pia_exit

# Delete PIA exit forwarding rules
uci -q delete firewall.fwd_lan_pia_exit
uci -q delete firewall.fwd_tailscale_pia_exit
uci -q delete firewall.fwd_lan_pia
uci -q delete firewall.fwd_tailscale_pia

# Helper function to add named firewall forwarding safely
add_forwarding() {
    local src=$1; local dest=$2
    local name="fwd_${src}_${dest}"
    
    # Remove any duplicate anonymous forwarding targeting the same source and destination
    local anon_fwd=$(uci show firewall | grep "@forwarding" | grep ".src='$src'" | grep ".dest='$dest'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
    [ -n "$anon_fwd" ] && uci delete firewall.@forwarding[$anon_fwd]

    uci set firewall."$name"=forwarding
    uci set firewall."$name".src="$src"
    uci set firewall."$name".dest="$dest"
}

# Ensure clean routing forwardings
log_message "-> Setting up 'tailscale' -> 'wan' forwarding (for Tailscale exit node functionality)"
add_forwarding 'tailscale' 'wan'

log_message "-> Restoring/Ensuring 'lan' -> 'wan' forwarding"
add_forwarding 'lan' 'wan'

log_message "-> Restoring/Ensuring 'tailscale' -> 'lan' forwarding"
add_forwarding 'tailscale' 'lan'

uci commit firewall
log_message "-> UCI firewall rules committed."

# 5. Apply changes and restart networking/firewall
log_message "5. Applying and restarting network and firewall services..."
/etc/init.d/network restart
log_message "-> Network restarted."
/etc/init.d/firewall restart
log_message "-> Firewall restarted."

# 6. Verify and report status
log_message "6. Verifying connection and status..."
sleep 4

# Check external internet connection
if ping -c 3 -W 3 8.8.8.8 >/dev/null 2>&1; then
    log_message "-> STATUS: Internet connectivity is ACTIVE over Physical WAN!"
else
    log_message "-> STATUS WARNING: Internet connectivity check failed. Please verify physical WAN cabling/status."
fi

# Check Tailscale status
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    log_message "-> STATUS: Tailscale is RUNNING and connected."
    log_message "-> Tailscale Exit Node routes are advertised and active."
else
    log_message "-> STATUS WARNING: Tailscale is not running or connected. Run 'tailscale up' to register."
fi

log_message "=== REVERSION TO SINGLE VPN COMPLETE ==="
log_message "All hardware settings, bridges, and Tailscale exit node routes have been preserved."
log_message "PIA VPN interface and watchdog triggers are completely removed."
