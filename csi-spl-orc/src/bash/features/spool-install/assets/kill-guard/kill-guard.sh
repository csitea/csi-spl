#!/usr/bin/env bash
# spool kill-guard, written by spool-install (y11-kill-guard.sh)
#------------------------------------------------------------------------------
# Installed as `pkill` and `killall` in the agent user's ~/.local/bin, ahead of
# /usr/bin. Every agent seat carries every ./run action name and its seed on
# its argv, so a pattern kill (`pkill -f "git push"`) hits every seat on the
# box: on 2026-10-09 one SIGTERMed twelve. This refuses the pattern forms:
#   pkill -f / --full (any cluster or position)  -> exit 2
#   killall (any form)                           -> exit 2
# and passes every other form unchanged to the next pkill on PATH that is not
# this file (e.g. `pkill -x <name>`). Re-run install.sh to rewrite this file.
#------------------------------------------------------------------------------
set -u
REFUSED="refused: pattern kills hit every agent seat; stop a process by its own pid or its ./run stop action"
name="${0##*/}"

# real <name>: the next <name> on PATH that is not this file.
real() {
  local self d c dirs
  self="$(readlink -f "$0")"
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    c="$d/$1"
    if [ ! -x "$c" ] || [ -d "$c" ]; then continue; fi
    [ "$(readlink -f "$c")" = "$self" ] && continue
    printf '%s\n' "$c"; return 0
  done
  return 1
}

# full_match <args...>: 0 when the pkill args ask for -f / --full.
full_match() {
  local a i ch
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --) return 1 ;;
      # getopt takes any unique prefix of --full
      --f*) if [[ --full == "$a"* ]]; then return 0; fi ;;
      --*=*) ;;
      --signal|--group|--pgroup|--parent|--session|--terminal|--euid|--uid|--pidfile|--ns|--nslist|--runstates|--older|--cgroup|--env) shift ;;
      --*) ;;
      -?*)
        for ((i = 1; i < ${#a}; i++)); do
          ch="${a:i:1}"
          case "$ch" in
            f) return 0 ;;
            # an option that takes a value: the rest is the value, or the next arg
            [gGOPstuUFr]) [ $((i + 1)) -eq ${#a} ] && shift; break ;;
          esac
        done ;;
    esac
  done
  return 1
}

case "$name" in
  killall) echo "$REFUSED" >&2; exit 2 ;;
  *) if full_match "$@"; then echo "$REFUSED" >&2; exit 2; fi ;;
esac
bin="$(real "$name")" || { echo "$name: no real $name on PATH" >&2; exit 127; }
exec "$bin" "$@"
