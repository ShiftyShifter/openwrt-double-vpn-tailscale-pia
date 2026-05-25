#!/bin/sh

# diagnose_tailscale.sh
# -----------------------------------------------------------------------------
# Purpose: Gathers comprehensive network, firewall, and routing diagnostics 
#          from the OpenWrt router to troubleshoot Tailscale Exit Node issues.
# -----------------------------------------------------------------------------

echo "=========================================================="
echo "      OpenWrt Tailscale Exit Node Diagnostics"
echo "=========================================================="
echo "Timestamp: $(date)"
echo "Firmware: $(cat /etc/openwrt_release | grep DISTRIB_DESCRIPTION | cut -d"'" -f2)"
echo "Kernel: $(uname -r)"
echo "----------------------------------------------------------"

echo ""
echo "=== [1] Tailscale Service Status ==="
if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale Version: $(tailscale --version | head -1)"
    echo "Tailscale Status:"
    tailscale status | head -10
    echo ""
    echo "Tailscale IPs:"
    tailscale ip
else
    echo "ERROR: tailscale CLI not found!"
fi

echo ""
echo "=== [2] Kernel IP Forwarding ==="
echo "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)"
echo "net.ipv6.conf.all.forwarding = $(sysctl -n net.ipv6.conf.all.forwarding)"

echo ""
echo "=== [3] Active IP Rules (Policy Routing) ==="
ip rule show

echo ""
echo "=== [4] Active Routes (Main Table) ==="
ip route show

echo ""
echo "=== [5] Active Routes (Table 100 / wan_direct if exists) ==="
ip route show table 100 2>/dev/null || echo "Table 100 not found or empty."

echo ""
echo "=== [6] Network Interface Configuration (/etc/config/network) ==="
uci show network | grep -E "tailscale|wan_direct|br_extender"

echo ""
echo "=== [7] Firewall Configuration (/etc/config/firewall) ==="
uci show firewall | grep -E "tailscale|pia|forwarding"

echo ""
echo "=== [8] DHCP/DNSmasq Configuration (/etc/config/dhcp) ==="
uci show dhcp | grep -E "dnsmasq|interface|localservice"

echo ""
echo "=== [9] Active Firewall Rules (NFTables/IPTables summary) ==="
if command -v nft >/dev/null 2>&1; then
    echo "NFTables detected. Looking for tailscale references:"
    nft list ruleset | grep -A 5 -E "tailscale|tailscale0" | head -30
else
    echo "IPTables detected. Looking for tailscale references:"
    iptables -vnL | grep -i tailscale | head -30
fi

echo ""
echo "=== [10] Testing DNSmasq Listen Status ==="
netstat -tulpn | grep dnsmasq

echo "=========================================================="
echo "Diagnostics complete. Please copy and paste this entire output!"
echo "=========================================================="
