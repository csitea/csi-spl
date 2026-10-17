#!/bin/bash
#------------------------------------------------------------------------------
# @description Give THIS box a persistent wired profile that wins the default
# @description route (networking round row 03, the networking round plan v1.0
# @description section 4, SPL-2288). The only wired profile NM has is its
# @description in-memory auto-default "Wired connection 1" (/run, priority
# @description -999). This action writes the NM keyfile
# @description   <NET_ROOT>/etc/NetworkManager/system-connections/wired-default.nmconnection
# @description bound to the wired NIC, autoconnect = yes, autoconnect-priority
# @description = 100, ipv4 and ipv6 method = auto with route-metric = 100, so
# @description a cable insert brings it up ahead of Wi-Fi (600) and the USB
# @description tether (650). The keyfile is mode 0600, as NM ignores a
# @description keyfile that group or others can read (nm-settings-keyfile(5)).
# @description Then it loads it (`nmcli connection reload`; no connection goes
# @description down) and reads it back with the plan's measuring command
# @description (`nmcli ... connection show wired-default`): 100, 100, 100.
# @description With a cable in, it also activates the profile on the NIC (only
# @description the wired link re-does DHCP, Wi-Fi stays up) and proves the
# @description routes: an IPv4 default via the NIC at metric 100 that is the
# @description lowest metric of all defaults, and the same for IPv6 when the
# @description wired network gives an IPv6 default (none: WARN). That is the
# @description case of the field fence: Wi-Fi gone while wired is up, the
# @description default goes via the NIC at once. With no cable it says so;
# @description autoconnect does the rest on insert.
# @description Nothing is installed; no other profile is changed.
# @description Dry run unless DRY_RUN=0: prints the state now, the file and the
# @description commands, and writes nothing. Re-running is safe: an identical
# @description file is left as it is. Writing needs sudo (NET_SUDO).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_WIRED_IFACE (optional) - the wired NIC, default enp0s31f6 (the plan)
# @param NET_WAIT (optional) - seconds to wait for the routes, default 10
# @param NET_ROOT (optional, tests) - the target root, default / (empty)
# @param NET_SYS (optional, tests) - default /sys
# @param NET_NMCLI (optional, tests) - default nmcli
# @param NET_IP (optional, tests) - default ip
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @example ./run -a do_net_wired_priority
# @example DRY_RUN=0 ./run -a do_net_wired_priority
#------------------------------------------------------------------------------

# nwp_conf <iface> - the keyfile content, one place
nwp_conf() {
  printf '[connection]\nid = wired-default\ntype = ethernet\ninterface-name = %s\nautoconnect = yes\nautoconnect-priority = 100\n\n[ipv4]\nmethod = auto\nroute-metric = 100\n\n[ipv6]\nmethod = auto\nroute-metric = 100\n' "$1"
}

# nwp_state <iface> - the NIC's nmcli state (connected, unavailable, ...)
nwp_state() { $NWP_NMCLI -t -f DEVICE,STATE dev 2>/dev/null | awk -F: -v d="$1" '$1 == d {print $2; exit}'; }

# nwp_carrier <iface> - 1 with a cable in
nwp_carrier() { cat "$NWP_SYS/class/net/$1/carrier" 2>/dev/null; }

# nwp_route <4|6> <iface> - prints "ROUTE v<f> ..."; rc 0 when a default via
# <iface> has metric 100 and every other default a higher one, 2 when there is
# no default via <iface>, else 1
nwp_route() {
  $NWP_IP -"$1" route show default 2>/dev/null | awk -v d="$2" -v f="$1" '
    { m = 0; dv = ""
      for (i = 1; i < NF; i++) { if ($i == "metric") m = $(i + 1) + 0; if ($i == "dev") dv = $(i + 1) }
      if (dv == d) { if (own == "" || m < own) own = m } else if (best == "" || m < best) { best = m; bdev = dv } }
    END {
      if (own == "") { print "ROUTE v" f " none via " d; exit 2 }
      printf "ROUTE v%s %s metric %s", f, d, own
      if (best != "") printf " (next %s metric %s)", bdev, best
      print ""
      exit !(own == 100 && (best == "" || best > own)) }'
}

# nwp_wait_routes <iface> - IPv4 must win; IPv6 must win when it exists
nwp_wait_routes() {
  local dev="$1" i rc4 rc6 out4 out6
  for ((i = 0; ; i++)); do
    out4="$(nwp_route 4 "$dev")"; rc4=$?
    out6="$(nwp_route 6 "$dev")"; rc6=$?
    ((rc4 == 0 && rc6 != 1)) && break
    ((i >= NWP_WAIT)) && break
    sleep 1
  done
  echo "$out4"; echo "$out6"
  ((rc4 == 0)) || { do_log "FATAL no IPv4 default via $dev at metric 100 ahead of the others after ${NWP_WAIT}s"; return 1; }
  ((rc6 == 1)) && { do_log "FATAL the IPv6 default via $dev is not metric 100 ahead of the others"; return 1; }
  ((rc6 == 2)) && echo "WARN no IPv6 default via $dev: the wired network gives none"
  return 0
}

do_net_wired_priority() {
  local dry="${DRY_RUN:-1}" root="${NET_ROOT:-}" dev="${NET_WIRED_IFACE:-enp0s31f6}" file state carrier tmp got
  NWP_SYS="${NET_SYS:-/sys}" NWP_NMCLI="${NET_NMCLI:-nmcli}" NWP_IP="${NET_IP:-ip}" NWP_SUDO="${NET_SUDO-sudo}" NWP_WAIT="${NET_WAIT:-10}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -z "$root" || "$root" == /* ]] || { do_log "FATAL NET_ROOT must be an absolute path, got: '$root'"; return 1; }
  [[ "$NWP_WAIT" =~ ^[0-9]+$ ]] || { do_log "FATAL NET_WAIT must be a whole number of seconds, got: '$NWP_WAIT'"; return 1; }
  [[ "$dev" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL NET_WIRED_IFACE is not an interface name: '$dev'"; return 1; }
  [[ -e "$NWP_SYS/class/net/$dev/device" ]] ||
    { do_log "FATAL no wired NIC $dev on this box (no $NWP_SYS/class/net/$dev/device); set NET_WIRED_IFACE"; return 1; }
  root="${root%/}" file="$root/etc/NetworkManager/system-connections/wired-default.nmconnection"
  state="$(nwp_state "$dev")" carrier="$(nwp_carrier "$dev")"
  echo "NOW $dev state=${state:-unknown} carrier=${carrier:-unknown}"
  $NWP_IP -4 route show default 2>/dev/null | sed 's/^/NOW v4 /'
  $NWP_IP -6 route show default 2>/dev/null | sed 's/^/NOW v6 /'
  if [[ -f "$file" && "$(cat "$file")" == "$(nwp_conf "$dev")" ]]; then
    echo "SAME $file"
  elif [[ "$dry" == 1 ]]; then
    echo "PLAN write $file (0600):"; nwp_conf "$dev" | sed 's/^/  /'
  else
    tmp="$(mktemp)" && nwp_conf "$dev" >"$tmp" && $NWP_SUDO install -D -m 0600 "$tmp" "$file" ||
      { rm -f "$tmp"; do_log "FATAL cannot write $file"; return 1; }
    rm -f "$tmp"; echo "WROTE $file"
  fi
  if [[ "$dry" == 1 ]]; then
    echo "PLAN ${NWP_SUDO:+$NWP_SUDO }$NWP_NMCLI connection reload"
    echo "PLAN $NWP_NMCLI -g connection.autoconnect-priority,ipv4.route-metric,ipv6.route-metric connection show wired-default (must read 100 100 100)"
    if [[ "$carrier" == 1 ]]; then
      echo "PLAN ${NWP_SUDO:+$NWP_SUDO }$NWP_NMCLI connection up wired-default ifname $dev, then the default routes via $dev must be metric 100, lowest"
    else
      echo "PLAN no cable in $dev: nothing to activate; autoconnect brings wired-default up on insert"
    fi
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  $NWP_SUDO $NWP_NMCLI connection reload || { do_log "FATAL nmcli connection reload failed"; return 1; }
  got="$($NWP_NMCLI -g connection.autoconnect-priority,ipv4.route-metric,ipv6.route-metric connection show wired-default 2>&1)"
  [[ "$got" == $'100\n100\n100' ]] ||
    { got="${got//$'\n'/ } "; do_log "FATAL nmcli reads wired-default as '${got:0:300}', not 100 100 100"; return 1; }
  echo "READ wired-default autoconnect-priority=100 ipv4.route-metric=100 ipv6.route-metric=100"
  if [[ "$carrier" != 1 ]]; then
    do_log "OK wired-default in place; no cable in $dev, so the route proof waits for a cable insert"; return 0
  fi
  $NWP_SUDO $NWP_NMCLI connection up wired-default ifname "$dev" || { do_log "FATAL nmcli connection up wired-default ifname $dev failed"; return 1; }
  nwp_wait_routes "$dev" || return 1
  do_log "OK wired-default up on $dev; its default route has metric 100, ahead of every other uplink"
}
