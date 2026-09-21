#!/bin/bash
#------------------------------------------------------------------------------
# @description Take a desk agent off the air: stop the `spool hub-run` sidecar
# @description do_spl_desk_up started, so the agent goes OFFLINE in the WUI
# @description roster and a human's DM queues at the hub instead of reaching
# @description the pane. The box stays pinned and the inbox stays on disk: this
# @description is the reverse of the sidecar, not of the pin (revoke the pin
# @description with `spool hub-pin --box <box> --revoke --root-key <root key>`).
# @description Prints one JSON line (box, agent, the pid it stopped, whether a
# @description sidecar was running at all). Idempotent: a desk that is already
# @description down is OK, not an error.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DESK_AGENT (optional) - recorded in the output; the sidecar serves the whole box
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DRY_RUN=0 ./run -a do_spl_desk_down
#------------------------------------------------------------------------------
do_spl_desk_down() {
  do_require_bin python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ -z "$agent" || "$agent" =~ ^[A-Z]{2,4}-[0-9]+$ ]] || { do_log "FATAL DESK_AGENT '$agent' is not an agent id (e.g. CLE-00)"; return 1; }

  local d="$SPL_STATE_DIR/desk/$tenant/$box" pidf pid="" was=0
  pidf="$d/spool/.hub/hub-run.pid"
  if spl_desk_alive "$pidf"; then was=1; pid="$(cat "$pidf")"; fi
  if (( dry )); then
    if (( was )); then do_log "INFO DRY_RUN would: stop the hub-run sidecar of $box (pid $pid)"
    else do_log "INFO DRY_RUN nothing to stop: no live hub-run sidecar for $box in $tenant ($d)"; fi
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to stop it."
    return 0
  fi
  if (( was )); then
    kill "$pid" 2>/dev/null || true
    local i
    for ((i = 0; i < 75; i++)); do spl_desk_alive "$pidf" || break; sleep 0.2; done
    spl_desk_alive "$pidf" && { kill -9 "$pid" 2>/dev/null || true; sleep 0.5; }
    spl_desk_alive "$pidf" && { do_log "FATAL the hub-run sidecar of $box (pid $pid) will not stop"; return 1; }
    rm -f "$pidf"
  fi
  python3 - "$ENV" "$tenant" "$box" "$agent" "$pid" "$was" "$d" <<'EOF_PY'
import json, sys
env, tenant, box, agent, pid, was, state = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent or None,
                  "stopped_pid": int(pid) if pid else None, "was_running": was == "1",
                  "state_dir": state}, sort_keys=True))
EOF_PY
  if (( was )); then do_log "OK the desk $box is down in $tenant ($ENV): stopped hub-run pid $pid"
  else do_log "OK the desk $box was already down in $tenant ($ENV)"; fi
}
