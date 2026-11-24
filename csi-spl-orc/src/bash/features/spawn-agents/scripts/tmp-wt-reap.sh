#!/usr/bin/env bash
# tmp-wt-reap.sh - remove the git worktrees an agent left directly under the
# box's tmp root (a review seat's checkout, its red-control copy), only when
# that agent is PROVEN to have made them (SPL-6347). Why: review seats (mostly
# grok) leave worktrees of the main checkout under /tmp, 11-32k inodes each;
# one box's /tmp tmpfs reached 80% inodes three times in three days and 99%
# once (ENOSPC for every seat), and 18 of its 31 such trees were DIRTY red
# copies of seats already gone. tmp-stale-sweep.sh keeps every worktree,
# wt-dead-sweep.sh keeps every dirty one, and a red copy is dirty by design.
#
# Two modes:
#   --agent <ID>  the retire (agent-id-retire.sh step 8b): <ID>'s own trees.
#   --orphans     the backlog: trees of ids already retired on this box
#                 (registry.retired.tsv or $SPOOL_ROOT/.retired/<ID>.*) that
#                 no live agent holds on ANY box (registry.tsv, the box's tmux
#                 window names, the fleet lane map with the hub answering), and
#                 idle TMP_WT_IDLE_H hours. Run by hand
#                 (csi-spl-utl do_sweep_tmp_worktrees), no cron.
# Without --apply it plans only (PLAN lines) and writes nothing.
#
# A tree is a candidate only when it is a linked worktree of TMP_WT_REPO
# (`git worktree list --porcelain`), sits DIRECTLY under TMP_WT_ROOT, and is
# no symlink. Its owner <ID> is proven by one of (never by its name alone,
# SPL-4761):
#   marker  its git dir holds `spl-owner` naming <ID>: hooks/post-checkout
#           writes it at `git worktree add`, from the creating agent's
#           SPOOL_AGENT_ID (from 2026-11-24 on; older trees have none);
#   outbox  its dir name carries <ID> (g-489-x, g489-x) AND a message <ID>
#           itself SENT (its spool outbox, live or under .retired/) names the
#           exact path. A name alone, or a path only another agent named (a
#           reviewer quotes the author's copy), is KEEP name-only.
# A marker naming another id is that id's tree, whatever its name.
# Kept, whatever the proof: a locked tree, a mount at or under it (findmnt), a
# process with its cwd or an open fd under it (every /proc via sudo -n; a scan
# that cannot read them all removes nothing), a tree owned by another user
# than the main checkout. A clean tree goes by `git worktree remove`; a dirty
# one by `git worktree remove --force` ONLY when its name says it is a red
# control or parent copy (a `red` / `parent` word: g-244-red, g274-r93-01-parent);
# any other dirty tree is KEEP dirty, never forced. The branch stays.
# Never rm -rf: git removes the tree, and only a path git lists.
#
# Usage: tmp-wt-reap.sh [--apply] (--agent <ID> | --orphans)
# Env: TMP_WT_REPO (default: this script's main checkout), TMP_WT_ROOT
#   (default /tmp), TMP_WT_IDLE_H (default 2, --orphans), TMP_WT_SUDO=1|0
#   (0: this user's processes only; tests), TMP_WT_LIVE_IDS (tests: the live
#   ids, space separated; unset = registry.tsv + tmux + lane map), SPOOL_ROOT.
# One PLAN|DO remove / KEEP line per tree, a DONE line.
# Exit 0 done (kept trees included); 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"

APPLY=0 MODE="" ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --orphans) MODE=orphans; shift ;;
    --agent) [ "$#" -ge 2 ] || { echo "tmp-wt-reap: --agent needs an id" >&2; exit 2; }; MODE=agent; ID="${2%%@*}"; shift 2 ;;
    *) echo "tmp-wt-reap: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "tmp-wt-reap: --agent <ID> or --orphans" >&2; exit 2; }
if [ "$MODE" = agent ]; then
  [[ "$ID" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || { echo "tmp-wt-reap: '$ID' is not an agent id" >&2; exit 2; }
fi
VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO
say() { printf '%s tmp-wt-reap: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }

repo="${TMP_WT_REPO:-$(git -C "$_here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')}"
root="${TMP_WT_ROOT:-/tmp}"
idle_h="${TMP_WT_IDLE_H:-2}"
use_sudo="${TMP_WT_SUDO:-1}"
spool="${SPOOL_ROOT:-/var/spool-hub}"
[[ -n "$repo" && -d "$repo/.git" ]] || refuse "TMP_WT_REPO '$repo' is not a main checkout"
[[ -d "$root" && ! -L "$root" ]] || refuse "no tmp root dir $root"
root="$(readlink -f "$root")"
[[ "$idle_h" =~ ^[0-9]+$ ]] && (( idle_h >= 1 )) || refuse "TMP_WT_IDLE_H must be a whole number >= 1, got '$idle_h'"
[[ "$use_sudo" == 0 || "$use_sudo" == 1 ]] || refuse "TMP_WT_SUDO must be 0 or 1, got '$use_sudo'"

as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }
repo_user="$(stat -c %U -- "$repo")"
# g ARGS...: git as the main checkout's owner, as every lane's git runs
g() {
  if [[ "$repo_user" == "$(id -un)" ]]; then GIT_TERMINAL_PROMPT=0 timeout 120 git -c safe.directory='*' "$@"
  else timeout 120 sudo -n -u "$repo_user" env GIT_TERMINAL_PROMPT=0 git -c safe.directory='*' "$@"; fi
}

# lane_id NAME: the normalised agent id a dir name starts with (g273-x -> g-273)
lane_id() {
  [[ "${1,,}" =~ ^([acgmq])-?([0-9]{3})([^0-9]|$) ]] && printf '%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
# marker_of WT: the id in the spl-owner file of WT's git dir, or empty
marker_of() {
  local gd
  gd="$(as_root sed -n 's/^gitdir: //p;T;q' "$1/.git" 2>/dev/null)"
  [ -n "$gd" ] && as_root head -1 "$gd/spl-owner" 2>/dev/null | cut -f1
}
# sent_names ID WT: a message ID itself sent names WT exactly
sent_names() {
  local re d dirs=()
  re="$(printf '%s' "$2" | sed 's/[.[\*^$()+?{}|]/\\&/g')([^A-Za-z0-9._/-]|\$)"
  for d in "$spool/$1/outbox" "$spool/$1"@*/outbox "$spool/.retired/$1".*/outbox; do
    [ -d "$d" ] && dirs+=("$d")
  done
  [ "${#dirs[@]}" -gt 0 ] && as_root grep -rqE -- "$re" "${dirs[@]}" 2>/dev/null
}
retired_id() {
  awk -F'\t' -v id="$1" '{ k = $1; sub(/^.*: /, "", k); sub(/@.*/, "", k) } k == id { f = 1 } END { exit !f }' \
    "$spool/registry.retired.tsv" 2>/dev/null && return 0
  compgen -G "$spool/.retired/$1.*" >/dev/null
}

# The live ids (--orphans): every source must answer, or nothing is removed.
declare -A live=()
add_live() { local w x; for w in "$@"; do x="$(lane_id "${w##*: }")"; [ -n "$x" ] && live["$x"]=1; done; return 0; }
if [ "$MODE" = orphans ]; then
  if [[ -n "${TMP_WT_LIVE_IDS+set}" ]]; then
    # shellcheck disable=SC2086
    add_live $TMP_WT_LIVE_IDS
  else
    reg="$spool/registry.tsv"
    [ -r "$reg" ] || refuse "cannot read $reg: no live-lane guard"
    # shellcheck disable=SC2046
    add_live $(cut -f1 "$reg" | sed 's/@.*//')
    wins="$(tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(stat -c %u "$reg")/default}" list-windows -a -F '#{window_name}' 2>/dev/null)" \
      || refuse "cannot list the box's tmux windows: no live-lane guard"
    # shellcheck disable=SC2046
    add_live $(tr -c 'A-Za-z0-9-\n' ' ' <<<"$wins")
    lm="$(timeout 120 bash "$_here/lane-map.sh" list --all --json 2>/dev/null)" || refuse "the fleet lane map did not answer: other boxes unread"
    ids="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
if d.get("hub") != "ok": sys.exit(3)
out = [l.get("agent_id", "") for l in d.get("lanes") or [] if l.get("state") == "live"]
for b in d.get("load") or []: out += (b.get("busy_ids") or []) + (b.get("seat_ids") or [])
print(" ".join(out))' <<<"$lm")" || refuse "the hub did not answer the lane map: other boxes unread"
    # shellcheck disable=SC2086
    add_live $ids
  fi
fi

# Every path a process holds (cwd, open fds), and every mount point.
[[ "$use_sudo" == 0 || "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: cannot read every process's cwd and fds"
held="$(as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) -printf '%l\n' 2>/dev/null | grep "^$root/" | sort -u)"
mounts="$(findmnt -rn -o TARGET 2>/dev/null | grep "^$root/")"

# The linked worktrees directly under the root: "path<TAB>locked(0|1)"
wts="$(g -C "$repo" worktree list --porcelain 2>/dev/null | awk '
  /^worktree / { if (p != "") print p "\t" l; p = substr($0, 10); l = 0 }
  /^locked/ { l = 1 }
  END { if (p != "") print p "\t" l }' | awk -F'\t' -v r="$root/" 'index($1, r) == 1')" \
  || refuse "git worktree list failed in $repo"

say "START mode=$MODE${ID:+ agent=$ID} repo=$repo root=$root apply=$APPLY live_ids=${#live[@]} idle_h=$idle_h"
n_rm=0 kb_rm=0 n_keep=0
keep() { say "KEEP $1 $2"; n_keep=$((n_keep + 1)); }
while IFS=$'\t' read -r wt locked; do
  [ -n "$wt" ] || continue
  name="${wt##*/}"
  [[ "${wt%/*}" == "$root" && ! -L "$wt" && -d "$wt" ]] || continue
  mk="$(marker_of "$wt")" nid="$(lane_id "$name")"
  if [ "$MODE" = agent ]; then who="$ID"
  else who="${mk:-$nid}"; fi
  [ -n "$who" ] || continue
  if [ -n "$mk" ] && [ "$mk" != "$who" ]; then
    [ "$nid" = "$who" ] && keep "marker-other ($mk)" "$wt"
    continue
  fi
  if [ "$mk" = "$who" ]; then proof=marker
  elif [ "$nid" != "$who" ]; then continue
  elif sent_names "$who" "$wt"; then proof=outbox
  else keep "name-only (no spl-owner marker, no message of $who names it)" "$wt"; continue
  fi
  if [ "$MODE" = orphans ]; then
    if ! retired_id "$who"; then keep "not-retired $who" "$wt"; continue; fi
    if [ -n "${live[$who]:-}" ]; then keep "live-id $who" "$wt"; continue; fi
  fi
  if [ "$locked" = 1 ]; then keep locked "$wt"; continue; fi
  if grep -qxF -e "$wt" <<<"$mounts" || grep -qF -e "$wt/" <<<"$mounts"; then keep mounted "$wt"; continue; fi
  if grep -qxF -e "$wt" <<<"$held" || grep -qF -e "$wt/" <<<"$held"; then keep "in-use (a process has its cwd or an open file under it)" "$wt"; continue; fi
  if [ "$(stat -c %U -- "$wt" 2>/dev/null)" != "$repo_user" ]; then keep "owner-not-$repo_user" "$wt"; continue; fi
  if [ "$MODE" = orphans ]; then
    young="$(as_root find "$wt" -newermt "-${idle_h} hours" -print -quit 2>/dev/null)"; frc=$?
    if [ -n "$young" ]; then keep "recent (changed in the last ${idle_h} h)" "$wt"; continue; fi
    if [ "$frc" != 0 ]; then keep unreadable "$wt"; continue; fi
  fi
  st="$(g -C "$wt" status --porcelain 2>/dev/null)" || { keep "git-status-failed" "$wt"; continue; }
  force=()
  if [ -n "$st" ]; then
    if [[ "${name,,}" =~ (^|[-_.])(red|parent)([-_.]|$) ]]; then force=(--force)
    else keep "dirty (not a red-control or parent copy: never forced)" "$wt"; continue; fi
  fi
  kb="$(as_root du -sk -- "$wt" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  what="remove ${kb}KB proof=$proof${force:+ dirty red-copy --force} $wt"
  if [ "$APPLY" = 1 ]; then
    g -C "$repo" worktree remove "${force[@]}" "$wt" 2>/dev/null || { keep "git-refused" "$wt"; continue; }
  fi
  say "$VERB $what"
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
done <<<"$wts"
say "DONE $([ "$APPLY" = 1 ] && echo removed || echo would-remove)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep"
