#!/bin/sh

# fix_tailscale_exit_node.sh
# -----------------------------------------------------------------------------
# Purpose: Diagnoses and resolves internet/DNS routing issues when using the
#          OpenWrt router as a Tailscale Exit Node.
#
# Fixes:
#   1. System-level IP Forwarding (sysctl net.ipv4.ip_forward).
#   2. Unmanaged 'tailscale' interface mapping to 'tailscale0' device.
#   3. Tailscale Firewall Zone configuration (sets forward='ACCEPT', masq='1').
#   4. Forwarding rules (tailscale -> wan, tailscale -> lan, lan -> tailscale).
#   5. DNSmasq local service restriction (adds 'tailscale' to dnsmasq interfaces
#      so clients can resolve DNS).
# -----------------------------------------------------------------------------

LOG_FILE='/var/log/fix_tailscale_exit_node.log'

log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" >> "$LOG_FILE"
    echo "$message"
}

check_dependencies() {
    local deps="uci ip grep sed awk tailscale"
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "ERROR: Missing dependency: $dep"
            exit 1
        fi
    done
}

echo "=========================================================="
echo "   Tailscale Exit Node Routing & DNS Repair Tool"
echo "=========================================================="
check_dependencies

# 1. Enable System IP Forwarding (IPv4 & IPv6)
log_message "1. Enabling kernel IP forwarding in sysctl..."
# Enable immediately in running kernel
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

# Persist in /etc/sysctl.conf
if ! grep -q "net.ipv4.ip_forward" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
else
    sed -i 's/net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
fi

if ! grep -q "net.ipv6.conf.all.forwarding" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
else
    sed -i 's/net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
fi
log_message "-> Kernel IP forwarding enabled and persisted."

# 2. Configure 'tailscale' Network Interface & Eliminate Netifd Conflict
log_message "2. Validating network config and eliminating netifd conflict..."
# On modern OpenWrt releases, defining a logical 'tailscale' interface in /etc/config/network
# conflicts with 'tailscaled' attempting to assign IPv4 addresses to 'tailscale0' via Netlink.
# Deleting 'network.tailscale' lets tailscaled assign IPs correctly without netifd interference.
if uci -q get network.tailscale >/dev/null; then
    uci delete network.tailscale
    uci commit network
    log_message "-> Deleted conflicting network.tailscale network interface."
else
    log_message "-> Conflicting network.tailscale interface is already absent."
fi

# 3. Configure Tailscale Firewall Zone
log_message "3. Reconfiguring Tailscale firewall zone..."
# Delete any existing anonymous or duplicate tailscale zones
anon_ts_zone=$(uci show firewall | grep "@zone" | grep ".name='tailscale'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_ts_zone" ] && uci delete firewall.@zone[$anon_ts_zone]

# Create/Overwrite named tailscale zone
uci set firewall.tailscale=zone
uci set firewall.tailscale.name='tailscale'
uci set firewall.tailscale.input='ACCEPT'
uci set firewall.tailscale.output='ACCEPT'
uci set firewall.tailscale.forward='ACCEPT' # Essential for robust exit-node forwarding
uci set firewall.tailscale.masq='1'        # NAT exit traffic correctly
uci set firewall.tailscale.mtu_fix='1'     # Prevent MSS clamping issues over VPN
# Bind directly to physical device tailscale0 instead of logical network interface to avoid netifd bugs
uci -q delete firewall.tailscale.network
uci add_list firewall.tailscale.device='tailscale0'
log_message "-> Firewall zone 'tailscale' configured directly on device 'tailscale0' (forward=ACCEPT, masq=1, mtu_fix=1)."

# 4. Clean and Establish Firewall Forwardings
log_message "4. Readjusting zone forwardings..."
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

# Add standard required forwardings
add_forwarding 'tailscale' 'wan'
add_forwarding 'tailscale' 'lan'
add_forwarding 'lan' 'tailscale'
add_forwarding 'lan' 'wan'

# Clean up any residual double-VPN or PIA forwardings if they still exist
uci -q delete firewall.fwd_lan_pia_exit
uci -q delete firewall.fwd_tailscale_pia_exit
uci -q delete firewall.fwd_lan_pia
uci -q delete firewall.fwd_tailscale_pia

uci commit firewall
log_message "-> Firewall forwardings established (tailscale <-> wan, tailscale <-> lan)."

# 5. Fix DNSmasq Local Service & Wildcard Restrictions
log_message "5. Patching DNSmasq configuration for Tailscale..."
# OpenWrt's dnsmasq has 'localservice' and 'nonwildcard' enabled by default.
# 1. 'nonwildcard=1' forces dnsmasq to bind only to static IP interfaces defined in network config.
#    Since 'tailscale' is unmanaged (proto 'none'), dnsmasq refuses to listen on its dynamic IP (100.x.y.z).
#    Disabling 'nonwildcard' makes it bind to wildcard 0.0.0.0 so it listens on all dynamic interfaces.
# 2. 'localservice=1' rejects queries from non-local subnets (like Tailscale's 100.64.0.0/10).
#    Disabling 'localservice' allows queries from Tailscale clients, while the WAN zone firewall remains protected.

uci set dhcp.@dnsmasq[0].localservice='0'
uci set dhcp.@dnsmasq[0].nonwildcard='0'

# Ensure tailscale is also explicitly added to the interface list for clarity
if ! uci show dhcp | grep -q "dnsmasq.@dnsmasq\[0\].interface='tailscale'"; then
    if uci -q get dhcp.@dnsmasq[0].interface >/dev/null; then
        uci add_list dhcp.@dnsmasq[0].interface='tailscale'
    else
        uci add_list dhcp.@dnsmasq[0].interface='lan'
        uci add_list dhcp.@dnsmasq[0].interface='loopback'
        uci add_list dhcp.@dnsmasq[0].interface='tailscale'
    fi
fi

uci commit dhcp
log_message "-> DNSmasq patched (localservice=0, nonwildcard=0) to listen on wildcard 0.0.0.0 and accept Tailscale queries."

# 6. Apply Changes and Restart Services
log_message "6. Applying configuration and restarting network/firewall/DNS..."
/etc/init.d/network restart
sleep 2
/etc/init.d/firewall restart
sleep 2
/etc/init.d/dnsmasq restart
log_message "-> Services restarted successfully."

# 7. Reinforce Tailscale Exit Node Flags
log_message "7. Re-registering Tailscale Exit Node flags..."
LAN_SUBNET="192.168.2.0/24"
tailscale up --advertise-exit-node --advertise-routes="$LAN_SUBNET" --accept-dns=false
log_message "-> Tailscale up completed with exit node and route advertisement."

echo ""
echo "=========================================================="
echo "✔ Tailscale Exit Node & DNS Repair Complete!"
echo "=========================================================="
echo "Please verify the following on your Tailscale admin panel:"
echo "1. Go to: https://login.tailscale.com/admin/machines"
echo "2. Find your OpenWrt router."
echo "3. Click the '...' menu -> 'Edit route settings'."
echo "4. Ensure BOTH 'Use as exit node' and '192.168.2.0/24' routes are approved."
echo "=========================================================="
echo ""
