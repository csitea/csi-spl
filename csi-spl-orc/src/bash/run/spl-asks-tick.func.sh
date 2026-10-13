#!/bin/bash
# @description The asks timer (CLE-77929; SPEC-spool-fleet-roles.md 4.3), run by
# @description the dispatch lease loop on EVERY machine of the fleet each tick:
# @description   1. every machine: push its journal asks the hub has not got
# @description      (do_spl_asks_sync), so a sender whose hub was down is heard
# @description   2. the machine holding the DISPATCH role: ALERT the owner once
# @description      when no orchestrator is live on any box (the hub's orch
# @description      holder silent past ASKS_ORCH_STALE s, from the lease loop's
# @description      <dir>/fleet.orch.age); the alert clears itself (below)
# @description   3. only the machine whose agent holds the orch role (the fleet
# @description      lease's <dir>/lease.orch, else the local LEASE_ORCH):
# @description      a. HANDOVER - the holder changed (or this is its first
# @description         tick): ONE blocker to the holder listing every open
# @description         ask, so a successor gets what the dead holder had
# @description         received and never acked
# @description      a0. LOCK TIMEOUT (CLE-77942, Kafka share-group acquisition
# @description         lock) - an acked ask whose holder has been quiet
# @description         ASKS_LOCK_MIN minutes (no re-ack, no close) is released:
# @description         acked -> open on the hub (op release, acked_by kept as
# @description         the last holder) and re-raised this tick, labelled
# @description         "lock expired, acked by X". Re-acking renews the lock
# @description      b. RE-RAISE - an ask still open (nobody acked it) and quiet
# @description         ASKS_RERAISE_MIN minutes, or acked and past its deadline,
# @description         or whose lock just expired, goes to the holder and then
# @description         to every other live DO seat (spl_asks_seats), ONE
# @description         blocker each; any of them may take it (ack as itself).
# @description         raised_n counts it on the hub (the delivery count). One
# @description         raised ASKS_MAX_RAISES times is not raised again
# @description      c. FALLBACK (owner HUM-10, t1 c9beaa77: an agent-to-agent
# @description         ask never pages the owner) - an ask still unacked
# @description         ASKS_OWNER_MIN minutes after it was raised goes ONCE
# @description         (escalated_at) to the fallback seats: c-001 on every
# @description         other box of the orch order, the dispatch holder, every
# @description         other live DO seat and ASKS_SEATS - ONE blocker each
# @description      d. DEAD-LETTER (CLE-77942, Kafka's archived after the
# @description         delivery limit) - an open ask raised ASKS_MAX_RAISES
# @description         times is closed as dead with the reason (op dead) and
# @description         named in the same fallback blocker, never to the owner
# @description      e. ALERT - the owner gets ONE line in #alerts only for a
# @description         real failure: an ask the fallback seats left unacked
# @description         ASKS_ALERT_MIN minutes, or no fallback seat at all. Once
# @description         the cause clears, the alert edits itself to "cleared"
# @description         (do_spl_desk_edit, the hub cannot clear a post's mark
# @description         from a box): no new post, nothing for the owner to do
# @description No "resolved" reply is ever posted. The messages to agents carry
# @description kind blocker on task asks-open and are never recorded as asks
# @description themselves. One tick at a time (flock).
# @param ASKS_RERAISE_MIN (optional) - minutes an open ask may sit unacked before the re-raise, default 15 (also lease.conf)
# @param ASKS_OWNER_MIN (optional) - minutes after which an unacked ask goes to the fallback seats, default 60 (also lease.conf; the name is kept for the lease.conf already deployed)
# @param ASKS_ALERT_MIN (optional) - minutes the fallback seats may leave an ask unacked before the owner alert, default ASKS_OWNER_MIN (also lease.conf)
# @param ASKS_ORCH_STALE (optional) - seconds the hub's orch holder may be silent before the no-orchestrator alert, default 600 (also lease.conf)
# @param ASKS_LOCK_MIN (optional) - minutes an acked ask's holder may stay quiet before the lock expires, default 60, 0 = never (also lease.conf)
# @param ASKS_MAX_RAISES (optional) - the delivery limit: raises after which an open ask is dead-lettered, default 4, 0 = never (also lease.conf)
# @param ASKS_OWNER (optional) - the owner's human id (HUM-<n>), mentioned in an alert (also lease.conf)
# @param ASKS_SEATS (optional) - more DO seats as <ID>@<box>, comma-separated, for the fallback (also lease.conf)
# @param ASKS_SEAT_STALE (optional) - seconds after which this box's agent-run.tsv no longer proves a seat live, default 300
# @param ASKS_SEATS_CMD (optional, tests) - replaces the live DO seat discovery: prints <ID>@<box> lines
# @param ASKS_ALERT_CMD (optional) - replaces the #alerts post and its edit: ASK_ALERT_OP=post|clear, ASK_ALERT_MSG the post id, the text on stdin; post prints the msg id
# @param ASKS_SEND (optional, tests) - replaces spool-send.sh
# @param ASKS_HOLDER (optional, tests) - the holder as <ID>@<box>, instead of lease.orch
# @param ASKS_TICK_WAIT (optional) - seconds to wait for a tick already running (the lease loop's), default 60
# @description Every tick ends with ONE summary line (holder, open, unacked, due), so a
# @description tick that had nothing to do says so instead of printing nothing.
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ./run -a do_spl_asks_tick
# @example ASKS_RERAISE_MIN=5 ASKS_OWNER_MIN=30 ./run -a do_spl_asks_tick

do_spl_asks_tick() {
  spl_asks_init || return 1
  local lock
  lock="$(spool_asks_dir)/.tick.lock" || { do_log "FATAL no journal dir under $SPOOL_ROOT"; return 1; }
  exec 7>>"$lock"
  # wait, not skip: a manual tick that meets the lease loop's must still run
  flock -w "${ASKS_TICK_WAIT:-60}" 7 || { do_log "WARN another asks tick held the lock ${ASKS_TICK_WAIT:-60}s: skipped"; return 0; }
  spl_asks_sync_pending
  spl_asks_orch_alert
  local holder
  holder="$(spl_asks_holder)"
  if [[ -z "$holder" ]]; then
    do_log "INFO no orchestrator holds the orch role right now: nothing to raise"
    return 0
  fi
  if [[ "${holder##*@}" != "$ASKS_BOX" ]]; then
    do_log "INFO the orch role is held on ${holder##*@} ($holder): its machine raises the asks"
    return 0
  fi
  local rows seats
  spl_asks_load || return 1
  rows="$(jq -c --argjson l "$(( ${ASKS_LOCK_MIN:-60} * 60 ))" '[.[] | select(.state == "open" or .state == "acked")
    | . + {lock_expired: ($l > 0 and .state == "acked" and .quiet_s >= $l)}]' <<<"$ASKS_ROWS")"
  spl_asks_summary "$holder" "$rows"
  rows="$(spl_asks_release "$holder" "$rows")"
  seats="$(spl_asks_seats "$holder")"
  spl_asks_handover "$holder" "$rows" || spl_asks_reraise "$holder" "$rows" "$seats"
  spl_asks_fallback "$holder" "$rows" "$(spl_asks_fallback_seats "$holder" "$seats")"
  spl_asks_fallback_alert "$holder" "$rows" "$(spl_asks_fallback_seats "$holder" "$seats")"
  return 0
}

# One line: what this tick sees and what is due, before it acts.
spl_asks_summary() {
  jq -r --arg h "$1" --argjson r "$(( ${ASKS_RERAISE_MIN:-15} * 60 ))" --argjson o "$(( ${ASKS_OWNER_MIN:-60} * 60 ))" \
    --arg rm "${ASKS_RERAISE_MIN:-15}" --arg om "${ASKS_OWNER_MIN:-60}" --arg hub "$ASKS_HUB_STATE" \
    --arg lm "${ASKS_LOCK_MIN:-60}" --argjson x "${ASKS_MAX_RAISES:-4}" '
    "asks tick: holder \($h), hub \($hub): \(length) open (\([.[] | select(.state == "open")] | length) unacked, \([.[] | select(.state == "acked")] | length) acked); "
    + "re-raise due \([.[] | select(.quiet_s >= $r and (.state == "open" or .overdue))] | length) (quiet >= \($rm) min); "
    + "fallback due \([.[] | select(.state == "open" and .age_s >= $o and ((.escalated_at // "") == ""))] | length) (open >= \($om) min); "
    + "lock expired \([.[] | select(.lock_expired)] | length) (acked quiet >= \($lm) min); "
    + "dead-letter due \([.[] | select((.state == "open" or .lock_expired) and $x > 0 and (.raised_n // 0) >= $x)] | length) (raised >= \($x))"' <<<"$2" |
    while IFS= read -r line; do do_log "INFO $line"; done
}

# The orch holder as <ID>@<box>: ASKS_HOLDER, else the fleet lease mirror
# (lease.orch "<ID>@<box> <epoch>"; none@unreachable = nobody), else the
# local LEASE_ORCH / SPOOL_ORCHESTRATOR_ID at this machine's box.
spl_asks_holder() {
  local h=""
  if [[ -n "${ASKS_HOLDER:-}" ]]; then h="$ASKS_HOLDER"
  elif [[ -r "$SPOOL_ROOT/dispatch/lease.orch" ]]; then read -r h _ <"$SPOOL_ROOT/dispatch/lease.orch"
  fi
  case "$h" in
    none@*|unknown:*) return 0 ;;
    *@*) ;;
    '') h="${LEASE_ORCH:-${SPOOL_ORCHESTRATOR_ID:-}}"; [[ -n "$h" ]] && h="$h@$ASKS_BOX" ;;
    *) h="$h@$ASKS_BOX" ;;
  esac
  [[ "$h" =~ ^${SPOOL_PARTICIPANT_RX}@[a-z0-9][a-z0-9-]{0,31}$ ]] && printf '%s' "$h"
  return 0
}

# One line per ask for a message body.
spl_asks_lines() {
  jq -r '.[] | "- **\(.ask_id[0:8])** \(.kind) from \(.from), open \(.age_s / 60 | floor) min\(if .raised_n > 0 then ", raised \(.raised_n)x" else "" end)\(if .lock_expired then ", LOCK EXPIRED, acked by \(.acked_by)" elif .state == "acked" then ", acked by \(.acked_by)" elif (.acked_by // "") != "" then ", last acked by \(.acked_by)" else "" end)\(if .overdue then ", PAST DEADLINE \(.deadline_at)" else "" end), topic \(.topic): \(.summary)"' <<<"$1"
}

spl_asks_footer() {
  printf '\nAck: `ASK_ID=<8 hex> ./run -a do_spl_ask_ack`; close: `ASK_ID=<8 hex> ASK_REASON=... ./run -a do_spl_ask_close` (ASK_STATE=declined needs a reason). Book: `./run -a do_spl_asks_open`.'
}

# Send ONE blocker to a seat (never recorded as an ask). 0 = delivered.
# The spool binary is the host one the hub calls use (SPL_SPOOL, built from
# this tree): spool-send.sh otherwise prefers the tree's own bin/spool, which
# in the box user's checkout was a 2026-09-18 build that refuses kind blocker
# (measured 2026-10-02: every re-raise failed there, exit 11).
spl_asks_send() {  # SEAT BODY [FROM, default the seat's own id]
  local holder="$1" body="$2" id="${1%@*}" box="${1##*@}" to rc=0 err from="${3:-${1%@*}}"
  local send="${ASKS_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  to="$id"; [[ "$box" != "$ASKS_BOX" ]] && to="$id@$box"
  err="$(mktemp)"
  SPOOL_ROOT="$SPOOL_ROOT" SPOOL_ASKS=0 SPOOL_BIN="${SPL_SPOOL:-${SPOOL_BIN:-}}" bash "$send" --from "$from" --to "$to" --kind blocker \
    --task asks-open --no-ask --body "$body" >/dev/null 2>"$err" 7>&- 8>&- || rc=$?
  # spool-send.sh: 1-9 = delivered, only the poke did not ring
  if (( rc >= 10 || rc == 2 )); then
    do_log "WARN the asks blocker did NOT reach $holder (spool-send exit $rc): $(grep -v '^to:' "$err" | tr '\n' ' ' | cut -c1-300)"
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  return 0
}

# Record a tick op (raise | escalate | release | dead) on the hub (best
# effort) and in the journal. 1 = the hub refused it (logged).
spl_asks_mark() {  # OP ID HOLDER [REASON]
  local op="$1" id="$2" by="$3" reason="${4:-}" cur n rc=0
  if [[ "$LANE_MODE" == hub ]]; then
    spl_asks_hub "$op" --fleet "$LANE_FLEET" --id "$id" --by "$by" --reason "$reason" >/dev/null 2>&1 ||
      { do_log "WARN the hub did not record the $op of ${id:0:8}" >&2; rc=1; }
  fi
  cur="$(spool_ask_journal_get "$id" 2>/dev/null)" || return "$rc"
  case "$op" in
    raise)
      n="$(jq -r '.raised_n // 0' <<<"$cur")"
      spool_ask_journal_set "$id" "$(jq -n -c --argjson n "$((n + 1))" --arg t "$(spool_asks_now)" '{raised_n: $n, raised_at: $t}')" raise "$by" ;;
    escalate) spool_ask_journal_set "$id" "$(jq -n -c --arg t "$(spool_asks_now)" '{escalated_at: $t}')" escalate "$by" ;;
    release) spool_ask_journal_set "$id" '{"state":"open"}' release "$by" ;;
    dead) spool_ask_journal_set "$id" "$(jq -n -c --arg b "$by" --arg r "$reason" '{state: "dead", closed_by: $b, reason: $r}')" dead "$by" ;;
  esac
  return "$rc"
}

# a0. The acquisition lock: an acked ask whose holder went quiet
# ASKS_LOCK_MIN is released (acked -> open). Prints the rows with those
# asks open again (lock_expired stays set, for the re-raise's label).
spl_asks_release() {
  local holder="$1" rows="$2" id by n=0
  while IFS=' ' read -r id by; do
    [[ -n "$id" ]] || continue
    spl_asks_mark release "$id" "$holder" >&2 || true
    do_log "INFO ask ${id:0:8}: the lock of $by expired (quiet >= ${ASKS_LOCK_MIN:-60} min): released to open" >&2
    n=$((n + 1))
  done < <(jq -r '.[] | select(.lock_expired) | "\(.ask_id) \(.acked_by)"' <<<"$rows")
  jq -c 'map(if .lock_expired then .state = "open" else . end)' <<<"$rows"
}

# a. A new holder (or this machine's first tick as holder) gets every open
# ask in one message. Returns 0 when it sent (the re-raise waits a tick).
spl_asks_handover() {
  local holder="$1" rows="$2" f prev n id
  f="$(spool_asks_dir)/.holder"
  prev="$(cat "$f" 2>/dev/null)"
  [[ "$prev" == "$holder" ]] && return 1
  n="$(jq length <<<"$rows")"
  if (( n == 0 )); then echo "$holder" >"$f"; return 1; fi
  spl_asks_send "$holder" "$(printf '**ASKS HANDOVER: %s open ask(s) for %s** (the orch role was %s). Each one is OPEN until you ack and close it; whoever held the role before you may have read them and died before acking.\n\n%s\n%s' \
    "$n" "$holder" "${prev:-not seen on this machine}" "$(spl_asks_lines "$rows")" "$(spl_asks_footer)")" || return 1
  echo "$holder" >"$f"
  while IFS= read -r id; do spl_asks_mark raise "$id" "$holder"; done < <(jq -r '.[].ask_id' <<<"$rows")
  do_log "OK handover: $n open ask(s) sent to $holder (was ${prev:-none})"
  return 0
}

# b. Unacked and quiet past ASKS_RERAISE_MIN, or acked and past the deadline,
# or its lock just expired - and below the delivery limit (d takes the rest).
# The holder first, then every other live DO seat (any may take it).
spl_asks_reraise() {  # HOLDER ROWS SEATS
  local holder="$1" rows="$2" due n id seat sent=0 body
  due="$(jq -c --argjson m "$(( ${ASKS_RERAISE_MIN:-15} * 60 ))" --argjson x "${ASKS_MAX_RAISES:-4}" \
    '[.[] | select(($x == 0 or (.raised_n // 0) < $x) and (.lock_expired or (.quiet_s >= $m and (.state == "open" or .overdue))))]' <<<"$rows")"
  n="$(jq length <<<"$due")"
  (( n > 0 )) || return 0
  body="$(printf '**ASKS STILL OPEN: %s ask(s) nobody has acked for %s+ min, or whose holder went quiet %s+ min after acking** - re-raised to %s and every live DO seat (delivery limit %s); any DO seat may take one: ack it as yourself, then close it.\n\n%s\n%s' \
    "$n" "${ASKS_RERAISE_MIN:-15}" "${ASKS_LOCK_MIN:-60}" "$holder" "${ASKS_MAX_RAISES:-4}" "$(spl_asks_lines "$due")" "$(spl_asks_footer)")"
  while IFS= read -r seat; do
    spl_asks_send "$seat" "$body" "${holder%@*}" && sent=$((sent + 1))
  done < <(printf '%s\n%s\n' "$holder" "${3:-}" | spl_asks_seat_filter)
  (( sent > 0 )) || return 0
  while IFS= read -r id; do spl_asks_mark raise "$id" "$holder"; done < <(jq -r '.[].ask_id' <<<"$due")
  do_log "OK re-raised $n ask(s) to $holder and $((sent - 1)) more DO seat(s)"
}

# The live DO seats as <ID>@<box>, the holder first, one per line, unique:
# ASKS_SEATS_CMD (tests), else this box's c-001..c-003 that the lease loop's
# agent-run.tsv shows running (fresh within ASKS_SEAT_STALE s) and the
# dispatch lease holder (the lease mirror: it renews only while live).
spl_asks_seats() {  # HOLDER
  local d=""
  {
    printf '%s\n' "$1"
    if [[ -n "${ASKS_SEATS_CMD:-}" ]]; then
      "$ASKS_SEATS_CMD" 2>/dev/null
    else
      spl_asks_seats_here
      [[ -r "$SPOOL_ROOT/dispatch/lease" ]] && read -r d _ <"$SPOOL_ROOT/dispatch/lease"
      printf '%s\n' "$d"
    fi
  } | spl_asks_seat_filter
}

# This box's DO seats (ids 001-003) in a fresh agent-run.tsv ("# agent-run
# v1 <epoch>", then "<id>\t<state>" rows; run = live and able).
spl_asks_seats_here() {
  local f="$SPOOL_ROOT/dispatch/agent-run.tsv" at="" id st
  [[ -r "$f" ]] || return 0
  declare -F spl_is_role_seat >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  read -r _ _ _ at _ <"$f"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at <= ${ASKS_SEAT_STALE:-300} )) || return 0
  while IFS=$'\t' read -r id st _; do
    spl_is_role_seat "$id" && [[ "$st" == run ]] && printf '%s@%s\n' "$id" "$ASKS_BOX"
  done <"$f"
  return 0
}

# stdin -> the well-formed <ID>@<box> lines, first occurrence kept.
spl_asks_seat_filter() {
  local s
  declare -A uniq=()
  while IFS= read -r s; do
    [[ "$s" =~ ^${SPOOL_PARTICIPANT_RX}@[a-z0-9][a-z0-9-]{0,31}$ && -z "${uniq[$s]:-}" ]] || continue
    uniq[$s]=1
    printf '%s\n' "$s"
  done
  return 0
}

# The fallback seats (owner HUM-10, t1 c9beaa77): the orchestrator id on
# every other box of the orch order first, then every live DO seat but the
# holder, then ASKS_SEATS. Empty = nobody to fall back to.
spl_asks_fallback_seats() {  # HOLDER SEATS
  local h="$1" b
  {
    for b in $(tr ',' ' ' <<<"${LEASE_PRIORITY_ORCH:-${LEASE_PRIORITY:-}}"); do
      [[ "$b" != "${h##*@}" ]] && printf '%s@%s\n' "${h%@*}" "$b"
    done
    printf '%s\n' "$2"
    tr ' ,' '\n' <<<"${ASKS_SEATS:-}"
  } | grep -vxF -- "$h" | spl_asks_seat_filter
}

# c + d. Open and unacked ASKS_OWNER_MIN without a fallback yet, or at the
# delivery limit: ONE blocker to each fallback seat (never the owner), then
# escalated_at on each, and the ones at the limit closed as dead.
spl_asks_fallback() {  # HOLDER ROWS FALLBACK_SEATS
  local holder="$1" seats="$3" due n seat sent=0 id maxed told why tail
  due="$(jq -c --argjson m "$(( ${ASKS_OWNER_MIN:-60} * 60 ))" --argjson x "${ASKS_MAX_RAISES:-4}" \
    '[.[] | select(.state == "open") | . + {maxed: ($x > 0 and (.raised_n // 0) >= $x)}
      | select(.maxed or (.age_s >= $m and ((.escalated_at // "") == "")))]' <<<"$2")"
  n="$(jq length <<<"$due")"
  (( n > 0 )) || return 0
  if [[ -z "$seats" ]]; then
    do_log "WARN $n ask(s) due for the fallback and no DO seat besides $holder: the owner alert decides"
    tail="no DO seat to tell"
  else
    while IFS= read -r seat; do
      spl_asks_send "$seat" "$(spl_asks_fallback_body "$holder" "$due" "$n")" "${holder%@*}" && sent=$((sent + 1))
    done <<<"$seats"
    if (( sent == 0 )); then do_log "WARN the fallback reached no DO seat; retried next tick"; return 0; fi
    do_log "OK fallback: $n ask(s) sent to $sent DO seat(s): $(tr '\n' ' ' <<<"$seats")"
    tail="the DO seats were told"
  fi
  while IFS=$'\t' read -r id maxed told; do
    [[ -n "$id" ]] || continue
    [[ -n "$seats" && -z "$told" ]] && spl_asks_mark escalate "$id" "$holder"
    why="max delivery count ${ASKS_MAX_RAISES:-4} reached"
    [[ "$maxed" == true ]] && spl_asks_dead "$id" "$holder" "$why (raised $(jq -r --arg i "$id" '.[] | select(.ask_id == $i) | .raised_n // 0' <<<"$due")x); $tail"
  done < <(jq -r '.[] | [.ask_id, (.maxed | tostring), (.escalated_at // "")] | @tsv' <<<"$due")
  return 0
}

spl_asks_fallback_body() {  # HOLDER DUE N
  printf '**ASKS FALLBACK: %s ask(s) the orchestrator %s has not acked for %s+ min** - any DO seat may take one: ack it as yourself, handle it, close it. The owner is not paged for these; one they all leave %s+ min becomes an #alerts line.\n\n%s\n%s' \
    "$3" "$1" "${ASKS_OWNER_MIN:-60}" "${ASKS_ALERT_MIN:-${ASKS_OWNER_MIN:-60}}" \
    "$(jq -r '.[] | "- **\(.ask_id[0:8])** \(.kind) from \(.from), open \(.age_s / 60 | floor) min, raised \(.raised_n // 0)x\(if .maxed then ", DEAD-LETTERED at the delivery limit" else "" end), topic \(.topic): \(.summary)"' <<<"$2")" \
    "$(spl_asks_footer)"
}

# e1. The asks the fallback left unanswered: open ASKS_ALERT_MIN after the
# fallback (escalated_at, on the hub's clock: created_at + age_s), or open
# ASKS_OWNER_MIN with no fallback seat at all. ONE alert while any is.
spl_asks_fallback_alert() {  # HOLDER ROWS FALLBACK_SEATS
  local holder="$1" stuck n=0 text="" none=false
  [[ -z "$3" ]] && none=true
  stuck="$(jq -c --argjson m "$(( ${ASKS_ALERT_MIN:-${ASKS_OWNER_MIN:-60}} * 60 ))" --argjson o "$(( ${ASKS_OWNER_MIN:-60} * 60 ))" --argjson none "$none" '
    [.[] | select(.state == "open")
      | ((.created_at // "") | try fromdateiso8601 catch 0) as $c | ($c + (.age_s // 0)) as $t
      | ((.escalated_at // "") | if . == "" then null else (try fromdateiso8601 catch null) end) as $e
      | select(($e != null and $c > 0 and $t - $e >= $m) or ($none and .age_s >= $o))]' <<<"$2")"
  n="$(jq length <<<"$stuck")"
  if (( n > 0 )); then
    text="$(jq -r --arg h "$holder" --arg who "$(spl_asks_alert_who)" --argjson none "$none" --arg m "${ASKS_ALERT_MIN:-${ASKS_OWNER_MIN:-60}}" '
      (sort_by(-.age_s) | .[0]) as $o |
      "**ALERT**\($who): \(length) ask(s) to the orchestrator \(if $none then "and no DO seat besides \($h) to fall back to" else "unanswered by every DO seat \($m)+ min after the fallback" end). "
      + "Oldest \($o.ask_id[0:8]) from \($o.from), \($o.age_s / 60 | floor) min: \($o.summary // "" | .[0:100]). "
      + "Blocks: \([.[].from | split("@")[0]] | unique | join(", ")). "
      + "Do: wake a DO seat (c-001/c-002/c-003), or take it: `ASK_ID=\($o.ask_id[0:8]) ./run -a do_spl_ask_ack`."' <<<"$stuck" | tr -d '\n')"
  fi
  spl_asks_alert fallback "$(( n > 0 ))" "$text" "${holder%@*}"
}

# e2. Run on the machine holding the DISPATCH role: no live orchestrator on
# any box = the hub's orch holder silent past ASKS_ORCH_STALE s. The lease
# loop writes <dir>/fleet.orch.age "<holder> <silent s> <epoch read>" every
# tick; without it nothing is known and nothing is said.
spl_asks_orch_alert() {
  local dh="" h="" age="" seen="" active=0 text=""
  [[ -r "$SPOOL_ROOT/dispatch/lease" ]] && read -r dh _ <"$SPOOL_ROOT/dispatch/lease"
  [[ "$dh" == *@"$ASKS_BOX" ]] || return 0
  [[ -r "$SPOOL_ROOT/dispatch/fleet.orch.age" ]] && read -r h age seen _ <"$SPOOL_ROOT/dispatch/fleet.orch.age"
  [[ "$age" =~ ^[0-9]+$ && "$seen" =~ ^[0-9]+$ ]] || return 0
  age=$(( age + $(date +%s) - seen ))
  if [[ "$h" != *@* ]] || (( age > ${ASKS_ORCH_STALE:-600} )); then
    active=1
    text="**ALERT**$(spl_asks_alert_who): no live orchestrator on any box - ${h:-nobody} has held the orch lease silent $(( age / 60 )) min. Blocks: every ask to the orchestrator, spawns and lane placement. Do: restart the orchestrator seat on its box (\`IDENTITY_RESTORE_IDS=${h%@*} DRY_RUN=0 ./run -a do_spl_agent_identity_restore\`)."
  fi
  spl_asks_alert orch "$active" "$text" "${dh%@*}"
}

# " @HUM-n" when the owner id is known, so the #alerts line reaches them.
spl_asks_alert_who() { [[ "${ASKS_OWNER:-}" =~ ^HUM-[0-9]+$ ]] && printf ' @%s' "$ASKS_OWNER"; return 0; }

# ONE alert per cause: posted once while the cause holds (<asks dir>/.alert.
# <cause>: post id, author, text); when the cause clears, the post is edited
# to say so - no new post, nothing for the owner to answer.
spl_asks_alert() {  # CAUSE ACTIVE(0|1) TEXT AUTHOR
  local f msg="" by="" old=""
  f="$(spool_asks_dir)/.alert.$1" || return 0
  if [[ "$2" == 1 ]]; then
    [[ -s "$f" ]] && return 0
    msg="$(spl_asks_alert_post "$4" "$3")" || msg=""
    if [[ -z "$msg" ]]; then do_log "WARN the $1 alert did not post; retried next tick"; return 0; fi
    printf '%s\n%s\n%s\n' "$msg" "$4" "$3" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
    do_log "ALERT $1 (once, until it clears): $3"
    return 0
  fi
  [[ -s "$f" ]] || return 0
  { IFS= read -r msg; IFS= read -r by; IFS= read -r old; } <"$f"
  if spl_asks_alert_clear "$by" "$msg" "$old"; then
    rm -f "$f"
    do_log "OK the $1 alert cleared itself (post $msg edited, no new post)"
  else
    do_log "WARN the $1 alert could not be marked cleared; retried next tick"
  fi
  return 0
}

# The #alerts post (do_spl_desk_post, kind note: a blocker would become an
# issue for the owner). Prints the post id; "unposted" when this machine has
# no hub (a stub hub, or journal only), logged instead.
spl_asks_alert_post() {  # AUTHOR TEXT
  local out msg
  if [[ -n "${ASKS_ALERT_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(ASK_ALERT_OP=post ASK_ALERT_MSG='' $ASKS_ALERT_CMD <<<"$2")" || return 1
  elif [[ -n "${ASKS_HUB_CMD:-}" || "${LANE_MODE:-}" != hub ]]; then
    do_log "ALERT (not posted, no hub on this machine): $2" >&2
    printf 'unposted'; return 0
  else
    out="$(ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX" DESK_AGENT="$1" DESK_CHANNEL=alerts \
      DESK_KIND=note DESK_BODY="$2" DRY_RUN=0 do_spl_desk_post 2>/dev/null)" || return 1
  fi
  msg="$(grep '^{' <<<"$out" | tail -1 | jq -r '.send.msg_id // .msg_id // empty' 2>/dev/null)"
  [[ -n "$msg" ]] || msg="$(tail -1 <<<"$out")"
  printf '%s' "$msg"
}

# The cleared alert: the same post, edited in place (its author edits it).
spl_asks_alert_clear() {  # AUTHOR MSG TEXT
  local body
  [[ "$2" == unposted ]] && return 0
  body="Cleared $(date -u +%Y-%m-%dT%H:%M:%SZ), nothing to do. Was: ${3/ @${ASKS_OWNER:-HUM-none}/}"
  if [[ -n "${ASKS_ALERT_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    ASK_ALERT_OP=clear ASK_ALERT_MSG="$2" $ASKS_ALERT_CMD <<<"$body" >/dev/null
    return
  fi
  ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX" DESK_AGENT="$1" MSG_ID="$2" \
    DESK_BODY="$body" DRY_RUN=0 do_spl_desk_edit >/dev/null 2>&1
}

# d. Close an ask as dead with the reason (Kafka: archived).
spl_asks_dead() {  # ID HOLDER REASON
  spl_asks_mark dead "$1" "$2" "$3" &&
    do_log "OK ask ${1:0:8} dead-lettered: $3"
}
