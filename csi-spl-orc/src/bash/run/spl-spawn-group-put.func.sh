#!/bin/bash
# @description Put a work group in line (SPL-2370; owner HUM-10, t1 d4c0c0a8
# @description msgs 09958ea6, e8b2b36a: "When there is one, there will always
# @description be many"). A group is keyed by its epic and holds ordered rows,
# @description each a class, a placement <vendor>:<slug> (its brief <slug>.md
# @description in the briefs dir, as do_spl_spawn_enqueue) and the issue key
# @description the lane closes, plus a width N: the rows that run at once.
# @description The spawn placer (do_spl_spawn_place, every minute on the orch
# @description box) keeps N rows in flight: a row is fed into the ONE spawn
# @description queue (spl_spawn_q_enqueue, the path a single enqueue takes)
# @description whenever fewer than N of the group's rows are open, queued,
# @description placing or running, so the bands, the bypass and ONE AT A TIME
# @description apply to it like to any row. A single ask is the case of one
# @description row at width 1. A row's state is read, never kept by hand:
# @description   waiting - no ask on the hub yet
# @description   queued  - its ask is open, queued or placing (in flight)
# @description   running - its ask is done "placed: <ID>@<box>" and that lane
# @description             is live (or was placed under SPAWN_GROUP_GRACE_MIN)
# @description   done    - its issue is done (the lane landed)
# @description   closed  - its issue is diss, or its lane is gone unlanded
# @description   failed  - its ask was declined or dead
# @description Each row's ask id is derived from fleet, epic and slug, so a
# @description row is put on the hub at most once: no tick, re-put or second
# @description machine can place it twice. done, closed and failed are kept in
# @description the group file (the hub prunes closed asks after a week). The
# @description group file is <spool root>/dispatch/groups/<EPIC>.json on the
# @description box that holds the briefs (the orch box); a re-put keeps the
# @description rows' recorded ends and may change the width or add rows.
# @description The list: do_spl_spawn_group_list. The backstop:
# @description do_spl_epic_stall_check reports a group with waiting rows and
# @description fewer than N in flight for EPIC_STALL_IDLE_MIN.
# @param GROUP_EPIC (required) - the group's key, its epic, e.g. SPL-2151
# @param GROUP_WIDTH (required) - N, the rows in flight at once, 1..9
# @param GROUP_ROWS (required) - a file, one row per line in order: `<class> <vendor>:<slug> <ISSUE-KEY> [urgent|<owner msg uuid>]` (class ci, refactor, bug or feature; urgent = SPAWN_URGENT, a uuid = SPAWN_BYPASS); blank and # lines skipped
# @param GROUP_TOPIC (optional) - the task the rows' notes ride (an owner topic uuid becomes dispatch-<topic8>); default spawn-queue
# @param ASK_BY (optional) - who puts it, <ID>@<box>: the rows' sender; default this machine's orchestrator
# @param SPAWN_GROUP_DIR (optional) - the group files, default <spool root>/dispatch/groups
# @param SPAWN_GROUP_POLL_MIN (optional) - minutes between two reads of the lane map and the issues per group, default 2
# @param SPAWN_GROUP_GRACE_MIN (optional) - minutes a placed lane counts as running before the lane map must show it, default 15
# @param SPAWN_PLACE_BRIEF_DIR (optional) - as do_spl_spawn_place
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example GROUP_EPIC=SPL-2151 GROUP_WIDTH=2 GROUP_ROWS=/tmp/spl-2151.rows ./run -a do_spl_spawn_group_put

SPL_SPAWN_GROUP_RUN_DIR="$(dirname "${BASH_SOURCE[0]}")"

# The lane map and issue readers live in the stall check.
spl_spawn_group_need_stall() {
  declare -F spl_epic_stall_lanes >/dev/null || source "$SPL_SPAWN_GROUP_RUN_DIR/spl-epic-stall-check.func.sh"
}

do_spl_spawn_group_put() {
  local epic="${GROUP_EPIC:-}" width="${GROUP_WIDTH:-}" topic="${GROUP_TOPIC:-}" by rows f old holder n cls place key
  [[ "$epic" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { do_log "FATAL GROUP_EPIC must be the epic's key, e.g. SPL-2151, got '$epic'"; return 1; }
  [[ "$width" =~ ^[1-9]$ ]] || { do_log "FATAL GROUP_WIDTH must be 1..9, got '$width'"; return 1; }
  [[ -r "${GROUP_ROWS:-}" ]] || { do_log "FATAL GROUP_ROWS must be a readable rows file, got '${GROUP_ROWS:-}'"; return 1; }
  [[ "$topic" =~ ^[A-Za-z0-9._-]{0,64}$ ]] || { do_log "FATAL GROUP_TOPIC must be a task id, got '$topic'"; return 1; }
  spl_spawn_q_init || return 1
  by="$(spl_asks_by)" || return 1
  rows="$(spl_spawn_group_parse "$GROUP_ROWS" "$epic")" || return 1
  f="$(spl_spawn_group_dir)/$epic.json"
  mkdir -p "${f%/*}" || { do_log "FATAL cannot make ${f%/*}"; return 1; }
  old="$(jq -c '.' "$f" 2>/dev/null)" || old=""
  [[ -n "$old" ]] || old='{"rows": []}'
  jq -c -n --arg e "$epic" --argjson w "$width" --arg f "$LANE_FLEET" --arg by "$by" --arg t "$topic" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson rows "$rows" --argjson old "$old" '
    ($old.rows | map({key: .slug, value: .}) | from_entries) as $o
    | {epic: $e, width: $w, fleet: $f, by: $by, topic: $t, created_at: ($old.created_at // $at), put_at: $at,
       rows: [$rows[] | . + {end: ($o[.slug].end // ""), agent: ($o[.slug].agent // "")}]}' >"$f.$$" &&
    mv -f "$f.$$" "$f" || { rm -f "$f.$$"; do_log "FATAL could not write $f"; return 1; }
  while IFS=$'\t' read -r n cls place key; do
    [[ -n "$(spl_spawn_place_brief "${place#*:}")" ]] ||
      do_log "WARN row $n ($key): no brief ${place#*:}.md under ${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}: the placer hands it to the orchestrator"
  done < <(jq -r '.[] | [.seq, .class, .place, .issue] | @tsv' <<<"$rows")
  holder="$(spl_asks_holder)"
  [[ -z "$holder" || "${holder##*@}" == "$ASKS_BOX" ]] ||
    do_log "WARN the orch role is held on ${holder##*@} ($holder): its placer feeds groups from ITS $(spl_spawn_group_dir); put the group (and the briefs) there too"
  do_log "OK work group $epic: $(jq length <<<"$rows") row(s), width $width, in $f; the placer keeps $width in flight (list: GROUP_EPIC=$epic ./run -a do_spl_spawn_group_list)"
}

spl_spawn_group_dir() { printf '%s' "${SPAWN_GROUP_DIR:-$SPOOL_ROOT/dispatch/groups}"; }

# The rows file as a JSON array [{seq, class, place, slug, issue, urgent,
# bypass, ask_id}], or FATAL and exit 1 on the first bad line.
spl_spawn_group_parse() {  # FILE EPIC
  local line cls place key extra more n=0 ln=0 acc='[]' urgent bypass
  while IFS= read -r line || [[ -n "$line" ]]; do
    ln=$((ln + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r cls place key extra more <<<"$line"
    [[ "$cls" =~ ^(ci|refactor|bug|feature)$ ]] || { do_log "FATAL GROUP_ROWS line $ln: class must be ci, refactor, bug or feature, got '$cls'" >&2; return 1; }
    [[ "$place" =~ ^[a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63}$ ]] || { do_log "FATAL GROUP_ROWS line $ln: placement must be <vendor>:<slug> (lowercase), got '$place'" >&2; return 1; }
    [[ "$key" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { do_log "FATAL GROUP_ROWS line $ln: the issue key must look like SPL-17, got '$key'" >&2; return 1; }
    [[ -z "$more" ]] || { do_log "FATAL GROUP_ROWS line $ln: more than 4 fields" >&2; return 1; }
    urgent=0 bypass=""
    if [[ "$extra" == urgent ]]; then urgent=1
    elif [[ "$extra" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then bypass="$extra"
    elif [[ -n "$extra" ]]; then do_log "FATAL GROUP_ROWS line $ln: the 4th field is urgent or the owner's msg uuid, got '$extra'" >&2; return 1
    fi
    [[ $urgent == 0 || "$cls" == bug ]] || { do_log "FATAL GROUP_ROWS line $ln: urgent goes with class bug only" >&2; return 1; }
    [[ -z "$bypass" || "$cls" == feature ]] || { do_log "FATAL GROUP_ROWS line $ln: a bypass goes with class feature only" >&2; return 1; }
    jq -e --arg s "${place#*:}" 'any(.[]; .slug == $s)' >/dev/null <<<"$acc" &&
      { do_log "FATAL GROUP_ROWS line $ln: slug ${place#*:} is already a row of this group" >&2; return 1; }
    n=$((n + 1))
    acc="$(jq -c --argjson n "$n" --arg c "$cls" --arg p "$place" --arg k "$key" --argjson u "$urgent" --arg b "$bypass" \
      --arg id "$(spl_spawn_group_ask_id "$LANE_FLEET" "$2" "${place#*:}")" \
      '. + [{seq: $n, class: $c, place: $p, slug: ($p | sub("^[^:]*:"; "")), issue: $k, urgent: $u, bypass: $b, ask_id: $id}]' <<<"$acc")"
  done <"$1"
  (( n > 0 )) || { do_log "FATAL GROUP_ROWS $1 holds no row" >&2; return 1; }
  printf '%s' "$acc"
}

# The row's ask id: a lowercase UUID (version 5 form) derived from fleet,
# epic and slug, the same on every machine and every tick.
spl_spawn_group_ask_id() {  # FLEET EPIC SLUG
  local h
  h="$(printf 'spawn-group:%s:%s:%s' "$1" "$2" "$3" | sha256sum | cut -c1-32)"
  printf '%s-%s-5%s-%x%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$(( (16#${h:16:1} & 3) | 8 ))" "${h:17:3}" "${h:20:12}"
}

# The group with each row's state read from the hub's asks (all states), the
# issues of its epic and the live lanes; ISSUES or LANES "null" = not read
# (a placed row then counts as running). Adds .counts and .free. The hub's
# lists go to jq as files, never argv: one argument holds at most 128 KiB
# (MAX_ARG_STRLEN), and the real asks list is larger (SPL-2428).
spl_spawn_group_state() {  # GROUP ASKS ISSUES LANES
  jq -c --slurpfile asks <(printf '%s' "$2") --slurpfile issues <(printf '%s' "$3") --slurpfile lanes <(printf '%s' "$4") \
    --argjson now "${SPAWN_GROUP_NOW:-$(date -u +%s)}" --argjson grace "$(( ${SPAWN_GROUP_GRACE_MIN:-15} * 60 ))" '
    def secs: if . == null or . == "" then null else (sub("\\.[0-9]+"; "") | fromdateiso8601) end;
    ($asks[0] // []) as $asks | $issues[0] as $issues | $lanes[0] as $lanes
    | ($asks | map({key: .ask_id, value: .}) | from_entries) as $a
    | (if $issues == null then null else ($issues | map({key: .key, value: .status}) | from_entries) end) as $is
    | (if $lanes == null then null else [$lanes[] | "\(.id)@\(.box)"] end) as $live
    | .rows |= map(. as $r | ($a[$r.ask_id] // null) as $k | (if $is == null then null else $is[$r.issue] end) as $st
        | (if (($k.reason // "") | startswith("placed: ")) then {agent: ($k.reason | sub("^placed: "; ""))} else {} end) as $p
        | (if ($r.end // "") != "" then {state: $r.end}
           elif $st == "done" then $p + {state: "done", why: "issue \($r.issue) is done"}
           elif $st == "diss" then $p + {state: "closed", why: "issue \($r.issue) is diss"}
           elif $k == null then {state: "waiting"}
           elif $k.state == "open" then {state: "open"}
           elif $k.state == "queued" then {state: "queued", why: "position \($k.position // "?") of \($k.queue_len // "?")"}
           elif $k.state == "acked" then {state: "placing"}
           elif $k.state == "done" and (($k.reason // "") | startswith("placed: ")) then
             ($k.reason | sub("^placed: "; "")) as $ag
             | if $live != null and ($live | index($ag)) == null and ($now - ($k.updated_at | secs // $now)) >= $grace
               then {state: "closed", agent: $ag, why: "lane \($ag) is gone, its issue not done"}
               else {state: "running", agent: $ag} end
           else {state: "failed", why: "ask \($k.state): \($k.reason // "")"} end) as $s
        | . + {state: $s.state, agent: ($s.agent // $r.agent // ""), why: ($s.why // ""), ask_state: ($k.state // "")})
    | .counts = (reduce .rows[] as $r ({waiting: 0, open: 0, queued: 0, placing: 0, running: 0, done: 0, closed: 0, failed: 0};
        .[$r.state] += 1))
    | .inflight = (.counts.open + .counts.queued + .counts.placing + .counts.running)
    | .free = ([.width - .inflight, 0] | max)' <<<"$1"
}

# The live lanes of the fleet ([{id, box, text}], spl_epic_stall_lanes), read
# once per tick; "null" when the lane map does not answer.
spl_spawn_group_lanes() {
  if [[ -z "${SPAWN_GROUP_LANES:-}" ]]; then
    spl_spawn_group_need_stall
    SPAWN_GROUP_LANES="$(spl_epic_stall_lanes 2>/dev/null)" || SPAWN_GROUP_LANES=""
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$SPAWN_GROUP_LANES" || SPAWN_GROUP_LANES=null
  fi
  printf '%s' "$SPAWN_GROUP_LANES"
}

# The issues of EPIC as a JSON array, or "null" when they cannot be read.
spl_spawn_group_issues() {  # EPIC
  local out
  spl_spawn_group_need_stall
  out="$(EPIC_KEY="$1" spl_epic_stall_list issues 2>/dev/null)" &&
    jq -e -c '.result.issues | if type == "array" then . else error("no issues") end' 2>/dev/null <<<"$out" || printf 'null'
}

# The group's full state (issues and lanes read), or the hub-only one.
spl_spawn_group_read() {  # GROUP ASKS FULL(0|1)
  if [[ "$3" == 1 ]]; then
    spl_spawn_group_state "$1" "$2" "$(spl_spawn_group_issues "$(jq -r .epic <<<"$1")")" "$(spl_spawn_group_lanes)"
  else
    spl_spawn_group_state "$1" "$2" null null
  fi
}

# The placer's step 0b: every group gets its free slots fed into the queue.
# Runs under the placer's lock on the orch holder's machine.
spl_spawn_group_feed() {  # HOLDER
  local dir f asks
  dir="$(spl_spawn_group_dir)"
  compgen -G "$dir/*.json" >/dev/null || return 0
  asks="$(spl_asks_hub_list)" || { do_log "WARN the hub did not answer: no work group fed this tick"; return 0; }
  SPAWN_GROUP_LANES=""
  for f in "$dir"/*.json; do
    spl_spawn_group_tick "$1" "$f" "$asks" || do_log "WARN work group ${f##*/}: not fed this tick"
  done
  return 0
}

# One group: read its state (the lane map and issues at most once per
# SPAWN_GROUP_POLL_MIN, only while a row has not ended), keep its ends, take the
# ask of an ended row out of the queue, queue an open row again and feed
# the next waiting rows into the free slots.
spl_spawn_group_tick() {  # HOLDER FILE ASKS
  local g st epic poll full=0 id n=0
  g="$(jq -c 'select(.epic and .width and (.rows | type) == "array")' "$2" 2>/dev/null)"
  [[ -n "$g" ]] || { do_log "WARN ${2##*/} is not a work group file: skipped"; return 1; }
  epic="$(jq -r .epic <<<"$g")"
  st="$(spl_spawn_group_read "$g" "$3" 0)" || return 1
  (( $(jq '.counts.waiting + .inflight' <<<"$st") > 0 )) || return 0
  poll="${2%.json}.polled"
  if (( $(date +%s) - $(stat -c %Y "$poll" 2>/dev/null || echo 0) >= ${SPAWN_GROUP_POLL_MIN:-2} * 60 )); then
    full=1; touch "$poll"
    st="$(spl_spawn_group_read "$g" "$3" 1)" || return 1
  fi
  spl_spawn_group_keep_ends "$2" "$st"
  while IFS=$'\t' read -r id why; do
    spl_spawn_q_op decline "$id" "$1" "work group $epic: $why" >/dev/null &&
      do_log "INFO work group $epic: ask ${id:0:8} taken out of the queue ($why)"
  done < <(jq -r '.rows[] | select((.state == "done" or .state == "closed") and (.ask_state == "open" or .ask_state == "queued")) | [.ask_id, .why] | @tsv' <<<"$st")
  while IFS= read -r id; do
    spl_spawn_group_enqueue "$1" "$st" "$id" >/dev/null && do_log "INFO work group $epic: open ask ${id:0:8} queued again"
  done < <(jq -r '.rows[] | select(.state == "open") | .ask_id' <<<"$st")
  while IFS= read -r id; do
    spl_spawn_group_put_ask "$1" "$st" "$id" && spl_spawn_group_enqueue "$1" "$st" "$id" >/dev/null && n=$((n + 1))
  done < <(jq -r '.free as $f | [.rows[] | select(.state == "waiting")][0:$f][] | .ask_id' <<<"$st")
  (( n > 0 )) && do_log "OK work group $epic: $n row(s) queued, $(jq -r --argjson n "$n" '"\(.inflight + $n) of width \(.width) in flight, \(.counts.waiting - $n) waiting"' <<<"$st")$([[ $full == 1 ]] || echo " (lanes not re-read this tick)")"
  return 0
}

# Record done / closed / failed (and the agent) in the group FILE.
spl_spawn_group_keep_ends() {  # FILE STATE
  local ends
  ends="$(jq -c '[.rows[] | select((.end // "") == "" and (.state == "done" or .state == "closed" or .state == "failed")) | {slug, state, agent}]' <<<"$2")"
  [[ "$ends" != "[]" ]] || return 0
  jq -c --argjson e "$ends" '($e | map({key: .slug, value: .}) | from_entries) as $m
    | .rows |= map(if $m[.slug] then . + {end: $m[.slug].state, agent: $m[.slug].agent, ended_at: (now | todate)} else . end)' "$1" >"$1.$$" &&
    mv -f "$1.$$" "$1" || rm -f "$1.$$"
  do_log "INFO work group $(jq -r .epic <<<"$2"): $(jq -r 'map("\(.slug) \(.state)") | join(", ")' <<<"$ends")"
}

# Put the row's ask on the hub (idempotent on its derived id).
spl_spawn_group_put_ask() {  # HOLDER STATE ASK_ID
  local r out
  r="$(jq -c --arg i "$3" '. as $g | .rows[] | select(.ask_id == $i) | . + {epic: $g.epic, by: $g.by, topic: $g.topic, n: ($g.rows | length)}' <<<"$2")"
  out="$(spl_asks_hub put --fleet "$LANE_FLEET" --id "$3" --kind task --role orch --from "$(jq -r '.by // ""' <<<"$r")" \
    --topic "$(spl_spawn_q_task "$(jq -r '.topic // ""' <<<"$r")")" \
    --summary "$(jq -r '"SPAWN work group \(.epic) row \(.seq)/\(.n): \(.issue) \(.slug)"' <<<"$r")" 2>&1)" ||
    { do_log "WARN the hub did not take the ask of work group row $(jq -r '"\(.epic) \(.seq)"' <<<"$r"): $(tail -1 <<<"$out" | cut -c1-200)"; return 1; }
}

# The row into the one spawn queue (spl_spawn_q_enqueue).
spl_spawn_group_enqueue() {  # HOLDER STATE ASK_ID
  local r
  r="$(jq -c --arg i "$3" '.rows[] | select(.ask_id == $i)' <<<"$2")"
  spl_spawn_q_enqueue "$3" "$1" "$(jq -r .place <<<"$r")" "$(jq -r .class <<<"$r")" "$(jq -r '.urgent // 0' <<<"$r")" "$(jq -r '.bypass // ""' <<<"$r")"
}

# The backstop (do_spl_epic_stall_check): a group with waiting rows and fewer
# than its width in flight, continuously for EPIC_STALL_IDLE_MIN, is STALLED
# (the placer did not feed it: its cron, the hub or a brief). One blocker per
# group per EPIC_STALL_REPEAT_H to TO, on the group's task; the first time a
# group was seen short is kept in <spool root>/dispatch/group-stall.state.
# LANES_FILE is the stall check's live lanes ([{id, box, text}]).
spl_spawn_group_stall() {  # LANES_FILE FROM TO
  local dir f g st asks key now first short="$SPOOL_ROOT/dispatch/group-stall.state" sent="$SPOOL_ROOT/dispatch/epic-stall.state" last
  dir="$(spl_spawn_group_dir)"
  compgen -G "$dir/*.json" >/dev/null || return 0
  asks="$(spl_asks_hub_list)" || { do_log "WARN the hub did not answer: no work group stall check this tick"; return 0; }
  now="${EPIC_STALL_NOW:-$(date -u +%s)}"
  for f in "$dir"/*.json; do
    g="$(jq -c 'select(.epic and .width and (.rows | type) == "array")' "$f" 2>/dev/null)"
    [[ -n "$g" ]] || continue
    key="$(jq -r .epic <<<"$g")"
    st="$(SPAWN_GROUP_NOW="$now" spl_spawn_group_state "$g" "$asks" "$(spl_spawn_group_issues "$key")" "$(cat "$1")")" || continue
    if ! jq -e '.counts.waiting > 0 and .inflight < .width' >/dev/null <<<"$st"; then
      [[ "${DRY_RUN:-1}" == 1 ]] || spl_spawn_group_stall_forget "$short" "$key"
      do_log "INFO work group $key: $(jq -r '"\(.inflight) of width \(.width) in flight, \(.counts.waiting) waiting"' <<<"$st")"
      continue
    fi
    first="$(awk -F'\t' -v k="$key" '$1 == k {v = $2} END {print v + 0}' "$short" 2>/dev/null)"
    if [[ "${first:-0}" == 0 ]]; then
      first="$now"
      [[ "${DRY_RUN:-1}" == 1 ]] || spl_epic_stall_remember "$short" "$key" "$now"
    fi
    if (( now - first < ${EPIC_STALL_IDLE_MIN:-30} * 60 )); then
      do_log "INFO work group $key is short ($(jq -r '"\(.inflight) of \(.width) in flight, \(.counts.waiting) waiting"' <<<"$st")) for $(( (now - first) / 60 )) min (stalled at ${EPIC_STALL_IDLE_MIN:-30})"
      continue
    fi
    last="$(awk -F'\t' -v k="group:$key" '$1 == k {v = $2} END {print v + 0}' "$sent" 2>/dev/null)"
    if (( now - ${last:-0} < ${EPIC_STALL_REPEAT_H:-6} * 3600 )); then
      do_log "INFO work group $key is stalled; its blocker went out $(( (now - last) / 60 )) min ago (one per ${EPIC_STALL_REPEAT_H:-6} h)"
      continue
    fi
    st="$(jq -c --argjson m "$(( (now - first) / 60 ))" '. + {short_min: $m}' <<<"$st")"
    if [[ "${DRY_RUN:-1}" == 1 ]]; then
      do_log "PLAN would send a blocker to $3: work group $key stalled ($(jq -r '"\(.inflight) of width \(.width) in flight, \(.counts.waiting) waiting"' <<<"$st"))"
      continue
    fi
    spl_spawn_q_send "$2" "$3" blocker "$(spl_spawn_q_task "$(jq -r '.topic // ""' <<<"$st")")" "$(spl_spawn_group_stall_body "$st")" || continue
    spl_epic_stall_remember "$sent" "group:$key" "$now"
    do_log "OK work group $key stalled: blocker sent to $3"
  done
  return 0
}

spl_spawn_group_stall_forget() {  # STATE KEY
  [[ -f "$1" ]] || return 0
  awk -F'\t' -v k="$2" '$1 != k' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# The group stall blocker's body (markdown, how-to-post.md).
spl_spawn_group_stall_body() {  # STATE
  jq -r '
    "**Blocker: work group \(.epic) has stalled**\n",
    "\(.inflight) of width \(.width) in flight and \(.counts.waiting) row(s) waiting for \(.short_min) min: the placer did not feed it.",
    "Check the placer on the orch box (`./run -a do_spl_spawn_place`), the hub and the briefs; the group: `GROUP_EPIC=\(.epic) ./run -a do_spl_spawn_group_list`.", "",
    "**Next rows:**", "",
    ([.rows[] | select(.state == "waiting")][0:3][] | "- \(.seq). \(.issue) \(.place) (\(.class))"), "",
    "Sent by do_spl_epic_stall_check (SPL-2370); once per group per \(env.EPIC_STALL_REPEAT_H // "6") h while it stays stalled."' <<<"$1"
}
