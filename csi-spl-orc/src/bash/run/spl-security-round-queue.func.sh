#!/bin/bash
# @description The weekly security round starts itself (owner HUM-10, t1
# @description #spool-hub-ops topic 3d0675ba msg 7ec35e69; day: Friday, poll
# @description answer msg 3271f95a, "Friday, as a week-end check"). One run
# @description for the round of SECURITY_ROUND_DATE (default today, UTC):
# @description   1. VENDORS - do_spl_lane_mix, kind secret (the data rule:
# @description      claude, grok or mistral only). Seat 1 takes its pick; seat 2
# @description      a different vendor when one is available (the row's backup
# @description      first, then claude, grok, mistral), else the same one
# @description   2. QUEUE - per seat: the brief <slug>.md rendered from the seat
# @description      template (<N> and <YYYY-MM-DD> replaced) under
# @description      SPAWN_PLACE_BRIEF_DIR, the ask (task security-round-<date>,
# @description      from the dispatch lease holder, id derived from the date and
# @description      the seat) and do_spl_spawn_enqueue SPAWN_CLASS=bug,
# @description      SPAWN_PLACE=<vendor>:<slug>. An ask the hub has already (any
# @description      state) is never queued again: a replay adds nothing
# @description   3. CALENDAR - the round on the t1 calendar
# @description      (do_spl_calendar_event_add, 06:00-08:00Z that day, linked to
# @description      the topic), once per date (a marker under
# @description      <spool root>/dispatch/security-round/)
# @description It never spawns: the placer places. DRY_RUN=1 (the default)
# @description prints the plan. The switch: SECURITY_ROUND=on|off, else cnf
# @description env.box.security_round.enabled; absent = OFF. A live run
# @description (DRY_RUN=0) acts only while it is on and only on the orch
# @description holder's machine. The rule's one home:
# @description csi-spl-doc/doc/md/fleet-rules-index.md ("security round").
# @description Installed by do_spl_security_round_install_cron (the orch's call).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SECURITY_ROUND (optional) - on | off: beats cnf env.box.security_round.enabled (absent = off)
# @param SECURITY_ROUND_DATE (optional) - the round's day, YYYY-MM-DD, default today (UTC)
# @param SECURITY_ROUND_TEMPLATE (optional) - the seat brief template, default <spool root>/dispatch/briefs/c002-security-round-seat.md
# @param SECURITY_ROUND_TOPIC (optional) - the topic the calendar event links, default the owner's 3d0675ba-6dab-46cc-92c9-2aba3ac7cd23
# @param SECURITY_ROUND_TENANT (optional) - the calendar's workspace, default t1
# @param SECURITY_ROUND_ENV (optional) - the calendar's env, default prd
# @param SECURITY_ROUND_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where the briefs go, default <spool root>/dispatch/briefs
# @param SECURITY_ROUND_MIX_CMD SECURITY_ROUND_CAL_CMD (optional, tests) - replace the lane mix / the calendar add
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ASKS_HOLDER (optional) - as do_spl_spawn_place
# @example ./run -a do_spl_security_round_queue
# @example SECURITY_ROUND=on DRY_RUN=0 ./run -a do_spl_security_round_queue
# @example SECURITY_ROUND_DATE=2026-10-23 ./run -a do_spl_security_round_queue

SPL_SECURITY_ROUND_TOPIC=3d0675ba-6dab-46cc-92c9-2aba3ac7cd23

do_spl_security_round_queue() {
  local dry="${DRY_RUN:-1}" on day tpl holder from v1 v2 n=0 seat vendor
  spl_security_round_check || return 1
  day="${SECURITY_ROUND_DATE:-$(date -u +%F)}"
  tpl="${SECURITY_ROUND_TEMPLATE:-$SPOOL_ROOT/dispatch/briefs/c002-security-round-seat.md}"
  [[ -s "$tpl" ]] || { do_log "FATAL the seat brief template $tpl is missing or empty"; return 1; }
  on="$(spl_security_round_switch)"
  if [[ "$dry" == 0 && "$on" != on ]]; then
    do_log "INFO the security round is off (SECURITY_ROUND / cnf env.box.security_round.enabled): nothing queued"
    return 0
  fi
  spl_spawn_q_init || return 1
  holder="$(spl_asks_holder)"
  if [[ "$dry" == 0 && "${holder##*@}" != "$ASKS_BOX" ]]; then
    do_log "INFO the orch role is held on ${holder##*@} (${holder:-nobody}): its machine queues the round"
    return 0
  fi
  from="$(spl_spawn_place_dispatch)"; from="${from:-$holder}"
  [[ -n "$from" ]] || { do_log "FATAL neither the dispatch nor the orch lease names a holder: nobody to send the asks from"; return 1; }
  read -r v1 v2 <<<"$(spl_security_round_vendors "$day")"
  [[ -n "$v1" ]] || { do_log "FATAL the lane mix holds kind secret (no claude, grok or mistral free): round $day not queued"; return 1; }
  for seat in 1 2; do
    vendor="$v1"; [[ "$seat" == 2 ]] && vendor="${v2:-$v1}"
    spl_security_round_seat "$day" "$seat" "$vendor" "$tpl" "$from" "$holder" && n=$((n + 1))
  done
  spl_security_round_calendar "$day" "$from"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN round $day: $n seat(s) planned or on the hub, nothing queued (switch $on; a live run needs DRY_RUN=0 and the switch on)"
  else
    do_log "OK round $day: $n of 2 seat(s) queued or already on the hub; the placer places them"
  fi
}

# The knobs' shape, before any hub call.
spl_security_round_check() {
  [[ "${DRY_RUN:-1}" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "${SECURITY_ROUND:-}" =~ ^(|on|off)$ ]] || { do_log "FATAL SECURITY_ROUND must be on or off, got '${SECURITY_ROUND:-}'"; return 1; }
  [[ -z "${SECURITY_ROUND_DATE:-}" ]] || [[ "$(date -u -d "$SECURITY_ROUND_DATE" +%F 2>/dev/null)" == "$SECURITY_ROUND_DATE" ]] ||
    { do_log "FATAL SECURITY_ROUND_DATE must be a day, YYYY-MM-DD, got '${SECURITY_ROUND_DATE:-}'"; return 1; }
  [[ "${SECURITY_ROUND_TOPIC:-$SPL_SECURITY_ROUND_TOPIC}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL SECURITY_ROUND_TOPIC must be a topic UUID"; return 1; }
}

# on | off: SECURITY_ROUND, else cnf env.box.security_round.enabled (true = on), else off.
spl_security_round_switch() {
  local cnf v
  [[ -n "${SECURITY_ROUND:-}" ]] && { printf '%s' "$SECURITY_ROUND"; return 0; }
  cnf="${SECURITY_ROUND_CNF:-${APP_PATH:-}/csi-spl-cnf/csi-spl/all.env.yaml}"
  v="$(yq -r '.env.box.security_round.enabled // false' "$cnf" 2>/dev/null)"
  if [[ "$v" == true ]]; then printf on; else printf off; fi
}

# "<seat 1 vendor> <seat 2 vendor>" from one kind-secret lane mix; nothing on hold.
spl_security_round_vendors() {  # DAY
  local out v1 backup v
  if [[ -n "${SECURITY_ROUND_MIX_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(LANE_MIX_KIND=secret LANE_MIX_TASK="security-round-$1" $SECURITY_ROUND_MIX_CMD 2>&1)"
  else
    out="$(LANE_MIX_KIND=secret LANE_MIX_TASK="security-round-$1" \
      timeout "${SECURITY_ROUND_TIMEOUT:-60}" bash "$PROJ_PATH/run" -a do_spl_lane_mix 2>&1)"
  fi
  v1="$(sed -nE 's/^pick=([a-z]+)( .*)?$/\1/p' <<<"$out" | tail -1)"
  [[ "$v1" =~ ^(claude|grok|mistral)$ ]] || return 0
  backup="$(sed -nE 's/^kind=secret .*backup=([a-z]+).*$/\1/p' <<<"$out" | tail -1)"
  for v in $backup claude grok mistral; do
    [[ "$v" != "$v1" && "$v" =~ ^(claude|grok|mistral)$ ]] || continue
    # its table row "<vendor> <target> <effective> <actual> <count> <cli> <status>";
    # a vendor out (no CLI, no auth, a limit verdict, paused) reads "skip (...)"
    grep -qE "^$v +[0-9]+% " <<<"$out" || continue
    grep -qE "^$v +[0-9]+% .* skip " <<<"$out" && continue
    printf '%s %s' "$v1" "$v"; return 0
  done
  printf '%s' "$v1"
}

# The ask id of one seat: a UUID from its sha1, so a replay is the same ask.
spl_security_round_ask_id() {  # DAY SEAT
  local h
  h="$(printf 'security-round:%s:seat-%s' "$1" "$2" | sha1sum | cut -c1-32)"
  printf '%s-%s-5%s-a%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# 0 when the hub has ID in any state (open, queued, placed or closed).
spl_security_round_known() {  # ID
  spl_asks_hub list --fleet "$LANE_FLEET" --role orch --all 2>/dev/null |
    jq -e --arg i "$1" '[.asks[]? | select(.ask_id == $i)] | length > 0' >/dev/null 2>&1
}

# One seat: plan it, or write its brief, put its ask and enqueue it.
spl_security_round_seat() {  # DAY SEAT VENDOR TEMPLATE FROM HOLDER
  local dir="${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}" slug="security-round-$1-seat-$2" id out
  id="$(spl_security_round_ask_id "$1" "$2")"
  if spl_security_round_known "$id"; then
    do_log "INFO seat $2 of round $1 is on the hub already (ask ${id:0:8}): not queued again"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "PLAN would queue seat $2 of round $1 as $3:$slug, ask ${id:0:8}, task security-round-$1, from $5"
    return 0
  fi
  { mkdir -p "$dir" && sed -e "s/<N>/$2/g" -e "s/<YYYY-MM-DD>/$1/g" "$4" >"$dir/$slug.md" && [[ -s "$dir/$slug.md" ]]; } ||
    { do_log "WARN seat $2: the brief $dir/$slug.md was not written: not queued"; return 1; }
  out="$(spl_asks_hub put --fleet "$LANE_FLEET" --id "$id" --kind task --role orch --from "$5" \
    --topic "security-round-$1" --summary "SECURITY ROUND $1 seat $2 of 2 (bug, kind secret): the weekly walk of the chain for its weakest link" 2>&1)" ||
    { do_log "WARN seat $2: the hub did not take the ask: $(tail -1 <<<"$out" | cut -c1-200)"; return 1; }
  ASK_ID="$id" SPAWN_CLASS=bug SPAWN_PLACE="$3:$slug" ASK_BY="$6" SPAWN_URGENT=0 SPAWN_BYPASS='' \
    do_spl_spawn_enqueue || { do_log "WARN seat $2: the enqueue failed"; return 1; }
}

# The round on the calendar, once per date: 06:00-08:00Z that day, linked to the topic.
spl_security_round_calendar() {  # DAY FROM
  local mark="$SPOOL_ROOT/dispatch/security-round/$1.calendar" topic="${SECURITY_ROUND_TOPIC:-$SPL_SECURITY_ROUND_TOPIC}" out rc=0
  local tenant="${SECURITY_ROUND_TENANT:-t1}" env_="${SECURITY_ROUND_ENV:-prd}"
  local -a kv
  if [[ -s "$mark" ]]; then do_log "INFO round $1 is on the calendar already ($(head -1 "$mark"))"; return 0; fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "PLAN would add 'Weekly security round ($1)' $1 06:00-08:00Z to the $tenant calendar ($env_), topic ${topic:0:8}"
    return 0
  fi
  kv=(ENV="$env_" TENANT_ID="$tenant" TITLE="Weekly security round ($1)" ALL_DAY=0 DRY_RUN=0
    STARTS_AT="$1T06:00:00Z" ENDS_AT="$1T08:00:00Z" TOPIC_ID="$topic" AGENT_ID="${2%@*}"
    DESCRIPTION="The weekly security round: two panel seats walk the chain for its weakest link (owner msg 7ec35e69). Topic: /t/$topic")
  if [[ -n "${SECURITY_ROUND_CAL_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(env "${kv[@]}" $SECURITY_ROUND_CAL_CMD 2>&1)" || rc=$?
  else
    out="$(env "${kv[@]}" timeout "${SECURITY_ROUND_TIMEOUT:-60}" bash "$PROJ_PATH/run" -a do_spl_calendar_event_add 2>&1)" || rc=$?
  fi
  if (( rc != 0 )); then
    do_log "WARN round $1 is not on the calendar (rc $rc): $(grep -E 'FATAL|ERROR' <<<"$out" | tail -1 | cut -c1-200); the next run tries again"
    return 1
  fi
  mkdir -p "${mark%/*}" && printf '%s %s\n' "$(date -u +%FT%TZ)" "$(grep -oE 'OK event [A-Za-z0-9_-]+' <<<"$out" | tail -1)" >"$mark"
  do_log "OK round $1 is on the $tenant calendar ($env_), $1 06:00-08:00Z"
}
