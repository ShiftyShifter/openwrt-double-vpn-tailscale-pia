#!/bin/sh
#
# pia_wg.sh
# Script to setup and run PIA through WireGuard on OpenWrt
#
# Inspired from:
# - This thread: https://forum.openwrt.org/t/private-internet-access-pia-wireguard-vpn-on-openwrt/155475
# - And @Lazerdog's script: https://github.com/jimhall718/piawg/blob/main/piawgx.sh
#
# Version: 1.0.16
#
# ©2026 bOLEMO
# https://github.com/bolemo/pia_wg/
#
#########

SCRIPTPATH="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)/${0##*/}"
PIACONF='/etc/config/pia_wg'
PIAWG_IF='wg_pia'
PIAWG_PEER='wgpeer_pia'
PIALOG='/var/log/pia_wg_watchdog.log'

read_yn() {
  while :; do
    printf "%s? (y/n): " "$1"
    read -r AND
    case "$AND" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
    esac
  done
}



select_region() {
  echo "Fetching latest PIA servers list…"
  if ! PIAREGIONS="$(curl -s https://serverlist.piaservers.net/vpninfo/servers/v6 | head -1 | jq '.regions | sort_by(.name)')"; then
    echo "Error fetching PIA servers list!" >&3
    exit 1
  fi
  while :; do
    printf "Type the region ID if you know it or press enter for list selection: "
    read -r PIAREGIONID
    if [ -z "$PIAREGIONID" ]; then
      break
    else
      PIAREGIONNAME="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .name")"
      if [ -z "$PIAREGIONNAME" ]; then
        echo "Invalid region ID: '$PIAREGIONID'"
      else
        break
      fi
    fi
  done
  if [ -z "$PIAREGIONID" ]; then
    echo "Eliminating offline servers…"
    echo "Eliminating non WireGuard servers…"
    read_yn "Port forward only servers" && PIASERVPF='| select(.port_forward==true) ' || PIASERVPF=''
    read_yn "Geo only servers" && PIASERVGEO='| select(.geo==true) ' || PIASERVGEO=''
    echo "$PIAREGIONS" | jq -r ".[] | select(.offline==false) | select(.servers.wg) $PIASERVPF $PIASERVGEO | .name" | nl -v0
    printf "Select your region number: "
    read -r AND
    PIAREGIONID="$(echo "$PIAREGIONS" | jq -r "[.[] | select(.offline==false) | select(.servers.wg) $PIASERVPF $PIASERVGEO ][$AND].id")"
  fi
  PIAREGIONNAME="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .name")"
  PIAREGIONDNS="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .dns")"
  echo "Region selected: $PIAREGIONNAME"
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@region[0]
    add pia_wg region
    set pia_wg.@region[0].id="$PIAREGIONID"
    set pia_wg.@region[0].name="$PIAREGIONNAME"
    set pia_wg.@region[0].dns="$PIAREGIONDNS"
    commit pia_wg.@region[0]
EOI
}

set_piauser() {
  printf "PIA user id: "
  read -r PIAUSER
  printf "PIA password: "
  stty -echo
  read -r PIAPASS
  stty echo
  printf "\n"
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@user[0]
    add pia_wg user
    set pia_wg.@user[0].id="$PIAUSER"
    set pia_wg.@user[0].password="$PIAPASS"
    commit pia_wg.@user[0]
EOI
}

validate_dip() {
  DIPTOK="$(uci -q get pia_wg.@dip[0].token)" || return
  # Try to fetch DIP info from API
  DIPR="$(curl -s -L -X POST 'https://www.privateinternetaccess.com/api/client/v2/dedicated_ip' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Token $(uci -q get pia_wg.@token[0].hash)" \
    -d '{ "tokens":["'"$DIPTOK"'"] }' | jq 'select(.[0]) | .[0]')"
  # Extract status - if empty, API call failed (likely network down during restart)
  DIP_STATUS_NEW="$(echo "$DIPR" | jq -r 'select(.status) | .status')"
  if [ -z "$DIP_STATUS_NEW" ]; then
    # API call failed - preserve existing config if it exists
    DIP_STATUS_EXISTING="$(uci -q get pia_wg.@dip[0].status)"
    if [ -n "$DIP_STATUS_EXISTING" ]; then
      echo "Cannot validate DIP (network down?), keeping existing config" >&3
      return 0
    else
      # No existing config and API failed - this is a real error
      echo "Warning: Cannot validate DIP token!" >&3
      return 1
    fi
  fi
  # API call succeeded - update UCI with fresh data
  uci -q batch <<EOI >/dev/null
  set pia_wg.@dip[0].status="$DIP_STATUS_NEW"
  set pia_wg.@dip[0].ip="$(echo "$DIPR" | jq -r 'select(.ip) | .ip')"
  set pia_wg.@dip[0].cn="$(echo "$DIPR" | jq -r 'select(.cn) | .cn')"
  set pia_wg.@dip[0].expire="$(echo "$DIPR" | jq -r 'select(.dip_expire) | .dip_expire')"
  set pia_wg.@dip[0].id="$(echo "$DIPR" | jq -r 'select(.ip) | .id')"
  commit pia_wg.@dip[0]
EOI
}

set_dip() {
  while {
    printf "Dedicated IP token (press enter for none): "
    read -r DIPTOK
  }; do
    [ -z "$DIPTOK" ] && {
      uci -q delete pia_wg.@dip[0]
      uci -q commit pia_wg
      return
    }
    [ ${#DIPTOK} -eq 32 ] && [ "$(printf '%.3s' "$DIPTOK")" = "DIP" ] && break
    echo "Token starts with DIP and is 32 characters long!"
  done
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@dip[0]
    add pia_wg dip
    set pia_wg.@dip[0].token="$DIPTOK"
    commit pia_wg.@dip[0]
EOI
}

set_defnetpeer() {
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@net_peer[0]
    add pia_wg net_peer
    set pia_wg.@net_peer[0].route_allowed_ips='1'
    set pia_wg.@net_peer[0].persistent_keepalive="25"
    add_list pia_wg.@net_peer[0].allowed_ips="::/0"
    add_list pia_wg.@net_peer[0].allowed_ips="0.0.0.0/0"
    commit pia_wg.@net_peer[0]
EOI
}

set_defnetiface() {
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@net_interface[0]
    add pia_wg net_interface
    set pia_wg.@net_interface[0].proto="wireguard"
    set pia_wg.@net_interface[0].defaultroute='0'
    set pia_wg.@net_interface[0].delegate='0' # No IPv6 with PIA
    commit pia_wg.@net_interface[0]
EOI
}

set_firewall() {
  echo "Configuring firewall settings..."
  local ZONE_IDX=""
  
  local i=0
  while uci -q get firewall.@zone[$i] >/dev/null; do
    if [ "$(uci -q get firewall.@zone[$i].name)" = "pia_exit" ]; then
      ZONE_IDX=$i
      break
    fi
    i=$((i+1))
  done

  if [ -z "$ZONE_IDX" ]; then
    echo "Creating new firewall zone 'pia_exit'..."
    uci -q batch <<EOI >/dev/null
      add firewall zone
      set firewall.@zone[-1].name='pia_exit'
      set firewall.@zone[-1].input='REJECT'
      set firewall.@zone[-1].output='ACCEPT'
      set firewall.@zone[-1].forward='REJECT'
      set firewall.@zone[-1].masq='1'
      set firewall.@zone[-1].mtu_fix='1'
      add_list firewall.@zone[-1].network='$PIAWG_IF'
      add firewall forwarding
      set firewall.@forwarding[-1].src='lan'
      set firewall.@forwarding[-1].dest='pia_exit'
      commit firewall
EOI
  else
    echo "Updating existing firewall zone 'pia_exit'..."
    uci -q batch <<EOI >/dev/null
      set firewall.@zone[$ZONE_IDX].masq='1'
      set firewall.@zone[$ZONE_IDX].mtu_fix='1'
      del_list firewall.@zone[$ZONE_IDX].network='$PIAWG_IF'
      add_list firewall.@zone[$ZONE_IDX].network='$PIAWG_IF'
      commit firewall
EOI
  fi
  /etc/init.d/firewall restart >/dev/null 2>&1
  echo "Firewall configured."
}
generate_wgkeys() {
  WGPRIVKEY="$(wg genkey)"
  WGPUBKEY="$(echo "$WGPRIVKEY" | wg pubkey)"
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@keys[0]
    add pia_wg keys
    set pia_wg.@keys[0].priv="$WGPRIVKEY"
    set pia_wg.@keys[0].pub="$WGPUBKEY"
    commit pia_wg.@keys[0]
EOI
}

renew_piatoken() {
  echo "Renewing PIA token" >&3
  uci -q get pia_wg.@user[0] >/dev/null || set_piauser

  if ! PIARESPONSE="$(curl -s --data-urlencode "username=$(uci -q get pia_wg.@user[0].id)" --data-urlencode "password=$(uci -q get pia_wg.@user[0].password)" https://www.privateinternetaccess.com/api/client/v2/token)"; then
    echo "Error: Failed to connect to PIA authentication server!" >&3
    exit 1
  fi

  # Check if response is empty
  if [ -z "$PIARESPONSE" ]; then
    echo "Error: Empty response from PIA authentication server!" >&3
    exit 1
  fi

  # Check if response contains valid JSON with token field
  PIATOKEN="$(echo "$PIARESPONSE" | jq -r .token 2>/dev/null)"

  # Validate token format and handle errors
  if [ "$PIATOKEN" = "null" ] || [ -z "$PIATOKEN" ] || [ ${#PIATOKEN} -ne 128 ]; then
    echo "Error fetching PIA token!" >&3
    echo "Debug: Server response was:" >&3
    echo "$PIARESPONSE" | head -3 >&3
    # Check for common error patterns
    if echo "$PIARESPONSE" | jq -r .error 2>/dev/null | grep -q .; then
      echo "PIA Error: $(echo "$PIARESPONSE" | jq -r .error)" >&3
    elif echo "$PIARESPONSE" | grep -qi "invalid\|unauthorized\|credentials"; then
      echo "Hint: Check your PIA username and password" >&3
    fi
    exit 1
  fi

  uci -q batch <<EOI >/dev/null
    delete pia_wg.@token[0]
    add pia_wg token
    set pia_wg.@token[0].hash="$PIATOKEN"
    set pia_wg.@token[0].timestamp="$(date +%s)"
    commit pia_wg.@token[0]
EOI
}

keep_conf_section() {
  case "$1" in
  user) DESC='PIA user' ;;
  keys) DESC='WireGuard local keys' ;;
  net_interface) DESC='WireGuard network interface options' ;;
  net_peer) DESC='WireGuard network PIA peer options' ;;
  region) DESC='PIA region' ;;
  dip) DESC="Dedicated IP token" ;;
  esac
  if uci -q get "pia_wg.@$1[0]" >/dev/null; then
    echo "A configuration already exists for '$DESC':"
    uci show "pia_wg.@$1[0]" | awk 'sub(/^[^.]*\.[^.]*\./,"")==1{print "  "$0}'
    read_yn "Keep this configuration"
    return $?
  fi
  return 1
}

check_conf() {
  if ! uci -q get pia_wg.@user[0] >/dev/null; then
    echo "User is not configured!" >&3
    [ "$AUTO" ] && return 1 || set_piauser
  fi
  if ! uci -q get pia_wg.@keys[0] >/dev/null; then
    echo "Local keys are not configured!" >&3
    generate_wgkeys
  fi
  if ! uci -q get pia_wg.@net_interface[0] >/dev/null; then
    echo "Network interface options are not configured!" >&3
    [ "$AUTO" ] && return 1 || set_defnetiface
  fi
  if ! uci -q get pia_wg.@net_peer[0] >/dev/null; then
    echo "Network peer options are not configured!" >&3
    [ "$AUTO" ] && return 1 || set_defnetpeer
  fi
  if uci -q get pia_wg.@dip[0] >/dev/null; then
    validate_dip
    DIP_STATUS="$(uci -q get pia_wg.@dip[0].status)"
    if [ "$DIP_STATUS" != 'active' ]; then
      echo "Dedicated IP status is $DIP_STATUS!" >&3
      return 1
    fi
  fi
  if ! uci -q get pia_wg.@region[0] >/dev/null; then
    echo "PIA region is not configured!" >&3
    [ "$AUTO" ] && return 1 || select_region
  fi
}

set_netconf() {
  check_conf || {
    echo "Configuration is incomplete; exiting!" >&3
    exit 1
  }
  uci -q get pia_wg.@token[0] >/dev/null && [ $(($(date +%s) - $(uci get pia_wg.@token[0].timestamp))) -lt 86400 ] || renew_piatoken
  echo "Initializing network"

  PIA_REGION_DNS="$(uci -q get pia_wg.@region[0].dns)"
  PIA_REGION_IP="$(nslookup "$PIA_REGION_DNS" 8.8.8.8 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '8.8.8.8' | head -n1)"
  
  if [ -n "$PIA_REGION_IP" ] && [ "$PIA_REGION_IP" != "null" ]; then
    RESOLVE_ARG="--resolve $PIA_REGION_DNS:1337:$PIA_REGION_IP"
  else
    RESOLVE_ARG=""
  fi

  # if no DIP (DIP_STATUS is set from check_conf)
  if [ -z "$DIP_STATUS" ]; then
    PIAADDKEY="$(curl -sS --connect-timeout 10 -k -G $RESOLVE_ARG --data-urlencode "pt=$(uci -q get pia_wg.@token[0].hash)" --data-urlencode "pubkey=$(uci -q get pia_wg.@keys[0].pub)" "https://$PIA_REGION_DNS:1337/addKey")"
  else
    PIAADDKEY="$(curl -sS --connect-timeout 10 -k -G --connect-to "$(uci -q get pia_wg.@dip[0].cn)::$(uci -q get pia_wg.@dip[0].ip)" --user "dedicated_ip_$(uci -q get pia_wg.@dip[0].token):$(uci -q get pia_wg.@dip[0].ip)" --data-urlencode "pubkey=$(uci -q get pia_wg.@keys[0].pub)" "https://$(uci -q get pia_wg.@dip[0].cn):1337/addKey")"
  fi
  #  echo "$PIAADDKEY"

  WGSERVSTATUS="$(echo "$PIAADDKEY" | jq -r '.status')"
  [ "$WGSERVSTATUS" = "OK" ] || {
    echo "PIA server status: $WGSERVSTATUS; Aborting!" >&3
    exit 1
  }

  WGSERVIP="$(echo "$PIAADDKEY" | jq -r '.server_ip')"
  WGSERVPT="$(echo "$PIAADDKEY" | jq -r '.server_port')"
  WGSERVKEY="$(echo "$PIAADDKEY" | jq -r '.server_key')"
  WGDNS1="$(echo "$PIAADDKEY" | jq -r '.dns_servers[0]')"
  WGDNS2="$(echo "$PIAADDKEY" | jq -r '.dns_servers[1]')"
  WGPEERIP="$(echo "$PIAADDKEY" | jq -r '.peer_ip')"

  uci batch <<EOI >/dev/null
  set network.$PIAWG_IF=interface
  set network.$PIAWG_IF.addresses="$WGPEERIP"
  set network.$PIAWG_IF.private_key="$(uci -q get pia_wg.@keys[0].priv)"
  set network.$PIAWG_IF.defaultroute='0'
  add_list network.$PIAWG_IF.dns="$WGDNS1"
  add_list network.$PIAWG_IF.dns="$WGDNS2"
  set network.$PIAWG_PEER="wireguard_${PIAWG_IF}"
  set network.$PIAWG_PEER.description="PIA $(uci -q get pia_wg.@region[0].name)"
  set network.$PIAWG_PEER.endpoint_host="$WGSERVIP"
  set network.$PIAWG_PEER.endpoint_port="$WGSERVPT"
  set network.$PIAWG_PEER.public_key="$WGSERVKEY"
$(uci export pia_wg | awk '
    $0==""{d=0;next}
    index($0,"config net_"){
      if($2=="net_interface"){d="network.'$PIAWG_IF'"}
      else if($2=="net_peer"){d="network.'$PIAWG_PEER'"}
    }
    d{
      if($1=="option"){c="set"}
      else if($1=="list"){c="add_list"}
      else next
      printf("  %s %s.%s=%s\n",c,d,$2,$3)
    }
')

  commit network
EOI
  /etc/init.d/network restart
}

start_wgpia() {
  stop_wgpia
  set_netconf
  echo "Starting PIA ($(uci get network.$PIAWG_PEER.description))" >&3
  ifup $PIAWG_IF
  for i in $(seq 1 15); do
    ubus call network.interface.${PIAWG_IF} status 2>/dev/null | grep -q '"up": true' && break
    sleep 1
  done
  check_wg
  RET=$?
  [ $RET -eq 0 ] && echo "PIA started successfully ..." >&3 || echo "Could not start PIA!" >&3
  return $RET
}

stop_wgpia() {
  DESC=" ($(uci -q get network.$PIAWG_PEER.description 2>/dev/null))" || DESC=""
  echo "Stopping PIA$DESC" >&3
  ifdown $PIAWG_IF >/dev/null 2>&1
  uci -q batch <<EOI >/dev/null
  delete network.$PIAWG_IF
  delete network.$PIAWG_PEER
  commit network
EOI
  /etc/init.d/network restart
  echo "Waiting for raw WAN connectivity to settle..." >&3
  for i in $(seq 1 15); do
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && break
    sleep 1
  done
}

check_wg() {
  if wg show "$PIAWG_IF" >/dev/null 2>&1; then
    PIAWG_EP="$(wg show "$PIAWG_IF" endpoints | awk -F'[[:space:]:]' '{print $2; exit;}')"
    PIAWG_MK="$(wg show "$PIAWG_IF" fwmark)"
    [ "$PIAWG_MK" = "off" ] && PIAWG_MK=''
    WAN_IF="$(ip route get "$PIAWG_EP" ${PIAWG_MK:+mark "$PIAWG_MK"} | awk '{for(i=0;i<NF;i++){if($i=="dev"){print $++i; exit;}}}')"
    echo "WireGuard PIA interface: UP"
  else
    echo "WireGuard PIA interface: DOWN!" >&3
    return 1
  fi

  echo "Region is: $(uci get network.$PIAWG_PEER.description)"
  for i in $(seq 1 10); do
    if ping -q -c1 -W1 -I "$PIAWG_IF" 8.8.8.8 >/dev/null 2>&1; then
      echo "Connectivity through PIA: OK"
      return 0
    fi
    sleep 1
  done

  if ping -q -c1 -n -I "$WAN_IF" "$PIAWG_EP" >/dev/null; then
    echo "Connectivity through PIA: NOK" >&3
    return 1
  elif traceroute -i "$WAN_IF" -q1 -m1 8.8.8.8 2>/dev/null | grep -q ' ms'; then
    echo "Access to PIA Endpoint through WAN: NOK!" >&3
    return 1
  else
    echo "Connectivity through PIA: NOK" >&3
    return 1
  fi
}

watchdog_installed() {
  grep -qF 'pia_wg.sh start' /etc/crontabs/root 2>/dev/null
  return $?
}

watchdog_lastrun() {
  [ -f "$PIALOG" ] && date -r "$PIALOG" || return 1
}

watchdog_install() {
  watchdog_installed && return
  {
    crontab -l 2>/dev/null
    echo "* * * * * /bin/sh $SCRIPTPATH start # pia_wg watchdog"
  } | crontab -
  echo "[$(date)] Watchdog installed" >>"$PIALOG"
}

watchdog_remove() {
  watchdog_installed || return
  crontab -l | grep -vF 'pia_wg.sh' | crontab -
  echo "[$(date)] Watchdog removed" >>"$PIALOG"
}

log_show() {
  [ -s "$PIALOG" ] && cat "$PIALOG" || echo "Log is empty!"
  watchdog_installed && WLR="$(watchdog_lastrun)" && echo "[$WLR] Watchdog last check"
}

log_clear() {
  echo "[$(date)] Log cleared" >"$PIALOG"
}



print_usage() {
  echo "Usage: $0 { configure <section> | start [ --watchdog ] | restart [ --watchdog ] | stop | status | watchdog { install | remove } | log { show | clear } }"
  echo "  Details:"
  echo "    - configure          : same as configure all"
  echo "    - configure all      : configure all settings"
  echo "    - configure user     : set PIA user ID and password"
  echo "    - configure dip      : set PIA dedicated IP"
  echo "    - configure region   : set/choose PIA region"
  echo "    - configure keys     : generate local WireGuard keys"
  echo "    - configure network  : generate default network settings"
  echo "    - configure firewall : verify and apply pia_exit firewall rules"
  echo "    - init-network       : setup PIA WireGuard network (no start)"
  echo "    - start              : start PIA WireGuard (if not already up)"
  echo "    - start --watchdog   : same as start and install the watchdog"
  echo "    - restart            : start or restart PIA WireGuard"
  echo "    - restart --watchdog : same as restart and install the watchdog"
  echo "    - stop               : stop PIA WireGuard (and remove the watchdog)"
  echo "    - status             : show PIA WireGuard status"
  echo "    - watchdog install   : install the watchdog"
  echo "    - watchdog remove    : remove the watchdog"
  echo "    - log show           : display the watchdog log"
  echo "    - log clear          : clear the watchdog log"
}

# ---- Main ->

[ -e "$PIACONF" ] || touch "$PIACONF"
[ -t 0 ] && unset AUTO || AUTO=1

# Logging (only if not in interactive mode)
if [ "$AUTO" ]; then
  exec 3>&2
  exec 2>>"$PIALOG"
  echo "[$(date)] Watchdog executed" >&2
else
  exec 3>&2
fi

case "$1" in
'configure') case "$2" in
  '' | 'all')
    keep_conf_section 'user' || set_piauser
    keep_conf_section 'keys' || generate_wgkeys
    keep_conf_section 'net_interface' || set_defnetiface
    keep_conf_section 'net_peer' || set_defnetpeer
    if read_yn "Do you have a dedicated IP"; then
      keep_conf_section 'dip' || set_dip
      validate_dip
    else
      uci -q delete pia_wg.@dip[0]
      uci -q commit pia_wg
    fi
    # if no DIP ask for region
    uci -q get pia_wg.@dip[0].token >/dev/null || keep_conf_section 'region' || select_region
    set_firewall
    ;;
  'user') keep_conf_section 'user' || set_piauser ;;
  'dip') keep_conf_section 'dip' || set_dip ;;
  'region') keep_conf_section 'region' || select_region ;;
  'network')
    keep_conf_section 'net_interface' || set_defnetiface
    keep_conf_section 'net_peer' || set_defnetpeer
    ;;
  'firewall') set_firewall ;;
  'keys') keep_conf_section 'keys' || generate_wgkeys ;;
  *)
    echo "Unknown configure subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'watchdog') case "$2" in
  'install') watchdog_install ;;
  'remove') watchdog_remove ;;
  *)
    echo "Unknown watchdog subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'init-network') set_netconf ;;
'restart')
  start_wgpia
  R=$?
  [ $R -eq 0 ] && [ "$2" = "--watchdog" ] && watchdog_install
  exit $R
  ;;
'start')
  check_wg
  case $? in
  0) echo "PIA is already up!" ;;
  1) start_wgpia ;;
  2) echo "Could not start PIA!" >&2 ;;
  esac
  R=$?
  [ $R -eq 0 ] && [ "$2" = "--watchdog" ] && watchdog_install
  exit $R
  ;;
'stop')
  watchdog_remove
  stop_wgpia
  ;;
'status')
  check_wg
  R=$?
  if watchdog_installed; then
    echo "Watchdog (cron) installed: YES"
    if WLR="$(watchdog_lastrun)"; then
      echo "Watchdog last check: $WLR"
    fi
  else
    echo "Watchdog (cron) installed: NO"
  fi
  exit $R
  ;;
'log') case "$2" in
  'show') log_show ;;
  'clear') log_clear ;;
  *)
    echo "Unknown log subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'') print_usage ;;
*)
  echo "Unknown command '$*'!" >&2
  print_usage
  exit 1
  ;;
esac

exit
