#!/usr/bin/env bash
# wt-dead-sweep.sh - remove the linked worktrees of agents that are gone and
# whose work is all on the trunk. On sat, 2026-10-08, 45 lane worktrees sat
# under the worktree root, most of them closed lanes that never tore down.
#
# A linked worktree of WT_REPO under WT_ROOT is removed only when ALL hold:
#   - its dir name (the agent id) is not a role seat (WT_SWEEP_KEEP_RE);
#   - no agent record says it is alive ($SPOOL_ROOT/agents/<id>.json);
#   - no process has its cwd inside it;
#   - it is clean (no change, no untracked file) and its HEAD is contained in
#     WT_TRUNK (default origin/master, as last fetched: a stale ref only keeps);
#   - nothing in it (node_modules aside) changed in the last WT_SWEEP_AGE_H h.
# The removal is `git worktree remove` (no --force: git refuses a dirty one
# again) and `git branch -d` (merged branches only). The main checkout and a
# worktree outside WT_ROOT are never touched; neither is a non-worktree dir.
#
#   DRY_RUN=1 (default) | 0
#   WT_REPO           the main checkout (default: this script's checkout)
#   WT_ROOT           default <WT_REPO>-wt
#   WT_TRUNK          default origin/master
#   WT_SWEEP_AGE_H    default 72
#   WT_SWEEP_KEEP_RE  default ^(c-00[1-3]|CLE-00[1-3])$
#   SPOOL_ROOT        default /var/spool-hub (its agents/ records)
#
# One PLAN|REMOVE / KEEP line per worktree, a DONE line.
# Exit: 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo="${WT_REPO:-$(git -C "$self_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')}"
wt_root="${WT_ROOT:-${repo}-wt}"
trunk="${WT_TRUNK:-origin/master}"
age_h="${WT_SWEEP_AGE_H:-72}"
keep_re="${WT_SWEEP_KEEP_RE:-^(c-00[1-3]|CLE-00[1-3])$}"
spool="${SPOOL_ROOT:-/var/spool-hub}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
g() { git -c safe.directory='*' "$@"; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$age_h" =~ ^[0-9]+$ ]] && (( age_h >= 1 )) || refuse "WT_SWEEP_AGE_H must be a whole number >= 1, got '$age_h'"
[[ -n "$repo" && -d "$repo/.git" ]] || refuse "WT_REPO '$repo' is not a main checkout"
[[ -d "$wt_root" ]] || { say "OK no worktree root $wt_root: nothing to sweep"; exit 0; }
wt_root="$(readlink -f "$wt_root")"
g -C "$repo" rev-parse --verify -q "$trunk^{commit}" >/dev/null || refuse "no trunk ref $trunk in $repo"
[[ -d "$spool/agents" && -r "$spool/agents" ]] || refuse "cannot read the agent records in $spool/agents"

# Every cwd of a running process (ours; root's view when sudo -n works).
cwds="$(mktemp)"; trap 'rm -f "$cwds"' EXIT
{ sudo -n find /proc -mindepth 2 -maxdepth 2 -path '/proc/[0-9]*/cwd' -printf '%l\n' 2>/dev/null ||
  find /proc -mindepth 2 -maxdepth 2 -path '/proc/[0-9]*/cwd' -printf '%l\n' 2>/dev/null; } | sort -u >"$cwds"

alive() {
  [[ -r "$spool/agents/$1.json" ]] || return 1
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("alive") is True else 1)' "$spool/agents/$1.json" 2>/dev/null
}

say "START repo=$repo root=$wt_root trunk=$trunk dry_run=$dry age_h=$age_h"
n_rm=0 kb_rm=0 n_keep=0
while IFS= read -r wt; do
  wt="$(readlink -f "$wt")"
  [[ "${wt%/*}" == "$wt_root" ]] || continue
  id="${wt##*/}"; why=""
  br="$(g -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)"
  if [[ "$id" =~ $keep_re ]]; then why="role-seat"
  elif alive "$id"; then why="alive"
  elif grep -qxF -e "$wt" "$cwds" || grep -qF -e "$wt/" "$cwds"; then why="in-use"
  elif [[ -n "$(g -C "$wt" status --porcelain 2>/dev/null)" ]]; then why="dirty"
  elif ! g -C "$repo" merge-base --is-ancestor "$(g -C "$wt" rev-parse HEAD 2>/dev/null)" "$trunk" 2>/dev/null; then why="not-on-trunk"
  elif [[ -n "$(find "$wt" -name node_modules -prune -o -newermt "-${age_h} hours" -print -quit 2>/dev/null)" ]]; then why="recent"
  fi
  if [[ -n "$why" ]]; then say "KEEP $why $wt"; n_keep=$((n_keep + 1)); continue; fi
  kb="$(du -sk -- "$wt" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB $wt${br:+ branch $br}"
  else
    g -C "$repo" worktree remove "$wt" || { say "WARN git refused to remove $wt"; continue; }
    [[ -n "$br" ]] && { g -C "$repo" branch -d "$br" >/dev/null 2>&1 || say "WARN branch $br kept (git branch -d refused)"; }
    say "REMOVE ${kb}KB $wt${br:+ branch $br}"
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
done < <(g -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p' | tail -n +2)
say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep"
