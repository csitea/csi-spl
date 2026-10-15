#!/bin/bash
# @description The spawn queue, oldest first (owner HUM-10, t1 c9beaa77 msg
# @description ca668844: "you are in line ... some kind scheduling structure in
# @description the db, where once resources are free they will be just taken").
# @description A spawn request is an ask to the orchestrator; the orchestrator
# @description puts it in line with do_spl_spawn_enqueue (rdb 0180: state
# @description queued, enqueued_at, an optional placement "<vendor>:<slug>"),
# @description the placer (do_spl_spawn_place, every minute on the orch box)
# @description takes position 1 when the box has room, and do_spl_spawn_placed
# @description closes it with the agent id. The asks tick raises and escalates
# @description only open and acked asks, so a queued one is never re-raised,
# @description never told to the owner and never dead-lettered, whatever its age.
# @description One row per waiting request: POS (1 = placed next; "placing" =
# @description the placer took it), its CLASS (rdb 0195, SPL-1817; "+urgent" /
# @description "+bypass" when flagged), the ask, the sender, its age, how long
# @description it has been in line, the placement and the summary; then one
# @description line with the live share per class against the bands
# @description (do_spl_spawn_share; the rule: fleet-rules-index.md). A queued
# @description ask the launcher held gets one WAIT line with its reason
# @description (do_spl_spawn_place's .place.wait, e.g. "waiting: claude weekly
# @description >= 90% on box-a, box-b", SPL-2035).
# @description The order is the hub's (class, then time in line); the placer
# @description may take a lower row to keep the bands (do_spl_spawn_place).
# @param SPAWN_QUEUE_FORMAT (optional) - table (default) or json
# @param SPAWN_QUEUE_SHARE (optional) - 0 skips the share line (it reads the lane map)
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ./run -a do_spl_spawn_queue
# @example SPAWN_QUEUE_FORMAT=json ./run -a do_spl_spawn_queue

do_spl_spawn_queue() {
  local fmt="${SPAWN_QUEUE_FORMAT:-table}" rows share
  [[ "$fmt" =~ ^(table|json)$ ]] || { do_log "FATAL SPAWN_QUEUE_FORMAT must be table or json"; return 1; }
  spl_spawn_q_init || return 1
  rows="$(spl_spawn_q_rows)" || { do_log "FATAL the hub did not answer: the spawn queue lives there (rdb 0180)"; return 1; }
  if [[ "$fmt" == json ]]; then
    jq -c --arg f "$LANE_FLEET" '{fleet: $f, queue: .}' <<<"$rows"
    return 0
  fi
  # -c 1000: util-linux 2.39 column (ubuntu-latest) drops every column past
  # 80 characters when stdout is no tty, so a pipe or a CI log lost SUMMARY.
  jq -r '
    def cut($n): if length > $n then .[0:$n-1] + "~" else . end;
    def dur: if . == null then "-" elif . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
    (["POS", "CLASS", "ASK", "FROM", "AGE", "IN LINE", "PLACEMENT", "TOPIC", "SUMMARY"] | @tsv),
    (.[] | [ (if .state == "acked" then "placing" else "\(.position)/\(.queue_len)" end),
             ((.class // "" | if . == "" then "?" else . end) + (if (.flag // "") != "" then "+" + .flag else "" end)), .ask_id[0:8], .from,
             (.age_s | dur), (.wait_s | dur), (.placement // "" | if . == "" then "-" else . end),
             (.topic | cut(12)), (.summary | cut(70)) ] | @tsv)' <<<"$rows" | column -t -s $'\t' -c 1000
  spl_spawn_q_waits "$rows"
  do_log "INFO $(jq '[.[] | select(.state == "queued")] | length' <<<"$rows") queued, $(jq '[.[] | select(.state == "acked")] | length' <<<"$rows") placing (fleet $LANE_FLEET)"
  if [[ "${SPAWN_QUEUE_SHARE:-1}" != 0 ]]; then
    if share="$(spl_spawn_share)"; then do_log "INFO $(spl_spawn_share_line "$share")"
    else do_log "WARN the live share could not be read (hub or lane map)"
    fi
  fi
}

# One "WAIT <ask8> <why> (held Nm ago)" line per queued ask in ROWS with a
# reason in <asks dir>/.place.wait (spl_spawn_place_wait).
spl_spawn_q_waits() {  # ROWS
  local id at why now
  now="$(date +%s)"
  while IFS=$'\t' read -r id at why; do
    [[ "$at" =~ ^[0-9]+$ ]] && jq -e --arg id "$id" 'any(.[]; .ask_id == $id and .state == "queued")' >/dev/null <<<"$1" || continue
    echo "WAIT ${id:0:8} $why (held $(( (now - at) / 60 ))m ago)"
  done <"$(spool_asks_dir)/.place.wait" 2>/dev/null
  return 0
}

# The asks settings (spl_asks_init) and a hub: the queue has no journal-only
# mode, a queued ask must be the same row on every machine.
spl_spawn_q_init() {
  spl_asks_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "FATAL no fleet hub on this machine: the spawn queue lives on the hub (rdb 0180)"; return 1; }
  return 0
}

# The waiting spawn requests of the orch role as a JSON array: the placing
# ones (acked, with enqueued_at) first, then the queue by position. wait_s is
# the time in line, on this machine's clock against the hub's enqueued_at.
spl_spawn_q_rows() {
  local out now
  now="$(date -u +%s)"
  out="$(spl_asks_hub list --fleet "$LANE_FLEET" --role orch 2>"${ASKS_ERR:-/dev/null}")" || return 1
  jq -e -c --argjson now "$now" '
    def secs: if . == null or . == "" then null else (sub("\\.[0-9]+"; "") | fromdateiso8601) end;
    [.asks[] | select(.state == "queued" or (.state == "acked" and (.enqueued_at // "") != ""))
     | . + {wait_s: ((.enqueued_at | secs) as $e | if $e == null then null else $now - $e end)}]
    | sort_by((if .state == "acked" then 0 else 1 end), (.position // 0))' <<<"$out" 2>/dev/null
}

# The task a reply rides: an owner topic uuid never (a lane relay in it is
# read by the owner as addressed to him) -> dispatch-<topic8>; none -> spawn-queue.
spl_spawn_q_task() {
  local t="$1"
  if [[ "$t" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then printf 'dispatch-%s' "${t:0:8}"
  elif [[ -n "$t" ]]; then printf '%s' "$t"
  else printf 'spawn-queue'
  fi
}

# One spool message FROM (<ID>@<box>) TO (<ID>@<box>), kind KIND, on TASK.
# A peer on this box is addressed by its bare id, another box's as <ID>@<box>.
# SPAWN_QUEUE_SEND replaces spool-send.sh (tests). 0 = delivered.
spl_spawn_q_send() {  # FROM TO KIND TASK BODY
  local from="${1%@*}" to="$2" rc=0
  [[ "${to##*@}" == "$ASKS_BOX" ]] && to="${to%@*}"
  local send="${SPAWN_QUEUE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="$SPOOL_ROOT" SPOOL_ASKS=0 SPOOL_BIN="${SPL_SPOOL:-${SPOOL_BIN:-}}" bash "$send" --from "$from" --to "$to" \
    --kind "$3" --task "$4" --no-ask --body "$5" >/dev/null 2>&1 6>&- 7>&- || rc=$?
  # spool-send.sh: 1-9 = delivered, only the poke did not ring
  (( rc >= 10 || rc == 2 )) && { do_log "WARN the $3 to $2 on $4 was NOT delivered (spool-send exit $rc)"; return 1; }
  return 0
}

# Tell the sender of ROW (an ask row) TEXT, on its task, from BY.
spl_spawn_q_reply() {  # ROW BY TEXT
  local from topic
  from="$(jq -r '.from // ""' <<<"$1")"
  topic="$(jq -r '.topic // ""' <<<"$1")"
  [[ "$from" == *@* ]] || from="$from@$ASKS_BOX"
  spl_spawn_q_send "$2" "$from" note "$(spl_spawn_q_task "$topic")" "$3"
}

# One op on the hub, the answer's row on stdout (and mirrored into the
# journal). 3 = the ask is already closed (the hub's 409, printed).
spl_spawn_q_op() {  # OP ID BY [REASON] [PLACEMENT] [CLASS] [FLAG] [FLAG_MSG]
  local out row
  if ! out="$(spl_asks_hub "$1" --fleet "$LANE_FLEET" --id "$2" --by "$3" --reason "${4:-}" ${5:+--placement "$5"} \
    ${6:+--class "$6"} ${7:+--flag "$7"} ${8:+--flag-msg "$8"} 2>&1)"; then
    if grep -q 'ask_closed' <<<"$out"; then do_log "WARN ask ${2:0:8}: $(tail -1 <<<"$out")" >&2; return 3; fi
    do_log "WARN the hub did not take the $1 of ask ${2:0:8}: $(tail -1 <<<"$out" | cut -c1-200)" >&2
    return 1
  fi
  row="$(jq -c '.asks[0] // empty' <<<"$out" 2>/dev/null)"
  [[ -n "$row" ]] || { do_log "WARN the hub's $1 answer of ask ${2:0:8} has no row" >&2; return 1; }
  spl_asks_mirror "[$row]" >&2
  printf '%s\n' "$row"
}

# ASK_ID (full or a unique prefix) against the hub's book.
spl_spawn_q_resolve() {
  spl_asks_load || return 1
  spl_asks_resolve "${ASK_ID:-}" "$ASKS_ROWS"
}
