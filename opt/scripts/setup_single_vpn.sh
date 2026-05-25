#!/bin/sh

# Ensure we are running from the script's directory
cd "$(dirname "$0")" || exit 1

echo "Starting Single-VPN System Bootstrap..."

if [ ! -f "requirements.txt" ]; then
    echo "ERROR: 'requirements.txt' file not found in $(pwd)"
    exit 1
fi

echo "Updating package lists..."
opkg update || { echo "ERROR: opkg update failed"; exit 1; }

echo "Installing required packages from requirements.txt..."
cat requirements.txt | xargs opkg install

echo "Setting permissions..."
chmod +x setup_single_vpn.sh revert_single_vpn.sh setup_double_vpn.sh

# --- CONFIGURATION ---
LAN_IP="192.168.2.1"
LAN_NETMASK="255.255.255.0"
ADMIN_IP="192.168.1.92"      # IP allowed to access router from WAN
TS_PORT="41641"              # Tailscale UDP port
WAN_PORTS="wan lan4"         # Ports to include in br-extender
LAN_PORTS="lan1 lan2 lan3"   # Ports to include in br-lan

# --- HELPER FUNCTIONS ---
check_dependencies() {
    local deps="uci ip tailscale grep awk"
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "ERROR: Missing dependency: $dep"
            exit 1
        fi
    done
}

echo "Starting Safe Native Single-VPN (Tailscale-only) Configuration..."
check_dependencies


# 1. Disable PBR (Policy Based Routing) if installed
echo "Disabling PBR if present..."
/etc/init.d/pbr stop 2>/dev/null
/etc/init.d/pbr disable 2>/dev/null

# 2. Configure UCI Network
echo "Configuring network devices and interfaces..."

# br-extender bridge device
uci -q delete network.br_extender
uci set network.br_extender=device
uci set network.br_extender.name='br-extender'
uci set network.br_extender.type='bridge'
for port in $WAN_PORTS; do uci add_list network.br_extender.ports="$port"; done

# Update br-lan bridge device
uci -q delete network.device_br_lan
uci set network.device_br_lan=device
uci set network.device_br_lan.name='br-lan'
uci set network.device_br_lan.type='bridge'
for port in $LAN_PORTS; do uci add_list network.device_br_lan.ports="$port"; done

# LAN Interface
uci set network.lan=interface
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask="$LAN_NETMASK"
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

# Remove any remnants of double-vpn bypass rules/routes
uci -q delete network.ts_underlay_bypass
uci -q delete network.ts_local_bypass
uci -q delete network.wan_direct_route

uci commit network

# 3. Configure UCI Firewall
echo "Configuring firewall zones and forwardings..."

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

# Remove PIA exit zone if it exists
anon_pia_zone=$(uci show firewall | grep "@zone" | grep ".name='pia_exit'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_pia_zone" ] && uci delete firewall.@zone[$anon_pia_zone]
uci -q delete firewall.pia_exit

# Add named forwardings
add_forwarding() {
    local src=$1; local dest=$2
    local name="fwd_${src}_${dest}"
    
    local anon_fwd=$(uci show firewall | grep "@forwarding" | grep ".src='$src'" | grep ".dest='$dest'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
    [ -n "$anon_fwd" ] && uci delete firewall.@forwarding[$anon_fwd]

    uci set firewall."$name"=forwarding
    uci set firewall."$name".src="$src"
    uci set firewall."$name".dest="$dest"
}

# Delete any old double-vpn forwardings
uci -q delete firewall.fwd_lan_pia_exit
uci -q delete firewall.fwd_tailscale_pia_exit
uci -q delete firewall.fwd_lan_pia
uci -q delete firewall.fwd_tailscale_pia

# Set clean single-vpn forwardings
add_forwarding 'lan' 'wan'
add_forwarding 'tailscale' 'wan'
add_forwarding 'tailscale' 'lan'

# Allow Tailscale underlay port on WAN using a named rule
anon_ts_rule=$(uci show firewall | grep "@rule" | grep ".dest_port='41641'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
[ -n "$anon_ts_rule" ] && uci delete firewall.@rule[$anon_ts_rule]

uci set firewall.rule_ts_wan=rule
uci set firewall.rule_ts_wan.name='Allow-Tailscale-WAN'
uci set firewall.rule_ts_wan.src='wan'
uci set firewall.rule_ts_wan.target='ACCEPT'
uci set firewall.rule_ts_wan.proto='udp'
uci set firewall.rule_ts_wan.dest_port="$TS_PORT"

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
uci set firewall.redirect_admin.src_ip="$ADMIN_IP"
uci set firewall.redirect_admin.src_dport='8080'
uci set firewall.redirect_admin.dest='lan'
uci set firewall.redirect_admin.dest_ip="$LAN_IP"
uci set firewall.redirect_admin.dest_port='80'
uci set firewall.redirect_admin.proto='tcp'
uci set firewall.redirect_admin.target='DNAT'

uci commit firewall

# 4. Tailscale Settings
echo "Configuring Tailscale..."
LAN_SUBNET="192.168.2.0/24"

if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale not logged in. Initiating 'tailscale up'..."
    tailscale up --advertise-exit-node --advertise-routes="$LAN_SUBNET" --accept-dns=false
else
    echo "Tailscale is logged in. Updating settings..."
    tailscale set --accept-dns=false --advertise-exit-node --advertise-routes="$LAN_SUBNET" 2>/dev/null || true
fi

echo ""
echo "----------------------------------------------------------------"
echo "IMPORTANT: TAILSCALE APPROVAL REQUIRED"
echo "1. Go to: https://login.tailscale.com/admin/machines"
echo "2. Find this device (OpenWrt)"
echo "3. Click the '...' menu -> 'Edit route settings'"
echo "4. Enable 'Use as exit node' AND approve the advertised routes"
echo "----------------------------------------------------------------"
echo ""

# 5. Apply Changes
echo "Applying changes..."
/etc/init.d/network restart
/etc/init.d/firewall restart

echo "Single-VPN Setup complete."
