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
# @description (a seat with no <DST> desk, a shared item, a hub refusal). It also
# @description prints the Cloud SQL backup retention and each log bucket's
# @description retention (R4, row T9b), read as the per-env service account; it
# @description refuses nothing on them, and a value it cannot read prints as
# @description "not read: <reason>". For a move it also reads the channel's row in
# @description THIS box's channel-rules.tsv (W2's F14 half, row T9c) and refuses
# @description when that desk agent has no <DST> desk on this box. A box reads
# @description only its own file: run the plan on every box that works the channel.
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
# @description The hub is the T7 endpoint, POST /v1/operator/channel-moves on
# @description the ENV hub (https://<env.dns.api_fqdn>), called as the per-env
# @description service account with a Google ID token (spl_hub_operator_call):
# @description one request JSON ({op, env, src, channel, dst, mode, to_name,
# @description move_id, go_msg_id, step, detail}; op is plan, journal, step or
# @description mark), the answer JSON back, any HTTP code but 200 = refused.
# @description It prints the plan's shared files, P4's and P7's .report and
# @description P7's .kept with each copy's date and .kept_until; none of them refuses.
# @description P7 sends the hub retention_days (row T8c): per kept copy of 5.6 that
# @description ends with a retention, its days, read from the cnf and as the
# @description per-env service account; a value it cannot read is not sent and
# @description prints as "RETENTION <copy>: not read: <reason>".
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
# @param CHANNEL_MOVE_HUB_CMD (optional, tests) - a command in place of the T7 call: the request JSON on stdin, the answer JSON on stdout, non-zero = refused
# @param CHANNEL_MOVE_STATE (optional) - the box journal dir, default $SPOOL_ROOT/channel-move
# @param PROBE_AGENT, PROBE_TO, PROBE_MOVE (MOVE_CMD=probe only) - the seat, the recipient <agent id>[@<box>], the move id
# @param DESK_BOX (optional, MOVE_CMD=probe or plan) - the seat's box id, default this box's desk id
# @param CWM_GCLOUD_TIMEOUT (optional, MOVE_CMD=plan and P7) - seconds per retention read, default 60
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
  _spl_cwm_hub_wire || return 1
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

# _spl_cwm_hub_wire: the T7 endpoint's URL and the per-env service account,
# once per run; never the owner account. CHANNEL_MOVE_HUB_CMD (tests) needs none.
_spl_cwm_hub_wire() {
  [[ -z "${CHANNEL_MOVE_HUB_CMD:-}" ]] || return 0
  do_require_bin yq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
}

# _spl_cwm_hub_post: the default seam, POST /v1/operator/channel-moves with the
# request on stdin. The answer on stdout; any code but 200 is a refusal. It
# waits as long as Cloud Run lets the hub run (SPL-5067): a client that leaves
# cancels the request, so a P4 longer than the cap rolls back on every re-run.
_spl_cwm_hub_post() {
  local max
  max="$(yq -r '.env.hub.cloud_run.timeout_seconds // ""' "$SPL_CNF")"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL env.hub.cloud_run.timeout_seconds is not whole seconds in $SPL_CNF: '$max'" >&2; return 1; }
  SPL_HUB_OP_MAX_TIME="$max" spl_hub_operator_call POST /v1/operator/channel-moves "$(cat)" || return 1
  printf '%s\n' "$SPL_HUB_OP_BODY"
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] || { do_log "FATAL POST /v1/operator/channel-moves answered HTTP $SPL_HUB_OP_STATUS" >&2; return 1; }
}

# _spl_cwm_hub <op> [step] [detail json]: one call through the seam; the
# answer JSON on stdout. A refusal: FATAL with the hub's answer on stderr (every
# caller captures stdout), 1.
_spl_cwm_hub() {
  local req out rc=0
  req="$(jq -cn --arg op "$1" --arg env "$ENV" --arg src "$CWM_SRC" --arg ch "$CWM_CH" --arg dst "$CWM_DST" \
    --arg mode "$CWM_MODE" --arg name "$CWM_NAME" --arg move "${CWM_MOVE:-}" --arg go "${MOVE_GO_MSG:-}" \
    --arg step "${2:-}" --argjson detail "${3:-null}" \
    '{op:$op, env:$env, src:$src, channel:$ch, dst:$dst, mode:$mode, to_name:$name,
      move_id:($move | if . == "" then null else . end), go_msg_id:($go | if . == "" then null else . end),
      step:($step | if . == "" then null else . end), detail:$detail}')" || return 1
  if [[ -n "${CHANNEL_MOVE_HUB_CMD:-}" ]]; then out="$(bash -c "$CHANNEL_MOVE_HUB_CMD" <<<"$req")" || rc=$?
  else out="$(_spl_cwm_hub_post <<<"$req")" || rc=$?; fi
  if (( rc != 0 )) || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
    do_log "FATAL the hub refused $1${2:+ $2} for $CWM_SRC/$CWM_CH -> $CWM_DST (exit $rc): $out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# _spl_cwm_plan [quiet]: print the plan; 3 when it refuses (C11, Q6).
_spl_cwm_plan() {
  local p n rule=0
  p="$(_spl_cwm_hub plan)" || return 1
  if [[ -z "${1:-}" ]]; then
    jq -r '(.counts // {} | to_entries[] | "PLAN count \(.key) \(.value)"),
      (.seats // [] | .[] | "PLAN seat \(.agent) on \(.box // "-")"),
      (.mentions // [] | .[] | "PLAN mention outside the set: \(tostring)"),
      (.members_lost // [] | .[] | "PLAN member not in the target: \(tostring)"),
      (.shared_files // [] | .[] | "PLAN shared file \(.): a staying post lists it too, copied, not deleted in <SRC>"),
      (.kept // [] | .[] | "PLAN kept \(.store) until \(.gone_by // "?")")' <<<"$p"
    _spl_cwm_plan_retention
  fi
  _spl_cwm_plan_box_rule "${1:-}" "$p" || rule=1
  jq -r --arg dst "$CWM_DST" '(.missing_desks // [] | .[] | "REFUSE seat \(.agent) on \(.box // "-") has no desk in \($dst)"),
    (.shared // [] | .[] | "REFUSE shared item \(tostring)"), (.refuse // [] | .[] | "REFUSE \(.)")' <<<"$p"
  n="$(jq '[(.missing_desks // []), (.shared // []), (.refuse // [])] | map(length) | add' <<<"$p")"
  n=$((n + rule))
  if (( n > 0 )); then
    do_log "FATAL the plan for $CWM_SRC/$CWM_CH -> $CWM_DST refuses ($n item(s) above); nothing changed"
    return 3
  fi
  [[ -n "${1:-}" ]] || do_log "OK plan of $CWM_SRC/$CWM_CH -> $CWM_DST ($CWM_MODE): nothing changed. Run it: MOVE_CMD=run"
}

# _spl_cwm_plan_box_rule <quiet> <plan json> (T9c, W2, F14, C25, C26): the desk
# agent of this box's rule row needs a <DST> desk on this box; the hub cannot
# read that file. 1 and a REFUSE line when it has none or this cannot tell; an
# absent row is no refusal. Read-only, P5 rewrites the file. A subshell: the
# desk cnf's globals end here. A copy moves no seat (section 7), and a row of
# another env is not this move's seat. Other boxes are the operator's: the
# lines say so and name the boxes of the hub's seats.
_spl_cwm_plan_box_rule() (
  local say=echo map box desk row rc=0 env agent d log why id="$CWM_SRC/$CWM_CH"
  [[ -z "$1" ]] || say=:
  if [[ "$CWM_MODE" == copy ]]; then $say "PLAN box rule: not checked, a copy moves no seat"; return 0; fi
  declare -F cr_row >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/channel-rules.inc.sh"
  map="$(cr_map)"; box="$(spl_box_name)"; desk="${DESK_BOX:-$(spl_desk_box_default)}"
  $say "PLAN box rule: read $map on box $box; other boxes are not read: run this plan on each box that works $id"
  while read -r d; do
    [[ -z "$d" || "$d" == "$box" || "$d" == "$desk" ]] || $say "PLAN box rule: run this plan on box $d too (a seat of $id is there)"
  done < <(jq -r '.seats // [] | map(.box // empty) | unique | .[]' <<<"$2")
  [[ ! -e "$map" || -r "$map" ]] || { echo "REFUSE box rule: $id cannot tell: $map exists but cannot be read"; return 1; }
  row="$(cr_row "$CWM_SRC" "$CWM_CH" 2>&1)" || rc=$?
  if (( rc == 1 )); then $say "PLAN box rule: no row for $id on box $box"; return 0; fi
  (( rc == 0 )) || { echo "REFUSE box rule: $id cannot tell: $row"; return 1; }
  read -r _ env agent <<<"$row"
  if [[ "$env" != "$ENV" ]]; then $say "PLAN box rule: $id row is for env $env, not $ENV: not checked"; return 0; fi
  why="$(spl_desk_validate "$CWM_DST" "$desk" none 2>&1)" || { echo "REFUSE box rule: $id cannot tell: $(_spl_cwm_last_line <<<"$why")"; return 1; }
  log="$(mktemp)" || { echo "REFUSE box rule: $id cannot tell: cannot make a temp file"; return 1; }
  rc=0
  { do_require_bin yq && TENANT_ID="$CWM_DST" do_spl_desk_cnf; } >"$log" 2>&1 || rc=$?
  (( rc != 0 )) || { d="$(spl_desk_dir "$CWM_DST" "$desk" 2>"$log")" || [[ $? -eq 1 ]] || rc=3; }
  why="$(_spl_cwm_last_line <"$log")"; rm -f "$log"
  (( rc == 0 )) || { echo "REFUSE box rule: $id cannot tell if desk agent $agent has a $CWM_DST desk on box $box: ${why:-the desk cnf did not resolve}"; return 1; }
  if [[ ! -d "$d/spool/$agent" ]]; then
    echo "REFUSE box rule: $id desk agent $agent has no $CWM_DST desk on box $box (desk id $desk, looked in $d as $(id -un))"
    return 1
  fi
  $say "PLAN box rule: $id desk agent $agent has its $CWM_DST desk on box $box"
)

# _spl_cwm_plan_retention (T9b, R4, C24): how long the copies of 5.6 live. It
# only prints: this is the operator's reading, never a refusal, and a value it
# cannot read says so and why. A subshell: the cnf's globals and the pin's
# private CLOUDSDK_CONFIG (with its EXIT cleanup) end here. The log buckets come
# from the project, all of them: the cnf names none (no terraform step manages
# them), and a guessed name would hide the one that holds the lines.
_spl_cwm_plan_retention() (
  local log why
  log="$(mktemp)" || log=/dev/null
  if ! { do_require_bin gcloud yq && do_spl_cloud_cnf && do_gcp_pin_account "$SPL_CNF"; } >"$log" 2>&1; then
    why="$(_spl_cwm_last_line <"$log")"
    echo "PLAN retention Cloud SQL backups: not read: ${why:-the cnf or the account did not resolve}"
    echo "PLAN retention log buckets: not read: ${why:-the cnf or the account did not resolve}"
    [[ "$log" == /dev/null ]] || rm -f "$log"
    return 0
  fi
  [[ "$log" == /dev/null ]] || rm -f "$log"
  _spl_cwm_retention_sql
  _spl_cwm_retention_logs
)

# _spl_cwm_last_line: stdin's last non-blank line, at most 200 characters.
_spl_cwm_last_line() { awk 'NF { l = $0 } END { print substr(l, 1, 200) }'; }

# _spl_cwm_read <cmd...>: runs a read under a timeout, so a hung gcloud cannot
# hold the plan. Sets CWM_READ to its stdout, or returns 1 with CWM_WHY set.
_spl_cwm_read() {
  local e rc=0 t="${CWM_GCLOUD_TIMEOUT:-60}"
  e="$(mktemp)" || { CWM_WHY="cannot make a temp file"; return 1; }
  CWM_READ="$(timeout "$t" "$@" 2>"$e")" || rc=$?
  CWM_WHY="$(_spl_cwm_last_line <"$e")"
  rm -f "$e"
  (( rc != 124 )) || CWM_WHY="gcloud gave no answer in $t s"
  (( rc == 0 ))
}

_spl_cwm_retention_sql() {
  local line
  if ! _spl_cwm_read gcloud sql instances describe "$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --format='json(settings.backupConfiguration)'; then
    echo "PLAN retention Cloud SQL backups: not read: ${CWM_WHY:-gcloud failed}"
    return 0
  fi
  line="$(jq -r '.settings.backupConfiguration // {} | . as $b | .backupRetentionSettings as $r
    | if $b.enabled == false then "automated backups off"
      elif ($r.retainedBackups // null) == null then empty
      else "\($r.retainedBackups) \($r.retentionUnit // "?") kept, point-in-time logs \($b.transactionLogRetentionDays // "?") days" end' <<<"$CWM_READ" 2>/dev/null)"
  echo "PLAN retention Cloud SQL backups: ${line:-not read: no backup retention in the answer}"
}

_spl_cwm_retention_logs() {
  local lines
  if ! _spl_cwm_read gcloud logging buckets list --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --format=json; then
    echo "PLAN retention log buckets: not read: ${CWM_WHY:-gcloud failed}"
    return 0
  fi
  lines="$(jq -r '.[] | "PLAN retention log bucket \(.name | split("/") | last): " +
    (if .retentionDays then "\(.retentionDays) days" else "not read: no retention in the answer" end)' <<<"$CWM_READ" 2>/dev/null)"
  echo "${lines:-PLAN retention log buckets: not read: no bucket in the answer}"
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
  local out detail=null
  case "$1" in
    P2b) _spl_cwm_probe_all || return $? ;;
    P5) _spl_cwm_box_p5 || return $? ;;
    *)
      [[ "$1" != P7 ]] || detail="$(_spl_cwm_p7_detail)" || return 1
      out="$(_spl_cwm_hub step "$1" "$detail")" || return 1
      [[ "$1" != P1 ]] || CWM_MOVE="$(jq -r '.move_id // empty' <<<"$out")"
      [[ -n "$CWM_MOVE" ]] || { do_log "FATAL P1 returned no move id"; return 1; }
      _spl_cwm_report "$1" "$out"
      [[ "$1" != P7 ]] || _spl_cwm_proofs "$out" || return 1 ;;
  esac
  do_log "OK $1 of move $CWM_MOVE done"
}

# _spl_cwm_report <step> <answer>: P4's and P7's .report lines, P7's mentions
# left in place (5.4, by class and by id, never their text), P7's .kept
# list with each copy's date (.expires, T8b: a date or "not read: <why>") and
# .kept_until, the last of them (section 8.4, T8c); they only print, a proof is
# what fails P7.
_spl_cwm_report() {
  jq -r --arg s "$1" '(.report // [] | .[] | "REPORT \($s) \(.)"),
    (.mentions // empty | "MENTIONS uuid with redirect \(.uuid_with_redirect), name or channel id \(.name_or_channel_id)"),
    (.mentions.rows // [] | .[] | "MENTION \(.kind) \(.msg_id // "\(.doc_id) \(.item_id)"): \(.class)"),
    (.kept // [] | .[] | "KEPT \(.store) until \(.expires // .gone_by // "?")"),
    (.kept_until // empty | "KEPT_UNTIL \(.)")' <<<"$2"
}

# _spl_cwm_p7_detail (T8c, N5): P7's detail, {"retention_days": {<copy>: <days>}},
# on stdout. One RETENTION line per kept copy of 5.6 that ends with a retention
# goes to stderr (stdout is the detail): its days and how they were counted, or
# "not read: <why>", and that copy is then not sent: the hub dates no copy from
# a guess. Days count from P4's done_at to the day the last copy made before P4
# is gone for good, so a bucket's soft delete and a versioned bucket's
# noncurrent generation count too: a date too late is safe, one too early is a
# false "gone".
_spl_cwm_p7_detail() {
  local rows
  rows="$(_spl_cwm_retention_days)"
  awk -F'\t' 'NF { print "RETENTION " $1 ": " ($2 != "" ? $2 " days (" $3 ")" : "not read: " $3) }' <<<"$rows" >&2
  jq -cRn '[inputs | split("\t") | select(length > 1 and .[1] != "") | {(.[0]): (.[1] | tonumber)}] | add // {}
    | {retention_days: .}' <<<"$rows"
}

# _spl_cwm_retention_days: one line per dated copy, <copy> TAB <days> TAB <how>,
# or <copy> TAB TAB <why not read>. A subshell, as the plan's reads: the cnf's
# globals and the pin's private CLOUDSDK_CONFIG end here.
_spl_cwm_retention_days() (
  local log why c
  log="$(mktemp)" || log=/dev/null
  if ! { do_require_bin gcloud yq && do_spl_cloud_cnf && do_gcp_pin_account "$SPL_CNF"; } >"$log" 2>&1; then
    why="$(_spl_cwm_last_line <"$log")"
    [[ "$log" == /dev/null ]] || rm -f "$log"
    for c in "daily DB dumps" "off-project copy of the dumps" "Cloud SQL automated backups" "Qto daily export" "box-state copy" "hub logs"; do
      printf '%s\t\t%s\n' "$c" "${why:-the cnf or the account did not resolve}"
    done
    return 0
  fi
  [[ "$log" == /dev/null ]] || rm -f "$log"
  _spl_cwm_retention_cnf_days
  _spl_cwm_retention_sql_days
  _spl_cwm_retention_log_days
)

# _spl_cwm_retention_log_days: the hub logs' days, from the bucket the cnf names
# (hub.log_bucket). A guessed bucket is not a date, so every run also reads one
# line of the hub's service back from that bucket; none, and the copy is not read.
_spl_cwm_retention_log_days() {
  local c="hub logs" bucket svc row location days
  bucket="$(yq -r '.env.hub.log_bucket // ""' "$SPL_CNF" 2>/dev/null)"
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF" 2>/dev/null)"
  if [[ -z "$bucket" || -z "$svc" ]]; then
    printf '%s\t\t%s\n' "$c" "the cnf has no hub.log_bucket or hub.service_name"
    return 0
  fi
  if ! _spl_cwm_read gcloud logging buckets list --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --format=json; then
    printf '%s\t\t%s\n' "$c" "${CWM_WHY:-gcloud failed}"
    return 0
  fi
  row="$(jq -r --arg b "$bucket" '.[] | (.name | split("/")) as $n | select($n[-1] == $b) | "\($n[3]) \(.retentionDays // "")"' <<<"$CWM_READ" 2>/dev/null)"
  read -r location days <<<"$row"
  if [[ -z "${days:-}" ]]; then
    printf '%s\t\t%s\n' "$c" "no retention for log bucket $bucket in the answer"
    return 0
  fi
  if ! _spl_cwm_read gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$svc\"" \
    --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --bucket="$bucket" --location="$location" --view=_AllLogs \
    --limit=1 --freshness=1d --format=json; then
    printf '%s\t\t%s\n' "$c" "${CWM_WHY:-gcloud failed}"
    return 0
  fi
  if [[ "$(jq -r 'length' <<<"$CWM_READ" 2>/dev/null)" == 0 || -z "$CWM_READ" ]]; then
    printf '%s\t\t%s\n' "$c" "no line of $svc in log bucket $bucket in the last day"
    return 0
  fi
  _spl_cwm_days_capped <<<"$c"$'\t'"$days"$'\t'"log bucket $bucket, read back a line of $svc"
}

# _spl_cwm_retention_cnf_days: the four bucket copies, from the cnf the
# terraform steps are rendered from. Per step: its lifecycle Delete age; plus
# the noncurrent rule's days where the bucket is versioned (the age rule only
# makes the object noncurrent: 046 noncurrent_max_age_days, 052 the literal 7
# days of 052-gcs-workspace-docs/03-workspace-docs-buckets.tf, no cnf key);
# plus the soft delete, rounded up to whole days.
_spl_cwm_retention_cnf_days() {
  local q cnf rows
  q='def n(v): v | if type == "number" and . >= 0 and . == floor then . else null end;
    def sd(v): n(v) | if . == null then null else ((. + 86399) / 86400 | floor) end;
    def row(c; parts; how): if (parts | all(. != null)) then [c, (parts | add | tostring), how]
      else [c, "", "the cnf has no whole number for " + how] end;
    .env.steps as $s
    | row("daily DB dumps"; [n($s."045-gcs-db-backups".backup_max_age_days), sd($s."045-gcs-db-backups".soft_delete_retention_seconds)];
        "045 backup_max_age_days + soft delete"),
      row("off-project copy of the dumps"; [n($s."046-gcs-offsite-backups".max_age_days), n($s."046-gcs-offsite-backups".noncurrent_max_age_days),
        sd($s."046-gcs-offsite-backups".soft_delete_retention_seconds)]; "046 max_age_days + noncurrent_max_age_days + soft delete"),
      row("Qto daily export"; [n($s."052-gcs-workspace-docs".backup_retention_days), 7, sd($s."052-gcs-workspace-docs".soft_delete_retention_seconds)];
        "052 backup_retention_days + 7 noncurrent + soft delete"),
      row("box-state copy"; [n($s."056-gcs-box-state".retention_days), sd($s."056-gcs-box-state".soft_delete_retention_seconds)];
        "056 retention_days + soft delete")
    | @tsv'
  if cnf="$(yq -o=json '.' "$SPL_CNF" 2>/dev/null)" && rows="$(jq -r "$q" <<<"$cnf" 2>/dev/null)" && [[ -n "$rows" ]]; then
    _spl_cwm_days_capped <<<"$rows"
    return 0
  fi
  printf '%s\t\t%s\n' "daily DB dumps" "cannot read $SPL_CNF" "off-project copy of the dumps" "cannot read $SPL_CNF" \
    "Qto daily export" "cannot read $SPL_CNF" "box-state copy" "cannot read $SPL_CNF"
}

# _spl_cwm_retention_sql_days: Cloud SQL keeps a COUNT of automated backups
# (backupRetentionSettings), not days. The schedule is one backup a day, in
# the window at backupConfiguration.startTime (040's start_time "01:00"), so
# the last backup made before P4 is the oldest of the count after <count> more
# days and is gone then: days = the count. The point-in-time logs before P4
# live transactionLogRetentionDays: the later of the two. Any other unit, no
# daily window, or backups off: not read.
_spl_cwm_retention_sql_days() {
  local line c="Cloud SQL automated backups"
  if ! _spl_cwm_read gcloud sql instances describe "$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --format='json(settings.backupConfiguration)'; then
    printf '%s\t\t%s\n' "$c" "${CWM_WHY:-gcloud failed}"
    return 0
  fi
  line="$(jq -r --arg c "$c" '.settings.backupConfiguration // {} | . as $b | (.backupRetentionSettings // {}) as $r
    | ($r.retainedBackups // null) as $n | ($b.transactionLogRetentionDays // 0) as $l
    | if $b.enabled != true then [$c, "", "automated backups are not on"]
      elif $r.retentionUnit != "COUNT" or ($n | type) != "number" or $n < 1 or $n != ($n | floor) then
        [$c, "", "no backup count in the answer (unit \($r.retentionUnit // "none"))"]
      elif ($b.startTime // "") == "" then [$c, "", "no daily backup window (startTime) in the answer"]
      else [$c, ([$n, $l] | max | tostring), "\($n) backups kept, one a day at \($b.startTime); point-in-time logs \($l) days"] end
    | @tsv' <<<"$CWM_READ" 2>/dev/null)"
  _spl_cwm_days_capped <<<"${line:-$c$'\t\t'no backup retention in the answer}"
}

# _spl_cwm_days_capped: the hub refuses days outside 1..36500 (bad_detail),
# so such a value is not read, never clipped.
_spl_cwm_days_capped() {
  awk -F'\t' -v OFS='\t' '$2 != "" && ($2 !~ /^[0-9]+$/ || $2 < 1 || $2 > 36500) { $3 = $2 " days is outside 1..36500"; $2 = "" } { print }'
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
  d="$(spl_desk_dir "$tenant" "$box")" || [[ $? -eq 1 ]] || return 1
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
