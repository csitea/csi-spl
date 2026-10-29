#!/bin/bash
#------------------------------------------------------------------------------
# @description The pre-shutdown clean-tree check of THIS box (SPL-4202, spec
# @description 069; box shutdown drill 2026-10-29): is the work of every LIVE lane
# @description pushed? On the drill a manual loop over every worktree root
# @description folder read 358 folders, dozens of them retired lanes still
# @description dirty (a-461, c-005, c-135 ...), and that noise hid the live
# @description rows, the ones that matter before a switch-off.
# @description A live lane is an agent id a running process carries
# @description (SPOOL_AGENT_ID, as the lease loop reads /proc). Its worktree is
# @description its latest registry.tsv run dir, else <worktree root>/<id>.
# @description   1. one row per live lane: id | pushed | worktree, pushed =
# @description      yes / no (<n> unpushed, <m> dirty) / n/a (no own worktree),
# @description      as do_spl_box_leave's table reads it;
# @description   2. the other folders of the worktree root are RETIRED: one
# @description      count line (scanned, dirty or unpushed), their ids only
# @description      with CLEAN_TREE_LIST_RETIRED=1;
# @description   3. "CLEAN: every live lane pushed" (exit 0) or "NOT CLEAN: <n>
# @description      live lanes hold unpushed or dirty work" (exit 3).
# @description Read-only: it writes nothing, sends nothing, fetches nothing.
# @param SPOOL_WT_ROOT (optional) - the worktree root, default /opt/csi/csi-spl-wt
# @param SPOOL_ROOT (optional) - the spool root (its registry.tsv), default /var/spool-hub
# @param CLEAN_TREE_LIST_RETIRED (optional) - 1 = also list the dirty retired ids; default 0
# @param LEASE_PROC_ROOT (tests) - the /proc to read the live ids from
# @example ./run -a do_spl_box_clean_tree
# @example CLEAN_TREE_LIST_RETIRED=1 ./run -a do_spl_box_clean_tree
#------------------------------------------------------------------------------
# spl_box_pushed / spl_box_rundir (and spl_lease_live_ids through it)
declare -F spl_box_pushed >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-leave.func.sh"

do_spl_box_clean_tree() {
  local root="${SPOOL_WT_ROOT:-/opt/csi/csi-spl-wt}" list="${CLEAN_TREE_LIST_RETIRED:-0}"
  [[ "$list" =~ ^[01]$ ]] || { do_log "FATAL CLEAN_TREE_LIST_RETIRED must be 0 or 1, got '$list'"; return 1; }
  local -a ids=() rest=()
  local id d p bad=0 seen=" " scanned=0 dirty=0
  mapfile -t ids < <(spl_lease_live_ids)
  echo "clean-tree: ${#ids[@]} live lanes (worktree root $root)"
  echo "1. agent | pushed | worktree"
  for id in "${ids[@]}"; do
    d="$(spl_box_clean_tree_dir "$id" "$root")"
    p="$(spl_box_pushed "$d" no)"
    [[ "$p" == no* ]] && bad=$((bad + 1))
    [[ -n "$d" ]] && seen+="$(readlink -f "$d") "
    echo "   $id | $p | ${d:-none}"
  done
  (( ${#ids[@]} )) || echo "   (no live lanes)"
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    [[ "$seen" == *" $(readlink -f "$d") "* ]] && continue
    scanned=$((scanned + 1))
    [[ "$(spl_box_pushed "$d" no)" == no* ]] || continue
    dirty=$((dirty + 1)); rest+=("${d##*/}")
  done
  echo "2. retired worktrees (no live agent): $scanned scanned, $dirty dirty or unpushed (not in the verdict)"
  [[ "$list" == 1 ]] && (( dirty )) && echo "   ${rest[*]}"
  if (( bad )); then
    echo "NOT CLEAN: $bad live lanes hold unpushed or dirty work"
    return 3
  fi
  echo "CLEAN: every live lane pushed"
}

# The worktree of a live <id>: its latest registry run dir when it exists, else
# <root>/<id> when it exists, else empty (no own worktree).
spl_box_clean_tree_dir() {
  local d
  d="$(spl_box_rundir "$1")"
  [[ -n "$d" && -d "$d" ]] && { echo "$d"; return 0; }
  [[ -d "$2/$1" ]] && echo "$2/$1"
  return 0
}
