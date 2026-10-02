#!/bin/bash
#------------------------------------------------------------------------------
# @description Prove an agent's spool MCP server (do_spl_agent_mcp_install) the
# @description way its CLI uses it, and price it: spool-mcp-probe.py starts
# @description <agent home>/.local/bin/spool-mcp <env> as AGENT_USER with
# @description MCP_BOT_AGENT_ID=<MCP_AS>, speaks MCP over stdio and prints one
# @description JSON line:
# @description   - the five tools, and a SEATED schema (from / as optional)
# @description   - CONTROL: spool_recv as another agent (MCP_CONTROL_AS) is
# @description     REFUSED. Read-only: it never acks
# @description   - spool_recv of the own seat
# @description   - with MCP_TO / MCP_TO_BOX: MCP_N spool_send notes, each
# @description     timed from the tool call to its result (the hub's ack of the
# @description     frame: delivery sent / queued), and with MCP_FILE=1 a file
# @description     put -> sent attached -> got back, sha256 compared
# @description Without MCP_TO nothing is sent and it runs for real. With MCP_TO
# @description it sends real messages into the tenant: dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param AGENT_USER - required: the OS user the agent CLIs run as
# @param MCP_AS - required: the seated agent id to act as
# @param MCP_CONTROL_AS (optional) - another agent id; its inbox must be refused
# @param MCP_TO / MCP_TO_BOX (optional) - the recipient and its box for the sends
# @param MCP_TASK (optional) - the topic uuid for the sends, default a new one
# @param MCP_N (optional) - timed sends, default 6
# @param MCP_FILE (optional) - 1 = also the file round trip, default 0
# @param DRY_RUN (optional) - 1 (default) or 0; only matters with MCP_TO
# @example ENV=prd AGENT_USER=<agent user> MCP_AS=CLE-01 MCP_CONTROL_AS=CLE-02 ./run -a do_spl_agent_mcp_probe
# @example ENV=dev AGENT_USER=<agent user> MCP_AS=CLE-01 MCP_TO=EZA-1 MCP_TO_BOX=box-e2e-a MCP_FILE=1 DRY_RUN=0 ./run -a do_spl_agent_mcp_probe
#------------------------------------------------------------------------------
do_spl_agent_mcp_probe() {
  do_require_bin python3 getent sudo || return 1
  local envn="${ENV:-}" agent="${AGENT_USER:-}" as="${MCP_AS:-}" ctl="${MCP_CONTROL_AS:-}"
  local to="${MCP_TO:-}" tobox="${MCP_TO_BOX:-}" task="${MCP_TASK:-}" n="${MCP_N:-6}" file="${MCP_FILE:-0}"
  spl_require_cloud_env "$envn" || return 1
  [[ "$agent" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL AGENT_USER must name the agent OS user, got: '$agent'"; return 1; }
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_participant_id "$as" || { do_log "FATAL MCP_AS must be an agent id, got: '$as'"; return 1; }
  [[ -z "$ctl" ]] || { spl_is_participant_id "$ctl" && [[ "$ctl" != "$as" ]]; } || { do_log "FATAL MCP_CONTROL_AS must be ANOTHER agent id, got: '$ctl'"; return 1; }
  [[ "$n" =~ ^[0-9]+$ && "$n" -le 50 ]] || { do_log "FATAL MCP_N must be 0..50, got: '$n'"; return 1; }
  [[ "$file" == 0 || "$file" == 1 ]] || { do_log "FATAL MCP_FILE must be 0 or 1, got: '$file'"; return 1; }
  [[ -z "$task" || "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { do_log "FATAL MCP_TASK must be a task uuid"; return 1; }
  local -a args=(--as "$as")
  [[ -n "$ctl" ]] && args+=(--control-as "$ctl")
  if [[ -n "$to" ]]; then
    { spl_is_participant_id "$to" || [[ "$to" =~ ^HUM-[A-Za-z0-9_-]{1,64}$ ]]; } && [[ "$tobox" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] ||
      { do_log "FATAL MCP_TO needs an agent or human id and MCP_TO_BOX a box id, got: '$to' '$tobox'"; return 1; }
    local dry=1
    if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
    if (( dry )); then
      do_log "INFO DRY_RUN would: as $as ($ENV) send $n timed note(s)$( ((file)) && echo ' and one file') to $to on $tobox"
      do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0, or without MCP_TO for the read-only checks."
      return 0
    fi
    args+=(--to "$to" --to-box "$tobox" --n "$n")
    [[ -n "$task" ]] && args+=(--task "$task")
    (( file )) && args+=(--file)
  fi
  local ahome py out rc=0
  ahome="$(getent passwd "$agent" | cut -d: -f6)"
  py="$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-mcp-probe.py"
  # the agent user runs the probe, fed through stdin: it may not read this checkout
  if [[ "$agent" == "$(id -un)" ]]; then
    out="$(python3 - --cmd "$ahome/.local/bin/spool-mcp" "$envn" "${args[@]}" <"$py")" || rc=$?
  else
    out="$(sudo -n -u "$agent" -H python3 - --cmd "$ahome/.local/bin/spool-mcp" "$envn" "${args[@]}" <"$py")" || rc=$?
  fi
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FAIL the spool MCP probe of $as on $envn did not hold (see the checks above)"; return 1; }
  do_log "OK $as's spool-$envn MCP server holds: seated$( [[ -n "$ctl" ]] && echo ", $ctl's inbox refused")$( [[ -n "$to" ]] && echo ", $n send(s) to $to@$tobox timed")"
}
