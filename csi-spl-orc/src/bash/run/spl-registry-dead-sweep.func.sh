#!/bin/bash
#------------------------------------------------------------------------------
# @description Retire the open registry.tsv rows of agents long gone on THIS
# @description box (a box restart drill 2026-10-08: the watchdog walked ~25
# @description dead rows after the boot). An id is retired, through
# @description do_spl_agent_id_retire, only when ALL hold: not a role seat
# @description (001..004); no process carries SPOOL_AGENT_ID=<id>; no tmux
# @description window carries the id; no local branch <id>-* off the trunk;
# @description and its workdir is gone OR (the worktree is clean, HEAD on
# @description origin/master, and no verdict / heartbeat in REG_SWEEP_AGE_H).
# @description One "retire <id>: <why>" / "keep <id>: <why>" line per id, a
# @description DONE line with the counts. Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param REG_SWEEP_AGE_H (optional) - idle hours before retiring, default 24
# @param REG_SWEEP_REPO (optional) - main checkout whose <id>-* branches are
# @param   read, default this checkout's
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_registry_dead_sweep
# @example DRY_RUN=0 ./run -a do_spl_registry_dead_sweep
#------------------------------------------------------------------------------
do_spl_registry_dead_sweep() {
  local dry="${DRY_RUN:-1}" age_h="${REG_SWEEP_AGE_H:-24}" root="${SPOOL_ROOT:-/var/spool-hub}"
  local repo procs wins id wd why n_ret=0 n_keep=0 n_fail=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$age_h" =~ ^[0-9]+$ ]] && ((age_h >= 1)) || { do_log "FATAL REG_SWEEP_AGE_H must be a whole number >= 1, got: '$age_h'"; return 1; }
  [[ -r "$root/registry.tsv" ]] || { do_log "OK no $root/registry.tsv: nothing to sweep"; return 0; }
  repo="${REG_SWEEP_REPO:-$(git -c safe.directory='*' -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')}"
  procs="$(spl_reg_sweep_proc_ids)"
  wins="$(spl_reg_sweep_windows "$root")" || { do_log "FATAL cannot list the tmux windows: nothing retired"; return 1; }
  do_log "START registry=$root/registry.tsv dry_run=$dry age_h=$age_h repo=${repo:-none}"
  while IFS=$'\t' read -r id wd; do
    why="$(spl_reg_sweep_keep_why "$id" "$wd" "$procs" "$wins" "$repo" "$root" "$age_h")"
    if [[ "$why" != retire:* ]]; then
      echo "keep $id: $why"; n_keep=$((n_keep + 1)); continue
    fi
    if [[ "$dry" == 0 ]] && ! (AGENT_ID="$id" DRY_RUN=0 SPOOL_ROOT="$root" do_spl_agent_id_retire >/dev/null 2>&1); then
      echo "keep $id: do_spl_agent_id_retire refused"; n_fail=$((n_fail + 1)); continue
    fi
    echo "retire $id:${why#retire:}"; n_ret=$((n_ret + 1))
  done < <(spl_reg_sweep_rows "$root/registry.tsv")
  do_log "DONE $([[ "$dry" == 1 ]] && echo would-retire || echo retired)=$n_ret kept=$n_keep refused=$n_fail"
  ((n_fail == 0))
}

# One "<id>\t<workdir>" per id of the registry, from its last row (the latest spawn).
spl_reg_sweep_rows() {
  awk -F'\t' 'NF >= 4 && $1 != "" { wd[$1] = $4; if (!($1 in seen)) { seen[$1] = 1; ids[++n] = $1 } }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", ids[i], wd[ids[i]] }' "$1"
}

# Every SPOOL_AGENT_ID a running process carries, @box stripped, one per line:
# root's view when sudo -n works, else ours.
spl_reg_sweep_proc_ids() {
  { sudo -n sh -c 'cat /proc/[0-9]*/environ 2>/dev/null' 2>/dev/null || cat /proc/[0-9]*/environ 2>/dev/null; } |
    tr '\0' '\n' | sed -n 's/^SPOOL_AGENT_ID=//p' | sed 's/@.*//' | sort -u
}

# Every tmux window name on the box's socket; no server: none. A socket that
# exists but cannot be listed fails: a live window must never be missed.
spl_reg_sweep_windows() {
  (
    SPOOL_ROOT="$1"
    # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
    source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || exit 1
    spool_env_resolve
    spool_tmux_argv
    "${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null && exit 0
    [[ ! -e "$SPOOL_TMUX_SOCKET" ]] || grep -q 'no server running' <<<"$("${SPOOL_TM[@]}" ls 2>&1)"
  )
}

# "retire: <why>" when every guard passes, else the reason to keep the row.
spl_reg_sweep_keep_why() {
  local id="$1" wd="$2" procs="$3" wins="$4" repo="$5" root="$6" age_h="$7" head br
  if [[ "$id" =~ ^[A-Za-z]+-0*[1-4]$ ]]; then echo "role seat"; return; fi
  if grep -qxF -e "$id" <<<"$procs"; then echo "a process carries SPOOL_AGENT_ID=$id"; return; fi
  if grep -qE "(^|[^A-Za-z0-9])${id}([^0-9]|\$)" <<<"$wins"; then echo "a tmux window carries $id"; return; fi
  br="$(spl_reg_sweep_unpushed_branch "$id" "$repo")"
  if [[ -n "$br" ]]; then echo "unpushed: branch $br is not on origin/master"; return; fi
  if [[ -z "$wd" || ! -e "$wd" ]]; then echo "retire: workdir gone${wd:+ ($wd)}"; return; fi
  head="$(git -c safe.directory='*' -C "$wd" rev-parse -q --verify HEAD 2>/dev/null)"
  if [[ -z "$head" ]]; then echo "workdir $wd is not a git worktree"; return; fi
  if [[ -n "$(git -c safe.directory='*' -C "$wd" status --porcelain 2>/dev/null)" ]]; then echo "dirty worktree $wd"; return; fi
  if ! git -c safe.directory='*' -C "$wd" merge-base --is-ancestor "$head" origin/master 2>/dev/null; then
    echo "unpushed: HEAD ${head:0:8} is not on origin/master"; return
  fi
  if spl_reg_sweep_recent "$id" "$root" "$age_h"; then echo "verdict or heartbeat within ${age_h}h"; return; fi
  echo "retire: clean, on origin/master, idle ${age_h}h+"
}

# The first local branch <id> / <id>-* of REPO that is not on its origin/master.
spl_reg_sweep_unpushed_branch() {
  local id="$1" repo="$2" b
  [[ -n "$repo" && -e "$repo/.git" ]] || return 0
  while IFS= read -r b; do
    git -c safe.directory='*' -C "$repo" merge-base --is-ancestor "refs/heads/$b" origin/master 2>/dev/null || { echo "$b"; return 0; }
  done < <(git -c safe.directory='*' -C "$repo" for-each-ref --format='%(refname:short)' "refs/heads/$id" "refs/heads/$id-*" 2>/dev/null)
}

# True when the watchdog verdict or the heartbeat of ID changed within AGE_H hours.
spl_reg_sweep_recent() {
  local id="$1" root="$2" age_h="$3" f
  for f in "$root/dispatch/wd.$id" "$root/dispatch/wd/$id".* "$root/$id"/heartbeat.* "$root/$id"@*/heartbeat.*; do
    [[ -e "$f" && -n "$(find "$f" -maxdepth 0 -newermt "-${age_h} hours" 2>/dev/null)" ]] && return 0
  done
  return 1
}
