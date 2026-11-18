#!/bin/bash
#------------------------------------------------------------------------------
# The dependent queue row (spec 157 section 4.2, SPL-5874; owner HUM-10, topic
# dfe850d9 msg 01e9793b: "automate every single thing that can be automated").
# A queued row whose brief carries `After: <issue key | row slug>` is held by
# the placer until that prerequisite has landed on origin/master, then for
# `After-Delay: <minutes>` (default 0), then placed like any row, once. The
# miss it ends: spec 170 B3 was to be queued "after B2 lands" in a dispatcher
# note only; B2 landed on 2026-11-15 (6b5667bad) and B3 sat unqueued 3 days.
#
# The prerequisite lives in the brief, not on the hub: the brief travels with
# the row (the placer reads it on the orch box) and a hand-written After: line
# works the same as SPAWN_AFTER. Landed means:
#   - an issue key: a trunk commit closes it by the close rule
#     (li_landed: a fix|feat|perf|refactor subject with the key in its scope,
#     or a Closes: trailer; lane-issue-and-docs.md)
#   - a row slug: its lane's issue landed by that same rule. The lane's key is
#     the slug brief's `Issue:` line, else the key the placer read when it
#     launched the slug (<asks dir>/.place.slugs), else, for a lane of this
#     box, its lifetime/issue. No key known yet -> held, and the reason says so
# The land time is the committer time of the oldest closing commit; the
# delay counts from it.
#
# Callers: do_spl_spawn_enqueue (spl_spawn_after_enqueue: checks and writes
# the lines), do_spl_spawn_place (spl_spawn_place_after_hold, the alarm
# spl_spawn_after_alarm, spl_spawn_after_held for the review-seat alarm and
# spl_spawn_after_unheld for the supply check) and do_spl_spawn_queue
# (spl_spawn_q_afters).
#------------------------------------------------------------------------------

# 0 = ARG is an issue key (SPL-123), resp. a row slug (the SPAWN_PLACE slug form).
spl_spawn_after_is_key() { [[ "$1" =~ ^[A-Z][A-Z0-9]{0,9}-[1-9][0-9]*$ ]]; }
spl_spawn_after_is_slug() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }

# The brief's prerequisite, "<after>\t<delay minutes>", or nothing for none.
spl_spawn_after_of() {  # BRIEF
  local after delay
  [[ -n "$1" && -r "$1" ]] || return 0
  after="$(sed -nE 's/^After:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$1" | tail -1)"
  [[ -n "$after" ]] || return 0
  delay="$(sed -nE 's/^After-Delay:[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$1" | tail -1)"
  printf '%s\t%s\n' "$after" "${delay:-0}"
}

# The lane-issue helpers (li_landed, li_key_from_brief, li_hub_read).
spl_spawn_after_li() {
  declare -F li_landed >/dev/null || . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2
}

# The issue key of AFTER: AFTER itself for a key; for a row slug its lane's
# key (see the header); nothing when not known yet.
spl_spawn_after_key() {  # AFTER
  local brief f k="" agent
  spl_spawn_after_is_key "$1" && { printf '%s\n' "$1"; return 0; }
  spl_spawn_after_li
  brief="$(spl_spawn_place_brief "$1")"
  [[ -z "$brief" ]] || k="$(li_key_from_brief "$brief")"
  f="$(spool_asks_dir)/.place.slugs"
  if [[ -z "$k" && -r "$f" ]]; then
    k="$(awk -F'\t' -v s="$1" '$1 == s && $3 != "" { k = $3 } END { print k }' "$f")"
    agent="$(awk -F'\t' -v s="$1" '$1 == s { a = $2 } END { sub(/@.*/, "", a); print a }' "$f")"
    [[ -n "$k" || -z "$agent" ]] || k="$(li_key_of_agent "$SPOOL_ROOT" "$agent" 2>/dev/null)"
  fi
  [[ -z "$k" ]] || printf '%s\n' "$k"
}

# The git clone whose origin/master is read, default the checkout this runs from.
spl_spawn_after_dir() { printf '%s' "${SPAWN_AFTER_GIT_DIR:-$APP_PATH}"; }

# The epoch KEY landed on origin/master (its oldest closing commit), or exit 1.
spl_spawn_after_landed() {  # KEY
  local dir h
  spl_spawn_after_li
  dir="$(spl_spawn_after_dir)"
  h="$(li_landed "$dir" "$1" | tail -1)"
  [[ -n "$h" ]] || return 1
  li_git "$dir" log -1 --format=%ct "$h"
}

# The state of BRIEF's prerequisite: "free\t<why>" (none, or landed and past
# its delay), else "held\t<why>"; one line.
spl_spawn_after_state() {  # BRIEF
  local spec after delay key at left
  spec="$(spl_spawn_after_of "$1")"
  [[ -n "$spec" ]] || { printf 'free\tno After: line\n'; return 0; }
  after="${spec%%$'\t'*}"; delay="${spec#*$'\t'}"
  key="$(spl_spawn_after_key "$after")"
  if [[ -z "$key" ]]; then
    printf 'held\twaiting on %s: its lane has no issue key known on this box yet (not placed, or placed elsewhere)\n' "$after"
    return 0
  fi
  [[ "$key" == "$after" ]] || after="$after ($key)"
  if ! at="$(spl_spawn_after_landed "$key")"; then
    printf 'held\twaiting on %s: not landed on origin/master\n' "$after"
    return 0
  fi
  left=$(( at + delay * 60 - $(date +%s) ))
  if (( left > 0 )); then
    printf 'held\twaiting on %s: landed %s, placed after its %s min delay (%s min left)\n' "$after" \
      "$(date -u -d "@$at" +%Y-%m-%dT%H:%MZ)" "$delay" "$(( (left + 59) / 60 ))"
    return 0
  fi
  printf 'free\t%s landed %s\n' "$after" "$(date -u -d "@$at" +%Y-%m-%dT%H:%MZ)"
}

# Fetches origin once a tick, only when a row waits on a prerequisite
# (SPAWN_AFTER_FETCH=0: no fetch, the last fetched trunk counts).
spl_spawn_after_fetch() {
  local dir
  [[ "${SPAWN_AFTER_FETCH:-1}" != 0 ]] || return 0
  dir="$(spl_spawn_after_dir)"
  timeout "${SPAWN_AFTER_FETCH_TIMEOUT:-60}" git -C "$dir" fetch -q origin >/dev/null 2>&1 ||
    do_log "WARN git fetch origin failed in $dir: the dependent rows are judged on its last fetched trunk" >&2
  return 0
}

# Holds every queued row the placer can launch whose prerequisite is not
# free: it stays queued, out of this tick's line, never acked or closed (so
# no close of another row drops it), its reason in .place.wait ("held: ...").
# Prints ROWS minus the held ones.
spl_spawn_place_after_hold() {  # MARKED ROWS
  local id slug brief st held=() fetched=0
  while IFS=$'\t' read -r id slug; do
    brief="$(spl_spawn_place_brief "$slug")"
    [[ -n "$(spl_spawn_after_of "$brief")" ]] || continue
    (( fetched )) || { spl_spawn_after_fetch; fetched=1; }
    st="$(spl_spawn_after_state "$brief")"
    if [[ "$st" == held$'\t'* ]]; then
      spl_spawn_place_wait "$id" "held: ${st#held$'\t'}"
      do_log "INFO hold: ask ${id:0:8} ($slug) is ${st#held$'\t'}; it stays queued" >&2
      held+=("$id")
    else
      do_log "INFO ask ${id:0:8} ($slug): ${st#free$'\t'}: released to the line" >&2
    fi
  done < <(jq -r '.[] | select(.state == "queued" and ._l) | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")
  spl_spawn_place_wait_keep held "$(printf '%s\n' "${held[@]}")" "^held: waiting on "
  jq -c --argjson h "$(spl_spawn_place_json_ids "${held[@]}")" '[.[] | select(.ask_id as $i | $h | index($i) | not)]' <<<"$1"
}

# 0 = the row PLACEMENT (<vendor>:<slug>) is held by its brief's After: line
# right now: an intended hold, judged on the last fetched trunk.
spl_spawn_after_held() {  # PLACEMENT
  local brief
  brief="$(spl_spawn_place_brief "${1#*:}")"
  [[ -n "$(spl_spawn_after_of "$brief")" ]] || return 1
  [[ "$(spl_spawn_after_state "$brief")" == held$'\t'* ]]
}

# ROWS without the queued rows their After: line holds: a held row is no
# supply of its class (R7 c-434 N2 of SPL-5874), so the supply blocker still
# fires while the only row of a class waits on a prerequisite.
spl_spawn_after_unheld() {  # ROWS
  local id place held=()
  while IFS=$'\t' read -r id place; do
    spl_spawn_after_held "$place" && held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and (.placement // "") != "") | "\(.ask_id)\t\(.placement)"' <<<"$1")
  jq -c --argjson h "$(spl_spawn_place_json_ids "${held[@]}")" '[.[] | select(.ask_id as $i | $h | index($i) | not)]' <<<"$1"
}

# The held-age limit in minutes: SPAWN_AFTER_ALARM_MIN, else cnf
# env.box.spawn_after.alarm_min, else 1440; 0 = no held-age alarm.
spl_spawn_after_alarm_min() {
  local v="${SPAWN_AFTER_ALARM_MIN-}" cnf="${SPAWN_PLACE_CNF:-$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml}"
  [[ -n "$v" || ! -r "$cnf" ]] || v="$(yq -r '.env.box.spawn_after.alarm_min // ""' "$cnf" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=1440
  printf '%s' "$v"
}

# Why the prerequisite AFTER will never land, or nothing: a key that is diss
# or unknown on the hub, a slug (or its lane's key) known nowhere, a value
# that is neither (a hand-copied After: line skips the enqueue check). A hub
# that did not answer is no verdict: nothing.
spl_spawn_after_dead() {  # AFTER
  local key why
  key="$(spl_spawn_after_key "$1")"
  why="$(spl_spawn_after_check "${key:-$1}" 0 "")"
  [[ "$why" == *"could not be checked"* ]] || printf '%s' "${why#SPAWN_AFTER }"
}

# W1 (R7 c-434 of SPL-5874): a held row ends or alarms, never waits forever
# unseen. Each tick, for every queued row the placer can launch whose brief
# carries After: (MARKED_ROWS, after spl_spawn_place_mark):
#   dead - its prerequisite will never land (spl_spawn_after_dead; the hub is
#          read at most once per SPAWN_AFTER_CHECK_MIN, default 15)
#   age  - still held SPAWN_AFTER_ALARM_MIN or more in line (wait_s: since
#          enqueued_at)
# ONE blocker per ask and kind to the dispatch lease holder (none: HOLDER)
# with the close command; <asks dir>/.place.after-alarm keeps "<ask>\t<kind>",
# pruned to the rows in the queue. Not delivered: retried next tick.
spl_spawn_after_alarm() {  # HOLDER MARKED_ROWS
  local d f now check=0 lim id slug wait brief after why lines="" fired=() to
  d="$(spool_asks_dir)"; f="$d/.place.after-alarm"; now="$(date +%s)"
  [[ -e "$f" ]] || : >"$f"
  awk -F'\t' 'NR == FNR { k[$1]; next } $1 in k' <(jq -r '.[].ask_id' <<<"$2") "$f" >"$f.$$" && mv -f "$f.$$" "$f"
  (( now - $(stat -c %Y "$f.check" 2>/dev/null || echo 0) >= ${SPAWN_AFTER_CHECK_MIN:-15} * 60 )) && check=1
  lim=$(( $(spl_spawn_after_alarm_min) * 60 ))
  while IFS=$'\t' read -r id slug wait; do
    brief="$(spl_spawn_place_brief "$slug")"
    after="$(spl_spawn_after_of "$brief")"; after="${after%%$'\t'*}"
    [[ -n "$after" ]] || continue
    if (( check )) && ! grep -qx "$id"$'\t'dead "$f"; then
      why="$(spl_spawn_after_dead "$after")"
      if [[ -n "$why" ]]; then
        lines+=$'\n'"- ask ${id:0:8} ($slug), $(( wait / 60 )) min in line: $why. End it: \`ASK_ID=${id:0:8} ASK_STATE=declined ASK_REASON='After: $after will never land' ./run -a do_spl_ask_close\`, or fix its After: line"
        fired+=("$id"$'\t'dead); continue
      fi
    fi
    (( lim > 0 && wait >= lim )) && ! grep -qx "$id"$'\t'age "$f" || continue
    why="$(spl_spawn_after_state "$brief")"
    [[ "$why" == held$'\t'* ]] || continue
    lines+=$'\n'"- ask ${id:0:8} ($slug), $(( wait / 60 )) min in line, ${why#held$'\t'}"
    fired+=("$id"$'\t'age)
  done < <(jq -r '.[] | select(.state == "queued" and ._l) | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))\t\(.wait_s // 0 | floor)"' <<<"$2")
  if (( ${#fired[@]} > 0 )); then
    to="$(spl_spawn_place_dispatch)"
    spl_spawn_q_send "$1" "${to:-$1}" blocker spawn-queue "**SPAWN QUEUE: ${#fired[@]} dependent row(s) held on their After: line need you** (spec 157 4.2).$lines"$'\n\n'"The held-age limit is $(( lim / 60 )) min (SPAWN_AFTER_ALARM_MIN, cnf env.box.spawn_after.alarm_min). The queue: \`./run -a do_spl_spawn_queue\`." ||
      { do_log "WARN the dependent-row alarm was not delivered: retried next tick"; return 0; }
    printf '%s\n' "${fired[@]}" >>"$f"
    do_log "ALERT dependent row(s) held:$(tr '\n' ' ' <<<"$lines")"
  fi
  (( check )) && touch "$f.check"
  return 0
}

# The placer launched SLUG as AGENT: one line in <asks dir>/.place.slugs,
# "<slug>\t<agent>\t<issue key or empty>\t<epoch>", the key read from the
# launcher's "<ID> carries issue <KEY>" line in OUT. A row slug's prerequisite
# resolves to its lane's key through it.
spl_spawn_after_launched() {  # SLUG AGENT OUT
  local key
  key="$(sed -nE 's/^spawn-window: [^ ]+ carries issue ([A-Z][A-Z0-9]{0,9}-[1-9][0-9]*)( .*)?$/\1/p' <<<"$3" | tail -1)"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$key" "$(date +%s)" >>"$(spool_asks_dir)/.place.slugs" 2>/dev/null || true
}

# At enqueue (inside spl_spawn_q_enqueue, before the hub's queue op): checks
# the prerequisite, SPAWN_AFTER (+ SPAWN_AFTER_DELAY) or the brief's own
# After: line, and writes SPAWN_AFTER into the brief. One FATAL line and exit
# 1 = not queued: an unknown key or slug, a key that ended diss, the row's own
# slug, a bad delay. PLACE is the row's <vendor>:<slug>, BRIEF its brief file.
spl_spawn_after_enqueue() {  # ID PLACE BRIEF
  local after="${SPAWN_AFTER:-}" delay="${SPAWN_AFTER_DELAY:-}" spec why
  if [[ -z "$after" ]]; then
    [[ -z "$delay" ]] || { do_log "FATAL SPAWN_AFTER_DELAY needs SPAWN_AFTER: ask not queued" >&2; return 1; }
    spec="$(spl_spawn_after_of "$3")"
    [[ -n "$spec" ]] || return 0
    after="${spec%%$'\t'*}"; delay="${spec#*$'\t'}"
  fi
  [[ -n "$2" && -n "$3" ]] ||
    { do_log "FATAL SPAWN_AFTER needs a placed row with its brief here (SPAWN_PLACE=<vendor>:<slug>, <slug>.md under ${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}): the prerequisite is kept in the brief; ask not queued" >&2; return 1; }
  why="$(spl_spawn_after_check "$after" "${delay:-0}" "${2#*:}")"
  [[ -z "$why" ]] || { do_log "FATAL ask ${1:0:8} not queued: $why" >&2; return 1; }
  if [[ -n "${SPAWN_AFTER:-}" ]]; then
    spl_spawn_after_write "$3" "$after" "${delay:-0}" ||
      { do_log "FATAL ask ${1:0:8} not queued: its brief $3 could not be written" >&2; return 1; }
  fi
  do_log "INFO ask ${1:0:8} is held until $after lands on origin/master$( [[ "${delay:-0}" == 0 ]] || echo ", then $delay min") (spec 157 4.2)" >&2
}

# Why AFTER (with DELAY, on the row SLUG) is refused, or nothing.
spl_spawn_after_check() {  # AFTER DELAY SLUG
  local out st
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 <= 1440 )) || { echo "SPAWN_AFTER_DELAY must be whole minutes 0..1440, got '$2'"; return 0; }
  [[ "$1" != "$3" ]] || { echo "SPAWN_AFTER $1 is this row's own slug"; return 0; }
  spl_spawn_after_li
  if spl_spawn_after_is_key "$1"; then
    [[ -z "$(li_landed "$(spl_spawn_after_dir)" "$1")" ]] || return 0
    out="$(li_hub_read "$1")"
    st="$(li_status_of "$1" <<<"$out")"
    case "$st" in
      diss) echo "SPAWN_AFTER $1 is diss on the hub: it will never land" ;;
      "") if grep -q 'not_found' <<<"$out"; then echo "SPAWN_AFTER $1 is no live issue on the hub (unknown key)"
          else echo "SPAWN_AFTER $1 could not be checked: the hub did not answer and no trunk commit closes it"; fi ;;
    esac
    return 0
  fi
  spl_spawn_after_is_slug "$1" || { echo "SPAWN_AFTER must be an issue key (SPL-123) or a row slug, got '$1'"; return 0; }
  [[ -z "$(spl_spawn_place_brief "$1")" ]] || return 0
  awk -F'\t' -v s="$1" '$1 == s { f = 1 } END { exit !f }' "$(spool_asks_dir)/.place.slugs" 2>/dev/null && return 0
  echo "SPAWN_AFTER $1 is no known row slug (no brief $1.md under ${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}, never placed from this box)"
}

# Replaces BRIEF's After: and After-Delay: lines with AFTER and DELAY, in
# place (cat >, so the file keeps its owner and mode).
spl_spawn_after_write() {  # BRIEF AFTER DELAY
  local tmp rc
  tmp="$(mktemp)" || return 1
  { grep -vE '^After(-Delay)?:' "$1"; printf 'After: %s\n' "$2"; (( $3 == 0 )) || printf 'After-Delay: %s\n' "$3"; } >"$tmp" &&
    cat "$tmp" >"$1"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

# One "HELD <ask8> <slug> after <x>[ +Nm]" line per queued row of ROWS whose
# brief is here and carries an After: line; the placer's .place.wait line (a
# WAIT line) says how far it is.
spl_spawn_q_afters() {  # ROWS
  local id slug spec brief
  declare -F spl_spawn_place_brief >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
  while IFS=$'\t' read -r id slug; do
    brief="$(spl_spawn_place_brief "$slug")"
    spec="$(spl_spawn_after_of "$brief")"
    [[ -n "$spec" ]] || continue
    echo "HELD ${id:0:8} $slug after ${spec%%$'\t'*}$( [[ "${spec#*$'\t'}" == 0 ]] || echo " +${spec#*$'\t'}m"): never placed before it lands on origin/master"
  done < <(jq -r '.[] | select(.state == "queued" and (.placement // "") != "") | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")
  return 0
}
