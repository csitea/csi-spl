#!/bin/bash
#------------------------------------------------------------------------------
# @description Put THIS box's saved Wi-Fi profiles on one autoconnect ladder
# @description (networking round row 05, the networking round plan v1.0
# @description section 4, SPL-2352). One Wi-Fi radio joins one SSID at a time,
# @description so connection.autoconnect-priority alone picks which visible
# @description network is joined; every rung keeps the Wi-Fi metric 600:
# @description   home      priority 10, metric 600
# @description   hotspot-a priority  8, metric 600, connection.metered yes
# @description   hotspot-b priority  7, metric 600, connection.metered yes
# @description   travel    priority  5, metric 600 (any number of profiles)
# @description home, hotspot-a and hotspot-b take one profile each; metered is
# @description left as it is on home and travel.
# @description SSIDs are personal data: profiles are named by UUID only, read
# @description at run time from the ladder map (NET_WLAN_LADDER_FILE, default
# @description $HOME/.config/csi-spl/net-wlan-ladder.tsv, outside the repo),
# @description one "<uuid> <rung>" per line, # comments. The action never reads
# @description or prints a profile name, an SSID or a PSK (nmcli fields UUID,
# @description TYPE, AUTOCONNECT-PRIORITY, ACTIVE only), and changes no other
# @description setting of a profile.
# @description It lists the Wi-Fi profiles now (mapped and unmapped, with
# @description their priority), then per mapped profile runs
# @description `nmcli connection modify uuid <uuid> connection.autoconnect-priority
# @description <p> [connection.metered yes] ipv4.route-metric 600
# @description ipv6.route-metric 600` (NM rewrites the keyfile; no connection
# @description goes down: an active profile's metric applies on its next
# @description activation) and reads each back (`nmcli -g ... connection show
# @description uuid <uuid>`). A profile already on its rung is left: SAME.
# @description Dry run unless DRY_RUN=0: prints the state now and the commands,
# @description changes nothing; with no map file it says how to write one.
# @description Nothing is installed. Writing needs sudo (NET_SUDO).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_WLAN_LADDER_FILE (optional) - the ladder map, see above
# @param NET_NMCLI (optional, tests) - default nmcli
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @example ./run -a do_net_wlan_ladder
# @example DRY_RUN=0 ./run -a do_net_wlan_ladder
#------------------------------------------------------------------------------

NWL_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# nwl_rung <rung> - prints "<priority> <metered: yes, or - to leave it>"
nwl_rung() {
  case "$1" in
    home) echo "10 -" ;;
    hotspot-a) echo "8 yes" ;;
    hotspot-b) echo "7 yes" ;;
    travel) echo "5 -" ;;
    *) return 1 ;;
  esac
}

# nwl_wifi - prints "<uuid> <priority> <active>" per saved Wi-Fi profile
nwl_wifi() {
  $NWL_NMCLI -t -f UUID,TYPE,AUTOCONNECT-PRIORITY,ACTIVE connection show 2>/dev/null |
    awk -F: '$2 == "802-11-wireless" {print $1, $3, $4}'
}

# nwl_map <file> <wifi list> - checks the map, prints "<uuid> <rung>" per line
nwl_map() {
  local file="$1" wifi="$2" n=0 uuid rung extra seen=" " ones=" "
  while read -r uuid rung extra; do
    n=$((n + 1))
    [[ -z "$uuid" || "$uuid" == \#* ]] && continue
    [[ -z "$extra" ]] || { do_log "FATAL $file line $n: want '<uuid> <rung>', got more fields" >&2; return 1; }
    [[ "$uuid" =~ $NWL_UUID_RE ]] || { do_log "FATAL $file line $n: not a profile UUID: '$uuid'" >&2; return 1; }
    nwl_rung "$rung" >/dev/null || { do_log "FATAL $file line $n: rung must be home, hotspot-a, hotspot-b or travel, got '$rung'" >&2; return 1; }
    [[ "$seen" != *" $uuid "* ]] || { do_log "FATAL $file line $n: $uuid is mapped twice" >&2; return 1; }
    [[ "$rung" == travel || "$ones" != *" $rung "* ]] || { do_log "FATAL $file line $n: rung $rung takes one profile, the map gives it two" >&2; return 1; }
    grep -q "^$uuid " <<<"$wifi" || { do_log "FATAL $file line $n: $uuid is no saved Wi-Fi profile" >&2; return 1; }
    seen+="$uuid " ones+="$rung "
    echo "$uuid $rung"
  done <"$file"
}

# nwl_read <uuid> - prints "<priority> <metered> <ipv4 metric> <ipv6 metric>"
nwl_read() {
  $NWL_NMCLI -g connection.autoconnect-priority,connection.metered,ipv4.route-metric,ipv6.route-metric connection show uuid "$1" 2>&1 |
    tr ':\n' '  ' | tr -s ' ' | sed 's/ $//'
}

# nwl_ok <got> <priority> <metered> - rc 0 when a read-back sits on its rung
nwl_ok() {
  local p m r4 r6 x
  read -r p m r4 r6 x <<<"$1"
  [[ -z "$x" && "$p" == "$2" && "$r4" == 600 && "$r6" == 600 && ("$3" == - || "$m" == "$3") ]]
}

# nwl_args <priority> <metered> - the nmcli connection modify property words
nwl_args() {
  local m=""
  [[ "$2" == yes ]] && m=" connection.metered yes"
  echo "connection.autoconnect-priority $1$m ipv4.route-metric 600 ipv6.route-metric 600"
}

do_net_wlan_ladder() {
  local dry="${DRY_RUN:-1}" file="${NET_WLAN_LADDER_FILE:-$HOME/.config/csi-spl/net-wlan-ladder.tsv}"
  local wifi map uuid rung prio met active got args todo=0 bad=0
  NWL_NMCLI="${NET_NMCLI:-nmcli}" NWL_SUDO="${NET_SUDO-sudo}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  wifi="$(nwl_wifi)"
  [[ -n "$wifi" ]] || echo "NOW no saved Wi-Fi profile"
  if [[ ! -f "$file" ]]; then
    [[ -n "$wifi" ]] && awk '{print "NOW wifi " $1 " priority=" $2 " active=" $3 " rung=unmapped"}' <<<"$wifi"
    [[ "$dry" == 1 ]] || { do_log "FATAL no ladder map at $file"; return 1; }
    echo "PLAN no ladder map at $file: write one '<uuid> <rung>' per line (rungs home, hotspot-a, hotspot-b, travel)"
    do_log "OK DRY_RUN nothing was touched. Write the map, then re-run."; return 0
  fi
  map="$(nwl_map "$file" "$wifi")" || return 1
  [[ -n "$map" ]] || { do_log "FATAL $file maps no profile"; return 1; }
  while read -r uuid prio active; do
    rung="$(awk -v u="$uuid" '$1 == u {print $2}' <<<"$map")"
    echo "NOW wifi $uuid priority=$prio active=$active rung=${rung:-unmapped}"
  done <<<"$wifi"
  while read -r uuid rung; do
    read -r prio met <<<"$(nwl_rung "$rung")"
    got="$(nwl_read "$uuid")"
    if nwl_ok "$got" "$prio" "$met"; then echo "SAME $uuid $rung ($got)"; continue; fi
    args="$(nwl_args "$prio" "$met")" todo=$((todo + 1))
    if [[ "$dry" == 1 ]]; then
      echo "PLAN ${NWL_SUDO:+$NWL_SUDO }$NWL_NMCLI connection modify uuid $uuid $args (now $got)"; continue
    fi
    # shellcheck disable=SC2086 # args is a list of nmcli property/value words
    $NWL_SUDO $NWL_NMCLI connection modify uuid "$uuid" $args || { do_log "FATAL nmcli connection modify uuid $uuid failed"; return 1; }
    got="$(nwl_read "$uuid")"
    if nwl_ok "$got" "$prio" "$met"; then echo "READ $uuid $rung ($got)"
    else do_log "FATAL nmcli reads $uuid as '${got:0:200}', not rung $rung ($prio ${met/#-/any} 600 600)"; bad=$((bad + 1)); fi
  done <<<"$map"
  ((bad == 0)) || return 1
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN $todo profile(s) to change, nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  do_log "OK the Wi-Fi ladder is in place ($(wc -l <<<"$map") profile(s), $todo changed)"
}
