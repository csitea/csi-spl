#!/bin/bash
#------------------------------------------------------------------------------
# @description Give every uplink profile on THIS box public resolvers and fast
# @description glibc resolver options (networking round row 07, the networking
# @description round plan v1.0 section 4, SPL-2625). glibc waits `timeout`
# @description (default 5 s) per nameserver for `attempts` (default 2) rounds
# @description (resolv.conf(5)), so a stale DHCP nameserver left over from the
# @description old uplink stalls a lookup for up to 20 s after a switch. Per
# @description saved profile of an uplink type (NET_DNS_TYPES, default
# @description 802-3-ethernet 802-11-wireless gsm) it runs
# @description   nmcli connection modify uuid <uuid> ipv4.dns 8.8.8.8,1.1.1.1
# @description         ipv4.dns-options timeout:2,attempts:2
# @description and reads both back (`nmcli -g <field> connection show uuid
# @description <uuid>`). Only those two properties change: ipv4.ignore-auto-dns
# @description is left as it is, so a DHCP profile keeps its router's DNS after
# @description the public ones (a captive portal still resolves). A profile
# @description already holding both values is left: SAME. Other profile types
# @description (loopback, bridge, vpn, ...) are listed as SKIP and never touched.
# @description Profiles are named by UUID only: a Wi-Fi profile's name is
# @description often its SSID (personal data), so the action never asks nmcli
# @description for NAME.
# @description No connection goes down: an active profile's DNS reaches
# @description /etc/resolv.conf on its next activation, or at once with
# @description NET_DNS_REAPPLY=1 (`nmcli device reapply <device>` per active
# @description uplink profile, only while resolv.conf does not read the target
# @description yet, then the plan's measuring command
# @description `grep -E 'nameserver|options' /etc/resolv.conf` must read
# @description nameserver 8.8.8.8 first and options timeout:2 attempts:2).
# @description Order: row 06 (do_net_dns_pin_and_mask) first. DRY_RUN=0
# @description refuses, prints why and changes nothing while /etc/resolv.conf
# @description is not the symlink to /run/NetworkManager/resolv.conf: NM's
# @description options would not reach the resolver. A dry run says so too.
# @description Dry run unless DRY_RUN=0: prints every profile with what it
# @description holds now and the commands, changes nothing. Re-running is safe.
# @description Nothing is installed. Writing needs sudo (NET_SUDO).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_DNS_REAPPLY (optional) - 1 reapplies the active uplink devices while resolv.conf misses the target; default 0
# @param NET_DNS_TYPES (optional) - the uplink profile types, space separated
# @param NET_ROOT (optional, tests) - the target root, default / (empty)
# @param NET_NMCLI (optional, tests) - default nmcli
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @example ./run -a do_net_dns_fast_failover
# @example DRY_RUN=0 ./run -a do_net_dns_fast_failover
# @example DRY_RUN=0 NET_DNS_REAPPLY=1 ./run -a do_net_dns_fast_failover
#------------------------------------------------------------------------------

NDF_DNS=8.8.8.8,1.1.1.1
NDF_OPTS=timeout:2,attempts:2
NDF_LINK=/run/NetworkManager/resolv.conf

# ndf_profiles - prints "<uuid> <type> <active> <device>" per saved profile
# (the device is - when the profile is not active)
ndf_profiles() {
  $NDF_NMCLI -t -f UUID,TYPE,ACTIVE,DEVICE connection show 2>/dev/null |
    awk -F: 'NF >= 3 {print $1, $2, $3, ($4 == "" ? "-" : $4)}'
}

# ndf_get <uuid> <field> - one property, nmcli's terse escapes undone
ndf_get() {
  $NDF_NMCLI -g "$2" connection show uuid "$1" 2>/dev/null </dev/null | sed -n 1p | sed 's/\\:/:/g; s/\\\\/\\/g'
}

# ndf_sorted <a,b,...> - the comma list sorted, for an order-free compare
ndf_sorted() { tr ',' '\n' <<<"$1" | sed '/^$/d' | sort | paste -sd, -; }

# ndf_ok <dns> <opts> - rc 0 when a profile holds both targets (nameserver
# order matters, option order does not)
ndf_ok() { [[ "$1" == "$NDF_DNS" && "$(ndf_sorted "$2")" == "$(ndf_sorted "$NDF_OPTS")" ]]; }

# ndf_link <root> - where <root>/etc/resolv.conf points, "not a symlink" or "missing"
ndf_link() {
  local f="$1/etc/resolv.conf"
  if [[ -L "$f" ]]; then readlink "$f"
  elif [[ -e "$f" ]]; then echo "not a symlink"
  else echo missing; fi
}

# ndf_resolv_file <root> - the file <root>/etc/resolv.conf resolves to, an
# absolute symlink target taken under <root>
ndf_resolv_file() {
  local f="$1/etc/resolv.conf" t
  t="$(readlink "$f" 2>/dev/null)"
  if [[ "$t" == /* ]]; then echo "$1$t"; else echo "$f"; fi
}

# ndf_resolv_ok <root> - the plan's measuring command; rc 1 unless the first
# nameserver is 8.8.8.8 and the options hold timeout:2 and attempts:2
ndf_resolv_ok() {
  local lines first opts
  lines="$(grep -E 'nameserver|options' "$(ndf_resolv_file "$1")" 2>/dev/null)"
  echo "READ resolv.conf: $(paste -sd'|' - <<<"$lines")"
  first="$(awk '$1 == "nameserver" {print $2; exit}' <<<"$lines")"
  opts=" $(awk '$1 == "options" {$1 = ""; print}' <<<"$lines" | tr '\n' ' ') "
  [[ "$first" == 8.8.8.8 && "$opts" == *" timeout:2 "* && "$opts" == *" attempts:2 "* ]] ||
    { do_log "FATAL resolv.conf reads first nameserver '${first:-none}', options '$(xargs <<<"$opts")': not nameserver 8.8.8.8 + options timeout:2 attempts:2"; return 1; }
}

# ndf_modify <uuid> - the one write, then the read-back; rc 1 on a miss
ndf_modify() {
  local dns opts
  $NDF_SUDO $NDF_NMCLI connection modify uuid "$1" ipv4.dns "$NDF_DNS" ipv4.dns-options "$NDF_OPTS" </dev/null ||
    { do_log "FATAL nmcli connection modify uuid $1 failed"; return 1; }
  dns="$(ndf_get "$1" ipv4.dns)" opts="$(ndf_get "$1" ipv4.dns-options)"
  ndf_ok "$dns" "$opts" ||
    { do_log "FATAL nmcli reads $1 as ipv4.dns='$dns' ipv4.dns-options='$opts', not $NDF_DNS + $NDF_OPTS"; return 1; }
  echo "READ $1 ipv4.dns=$dns ipv4.dns-options=$opts"
}

do_net_dns_fast_failover() {
  local dry="${DRY_RUN:-1}" reapply="${NET_DNS_REAPPLY:-0}" root="${NET_ROOT:-}" types=" ${NET_DNS_TYPES:-802-3-ethernet 802-11-wireless gsm} "
  local list link uuid type active dev dns opts todo=0 n=0 devs=""
  NDF_NMCLI="${NET_NMCLI:-nmcli}" NDF_SUDO="${NET_SUDO-sudo}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$reapply" == 0 || "$reapply" == 1 ]] || { do_log "FATAL NET_DNS_REAPPLY must be 0 or 1, got: '$reapply'"; return 1; }
  [[ -z "$root" || "$root" == /* ]] || { do_log "FATAL NET_ROOT must be an absolute path, got: '$root'"; return 1; }
  root="${root%/}" link="$(ndf_link "$root")"
  echo "NOW resolv.conf -> $link"
  if [[ "$link" != "$NDF_LINK" ]]; then
    [[ "$dry" == 1 ]] ||
      { do_log "FATAL $root/etc/resolv.conf is '$link', not the symlink to $NDF_LINK: run row 06 (do_net_dns_pin_and_mask) first, refusing; nothing was changed"; return 1; }
    echo "NOTE DRY_RUN=0 refuses now: $root/etc/resolv.conf is '$link', not the symlink to $NDF_LINK (row 06 first)"
  fi
  list="$(ndf_profiles)"
  [[ -n "$list" ]] || { do_log "FATAL nmcli lists no saved profile"; return 1; }
  while read -r uuid type active dev; do
    if [[ "$types" != *" $type "* ]]; then echo "SKIP $uuid type=$type (not an uplink type)"; continue; fi
    [[ "$active" == yes && "$dev" != - ]] && devs+="$dev "
    n=$((n + 1)) dns="$(ndf_get "$uuid" ipv4.dns)" opts="$(ndf_get "$uuid" ipv4.dns-options)"
    echo "NOW $uuid type=$type active=$active device=$dev ipv4.dns=${dns:-none} ipv4.dns-options=${opts:-none}"
    if ndf_ok "$dns" "$opts"; then echo "SAME $uuid"; continue; fi
    todo=$((todo + 1))
    if [[ "$dry" == 1 ]]; then
      echo "PLAN ${NDF_SUDO:+$NDF_SUDO }$NDF_NMCLI connection modify uuid $uuid ipv4.dns $NDF_DNS ipv4.dns-options $NDF_OPTS"
    else
      ndf_modify "$uuid" || return 1
    fi
  done <<<"$list"
  ((n > 0)) || { do_log "FATAL no saved profile of an uplink type (${types:1:-1})"; return 1; }
  if [[ -n "$devs" ]] && ndf_resolv_ok "$root" >/dev/null 2>&1; then
    echo "SAME resolv.conf already reads nameserver 8.8.8.8 first + options timeout:2 attempts:2"; devs=""
  fi
  if [[ "$dry" == 1 ]]; then
    [[ "$reapply" == 1 && -n "$devs" ]] && echo "PLAN ${NDF_SUDO:+$NDF_SUDO }$NDF_NMCLI device reapply ${devs% }"
    do_log "OK DRY_RUN $todo of $n uplink profile(s) to change, nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  if [[ "$reapply" == 1 && -n "$devs" ]]; then
    for dev in $devs; do
      $NDF_SUDO $NDF_NMCLI device reapply "$dev" </dev/null || { do_log "FATAL nmcli device reapply $dev failed"; return 1; }
      echo "REAPPLIED $dev"
    done
    ndf_resolv_ok "$root" || return 1
  elif [[ -n "$devs" ]]; then
    echo "PENDING active device(s) ${devs% }: resolv.conf shows the new DNS on the next activation (or re-run with NET_DNS_REAPPLY=1)"
  fi
  do_log "OK every uplink profile holds ipv4.dns $NDF_DNS + ipv4.dns-options $NDF_OPTS ($n profile(s), $todo changed)"
}
