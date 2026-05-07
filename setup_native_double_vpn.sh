#!/bin/sh

# setup_native_double_vpn.sh (SAFE VERSION)
# 1. Routes all LAN and Tailscale exit node traffic through PIA VPN.
# 2. Forces Tailscale underlay (fwmark 0x80000) to bypass VPN via physical WAN.

echo "Starting Safe Native Double-VPN Configuration..."

# 1. Disable PBR
echo "Disabling PBR..."
/etc/init.d/pbr stop 2>/dev/null
/etc/init.d/pbr disable 2>/dev/null

# 2. Configure Routing Tables
if ! grep -q "wan_direct" /etc/iproute2/rt_tables; then
    echo "Adding wan_direct table to /etc/iproute2/rt_tables"
    echo "100 wan_direct" >> /etc/iproute2/rt_tables
fi

# 3. Configure UCI Network
echo "Configuring network rules..."

# Ensure Tailscale interface exists and is unmanaged
if ! uci -q get network.tailscale >/dev/null; then
    uci set network.tailscale=interface
fi
uci set network.tailscale.device='tailscale0'
uci set network.tailscale.proto='none'
uci commit network

# Tailscale Underlay Bypass Rule (fwmark 0x80000)
uci -q delete network.ts_underlay_bypass
uci set network.ts_underlay_bypass=rule
uci set network.ts_underlay_bypass.name='Tailscale-Underlay-WAN-Bypass'
uci set network.ts_underlay_bypass.mark='0x80000/0xff0000'
uci set network.ts_underlay_bypass.lookup='wan_direct'
uci set network.ts_underlay_bypass.priority='2000'

# Tailscale Local Bypass (access local devices)
uci -q delete network.ts_local_bypass
uci set network.ts_local_bypass=rule
uci set network.ts_local_bypass.name='Tailscale-Local-Bypass'
uci set network.ts_local_bypass.mark='0x80000/0xff0000'
uci set network.ts_local_bypass.lookup='main'
uci set network.ts_local_bypass.suppress_prefixlength='0'
uci set network.ts_local_bypass.priority='1900'

# WAN Direct Route (Table 100)
WAN_GW=$(ip route show dev br-extender | grep default | awk '{print $3}')
if [ -z "$WAN_GW" ]; then
    WAN_GW=$(uci -q get network.wan.gateway)
fi

uci -q delete network.wan_direct_route
uci set network.wan_direct_route=route
uci set network.wan_direct_route.interface='wan'
uci set network.wan_direct_route.target='0.0.0.0/0'
uci set network.wan_direct_route.table='wan_direct'
[ -n "$WAN_GW" ] && uci set network.wan_direct_route.gateway="$WAN_GW"

uci commit network

# 4. Configure UCI Firewall
echo "Configuring firewall zones and forwardings..."

# Ensure zones exist
if ! uci -q get firewall.tailscale >/dev/null; then
    uci set firewall.tailscale=zone
    uci set firewall.tailscale.name='tailscale'
    uci set firewall.tailscale.input='ACCEPT'
    uci set firewall.tailscale.output='ACCEPT'
    uci set firewall.tailscale.forward='REJECT'
    uci set firewall.tailscale.masq='1'
    uci set firewall.tailscale.mtu_fix='1'
    uci set firewall.tailscale.network='tailscale'
fi

if ! uci -q get firewall.pia_exit >/dev/null; then
    uci set firewall.pia_exit=zone
    uci set firewall.pia_exit.name='pia_exit'
    uci set firewall.pia_exit.input='REJECT'
    uci set firewall.pia_exit.output='ACCEPT'
    uci set firewall.pia_exit.forward='REJECT'
    uci set firewall.pia_exit.masq='1'
    uci set firewall.pia_exit.mtu_fix='1'
    uci set firewall.pia_exit.network='wg_pia'
fi

# Add forwardings if they don't exist
add_forwarding() {
    src=$1; dest=$2
    if ! uci show firewall | grep -q "src='$src'.*dest='$dest'"; then
        uci add firewall forwarding >/dev/null
        uci set firewall.@forwarding[-1].src="$src"
        uci set firewall.@forwarding[-1].dest="$dest"
    fi
}

add_forwarding 'lan' 'pia_exit'
add_forwarding 'tailscale' 'pia_exit'
add_forwarding 'tailscale' 'lan'
add_forwarding 'lan' 'wan'

# Allow Tailscale underlay port on WAN
if ! uci show firewall | grep -q "dest_port='41641'"; then
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='Allow-Tailscale-WAN'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].dest_port='41641'
fi

uci commit firewall

# 5. Tailscale Settings
echo "Configuring Tailscale..."

# We advertise the private LAN subnet so you can access hardwired devices
LAN_SUBnet="192.168.2.0/24"

# Check if logged in, if not, initiate login
if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale not logged in. Initiating 'tailscale up'..."
    tailscale up --advertise-exit-node --advertise-routes="$LAN_SUBnet" --accept-dns=false
else
    echo "Tailscale is logged in. Updating settings..."
    tailscale set --accept-dns=false --advertise-exit-node --advertise-routes="$LAN_SUBnet" 2>/dev/null || true
fi

# 6. Apply Changes
echo "Applying changes..."
/etc/init.d/network restart
/etc/init.d/firewall restart

echo "Setup complete. Please run your PIA script to establish the VPN."
