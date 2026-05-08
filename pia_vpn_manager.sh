#!/bin/sh

# pia_vpn_manager.sh
# -----------------------------------------------------------------------------
# Purpose: Automates the setup, connection, and monitoring of Private Internet
#          Access (PIA) WireGuard VPN on OpenWrt routers.
#
# Double-VPN Support:
#   Designed to work alongside Tailscale. This script manages the 'wg_pia' 
#   interface which serves as the primary internet exit for the router.
#
# Credits: Inspired by bOLEMO's pia_wg.sh and Lazerdog's piawgx.sh
# -----------------------------------------------------------------------------

# --- GLOBAL CONFIGURATION ---
SCRIPT_PATH="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)/${0##*/}"
CONFIG_FILE='/etc/config/pia_wg'
INTERFACE_NAME='wg_pia'
PEER_NAME='wgpeer_pia'
LOG_FILE='/var/log/pia_vpn_manager.log'
PIA_TOKEN_EXPIRY_SECONDS=86400  # 24 hours

# --- HELPER FUNCTIONS ---

# Logs a message with a timestamp to the log file and optionally to stderr
log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" >> "$LOG_FILE"
    # If not running in auto-mode (watchdog), print to screen too
    [ -t 0 ] && echo "$message"
}

# Prompts the user for a Yes/No answer
ask_user_yes_no() {
    local prompt="$1"
    while :; do
        printf "%s? (y/n): " "$prompt"
        read -r choice
        case "$choice" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
        esac
    done
}

# --- PIA API & CONFIGURATION FUNCTIONS ---

# Fetches the list of available PIA regions and lets the user choose one
interactive_region_selection() {
    echo "Fetching latest PIA servers list..."
    local region_json
    region_json=$(curl -s https://serverlist.piaservers.net/vpninfo/servers/v6 | head -1 | jq '.regions | sort_by(.name)')
    
    if [ -z "$region_json" ]; then
        log_message "ERROR: Failed to fetch PIA server list." >&2
        exit 1
    fi

    while :; do
        printf "Enter Region ID (or press Enter to list all): "
        read -r manual_id
        if [ -n "$manual_id" ]; then
            local name=$(echo "$region_json" | jq -r ".[] | select(.id==\"$manual_id\") | .name")
            if [ "$name" != "null" ] && [ -n "$name" ]; then
                region_id="$manual_id"
                break
            fi
            echo "Invalid region ID: '$manual_id'"
        else
            # List regions numerically
            echo "Filtering for active WireGuard servers..."
            echo "$region_json" | jq -r ".[] | select(.offline==false) | select(.servers.wg) | .name" | nl -v0
            printf "Select region number: "
            read -r selection_index
            region_id=$(echo "$region_json" | jq -r "[.[] | select(.offline==false) | select(.servers.wg)][$selection_index].id")
            [ "$region_id" != "null" ] && break
        fi
    done

    local region_name=$(echo "$region_json" | jq -r ".[] | select(.id==\"$region_id\") | .name")
    local region_dns=$(echo "$region_json" | jq -r ".[] | select(.id==\"$region_id\") | .dns")

    log_message "Region selected: $region_name ($region_id)"
    
    uci -q batch <<EOI
        delete pia_wg.@region[0]
        add pia_wg region
        set pia_wg.@region[0].id="$region_id"
        set pia_wg.@region[0].name="$region_name"
        set pia_wg.@region[0].dns="$region_dns"
        commit pia_wg
EOI
}

# Configures PIA username and password in UCI
configure_pia_credentials() {
    printf "PIA Username (pXXXXXXX): "
    read -r username
    printf "PIA Password: "
    stty -echo
    read -r password
    stty echo
    printf "\n"
    
    uci -q batch <<EOI
        delete pia_wg.@user[0]
        add pia_wg user
        set pia_wg.@user[0].id="$username"
        set pia_wg.@user[0].password="$password"
        commit pia_wg
EOI
}

# Requests a fresh authentication token from PIA
refresh_pia_auth_token() {
    log_message "Refreshing PIA authentication token..."
    
    local username=$(uci -q get pia_wg.@user[0].id)
    local password=$(uci -q get pia_wg.@user[0].password)
    
    if [ -z "$username" ] || [ -z "$password" ]; then
        log_message "ERROR: Missing PIA credentials. Run 'configure' first."
        return 1
    fi

    local response
    response=$(curl -s --data-urlencode "username=$username" --data-urlencode "password=$password" https://www.privateinternetaccess.com/api/client/v2/token)
    
    local token=$(echo "$response" | jq -r .token 2>/dev/null)
    if [ "$token" = "null" ] || [ -z "$token" ]; then
        log_message "ERROR: Failed to obtain PIA token. Check credentials."
        return 1
    fi

    uci -q batch <<EOI
        delete pia_wg.@token[0]
        add pia_wg token
        set pia_wg.@token[0].hash="$token"
        set pia_wg.@token[0].timestamp="$(date +%s)"
        commit pia_wg
EOI
    return 0
}

# --- NETWORK & FIREWALL FUNCTIONS ---

# Sets up the firewall zone and forwarding for the PIA tunnel
apply_firewall_configuration() {
    log_message "Syncing firewall rules for 'pia_exit' zone..."
    
    # Use named section for the zone to avoid duplicates and simplify management
    # If it already exists as an anonymous section, we'll try to 'convert' it by deleting and recreating
    local anon_zone=$(uci show firewall | grep "@zone" | grep ".name='pia_exit'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
    [ -n "$anon_zone" ] && uci delete firewall.@zone[$anon_zone]

    uci set firewall.pia_exit=zone
    uci set firewall.pia_exit.name='pia_exit'
    uci set firewall.pia_exit.input='REJECT'
    uci set firewall.pia_exit.output='ACCEPT'
    uci set firewall.pia_exit.forward='REJECT'
    uci set firewall.pia_exit.masq='1'
    uci set firewall.pia_exit.mtu_fix='1'
    
    # Ensure interface is in the network list without duplication
    uci del_list firewall.pia_exit.network="$INTERFACE_NAME" 2>/dev/null
    uci add_list firewall.pia_exit.network="$INTERFACE_NAME"
    
    # Use named section for forwarding to avoid duplicates
    # Clean up any matching anonymous forwarding first
    local anon_fwd=$(uci show firewall | grep "@forwarding" | grep ".src='lan'" | grep ".dest='pia_exit'" | cut -d'[' -f2 | cut -d']' -f1 | head -1)
    [ -n "$anon_fwd" ] && uci delete firewall.@forwarding[$anon_fwd]

    uci set firewall.fwd_lan_pia=forwarding
    uci set firewall.fwd_lan_pia.src='lan'
    uci set firewall.fwd_lan_pia.dest='pia_exit'
    
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1
}

# Generates the WireGuard configuration based on PIA's response
initialize_wireguard_interface() {
    log_message "Generating WireGuard configuration..."
    
    # Check if token needs refresh
    local last_token_time=$(uci -q get pia_wg.@token[0].timestamp || echo 0)
    local current_time=$(date +%s)
    if [ $((current_time - last_token_time)) -ge $PIA_TOKEN_EXPIRY_SECONDS ]; then
        refresh_pia_auth_token || return 1
    fi

    local token=$(uci -q get pia_wg.@token[0].hash)
    local region_dns=$(uci -q get pia_wg.@region[0].dns)
    local pub_key=$(uci -q get pia_wg.@keys[0].pub)
    
    # Resolve region DNS manually to help curl if DNS is shaky
    local region_ip=$(nslookup "$region_dns" 8.8.8.8 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '8.8.8.8' | head -n1)
    local resolve_arg=""
    [ -n "$region_ip" ] && resolve_arg="--resolve $region_dns:1337:$region_ip"

    log_message "Registering public key with PIA ($region_dns)..."
    local register_response
    register_response=$(curl -sS --connect-timeout 10 -k -G $resolve_arg \
        --data-urlencode "pt=$token" \
        --data-urlencode "pubkey=$pub_key" \
        "https://$region_dns:1337/addKey")

    if [ "$(echo "$register_response" | jq -r '.status')" != "OK" ]; then
        log_message "ERROR: PIA registration failed: $(echo "$register_response" | jq -r '.status')"
        return 1
    fi

    # Extract connection details
    local server_ip=$(echo "$register_response" | jq -r '.server_ip')
    local server_port=$(echo "$register_response" | jq -r '.server_port')
    local server_key=$(echo "$register_response" | jq -r '.server_key')
    local peer_ip=$(echo "$register_response" | jq -r '.peer_ip')
    local dns1=$(echo "$register_response" | jq -r '.dns_servers[0]')
    local dns2=$(echo "$register_response" | jq -r '.dns_servers[1]')

    # Update UCI network
    uci batch <<EOI
        set network.$INTERFACE_NAME=interface
        set network.$INTERFACE_NAME.proto='wireguard'
        set network.$INTERFACE_NAME.addresses="$peer_ip"
        set network.$INTERFACE_NAME.private_key="$(uci -q get pia_wg.@keys[0].priv)"
        set network.$INTERFACE_NAME.defaultroute='1'
        delete network.$INTERFACE_NAME.dns
        add_list network.$INTERFACE_NAME.dns="$dns1"
        add_list network.$INTERFACE_NAME.dns="$dns2"
        set network.$PEER_NAME="wireguard_${INTERFACE_NAME}"
        set network.$PEER_NAME.endpoint_host="$server_ip"
        set network.$PEER_NAME.endpoint_port="$server_port"
        set network.$PEER_NAME.public_key="$server_key"
        set network.$PEER_NAME.persistent_keepalive='25'
        set network.$PEER_NAME.route_allowed_ips='1'
        delete network.$PEER_NAME.allowed_ips
        add_list network.$PEER_NAME.allowed_ips='0.0.0.0/0'
        add_list network.$PEER_NAME.allowed_ips='::/0'
        commit network
EOI
    
    /etc/init.d/network restart
    return 0
}

# --- OPERATION FUNCTIONS ---

# Verifies if the VPN tunnel is actually passing traffic
verify_vpn_connectivity() {
    if ! wg show "$INTERFACE_NAME" >/dev/null 2>&1; then
        echo "Interface $INTERFACE_NAME is DOWN."
        return 1
    fi

    # Try pinging through the VPN interface
    if ping -q -c1 -W2 -I "$INTERFACE_NAME" 8.8.8.8 >/dev/null 2>&1; then
        echo "VPN Connectivity: OK"
        return 0
    else
        echo "VPN Connectivity: FAILED (No traffic flow)"
        return 1
    fi
}

start_vpn() {
    log_message "Starting PIA VPN..."
    if verify_vpn_connectivity >/dev/null 2>&1; then
        log_message "PIA is already up and running."
        return 0
    fi

    initialize_wireguard_interface || return 1
    
    ifup "$INTERFACE_NAME"
    # Wait for up to 15 seconds for interface to settle
    for i in $(seq 1 15); do
        ubus call network.interface."$INTERFACE_NAME" status 2>/dev/null | grep -q '"up": true' && break
        sleep 1
    done

    if verify_vpn_connectivity; then
        log_message "PIA VPN started successfully."
        return 0
    else
        log_message "ERROR: VPN failed to establish connectivity."
        return 1
    fi
}

stop_vpn() {
    log_message "Stopping PIA VPN..."
    ifdown "$INTERFACE_NAME" 2>/dev/null
    uci -q delete network.$INTERFACE_NAME
    uci -q delete network.$PEER_NAME
    uci commit network
    /etc/init.d/network restart
    log_message "PIA VPN stopped and network configurations cleared."
}

# --- WATCHDOG MANAGEMENT ---

manage_watchdog() {
    local action="$1"
    case "$action" in
        "install")
            (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "* * * * * $SCRIPT_PATH start >/dev/null 2>&1") | crontab -
            log_message "Watchdog installed (checks every minute)."
            ;;
        "remove")
            crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
            log_message "Watchdog removed."
            ;;
    esac
}

# --- MAIN ENTRY POINT ---

[ -e "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

# Usage help
print_usage() {
    echo "Usage: $0 { configure | start | stop | status | watchdog {install|remove} }"
    echo "  configure : Interactive setup for credentials and region"
    echo "  start     : Connects the VPN and verifies connectivity"
    echo "  stop      : Disconnects and removes temporary network configs"
    echo "  status    : Checks current VPN and connectivity state"
}

case "$1" in
    "configure")
        configure_pia_credentials
        interactive_region_selection
        apply_firewall_configuration
        # Generate keys if they don't exist
        if ! uci -q get pia_wg.@keys[0] >/dev/null; then
            log_message "Generating new WireGuard keys..."
            local priv=$(wg genkey)
            local pub=$(echo "$priv" | wg pubkey)
            uci add pia_wg keys >/dev/null
            uci set pia_wg.@keys[0].priv="$priv"
            uci set pia_wg.@keys[0].pub="$pub"
            uci commit pia_wg
        fi
        ;;
    "start")
        start_vpn
        ;;
    "stop")
        manage_watchdog remove
        stop_vpn
        ;;
    "status")
        verify_vpn_connectivity
        ;;
    "watchdog")
        manage_watchdog "$2"
        ;;
    *)
        print_usage
        exit 1
        ;;
esac
