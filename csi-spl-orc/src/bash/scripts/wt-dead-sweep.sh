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
#     WT_TRUNK (default origin/master, as last fetched: a stale ref only keeps),
#     or every commit of WT_TRUNK..HEAD is on WT_TRUNK by patch (git cherry
#     prints no '+' line, and no merge commit), or it is a SALVAGED dirty tree;
#   - nothing in it (node_modules aside) changed in the last WT_SWEEP_AGE_H h.
# The removal is `git worktree remove` (no --force: git refuses a dirty one
# again) and `git branch -d` (merged branches only). The main checkout and a
# worktree outside WT_ROOT are never touched.
#
# The one non-worktree dir it removes (SPL-2309): <ID>.stale-<UTC> directly
# under WT_ROOT, the dir spawn moves aside (_spawn_reusable). Its id <ID> must
# pass the first three checks, nothing in it may have changed in the last
# WT_SWEEP_AGE_H h, and it must hold no .git (a worktree or a repo is never
# removed with rm -rf). Any other dir is never touched.
#
#   DRY_RUN=1 (default) | 0
#   WT_REPO           the main checkout (default: this script's checkout)
#   WT_ROOT           default <WT_REPO>-wt
#   WT_TRUNK          default origin/master
#   WT_SWEEP_AGE_H    default 72
#   WT_SWEEP_KEEP_RE  default ^(<SPL_ROLE_SEAT_RX>|CLE-00[1-3])$ (role seats, any vendor letter)
#   SPOOL_ROOT        default /var/spool-hub (its agents/ records)
#
# Salvage (SPL-2514), wt-dirty-salvage.inc.sh: a dirty tree is kept, but
# nothing resolved one, so on sat, 2026-10-18, 66 dirty trees sat for good,
# 55 of them RETIRED lanes. For a retired lane's dirty tree only (a
# registry.retired.tsv row with this rundir, no registry.tsv row for the id;
# never a role seat, an alive record or a tree in use) a real run writes its
# work to a LOCAL git bundle (never pushed: the repo is public), archives the
# rest and logs the sha, and keeps the tree; a LATER pass removes it once the
# bundle verifies and the tree is unchanged. The include's header has the rules.
#   WT_SALVAGE                 1 (default, on since the dispatcher accepted the
#                              live run, SPL-2550) | 0 off
#   WT_SALVAGE_LOG             default $SPOOL_ROOT/wt-salvage.tsv
#   WT_SALVAGE_DIR             default $SPOOL_ROOT/wt-salvage (bundles + archives, mode 700)
#   WT_SALVAGE_RESIDUE_MAX_KB  default 10240
#
# Landed by patch (SPL-4287): a lane that rebased before its push leaves its
# worktree on the pre-rebase shas, which trunk never contains, so the tree
# was "not-on-trunk" for good: on sat, 2026-10-30, 47 such trees, 32 of them
# with every commit on trunk by patch-id. Such a tree is removed like a merged
# one, and its branch with `git branch -D` (its patches are on trunk);
# PLAN / REMOVE lines name it "landed-by-patch".
#
# One PLAN|REMOVE / KEEP / SALVAGE line per worktree, a DONE line.
# Exit: 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo="${WT_REPO:-$(git -C "$self_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')}"
wt_root="${WT_ROOT:-${repo}-wt}"
trunk="${WT_TRUNK:-origin/master}"
age_h="${WT_SWEEP_AGE_H:-72}"
# shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
. "$self_dir/../features/spawn-agents/lib/spool-env.inc.sh"
keep_re="${WT_SWEEP_KEEP_RE:-^(${SPL_ROLE_SEAT_RX}|CLE-00[1-3])$}"
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

salvage_on="${WT_SALVAGE:-1}"
# salvage_log, salvage_dir: read by wt-dirty-salvage.inc.sh
# shellcheck disable=SC2034
salvage_log="${WT_SALVAGE_LOG:-$spool/wt-salvage.tsv}"
# shellcheck disable=SC2034
salvage_dir="${WT_SALVAGE_DIR:-$spool/wt-salvage}"
residue_max_kb="${WT_SALVAGE_RESIDUE_MAX_KB:-10240}"
[[ "$salvage_on" == 0 || "$salvage_on" == 1 ]] || refuse "WT_SALVAGE must be 0 or 1, got '$salvage_on'"
[[ "$residue_max_kb" =~ ^[0-9]+$ ]] || refuse "WT_SALVAGE_RESIDUE_MAX_KB must be a whole number, got '$residue_max_kb'"
# shellcheck source=wt-dirty-salvage.inc.sh
. "$self_dir/wt-dirty-salvage.inc.sh"

# landed_by_patch <worktree>: 0 when HEAD has commits off trunk, none a merge,
# and every one of them is on trunk by patch (git cherry: no '+' line)
landed_by_patch() {
  local head out
  head="$(g -C "$1" rev-parse -q --verify HEAD 2>/dev/null)" || return 1
  [[ -z "$(g -C "$repo" rev-list --merges "$trunk..$head" 2>/dev/null)" ]] || return 1
  out="$(g -C "$repo" cherry "$trunk" "$head" 2>/dev/null)" || return 1
  [[ -n "$out" ]] && ! grep -q '^+' <<<"$out"
}

say "START repo=$repo root=$wt_root trunk=$trunk dry_run=$dry age_h=$age_h salvage=$salvage_on"
n_rm=0 kb_rm=0 n_keep=0 n_sv=0 kb_sv=0

# Every linked worktree, then every bare <ID>.stale-<UTC> dir (no .git).
list_dirs() {
  local d
  g -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p' | tail -n +2
  for d in "$wt_root"/*.stale-*; do
    [[ "${d##*/}" =~ ^[^/]+\.stale-[0-9]{8}T[0-9]{6}Z$ && -d "$d" && ! -L "$d" && ! -e "$d/.git" ]] && printf 'stale %s\n' "$d"
  done
}

while IFS= read -r wt; do
  stale=0; [[ "$wt" == "stale "* ]] && { stale=1; wt="${wt#stale }"; }
  wt="$(readlink -f "$wt")"
  [[ "${wt%/*}" == "$wt_root" ]] || continue
  id="${wt##*/}"; why=""; br=""; sv_sha=""; patched=""
  if (( stale )); then id="${id%%.stale-*}"
  else br="$(g -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" || br=""
  fi

  if [[ "$id" =~ $keep_re ]]; then why="role-seat"
  elif alive "$id"; then why="alive"
  elif grep -qxF -e "$wt" "$cwds" || grep -qF -e "$wt/" "$cwds"; then why="in-use"
  elif (( ! stale )) && [[ -n "$(g -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    why="dirty"
    # shellcheck disable=SC2154 # sv_why: set by salvage (wt-dirty-salvage.inc.sh)
    if [[ "$salvage_on" == 1 ]] && salvage_retired "$id" "$wt"; then salvage "$wt" "$id" "$br"; why="$sv_why"; fi
  fi
  if [[ -n "$why" ]]; then :
  elif (( ! stale )) && [[ -z "$sv_sha" ]] && ! g -C "$repo" merge-base --is-ancestor "$(g -C "$wt" rev-parse HEAD 2>/dev/null)" "$trunk" 2>/dev/null; then
    if landed_by_patch "$wt"; then patched=" landed-by-patch"; else why="not-on-trunk"; fi
  fi
  if [[ -n "$why" ]]; then :
  elif [[ -n "$(find "$wt" -name node_modules -prune -o -newermt "-${age_h} hours" -print -quit 2>/dev/null)" ]]; then why="recent"
  fi

  if [[ -n "$why" ]]; then
    say "KEEP $why $wt"; n_keep=$((n_keep + 1))
    [[ "$why" == dirty-retired-salvage* ]] && { kb="$(du -sk -- "$wt" 2>/dev/null | cut -f1)"; n_sv=$((n_sv + 1)); kb_sv=$((kb_sv + ${kb:-0})); }
    continue
  fi
  kb="$(du -sk -- "$wt" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB $wt${br:+ branch $br}${sv_sha:+ salvaged $sv_sha}$patched"
  elif [[ -n "$sv_sha" ]]; then
    g -C "$repo" worktree remove --force "$wt" || { say "WARN git refused to remove $wt"; continue; }
    [[ -n "$br" ]] && { g -C "$repo" branch -D "$br" >/dev/null 2>&1 || say "WARN branch $br kept (git branch -D refused)"; }
    say "REMOVE ${kb}KB $wt${br:+ branch $br} salvaged $sv_sha"
  elif (( stale )); then
    rm -rf -- "$wt" || { say "WARN rm refused to remove $wt"; continue; }
    say "REMOVE ${kb}KB $wt"
  else
    g -C "$repo" worktree remove "$wt" || { say "WARN git refused to remove $wt"; continue; }
    bd=-d; [[ -n "$patched" ]] && bd=-D
    [[ -n "$br" ]] && { g -C "$repo" branch "$bd" "$br" >/dev/null 2>&1 || say "WARN branch $br kept (git branch $bd refused)"; }
    say "REMOVE ${kb}KB $wt${br:+ branch $br}$patched"
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
done < <(list_dirs)

say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep $([[ "$dry" == 1 ]] && echo would-salvage || echo salvaged-pending)=$n_sv ($((kb_sv / 1024)) MB)"
