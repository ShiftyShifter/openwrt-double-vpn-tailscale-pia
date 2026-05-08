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
echo "Configuring network devices and interfaces..."

# br-extender bridge device
uci -q delete network.br_extender
uci set network.br_extender=device
uci set network.br_extender.name='br-extender'
uci set network.br_extender.type='bridge'
uci add_list network.br_extender.ports='wan'
uci add_list network.br_extender.ports='lan4'

# Update br-lan bridge device (ensure lan4 is NOT in it to avoid conflicts)
uci -q delete network.device_br_lan
uci set network.device_br_lan=device
uci set network.device_br_lan.name='br-lan'
uci set network.device_br_lan.type='bridge'
uci add_list network.device_br_lan.ports='lan1'
uci add_list network.device_br_lan.ports='lan2'
uci add_list network.device_br_lan.ports='lan3'

# LAN Interface
uci set network.lan=interface
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.2.1'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.ip6assign='60'

# WAN Interface
uci set network.wan=interface
uci set network.wan.device='br-extender'
uci set network.wan.proto='dhcp'

# WAN6 Interface
if ! uci -q get network.wan6 >/dev/null; then
    uci set network.wan6=interface
fi
uci set network.wan6.device='br-extender'
uci set network.wan6.proto='dhcpv6'

# Extender Interface
if ! uci -q get network.extender >/dev/null; then
    uci set network.extender=interface
fi
uci set network.extender.proto='none'
uci set network.extender.device='br-extender'

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

# Ensure zones exist using named sections to avoid duplicates

# LAN Zone
anon_lan_zone=$(uci show firewall | grep "@zone" | grep ".name='lan'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_lan_zone" ] && uci delete firewall.@zone[$anon_lan_zone]

uci set firewall.lan=zone
uci set firewall.lan.name='lan'
uci set firewall.lan.input='ACCEPT'
uci set firewall.lan.output='ACCEPT'
uci set firewall.lan.forward='ACCEPT'
uci add_list firewall.lan.network='lan'

# WAN Zone
anon_wan_zone=$(uci show firewall | grep "@zone" | grep ".name='wan'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_wan_zone" ] && uci delete firewall.@zone[$anon_wan_zone]

uci set firewall.wan=zone
uci set firewall.wan.name='wan'
uci set firewall.wan.input='REJECT'
uci set firewall.wan.output='ACCEPT'
uci set firewall.wan.forward='REJECT'
uci set firewall.wan.masq='1'
uci set firewall.wan.mtu_fix='1'
uci add_list firewall.wan.network='wan'
uci add_list firewall.wan.network='wan6'

# Tailscale Zone
anon_ts_zone=$(uci show firewall | grep "@zone" | grep ".name='tailscale'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_ts_zone" ] && uci delete firewall.@zone[$anon_ts_zone]

uci set firewall.tailscale=zone
uci set firewall.tailscale.name='tailscale'
uci set firewall.tailscale.input='ACCEPT'
uci set firewall.tailscale.output='ACCEPT'
uci set firewall.tailscale.forward='REJECT'
uci set firewall.tailscale.masq='1'
uci set firewall.tailscale.mtu_fix='1'
uci set firewall.tailscale.network='tailscale'

# PIA Exit Zone
anon_pia_zone=$(uci show firewall | grep "@zone" | grep ".name='pia_exit'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_pia_zone" ] && uci delete firewall.@zone[$anon_pia_zone]

uci set firewall.pia_exit=zone
uci set firewall.pia_exit.name='pia_exit'
uci set firewall.pia_exit.input='REJECT'
uci set firewall.pia_exit.output='ACCEPT'
uci set firewall.pia_exit.forward='REJECT'
uci set firewall.pia_exit.masq='1'
uci set firewall.pia_exit.mtu_fix='1'
uci set firewall.pia_exit.network='wg_pia'

# Add forwardings using named sections
add_forwarding() {
    local src=$1; local dest=$2
    local name="fwd_${src}_${dest}"
    
    # Clean up any matching anonymous forwarding first
    local anon_fwd=$(uci show firewall | grep "@forwarding" | grep ".src='$src'" | grep ".dest='$dest'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
    [ -n "$anon_fwd" ] && uci delete firewall.@forwarding[$anon_fwd]

    uci set firewall."$name"=forwarding
    uci set firewall."$name".src="$src"
    uci set firewall."$name".dest="$dest"
}

add_forwarding 'lan' 'pia_exit'
add_forwarding 'tailscale' 'pia_exit'
add_forwarding 'tailscale' 'lan'
add_forwarding 'lan' 'wan'

# Allow Tailscale underlay port on WAN using a named rule
anon_ts_rule=$(uci show firewall | grep "@rule" | grep ".dest_port='41641'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_ts_rule" ] && uci delete firewall.@rule[$anon_ts_rule]

uci set firewall.rule_ts_wan=rule
uci set firewall.rule_ts_wan.name='Allow-Tailscale-WAN'
uci set firewall.rule_ts_wan.src='wan'
uci set firewall.rule_ts_wan.target='ACCEPT'
uci set firewall.rule_ts_wan.proto='udp'
uci set firewall.rule_ts_wan.dest_port='41641'

# Allow Admin Access from specific IP
uci -q delete firewall.rule_admin
uci set firewall.rule_admin=rule
uci set firewall.rule_admin.name='Allow-Admin'
uci set firewall.rule_admin.src='wan'
uci set firewall.rule_admin.dest='lan'
uci add_list firewall.rule_admin.src_ip='192.168.1.92'
uci set firewall.rule_admin.target='ACCEPT'

# Restricted Admin Access Redirect
uci -q delete firewall.redirect_admin
uci set firewall.redirect_admin=redirect
uci set firewall.redirect_admin.name='Restricted-Admin-Access'
uci set firewall.redirect_admin.src='wan'
uci set firewall.redirect_admin.src_ip='192.168.1.92'
uci set firewall.redirect_admin.src_dport='8080'
uci set firewall.redirect_admin.dest='lan'
uci set firewall.redirect_admin.dest_ip='192.168.2.1'
uci set firewall.redirect_admin.dest_port='80'
uci set firewall.redirect_admin.proto='tcp'
uci set firewall.redirect_admin.target='DNAT'

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
