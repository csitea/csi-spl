#!/usr/bin/env bash
# lane-scratch-reap.sh - remove a closed lane's Claude Code scratch from the
# shared /tmp tmpfs: /tmp/claude-<uid>/<slug>/ and /tmp/claude-<uid>/<slug>-*/
# (sessions started in a subdir), <slug> being the lane's worktree path with
# every character but [A-Za-z0-9] turned into '-' (Claude Code's project
# slug: /opt/x/c-236 -> -opt-x-c-236). agent-id-retire.sh (step 8) runs it
# with --apply once the lane's window is gone, then --list, and lists each
# dir that stayed (one a process holds) in the box's workdir table
# (workdir-register.sh): the disk sweep removes it after 24 h (owner, t1
# 37349c9b msg ec060ebc). Why at once: retired lanes' scratch filled /tmp,
# 13 dirs held 12.85 GB and their removal took /tmp inodes from 80% to 36%
# (2026-10-31, n=1); it regrew about 10 points an hour.
# Why: on sat, 2026-10-15, the closed c-232's scratch held 20 GB (434 test
# harness dirs + a Postgres data dir) and /tmp reached 93%; the hourly
# do_tmp_scratch_sweep waits 24 h of idleness, closing a lane removed nothing.
#
# A dir is removed only when it is a real dir (no symlink) and NO process has
# its cwd or an open fd under it (every process's /proc read via sudo -n; a
# scan that cannot read them all keeps everything). It is removed as its
# owner. One line per dir (PLAN|DO remove <KB> / KEEP <why>), also appended
# to LANE_SCRATCH_LOG.
#
# Usage: lane-scratch-reap.sh [--apply|--list] <worktree path>
#   without --apply: PLAN lines only; --list: each real dir's path, one per
#   line, nothing else (no process check, nothing removed)
# Env: LANE_SCRATCH_TMP (default /tmp), LANE_SCRATCH_SUDO=1|0 (0: only this
#   user's processes are read and only its dirs removed; tests),
#   LANE_SCRATCH_LOG (default $XDG_STATE_HOME or ~/.local/state, then
#   <org>-<app>/lane-scratch-reap.log; "" = no log file)
# A /tmp/claude-<uid> root is 0700, its user's: one this user cannot read is
# read as its owner (sudo -n -u; LANE_SCRATCH_SUDO=0: never), and one it still
# cannot read gets a WARN line naming it and exit 3, never "OK no scratch".
# Why: as the box user (its reaper cron, a hand retire under sudo -u) every
# root of the agent user read empty, and 13 dirs of 12.85 GB were reported
# "OK no scratch" (2026-10-31, n=1 run per box).
#
# Exit 0 done (kept dirs included); 2 usage; 3 a root left unread.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

APPLY=0 LIST=0 WT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --list) LIST=1; shift ;;
    -*) echo "lane-scratch-reap: unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$WT" ] || { echo "lane-scratch-reap: one worktree path only" >&2; exit 2; }; WT="$1"; shift ;;
  esac
done
[ "$APPLY$LIST" != 11 ] || { echo "lane-scratch-reap: --apply or --list, not both" >&2; exit 2; }
[[ "$WT" == /?* ]] || { echo "lane-scratch-reap: needs an absolute worktree path, got '${WT}'" >&2; exit 2; }
WT="${WT%/}"
slug="${WT//[^A-Za-z0-9]/-}"
tmp="${LANE_SCRATCH_TMP:-/tmp}"
use_sudo="${LANE_SCRATCH_SUDO:-1}"
orc="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../../.." && pwd)"
app="$(basename "$orc")"; app="${app%-orc}"
log="${LANE_SCRATCH_LOG-${XDG_STATE_HOME:-$HOME/.local/state}/$app/lane-scratch-reap.log}"
VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO

say() {
  local l; l="$(date -u +%Y-%m-%dT%H:%M:%SZ) lane-scratch-reap: $*"
  printf '%s\n' "$l"
  [ "$APPLY" = 1 ] && [ -n "$log" ] && { mkdir -p "${log%/*}" && printf '%s\n' "$l" >>"$log"; } 2>/dev/null
  return 0
}
as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }

readable() { [ -r "$1" ] && [ -x "$1" ]; }
in_root() {  # ROOT CMD...: CMD as a user that can read ROOT (its owner, else this one)
  local r="$1"; shift
  if readable "$r"; then "$@"; else sudo -n -u "$(stat -c %U -- "$r")" -- "$@"; fi
}
dirs=() blind=()
for r in "$tmp"/claude-*; do
  [ -d "$r" ] && [ ! -L "$r" ] || continue
  if ! readable "$r" && { [ "$use_sudo" != 1 ] || ! in_root "$r" test -x "$r" 2>/dev/null; }; then
    blind+=("$r"); continue
  fi
  while IFS= read -r d; do [ -n "$d" ] && dirs+=("$d"); done \
    < <(in_root "$r" find "$r" -mindepth 1 -maxdepth 1 \( -name "$slug" -o -name "$slug-*" \) -print 2>/dev/null | sort)
done
blind_warn() {  # to stderr under --list (its stdout is paths only)
  local r
  for r in "${blind[@]}"; do
    if [ "$LIST" = 1 ]; then
      printf 'lane-scratch-reap: WARN unreadable %s (owner %s, mode %s): its scratch of %s is unknown\n' "$r" "$(stat -c %U -- "$r")" "$(stat -c %a -- "$r")" "$WT" >&2
    else
      say "WARN unreadable $r (owner $(stat -c %U -- "$r"), mode $(stat -c %a -- "$r")): its scratch of $WT is unknown"
    fi
  done
}
rc=0; [ "${#blind[@]}" -eq 0 ] || rc=3
if [ "$LIST" = 1 ]; then
  for d in "${dirs[@]}"; do in_root "${d%/*}" test -d "$d" -a ! -L "$d" && printf '%s\n' "$d"; done
  blind_warn; exit "$rc"
fi
if [ "${#dirs[@]}" -eq 0 ]; then
  if [ "$rc" = 0 ]; then say "OK no scratch of $WT under $tmp/claude-*/$slug"; else blind_warn; fi
  exit "$rc"
fi

if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]] && ! sudo -n true 2>/dev/null; then
  for d in "${dirs[@]}"; do say "KEEP unreadable-procs $d (no sudo -n: cannot prove no process holds it)"; done
  blind_warn; exit "$rc"
fi
held="$(as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) -printf '%l\n' 2>/dev/null | sort -u)"

for d in "${dirs[@]}"; do
  if in_root "${d%/*}" test -L "$d" -o ! -d "$d"; then say "KEEP not-a-dir $d"; continue; fi
  owner="$(in_root "${d%/*}" stat -c %U -- "$d" 2>/dev/null)" || { say "KEEP unreadable $d"; continue; }
  if [[ "$use_sudo" == 0 && "$owner" != "$(id -un)" ]]; then say "KEEP not-ours $d (owner $owner)"; continue; fi
  if grep -qxF -e "$d" <<<"$held" || grep -qF -e "$d/" <<<"$held"; then
    say "KEEP in-use $d (a process has its cwd or an open file under it)"; continue
  fi
  kb="$(as_root du -sk -- "$d" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  if [ "$APPLY" = 1 ]; then
    if [[ "$owner" == "$(id -un)" ]]; then chmod -R u+w -- "$d" 2>/dev/null; rm -rf -- "$d"
    else sudo -n -u "$owner" chmod -R u+w -- "$d" 2>/dev/null; sudo -n -u "$owner" rm -rf -- "$d"; fi
    in_root "${d%/*}" test -e "$d" && { say "WARN could not remove $d (owner $owner)"; continue; }
  fi
  say "$VERB remove ${kb}KB owner=$owner $d"
done
blind_warn
exit "$rc"
