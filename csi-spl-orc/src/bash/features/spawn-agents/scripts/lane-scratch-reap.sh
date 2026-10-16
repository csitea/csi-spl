#!/usr/bin/env bash
# lane-scratch-reap.sh - remove a closed lane's Claude Code scratch from the
# shared /tmp tmpfs: /tmp/claude-<uid>/<slug>/ and /tmp/claude-<uid>/<slug>-*/
# (sessions started in a subdir), <slug> being the lane's worktree path with
# every character but [A-Za-z0-9] turned into '-' (Claude Code's project
# slug: /opt/x/c-236 -> -opt-x-c-236). agent-id-retire.sh (step 8) runs it
# with --list once the lane's window is gone and lists each dir in the box's
# workdir table (workdir-register.sh): the disk sweep removes it after 24 h
# (owner, t1 37349c9b msg ec060ebc). --apply still removes at once, by hand.
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
# Exit 0 done (kept dirs included); 2 usage.
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

dirs=()
for d in "$tmp"/claude-*/"$slug" "$tmp"/claude-*/"$slug"-*; do
  [ -e "$d" ] || [ -L "$d" ] || continue
  dirs+=("$d")
done
if [ "$LIST" = 1 ]; then
  for d in "${dirs[@]}"; do [ -d "$d" ] && [ ! -L "$d" ] && printf '%s\n' "$d"; done
  exit 0
fi
[ "${#dirs[@]}" -gt 0 ] || { say "OK no scratch of $WT under $tmp/claude-*/$slug"; exit 0; }

if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]] && ! sudo -n true 2>/dev/null; then
  for d in "${dirs[@]}"; do say "KEEP unreadable-procs $d (no sudo -n: cannot prove no process holds it)"; done
  exit 0
fi
held="$(as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) -printf '%l\n' 2>/dev/null | sort -u)"

for d in "${dirs[@]}"; do
  if [ -L "$d" ] || [ ! -d "$d" ]; then say "KEEP not-a-dir $d"; continue; fi
  owner="$(stat -c %U -- "$d" 2>/dev/null)" || { say "KEEP unreadable $d"; continue; }
  if [[ "$use_sudo" == 0 && "$owner" != "$(id -un)" ]]; then say "KEEP not-ours $d (owner $owner)"; continue; fi
  if grep -qxF -e "$d" <<<"$held" || grep -qF -e "$d/" <<<"$held"; then
    say "KEEP in-use $d (a process has its cwd or an open file under it)"; continue
  fi
  kb="$(as_root du -sk -- "$d" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  if [ "$APPLY" = 1 ]; then
    if [[ "$owner" == "$(id -un)" ]]; then chmod -R u+w -- "$d" 2>/dev/null; rm -rf -- "$d"
    else sudo -n -u "$owner" chmod -R u+w -- "$d" 2>/dev/null; sudo -n -u "$owner" rm -rf -- "$d"; fi
    [ -e "$d" ] && { say "WARN could not remove $d (owner $owner)"; continue; }
  fi
  say "$VERB remove ${kb}KB owner=$owner $d"
done
exit 0
