#!/bin/bash
#------------------------------------------------------------------------------
# @description Turn Wi-Fi power save off on THIS box (networking round row 01,
# @description the networking round plan v1.0 section 4, SPL-2205).
# @description The iwlwifi driver runs power_scheme=2 and NetworkManager leaves
# @description it alone while wifi.powersave is unset ("ignore"), so 802.11
# @description power save stays on. This action writes the NM default
# @description   <NET_ROOT>/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf
# @description   [connection]
# @description   wifi.powersave = 2
# @description (2 = disable, nm-settings-nmcli(5)), reloads NM's config
# @description (`nmcli general reload conf`; no connection goes down) and sets
# @description the runtime value at once with `iw dev <wlan> set power_save off`,
# @description then reads it back: `iw dev <wlan> get power_save` must say off.
# @description Without iw on the box the file still lands and NM applies it at
# @description the next activation of the Wi-Fi connection; nothing is
# @description installed. It costs some battery (fine on a mostly-mains laptop).
# @description Dry run unless DRY_RUN=0: prints the state now, the file and the
# @description commands, and writes nothing. Re-running is safe: an identical
# @description file is left as it is. Writing needs sudo (NET_SUDO).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_WLAN (optional) - the Wi-Fi interface; default the first nmcli
# @param   device of type wifi
# @param NET_ROOT (optional, tests) - the target root, default / (empty)
# @param NET_IW (optional, tests) - default /usr/sbin/iw
# @param NET_NMCLI (optional, tests) - default nmcli
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @example ./run -a do_net_powersave_off
# @example DRY_RUN=0 ./run -a do_net_powersave_off
#------------------------------------------------------------------------------

# nps_conf - the conf.d file content, one place
nps_conf() { printf '[connection]\nwifi.powersave = 2\n'; }

# nps_wlan - NET_WLAN, else the first wifi device nmcli lists (empty: none)
nps_wlan() {
  [[ -n "${NET_WLAN:-}" ]] && { echo "$NET_WLAN"; return 0; }
  $NPS_NMCLI -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2 == "wifi" {print $1; exit}'
}

# nps_get <wlan> - "on" / "off" from iw, empty when iw cannot tell
nps_get() {
  [[ -x "$NPS_IW" ]] || return 0
  "$NPS_IW" dev "$1" get power_save 2>/dev/null | awk -F': *' '/Power save/ {print $2; exit}'
}

do_net_powersave_off() {
  local dry="${DRY_RUN:-1}" root="${NET_ROOT:-}" file wlan now="" tmp
  NPS_IW="${NET_IW:-/usr/sbin/iw}" NPS_NMCLI="${NET_NMCLI:-nmcli}" NPS_SUDO="${NET_SUDO-sudo}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -z "$root" || "$root" == /* ]] || { do_log "FATAL NET_ROOT must be an absolute path, got: '$root'"; return 1; }
  root="${root%/}" file="$root/etc/NetworkManager/conf.d/20-wifi-powersave-off.conf"
  wlan="$(nps_wlan)"
  [[ -x "$NPS_IW" ]] || echo "WARN $NPS_IW not found: the runtime value is not set now, NM applies the file at the next Wi-Fi activation (nothing is installed)"
  [[ -z "$wlan" ]] && echo "WARN no Wi-Fi device found (NET_WLAN unset, nmcli lists no wifi device)"
  [[ -n "$wlan" ]] && now="$(nps_get "$wlan")"
  echo "NOW wlan=${wlan:-none} power_save=${now:-unknown}"
  if [[ -f "$file" && "$(cat "$file")" == "$(nps_conf)" ]]; then
    echo "SAME $file"
  elif [[ "$dry" == 1 ]]; then
    echo "PLAN write $file (0644):"; nps_conf | sed 's/^/  /'
  else
    tmp="$(mktemp)" && nps_conf >"$tmp" && $NPS_SUDO install -D -m 0644 "$tmp" "$file" ||
      { rm -f "$tmp"; do_log "FATAL cannot write $file"; return 1; }
    rm -f "$tmp"; echo "WROTE $file"
  fi
  if [[ "$dry" == 1 ]]; then
    echo "PLAN ${NPS_SUDO:+$NPS_SUDO }$NPS_NMCLI general reload conf"
    [[ -n "$wlan" && -x "$NPS_IW" ]] && echo "PLAN ${NPS_SUDO:+$NPS_SUDO }$NPS_IW dev $wlan set power_save off"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  $NPS_SUDO $NPS_NMCLI general reload conf || { do_log "FATAL nmcli general reload conf failed"; return 1; }
  [[ -n "$wlan" && -x "$NPS_IW" ]] || { do_log "OK $file in place; runtime value not checked (see WARN)"; return 0; }
  $NPS_SUDO "$NPS_IW" dev "$wlan" set power_save off || { do_log "FATAL iw dev $wlan set power_save off failed"; return 1; }
  now="$(nps_get "$wlan")"
  [[ "$now" == off ]] || { do_log "FATAL iw dev $wlan get power_save reads '${now:-nothing}', not off"; return 1; }
  do_log "OK $wlan Power save: off; $file in place"
}
