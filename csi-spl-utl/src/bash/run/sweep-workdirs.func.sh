#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the finished lanes' working directories listed in this
# @description box's table ($SPOOL_ROOT/workdirs.tsv; the retire lists a lane's
# @description worktree, /tmp scratch and /var/tmp leftovers there instead of
# @description removing them) once their finished_at is older than cnf
# @description env.box.workdir_sweep.age_h (24) hours, or crit_age_h (6) when the
# @description disk is critical (free % <= crit_free_pct, 8), oldest first. Only
# @description an unheld directory goes (no process cwd or open fd under it); a
# @description worktree only clean and on its listed branch, through `git
# @description worktree remove`, then `git branch -d` (merged only). One KEEP
# @description line says why a row stays. Dry run unless DRY_RUN=0. The box disk
# @description sweep (csi-spl-orc do_box_disk_sweep, step workdirs) runs it from
# @description its cron line; run it by hand the same way.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param WORKDIR_SWEEP_AGE_H (optional) - default cnf env.box.workdir_sweep.age_h, else 24
# @param WORKDIR_SWEEP_CRIT_AGE_H (optional) - default cnf env.box.workdir_sweep.crit_age_h, else 6
# @param WORKDIR_SWEEP_CRIT_FREE_PCT (optional) - default cnf env.box.workdir_sweep.crit_free_pct, else 8
# @param WORKDIR_SWEEP_FREE_PCT (optional) - the measured free % (the box sweep's), default measured here
# @param WORKDIR_TABLE (optional) - default $SPOOL_ROOT/workdirs.tsv
# @example ./run -a do_sweep_workdirs
# @example DRY_RUN=0 ./run -a do_sweep_workdirs
#------------------------------------------------------------------------------
do_sweep_workdirs() {
  local oa cnf k v
  oa="$(basename "$PROJ_PATH")"; oa="${oa%-utl}"
  cnf="${WORKDIR_SWEEP_CNF:-$PROJ_PATH/../$oa-cnf/$oa/all.env.yaml}"
  for k in age_h crit_age_h crit_free_pct; do
    v="WORKDIR_SWEEP_${k^^}"
    [[ -n "${!v:-}" ]] && continue
    [[ -r "$cnf" ]] && command -v yq >/dev/null 2>&1 || continue
    printf -v "$v" '%s' "$(yq -r ".env.box.workdir_sweep.$k // \"\"" "$cnf" 2>/dev/null)"
    [[ -n "${!v}" ]] && export "${v?}"
  done
  DRY_RUN="${DRY_RUN:-1}" SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$PROJ_PATH/src/bash/scripts/workdir-sweep.sh"
}
