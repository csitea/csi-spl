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
# @description      a0. LOCK TIMEOUT (CLE-77942, Kafka share-group acquisition
# @description         lock) - an acked ask whose holder has been quiet
# @description         ASKS_LOCK_MIN minutes (no re-ack, no close) is released:
# @description         acked -> open on the hub (op release, acked_by kept as
# @description         the last holder) and re-raised this tick, labelled
# @description         "lock expired, acked by X". Re-acking renews the lock
# @description      b. RE-RAISE - an ask still open (nobody acked it) and quiet
# @description         ASKS_RERAISE_MIN minutes, or acked and past its deadline,
# @description         or whose lock just expired, goes to the holder again,
# @description         all in ONE blocker; raised_n counts it on the hub (the
# @description         delivery count). One raised ASKS_MAX_RAISES times is not
# @description         raised again
# @description      c. OWNER - an ask still unacked ASKS_OWNER_MIN minutes after
# @description         it was raised goes to the owner ONCE (escalated_at). The
# @description         reminder names the topic by its title, who is waiting,
# @description         the summary and what the owner is asked to do, and keeps
# @description         the topic uuid. A channel topic this owner can read gets
# @description         the reminder as a reply in it; any other topic gets a new
# @description         one (the old id line when the title could not be read).
# @description         ASKS_OWNER_CMD, else a DM to ASKS_OWNER (a HUM id) from
# @description         the holder's desk (do_spl_desk_reply). Neither set: logged
# @description         once per ask, nothing sent
# @description      c2. RESOLVED - once that ask is acked, closed or dead, one
# @description         reply in the reminder's topic says resolved and why.
# @description         A dead-letter in the same tick is answered on the next
# @description      d. DEAD-LETTER (CLE-77942, Kafka's archived after the
# @description         delivery limit) - an open ask raised ASKS_MAX_RAISES
# @description         times goes to the owner (as c, unless already told) and
# @description         is closed as dead with the reason (op dead), whichever
# @description         of c's age and d's count comes first
# @description The messages carry kind blocker on task asks-open and are never
# @description recorded as asks themselves. One tick at a time (flock).
# @param ASKS_RERAISE_MIN (optional) - minutes an open ask may sit unacked before the re-raise, default 15 (also lease.conf)
# @param ASKS_OWNER_MIN (optional) - minutes after which an unacked ask goes to the owner, default 60 (also lease.conf)
# @param ASKS_LOCK_MIN (optional) - minutes an acked ask's holder may stay quiet before the lock expires, default 60, 0 = never (also lease.conf)
# @param ASKS_MAX_RAISES (optional) - the delivery limit: raises after which an open ask is dead-lettered to the owner, default 4, 0 = never (also lease.conf)
# @param ASKS_OWNER (optional) - the owner's human id (HUM-<n>) for the DM leg (also lease.conf)
# @param ASKS_OWNER_CMD (optional) - replaces the DM leg: the text on stdin, ASK_JSON the row, ASK_TASK the reminder topic
# @param ASKS_TOPIC_CMD (optional) - replaces the topic lookup: arg 1 is the topic uuid; prints {"title","readable","channel","ask"}
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
  rows="$(jq -c --argjson l "$(( ${ASKS_LOCK_MIN:-60} * 60 ))" '[.[] | select(.state == "open" or .state == "acked")
    | . + {lock_expired: ($l > 0 and .state == "acked" and .quiet_s >= $l)}]' <<<"$ASKS_ROWS")"
  spl_asks_summary "$holder" "$rows"
  rows="$(spl_asks_release "$holder" "$rows")"
  spl_asks_handover "$holder" "$rows" || spl_asks_reraise "$holder" "$rows"
  spl_asks_owner "$holder" "$rows"
  spl_asks_resolved "$holder"
  return 0
}

# One line: what this tick sees and what is due, before it acts.
spl_asks_summary() {
  jq -r --arg h "$1" --argjson r "$(( ${ASKS_RERAISE_MIN:-15} * 60 ))" --argjson o "$(( ${ASKS_OWNER_MIN:-60} * 60 ))" \
    --arg rm "${ASKS_RERAISE_MIN:-15}" --arg om "${ASKS_OWNER_MIN:-60}" --arg hub "$ASKS_HUB_STATE" \
    --arg lm "${ASKS_LOCK_MIN:-60}" --argjson x "${ASKS_MAX_RAISES:-4}" '
    "asks tick: holder \($h), hub \($hub): \(length) open (\([.[] | select(.state == "open")] | length) unacked, \([.[] | select(.state == "acked")] | length) acked); "
    + "re-raise due \([.[] | select(.quiet_s >= $r and (.state == "open" or .overdue))] | length) (quiet >= \($rm) min); "
    + "owner due \([.[] | select(.state == "open" and .age_s >= $o and ((.escalated_at // "") == ""))] | length) (open >= \($om) min); "
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
spl_asks_reraise() {
  local holder="$1" rows="$2" due n id
  due="$(jq -c --argjson m "$(( ${ASKS_RERAISE_MIN:-15} * 60 ))" --argjson x "${ASKS_MAX_RAISES:-4}" \
    '[.[] | select(($x == 0 or (.raised_n // 0) < $x) and (.lock_expired or (.quiet_s >= $m and (.state == "open" or .overdue))))]' <<<"$rows")"
  n="$(jq length <<<"$due")"
  (( n > 0 )) || return 0
  spl_asks_send "$holder" "$(printf '**ASKS STILL OPEN: %s ask(s) nobody has acked for %s+ min, or whose holder went quiet %s+ min after acking** - re-raised to %s (delivery limit %s).\n\n%s\n%s' \
    "$n" "${ASKS_RERAISE_MIN:-15}" "${ASKS_LOCK_MIN:-60}" "$holder" "${ASKS_MAX_RAISES:-4}" "$(spl_asks_lines "$due")" "$(spl_asks_footer)")" || return 0
  while IFS= read -r id; do spl_asks_mark raise "$id" "$holder"; done < <(jq -r '.[].ask_id' <<<"$due")
  do_log "OK re-raised $n ask(s) to $holder"
}

# The topic the ask belongs to: {"title","readable","channel","ask"}.
# title is the opening line of the topic (what the card shows). readable is
# true only for a channel topic this owner can read, so the reminder can be a
# reply in it. ASKS_TOPIC_CMD replaces the lookup. Otherwise hub-tail on the
# desk: the inner message has no channel, so "the owner can read it" means a
# channel post (to ALL-0) that names this owner. Anything else is readable
# false, with the title when the messages arrived. {} means nothing was learned.
spl_asks_owner_ctx() {  # TOPIC
  local topic="$1" out="" uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  if [[ "$topic" =~ $uuid_re ]]; then
    if [[ -n "${ASKS_TOPIC_CMD:-}" ]]; then
      out="$("$ASKS_TOPIC_CMD" "$topic" 2>/dev/null)" || out=""
    elif [[ -z "${ASKS_HUB_CMD:-}" && "${LANE_MODE:-}" == hub && -n "${SPL_SPOOL:-}" && -n "${LANE_DESK_DIR:-}" ]]; then
      out="$(spl_asks_topic_hub "$topic")" || out=""
    fi
  fi
  if [[ -z "$out" ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
    printf '%s' '{}'
    return 0
  fi
  if ! jq -c '{title: (.title // ""), readable: (.readable // false), channel: (.channel // ""), ask: (.ask // "")}' <<<"$out"; then
    printf '%s' '{}'
  fi
  return 0
}

# hub-tail --json of one topic, through the same desk spool `spool ask` uses.
spl_asks_topic_hub() {  # TOPIC
  local raw
  raw="$(SPOOL_ROOT="$LANE_DESK_DIR/spool" SPOOL_KEYS_DIR="$LANE_DESK_DIR/keys" SPOOL_BOX_ID="$LANE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$LANE_TENANT" \
    timeout "${ASKS_TIMEOUT:-30}" "$SPL_SPOOL" hub-tail --task "$1" --json 2>/dev/null)" || return 0
  [[ -n "$raw" ]] || return 0
  printf '%s\n' "$raw" | spl_asks_topic_read || return 0
}

# NDJSON of v:1 messages on stdin -> the context object. The oldest body's
# first line, whitespace collapsed, 100 characters, is the title (the WUI's
# topic opening). A channel post that names the owner is readable.
spl_asks_topic_read() {
  ASKS_OWNER="${ASKS_OWNER:-}" python3 -c '
import json, os, re, sys
owner = os.environ.get("ASKS_OWNER", "")
rows = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass
if not rows:
    sys.exit(0)
rows.sort(key=lambda m: (str(m.get("ts") or ""), str(m.get("msg_id") or "")))
first = str(rows[0].get("body") or "").split("\n", 1)[0]
flat = " ".join(first.split())
chars = list(flat)
title = flat if len(chars) <= 100 else "".join(chars[:100]) + "..."
channel = any(str(m.get("to") or "") == "ALL-0" for m in rows)
named = False
if owner:
    pat = re.compile(r"(^|[^A-Za-z0-9_-])@" + re.escape(owner) + r"([^A-Za-z0-9_-]|$)")
    for m in rows:
        if str(m.get("from") or "") == owner or str(m.get("to") or "") == owner or pat.search(str(m.get("body") or "")):
            named = True
            break
print(json.dumps({"title": title, "readable": bool(channel and named), "channel": "", "ask": ""}))
'
}

# The ask's own topic when it is a channel topic the owner can read, else a
# fresh topic (the reminder still names the source by its title).
spl_asks_owner_dest() {  # TOPIC READABLE
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  if [[ "$2" == true && "$1" =~ $uuid_re ]]; then
    printf '%s' "$1"
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

# The id line, used when the topic's title could not be read.
spl_asks_owner_words_plain() {  # ROW HOLDER MAXED MAX
  if [[ "$3" == true ]]; then
    jq -r --arg h "$2" --arg x "$4" '"**Dead-lettered ask to the orchestrator (raised \(.raised_n)x, the limit is \($x); \(.age_s / 60 | floor) min old):** \(.kind) from \(.from), topic \(.topic): \(.summary). The acting orchestrator \($h) never closed it; it is no longer re-raised. Ask id \(.ask_id)."' <<<"$1"
  else
    jq -r --arg h "$2" '"**Unanswered ask to the orchestrator (\(.age_s / 60 | floor) min, re-raised \(.raised_n)x):** \(.kind) from \(.from), topic \(.topic): \(.summary). The acting orchestrator \($h) has not acked it. Ask id \(.ask_id)."' <<<"$1"
  fi
}

# Plain words: the topic title, who is waiting, the summary, what to do, and
# the source topic uuid. No ask id. On a channel reply a known owner is
# mentioned so the post reaches them. The title stays the first line.
spl_asks_owner_words() {  # ROW HOLDER MAXED CTX MAX
  local title maxed_json=false
  if [[ "$3" == true ]]; then maxed_json=true; fi
  title="$(jq -r '.title // ""' <<<"$4")" || return 1
  if [[ -z "$title" ]]; then
    spl_asks_owner_words_plain "$1" "$2" "$3" "$5"
    return
  fi
  jq -r --arg x "$5" --arg owner "${ASKS_OWNER:-}" --argjson maxed "$maxed_json" --argjson ctx "$4" '
    def who: (.from // "" | split("@")[0]);
    def mins: ((.age_s // 0) / 60 | floor);
    ($ctx.channel // "") as $ch | ($ctx.ask // "") as $ask | ($ctx.title // "") as $title |
    (if $ch != "" then " (#\($ch))" else "" end) as $where |
    (if $maxed then "Set aside after \(.raised_n // 0) raises (the limit is \($x)): nobody answered (\(mins) min)."
     else "Unanswered for \(mins) min." end) as $state |
    (if ($ctx.readable == true) and ($owner | test("^HUM-[0-9]+$")) then "@\($owner)" else "" end) as $ping |
    [ "Topic: \($title)\($where)", $ping, $state,
      (if who != "" then "Waiting: \(who)." else "" end),
      (if (.summary // "") != "" then "Summary: \(.summary)" else "" end),
      (if $ask != "" then "What to do: \($ask)" else "" end),
      (.topic // "") ] | map(select(length > 0)) | join("\n")' <<<"$1"
}

# The reminder's topic, beside the ask file: the journal mirror rewrites that
# file from the hub and would drop a field only the file held. Line 1 is the
# task the reminder went into; line 2 is "resolved" once the follow-up posted.
spl_asks_told_file() { printf '%s/.owner-told.%s' "$(spool_asks_dir)" "$1"; }

spl_asks_told_save() {  # ID TASK
  local f tmp
  f="$(spl_asks_told_file "$1")" || return 1
  tmp="$f.tmp.$$"
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$f"
}

# Prints the reminder topic. 1 when there is none, or the follow-up is posted.
spl_asks_told_task() {  # ID
  local f task mark
  f="$(spl_asks_told_file "$1")" || return 1
  [[ -s "$f" ]] || return 1
  task="$(sed -n '1p' "$f")"
  mark="$(sed -n '2p' "$f")"
  [[ "$mark" == resolved ]] && return 1
  [[ "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  printf '%s' "$task"
}

spl_asks_told_done() {  # ID
  local f task tmp
  f="$(spl_asks_told_file "$1")" || return 1
  task="$(sed -n '1p' "$f")"
  tmp="$f.tmp.$$"
  printf '%s\nresolved\n' "$task" >"$tmp" && mv -f "$tmp" "$f"
}

spl_asks_resolved_why() {  # ROW
  jq -r '(.reason // "") as $r | .state as $s |
    if $s == "acked" then "the orchestrator acknowledged it"
    elif $s == "dead" then "it was closed because nobody answered"
    elif $r != "" then $r
    elif $s == "declined" then "it was declined"
    else "it was closed" end' <<<"$1"
}

# c2. A reminder already posted, whose ask the loaded book now shows acked,
# closed or dead. The book is what this tick read, so a dead-letter in this
# same tick is answered on the next one, after the reminder has been seen.
spl_asks_resolved() {  # HOLDER
  local holder="$1" dir f id task row state why text
  dir="$(spool_asks_dir)" || return 0
  for f in "$dir"/.owner-told.*; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f")"
    id="${id#.owner-told.}"
    task="$(spl_asks_told_task "$id")" || continue
    row="$(jq -c --arg id "$id" '[.[] | select(.ask_id == $id)][0] // empty' <<<"${ASKS_ROWS:-[]}")" || row=""
    [[ -n "$row" ]] || row="$(spool_ask_journal_get "$id" 2>/dev/null)" || continue
    state="$(jq -r '.state // ""' <<<"$row")" || continue
    case "$state" in acked|done|declined|dead) ;; *) continue ;; esac
    why="$(spl_asks_resolved_why "$row")" || continue
    text="resolved: $why"
    if spl_asks_owner_send "$holder" "$row" "$text" "$task"; then
      spl_asks_told_done "$id" || do_log "WARN ask ${id:0:8}: the resolved reply posted but was not recorded"
      do_log "OK ask ${id:0:8} reminder resolved: $why"
    else
      do_log "WARN the resolved reply for ask ${id:0:8} did not post; retried next tick"
    fi
  done
  return 0
}
# c. Unacked ASKS_OWNER_MIN after it was raised, owner not told yet; and
# d. open and raised ASKS_MAX_RAISES times: told (unless c already did) and
# dead-lettered with the reason.
spl_asks_owner() {
  local holder="$1" rows="$2" row id text maxed told why ctx dest max="${ASKS_MAX_RAISES:-4}"
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    id="$(jq -r '.ask_id' <<<"$row")"
    maxed="$(jq -r --argjson x "$max" '$x > 0 and (.raised_n // 0) >= $x' <<<"$row")"
    told="$(jq -r '.escalated_at // ""' <<<"$row")"
    why="max delivery count $max reached (raised $(jq -r '.raised_n // 0' <<<"$row")x)"
    if [[ -n "$told" ]]; then
      [[ "$maxed" == true ]] && spl_asks_dead "$id" "$holder" "$why; the owner was told at $told"
      continue
    fi
    if [[ -z "${ASKS_OWNER_CMD:-}" && ! "${ASKS_OWNER:-}" =~ ^HUM-[0-9]+$ ]]; then
      if [[ "$maxed" == true ]]; then
        do_log "WARN ask ${id:0:8} reached the delivery limit and no owner leg is configured (ASKS_OWNER / ASKS_OWNER_CMD in lease.conf)"
        spl_asks_dead "$id" "$holder" "$why; no owner leg configured, nobody was told"
        continue
      fi
      [[ -e "$(spool_asks_dir)/.owner-off.$id" ]] && continue
      touch "$(spool_asks_dir)/.owner-off.$id"
      do_log "WARN ask ${id:0:8} is unacked past ${ASKS_OWNER_MIN:-60} min and no owner leg is configured (ASKS_OWNER / ASKS_OWNER_CMD in lease.conf)"
      continue
    fi
    ctx="$(spl_asks_owner_ctx "$(jq -r '.topic // ""' <<<"$row")")"
    text="$(spl_asks_owner_words "$row" "$holder" "$maxed" "$ctx" "$max")" || { do_log "WARN ask ${id:0:8}: the reminder text could not be built"; continue; }
    dest="$(spl_asks_owner_dest "$(jq -r '.topic // ""' <<<"$row")" "$(jq -r '.readable // false' <<<"$ctx")")"
    if spl_asks_owner_send "$holder" "$row" "$text" "$dest"; then
      spl_asks_told_save "$id" "$dest" || do_log "WARN ask ${id:0:8}: the reminder topic was not recorded"
      spl_asks_mark escalate "$id" "$holder"
      do_log "OK ask ${id:0:8} told to the owner"
      [[ "$maxed" == true ]] && spl_asks_dead "$id" "$holder" "$why; the owner was told"
    else
      do_log "WARN the owner leg failed for ask ${id:0:8}; retried next tick"
    fi
  done < <(jq -c --argjson m "$(( ${ASKS_OWNER_MIN:-60} * 60 ))" --argjson x "$max" \
    '.[] | select(.state == "open" and ((.age_s >= $m and ((.escalated_at // "") == "")) or ($x > 0 and (.raised_n // 0) >= $x)))' <<<"$rows")
}

# d. Close an ask as dead with the reason (Kafka: archived).
spl_asks_dead() {  # ID HOLDER REASON
  spl_asks_mark dead "$1" "$2" "$3" &&
    do_log "OK ask ${1:0:8} dead-lettered: $3"
}

spl_asks_owner_send() {  # HOLDER ROW TEXT TASK
  if [[ -n "${ASKS_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    ASK_JSON="$2" ASK_TASK="${4:-}" $ASKS_OWNER_CMD <<<"$3"; return
  fi
  local topic="${4:-}"
  [[ -n "$topic" ]] || topic="$(cat /proc/sys/kernel/random/uuid)"
  ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX" DESK_AGENT="${1%@*}" DESK_TO="$ASKS_OWNER" \
    DESK_TASK="$topic" DESK_KIND=blocker DESK_BODY="$3" DRY_RUN=0 do_spl_desk_reply >/dev/null
}
