#!/bin/bash
#------------------------------------------------------------------------------
# @description Move (or copy) a whole channel into another workspace (spec
# @description 169, csi-spl-doc/specs/169-channel-workspace-move, row T9).
# @description The hub does the rows, the blobs and the journal through its
# @description operator endpoint (row T7); this action drives it step by step
# @description (section 8.2) and runs the box steps on this box
# @description (channel-workspace-move-box.sh, row T10):
# @description   P1 plan + freeze the set in the <DST> journal  (hub)
# @description   P2 checks: desks, quotas, shared items       (hub)
# @description   P2b one probe DM per seat via its <DST> desk (box, move only)
# @description   P3 copy blobs and Qto objects                (hub)
# @description   P4 the one database transaction              (hub)
# @description   P5 box rule row to <DST>, lane key notes     (box, move only)
# @description   P6 delete the <SRC> objects                  (hub, move only)
# @description   P7 the proofs of section 5                   (hub)
# @description MOVE_CMD=plan (the default) asks the hub for the plan and prints
# @description it; it changes nothing, and exits 3 when the plan refuses
# @description (a seat with no <DST> desk, a shared item, a hub refusal).
# @description MOVE_CMD=run reads the hub journal and resumes at the first step
# @description not done; DRY_RUN=1 (default) only prints those steps. P1-P4
# @description may be re-run until P4 commits; after that MOVE_FROM may not
# @description name P1-P4 (exit 3). DRY_RUN=0 is the owner's: it needs his
# @description (GO) poll answer's msg id, sent with every hub step.
# @description MOVE_CMD=probe is P2b's send, run by the box script for one
# @description seat: an agent-to-agent DM from PROBE_AGENT through its <TO>
# @description desk on THIS machine to PROBE_TO, the <DST> orchestrator seat
# @description (an agent: the hub's human-post guard refuses a probe DM to a
# @description person), on the task PROBE_MOVE. A seat whose <DST> desk is on
# @description another machine fails its probe, and the move stops before P3:
# @description run the move on the machine of its seats' desks (spec 167
# @description first, R5). DRY_RUN=1 checks the arguments only.
# @description NOT WIRED YET: the T7 endpoint does not exist. The hub is
# @description reached only through the seam CHANNEL_MOVE_HUB_CMD, a command
# @description that reads one request JSON on stdin ({op, env, src, channel,
# @description dst, mode, to_name, move_id, go_msg_id, step, detail}; op is
# @description plan, journal, step or mark) and prints the answer JSON (exit
# @description non-zero = refused). Without it the action stops with a FATAL.
# @param ENV - required: dev or prd
# @param CHANNEL - required: <SRC>/<channel id>, the workspace and channel to move
# @param TO - required: the <DST> workspace slug
# @param MOVE_MODE (optional) - move (default) or copy
# @param MOVE_CMD (optional) - plan (default) or run
# @param TO_NAME (optional) - the channel id in <DST> when <channel id> is taken there
# @param MOVE_FROM (optional) - restart at this step (P1..P7, P2b) instead of the journal's
# @param MOVE_GO_MSG - required for run with DRY_RUN=0: the owner's GO poll answer msg id
# @param MOVE_CALLER - required for a move with DRY_RUN=0: the <DST> orchestrator seat, <agent id>[@<box>], the probe DMs go to
# @param AGENT_ID - required for a move with DRY_RUN=0: the agent id the lane key notes come from
# @param CHANNEL_MOVE_HUB_CMD (optional) - the hub seam above (until T7 is wired)
# @param CHANNEL_MOVE_STATE (optional) - the box journal dir, default $SPOOL_ROOT/channel-move
# @param PROBE_AGENT, PROBE_TO, PROBE_MOVE (MOVE_CMD=probe only) - the seat, the recipient <agent id>[@<box>], the move id
# @param DESK_BOX (optional, MOVE_CMD=probe) - the seat's box id, default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd CHANNEL=<SRC>/<channel> TO=<DST> ./run -a do_spl_channel_workspace_move
# @example ENV=prd CHANNEL=<SRC>/<channel> TO=<DST> MOVE_CMD=run ./run -a do_spl_channel_workspace_move
#------------------------------------------------------------------------------
do_spl_channel_workspace_move() {
  do_require_bin jq flock || return 1
  if [[ "${MOVE_CMD:-}" == probe ]]; then _spl_cwm_probe_send; return $?; fi
  _spl_cwm_args || return $?
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if [[ "$CWM_CMD" == run && $dry -eq 0 ]]; then _spl_cwm_args_live || return $?; fi
  [[ -n "${CHANNEL_MOVE_HUB_CMD:-}" ]] || {
    do_log "FATAL the hub's channel move endpoint (spec 169 T7) is not wired yet: set CHANNEL_MOVE_HUB_CMD"
    return 2
  }
  if [[ "$CWM_CMD" == plan ]]; then _spl_cwm_plan; return $?; fi
  if (( dry )); then _spl_cwm_run 1; return $?; fi
  local lockd="${CHANNEL_MOVE_STATE:-${SPOOL_ROOT:-/var/spool-hub}/channel-move}"
  mkdir -p "$lockd" || { do_log "FATAL cannot make $lockd"; return 1; }
  (
    flock -n 9 || { do_log "FATAL another move of $CWM_SRC/$CWM_CH runs ($lockd/$CWM_SRC.$CWM_CH.lock)"; exit 3; }
    _spl_cwm_run 0
  ) 9>>"$lockd/$CWM_SRC.$CWM_CH.lock"
}

# _spl_cwm_args: checks the input, sets CWM_SRC CWM_CH CWM_DST CWM_MODE CWM_CMD
# CWM_NAME CWM_FROM. Nothing is called before it passes.
_spl_cwm_args() {
  local ch="${CHANNEL:-}" rx='^[a-z0-9][a-z0-9-]{0,63}$'
  spl_require_cloud_env || return 1
  [[ "$ch" == */* ]] || { do_log "FATAL CHANNEL must be <SRC>/<channel id>, got: '$ch'"; return 1; }
  CWM_SRC="${ch%%/*}"; CWM_CH="${ch#*/}"; CWM_DST="${TO:-}"
  spl_require_tenant_slug "$CWM_SRC" || return 1
  [[ "$CWM_CH" =~ $rx ]] || { do_log "FATAL CHANNEL's channel id must match $rx, got: '$CWM_CH'"; return 1; }
  spl_require_tenant_slug "$CWM_DST" || return 1
  [[ "$CWM_DST" != "$CWM_SRC" ]] || { do_log "FATAL TO is the channel's own workspace $CWM_SRC"; return 1; }
  CWM_MODE="${MOVE_MODE:-move}"; CWM_CMD="${MOVE_CMD:-plan}"; CWM_NAME="${TO_NAME:-$CWM_CH}"; CWM_FROM="${MOVE_FROM:-}"
  [[ "$CWM_MODE" =~ ^(move|copy)$ ]] || { do_log "FATAL MOVE_MODE must be move or copy, got: '$CWM_MODE'"; return 1; }
  [[ "$CWM_CMD" =~ ^(plan|run)$ ]] || { do_log "FATAL MOVE_CMD must be plan or run, got: '$CWM_CMD'"; return 1; }
  [[ "$CWM_NAME" =~ $rx ]] || { do_log "FATAL TO_NAME must match $rx, got: '$CWM_NAME'"; return 1; }
  [[ -z "$CWM_FROM" || " $(_spl_cwm_steps) " == *" $CWM_FROM "* ]] || {
    do_log "FATAL MOVE_FROM must be one of: $(_spl_cwm_steps) (MOVE_MODE=$CWM_MODE), got: '$CWM_FROM'"
    return 1
  }
}

# _spl_cwm_args_live: what DRY_RUN=0 needs besides (section 8.1, C15).
_spl_cwm_args_live() {
  local u='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [[ "${MOVE_GO_MSG:-}" =~ $u ]] || {
    do_log "FATAL DRY_RUN=0 is the owner's: MOVE_GO_MSG must carry the msg id of his (GO) poll answer for $CWM_SRC/$CWM_CH -> $CWM_DST"
    return 3
  }
  [[ "$CWM_MODE" == move ]] || return 0
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  _spl_cwm_is_seat "${MOVE_CALLER:-}" || {
    do_log "FATAL MOVE_CALLER must be the $CWM_DST orchestrator seat, <agent id>[@<box>] (the probe DMs of P2b go to it; never a HUM-: the hub refuses a probe DM to a person), got: '${MOVE_CALLER:-}'"
    return 1
  }
  spl_is_agent_id "${AGENT_ID:-}" || { do_log "FATAL AGENT_ID must be an agent id (the lane key notes of P5 come from it), got: '${AGENT_ID:-}'"; return 1; }
}

# _spl_cwm_is_seat <id>[@<box>]: 0 for an agent id with an optional box.
_spl_cwm_is_seat() {
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  [[ "$1" != *@* || "${1#*@}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && spl_is_agent_id "${1%@*}"
}

_spl_cwm_steps() {
  if [[ "${CWM_MODE:-move}" == copy ]]; then echo "P1 P2 P3 P4 P7"; else echo "P1 P2 P2b P3 P4 P5 P6 P7"; fi
}

# _spl_cwm_hub <op> [step] [detail json]: one call through the seam; the
# answer JSON on stdout. A refusal: FATAL with the hub's answer, 1.
_spl_cwm_hub() {
  local req out rc=0
  req="$(jq -cn --arg op "$1" --arg env "$ENV" --arg src "$CWM_SRC" --arg ch "$CWM_CH" --arg dst "$CWM_DST" \
    --arg mode "$CWM_MODE" --arg name "$CWM_NAME" --arg move "${CWM_MOVE:-}" --arg go "${MOVE_GO_MSG:-}" \
    --arg step "${2:-}" --argjson detail "${3:-null}" \
    '{op:$op, env:$env, src:$src, channel:$ch, dst:$dst, mode:$mode, to_name:$name,
      move_id:($move | if . == "" then null else . end), go_msg_id:($go | if . == "" then null else . end),
      step:($step | if . == "" then null else . end), detail:$detail}')" || return 1
  out="$(bash -c "$CHANNEL_MOVE_HUB_CMD" <<<"$req")" || rc=$?
  if (( rc != 0 )) || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
    do_log "FATAL the hub refused $1${2:+ $2} for $CWM_SRC/$CWM_CH -> $CWM_DST (exit $rc): $out"
    return 1
  fi
  printf '%s\n' "$out"
}

# _spl_cwm_plan [quiet]: print the plan; 3 when it refuses (C11, Q6).
_spl_cwm_plan() {
  local p n
  p="$(_spl_cwm_hub plan)" || return 1
  if [[ -z "${1:-}" ]]; then
    jq -r '(.counts // {} | to_entries[] | "PLAN count \(.key) \(.value)"),
      (.seats // [] | .[] | "PLAN seat \(.agent) on \(.box // "-")"),
      (.mentions // [] | .[] | "PLAN mention outside the set: \(tostring)"),
      (.members_lost // [] | .[] | "PLAN member not in the target: \(tostring)"),
      (.kept // [] | .[] | "PLAN kept \(.store) until \(.gone_by // "?")")' <<<"$p"
  fi
  jq -r --arg dst "$CWM_DST" '(.missing_desks // [] | .[] | "REFUSE seat \(.agent) on \(.box // "-") has no desk in \($dst)"),
    (.shared // [] | .[] | "REFUSE shared item \(tostring)"), (.refuse // [] | .[] | "REFUSE \(.)")' <<<"$p"
  n="$(jq '[(.missing_desks // []), (.shared // []), (.refuse // [])] | map(length) | add' <<<"$p")"
  if (( n > 0 )); then
    do_log "FATAL the plan for $CWM_SRC/$CWM_CH -> $CWM_DST refuses ($n item(s) above); nothing changed"
    return 3
  fi
  [[ -n "${1:-}" ]] || do_log "OK plan of $CWM_SRC/$CWM_CH -> $CWM_DST ($CWM_MODE): nothing changed. Run it: MOVE_CMD=run"
}

# _spl_cwm_run <dry>: resume at the first step the journal has not done.
_spl_cwm_run() {
  local j steps s todo="" p4done
  j="$(_spl_cwm_hub journal)" || return 1
  CWM_MOVE="$(jq -r '.move_id // empty' <<<"$j")"
  steps="$(_spl_cwm_steps)"
  p4done="$(jq -r '.steps.P4 // ""' <<<"$j")"
  if [[ -n "$CWM_FROM" ]]; then
    if [[ "$p4done" == "done" && " P1 P2 P2b P3 P4 " == *" $CWM_FROM "* ]]; then
      do_log "FATAL MOVE_FROM=$CWM_FROM: the journal of move $CWM_MOVE says P4 committed; only P5-P7 resume"
      return 3
    fi
    todo="${steps#*"$CWM_FROM"}"; todo="$CWM_FROM$todo"
  else
    for s in $steps; do
      [[ -n "$todo" || "$(jq -r --arg s "$s" '.steps[$s] // ""' <<<"$j")" != "done" ]] && todo="${todo:+$todo }$s"
    done
  fi
  if [[ -z "$todo" ]]; then do_log "OK move $CWM_MOVE of $CWM_SRC/$CWM_CH -> $CWM_DST is done: nothing to do"; return 0; fi
  if [[ -z "$CWM_MOVE" && "$todo" == P1* ]]; then _spl_cwm_plan quiet || return $?; fi
  if (( $1 )); then
    do_log "OK DRY_RUN move ${CWM_MOVE:-<new>} of $CWM_SRC/$CWM_CH -> $CWM_DST ($CWM_MODE) would run $todo. Re-run with DRY_RUN=0 and the owner's MOVE_GO_MSG."
    return 0
  fi
  for s in $todo; do
    _spl_cwm_step "$s" || return $?
  done
  do_log "OK move $CWM_MOVE of $CWM_SRC/$CWM_CH -> $CWM_DST ($CWM_MODE) done"
}

_spl_cwm_step() {
  local out
  case "$1" in
    P2b) _spl_cwm_probe_all || return $? ;;
    P5) _spl_cwm_box_p5 || return $? ;;
    *)
      out="$(_spl_cwm_hub step "$1")" || return 1
      [[ "$1" != P1 ]] || CWM_MOVE="$(jq -r '.move_id // empty' <<<"$out")"
      [[ -n "$CWM_MOVE" ]] || { do_log "FATAL P1 returned no move id"; return 1; }
      [[ "$1" != P7 ]] || _spl_cwm_proofs "$out" || return 1 ;;
  esac
  do_log "OK $1 of move $CWM_MOVE done"
}

_spl_cwm_proofs() {
  jq -r '.proofs // [] | .[] | "proof \(.name) \(.count)"' <<<"$1"
  if jq -e '[.proofs // [] | .[] | select(.count != 0)] | length > 0' >/dev/null <<<"$1"; then
    do_log "FATAL P7: a proof of section 5 is not 0 in $CWM_SRC (lines above)"
    return 1
  fi
}

_spl_cwm_box() { bash "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/channel-workspace-move-box.sh" "$@" --move "$CWM_MOVE" --apply; }

# P2b (W2, C11): every seat's <DST> desk sends its probe DM, or the move stops
# before P3/P4 with nothing changed.
_spl_cwm_probe_all() {
  local j agent box out id probes="[]"
  j="$(_spl_cwm_hub journal)" || return 1
  while IFS=$'\x1f' read -r agent box; do
    [[ -n "$agent" ]] || continue
    out="$(_spl_cwm_box probe --env "$ENV" --tenant "$CWM_DST" --to "$MOVE_CALLER" --agent "$agent" ${box:+--box "$box"})" \
      || { do_log "FATAL P2b: the $CWM_DST desk of $agent failed its probe; stopped before P3/P4, no row of the set moved"; return 1; }
    id="${out##*$'\n'}"
    probes="$(jq -c --arg a "$agent" --arg m "$id" '. + [{agent: $a, msg_id: $m}]' <<<"$probes")"
  done < <(jq -r '.seats // [] | .[] | [.agent // "", .box // ""] | join("\u001f")' <<<"$j")
  _spl_cwm_hub mark P2b "{\"probes\":$probes}" >/dev/null
}

# P5 (W2, W4, C12): the box rule row, then one note per lane whose key changed.
_spl_cwm_box_p5() {
  local j lanes rc=0
  j="$(_spl_cwm_hub journal)" || return 1
  _spl_cwm_box rule-rows --src "$CWM_SRC" --dst "$CWM_DST" --channel "$CWM_CH" --to-name "$CWM_NAME" \
    || { do_log "FATAL P5: the box rule row of $CWM_SRC/$CWM_CH was not rewritten; a re-run resumes at P5"; return 1; }
  lanes="$(mktemp)" || return 1
  jq -c '.lanes // []' <<<"$j" >"$lanes"
  _spl_cwm_box lane-notes --from "$AGENT_ID" --lanes "$lanes" || rc=$?
  rm -f "$lanes"
  (( rc == 0 )) || { do_log "FATAL P5: a lane key note was not sent; a re-run resumes at P5 and sends only the missing ones"; return 1; }
  _spl_cwm_hub mark P5 '{"box":"rule-rows,lane-notes"}' >/dev/null
}

# MOVE_CMD=probe (P2b, one seat): the agent-to-agent probe DM through the
# seat's <TO> desk on this machine. Prints the send result JSON (msg_id).
_spl_cwm_probe_send() {
  local tenant="${TO:-}" agent="${PROBE_AGENT:-}" to="${PROBE_TO:-}" task="${PROBE_MOVE:-}" box d sent rc=0 dry=1
  local u='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' body
  local -a tobox=()
  spl_require_cloud_env || return 1
  box="${DESK_BOX:-$(spl_desk_box_default)}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  _spl_cwm_is_seat "$to" || {
    do_log "FATAL PROBE_TO must be the $tenant orchestrator seat, <agent id>[@<box>] (never a HUM-: the hub refuses a probe DM to a person), got: '$to'"
    return 1
  }
  [[ "$to" != *@* ]] || { tobox=(--to-box "${to#*@}"); to="${to%@*}"; }
  [[ "$task" =~ $u ]] || { do_log "FATAL PROBE_MOVE must be the move id (uuid), got: '$task'"; return 1; }
  body="Channel move $task: desk probe of $agent in $tenant (spec 169 P2b). No answer needed."
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would send the P2b probe $agent -> $to${tobox[1]:+@${tobox[1]}} through its $tenant desk on $box, task $task"
    return 0
  fi
  # TENANT_ID: on a box claimed by a workspace (spec 108 3.5) the desk cnf's
  # guard checks it and picks that workspace's state dir
  TENANT_ID="$tenant" do_spl_desk_cnf || return 1
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  [[ -d "$d/spool/$agent" ]] || {
    do_log "FATAL no $tenant desk for $agent on $box on this machine ($d): P2b probes only the desks of the machine that runs the move"
    return 1
  }
  spl_host_spool || return 1
  sent="$(spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- send --from "$agent" --to "$to" "${tobox[@]}" \
    --task "$task" --kind note --body "$body" 2>&1)" || rc=$?
  (( rc == 0 )) || { do_log "FATAL P2b probe $agent -> $to in $tenant: $sent"; return 1; }
  printf '%s\n' "$sent"
}
