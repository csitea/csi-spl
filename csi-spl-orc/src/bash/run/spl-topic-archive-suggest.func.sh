#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_topic_archive_suggest - the daily archive suggestion
# @description (spec 041 section 7, SPL-5520; csitea topic 48d75e5f item 5:
# @description the owner asked to archive or close a finished topic 9 times).
# @description A topic gets ONE archive poll, addressed to its newest human
# @description poster, when all three hold:
# @description   1. the last agent post is a result: kind result, or a body
# @description      that opens with **Done**, **Live**, **Answered**,
# @description      **Answer** or a `## Result` heading,
# @description   2. no open ask names it (do_spl_asks_open: open, acked,
# @description      queued, placing or needs_owner; its full uuid or its first
# @description      8 hex digits as a whole token, as the zombie sweep),
# @description   3. 24 h (ARCHIVE_SUGGEST_QUIET_H) without a post.
# @description The candidates are the hub's 500 newest idle topic heads (GET
# @description /v1/operator/zombie-topics?idle_days=1&order=newest: not
# @description archived, no DM, not prioritised); a topic with no human post
# @description is no owner topic and is skipped. The poll:
# @description   (A) Archive -> do_spl_topic_archive, as the dispatch holder
# @description   (B) Keep    -> no suggestion for that topic for 7 days
# @description Never twice: the ledger $SPOOL_ROOT/dispatch/archive-suggest.tsv
# @description (append only, the last row of a topic wins) holds asked,
# @description archived and keep rows; an asked topic is never polled again,
# @description a kept one is muted ARCHIVE_SUGGEST_MUTE_D days. Each run first
# @description reads the answers of the asked topics (hub-tail: the newest
# @description `Poll: <id>` / `Answer: <key>` of a person), then, once a UTC
# @description day (the stamp archive-suggest.last, written only by DRY_RUN=0),
# @description posts at most ARCHIVE_SUGGEST_MAX new polls. It acts only on the
# @description box of the dispatch lease holder (ARCHIVE_SUGGEST_FORCE=1 skips
# @description the box and the day stamp). DRY_RUN=1 (default) posts and
# @description archives nothing and prints the PLAN lines only. Default off:
# @description its cron (do_spl_topic_archive_suggest_install_cron) runs it dry
# @description until lease.conf says ARCHIVE_SUGGEST_DRY_RUN=0.
# @param ENV (optional) - dev or prd; default the lease's LEASE_ENV, else prd
# @param TENANT_ID (optional) - default the lease's LEASE_TENANT
# @param DESK_AGENT (optional) - the polling and archiving desk agent; default the dispatch lease holder's id
# @param DESK_BOX (optional) - default lease.conf LEASE_DESK_BOX, else this machine's desk box
# @param ARCHIVE_SUGGEST_MAX (optional) - new polls a day, 1..100, default 10
# @param ARCHIVE_SUGGEST_SCAN (optional) - topics whose tail is read a day, 1..500, default 60
# @param ARCHIVE_SUGGEST_QUIET_H (optional) - hours without a post, 1..720, default 24
# @param ARCHIVE_SUGGEST_MUTE_D (optional) - days a Keep mutes a topic, 1..365, default 7
# @param ARCHIVE_SUGGEST_FORCE (optional) - 1 runs on any box and ignores the day stamp
# @param ARCHIVE_SUGGEST_NOW (optional) - the moment judged, ISO UTC (tests)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_topic_archive_suggest
# @example ARCHIVE_SUGGEST_FORCE=1 ARCHIVE_SUGGEST_MAX=3 ./run -a do_spl_topic_archive_suggest
# @example ARCHIVE_SUGGEST_FORCE=1 DRY_RUN=0 ./run -a do_spl_topic_archive_suggest
#------------------------------------------------------------------------------
# Test seams: spl_zombie_hub_list, do_spl_asks_open, spl_archive_suggest_tail,
# do_spl_desk_reply, do_spl_topic_archive and do_spl_desk_cnf are functions a
# test replaces.

declare -F spl_zombie_hub_list >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-zombie-topics.func.sh"

do_spl_topic_archive_suggest() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 holder box
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_archive_suggest_conf || return 1
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  [[ "${ARCHIVE_SUGGEST_FORCE:-0}" == 1 ]] || spl_archive_suggest_gate "$root" "$holder" || return 0
  export ENV="${ENV:-$(spl_owner_digest_lease_conf "$root" LEASE_ENV prd)}"
  export TENANT_ID="${TENANT_ID:-$(spl_owner_digest_lease_conf "$root" LEASE_TENANT "")}"
  export DESK_AGENT="${DESK_AGENT:-${holder%@*}}"
  [[ -n "$TENANT_ID" && -n "$DESK_AGENT" ]] ||
    { do_log "FATAL archive-suggest: no TENANT_ID / DESK_AGENT (LEASE_TENANT in $root/dispatch/lease.conf, the dispatch holder)"; return 1; }
  box="${DESK_BOX:-$(spl_owner_digest_lease_conf "$root" LEASE_DESK_BOX "")}"
  export DESK_BOX="${box:-$(spl_desk_box_default)}"
  do_spl_desk_cnf || return 1
  local hop_to
  if hop_to="$(spl_desk_action_hop_to "$TENANT_ID" "$DESK_BOX")"; then
    spl_desk_action_hop do_spl_topic_archive_suggest "$hop_to" "$TENANT_ID" "$DESK_BOX" "$DESK_AGENT" \
      ARCHIVE_SUGGEST_MAX ARCHIVE_SUGGEST_SCAN ARCHIVE_SUGGEST_QUIET_H ARCHIVE_SUGGEST_MUTE_D \
      ARCHIVE_SUGGEST_FORCE ARCHIVE_SUGGEST_NOW; return $?
  fi
  local work rc=0
  work="$(mktemp -d)" || return 1
  spl_archive_suggest_run "$work" "$dry" "$root" || rc=$?
  rm -rf "$work"
  return "$rc"
}

# spl_archive_suggest_run <work> <dry> <root>: the answers every run, the new
# polls once a UTC day (the stamp, written by DRY_RUN=0 only).
spl_archive_suggest_run() {
  local work="$1" dry="$2" root="$3" today stamp="$3/dispatch/archive-suggest.last" rc=0
  spl_archive_suggest_answers "$work" "$dry" "$root" || rc=$?
  today="$(date -u -d "${ARCHIVE_SUGGEST_NOW:-now}" +%F)" || return 1
  if [[ "${ARCHIVE_SUGGEST_FORCE:-0}" != 1 && "$(cat "$stamp" 2>/dev/null)" == "$today" ]]; then
    echo "archive-suggest: OK the polls of $today were already posted"
  elif spl_archive_suggest_polls "$work" "$dry" "$root"; then
    ((dry)) || printf '%s\n' "$today" >"$stamp" || do_log "WARN archive-suggest: cannot write the stamp $stamp"
  else
    rc=1
  fi
  return "$rc"
}

# spl_archive_suggest_gate <root> <holder>: 0 when this box holds the
# dispatch lease; else one OK line on stderr, rc 1.
spl_archive_suggest_gate() {
  local root="$1" holder="$2" box hbox
  [[ "$holder" =~ ^[A-Za-z][A-Za-z0-9-]*(@[a-z0-9][a-z0-9-]*)?$ ]] ||
    { echo "OK archive-suggest: no dispatch lease holder in $root/dispatch/lease: nothing" >&2; return 1; }
  box="$(spl_owner_digest_box "$root")"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  [[ "$hbox" == "$box" ]] ||
    { echo "OK archive-suggest: the dispatch holder $holder is not on this box ($box); its box suggests" >&2; return 1; }
}

# spl_archive_suggest_conf: the ARCHIVE_SUGGEST_* numbers, defaults filled,
# a value out of range refused.
spl_archive_suggest_conf() {
  local v n lo hi
  ARCHIVE_SUGGEST_MAX="${ARCHIVE_SUGGEST_MAX:-10}" ARCHIVE_SUGGEST_SCAN="${ARCHIVE_SUGGEST_SCAN:-60}"
  ARCHIVE_SUGGEST_QUIET_H="${ARCHIVE_SUGGEST_QUIET_H:-24}" ARCHIVE_SUGGEST_MUTE_D="${ARCHIVE_SUGGEST_MUTE_D:-7}"
  for v in MAX:1:100 SCAN:1:500 QUIET_H:1:720 MUTE_D:1:365; do
    IFS=: read -r n lo hi <<<"$v"; n="ARCHIVE_SUGGEST_$n"
    [[ "${!n}" =~ ^[1-9][0-9]{0,3}$ ]] && ((${!n} >= lo && ${!n} <= hi)) ||
      { do_log "FATAL $n must be $lo..$hi, got: '${!n}'"; return 1; }
  done
  [[ -z "${ARCHIVE_SUGGEST_NOW:-}" ]] || date -u -d "$ARCHIVE_SUGGEST_NOW" >/dev/null 2>&1 ||
    { do_log "FATAL ARCHIVE_SUGGEST_NOW is not a date: '$ARCHIVE_SUGGEST_NOW'"; return 1; }
}

# spl_archive_suggest_answers <work> <dry> <root>: for each asked topic of
# the ledger, the newest person answer to its poll: A archives, B keeps.
spl_archive_suggest_answers() {
  local work="$1" dry="$2" led="$3/dispatch/archive-suggest.tsv" topic poll key now
  now="$(date -u -d "${ARCHIVE_SUGGEST_NOW:-now}" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  while IFS=$'\t' read -r topic poll; do
    spl_archive_suggest_tail "$topic" >"$work/answer.ndjson" 2>/dev/null ||
      { echo "archive-suggest: WARN topic $topic cannot be read: its answer waits"; continue; }
    key="$(spl_archive_suggest_answer_of "$poll" <"$work/answer.ndjson")"
    case "$key" in
      A) if ((dry)); then echo "archive-suggest: PLAN archive $topic (answer A to poll $poll)"; continue; fi
         if TOPIC="$topic" MODE=archive DRY_RUN=0 do_spl_topic_archive >"$work/archive.out" 2>&1; then
           printf '%s\tarchived\t%s\t%s\t%s\n' "$topic" "$now" "$poll" "$TENANT_ID" >>"$led"
           echo "archive-suggest: archived $topic (answer A to poll $poll)"
         else
           echo "archive-suggest: WARN not archived $topic: $(tail -1 "$work/archive.out")"
         fi ;;
      B) if ((dry)); then echo "archive-suggest: PLAN keep $topic for $ARCHIVE_SUGGEST_MUTE_D d (answer B to poll $poll)"; continue; fi
         printf '%s\tkeep\t%s\t%s\t%s\n' "$topic" "$now" "$poll" "$TENANT_ID" >>"$led"
         echo "archive-suggest: keep $topic, no suggestion for $ARCHIVE_SUGGEST_MUTE_D d (answer B to poll $poll)" ;;
    esac
  done < <(spl_archive_suggest_ledger "$led" | awk -F'\t' '$2 == "asked" { print $1 "\t" $4 }')
  return 0
}

# spl_archive_suggest_ledger <file>: the last row of each topic.
spl_archive_suggest_ledger() {
  [[ -r "$1" ]] || return 0
  awk -F'\t' 'NF >= 3 { last[$1] = $0; if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } }
    END { for (i = 1; i <= n; i++) print last[order[i]] }' "$1"
}

# spl_archive_suggest_polls <work> <dry> <root>: read, judge, post.
spl_archive_suggest_polls() {
  local work="$1" dry="$2" led="$3/dispatch/archive-suggest.tsv" topic human why poll n=0 bad=0 now
  spl_archive_suggest_read "$work" || return 1
  spl_archive_suggest_ledger "$led" >"$work/ledger.tsv"
  spl_archive_suggest_pick "$work" >"$work/pick.tsv" || { do_log "FATAL archive-suggest: the candidates could not be judged"; return 1; }
  mkdir -p "$work/tails"
  while IFS=$'\t' read -r _ topic; do
    spl_archive_suggest_tail "$topic" >"$work/tails/$topic.ndjson" 2>/dev/null || rm -f "$work/tails/$topic.ndjson"
  done < <(grep '^scan' "$work/pick.tsv")
  spl_archive_suggest_judge "$work" >"$work/verdict.tsv" || { do_log "FATAL archive-suggest: the topics could not be judged"; return 1; }
  grep -h '^keep' "$work/pick.tsv" "$work/verdict.tsv" | sed 's/^/archive-suggest: /'
  now="$(date -u -d "${ARCHIVE_SUGGEST_NOW:-now}" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  while IFS=$'\t' read -r _ topic human why; do
    if ((dry)); then echo "archive-suggest: PLAN poll $topic to $human ($why)"; n=$((n + 1)); continue; fi
    if poll="$(spl_archive_suggest_post "$topic" "$human" "$work")"; then
      printf '%s\tasked\t%s\t%s\t%s\n' "$topic" "$now" "${poll:--}" "$TENANT_ID" >>"$led"
      n=$((n + 1)); echo "archive-suggest: polled $topic to $human (poll ${poll:-?})"
    else
      bad=$((bad + 1)); echo "archive-suggest: WARN no poll in $topic: $(tail -1 "$work/post.out")"
    fi
  done < <(grep '^poll' "$work/verdict.tsv")
  if ((dry)); then echo "archive-suggest: OK $(grep -c . "$work/cands.ids") idle topic(s) read; would post $n poll(s) (DRY_RUN)"
  else echo "archive-suggest: OK $(grep -c . "$work/cands.ids") idle topic(s) read; posted $n poll(s), failed $bad"; fi
  ((bad == 0))
}

# spl_archive_suggest_read <work>: cands.json (the hub's 500 newest idle
# heads, whole days rounded up: order=newest, a backlog of over 5000 older
# heads hid them) and asks.json; rc 1 (and a FATAL line) when one cannot be
# read.
spl_archive_suggest_read() {
  local w="$1" out
  out="$(ZOMBIE_IDLE_DAYS=$(((ARCHIVE_SUGGEST_QUIET_H + 23) / 24)) ZOMBIE_LIST_LIMIT=500 ZOMBIE_ORDER=newest spl_zombie_hub_list)" ||
    { do_log "FATAL archive-suggest: the hub's idle topic list was not read"; return 1; }
  jq -e '.topics | type == "array"' <<<"$out" >/dev/null 2>&1 || { do_log "FATAL archive-suggest: the hub's answer has no topics list"; return 1; }
  printf '%s\n' "$out" >"$w/cands.json"
  jq -r '.topics[].task_id' "$w/cands.json" >"$w/cands.ids"
  out="$(ASKS_ALL=1 ASKS_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_asks_open 2>/dev/null | grep '^{' | tail -1)"
  jq -e '(.asks | type == "array") and (.hub == "ok" or .hub == "partial")' <<<"$out" >/dev/null 2>&1 ||
    { do_log "FATAL archive-suggest: the ask book was not read from the hub (do_spl_asks_open)"; return 1; }
  printf '%s\n' "$out" >"$w/asks.json"
}

# spl_archive_suggest_pick <work>: newest first, `scan<TAB><uuid>` for at most
# ARCHIVE_SUGGEST_SCAN topics, `keep<TAB><uuid><TAB><reason>` for the rest:
# condition 2 (ask <id>), condition 3 (quiet), the ledger (polled, muted,
# archived) and the scan cap.
spl_archive_suggest_pick() {
  python3 - "$1" "${ARCHIVE_SUGGEST_NOW:-}" "$ARCHIVE_SUGGEST_QUIET_H" "$ARCHIVE_SUGGEST_MUTE_D" "$ARCHIVE_SUGGEST_SCAN" <<'PY'
import datetime as dt, json, re, sys
w, now, quiet_h, mute_d, scan = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
def when(s):
    return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00")).astimezone(dt.timezone.utc)
now = when(now) if now else dt.datetime.now(dt.timezone.utc)
cands = sorted(json.load(open(f"{w}/cands.json")).get("topics") or [], key=lambda t: t.get("last_at") or "", reverse=True)
live = {"open", "acked", "queued", "placing", "needs_owner"}
asks = [a for a in json.load(open(f"{w}/asks.json")).get("asks") or [] if a.get("state") in live]
ledger = {}
for line in open(f"{w}/ledger.tsv"):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 3:
        ledger[f[0]] = (f[1], f[2])
def names(text, u):
    text = (text or "").lower()
    return u in text or bool(re.search(r"(?<![0-9a-f])" + u[:8] + r"(?![0-9a-f])", text))
def ask_on(u):
    for a in asks:
        if names(a.get("topic"), u) or names(a.get("summary"), u):
            return f"ask {a.get('ask_id', '?')}"
def quiet(t):
    try:
        last = when(t.get("last_at"))
    except (TypeError, ValueError):
        return "quiet unknown"
    if now - last < dt.timedelta(hours=quiet_h):
        return f"quiet {last:%Y-%m-%dT%H:%M:%SZ}, under {quiet_h} h"
def book(u):
    st, at = ledger.get(u, ("", ""))
    if st == "asked":
        return f"polled {at}"
    if st == "archived":
        return f"archived {at}"
    if st == "keep" and now - when(at) < dt.timedelta(days=mute_d):
        return f"muted, kept {at}"
n = 0
for t in cands:
    u = (t.get("task_id") or "").lower()
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", u):
        continue
    why = book(u) or ask_on(u) or quiet(t)
    if why is None and n >= scan:
        why = "scan cap"
    if why:
        print(f"keep\t{u}\t{why}")
    else:
        n += 1
        print(f"scan\t{u}")
PY
}

# spl_archive_suggest_judge <work>: for each scanned topic (newest first),
# `poll<TAB><uuid><TAB><human><TAB><why>` for at most ARCHIVE_SUGGEST_MAX,
# else `keep<TAB><uuid><TAB><reason>`: condition 1 (the last agent post is a
# result), an owner topic (a person posted), a readable tail, the poll cap.
spl_archive_suggest_judge() {
  python3 - "$1" "$ARCHIVE_SUGGEST_MAX" <<'PY'
import json, os, re, sys
w, cap = sys.argv[1], int(sys.argv[2])
people = ("HUM-", "RSP-", "GST-")
RESULT = re.compile(r"\s*(\*\*(Done|Live|Answered|Answer)\b|#{1,3}\s+Result\b)")
def result(m):
    return m.get("kind") == "result" or bool(RESULT.match(str(m.get("body", ""))))
n = 0
for line in open(f"{w}/pick.tsv"):
    f = line.rstrip("\n").split("\t")
    if f[0] != "scan":
        continue
    u, path = f[1], f"{w}/tails/{f[1]}.ndjson"
    if not os.path.exists(path):
        print(f"keep\t{u}\ttail unreadable")
        continue
    msgs = []
    for raw in open(path, encoding="utf-8", errors="replace"):
        try:
            m = json.loads(raw)
        except ValueError:
            continue
        if isinstance(m, dict):
            msgs.append(m)
    msgs.sort(key=lambda m: str(m.get("ts", "")))
    humans = [m for m in msgs if str(m.get("from", "")).startswith(people)]
    agents = [m for m in msgs if not str(m.get("from", "")).startswith(people)]
    if not humans:
        why = "no human post"
    elif not agents or not result(agents[-1]):
        why = "last agent post is no result"
    elif n >= cap:
        why = "poll cap"
    else:
        n += 1
        who = str(humans[-1].get("from", "")).split("@")[0]
        print(f"poll\t{u}\t{who}\tresult {agents[-1].get('msg_id', '?')}")
        continue
    print(f"keep\t{u}\t{why}")
PY
}

# spl_archive_suggest_answer_of <poll id>, the topic's NDJSON on stdin: the
# key (A or B) of the newest person reply `Poll: <id>` + `Answer: <key>`; a
# `-` poll id (its id was not read back) takes our marker poll's id.
spl_archive_suggest_answer_of() {
  python3 -c '
import json, re, sys
poll = sys.argv[1]
msgs = []
for raw in sys.stdin:
    try:
        m = json.loads(raw)
    except ValueError:
        continue
    if isinstance(m, dict):
        msgs.append(m)
msgs.sort(key=lambda m: str(m.get("ts", "")))
if poll in ("", "-"):
    ours = [m for m in msgs if str(m.get("body", "")).startswith("**Archive suggestion**") and "```poll" in str(m.get("body", ""))]
    poll = ours[-1].get("msg_id", "") if ours else ""
key = ""
for m in msgs:
    lines = str(m.get("body", "")).split("\n")
    if not poll or not str(m.get("from", "")).startswith(("HUM-", "RSP-", "GST-")) or lines[0].strip() != "Poll: " + poll:
        continue
    a = [re.match(r"^Answer:\s+([A-Za-z0-9]+)", x) for x in lines[1:]]
    a = [x.group(1) for x in a if x]
    if a:
        key = a[0]
print(key if key in ("A", "B") else "")' "$1"
}

# spl_archive_suggest_tail <topic>: the topic's NDJSON from the desk's
# hub-tail (the holder's desk box reads it).
spl_archive_suggest_tail() {
  local d
  d="$(spl_desk_dir "$TENANT_ID" "$DESK_BOX")" || return 1
  [[ -n "${SPL_SPOOL:-}" ]] || spl_host_spool >/dev/null || return 1
  spl_desk_spool "$d" "$DESK_BOX" "$TENANT_ID" "$SPL_HUB_URL" -- hub-tail --task "$1" --json 2>/dev/null
}

# spl_archive_suggest_post <topic> <human> <work>: the poll, posted by the
# desk agent into the topic and addressed to <human>; prints its msg id.
spl_archive_suggest_post() {
  local body
  body="**Archive suggestion**: the last agent post here is a result, no ask is open on this topic and nobody has posted for ${ARCHIVE_SUGGEST_QUIET_H} h.

\`\`\`poll
Archive this topic?
(A) Archive
(B) Keep (no suggestion for ${ARCHIVE_SUGGEST_MUTE_D} days)
\`\`\`"
  ( DESK_TASK="$1" DESK_TO="$2" DESK_KIND=note DESK_BODY="$body" DESK_BODY_FILE='' DESK_ACK=0 DRY_RUN=0 \
    RUN_STDOUT_IS_DATA=1 do_spl_desk_reply ) >"$3/post.out" 2>&1 || return 1
  grep '^{' "$3/post.out" | tail -1 | jq -r '.send.msg_id // empty' 2>/dev/null
  return 0
}
