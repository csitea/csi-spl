#!/bin/bash
# @description The asks timer (CLE-77929; SPEC-spool-fleet-roles.md 4.3), run by
# @description the dispatch lease loop on EVERY machine of the fleet each tick:
# @description   1. every machine: push its journal asks the hub has not got
# @description      (do_spl_asks_sync), so a sender whose hub was down is heard
# @description   2. only the machine whose agent holds the orch role (the fleet
# @description      lease's <dir>/lease.orch, else the local LEASE_ORCH):
# @description      a. HANDOVER - the holder changed (or this is its first
# @description         tick): ONE blocker to the holder listing every open
# @description         ask, so a successor gets what the dead holder had
# @description         received and never acked
# @description      b. RE-RAISE - an ask still open (nobody acked it) and quiet
# @description         ASKS_RERAISE_MIN minutes, or acked and past its deadline,
# @description         goes to the holder again, all in ONE blocker; raised_n
# @description         counts it on the hub
# @description      c. OWNER - an ask still unacked ASKS_OWNER_MIN minutes after
# @description         it was raised goes to the owner ONCE (escalated_at), via
# @description         ASKS_OWNER_CMD, else a DM to ASKS_OWNER (a HUM id) from
# @description         the holder's desk (do_spl_desk_reply). Neither set: logged
# @description         once per ask, nothing sent
# @description The messages carry kind blocker on task asks-open and are never
# @description recorded as asks themselves. One tick at a time (flock).
# @param ASKS_RERAISE_MIN (optional) - minutes an open ask may sit unacked before the re-raise, default 15 (also lease.conf)
# @param ASKS_OWNER_MIN (optional) - minutes after which an unacked ask goes to the owner, default 60 (also lease.conf)
# @param ASKS_OWNER (optional) - the owner's human id (HUM-<n>) for the DM leg (also lease.conf)
# @param ASKS_OWNER_CMD (optional) - replaces the DM leg: run with the text on stdin and ASK_JSON in the environment
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
  local rows
  spl_asks_load || return 1
  rows="$(jq -c '[.[] | select(.state == "open" or .state == "acked")]' <<<"$ASKS_ROWS")"
  spl_asks_summary "$holder" "$rows"
  spl_asks_handover "$holder" "$rows" || spl_asks_reraise "$holder" "$rows"
  spl_asks_owner "$holder" "$rows"
  return 0
}

# One line: what this tick sees and what is due, before it acts.
spl_asks_summary() {
  jq -r --arg h "$1" --argjson r "$(( ${ASKS_RERAISE_MIN:-15} * 60 ))" --argjson o "$(( ${ASKS_OWNER_MIN:-60} * 60 ))" \
    --arg rm "${ASKS_RERAISE_MIN:-15}" --arg om "${ASKS_OWNER_MIN:-60}" --arg hub "$ASKS_HUB_STATE" '
    "asks tick: holder \($h), hub \($hub): \(length) open (\([.[] | select(.state == "open")] | length) unacked, \([.[] | select(.state == "acked")] | length) acked); "
    + "re-raise due \([.[] | select(.quiet_s >= $r and (.state == "open" or .overdue))] | length) (quiet >= \($rm) min); "
    + "owner due \([.[] | select(.state == "open" and .age_s >= $o and ((.escalated_at // "") == ""))] | length) (open >= \($om) min)"' <<<"$2" |
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
  [[ "$h" =~ ^[A-Z]{2,4}-[0-9]{1,9}@[a-z0-9][a-z0-9-]{0,31}$ ]] && printf '%s' "$h"
  return 0
}

# One line per ask for a message body.
spl_asks_lines() {
  jq -r '.[] | "- **\(.ask_id[0:8])** \(.kind) from \(.from), open \(.age_s / 60 | floor) min\(if .raised_n > 0 then ", raised \(.raised_n)x" else "" end)\(if .state == "acked" then ", acked by \(.acked_by)" else "" end)\(if .overdue then ", PAST DEADLINE \(.deadline_at)" else "" end), topic \(.topic): \(.summary)"' <<<"$1"
}

spl_asks_footer() {
  printf '\nAck: `ASK_ID=<8 hex> ./run -a do_spl_ask_ack`; close: `ASK_ID=<8 hex> ASK_REASON=... ./run -a do_spl_ask_close` (ASK_STATE=declined needs a reason). Book: `./run -a do_spl_asks_open`.'
}

# Send ONE blocker to the holder (never recorded as an ask). 0 = delivered.
# The spool binary is the host one the hub calls use (SPL_SPOOL, built from
# this tree): spool-send.sh otherwise prefers the tree's own bin/spool, which
# in the box user's checkout was a 2026-09-18 build that refuses kind blocker
# (measured 2026-10-02: every re-raise failed there, exit 11).
spl_asks_send() {
  local holder="$1" body="$2" id="${1%@*}" box="${1##*@}" to rc=0 err
  local send="${ASKS_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  to="$id"; [[ "$box" != "$ASKS_BOX" ]] && to="$id@$box"
  err="$(mktemp)"
  SPOOL_ROOT="$SPOOL_ROOT" SPOOL_ASKS=0 SPOOL_BIN="${SPL_SPOOL:-${SPOOL_BIN:-}}" bash "$send" --from "$id" --to "$to" --kind blocker \
    --task asks-open --no-ask --body "$body" >/dev/null 2>"$err" 7>&- 8>&- || rc=$?
  # spool-send.sh: 1-9 = delivered, only the poke did not ring
  if (( rc >= 10 || rc == 2 )); then
    do_log "WARN the asks blocker did NOT reach $holder (spool-send exit $rc): $(grep -v '^to:' "$err" | tr '\n' ' ' | cut -c1-300)"
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  return 0
}

# Record a re-raise on the hub (best effort) and in the journal.
spl_asks_mark() {  # OP ID HOLDER
  local op="$1" id="$2" by="$3" cur n
  if [[ "$LANE_MODE" == hub ]]; then
    spl_asks_hub "$op" --fleet "$LANE_FLEET" --id "$id" --by "$by" >/dev/null 2>&1 ||
      do_log "WARN the hub did not record the $op of ${id:0:8}"
  fi
  cur="$(spool_ask_journal_get "$id" 2>/dev/null)" || return 0
  if [[ "$op" == raise ]]; then
    n="$(jq -r '.raised_n // 0' <<<"$cur")"
    spool_ask_journal_set "$id" "$(jq -n -c --argjson n "$((n + 1))" --arg t "$(spool_asks_now)" '{raised_n: $n, raised_at: $t}')" raise "$by"
  else
    spool_ask_journal_set "$id" "$(jq -n -c --arg t "$(spool_asks_now)" '{escalated_at: $t}')" escalate "$by"
  fi
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

# b. Unacked and quiet past ASKS_RERAISE_MIN, or acked and past the deadline.
spl_asks_reraise() {
  local holder="$1" rows="$2" due n id
  due="$(jq -c --argjson m "$(( ${ASKS_RERAISE_MIN:-15} * 60 ))" \
    '[.[] | select(.quiet_s >= $m and (.state == "open" or .overdue))]' <<<"$rows")"
  n="$(jq length <<<"$due")"
  (( n > 0 )) || return 0
  spl_asks_send "$holder" "$(printf '**ASKS STILL OPEN: %s ask(s) nobody has acked for %s+ min** - re-raised to %s.\n\n%s\n%s' \
    "$n" "${ASKS_RERAISE_MIN:-15}" "$holder" "$(spl_asks_lines "$due")" "$(spl_asks_footer)")" || return 0
  while IFS= read -r id; do spl_asks_mark raise "$id" "$holder"; done < <(jq -r '.[].ask_id' <<<"$due")
  do_log "OK re-raised $n ask(s) to $holder"
}

# c. Unacked ASKS_OWNER_MIN after it was raised, owner not told yet.
spl_asks_owner() {
  local holder="$1" rows="$2" row id text
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id="$(jq -r '.ask_id' <<<"$row")"
    if [[ -z "${ASKS_OWNER_CMD:-}" && ! "${ASKS_OWNER:-}" =~ ^HUM-[0-9]+$ ]]; then
      [[ -e "$(spool_asks_dir)/.owner-off.$id" ]] && continue
      touch "$(spool_asks_dir)/.owner-off.$id"
      do_log "WARN ask ${id:0:8} is unacked past ${ASKS_OWNER_MIN:-60} min and no owner leg is configured (ASKS_OWNER / ASKS_OWNER_CMD in lease.conf)"
      continue
    fi
    text="$(jq -r --arg h "$holder" '"**Unanswered ask to the orchestrator (\(.age_s / 60 | floor) min, re-raised \(.raised_n)x):** \(.kind) from \(.from), topic \(.topic): \(.summary). The acting orchestrator \($h) has not acked it. Ask id \(.ask_id)."' <<<"$row")"
    if spl_asks_owner_send "$holder" "$row" "$text"; then
      spl_asks_mark escalate "$id" "$holder"
      do_log "OK ask ${id:0:8} told to the owner"
    else
      do_log "WARN the owner leg failed for ask ${id:0:8}; retried next tick"
    fi
  done < <(jq -c --argjson m "$(( ${ASKS_OWNER_MIN:-60} * 60 ))" \
    '.[] | select(.state == "open" and .age_s >= $m and ((.escalated_at // "") == ""))' <<<"$rows")
}

spl_asks_owner_send() {  # HOLDER ROW TEXT
  if [[ -n "${ASKS_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    ASK_JSON="$2" $ASKS_OWNER_CMD <<<"$3"; return
  fi
  local topic
  topic="$(cat /proc/sys/kernel/random/uuid)"
  ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX" DESK_AGENT="${1%@*}" DESK_TO="$ASKS_OWNER" \
    DESK_TASK="$topic" DESK_KIND=blocker DESK_BODY="$3" DRY_RUN=0 do_spl_desk_reply >/dev/null
}
