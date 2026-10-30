#!/usr/bin/env bash
# channel-workspace-move-box.sh — the box steps of moving a channel into
# another workspace (spec 169 T10; csi-spl-doc/specs/169-channel-workspace-move
# sections 6 W2/W4 and 8.2 P2b/P5). do_spl_channel_workspace_move runs it; the
# hub's part (the rows, the blobs, the journal) is the T7 endpoint's.
#
# Usage:
#   channel-workspace-move-box.sh probe --move ID --env ENV --tenant DST
#       --to CALLER --agent ID [--box BOX] [--apply]
#     P2b: one probe DM from the agent, through its <DST> desk, to the caller,
#     on the probe topic (task id = the move id). Prints its msg id last.
#   channel-workspace-move-box.sh rule-rows --move ID --src SRC --dst DST
#       --channel CH [--to-name CH2] [--apply]
#     P5: the channel's row of the box map ($SPOOL_CHANNEL_RULES_MAP, default
#     $SPOOL_ROOT/channel-rules.tsv, channel-rules.inc.sh) gets <DST> (and
#     CH2) in columns 1-2; every other column, row and comment is kept.
#   channel-workspace-move-box.sh lane-notes --move ID --from ID --lanes FILE
#       [--apply]
#     P5 (W4): one spool note per lane whose issue key changed, old -> new.
#     FILE is a JSON array of {agent, topic, old_key, new_key}.
#
# Without --apply each verb prints PLAN lines and changes nothing. Every step
# done is a row of the box journal $CHANNEL_MOVE_STATE/<move id>/box.tsv
# (default state dir $SPOOL_ROOT/channel-move), so a re-run after a crash
# skips what is done: no second probe DM, no second note, no second rewrite.
#
# Seams (tests): CMB_PROBE_CMD, run with CMB_ENV, CMB_TENANT, CMB_AGENT,
# CMB_BOX, CMB_TO, CMB_TASK, CMB_BODY set, prints the sent message's JSON
# (default: ./run -a do_spl_desk_reply with DESK_TO / DESK_TASK, DRY_RUN=0);
# CMB_SEND_CMD (default: spool-send.sh next to this file).
# Guard: tests/test-channel-workspace-move-box.sh.
# Exit 0 done (or planned), 1 a step failed, 2 usage, 3 refused (the map
# already holds a <DST> row for the channel beside the <SRC> one).
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/channel-rules.inc.sh
. "$_here/../lib/channel-rules.inc.sh"

UUID_RX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
KEY_RX='^[A-Z][A-Z0-9]{0,15}-[0-9]{1,9}$'

die() { echo "channel-workspace-move-box: $1" >&2; exit "${2:-2}"; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The box journal: <kind> TAB <key> TAB <value> TAB <utc>, one row per step.
jfile() { printf '%s/%s/box.tsv' "${CHANNEL_MOVE_STATE:-${SPOOL_ROOT:-/var/spool-hub}/channel-move}" "$MOVE"; }
jget() { [ -r "$(jfile)" ] && awk -F'\t' -v k="$1" -v n="$2" '$1 == k && $2 == n { print $3; exit }' "$(jfile)"; }
jput() {
  local f; f="$(jfile)"
  mkdir -p "${f%/*}" || die "cannot make ${f%/*}" 1
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(utc)" >>"$f" || die "cannot write $f" 1
}

need() { [ -n "${2:-}" ] || die "$1 is required"; }
check_tenant() { [[ "$2" =~ ^${CR_TENANT_RX}$ ]] || die "$1 '$2' is not a tenant slug"; }
check_channel() { [[ "$2" =~ ^${CR_CHANNEL_RX}$ ]] || die "$1 '$2' is not a channel id"; }
check_agent() { [[ "$2" =~ ^${SPOOL_AGENT_ID_RX}(@[A-Za-z0-9._-]+)?$ ]] || die "$1 '$2' is not an agent id"; }

# --- probe (P2b) ------------------------------------------------------------------------
_probe_default() {
  ( cd "$_here/../../../../.." && ENV="$CMB_ENV" TENANT_ID="$CMB_TENANT" DESK_AGENT="$CMB_AGENT" \
      DESK_BOX="${CMB_BOX:-}" DESK_TO="$CMB_TO" DESK_TASK="$CMB_TASK" DESK_KIND=note \
      DESK_BODY="$CMB_BODY" DRY_RUN=0 ./run -a do_spl_desk_reply ) </dev/null
}

verb_probe() {
  need --env "$ENVN"; need --tenant "$DST"; need --to "$TO"; need --agent "$AGENT"
  [[ "$ENVN" =~ ^(dev|prd)$ ]] || die "--env takes dev or prd, got: $ENVN"
  check_tenant --tenant "$DST"; check_agent --agent "$AGENT"
  [[ "$TO" =~ ^HUM-[0-9]+$ ]] || check_agent --to "$TO"
  [ -z "$BOX" ] || [[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "--box '$BOX' is not a box id"
  local done_id out rc=0 id
  done_id="$(jget probe "$AGENT")"
  if [ -n "$done_id" ]; then echo "OK probe $AGENT already sent"; echo "$done_id"; return 0; fi
  if [ "$APPLY" != 1 ]; then echo "PLAN probe $AGENT -> $TO via its $DST desk ($ENVN), task $MOVE"; return 0; fi
  export CMB_ENV="$ENVN" CMB_TENANT="$DST" CMB_AGENT="$AGENT" CMB_BOX="$BOX" CMB_TO="$TO" CMB_TASK="$MOVE"
  export CMB_BODY="Channel move $MOVE: desk probe of $AGENT in $DST (spec 169 P2b). No answer needed."
  if [ -n "${CMB_PROBE_CMD:-}" ]; then out="$(bash -c "$CMB_PROBE_CMD" </dev/null)" || rc=$?
  else out="$(_probe_default)" || rc=$?; fi
  id="$(grep -m1 '^{' <<<"$out" | jq -r '.msg_id // empty' 2>/dev/null)"
  if [ "$rc" -ne 0 ] || ! [[ "$id" =~ $UUID_RX ]]; then
    die "FATAL probe of $AGENT through its $DST desk failed (exit $rc, msg id '${id}'): its desk cannot post in $DST; stop before P4" 1
  fi
  jput probe "$AGENT" "$id"
  echo "OK probe $AGENT -> $TO sent"
  echo "$id"
}

# --- rule-rows (P5) ---------------------------------------------------------------------
# Prints the map with the channel's <SRC> row moved; exit 3 when a <DST> row
# for the new name is there too, 4 when there is no <SRC> row.
_rule_rows_rewrite() {
  awk -F'\t' -v OFS='\t' -v s="$SRC" -v d="$DST" -v c="$CHANNEL" -v n="$NAME" '
    $1 !~ /^#/ && $1 == d && $2 == n { dst = 1 }
    $1 !~ /^#/ && $1 == s && $2 == c { $1 = d; $2 = n; hit++ }
    { print }
    END { if (hit && dst) exit 3; if (!hit) exit 4 }' "$1"
}

verb_rule_rows() {
  need --src "$SRC"; need --dst "$DST"; need --channel "$CHANNEL"
  check_tenant --src "$SRC"; check_tenant --dst "$DST"; check_channel --channel "$CHANNEL"
  [ "$SRC" != "$DST" ] || die "--src and --dst are the same workspace"
  NAME="${NAME:-$CHANNEL}"; check_channel --to-name "$NAME"
  local m tmp rc=0
  m="$(cr_map)"
  if [ -n "$(jget rule-row "$SRC/$CHANNEL")" ]; then echo "OK rule-row $SRC #$CHANNEL already -> $DST #$NAME"; return 0; fi
  [ -e "$m" ] || { echo "OK no rule row for $SRC #$CHANNEL on this box (no $m)"; return 0; }
  [ -r "$m" ] && [ -w "$m" ] || die "FATAL $m is not readable and writable by $(id -un)" 1
  exec 9>>"$m.lock" || die "cannot open $m.lock" 1
  flock -w 30 9 || die "FATAL $m.lock is held by another writer" 1
  tmp="$(mktemp "$m.cwm.XXXXXX")" || die "cannot write next to $m" 1
  _rule_rows_rewrite "$m" >"$tmp" || rc=$?
  case "$rc" in
    0) ;;
    3) rm -f "$tmp"; die "FATAL $m already has a row for $DST #$NAME beside $SRC #$CHANNEL: resolve it by hand" 3 ;;
    4) rm -f "$tmp"
       if awk -F'\t' -v d="$DST" -v n="$NAME" '$1 == d && $2 == n { f = 1 } END { exit !f }' "$m"; then
         echo "OK rule-row $SRC #$CHANNEL already -> $DST #$NAME"
       else
         echo "OK no rule row for $SRC #$CHANNEL on this box"
       fi
       return 0 ;;
    *) rm -f "$tmp"; die "FATAL rewrite of $m failed (awk exit $rc)" 1 ;;
  esac
  if [ "$APPLY" != 1 ]; then rm -f "$tmp"; echo "PLAN rule-row $SRC #$CHANNEL -> $DST #$NAME in $m"; return 0; fi
  chmod --reference="$m" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$m" || { rm -f "$tmp"; die "FATAL cannot replace $m" 1; }
  jput rule-row "$SRC/$CHANNEL" "$DST/$NAME"
  echo "OK rule-row $SRC #$CHANNEL -> $DST #$NAME"
}

# --- lane-notes (P5, W4) ----------------------------------------------------------------
verb_lane_notes() {
  need --from "$FROM"; need --lanes "$LANES"
  check_agent --from "$FROM"
  [ -r "$LANES" ] || die "--lanes $LANES is not readable"
  local rows agent topic old new key body
  # one row per lane, fields split by US (0x1f): read collapses empty TAB fields
  rows="$(jq -r '.[] | [.agent // "", .topic // "", .old_key // "", .new_key // ""] | map(tostring) | join("\u001f")' "$LANES")" \
    || die "--lanes $LANES is not a JSON array of {agent, topic, old_key, new_key}"
  while IFS=$'\x1f' read -r agent topic old new; do
    [ -n "$agent" ] || continue
    check_agent "lane" "$agent"
    [[ "$old" =~ $KEY_RX && "$new" =~ $KEY_RX ]] || die "lane $agent: '$old' -> '$new' is not an issue key pair"
    [ -z "$topic" ] || [[ "$topic" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "lane $agent: topic '$topic' is not a task id"
  done <<<"$rows"
  while IFS=$'\x1f' read -r agent topic old new; do
    [ -n "$agent" ] || continue
    key="$agent:$old"
    if [ -n "$(jget note "$key")" ]; then echo "OK note $agent $old -> $new already sent"; continue; fi
    if [ "$APPLY" != 1 ]; then echo "PLAN note $agent $old -> $new${topic:+ on $topic}"; continue; fi
    body="Channel move $MOVE: your issue key changed, $old -> $new. Cite $new in your commits from now on; $old closes nothing once the move's redirect ends (spec 169 W4)."
    local -a targs=()
    [ -z "$topic" ] || targs=(--task "$topic")
    ${CMB_SEND_CMD:-bash "$_here/spool-send.sh"} --from "$FROM" --to "$agent" "${targs[@]}" --kind note --body "$body" </dev/null \
      || die "FATAL the note to $agent ($old -> $new) was not sent; a re-run sends it" 1
    jput note "$key" "$new"
    echo "OK note $agent $old -> $new"
  done <<<"$rows"
}

VERB="${1:-}"; [ "$#" -gt 0 ] && shift
MOVE=""; ENVN=""; DST=""; SRC=""; TO=""; AGENT=""; BOX=""; CHANNEL=""; NAME=""; FROM=""; LANES=""; APPLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift; continue ;;
    --move|--env|--tenant|--src|--dst|--to|--agent|--box|--channel|--to-name|--from|--lanes)
      [ "$#" -ge 2 ] || die "$1 needs a value" ;;
    *) die "unknown argument: $1" ;;
  esac
  case "$1" in
    --move) MOVE="$2" ;; --env) ENVN="$2" ;; --tenant|--dst) DST="$2" ;; --src) SRC="$2" ;;
    --to) TO="$2" ;; --agent) AGENT="$2" ;; --box) BOX="$2" ;; --channel) CHANNEL="$2" ;;
    --to-name) NAME="$2" ;; --from) FROM="$2" ;; --lanes) LANES="$2" ;;
  esac
  shift 2
done
case "$VERB" in probe|rule-rows|lane-notes) ;; *) die "the verb is probe, rule-rows or lane-notes, got: '$VERB'" ;; esac
[[ "$MOVE" =~ $UUID_RX ]] || die "--move '$MOVE' is not a move id (uuid)"
command -v jq >/dev/null || die "jq is not on PATH" 1
case "$VERB" in
  probe) verb_probe ;;
  rule-rows) verb_rule_rows ;;
  lane-notes) verb_lane_notes ;;
esac
