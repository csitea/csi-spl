#!/bin/bash
#------------------------------------------------------------------------------
# @description Turn on NetworkManager's connectivity check on THIS box
# @description (networking round row 02, the networking round plan v1.0
# @description section 4, SPL-2207). With no [connectivity] section NM never
# @description checks, so a Wi-Fi that is associated but has lost its WAN keeps
# @description the default route. With the check on, NM gives the default
# @description route of a device without global connectivity a +20000 metric
# @description penalty (NetworkManager.conf(5), CONNECTIVITY SECTION), so the
# @description kernel fails over to an uplink that still has internet. This
# @description action writes the NM file
# @description   <NET_ROOT>/etc/NetworkManager/conf.d/30-connectivity.conf
# @description   [connectivity]
# @description   uri = http://network-test.debian.org/nm
# @description   interval = 10
# @description   timeout = 5
# @description so an outage is seen within interval + timeout = 15 s. A strict
# @description rp_filter (1) makes the per-device check fail on every device
# @description but the best route (same man page section), so first it asserts
# @description the effective rp_filter, max(conf/all, conf/<dev>), is not 1 on
# @description conf/default and on every uplink nmcli lists (ethernet, wifi,
# @description gsm); a strict one is FATAL and nothing is written or changed.
# @description Then it reloads NM's config (`nmcli general reload conf`; no
# @description connection goes down) and runs the plan's measuring command
# @description `nmcli networking connectivity check`, which must say full.
# @description Nothing is installed and no sysctl is changed.
# @description Dry run unless DRY_RUN=0: prints the state now, the file and the
# @description commands, and writes nothing. Re-running is safe: an identical
# @description file is left as it is. Writing needs sudo (NET_SUDO).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_ROOT (optional, tests) - the target root, default / (empty)
# @param NET_PROC (optional, tests) - default /proc
# @param NET_NMCLI (optional, tests) - default nmcli
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @example ./run -a do_net_connectivity_check
# @example DRY_RUN=0 ./run -a do_net_connectivity_check
#------------------------------------------------------------------------------

# ncc_conf - the conf.d file content, one place
ncc_conf() {
  printf '[connectivity]\nuri = http://network-test.debian.org/nm\ninterval = 10\ntimeout = 5\n'
}

# ncc_uplinks - the ethernet, wifi and gsm devices nmcli lists, one per line
ncc_uplinks() {
  $NCC_NMCLI -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2 ~ /^(ethernet|wifi|gsm)$/ {print $1}'
}

# ncc_rp <name> - conf/<name>/rp_filter, empty when it cannot be read
ncc_rp() { cat "$NCC_PROC/sys/net/ipv4/conf/$1/rp_filter" 2>/dev/null; }

# ncc_rp_check - prints "RP <name>=<effective>" per name; rc 1 when one is 1
ncc_rp_check() {
  local all name v eff bad=0
  all="$(ncc_rp all)"
  [[ "$all" =~ ^[0-2]$ ]] || { echo "RP all=unreadable"; return 1; }
  for name in default $(ncc_uplinks); do
    v="$(ncc_rp "$name")"
    [[ "$v" =~ ^[0-2]$ ]] || { echo "RP $name=unreadable"; bad=1; continue; }
    eff=$((v > all ? v : all))
    echo "RP $name=$eff (all=$all $name=$v)"
    ((eff == 1)) && bad=1
  done
  return $bad
}

do_net_connectivity_check() {
  local dry="${DRY_RUN:-1}" root="${NET_ROOT:-}" file now tmp
  NCC_PROC="${NET_PROC:-/proc}" NCC_NMCLI="${NET_NMCLI:-nmcli}" NCC_SUDO="${NET_SUDO-sudo}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -z "$root" || "$root" == /* ]] || { do_log "FATAL NET_ROOT must be an absolute path, got: '$root'"; return 1; }
  root="${root%/}" file="$root/etc/NetworkManager/conf.d/30-connectivity.conf"
  now="$($NCC_NMCLI networking connectivity 2>/dev/null)"
  echo "NOW connectivity=${now:-unknown} uplinks=$(ncc_uplinks | paste -sd, -)"
  ncc_rp_check || { do_log "FATAL a strict rp_filter (1) or an unreadable one: the per-device check would fail; nothing was written"; return 1; }
  if [[ -f "$file" && "$(cat "$file")" == "$(ncc_conf)" ]]; then
    echo "SAME $file"
  elif [[ "$dry" == 1 ]]; then
    echo "PLAN write $file (0644):"; ncc_conf | sed 's/^/  /'
  else
    tmp="$(mktemp)" && ncc_conf >"$tmp" && $NCC_SUDO install -D -m 0644 "$tmp" "$file" ||
      { rm -f "$tmp"; do_log "FATAL cannot write $file"; return 1; }
    rm -f "$tmp"; echo "WROTE $file"
  fi
  if [[ "$dry" == 1 ]]; then
    echo "PLAN ${NCC_SUDO:+$NCC_SUDO }$NCC_NMCLI general reload conf"
    echo "PLAN $NCC_NMCLI networking connectivity check (must say full)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  $NCC_SUDO $NCC_NMCLI general reload conf || { do_log "FATAL nmcli general reload conf failed"; return 1; }
  now="$($NCC_NMCLI networking connectivity check 2>/dev/null)"
  [[ "$now" == full ]] || { do_log "FATAL nmcli networking connectivity check says '${now:-nothing}', not full"; return 1; }
  do_log "OK connectivity full; $file in place"
}
