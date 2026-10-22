#!/usr/bin/env bash
# tmp-stale-sweep.sh - remove the build and test leftovers of FINISHED runs
# from the shared /tmp tmpfs (the CI runners share it). On sat, 2026-10-08,
# /tmp was 21 GB used of 32 GB: 96 go-build<N> work dirs (7.2 GB, every one
# idle > 24 h), 5957 mktemp tmp.<X> entries (3.1 GB), two dead lanes'
# <id>-gocache dirs (4.7 GB) and Go test temp dirs Test<Name><N>.
#
# Only a TOP-LEVEL entry of the root whose name matches one of these shapes is
# a candidate:
#   go-build<digits>   tmp.<10 alnum>   Test<word><digits>   <word>-gocache
# It is removed only when ALL hold:
#   - it is no symlink and not owned by root;
#   - nothing under it changed in the last TMP_STALE_AGE_H hours;
#   - no process uses it: no /proc/<pid>/cwd and no open fd lies under it
#     (read for every process via sudo -n; a scan that cannot read them all
#     decides nothing, exit 2).
# It is removed AS its owner (sudo -n -u when that is not us), then as each
# other non-root owner of an entry under it (TMP_STALE_SUDO=1); what is still
# there gets ONE `SKIP not-owner <dir> owner=<u> left_owners=<u,..> bytes=<n>`
# line, never a line per file. The Claude
# scratch dirs (/tmp/claude-<uid>) are do_tmp_scratch_sweep's, never this one's.
#
# TMP_STALE_ANY=1 (the box sweep's `vartmp` step, root /var/tmp, only under
# disk pressure): EVERY top-level entry is a candidate, whatever its name, but
# a dot entry, systemd-private-* and claude-* are never, and a name that
# carries the id of a lane this box still holds (c908-gocache, c-161-copy:
# [acgmq]-?NNN in registry.tsv or a tmux window name) is kept as `live-lane`.
# On sat, 2026-10-15, /var/tmp held 6.9 GB of the 30 GB root in 1288 lane
# leftovers (copies, baselines, go caches) that no sweep looked at.
#
#   DRY_RUN=1 (default) | 0
#   TMP_STALE_ROOT     default /tmp
#   TMP_STALE_AGE_H    default 24
#   TMP_STALE_ANY      0 (default) | 1: any name (see above)
#   TMP_STALE_LIVE_IDS the live lane ids for TMP_STALE_ANY (tests); default
#                      $SPOOL_ROOT/registry.tsv + the window names of the tmux
#                      server of the registry's owner (the box user)
#   TMP_STALE_SUDO     1 (default): read /proc and remove other users' entries
#                      via sudo -n; 0: only this user's processes and entries
#
# One PLAN|REMOVE / KEEP / SKIP line per candidate, a DONE line.
# Exit: 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
root="${TMP_STALE_ROOT:-/tmp}"
age_h="${TMP_STALE_AGE_H:-24}"
use_sudo="${TMP_STALE_SUDO:-1}"
any="${TMP_STALE_ANY:-0}"
shape_ere='^(go-build[0-9]+|tmp\.[A-Za-z0-9]{10}|Test[A-Za-z0-9_]*[0-9]+|[A-Za-z0-9_.]+-gocache)$'

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
used() { df -P "$root" | awk 'NR==2{print $5}'; }
as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$any" == 0 || "$any" == 1 ]] || refuse "TMP_STALE_ANY must be 0 or 1, got '$any'"
[[ "$use_sudo" == 0 || "$use_sudo" == 1 ]] || refuse "TMP_STALE_SUDO must be 0 or 1, got '$use_sudo'"
[[ "$age_h" =~ ^[0-9]+$ ]] && (( age_h >= 1 )) || refuse "TMP_STALE_AGE_H must be a whole number >= 1, got '$age_h'"
[[ -d "$root" && ! -L "$root" ]] || refuse "no root dir $root"
root="$(readlink -f "$root")"

# Every path a process holds: its cwd and its open fds, one per line.
[[ "$use_sudo" == 0 || "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: cannot read every process's cwd and fds"
held="$(mktemp)"; trap 'rm -f "$held"' EXIT
as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) \
  -printf '%l\n' 2>/dev/null | grep "^$root/" | sort -u >"$held"

# rm_as <user> <path>: rm -rf <path> as <user>, stderr dropped: a tree it
# cannot remove gets ONE SKIP line from the caller, never one per file (sat,
# 2026-10-22: 250527 "Permission denied" lines in one tick). A Go module cache
# (GOMODCACHE under a mktemp dir) is read-only: u+w first.
rm_as() {
  if [[ "$1" == "$(id -un)" ]]; then { chmod -R u+w -- "$2"; rm -rf -- "$2"; } 2>/dev/null
  else { sudo -n -u "$1" chmod -R u+w -- "$2"; sudo -n -u "$1" rm -rf -- "$2"; } 2>/dev/null; fi
}
# owners_of <path>: the distinct owners of every entry under <path>
owners_of() { as_root find "$1" -printf '%u\n' 2>/dev/null | sort -u; }

# lane_id <name>: the normalised agent id a name carries (c908-x -> c-908), or empty
lane_id() {
  [[ "${1,,}" =~ (^|[^a-z0-9])([acgmq])-?([0-9]{3})([^0-9]|$) ]] && printf '%s-%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}
declare -A live=()
if [[ "$any" == 1 ]]; then
  if [[ -n "${TMP_STALE_LIVE_IDS+set}" ]]; then ids="$TMP_STALE_LIVE_IDS"
  else
    reg="${SPOOL_ROOT:-/var/spool-hub}/registry.tsv"
    [[ -r "$reg" ]] || refuse "TMP_STALE_ANY=1 cannot read the lane registry $reg: no live-lane guard"
    ids="$(cut -f1 "$reg") $(tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(stat -c %u "$reg")/default}" \
      list-windows -a -F '#{window_name}' 2>/dev/null | tr -c 'A-Za-z0-9@\n-' ' ')"
  fi
  for w in $ids; do w="$(lane_id "${w%%@*}")"; [[ -n "$w" ]] && live["$w"]=1; done
fi

say "START root=$root dry_run=$dry any=$any live_ids=${#live[@]} age_h=$age_h held_paths=$(wc -l <"$held") used=$(used)"
n_rm=0 kb_rm=0 n_keep=0 n_skip=0
while IFS= read -r -d '' p; do
  name="${p##*/}"
  if [[ "$any" == 1 ]]; then
    [[ "$name" == .* || "$name" == systemd-private-* || "$name" == claude-* ]] && continue
  else
    [[ "$name" =~ $shape_ere ]] || continue
  fi
  lid="$(lane_id "$name")"
  owner="$(stat -c %U -- "$p" 2>/dev/null)" || continue
  why=""
  if [[ -L "$p" ]]; then why="symlink"
  elif [[ "$owner" == root ]]; then why="root-owned"
  elif [[ "$use_sudo" == 0 && "$owner" != "$(id -un)" ]]; then why="not-ours"
  elif [[ "$any" == 1 && -n "$lid" && -n "${live[$lid]:-}" ]]; then why="live-lane"
  elif grep -qxF -e "$p" "$held" || grep -qF -e "$p/" "$held"; then why="in-use"
  elif [[ -n "$(as_root find "$p" -newermt "-${age_h} hours" -print -quit 2>/dev/null)" ]]; then why="recent"
  fi
  if [[ -n "$why" ]]; then say "KEEP $why $p"; n_keep=$((n_keep + 1)); continue; fi
  kb="$(as_root du -sk -- "$p" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB owner=$owner $p"
  else
    rm_as "$owner" "$p"
    # A lane dir of one user often holds another's subdirs (the agent user's
    # dir, the box user's e2e output): each owner removes what it can, the
    # top owner last, at most 3 rounds. Never root.
    for _ in 1 2 3; do
      [[ -e "$p" && "$use_sudo" == 1 ]] || break
      for u in $(owners_of "$p" | grep -vx -e root -e "$owner"); do rm_as "$u" "$p"; done
      rm_as "$owner" "$p"
    done
    if [[ -e "$p" ]]; then
      say "SKIP not-owner $p owner=$owner left_owners=$(owners_of "$p" | paste -sd, -) bytes=$(as_root du -sb -- "$p" 2>/dev/null | cut -f1)"
      n_skip=$((n_skip + 1)); continue
    fi
    say "REMOVE ${kb}KB owner=$owner $p"
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)
say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep skipped=$n_skip used=$(used)"
