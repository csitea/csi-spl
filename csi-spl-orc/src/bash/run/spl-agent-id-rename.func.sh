#!/bin/bash
#------------------------------------------------------------------------------
# @description Give every live legacy-id agent of THIS machine its new id from
# @description the alias table do_spl_agent_id_map wrote (specs/061 FR-011,
# @description T061): its spool dir moves to the new name and leaves an
# @description old -> new link, the registry row and the identity record are
# @description rewritten, its tmux window is renamed, the desks it is seated on
# @description in RENAME_DESK_ENVS move to the new id (the box sidecar
# @description announces it on its next scan: the re-seat), and the agent gets
# @description ONE note "your id is now c-0NN; use --from c-0NN". Role ids
# @description (001-003) are renamed only with RENAME_ROLES=1 (L6), and then
# @description only they. An agent already renamed
# @description is skipped, so a re-run is safe.
# @description Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param RENAME_IDS (optional) - the legacy ids to rename (default: every
# @param   non-role row of the table this machine still holds)
# @param RENAME_DESK_ENVS (optional) - "dev", "dev prd": the hub envs whose
# @param   desks are re-seated (default none; prd needs the owner's go)
# @param RENAME_NOTE_FROM (optional) - the id the note is sent from (default
# @param   SPOOL_AGENT_ID)
# @param RENAME_ROLES (optional) - 1: rename the role rows 001-003 instead
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_id_rename
# @example DRY_RUN=0 RENAME_DESK_ENVS="dev prd" RENAME_NOTE_FROM=c-015 ./run -a do_spl_agent_id_rename
# @example DRY_RUN=0 RENAME_ROLES=1 RENAME_IDS=CLE-003 RENAME_DESK_ENVS="dev prd" ./run -a do_spl_agent_id_rename
#------------------------------------------------------------------------------
do_spl_agent_id_rename() {
  local dry=1 args=() id
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  (( dry )) || args+=(--apply)
  [[ "${RENAME_ROLES:-0}" == 1 ]] && args+=(--roles)
  [[ -n "${RENAME_DESK_ENVS:-}" ]] && args+=(--desk-envs "$RENAME_DESK_ENVS")
  [[ -n "${RENAME_NOTE_FROM:-}" ]] && args+=(--note-from "$RENAME_NOTE_FROM")
  for id in ${RENAME_IDS:-}; do args+=("$id"); done
  # The desks live under <state root>/<env>/desk; SPL_STATE_DIR names one env's.
  [[ -z "${DESK_STATE_ROOT:-}" && -n "${SPL_STATE_DIR:-}" ]] && export DESK_STATE_ROOT="${SPL_STATE_DIR%/*}"
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-id-rename.sh" "${args[@]}"
}
