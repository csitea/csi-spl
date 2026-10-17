#!/bin/bash
#------------------------------------------------------------------------------
# @description Give THIS box a persistent USB-tether profile that is a metered
# @description backup uplink (networking round row 04, the networking round
# @description plan v1.0 section 4, SPL-2292). On Debian 13 a tethered phone
# @description gets a path name (en...u<port>), never usb* or enx*, so the
# @description profile matches by driver, not by name. This action writes the
# @description NM keyfile
# @description   <NET_ROOT>/etc/NetworkManager/system-connections/usb-tether.nmconnection
# @description type ethernet, autoconnect = yes, autoconnect-priority = 50,
# @description metered, [match] driver = rndis_host;cdc_ncm;cdc_ether;ipheth;
# @description huawei_cdc_ncm;, ipv4 and ipv6 method = auto with route-metric
# @description = 650: behind Wi-Fi (600), so phone data is used only when
# @description Wi-Fi is gone or carries the +20000 no-internet penalty (row 02).
# @description metered is written as 1, the keyfile form of yes: NM 1.52.1's
# @description keyfile reader silently drops the plan's "metered = yes"
# @description (nmcli --offline connection modify on the plan's text prints no
# @description metered line; with "metered = 1" it prints metered=1).
# @description The keyfile is mode 0600, as NM ignores a keyfile that group or
# @description others can read (nm-settings-keyfile(5)).
# @description Then it loads it (`nmcli connection reload`; no connection goes
# @description down) and reads it back (`nmcli -g ... connection show
# @description usb-tether`): 50, yes, the five drivers, 650, 650.
# @description With a phone plugged in (a /sys/class/net/<if> whose
# @description device/driver is one of the five), it activates the profile on
# @description it (only that link re-does DHCP, Wi-Fi stays up) and proves the
# @description routes: an IPv4 default via the tether at metric 650, and the
# @description same for IPv6 when the phone gives an IPv6 default (none: WARN);
# @description it says whether the tether is the backup (a lower-metric default
# @description exists, e.g. Wi-Fi 600) or carries the traffic (no lower one).
# @description With no phone it says so; autoconnect brings the profile up on
# @description plug-in. Note: a USB Ethernet dongle on cdc_ether also matches.
# @description Nothing is installed; no other profile is changed.
# @description Dry run unless DRY_RUN=0: prints the state now, the file and the
# @description commands, and writes nothing. Re-running is safe: an identical
# @description file is left as it is. Writing needs sudo (NET_SUDO).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_WAIT (optional) - seconds to wait for the routes, default 10
# @param NET_ROOT (optional, tests) - the target root, default / (empty)
# @param NET_SYS (optional, tests) - default /sys
# @param NET_NMCLI (optional, tests) - default nmcli
# @param NET_IP (optional, tests) - default ip
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @example ./run -a do_net_usb_tether_profiles
# @example DRY_RUN=0 ./run -a do_net_usb_tether_profiles
#------------------------------------------------------------------------------

NUT_DRIVERS='rndis_host cdc_ncm cdc_ether ipheth huawei_cdc_ncm'

# nut_conf - the keyfile content, one place
nut_conf() {
  printf '[connection]\nid = usb-tether\ntype = ethernet\nautoconnect = yes\nautoconnect-priority = 50\nmetered = 1\n\n[match]\ndriver = %s;\n\n[ipv4]\nmethod = auto\nroute-metric = 650\n\n[ipv6]\nmethod = auto\nroute-metric = 650\n' "${NUT_DRIVERS// /;}"
}

# nut_tethers - prints "<if> <driver>" for each interface on a tether driver
nut_tethers() {
  local d drv
  for d in "$NUT_SYS"/class/net/*; do
    drv="$(readlink "$d/device/driver" 2>/dev/null)" || continue
    drv="${drv##*/}"
    [[ " $NUT_DRIVERS " == *" $drv "* ]] && echo "${d##*/} $drv"
  done
  return 0
}

# nut_state <iface> - the interface's nmcli state (connected, disconnected, ...)
nut_state() { $NUT_NMCLI -t -f DEVICE,STATE dev 2>/dev/null | awk -F: -v d="$1" '$1 == d {print $2; exit}'; }

# nut_route <4|6> <iface> - prints "ROUTE v<f> ..."; rc 0 when a default via
# <iface> has metric 650, 2 when there is no default via <iface>, else 1
nut_route() {
  $NUT_IP -"$1" route show default 2>/dev/null | awk -v d="$2" -v f="$1" '
    { m = 0; dv = ""
      for (i = 1; i < NF; i++) { if ($i == "metric") m = $(i + 1) + 0; if ($i == "dev") dv = $(i + 1) }
      if (dv == d) { if (own == "" || m < own) own = m } else if (best == "" || m < best) { best = m; bdev = dv } }
    END {
      if (own == "") { print "ROUTE v" f " none via " d; exit 2 }
      printf "ROUTE v%s %s metric %s", f, d, own
      if (best != "" && best < own) printf ", backup behind %s metric %s", bdev, best
      else printf ", carries the traffic"
      if (best != "" && best >= own) printf " (next %s metric %s)", bdev, best
      print ""
      exit !(own == 650) }'
}

# nut_wait_routes <iface> - IPv4 must be 650; IPv6 must be 650 when it exists
nut_wait_routes() {
  local dev="$1" i rc4 rc6 out4 out6
  for ((i = 0; ; i++)); do
    out4="$(nut_route 4 "$dev")"; rc4=$?
    out6="$(nut_route 6 "$dev")"; rc6=$?
    ((rc4 == 0 && rc6 != 1)) && break
    ((i >= NUT_WAIT)) && break
    sleep 1
  done
  echo "$out4"; echo "$out6"
  ((rc4 == 0)) || { do_log "FATAL no IPv4 default via $dev at metric 650 after ${NUT_WAIT}s"; return 1; }
  ((rc6 == 1)) && { do_log "FATAL the IPv6 default via $dev is not metric 650"; return 1; }
  ((rc6 == 2)) && echo "WARN no IPv6 default via $dev: the phone gives none"
  return 0
}

do_net_usb_tether_profiles() {
  local dry="${DRY_RUN:-1}" root="${NET_ROOT:-}" file tethers dev drv tmp got want t0
  NUT_SYS="${NET_SYS:-/sys}" NUT_NMCLI="${NET_NMCLI:-nmcli}" NUT_IP="${NET_IP:-ip}" NUT_SUDO="${NET_SUDO-sudo}" NUT_WAIT="${NET_WAIT:-10}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -z "$root" || "$root" == /* ]] || { do_log "FATAL NET_ROOT must be an absolute path, got: '$root'"; return 1; }
  [[ "$NUT_WAIT" =~ ^[0-9]+$ ]] || { do_log "FATAL NET_WAIT must be a whole number of seconds, got: '$NUT_WAIT'"; return 1; }
  root="${root%/}" file="$root/etc/NetworkManager/system-connections/usb-tether.nmconnection"
  tethers="$(nut_tethers)"
  if [[ -z "$tethers" ]]; then
    echo "NOW no USB tether plugged in (no interface on $NUT_DRIVERS)"
  else
    while read -r dev drv; do echo "NOW tether $dev driver=$drv state=$(nut_state "$dev")"; done <<<"$tethers"
  fi
  $NUT_IP -4 route show default 2>/dev/null | sed 's/^/NOW v4 /'
  $NUT_IP -6 route show default 2>/dev/null | sed 's/^/NOW v6 /'
  if [[ -f "$file" && "$(cat "$file")" == "$(nut_conf)" ]]; then
    echo "SAME $file"
  elif [[ "$dry" == 1 ]]; then
    echo "PLAN write $file (0600):"; nut_conf | sed 's/^/  /'
  else
    tmp="$(mktemp)" && nut_conf >"$tmp" && $NUT_SUDO install -D -m 0600 "$tmp" "$file" ||
      { rm -f "$tmp"; do_log "FATAL cannot write $file"; return 1; }
    rm -f "$tmp"; echo "WROTE $file"
  fi
  dev="${tethers%%$'\n'*}" dev="${dev%% *}"
  if [[ "$dry" == 1 ]]; then
    echo "PLAN ${NUT_SUDO:+$NUT_SUDO }$NUT_NMCLI connection reload"
    echo "PLAN $NUT_NMCLI -g connection.autoconnect-priority,connection.metered,match.driver,ipv4.route-metric,ipv6.route-metric connection show usb-tether (must read 50 yes ${NUT_DRIVERS// /,} 650 650)"
    if [[ -n "$dev" ]]; then
      echo "PLAN ${NUT_SUDO:+$NUT_SUDO }$NUT_NMCLI connection up usb-tether ifname $dev, then the default routes via $dev must be metric 650"
    else
      echo "PLAN no USB tether plugged in: nothing to activate; autoconnect brings usb-tether up on plug-in"
    fi
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  $NUT_SUDO $NUT_NMCLI connection reload || { do_log "FATAL nmcli connection reload failed"; return 1; }
  got="$($NUT_NMCLI -g connection.autoconnect-priority,connection.metered,match.driver,ipv4.route-metric,ipv6.route-metric connection show usb-tether 2>&1)"
  got="$(tr ',;\n' '   ' <<<"$got" | tr -s ' ')" got="${got% }"
  want="50 yes $NUT_DRIVERS 650 650"
  [[ "$got" == "$want" ]] || { do_log "FATAL nmcli reads usb-tether as '${got:0:300}', not '$want'"; return 1; }
  echo "READ usb-tether autoconnect-priority=50 metered=yes match.driver=${NUT_DRIVERS// /,} ipv4.route-metric=650 ipv6.route-metric=650"
  if [[ -z "$dev" ]]; then
    do_log "OK usb-tether in place; no USB tether plugged in, so the route proof waits for a phone"; return 0
  fi
  t0="$SECONDS"
  $NUT_SUDO $NUT_NMCLI connection up usb-tether ifname "$dev" || { do_log "FATAL nmcli connection up usb-tether ifname $dev failed"; return 1; }
  nut_wait_routes "$dev" || return 1
  echo "UP usb-tether on $dev, routes in $((SECONDS - t0))s"
  do_log "OK usb-tether up on $dev; its default route has metric 650, metered"
}
