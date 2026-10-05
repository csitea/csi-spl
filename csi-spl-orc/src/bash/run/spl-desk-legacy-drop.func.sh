#!/bin/bash
#------------------------------------------------------------------------------
# @description List, and with DRY_RUN=0 drop, the legacy agent ids (CLE-/GRK-/
# @description AGY-/QWN-, spec 061: retired as ids 2026-10-03) that a hub desk
# @description of THIS machine still announces as members / tag targets. A
# @description desk sidecar announces every agent dir of its spool root, so a
# @description seat left there after the cutoff is a tag target the hub then
# @description refuses (owner 2026-10-05, t1 dc6d5e3f: "I should be able to
# @description tag only currently active agents"; the csi-rel prd desk
# @description announced AGY-3499, CLE-002, CLE-003). One SEATED line per
# @description desk, then one drop line per seat; a dropped seat moves to its
# @description spool root's .retired/<ID>.<utc>/ (unread mail kept) and is gone
# @description from the sidecar's next 10 s announce. Role ids CLE-001..003
# @description are dropped too: their successors c-001..003 are seated.
# @description Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param DESK_ENVS (optional) - default "dev prd"
# @param DESK_TENANT (optional) - one tenant (default every tenant)
# @param DESK_BOX (optional) - one box's desks (default every box dir)
# @param DESK_STATE_ROOT (optional) - default $HOME/.local/share/csi-spl/cloud
# @example ./run -a do_spl_desk_legacy_drop
# @example DESK_ENVS=prd DESK_BOX=sat DRY_RUN=0 ./run -a do_spl_desk_legacy_drop
#------------------------------------------------------------------------------
do_spl_desk_legacy_drop() {
  local args=(--legacy)
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; args+=(--apply); fi
  [[ -n "${DESK_BOX:-}" ]] && args+=(--box "$DESK_BOX")
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/desk-seat-drop.sh" "${args[@]}" || return 1
}
