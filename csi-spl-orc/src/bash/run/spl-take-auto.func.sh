#!/bin/bash
#------------------------------------------------------------------------------
# @description The take line posted by code, not by the holder's model
# @description (grade fix A, SPL-3517; SPEC-spool-fleet-roles.md 3). The desk
# @description notifier (spool-notify.sh, lib spool-notify-take.inc.sh) starts
# @description it in the background for a human post delivered to the seat
# @description that holds the dispatch lease on this box. When the topic has
# @description no agent reply yet (no OD owns it), it runs do_spl_take at once:
# @description "Taken by <id>@<box>: I read your post now. I post the result
# @description here." The holder's model still answers; its own do_spl_take
# @description then prints TAKEN-ALREADY. Measured before (grok dispatch grade
# @description 2026-10-25, section 5): first reply median 481 s under grok,
# @description 40 s under claude; the take line no longer waits on either.
# @description It takes nothing (one line per decision in
# @description <spool root>/dispatch/take-auto.log) when:
# @description   - the file <spool root>/dispatch/take-auto.off exists (off switch)
# @description   - the dispatch lease is not <TAKE_AUTO_TO>@<SPOOL_BOX_ID>, or is stale
# @description   - the workspace is a test one (spl_test_workspace)
# @description   - the post names another agent (@<id>): that one takes it
# @description   - the hub tail cannot be read: fail closed, the model takes it
# @description   - the topic holds an agent reply to a human or the channel: owned
# @description Dry run unless DRY_RUN=0 (the notifier passes DRY_RUN=0).
# @param TAKE_AUTO_TO - required: the seat the post was delivered to
# @param TAKE_AUTO_FROM - required: the human who posted (HUM-n)
# @param TAKE_AUTO_TASK - required: the full topic uuid
# @param TAKE_AUTO_DESK_ROOT - required: the desk sidecar's SPOOL_ROOT (<state>/<env>/desk/<tenant>/<box>/spool)
# @param SPOOL_BOX_ID - required: the desk box (the sidecar's)
# @param SPOOL_TENANT - required: the workspace (the sidecar's)
# @param SPOOL_ROOT (optional) - the box spool root that holds dispatch/, default /var/spool-hub
# @param TAKE_AUTO_BODY (optional) - the post's text, for the @mention check
# @param TAKE_AUTO_PLAN (optional) - default "I read your post now"
# @param TAKE_AUTO_ENV (optional) - default the env in TAKE_AUTO_DESK_ROOT's path
# @param TAKE_AUTO_TAIL_CMD (optional) - replaces "<state>/<env>/bin/spool hub-tail --task <uuid> --json" (tests)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example TAKE_AUTO_TO=c-002 TAKE_AUTO_FROM=HUM-10 TAKE_AUTO_TASK=<topic uuid> TAKE_AUTO_DESK_ROOT=<desk spool> SPOOL_BOX_ID=box-desk SPOOL_TENANT=t1 ./run -a do_spl_take_auto
#------------------------------------------------------------------------------
do_spl_take_auto() {
  spl_lease_init ro || return 1
  local to="${TAKE_AUTO_TO:-}" from="${TAKE_AUTO_FROM:-}" task="${TAKE_AUTO_TASK:-}" desk="${TAKE_AUTO_DESK_ROOT:-}"
  local box="${SPOOL_BOX_ID:-}" tenant="${SPOOL_TENANT:-}" env why
  task="${task,,}"
  [[ "$to" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL TAKE_AUTO_TO is not an id: '$to'"; return 1; }
  [[ "$from" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL TAKE_AUTO_FROM must be a human (HUM-n), got: '$from'"; return 1; }
  [[ "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL TAKE_AUTO_TASK must be the full topic uuid, got: '${TAKE_AUTO_TASK:-}'"; return 1; }
  [[ "$box" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL SPOOL_BOX_ID is not a box id: '$box'"; return 1; }
  [[ "$tenant" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL SPOOL_TENANT is required"; return 1; }
  env="${TAKE_AUTO_ENV:-$(spl_take_auto_env "$desk")}"
  [[ "$env" =~ ^(dev|prd|self)$ ]] || { do_log "FATAL no env in TAKE_AUTO_DESK_ROOT '$desk'; set TAKE_AUTO_ENV"; return 1; }
  if why="$(spl_take_auto_skip "$to@$box" "$tenant" "$task" "$desk" "$env")"; then
    spl_take_auto_log "$task" "$to@$box" "skip $why"
    echo "TAKE-AUTO skip $task: $why"; return 0
  fi
  spl_take_auto_log "$task" "$to@$box" "take"
  ENV="$env" TENANT_ID="$tenant" DESK_AGENT="$to" DESK_BOX="$box" TAKE_BOX="$box" DESK_TO="$from" \
    DESK_TASK="$task" TAKE_PLAN="${TAKE_AUTO_PLAN:-I read your post now}" TAKE_NOTIFY="" do_spl_take
}

# The env of a desk spool root: <state>/<env>/desk/<tenant>/<box>/spool.
spl_take_auto_env() {
  local p="${1%/}"
  [[ "$p" == */desk/*/*/spool ]] || return 0
  p="${p%/desk/*}"
  echo "${p##*/}"
}

# Print why <id>@<box> takes nothing in <topic> and exit 0; exit 1 = take it.
spl_take_auto_skip() {
  local by="$1" tenant="$2" task="$3" desk="$4" env="$5" held="" at="" owner
  [[ -e "$LEASE_DIR/take-auto.off" ]] && { echo "off ($LEASE_DIR/take-auto.off)"; return 0; }
  [[ -r "$LEASE_FILE" ]] && read -r held at _ <"$LEASE_FILE"
  [[ "$held" == "$by" ]] || { echo "not the dispatch lease holder (${held:-none})"; return 0; }
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at <= LEASE_STALE )) ||
    { echo "the dispatch lease is stale (${at:-no time})"; return 0; }
  spl_test_workspace "$tenant" && { echo "test workspace $tenant"; return 0; }
  owner="$(spl_take_auto_named "${by%@*}" "${TAKE_AUTO_BODY:-}")" && { echo "the post names $owner"; return 0; }
  owner="$(spl_take_auto_owner "$task" "$desk" "$env")" || { echo "the hub tail could not be read: the seat takes it"; return 0; }
  [[ -n "$owner" ]] && { echo "owned: $owner replied in the topic"; return 0; }
  return 1
}

# Print the first @<agent id> the body names that is not <to>; exit 1 = none.
spl_take_auto_named() {
  local to="${1,,}" b=" ${2:0:2000}" id re='[^A-Za-z0-9_-]@([acgmq]-[0-9]{3})([^A-Za-z0-9_-]|$)'
  b="${b,,}"
  while [[ "$b" =~ $re ]]; do
    id="${BASH_REMATCH[1]}"
    [[ "$id" != "$to" ]] && { echo "$id"; return 0; }
    b="${b#*@"$id"}"
  done
  return 1
}

# Print the first agent that replied in <topic> (to a human or the channel),
# or nothing. Agent-to-agent relays on the topic do not own it; neither does
# the non-AI responder (RSP-*). Exit 1 when the hub tail fails.
spl_take_auto_owner() {
  local task="$1" desk="$2" out bin
  if [[ -n "${TAKE_AUTO_TAIL_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(timeout "${TAKE_AUTO_TAIL_TIMEOUT:-15}" ${TAKE_AUTO_TAIL_CMD} "$task")" || return 1
  else
    bin="${desk%/desk/*}/bin/spool"
    [[ -x "$bin" ]] || return 1
    out="$(SPOOL_ROOT="$desk" SPOOL_LOG_LEVEL=error timeout "${TAKE_AUTO_TAIL_TIMEOUT:-15}" "$bin" hub-tail --task "$task" --json 2>/dev/null)" || return 1
  fi
  { grep '^{' <<<"$out" || true; } | jq -r -s '[.[] | select(((.from // "") | tostring | test("^(HUM|GST|RSP)-")) | not)
    | select(.to == "ALL-0" or ((.to // "") | tostring | startswith("HUM-")))] | (.[0].from // "")'
}

# One line per decision: "<epoch>\t<topic>\t<id>@<box>\t<decision>".
spl_take_auto_log() {
  { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >>"$LEASE_DIR/take-auto.log"; } 2>/dev/null || true
}
