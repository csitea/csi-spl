#!/bin/bash
#------------------------------------------------------------------------------
# @description The box's pick-up of the channel moves a person confirmed in the
# @description web UI (spec 169, csi-spl-doc/specs/169-channel-workspace-move,
# @description section 8.5.5 item 3, row T16). The confirm writes the person's
# @description GO and runs P1 on the hub; the box steps (P2b, P5) can only run
# @description on a box, so this action reads every open journal through the
# @description hub's operator op "open" and runs do_spl_channel_workspace_move
# @description (MOVE_CMD=run) for each, with the journal's GO, P1's stored detail
# @description (detail.inputs: keep, keep_emails, leave_hours, rule_doc, caller)
# @description and MOVE_CALLER = a <DST> orchestrator seat (the detail's caller,
# @description else one on this box, else the first the hub lists). It runs only
# @description on the box of the orch lease (<spool root>/dispatch/lease.orch):
# @description anywhere else it runs nothing. One pick-up at a time per box
# @description (flock), and each move keeps its own channel lock.
# @description A journal whose P1 is not done, or whose P1 kept no detail.inputs
# @description (R7 c-250 N4: P1's second write failed), is not run: sending {}
# @description would apply none of the person's decisions. It says so; the move
# @description then reads as waiting (8.5.6) until the operator runs P1 again
# @description with its detail (MOVE_FROM=P1 MOVE_DETAIL=<json>).
# @description A refused step is stored by the hub in the step's row (8.5.6) and
# @description the next pick-up resumes at the first step not done.
# @description DRY_RUN=1 (default) runs each move as MOVE_CMD=run DRY_RUN=1: it
# @description prints the steps a run would do and changes nothing.
# @param ENV (required) - dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param CHANNEL_MOVE_PICKUP_HOLDER (optional, tests) - the orch holder <ID>@<box>, instead of lease.orch
# @param CHANNEL_MOVE_HUB_CMD (optional, tests) - a command in place of the T7 call, as do_spl_channel_workspace_move's
# @param CHANNEL_MOVE_STATE (optional) - the box journal dir, default $SPOOL_ROOT/channel-move
# @example ENV=prd ./run -a do_spl_channel_move_pickup
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_channel_move_pickup
#------------------------------------------------------------------------------
do_spl_channel_move_pickup() {
  do_require_bin jq flock || return 1
  spl_require_cloud_env || return 1
  local dry=1 holder lockd
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  holder="$(_spl_cmp_holder_here)" || return 0
  lockd="${CHANNEL_MOVE_STATE:-${SPOOL_ROOT:-/var/spool-hub}/channel-move}"
  mkdir -p "$lockd" || { do_log "FATAL cannot make $lockd"; return 1; }
  (
    flock -n 9 || { do_log "OK channel move pick-up: another pick-up runs on this box ($lockd/pickup.lock)"; exit 0; }
    _spl_cmp_run "$holder" "$dry"
  ) 9>>"$lockd/pickup.lock"
}

# _spl_cmp_holder_here: the orch holder <ID>@<box> on stdout when it is on this
# box; 1 (and why, logged) when nobody holds it or another box does.
_spl_cmp_holder_here() {
  local h="${CHANNEL_MOVE_PICKUP_HOLDER:-}" f="${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.orch" box
  [[ -n "$h" || ! -r "$f" ]] || read -r h _ <"$f"
  box="$(spl_desk_box_default)"
  case "$h" in
    ''|none@*|unknown:*) do_log "OK channel move pick-up: no orchestrator holds the orch role: nothing picked up" >&2; return 1 ;;
  esac
  if [[ "$h" != *@* || "${h##*@}" != "$box" ]]; then
    do_log "OK channel move pick-up: the orch role is held on ${h##*@} ($h), not on $box: its box picks up" >&2
    return 1
  fi
  printf '%s\n' "$h"
}

# _spl_cmp_run <holder> <dry>: one pass over the open journals. 1 when a move
# failed or could not be read; the others still run.
_spl_cmp_run() {
  local open rc=0 n=0 row
  _spl_cwm_hub_wire || return 1
  open="$(_spl_cmp_open)" || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    n=$((n + 1))
    _spl_cmp_one "$1" "$2" "$row" || rc=1
  done < <(jq -c '.moves // [] | .[]' <<<"$open")
  do_log "OK channel move pick-up: $n open journal(s) read on $(spl_desk_box_default) as ${1%@*}"
  return "$rc"
}

# _spl_cmp_open: op open through the seam; the answer JSON on stdout.
_spl_cmp_open() {
  local req out rc=0
  req="$(jq -cn --arg env "$ENV" '{op: "open", env: $env}')" || return 1
  if [[ -n "${CHANNEL_MOVE_HUB_CMD:-}" ]]; then out="$(bash -c "$CHANNEL_MOVE_HUB_CMD" <<<"$req")" || rc=$?
  else out="$(_spl_cwm_hub_post <<<"$req")" || rc=$?; fi
  if (( rc != 0 )) || ! jq -e '.moves | type == "array"' >/dev/null 2>&1 <<<"$out"; then
    do_log "FATAL the hub refused op open (exit $rc): $out"
    return 1
  fi
  printf '%s\n' "$out"
}

# _spl_cmp_one <holder> <dry> <move json>: runs one journal, in a subshell so
# no CWM_ global of one move reaches the next.
_spl_cmp_one() {
  local m="$3" id src ch dst go inputs caller
  IFS=$'\x1f' read -r id src ch dst go < <(jq -r '[.move_id, .src, .channel, .dst, .go_msg_id] | map(. // "") | join("\u001f")' <<<"$m")
  if [[ "$(jq -r '.steps.P1 // ""' <<<"$m")" != "done" ]]; then
    do_log "OK channel move pick-up: move $id ($src/$ch -> $dst): P1 is not done, the confirm's to finish: not picked up"
    return 0
  fi
  inputs="$(jq -c '.inputs' <<<"$m")"
  if [[ "$inputs" != \{* ]]; then
    do_log "WARN channel move pick-up: move $id ($src/$ch -> $dst): P1 kept no detail.inputs, so the person's decisions are unknown: not picked up, never run with {}. Run P1 again with its detail: CHANNEL=$src/$ch TO=$dst MOVE_CMD=run MOVE_FROM=P1 MOVE_DETAIL=<json> MOVE_GO_MSG=$go"
    return 1
  fi
  caller="$(_spl_cmp_caller "$m")"
  [[ -n "$caller" ]] || { do_log "WARN channel move pick-up: move $id ($src/$ch -> $dst): $dst has no orchestrator seat on its roster: not picked up (P2 refuses it)"; return 1; }
  do_log "OK channel move pick-up: move $id ($src/$ch -> $dst), MOVE_CALLER $caller, DRY_RUN=$2"
  ( ENV="$ENV" CHANNEL="$src/$ch" TO="$dst" MOVE_MODE=move MOVE_CMD=run TO_NAME="" MOVE_FROM="" MOVE_GO_MSG="$go" \
      MOVE_DETAIL="$inputs" MOVE_CALLER="$caller" AGENT_ID="${1%@*}" DRY_RUN="$2" do_spl_channel_workspace_move ) || {
    do_log "WARN channel move pick-up: move $id ($src/$ch -> $dst) stopped (above); the hub keeps the refusal, the next pick-up resumes it"
    return 1
  }
}

# _spl_cmp_caller <move json>: the detail's caller, else the <DST> orchestrator
# seat on this box, else the first the hub lists; "" with none.
_spl_cmp_caller() {
  jq -r --arg box "$(spl_desk_box_default)" '(.inputs.caller // "") as $c | (.orchestrators // []) as $o
    | if $c != "" then $c else ([$o[] | select(endswith("@" + $box))] + $o | .[0] // "") end' <<<"$1"
}
