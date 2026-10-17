#!/bin/bash
# @description The idle filler (owner HUM-10, t1 71dbbf15, poll 41155726 answer
# @description msg 3c91b4c1: "(A) Yes, from open issues (bugs and features),
# @description within the share bands"). Spare box capacity becomes queued
# @description lanes from open issues; it never spawns, the placer
# @description (do_spl_spawn_place) places. The rule's one home:
# @description csi-spl-doc/doc/md/fleet-rules-index.md ("Idle filler"). One tick:
# @description   1. GATE - the box pick (do_spl_box_pick) says a box is BELOW its
# @description      LOW mark, and the spawn queue has 0 queued and 0 placing
# @description   2. HOW MANY - enough lanes to bring that box up to its low mark,
# @description      ceil((low% * cpus / 100 - load5) / SPAWN_FILL_CORES_PER_LANE)
# @description      (one lane ~ one core, the first estimate), at most
# @description      SPAWN_FILL_MAX per tick (default 1)
# @description   3. CLASS - bug or feature by the live share (do_spl_spawn_share):
# @description      a class OVER its band is never queued; the one furthest UNDER
# @description      comes first (ties bug > feature, as the placer)
# @description   4. ISSUES - open issues (SPAWN_FILL_STATUS, default todo,eval) of
# @description      kind issue labelled bug or feature (the label is the class,
# @description      never guessed); skipped: labels needs-owner / blocker / epic,
# @description      a human assignee (HUM-*), a live lane's assignee or lane key,
# @description      a key an ask names (open, queued or closed this week).
# @description      Order: todo before eval, then priority (1 urgent first, none
# @description      last), then the oldest
# @description   5. VENDOR - do_spl_lane_mix, kind SPAWN_FILL_KIND (default
# @description      complex_coding: an unattended issue needs judgement). Data
# @description      rule: an issue whose text names a secret or personal data
# @description      asks the mix with LANE_MIX_SENSITIVE=1 and is skipped unless
# @description      the pick is claude, grok or mistral
# @description   6. QUEUE - writes the brief <slug>.md (Issue: + Class: lines)
# @description      under SPAWN_PLACE_BRIEF_DIR, puts the ask (id derived from
# @description      the key, so a replay is the same ask) and enqueues it with
# @description      do_spl_spawn_enqueue, SPAWN_CLASS and SPAWN_PLACE=<vendor>:<slug>
# @description DRY_RUN=1 (the default) prints what it would queue and why. The
# @description switch: SPAWN_FILL=on|off, else cnf env.box.spawn_fill.enabled;
# @description absent = OFF. A live run (DRY_RUN=0) queues only while it is on
# @description and only on the orch holder's machine.
# @description Installed by do_spl_spawn_fill_install_cron (the orch's call).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPAWN_FILL (optional) - on | off: the switch, beats cnf env.box.spawn_fill.enabled (absent = off)
# @param SPAWN_FILL_MAX (optional) - rows per tick, 1..10, default 1
# @param SPAWN_FILL_CORES_PER_LANE (optional) - cores one lane is counted for, default 1
# @param SPAWN_FILL_STATUS (optional) - the issue statuses taken, todo / eval / both (comma list), default todo,eval
# @param SPAWN_FILL_KIND (optional) - the do_spl_lane_mix kind, default complex_coding
# @param SPAWN_FILL_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where the briefs go, default <spool root>/dispatch/briefs
# @param ENV TENANT_ID DESK_AGENT DESK_BOX (optional) - the issue desk, default the lease's (as do_spl_lane_issue)
# @param SPAWN_FILL_PICK_CMD SPAWN_FILL_ISSUES_CMD SPAWN_FILL_MIX_CMD (optional, tests) - print the box pick / the issue list JSON / the lane mix (gets LANE_MIX_KIND, LANE_MIX_SENSITIVE)
# @param SPAWN_SHARE_LANES_CMD ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ASKS_HOLDER (optional) - as do_spl_spawn_place
# @example ./run -a do_spl_spawn_fill
# @example SPAWN_FILL=on DRY_RUN=0 ./run -a do_spl_spawn_fill

do_spl_spawn_fill() {
  local dry="${DRY_RUN:-1}" on holder rows pick n share classes issues chosen
  spl_spawn_fill_check || return 1
  spl_spawn_fill_epic_stall
  on="$(spl_spawn_fill_switch)"
  if [[ "$dry" == 0 && "$on" != on ]]; then
    do_log "INFO the idle filler is off (SPAWN_FILL / cnf env.box.spawn_fill.enabled): nothing queued"
    return 0
  fi
  spl_spawn_q_init || return 1
  holder="$(spl_asks_holder)"
  if [[ "$dry" == 0 && "${holder##*@}" != "$ASKS_BOX" ]]; then
    do_log "INFO the orch role is held on ${holder##*@} (${holder:-nobody}): its machine fills"
    return 0
  fi
  rows="$(spl_spawn_q_rows)" || { do_log "WARN the hub did not answer: no fill this tick"; return 0; }
  jq -e 'length == 0' >/dev/null <<<"$rows" ||
    { do_log "INFO the spawn queue is not empty ($(jq '[.[] | select(.state == "queued")] | length' <<<"$rows") queued, $(jq '[.[] | select(.state == "acked")] | length' <<<"$rows") placing): nothing to fill"; return 0; }
  pick="$(spl_spawn_fill_pick)" || return 0
  n="$(spl_spawn_fill_count "$pick")"
  share="$(spl_spawn_share)" || { do_log "WARN the live share could not be read: no fill this tick"; return 0; }
  classes="$(spl_spawn_fill_classes "$share")"
  [[ -n "$classes" ]] || { do_log "INFO every class the filler takes is over its band ($(spl_spawn_share_line "$share")): nothing to fill"; return 0; }
  do_log "INFO $(jq -r '.why' <<<"$pick"): $n lane(s) this tick (${SPAWN_FILL_CORES_PER_LANE:-1} core(s) a lane, at most $(spl_spawn_fill_max)); classes in order: $classes ($(spl_spawn_share_line "$share"))"
  issues="$(spl_spawn_fill_issues)" || { do_log "WARN the open issues could not be read: no fill this tick"; return 0; }
  chosen="$(spl_spawn_fill_choose "$issues" "$classes" "$(spl_spawn_fill_held "$share")" "$n")"
  [[ "$(jq 'length' <<<"$chosen")" -gt 0 ]] ||
    { do_log "INFO no open $classes issue is free (labelled, not needs-owner / blocker / epic, not held by a lane or an ask): nothing to fill"; return 0; }
  spl_spawn_fill_queue "$chosen" "$pick" "$holder" "$on"
}

# The knobs' shape, before any hub call.
spl_spawn_fill_check() {
  [[ "${DRY_RUN:-1}" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "${SPAWN_FILL:-}" =~ ^(|on|off)$ ]] || { do_log "FATAL SPAWN_FILL must be on or off, got '${SPAWN_FILL:-}'"; return 1; }
  [[ "${SPAWN_FILL_MAX:-1}" =~ ^([1-9]|10)$ ]] || { do_log "FATAL SPAWN_FILL_MAX must be 1..10, got '${SPAWN_FILL_MAX:-}'"; return 1; }
  [[ "${SPAWN_FILL_CORES_PER_LANE:-1}" =~ ^[1-9][0-9]?$ ]] ||
    { do_log "FATAL SPAWN_FILL_CORES_PER_LANE must be a whole number of cores, 1..99, got '${SPAWN_FILL_CORES_PER_LANE:-}'"; return 1; }
  [[ "${SPAWN_FILL_STATUS:-todo,eval}" =~ ^(todo|eval)(,(todo|eval))?$ ]] ||
    { do_log "FATAL SPAWN_FILL_STATUS must be todo, eval or both (comma list), got '${SPAWN_FILL_STATUS:-}'"; return 1; }
  [[ "${SPAWN_FILL_KIND:-complex_coding}" =~ ^[a-z_]{2,32}$ ]] || { do_log "FATAL SPAWN_FILL_KIND must be a do_spl_lane_mix kind"; return 1; }
}

spl_spawn_fill_max() { printf '%s' "${SPAWN_FILL_MAX:-1}"; }

# A live tick also runs the stalled-epic check (SPL-2358), whatever the
# filler's switch: an epic whose next pair nobody queued is reported, never
# filled. Its failure never stops the fill.
spl_spawn_fill_epic_stall() {
  [[ "${DRY_RUN:-1}" == 0 ]] || return 0
  declare -F do_spl_epic_stall_check >/dev/null ||
    { [[ -r "$PROJ_PATH/src/bash/run/spl-epic-stall-check.func.sh" ]] && . "$PROJ_PATH/src/bash/run/spl-epic-stall-check.func.sh"; }
  declare -F do_spl_epic_stall_check >/dev/null || return 0
  ( do_spl_epic_stall_check ) || do_log "WARN the epic stall check failed: the fill goes on"
}

# on | off: SPAWN_FILL, else cnf env.box.spawn_fill.enabled (true = on), else off.
spl_spawn_fill_switch() {
  local cnf v
  [[ -n "${SPAWN_FILL:-}" ]] && { printf '%s' "$SPAWN_FILL"; return 0; }
  cnf="${SPAWN_FILL_CNF:-${APP_PATH:-}/csi-spl-cnf/csi-spl/all.env.yaml}"
  v="$(yq -r '.env.box.spawn_fill.enabled // false' "$cnf" 2>/dev/null)"
  if [[ "$v" == true ]]; then printf on; else printf off; fi
}

# The picked box as JSON {box, load5, cpus, pct, low, why} when the box pick
# says it is below its low mark; else one INFO line and 1.
spl_spawn_fill_pick() {
  local out line box row
  if [[ -n "${SPAWN_FILL_PICK_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_FILL_PICK_CMD 2>&1)"
  else
    out="$(timeout "${SPAWN_FILL_TIMEOUT:-60}" bash "$PROJ_PATH/run" -a do_spl_box_pick 2>&1)"
  fi
  line="$(grep -E '^pick=' <<<"$out" | tail -1)"
  [[ "$line" =~ ^pick=([a-z0-9][a-z0-9-]*)\ reason=.*below\ its\ low\ mark ]] ||
    { do_log "INFO no box is below its low mark (${line:-the box pick said nothing}): nothing to fill" >&2; return 1; }
  box="${BASH_REMATCH[1]}"
  row="$(grep -E "^BOX $box " <<<"$out" | tail -1)"
  [[ "$row" =~ load5\ ([0-9.]+)\ +cpus\ ([0-9]+)\ +([0-9]+)%.*band\ ([0-9]+)\.\. ]] ||
    { do_log "WARN the box pick names $box but its BOX line does not read: '$row'" >&2; return 1; }
  jq -n -c --arg b "$box" --argjson l "${BASH_REMATCH[1]}" --argjson c "${BASH_REMATCH[2]}" \
    --argjson p "${BASH_REMATCH[3]}" --argjson lo "${BASH_REMATCH[4]}" \
    '{box: $b, load5: $l, cpus: $c, pct: $p, low: $lo, why: "\($b) is below its low mark (\($p)% < \($lo)%, load5 \($l) on \($c) cpus)"}'
}

# How many lanes this tick: the cores to the low mark per lane, 1..SPAWN_FILL_MAX.
spl_spawn_fill_count() {  # PICK
  jq -r --argjson per "${SPAWN_FILL_CORES_PER_LANE:-1}" --argjson max "$(spl_spawn_fill_max)" '
    (((.low * .cpus / 100) - .load5) / $per | ceil) as $n | [([$n, $max] | min), 1] | max' <<<"$1"
}

# The classes the filler may queue, furthest under its band first: "bug
# feature", "feature", ... A class OVER its band is left out.
spl_spawn_fill_classes() {  # SHARE
  jq -r '
    [.by | to_entries[] | select(.key == "bug" or .key == "feature") | .key as $c | .value as $b
     | select($b.verdict != "OVER")
     | {c: $c, t: (if $b.pct < $b.lo then 0 else 1 end),
        s: (if $b.pct < $b.lo then ($b.lo - $b.pct) / $b.lo elif $c == "bug" then ($b.hi - $b.pct) / $b.hi else 0 end),
        o: (if $c == "bug" then 0 else 1 end)}]
    | sort_by(.t, -.s, .o) | map(.c) | join(" ")' <<<"$1"
}

# What is held already, as JSON {lanes: [ids], keys: [keys]}: the live lanes
# (the share's lane list), the keys of this box's live lanes (li_key_of_agent)
# and every key an ask summary names (open, queued, or closed this week).
spl_spawn_fill_held() {  # SHARE
  local ids keys='' id asks
  ids="$(jq -c '[.lanes[].id | sub("@.*"; "")]' <<<"$1")"
  declare -F li_key_of_agent >/dev/null || . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh"
  while IFS= read -r id; do
    keys+="$(li_key_of_agent "$SPOOL_ROOT" "$id" 2>/dev/null) "
  done < <(jq -r --arg b "$ASKS_BOX" '.lanes[].id | select(endswith("@" + $b)) | sub("@.*"; "")' <<<"$1")
  asks="$(spl_asks_hub list --fleet "$LANE_FLEET" --role orch --all 2>/dev/null | jq -r '[.asks[]? | .summary // ""] | join("\n")' 2>/dev/null)"
  keys+="$(grep -oE '\b[A-Z]{2,10}-[0-9]+\b' <<<"$asks" | tr '\n' ' ')"
  jq -n -c --argjson l "$ids" --arg k "$keys" '{lanes: $l, keys: ($k | split(" ") | map(select(length > 0)) | unique)}'
}

# The open issues as one list document (`spool issue list`'s JSON), every
# assignee, the statuses of SPAWN_FILL_STATUS.
spl_spawn_fill_issues() {
  if [[ -n "${SPAWN_FILL_ISSUES_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPAWN_FILL_ISSUES_CMD; return
  fi
  local s page rc=0
  local -a pages=()
  spl_lane_issue_desk "$SPOOL_ROOT" 0 >&2 || return 1
  spl_desk_issue_once >&2 || return 1
  for s in $(tr ',' ' ' <<<"${SPAWN_FILL_STATUS:-todo,eval}"); do
    page="$(mktemp)"; pages+=("$page")
    spl_issue_list_fetch --status "$s" --limit 50 >"$page" || { rc=1; break; }
  done
  ((rc == 0)) && { spl_issue_merge_pages "${pages[@]}" || rc=1; }
  rm -f "${pages[@]}"
  return "$rc"
}

# The issues to queue, best first, at most N, as a JSON array of
# {key, title, description, status, priority, created_at, class, sensitive}.
spl_spawn_fill_choose() {  # ISSUES CLASSES HELD N
  jq -c --arg cl "$2" --argjson held "$3" --argjson n "$4" --arg st "${SPAWN_FILL_STATUS:-todo,eval}" '
    def lbl: [.labels[]? | if type == "object" then (.id // .name) else . end];
    def secret: test("secret|credential|password|passphrase|private key|api[ _-]?key|access token|personal data|customer data|\\bpii\\b|key-[a-z0-9-]+\\.json"; "i");
    ($cl | split(" ")) as $order | ($st | split(",")) as $sts
    | [.result.issues[]? | select((.kind // "issue") == "issue") | select(.status as $s | $sts | index($s))
       | lbl as $l
       | select(($l | index("needs-owner") | not) and ($l | index("blocker") | not) and ($l | index("epic") | not))
       | (if ($l | index("bug")) then "bug" elif ($l | index("feature")) then "feature" else "" end) as $c
       | select($c != "" and ($order | index($c)))
       | select((.assignee // "") as $a | ($a | startswith("HUM-") | not) and ($held.lanes | index($a) | not))
       | select(.key as $k | $held.keys | index($k) | not)
       | {key, title, description: (.description // ""), status, priority: (.priority // 0), created_at, class: $c,
          sensitive: (((.title // "") + " " + (.description // "")) | secret),
          _o: ($order | index($c)), _s: (.status as $s | $sts | index($s)), _p: (if (.priority // 0) < 1 then 9 else .priority end)}]
    | sort_by(._o, ._s, ._p, .created_at) | .[0:$n] | map(del(._o, ._s, ._p))' <<<"$1"
}

# The vendor of one issue: "<vendor>" or nothing (hold, or the data rule).
spl_spawn_fill_vendor() {  # SENSITIVE(true|false)
  local out v sens=0
  [[ "$1" == true ]] && sens=1
  if [[ -n "${SPAWN_FILL_MIX_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(LANE_MIX_KIND="${SPAWN_FILL_KIND:-complex_coding}" LANE_MIX_SENSITIVE="$sens" $SPAWN_FILL_MIX_CMD 2>&1)"
  else
    out="$(LANE_MIX_KIND="${SPAWN_FILL_KIND:-complex_coding}" LANE_MIX_SENSITIVE="$sens" \
      timeout "${SPAWN_FILL_TIMEOUT:-60}" bash "$PROJ_PATH/run" -a do_spl_lane_mix 2>&1)"
  fi
  v="$(sed -nE 's/^pick=([a-z]+)( .*)?$/\1/p' <<<"$out" | tail -1)"
  [[ -n "$v" && "$v" != hold ]] || return 0
  [[ "$sens" == 0 || "$v" =~ ^(claude|grok|mistral)$ ]] || return 0
  printf '%s' "$v"
}

# The ask id of KEY: a UUID from its sha1, so a replay is the same ask.
spl_spawn_fill_ask_id() {  # KEY
  local h
  h="$(printf 'spawn-fill:%s' "$1" | sha1sum | cut -c1-32)"
  printf '%s-%s-5%s-a%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# Queue (or, dry, print) each chosen issue.
spl_spawn_fill_queue() {  # CHOSEN PICK HOLDER SWITCH
  local row key class vendor slug id from n=0
  from="$(spl_spawn_place_dispatch)"; from="${from:-$3}"
  while IFS= read -r row; do
    key="$(jq -r .key <<<"$row")"; class="$(jq -r .class <<<"$row")"
    vendor="$(spl_spawn_fill_vendor "$(jq -r .sensitive <<<"$row")")"
    [[ -n "$vendor" ]] || { do_log "INFO skip $key: no vendor ($(jq -r 'if .sensitive then "it names a secret: claude, grok or mistral only, none free" else "the lane mix says hold" end' <<<"$row"))"; continue; }
    slug="fill-${key,,}"; id="$(spl_spawn_fill_ask_id "$key")"
    if [[ "${DRY_RUN:-1}" == 1 ]]; then
      do_log "PLAN would queue $key ($class, $(jq -r '"\(.status), priority \(.priority)"' <<<"$row")) as $vendor:$slug, ask ${id:0:8}, from $from: $(jq -r '.title' <<<"$row" | cut -c1-90)"
      n=$((n + 1)); continue
    fi
    spl_spawn_fill_one "$row" "$2" "$from" "$vendor" "$slug" "$id" && n=$((n + 1))
  done < <(jq -c '.[]' <<<"$1")
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "OK DRY_RUN $n row(s) planned, nothing queued (switch $4; a live run needs DRY_RUN=0 and the switch on)"
  else
    do_log "OK $n row(s) queued; the placer places them"
  fi
}

# One issue: the brief, the ask, the enqueue.
spl_spawn_fill_one() {  # ROW PICK FROM VENDOR SLUG ID
  local dir="${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}" key class out
  key="$(jq -r .key <<<"$1")"; class="$(jq -r .class <<<"$1")"
  { mkdir -p "$dir" && spl_spawn_fill_brief "$1" "$2" "$3" >"$dir/$5.md" && [[ -s "$dir/$5.md" ]]; } ||
    { do_log "WARN $key: the brief $dir/$5.md was not written: not queued"; return 1; }
  out="$(spl_asks_hub put --fleet "$LANE_FLEET" --id "$6" --kind task --role orch --from "$3" \
    --topic "spawn-fill-${key,,}" --summary "SPAWN FILL $key ($class): $(jq -r .title <<<"$1" | cut -c1-140)" 2>&1)" ||
    { do_log "WARN $key: the hub did not take the ask: $(tail -1 <<<"$out" | cut -c1-200)"; return 1; }
  ASK_ID="$6" SPAWN_CLASS="$class" SPAWN_PLACE="$4:$5" ASK_BY="$(spl_asks_holder)" SPAWN_URGENT=0 SPAWN_BYPASS='' \
    do_spl_spawn_enqueue || { do_log "WARN $key: the enqueue failed"; return 1; }
}

# The lane brief of one issue (markdown).
spl_spawn_fill_brief() {  # ROW PICK FROM
  jq -r --argjson pick "$2" --arg from "$3" '
    "# Lane brief: \(.key) \(.title) (one small task, \(.class), from the idle filler)\n",
    "Issue: \(.key)", "Class: \(.class)\n",
    "Queued by do_spl_spawn_fill: \($pick.why). The issue is \(.status), priority \(.priority).",
    "Report your result to \($from) on task spawn-fill-\(.key | ascii_downcase); it judges Done.\n",
    "## 1. The issue\n", (if .description == "" then "(no description: read the title and the code)" else .description end), "",
    "## 2. Build\n",
    "Inspect the real code first. Already fixed, out of date, or it needs an owner decision: build nothing, end the issue with a reason (`LANE_ISSUE_OP=end`, your seed has the command) and report why.",
    "Otherwise fix it in small commits that cite \(.key), with a test that fails before the fix.\n",
    "## 3. Done\n",
    "Landed on origin/master, tests green; the result names the sha, the files and the test counts."' <<<"$1"
}
