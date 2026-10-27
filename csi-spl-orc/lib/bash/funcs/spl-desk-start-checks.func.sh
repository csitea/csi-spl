#!/bin/bash
#------------------------------------------------------------------------------
# The desk start checks of spec 127 5.3 / 5.4, with spec 159 5.2's one
# exception (owner HUM-10, Q-1 B, msg 2e9d03be): on a fleet box the fleet's
# own agent user is root-equivalent, so "no OS user on the box is
# root-equivalent" is not required there. What stays, each one refusing the
# desk start when it fails:
#   groups     no workspace OS user (<workspace_user_prefix>*) and not the
#              desk's own user is in sudo, wheel, admin, docker, lxd or disk
#   sudoers    the desk's own user has no sudo grant (`sudo -n -l`)
#   hidepid    /proc mounted hidepid=2 (or =invisible), no gid= exemption
#              naming a group of the desk's user
#   ptrace     kernel.yama.ptrace_scope >= 2
#   dumpable   fs.suid_dumpable = 0, kernel.core_pattern a file path or
#              systemd-coredump
#   swap       no plain swap: zram or a dm-crypt device only
#   runtime    /run/user/<uid> is tmpfs, owned by the desk's user, 0700
# They read only files every user can read. Each input is a variable so a test
# runs them on fixtures (defaults are the live files):
#   SPL_DSC_GROUP (/etc/group)  SPL_DSC_PASSWD (/etc/passwd)
#   SPL_DSC_MOUNTS (/proc/mounts)  SPL_DSC_SYSCTL (/proc/sys)
#   SPL_DSC_SWAPS (/proc/swaps)  SPL_DSC_SYS (/sys)
#   SPL_DSC_RUNTIME (/run/user/<uid>)
# The desk's own guard (spl_box_ws_guard) runs them for a workspace hosted on
# a fleet box (do_spl_fleet_ws_host, spec 159 T3).
#------------------------------------------------------------------------------

SPL_DSC_ROOT_GROUPS="sudo wheel admin docker lxd disk"

# spl_desk_start_checks <user> <workspace user prefix>: 0 when every check
# passes; else one "REFUSED <check>: <why>" line per failure and 1.
spl_desk_start_checks() {
  local u="$1" prefix="$2" bad=0 c
  for c in groups sudoers hidepid ptrace dumpable swap runtime; do
    "spl_dsc_$c" "$u" "$prefix" || bad=1
  done
  (( bad == 0 )) || { do_log "FATAL the desk start checks refused (spec 127 5.3, spec 159 5.2): fix the box, then start the desk again"; return 1; }
  do_log "OK desk start checks pass for $u (spec 127 5.3; the fleet agent user is exempt, spec 159 5.2)"
}

spl_dsc_refuse() { do_log "REFUSED $1: $2"; return 1; }

# spl_dsc_gid_of <user>: the primary gid in SPL_DSC_PASSWD.
spl_dsc_gid_of() {
  awk -F: -v u="$1" '$1 == u { print $4; exit }' "${SPL_DSC_PASSWD:-/etc/passwd}"
}

# spl_dsc_root_members: "<group> <user>" per member of a root-equivalent
# group, by the member list and by the primary gid.
spl_dsc_root_members() {
  local gf="${SPL_DSC_GROUP:-/etc/group}" pf="${SPL_DSC_PASSWD:-/etc/passwd}"
  awk -F: -v want=" $SPL_DSC_ROOT_GROUPS " -v pf="$pf" '
    BEGIN { while ((getline l < pf) > 0) { split(l, p, ":"); prim[p[4]] = prim[p[4]] " " p[1] } }
    index(want, " " $1 " ") {
      n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] != "") print $1, m[i]
      n = split(prim[$3], m, " "); for (i = 1; i <= n; i++) print $1, m[i]
    }' "$gf"
}

spl_dsc_groups() {
  local u="$1" prefix="$2" g m bad=0
  while read -r g m; do
    [[ -n "$m" ]] || continue
    if [[ "$m" == "$u" || ( -n "$prefix" && "$m" == "$prefix"* ) ]]; then
      spl_dsc_refuse groups "workspace OS user '$m' is in '$g' (root-equivalent)"; bad=1
    fi
  done < <(spl_dsc_root_members)
  return "$bad"
}

# A user with no grant gets "may not run sudo"; "a password is required" or a
# command list is a grant.
spl_dsc_sudoers() {
  local out
  command -v sudo >/dev/null 2>&1 || return 0
  out="$(sudo -n -l 2>&1)"
  [[ "$out" == *"may not run sudo"* ]] && return 0
  spl_dsc_refuse sudoers "user '$1' has a sudo grant (sudo -n -l: ${out%%$'\n'*})"
}

# spl_dsc_in_group <user> <gid>: the user is a member of that group.
spl_dsc_in_group() {
  [[ "$(spl_dsc_gid_of "$1")" == "$2" ]] && return 0
  awk -F: -v u="$1" -v g="$2" '$3 == g { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) f = 1 } END { exit !f }' \
    "${SPL_DSC_GROUP:-/etc/group}"
}

spl_dsc_hidepid() {
  local opts o hp="" gid=""
  opts="$(awk '$2 == "/proc" && $3 == "proc" { o = $4 } END { print o }' "${SPL_DSC_MOUNTS:-/proc/mounts}")"
  IFS=, read -ra _o <<<"$opts"
  for o in "${_o[@]}"; do
    case "$o" in hidepid=*) hp="${o#hidepid=}" ;; gid=*) gid="${o#gid=}" ;; esac
  done
  [[ "$hp" == 2 || "$hp" == invisible ]] || { spl_dsc_refuse hidepid "/proc is mounted without hidepid=2 (options: ${opts:-none})"; return 1; }
  [[ -z "$gid" ]] && return 0
  spl_dsc_in_group "$1" "$gid" && { spl_dsc_refuse hidepid "/proc gid=$gid exempts a group of '$1'"; return 1; }
  return 0
}

spl_dsc_sysctl() { tr -d '[:space:]' <"${SPL_DSC_SYSCTL:-/proc/sys}/$1" 2>/dev/null; }

spl_dsc_ptrace() {
  local v; v="$(spl_dsc_sysctl kernel/yama/ptrace_scope)"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 2 )) && return 0
  spl_dsc_refuse ptrace "kernel.yama.ptrace_scope is '${v:-unset}', want >= 2"
}

spl_dsc_dumpable() {
  local v cp
  v="$(spl_dsc_sysctl fs/suid_dumpable)"
  [[ "$v" == 0 ]] || { spl_dsc_refuse dumpable "fs.suid_dumpable is '${v:-unset}', want 0"; return 1; }
  cp="$(head -n 1 "${SPL_DSC_SYSCTL:-/proc/sys}/kernel/core_pattern" 2>/dev/null)"
  [[ -n "$cp" && ( "$cp" != '|'* || "$cp" == *systemd-coredump* ) ]] && return 0
  spl_dsc_refuse dumpable "kernel.core_pattern '${cp:-unset}' pipes to a collector that is not systemd-coredump"
}

# spl_dsc_swap: each active swap is zram (memory) or a dm-crypt device
# (/sys/block/dm-N/dm/uuid starts CRYPT-).
spl_dsc_swap() {
  local dev _rest real n bad=0 sys="${SPL_DSC_SYS:-/sys}"
  while read -r dev _rest; do
    [[ "$dev" == Filename || -z "$dev" ]] && continue
    real="$dev"
    [[ "$dev" == /dev/mapper/* ]] && real="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
    n="${real##*/}"
    [[ "$n" == zram* ]] && continue
    if [[ "$n" == dm-* ]] && grep -q '^CRYPT-' "$sys/block/$n/dm/uuid" 2>/dev/null; then continue; fi
    spl_dsc_refuse swap "plain swap $dev (want none, zram or dm-crypt)"; bad=1
  done <"${SPL_DSC_SWAPS:-/proc/swaps}"
  return "$bad"
}

spl_dsc_runtime() {
  local d="${SPL_DSC_RUNTIME:-/run/user/$(id -u "$1" 2>/dev/null)}" fs got
  fs="$(stat -f -c %T "$d" 2>/dev/null)"
  [[ "$fs" == tmpfs ]] || { spl_dsc_refuse runtime "$d is '${fs:-missing}', want tmpfs (loginctl enable-linger $1)"; return 1; }
  got="$(stat -c '%a %U' "$d" 2>/dev/null)"
  [[ "$got" == "700 $1" ]] || spl_dsc_refuse runtime "$d is '$got', want '700 $1'"
}
