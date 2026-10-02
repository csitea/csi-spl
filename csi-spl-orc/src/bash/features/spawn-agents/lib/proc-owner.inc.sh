#!/usr/bin/env bash
# proc-owner.inc.sh — read another user's /proc/<pid>/environ (CLE-77907).
#
# An agent that runs as the agent user (box.env SPOOL_AGENT_USER) keeps its
# /proc/<pid>/environ readable to that user only (mode 0400). Every check that
# runs as the box user and finds an agent by SPOOL_AGENT_ID then reads nothing
# and reports a live agent as "not running" (the dispatch GAP for CLE-002 /
# CLE-003, 2026-10-01). The rule of agent-identity.py, in bash: on a file we
# cannot read, ask the process's OWNER for it (sudo -n -u <owner>: least
# privilege, never root, never a prompt), only on the real /proc, and one sudo
# per owner per call, never one per process.
#
#   SPOOL_OWNER_HOP      1 (default) | 0 off | force (tests: hop on a fake
#                        root too, through SPOOL_OWNER_HOP_CMD). AI_OWNER_HOP=0
#                        (agent-identity.py's switch) also turns it off.
#   SPOOL_OWNER_HOP_CMD  the hop, called as `<cmd> <user> <argv...>`
#                        default "sudo -n -u"

_spool_hop_mode() {  # ROOT -> prints force|on, or returns 1 (no hop)
  local m="${SPOOL_OWNER_HOP:-${AI_OWNER_HOP:-1}}"
  case "$m" in
    force) echo force ;;
    0) return 1 ;;
    *) [ "$(readlink -f "$1" 2>/dev/null)" = /proc ] || return 1; echo on ;;
  esac
}

# "<pid> <value>" for each PID whose environ sets VAR (first entry). Readable
# files are read directly; the rest through their owner, grouped per owner.
spool_proc_env_get() {  # ROOT VAR PID...
  local root="$1" var="$2" p f mode me uid user rec path
  shift 2
  [ $# -gt 0 ] || return 0
  local -a own=() hop=()
  for p in "$@"; do
    f="$root/$p/environ"
    if [ -r "$f" ]; then own+=("$f"); elif [ -e "$f" ]; then hop+=("$f"); fi
  done
  {
    [ ${#own[@]} -gt 0 ] && grep -zH -m1 "^${var}=" "${own[@]}" 2>/dev/null
    if [ ${#hop[@]} -gt 0 ] && mode="$(_spool_hop_mode "$root")"; then
      local -A by=()
      if [ "$mode" = force ]; then
        by[test]="$(printf '%s\n' "${hop[@]}")"
      else
        me="$(id -u)"
        while read -r uid path; do
          [ "$uid" = "$me" ] && continue
          user="$(getent passwd "$uid" | cut -d: -f1)"
          [ -n "$user" ] && by[$user]+="$path"$'\n'
        done < <(stat -c '%u %n' "${hop[@]}" 2>/dev/null)
      fi
      for user in "${!by[@]}"; do
        mapfile -t hop < <(printf '%s' "${by[$user]}" | sed '/^$/d')
        # shellcheck disable=SC2086
        ${SPOOL_OWNER_HOP_CMD:-sudo -n -u} "$user" grep -zH -m1 "^${var}=" "${hop[@]}" </dev/null 2>/dev/null
      done
    fi
  } | while IFS= read -r -d '' rec; do
    path="${rec%%:"${var}"=*}"
    p="${path%/environ*}"; p="${p##*/}"
    printf '%s %s\n' "$p" "${rec#*:"${var}"=}"
  done
}

# ARGV run as the owner of PID (its stdout; nothing when no hop applies).
spool_proc_as_owner() {  # ROOT PID ARGV...
  local root="$1" pid="$2" mode user
  shift 2
  mode="$(_spool_hop_mode "$root")" || return 0
  if [ "$mode" = force ]; then user='test'
  else
    user="$(stat -c %U "$root/$pid" 2>/dev/null)"
    [ -n "$user" ] && [ "$user" != "$(id -un)" ] || return 0
  fi
  # shellcheck disable=SC2086
  ${SPOOL_OWNER_HOP_CMD:-sudo -n -u} "$user" "$@" </dev/null 2>/dev/null
  return 0
}

# The whole NUL-separated environ of PID, through its owner when unreadable.
spool_proc_environ() {  # ROOT PID
  local f="$1/$2/environ"
  if [ -r "$f" ]; then cat "$f" 2>/dev/null; return 0; fi
  [ -e "$f" ] || return 0
  spool_proc_as_owner "$1" "$2" cat "$f"
}
