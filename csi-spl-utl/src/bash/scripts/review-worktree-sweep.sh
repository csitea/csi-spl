#!/usr/bin/env bash
# review-worktree-sweep.sh - remove the finished review worktrees of a repo
# (SPL-5225, owner HUM-10 poll 2cfa8ce7 Q4, row 5 of the sat disk table: "6
# finished review worktrees whose commits are on origin", 1.5 GB). A reviewer
# checks a review/* branch out in its own worktree, often detached; nothing
# removes it when the review ends, and the workdir table never lists it.
#
# A linked worktree of REVIEW_WT_REPO is removed only when ALL hold:
#   - review: it is on a local review/* branch, or detached at a commit that
#     an origin review/* branch contains (the first one is named) and that is
#     NOT on origin/master: a review branch contains the master it was cut
#     from, so a checkout detached on master (a desk's) is no review;
#   - pushed: every commit of its HEAD is on origin (no commit outside
#     --remotes=origin), or each one that is not has a patch-id equal commit
#     on origin/master (git cherry); the proof is printed per worktree;
#   - clean: git status --porcelain is empty (untracked files count; ignored
#     ones do not, git worktree remove drops them);
#   - not locked, not a symlink, not root-owned;
#   - no live agent owns it: its dir name does not start with the id of a
#     live lane (lane-map.sh --json --all, rows in state live, the hub
#     answered; the bare list hides lanes over 2 h old) or of a registry.tsv
#     row, its branch is no live lane's branch, no registry.tsv row names its
#     path, and no process has its cwd or an open file under it (/proc via
#     sudo -n; a scan that reads nothing removes nothing).
# It goes through `git worktree remove` (never --force, never rm -rf), as its
# owner; the branch stays. Anything else: one KEEP line with the reason.
#
#   DRY_RUN=1 (default) | 0
#   REVIEW_WT_REPO   a checkout of the repo (default: the one holding this file)
#   REVIEW_WT_SUDO   1 (default) | 0: only this user's processes and worktrees
#   REVIEW_WT_LANES  (tests) a file holding lane-map.sh --json output
#   SPOOL_ROOT       its registry.tsv (default /var/spool-hub)
#
# Lines: PLAN remove|REMOVE <MB>MB <path> branch=<b> ref=<r> proof=<p>;
#        KEEP <reason> <MB|->MB <path>; SKIP gone <path>;
#        DONE would-remove|removed=<n> (<MB> MB) kept=<n>.
# Exit: 0 done; 1 a removal failed; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
dry="${DRY_RUN:-1}"
use_sudo="${REVIEW_WT_SUDO:-1}"
repo="${REVIEW_WT_REPO:-$self_dir}"
spool="${SPOOL_ROOT:-/var/spool-hub}"
lane_map="$self_dir/../../../../csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh"
id_ere='[acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+'
n_rm=0 mb_rm=0 n_keep=0 fail=0 lanes_ok=1 why="" ref="" proof=""
declare -A live_id=() live_br=() reg_path=()

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }
as_owner() { if [[ "$1" == "$(id -un)" ]]; then shift; "$@"; else local o="$1"; shift; sudo -n -u "$o" -- "$@"; fi; }
g() { as_owner "$1" env GIT_TERMINAL_PROMPT=0 timeout 120 git -c safe.directory='*' -C "$2" "${@:3}"; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$use_sudo" == 0 || "$use_sudo" == 1 ]] || refuse "REVIEW_WT_SUDO must be 0 or 1, got '$use_sudo'"
main="$(git -c safe.directory='*' -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
  refuse "REVIEW_WT_REPO $repo is no git checkout"
main="${main%/.git}"
[[ "$use_sudo" == 0 || "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: cannot read every process's cwd and fds"

held="$(mktemp)"; trap 'rm -f "$held"' EXIT
as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) \
  -printf '%l\n' 2>/dev/null | sort -u >"$held"
[[ -s "$held" ]] || refuse "the /proc scan read nothing"
is_held() { grep -qxF -e "$1" "$held" || grep -qF -e "$1/" "$held"; }

# load_live: the live lanes' ids and branches (lane-map.sh --json --all, only
# when the hub answered; the bare list hides lanes over 2 h old) and the
# registry's ids and paths; rc 1 when unread
load_live() {
  local json kind val id ok=0
  if [[ -n "${REVIEW_WT_LANES:-}" ]]; then json="$(cat -- "$REVIEW_WT_LANES")" || return 1
  else json="$(bash "$lane_map" --json --all 2>/dev/null)" || return 1; fi
  while read -r kind val; do
    case "$kind" in id) live_id["$val"]=1 ;; br) live_br["$val"]=1 ;; ok) ok=1 ;; esac
  done < <(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
if d.get("hub") != "ok" or not isinstance(d.get("lanes"), list):
    sys.exit(0)
for l in d["lanes"]:
    if l.get("state", "live") == "live":
        print("id", l.get("agent_id") or "-")
        if l.get("branch"):
            print("br", l["branch"])
print("ok", 1)' <<<"$json" 2>/dev/null)
  (( ok )) || return 1
  if [[ -r "$spool/registry.tsv" ]]; then
    while IFS=$'\t' read -r id _ _ val _; do
      [[ -n "$id" ]] && live_id["${id%%@*}"]=1
      [[ -n "$val" ]] && reg_path["$val"]=1
    done <"$spool/registry.tsv"
  fi
  return 0
}

# review_ref <owner> <path> <branch>: prints the review/* ref HEAD is on
review_ref() {
  local o="$1" p="$2" br="$3"
  if [[ -n "$br" ]]; then [[ "$br" == review/* ]] && echo "$br"; return 0; fi
  g "$o" "$p" merge-base --is-ancestor HEAD origin/master && return 0
  g "$o" "$p" for-each-ref --contains HEAD --count=1 --format='%(refname:short)' refs/remotes/origin/review/
}

# pushed_proof <owner> <path>: prints on-origin or patch-equal:<n>; rc 1 and
# the reason (unpushed <sha>) when a commit is on no origin ref and has no
# patch-id twin on origin/master
pushed_proof() {
  local o="$1" p="$2" out twins sha
  out="$(g "$o" "$p" rev-list HEAD --not --remotes=origin)" || { echo "rev-list-failed"; return 1; }
  [[ -z "$out" ]] && { echo "on-origin"; return 0; }
  twins="$(g "$o" "$p" cherry origin/master HEAD)" || { echo "cherry-failed"; return 1; }
  for sha in $out; do
    grep -qxF -- "- $sha" <<<"$twins" || { echo "unpushed ${sha:0:12}"; return 1; }
  done
  echo "patch-equal:$(wc -w <<<"$out")"
}

# wt_why <path> <owner> <branch> <locked>: sets why (the KEEP reason, empty
# when it may go), ref and proof
wt_why() {
  local p="$1" o="$2" br="$3" locked="$4" st
  why="" ref="" proof=""
  [[ "$locked" == 1 ]] && { why="locked"; return; }
  ref="$(review_ref "$o" "$p" "$br")"
  [[ -n "$ref" ]] || { why="not-review"; return; }
  [[ "${p##*/}" =~ ^($id_ere)(-|$) && -n "${live_id[${BASH_REMATCH[1]}]:-}" ]] && { why="live-owner ${BASH_REMATCH[1]}"; return; }
  [[ -n "$br" && -n "${live_br[$br]:-}" ]] && { why="live-branch $br"; return; }
  [[ -n "${reg_path[$p]:-}" ]] && { why="registry-row"; return; }
  is_held "$p" && { why="in-use"; return; }
  st="$(g "$o" "$p" status --porcelain)" || { why="status-failed"; return; }
  [[ -z "$st" ]] || { why="dirty"; return; }
  proof="$(pushed_proof "$o" "$p")" || { why="$proof"; proof=""; }
}

# settle <path> <branch> <locked>: one PLAN / REMOVE / KEEP line and the counts
settle() {
  local p="$1" br="$2" locked="$3" o="" mb
  why="" ref="" proof=""
  if [[ -L "$p" ]]; then why="symlink"
  elif ! o="$(stat -c %U -- "$p" 2>/dev/null)"; then why="unreadable"
  elif [[ "$o" == root ]]; then why="root-owned"
  elif [[ "$use_sudo" == 0 && "$o" != "$(id -un)" ]]; then why="not-ours"
  elif (( ! lanes_ok )); then why="owner-unknown"
  else wt_why "$p" "$o" "$br" "$locked"; fi
  case "$why" in
    not-review|symlink|unreadable|not-ours) mb="-" ;;
    *) mb="$(as_root du -sm -- "$p" 2>/dev/null | cut -f1)"; mb="${mb:-0}" ;;
  esac
  if [[ -n "$why" ]]; then say "KEEP $why ${mb}MB $p"; n_keep=$((n_keep + 1)); return; fi
  if [[ "$dry" == 1 ]]; then say "PLAN remove ${mb}MB $p branch=${br:-detached} ref=$ref proof=$proof"
  elif g "$o" "$main" worktree remove "$p" >/dev/null 2>&1 && [[ ! -e "$p" ]]; then
    say "REMOVE ${mb}MB $p branch=${br:-detached} ref=$ref proof=$proof"
  else say "WARN could not remove $p (git worktree remove refused)"; fail=1; return; fi
  n_rm=$((n_rm + 1)); mb_rm=$((mb_rm + mb))
}

load_live || { lanes_ok=0; say "WARN the lane map is unread: every worktree is kept"; }
say "START repo=$main dry_run=$dry"
first=1 path="" br="" locked=0
while IFS= read -r line; do
  case "$line" in
    "worktree "*) path="${line#worktree }" ;;
    "branch refs/heads/"*) br="${line#branch refs/heads/}" ;;
    locked*) locked=1 ;;
    prunable*) locked=gone ;;
    "")
      if [[ -n "$path" ]]; then
        if (( first )); then first=0
        elif [[ "$locked" == gone || ! -e "$path" ]]; then say "SKIP gone $path"
        else settle "$path" "$br" "$locked"; fi
      fi
      path="" br="" locked=0 ;;
  esac
done < <(git -c safe.directory='*' -C "$main" worktree list --porcelain; echo)
say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm (${mb_rm} MB) kept=$n_keep dry_run=$dry"
exit "$fail"
