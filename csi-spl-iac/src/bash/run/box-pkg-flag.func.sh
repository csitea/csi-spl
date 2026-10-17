#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Spec 142 section 5.3, row B2: the service-takeover check. Pure:
# @description input the `apt-get -s install` text, the service map and the
# @description box's current owners; output one line per takeover:
# @description   FLAG <service> <pkg> <current owner> -> <new owner>
# @description A closure `Inst` package that is a candidate for a service whose
# @description current owner is another package is a takeover; so is a `Remv`
# @description of the current owner. Installing the package that already owns
# @description the service is not (sat + systemd-resolved). A `libnss-<m>`
# @description package of the dns service is checked against the `hosts:` line
# @description of nsswitch.conf instead: flagged when <m> is not on it.
# @description Owners match a package by name, case and punctuation ignored
# @description (NetworkManager = network-manager). Read-only, any user; it
# @description flags, it never blocks: exit 0 with or without FLAG lines.
# @param BOX_PKG_SIM (required) - file with the `apt-get -s install` output
# @param BOX_PKG_SERVICES (required) - the map, cnf env.box.pkg_services: one
# @param        line per service, `<service>: <candidate pkg> ...`
# @param BOX_PKG_OWNERS (optional) - the probes' result, one `<service> <owner>`
# @param        line per service plus `nsswitch-hosts <modules>`; default: the
# @param        probes of _box_pkg_probe_owners on this box
# @param BOX_PKG_ROOT (optional) - root the probes read files under, default /
# @example BOX_PKG_SIM=sim.txt BOX_PKG_SERVICES="$map" ./run -a do_box_pkg_flag
#------------------------------------------------------------------------------

# _box_pkg_norm <name>: lowercase, letters and digits only
_box_pkg_norm() {
  local n="${1,,}"
  printf '%s\n' "${n//[^a-z0-9]/}"
}

# _box_pkg_unit <pkg>: the systemd unit that shows the package runs ("" = none)
_box_pkg_unit() {
  case "$1" in
    network-manager) echo NetworkManager ;;
    ifupdown) echo networking ;;
    connman|dhcpcd|systemd-networkd|ufw|firewalld|nftables|dropbear) echo "$1" ;;
    iptables-persistent) echo netfilter-persistent ;;
    openssh-server) echo ssh ;;
    *) echo "" ;;
  esac
}

# _box_pkg_dns_owner <root>: who writes resolv.conf, from where its link points
_box_pkg_dns_owner() {
  local f="$1/etc/resolv.conf" t
  [[ -L "$f" ]] || { echo file; return 0; }
  t="$(readlink "$f")"
  case "$t" in
    */NetworkManager/*) echo NetworkManager ;;
    */systemd/resolve/*) echo systemd-resolved ;;
    */resolvconf/*) echo resolvconf ;;
    */openresolv/*) echo openresolv ;;
    *) echo "link:$t" ;;
  esac
}

# _box_pkg_init_owner <root>: the package of the running /sbin/init
_box_pkg_init_owner() {
  local t
  t="$(readlink -f "$1/sbin/init" 2>/dev/null || true)"
  case "${t##*/}" in
    systemd) echo systemd-sysv ;;
    init) echo sysvinit-core ;;
    openrc-init) echo openrc ;;
    runit-init|runit) echo runit-init ;;
    *) echo none ;;
  esac
}

# _box_pkg_probe_owners <map> <root>: `<service> <owner>` lines for this box
_box_pkg_probe_owners() {
  local map="$1" root="$2" svc pkgs p u owner hosts
  while IFS=: read -r svc pkgs; do
    svc="${svc//[[:space:]]/}"
    [[ -n "$svc" && "$svc" != \#* ]] || continue
    case "$svc" in
      dns) echo "dns $(_box_pkg_dns_owner "$root")"; continue ;;
      init) echo "init $(_box_pkg_init_owner "$root")"; continue ;;
    esac
    owner=none
    for p in $pkgs; do
      u="$(_box_pkg_unit "$p")"
      if [[ -n "$u" ]] && systemctl is-active --quiet "$u"; then owner="$p"; break; fi
    done
    echo "$svc $owner"
  done <<< "$map"
  hosts="$(sed -n '/^hosts:/{s/^hosts:[[:space:]]*//p;q}' "$root/etc/nsswitch.conf" 2>/dev/null)"
  echo "nsswitch-hosts $hosts"
}

# _box_pkg_flag_nss <pkg> <hosts modules>: the nsswitch takeover of a libnss-<m>
_box_pkg_flag_nss() {
  local mod="${1#libnss-}" m cur=""
  for m in $2; do
    [[ "$m" == "$mod" ]] && return 0
    [[ "$m" == files || "$m" == \[* ]] || cur="${cur:+$cur,}$m"
  done
  echo "FLAG dns $1 nsswitch:${cur:-none} -> $mod"
}

# _box_pkg_flag_lines <sim> <map> <owners>: the FLAG lines, in sim order
_box_pkg_flag_lines() {
  local sim="$1" map="$2" owners="$3" op pkg svc pkgs owner hosts
  hosts="$(awk '$1 == "nsswitch-hosts" { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$owners")"
  while read -r op pkg _; do
    [[ "$op" == Inst || "$op" == Remv ]] || continue
    while IFS=: read -r svc pkgs; do
      svc="${svc//[[:space:]]/}"
      [[ -n "$svc" && "$svc" != \#* && " $pkgs " == *" $pkg "* ]] || continue
      if [[ "$svc" == dns && "$pkg" == libnss-* ]]; then
        [[ "$op" == Inst ]] && _box_pkg_flag_nss "$pkg" "$hosts"
        continue
      fi
      owner="$(awk -v s="$svc" '$1 == s { print $2; exit }' <<< "$owners")"
      owner="${owner:-none}"
      [[ "$owner" == none ]] && continue
      if [[ "$op" == Inst ]]; then
        [[ "$(_box_pkg_norm "$owner")" == "$(_box_pkg_norm "$pkg")" ]] ||
          echo "FLAG $svc $pkg $owner -> $pkg"
      elif [[ "$(_box_pkg_norm "$owner")" == "$(_box_pkg_norm "$pkg")" ]]; then
        echo "FLAG $svc $pkg $owner -> none"
      fi
    done <<< "$map"
  done < "$sim"
}

do_box_pkg_flag() {
  local sim="${BOX_PKG_SIM:-}" map="${BOX_PKG_SERVICES:-}" owners
  [[ -n "$sim" && -r "$sim" ]] || { echo "ERROR: BOX_PKG_SIM must name a readable apt-get -s output file" >&2; return 2; }
  [[ -n "$map" ]] || { echo "ERROR: BOX_PKG_SERVICES must be set (cnf env.box.pkg_services)" >&2; return 2; }
  owners="${BOX_PKG_OWNERS:-}"
  [[ -n "$owners" ]] || owners="$(_box_pkg_probe_owners "$map" "${BOX_PKG_ROOT:-}")"
  _box_pkg_flag_lines "$sim" "$map" "$owners"
}
