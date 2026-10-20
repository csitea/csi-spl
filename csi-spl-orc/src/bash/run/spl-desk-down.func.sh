#!/bin/bash
#------------------------------------------------------------------------------
# @description Take a desk agent off the air: stop the `spool hub-run` sidecar
# @description do_spl_desk_up started, so the agent goes OFFLINE in the WUI
# @description roster and a human's DM queues at the hub instead of reaching
# @description the pane. The box stays pinned and the inbox stays on disk: this
# @description is the reverse of the sidecar, not of the pin (revoke the pin
# @description with `spool hub-pin --box <box> --revoke --root-key <root key>`).
# @description ONE sidecar serves every agent seated on the box. So a DESK_AGENT
# @description run refuses while OTHER agents are seated on that live sidecar,
# @description and names them: an agent closing its own lane took every csi-rel
# @description agent offline for 40 min that way (SPL-1004, 2026-09-27 11:47Z).
# @description DESK_ALL=1 stops the box for everyone on purpose.
# @description A DESK_AGENT run also RELEASES that agent's seat: its spool dir
# @description moves to the desk's retired/ (inbox kept), so the sidecar stops
# @description announcing it on its next rescan (~10 s) and a per-workspace
# @description agent cap (spec 147) counts it free at once, not after the hub's
# @description dropDead timeout (up to 60 min on a DESK_RETIRE=0 customer desk).
# @description While other agents share the sidecar only the seat goes, the
# @description sidecar keeps running for them. An orchestrator or dispatcher
# @description seat (lease.conf) and a desk service id (SPL_DESK_AGENT_IDS:
# @description the responder, the ops desk) are never released here: on a
# @description shared sidecar it is refused, alone or with DESK_ALL=1 it only
# @description stops the sidecar. The responder sweep's standby step stops the
# @description RSP sidecar with DESK_AGENT=<the responder>; releasing that
# @description seat made the hub refuse every send of the responder and the
# @description issue closer (from_not_announced, sat-rsp + box-rsp, 2026-10-20).
# @description Prints one JSON line (box, agent, the pid it stopped, whether a
# @description sidecar was running at all). Idempotent: a desk that is already
# @description down is OK, not an error.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DESK_AGENT (optional) - the agent that leaves: its seat is released; the sidecar stops only when no other agent shares it
# @param DESK_ALL (optional) - 1 = stop the sidecar although other agents are seated on it
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DRY_RUN=0 ./run -a do_spl_desk_down
# @example ENV=prd TENANT_ID=csi-rel DESK_ALL=1 DRY_RUN=0 ./run -a do_spl_desk_down
#------------------------------------------------------------------------------
# spl_desk_seated <state dir>: the agent ids seated on the desk box, one per
# line - the agent directories under its spool root, which is what the one
# sidecar announces.
spl_desk_seated() {
  local a
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for a in "$1"/spool/*/; do
    a="${a%/}"; a="${a##*/}"
    [[ "$a" =~ ^${SPOOL_PARTICIPANT_RX}$ ]] && echo "$a"
  done
  return 0
}

do_spl_desk_down() {
  do_require_bin python3 || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  [[ -z "$agent" ]] || spl_is_participant_id "$agent" || { do_log "FATAL DESK_AGENT '$agent' is not an agent id (e.g. CLE-00)"; return 1; }

  local d="$SPL_STATE_DIR/desk/$tenant/$box" pidf pid="" was=0 rel=0 stop=0
  pidf="$d/spool/.hub/hub-run.pid"
  if spl_desk_alive "$pidf"; then was=1; stop=1; pid="$(cat "$pidf")"; fi
  [[ -n "$agent" && -d "$d/spool/$agent" ]] && ! spl_desk_is_od "$agent" &&
    [[ " ${SPL_DESK_AGENT_IDS:-} " != *" $agent "* ]] && rel=1
  if (( was )) && [[ -n "$agent" && "${DESK_ALL:-0}" != 1 ]]; then
    local others
    others="$(spl_desk_seated "$d" | grep -vx -- "$agent" | tr '\n' ' ')"
    if [[ -n "${others// /}" ]]; then
      if (( ! rel )); then
        do_log "FATAL the sidecar of $box in $tenant (pid $pid) also serves: ${others% }. Stopping it takes them ALL offline and nothing restarts it (SPL-1004). $agent has no seat this action releases (not seated, an orchestrator or dispatcher seat, or a desk service id); DESK_ALL=1 stops it for everyone"
        return 1
      fi
      stop=0
    fi
  fi
  local rdst
  rdst="$d/retired/$agent.$(date -u +%Y%m%dT%H%M%SZ)"
  if (( dry )); then
    (( rel )) && do_log "INFO DRY_RUN would: release the seat of $agent (move $d/spool/$agent to $rdst)"
    if (( stop )); then do_log "INFO DRY_RUN would: stop the hub-run sidecar of $box (pid $pid)"
    elif (( was )); then do_log "INFO DRY_RUN would: leave the hub-run sidecar of $box (pid $pid) running for the other seats"
    else do_log "INFO DRY_RUN nothing to stop: no live hub-run sidecar for $box in $tenant ($d)"; fi
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if (( rel )); then
    mkdir -p "$d/retired" && mv "$d/spool/$agent" "$rdst" ||
      { do_log "FATAL cannot release the seat of $agent (mv $d/spool/$agent $rdst)"; return 1; }
    do_log "INFO released the seat of $agent: its spool dir is at $rdst and the sidecar stops announcing it on its next rescan"
  fi
  (( stop )) || pid=""
  if (( stop )); then
    kill "$pid" 2>/dev/null || true
    local i
    for ((i = 0; i < 75; i++)); do spl_desk_alive "$pidf" || break; sleep 0.2; done
    spl_desk_alive "$pidf" && { kill -9 "$pid" 2>/dev/null || true; sleep 0.5; }
    spl_desk_alive "$pidf" && { do_log "FATAL the hub-run sidecar of $box (pid $pid) will not stop"; return 1; }
    rm -f "$pidf"
  fi
  python3 - "$ENV" "$tenant" "$box" "$agent" "$pid" "$was" "$d" "$rel" <<'EOF_PY'
import json, sys
env, tenant, box, agent, pid, was, state, rel = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent or None,
                  "stopped_pid": int(pid) if pid else None, "was_running": was == "1",
                  "released": rel == "1", "state_dir": state}, sort_keys=True))
EOF_PY
  if (( stop )); then do_log "OK the desk $box is down in $tenant ($ENV): stopped hub-run pid $pid"
  elif (( was )); then do_log "OK $agent left the desk $box in $tenant ($ENV); the sidecar keeps running for the other seats"
  else do_log "OK the desk $box was already down in $tenant ($ENV)"; fi
}
