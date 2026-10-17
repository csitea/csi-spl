#!/bin/bash
#------------------------------------------------------------------------------
# @description Pin NetworkManager's DNS mode and mask systemd-resolved on THIS
# @description box (networking round row 06, the networking round plan v1.0
# @description section 4, SPL-2362). systemd-resolved, installed during the
# @description 22-minute hub outage, is disabled or purged (not-found) now;
# @description anything that installs or starts it again can take
# @description /etc/resolv.conf, and NM switches to
# @description resolved on its own when /etc/resolv.conf points at resolved's
# @description stub (NetworkManager.conf(5), dns). This action writes the NM file
# @description   <NET_ROOT>/etc/NetworkManager/conf.d/10-dns-pin.conf
# @description   [main]
# @description   dns = default
# @description   rc-manager = symlink
# @description so today's state (/etc/resolv.conf -> NM's own file) becomes the
# @description declared one, runs `systemctl mask systemd-resolved` so nothing
# @description can start it (a unit that is not installed is masked too: the
# @description /dev/null link in /etc outlives a later reinstall), reloads NM's config (`nmcli general reload conf`;
# @description no connection goes down) and reads it back with the plan's
# @description measuring command: is-enabled reads masked, NetworkManager
# @description --print-config reads dns=default and rc-manager=symlink, and
# @description /etc/resolv.conf is still the symlink to
# @description /run/NetworkManager/resolv.conf.
# @description It refuses, in a dry run too, and changes nothing, unless
# @description /etc/resolv.conf already is that symlink and systemd-resolved is
# @description not running (is-active inactive or failed): pinning a box whose
# @description DNS is elsewhere would repeat the outage, not prevent it.
# @description Nothing is installed or purged; the unit is masked, not removed.
# @description Dry run unless DRY_RUN=0: prints the state now, the file and the
# @description commands, and writes nothing. Re-running is safe: an identical
# @description file and a masked unit are left as they are. Writing needs sudo
# @description (NET_SUDO).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_ROOT (optional, tests) - the target root, default / (empty)
# @param NET_NMCLI (optional, tests) - default nmcli
# @param NET_SYSTEMCTL (optional, tests) - default systemctl
# @param NET_NM (optional, tests) - default /usr/sbin/NetworkManager
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @example ./run -a do_net_dns_pin_and_mask
# @example DRY_RUN=0 ./run -a do_net_dns_pin_and_mask
#------------------------------------------------------------------------------

NDP_LINK=/run/NetworkManager/resolv.conf

# ndp_conf - the conf.d file content, one place
ndp_conf() { printf '[main]\ndns = default\nrc-manager = symlink\n'; }

# ndp_link <root> - where <root>/etc/resolv.conf points, "not a symlink" or "missing"
ndp_link() {
  local f="$1/etc/resolv.conf"
  if [[ -L "$f" ]]; then readlink "$f"
  elif [[ -e "$f" ]]; then echo "not a symlink"
  else echo missing; fi
}

# ndp_unit <is-enabled|is-active> - systemctl's word for systemd-resolved
# (is-enabled and is-active exit non-zero on masked / inactive: read the word)
ndp_unit() { $NDP_SYSTEMCTL "$1" systemd-resolved 2>/dev/null | sed -n 1p; }

# ndp_nm_dns - "dns=<x> rc-manager=<y>" from NetworkManager --print-config
ndp_nm_dns() {
  $NDP_SUDO $NDP_NM --print-config 2>/dev/null |
    awk -F= '/^dns=/ {d = $2} /^rc-manager=/ {r = $2} END {printf "dns=%s rc-manager=%s\n", d, r}'
}

# ndp_precheck <root> - rc 1 (and prints why) unless resolv.conf is NM's
# symlink and systemd-resolved is not running
ndp_precheck() {
  local link active
  link="$(ndp_link "$1")" active="$(ndp_unit is-active)"
  [[ "$link" == "$NDP_LINK" ]] ||
    { do_log "FATAL $1/etc/resolv.conf is '$link', not the symlink to $NDP_LINK: DNS is not NM's, refusing; nothing was changed"; return 1; }
  [[ "$active" == inactive || "$active" == failed ]] ||
    { do_log "FATAL systemd-resolved is '${active:-unknown}', not inactive: refusing; nothing was changed"; return 1; }
  return 0
}

# ndp_verify <root> - the plan's measuring command; rc 1 on any miss
ndp_verify() {
  local en nm link
  en="$(ndp_unit is-enabled)" nm="$(ndp_nm_dns)" link="$(ndp_link "$1")"
  echo "READ is-enabled=${en:-unknown} $nm resolv.conf -> $link"
  [[ "$en" == masked ]] || { do_log "FATAL systemd-resolved is-enabled reads '${en:-nothing}', not masked"; return 1; }
  [[ "$nm" == "dns=default rc-manager=symlink" ]] ||
    { do_log "FATAL NetworkManager --print-config reads '$nm', not dns=default rc-manager=symlink"; return 1; }
  [[ "$link" == "$NDP_LINK" ]] || { do_log "FATAL $1/etc/resolv.conf is now '$link', not the symlink to $NDP_LINK"; return 1; }
  return 0
}

do_net_dns_pin_and_mask() {
  local dry="${DRY_RUN:-1}" root="${NET_ROOT:-}" file tmp en
  NDP_NMCLI="${NET_NMCLI:-nmcli}" NDP_SYSTEMCTL="${NET_SYSTEMCTL:-systemctl}" NDP_NM="${NET_NM:-/usr/sbin/NetworkManager}" NDP_SUDO="${NET_SUDO-sudo}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -z "$root" || "$root" == /* ]] || { do_log "FATAL NET_ROOT must be an absolute path, got: '$root'"; return 1; }
  root="${root%/}" file="$root/etc/NetworkManager/conf.d/10-dns-pin.conf"
  en="$(ndp_unit is-enabled)"
  echo "NOW resolv.conf -> $(ndp_link "$root") systemd-resolved is-active=$(ndp_unit is-active) is-enabled=${en:-unknown}"
  ndp_precheck "$root" || return 1
  if [[ -f "$file" && "$(cat "$file")" == "$(ndp_conf)" ]]; then
    echo "SAME $file"
  elif [[ "$dry" == 1 ]]; then
    echo "PLAN write $file (0644):"; ndp_conf | sed 's/^/  /'
  else
    tmp="$(mktemp)" && ndp_conf >"$tmp" && $NDP_SUDO install -D -m 0644 "$tmp" "$file" ||
      { rm -f "$tmp"; do_log "FATAL cannot write $file"; return 1; }
    rm -f "$tmp"; echo "WROTE $file"
  fi
  if [[ "$en" == masked ]]; then
    echo "SAME systemd-resolved masked"
  elif [[ "$dry" == 1 ]]; then
    echo "PLAN ${NDP_SUDO:+$NDP_SUDO }$NDP_SYSTEMCTL mask systemd-resolved"
  else
    $NDP_SUDO $NDP_SYSTEMCTL mask systemd-resolved || { do_log "FATAL systemctl mask systemd-resolved failed"; return 1; }
    echo "MASKED systemd-resolved"
  fi
  if [[ "$dry" == 1 ]]; then
    echo "PLAN ${NDP_SUDO:+$NDP_SUDO }$NDP_NMCLI general reload conf"
    echo "PLAN read back: is-enabled masked; NetworkManager --print-config dns=default rc-manager=symlink; resolv.conf -> $NDP_LINK"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  $NDP_SUDO $NDP_NMCLI general reload conf || { do_log "FATAL nmcli general reload conf failed"; return 1; }
  ndp_verify "$root" || return 1
  do_log "OK NM DNS pinned (dns=default, rc-manager=symlink), systemd-resolved masked, resolv.conf -> $NDP_LINK"
}
