#!/bin/bash
# @description The spawn queue's placer, one tick (owner HUM-10, t1 c9beaa77
# @description msg ca668844: "once resources are free they will be just
# @description taken"; rdb 0180). It replaces the orchestrator's hand-kept
# @description queue file and runner loop. Every machine may run it; only the
# @description machine whose agent holds the orch role acts (the same rule as
# @description the asks tick). Each tick, in order:
# @description   1. STALLED - a request the placer took (acked, "placing") and
# @description      not closed within SPAWN_PLACE_LOCK_MIN goes back in line at
# @description      its old place (enqueued_at is set once), before the asks
# @description      tick's own lock timeout could ever re-raise it
# @description   2. ONE AT A TIME - a request the placer launches itself still
# @description      placing: nothing else. A request HANDED to the holder (4b)
# @description      blocks only the asks that need the holder too: the next
# @description      ask the placer can launch (placement + brief file) is placed
# @description      under the same room rules (SPL-2042). A handed request that
# @description      came back (1) waits behind every ask the placer can launch
# @description   3. ROOM - position 1 is taken only when the agent windows on
# @description      this box are below SPOOL_AGENT_CEILING (40), the fleet load
# @description      target does not say hold (do_spl_box_pick) and the gap
# @description      after the last launch ended: SPAWN_PLACE_GAP_FLOOR_MIN (3)
# @description      after it once the placed lane shows progress since the
# @description      launch (its heartbeat's progress_ts, else a metered token
# @description      burn bucket: this box's collector, or the hub's for a lane
# @description      on another box, SPL-3574), else SPAWN_PLACE_GAP_MIN (10)
# @description      after it (no signal = the ceiling). No room: it stays
# @description      queued, one INFO line says why
# @description   0b. WORK GROUPS (SPL-2370) - each group (do_spl_spawn_group_put)
# @description      with fewer than its width N of rows in flight (queued,
# @description      placing or running) gets its next waiting rows into this
# @description      queue, through the path every enqueue takes; from there
# @description      they are rows like any other (bands, bypass, one at a
# @description      time). A row whose lane landed or closed frees its slot
# @description   0. SUPPLY (SPL-1817) - at most once an hour per class: when the
# @description      live share of refactor or bug is under its band and no row of
# @description      that class is queued, the dispatch lease holder gets ONE
# @description      blocker asking for the next rows of that class. Supply
# @description      lead (spec 166 row B3): while do_spl_rhythm_phase says day
# @description      now and night SPAWN_SUPPLY_LEAD_MIN (120) from now, and
# @description      fewer than twice the night's refactor lanes (its band's
# @description      floor of the live lanes) are queued, the refactor blocker
# @description      names the night instead, once per night, so the day's
# @description      planner has rows ready at its start
# @description   3b. BANDS (SPL-1817) - a ci head (CI-red on trunk) or a flagged
# @description      one (urgent bug, owner bypass feature) is taken as it is;
# @description      then a review seat queued on the owner's review-seat GO
# @description      (SPL-3349: in the local bypass log, any class);
# @description      otherwise the queued row of the class furthest under its band
# @description      of the live lanes (do_spl_spawn_share) is taken, a class over
# @description      its band only when no other class waits; ties refactor > bug
# @description      > feature, then the queue's order. The bands are the rhythm
# @description      phase's (spec 166 row B2, do_spl_spawn_share): at night a
# @description      refactor or bug class whose last 24 h share reached its 24 h
# @description      top (capped) waits behind the feature rows, before the
# @description      classes over their band. A 24 h sample is taken when one is
# @description      due (SPAWN_SHARE_SAMPLE_MIN), queue or not. The rule's one
# @description      home: csi-spl-doc/doc/md/fleet-rules-index.md
# @description   4. TAKE - the row is acked by the orch holder (placing), then
# @description      a. with a placement <vendor>:<slug> and its brief file: the
# @description         existing launcher, `spawn-window.sh <vendor> auto
# @description         <SPAWN_PLACE_WORKDIR> <brief> <slug>`; the new id -> done
# @description         "placed: <ID>@<box>" and the sender is told; spawn-window's
# @description         HOLD (exit 10) or a failure -> back in line (a failure
# @description         also tells the holder). The id is any letter of
# @description         SPOOL_AGENT_ID_NEW_RX (o- codex included, SPL-5470); an
# @description         exit 0 with no id read is held, acked, never retried
# @description         (not even by 1. STALLED): one WARN with the output and
# @description         one blocker asks the holder to record it with
# @description         do_spl_spawn_placed. A HOLD's reason (e.g. "waiting:
# @description         claude weekly >= 90% on box-a, box-b", SPL-2035) is kept
# @description         in <asks dir>/.place.wait and do_spl_spawn_queue shows it.
# @description         Only a launch starts the SPAWN_PLACE_GAP_MIN slot
# @description         (.place.last); a hand-off (4b) or a hold burns none:
# @description         a HOLD puts .place.last back as it was (SPL-4265),
# @description         and the tick takes the next row the placer can
# @description         launch, the held one keeping its place, up to
# @description         SPAWN_PLACE_HOLD_TRIES rows a tick. A box that never
# @description         answers a launch pinned to it (spawn-window exit 8 on
# @description         spawn-remote exit 5) holds the same way (SPL-5143):
# @description         the box is tried again once per
# @description         SPAWN_PLACE_DARK_RETRY_MIN, its rows leave the line
# @description         until then, and a row dark for
# @description         SPAWN_PLACE_DARK_ALARM_MIN tells the holder once.
# @description         spawn-window's REFUSED for a vendor CLI the box it
# @description         would start on lacks (exit 13; a pinned box, this box
# @description         on any path that starts here) holds like a HOLD,
# @description         "no box to start <vendor> on: <why>" in .place.wait,
# @description         no blocker (SPL-5397, a-494 on 2026-11-10)
# @description      HAND-PINNED SLUG (SPL-2088), the dispatcher's convention:
# @description         hand-<box>-<slug> or <box>hand-<slug> (box id letters and
# @description         digits only) pins the lane to <box>. Its brief is
# @description         <slug>.md (the full slug's file wins when it exists), the
# @description         launch is `SPAWN_BOX=<box> spawn-window.sh ... <slug>`;
# @description         <box> at or past its overflow mark (do_spl_box_pick's BOX
# @description         line: load% >= high * BOX_PICK_OVERFLOW / 100), DEGRADED, RECOVERING
# @description         or AT CAP -> HOLD: it stays queued, the reason in
# @description         .place.wait, nothing acked; out of the tick's line
# @description         before the head and the band pick, so it blocks no
# @description         other row (SPL-4009)
# @description      UI RULE (owner HUM-10, t1 b61851fb): a mistral placement whose
# @description         brief names csi-spl-wui/ launches claude instead while
# @description         cnf env.box.agent_split.mistral_ui_allowed is not true
# @description         (spl_lane_mix_mistral_ui_off, do_spl_vendor_ui_retest);
# @description         agy when the brief's "Kind:" is specs_and_docs or i18n
# @description         (a review stays cross-vendor to a claude author, SPL-2942).
# @description         A review seat (slug ending -reviewer, or Kind: review)
# @description         stays mistral (SPL-3954, owner msg 594d77e1: mistral may
# @description         review UI work read-only); on a mistral author it is
# @description         refused, handed back to the holder (SPL-3776)
# @description      AGY OUT (SPL-3018): while agy is out on every box (this
# @description         box: agy's banner in the watchdog's pane capture, or an
# @description         S2 kind=limit verdict on an a- lane), a row swapped to agy
# @description         HOLDS when it is a review (brief Kind: review, or
# @description         "review" in its file name or first heading): queued, out
# @description         of the line, the reset in .place.wait; any other such
# @description         row launches claude. A row placed directly as agy:<slug>
# @description         HOLDS too, review or not (SPL-3024): agy was picked on
# @description         purpose, claude would change the vendor. Each box's agy
# @description         is judged alone (SPL-5078): quota (another box's only
# @description         while its lane is live there), or the program or its
# @description         login missing there (spool_vendor_clis). A row holds
# @description         only while every box is out, the line naming each box
# @description      AGY TARGET BOX (SPL-4020, SPL-5078): while any box's agy is
# @description         out (live lane or not), an agy row is judged against the
# @description         box it launches on (a pinned slug's box, else
# @description         do_spl_box_pick's pick with BOX_PICK_KIND=agy): that box
# @description         out -> a box that is in and not full (this box first),
# @description         else HOLD (queued, out of the line, the reason in
# @description         .place.wait); the box judged is the launch's SPAWN_BOX
# @description      BRIEF ON ANOTHER BOX (SPL-3470): a placed row whose brief
# @description         file is not here and whose hub row was last written on
# @description         another box (writer_box: the dispatcher queued it there,
# @description         and briefs are written on the dispatcher's box) HOLDS:
# @description         queued, out of the line, never handed to the holder;
# @description         .place.wait names that box. It is placed by the placer
# @description         on that box once the orch role is there, or here once
# @description         the file is copied here. A row queued from this box
# @description         with no brief here is handed off as below
# @description      CODING RULE (owner HUM-10, t1 b61851fb, msg 91bf8278): a
# @description         mistral placement whose brief's "Kind:" is not
# @description         specs_and_docs or i18n (none counts as coding) launches
# @description         claude instead while cnf
# @description         env.box.agent_split.mistral_coding_allowed is not true
# @description         (spl_lane_mix_mistral_code_off); do_spl_spawn_enqueue
# @description         refuses such a placement up front
# @description      REVIEW SEAT (SPL-3776): a slug ending in -reviewer (or a
# @description         brief Kind: review) writes no code: the coding rule
# @description         never swaps it; a swap onto its author's vendor (an
# @description         Author: line, else every lane id the brief names) is
# @description         refused: handed to the holder, nothing launched
# @description      b. otherwise (no placement, no brief file here, or a brief
# @description         whose epic is done, diss or archived on the hub, SPL-2508:
# @description         the brief needs judgement) the holder gets ONE blocker
# @description         "place ask X now" with the summary and the close command
# @description         (do_spl_spawn_placed); 1 brings it back if it is not placed
# @description      ARCHIVED DISCUSSION (SPL-4955, owner HUM-10 msg 51465f86): a row
# @description         whose discussion or dispatch-<topic8> topic is archived
# @description         on the hub is not placed: declined with the reason, its
# @description         sender and the holder told, the next row taken in the same
# @description         tick. do_spl_archived_followup lists it in a new
# @description         discussion (declined rows only since SPL-5284; the
# @description         issues follow their discussion in the hub). A failed
# @description         read places as before, one WARN.
# @description         A launch writes `Ask-Topic: <topic>` into the brief, the
# @description         lane's binding for do_spl_archived_seats_free
# @description      CATEGORY (spec 143 4.4, SPL-2790): before a launch (4a) the
# @description         brief's "Kind:" and "Category: <path>" are recorded on
# @description         the request (fleet_asks work_kind, category_path) for
# @description         the token rollup by category; a brief without them
# @description         places as before, a refused path is one WARN line
# @description   2a. REVIEW SEATS (SPL-4966, spec 146) - a logged review seat
# @description      (spl_spawn_place_seats) whose brief's first heading says review
# @description      (spl_spawn_place_seat_pass) finishes work already written, so its
# @description      launch carries BOX_PICK_REVIEW_SEAT=1: do_spl_box_pick then
# @description      holds it at cnf env.box.quota.review_seat_max_pct (95, at most
# @description      99), not at weekly_max_pct. At that mark, at 100%, and on every
# @description      other hold (window ceiling, load, disk, cordon, pin, agy out) it
# @description      stays queued like any lane; held SPAWN_PLACE_SEAT_ALARM_MIN (30)
# @description      or more in line, the dispatch lease holder gets ONE blocker naming
# @description      the seat and the hold, #alerts one post with neither
# @description      (spl_spawn_place_seat_alarm)
# @description Installed by do_spl_spawn_place_install_cron (every minute).
# @param SPAWN_PLACE_SEAT_ALARM_MIN (optional) - minutes in line after which a held logged review seat alarms, default 30
# @param SPAWN_PLACE_SEAT_ALARM_GAP_MIN (optional) - minutes between two such alarms at least; a seat due meanwhile goes in the next one, default 30
# @param SPAWN_PLACE_LOCK_MIN (optional) - minutes a placing request may stay unclosed before it goes back in line, default 30
# @param SPAWN_PLACE_GAP_MIN (optional) - minutes between two placements at most (the ceiling), default 10
# @param SPAWN_PLACE_HOLD_TRIES (optional) - rows one tick tries while the launcher answers HOLD (SPL-4265), default 5
# @param SPAWN_PLACE_DARK_RETRY_MIN (optional) - minutes before a box that gave no reply is tried again (SPL-5143), default 30
# @param SPAWN_PLACE_DARK_ALARM_MIN (optional) - minutes a row waits on a silent box before its one blocker to the holder (SPL-5143), default 120
# @param SPAWN_PLACE_GAP_FLOOR_MIN (optional) - minutes between two placements at least, when the placed lane shows progress, default 3
# @param TOKEN_BURN_STATE_DIR (optional) - the token burn collector's state dir, whose buckets.tsv shows a lane's progress on this box, default /var/csi/csi-spl/token-burn
# @param SPAWN_PLACE_ARCHIVED_CMD (optional, tests) - gets a topic id, prints the hub's `lane --archived --topic` answer
# @param SPAWN_PLACE_BURN_CMD (optional, tests) - prints the hub's fleet-tokens answer ({by_agent: [...]}) instead of GET /v1/operator/fleet-tokens
# @param SPOOL_AGENT_CEILING (optional) - the agent window ceiling, default 40
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where <slug>.md (or c001-<slug>.md) is, default <spool root>/dispatch/briefs
# @param SPAWN_PLACE_CNF (optional) - the cnf whose mistral_ui_allowed and mistral_coding_allowed the UI and coding rules read, default <APP_PATH>/csi-spl-cnf/csi-spl/all.env.yaml
# @param SPAWN_PLACE_WORKDIR (optional) - the launcher's WORKDIR, default the checkout this action runs from
# @param SPAWN_PLACE_TMUX_SOCKET (optional) - the box user's tmux socket, default /tmp/tmux-<uid>/default
# @param SPAWN_PLACE_WINDOWS_CMD SPAWN_PLACE_PICK_CMD SPAWN_PLACE_LAUNCH_CMD (optional, tests) - print the window count / the box pick / run the launch
# @param SPAWN_SHARE_SUPPLY_MIN (optional) - minutes between two supply blockers of one class, default 60
# @param SPAWN_SUPPLY_LEAD_MIN (optional) - minutes before the night the supply lead asks for its refactor rows, default 120; 0 = no lead
# @param SPAWN_SHARE_DISPATCH (optional) - the dispatch lease holder <ID>@<box>; default the lease file <spool root>/dispatch/lease
# @param SPAWN_SHARE_LANES_CMD (optional, tests) - as do_spl_spawn_share
# @param SPAWN_PLACE_LOAD_CMD (optional, tests) - prints the lane map's JSON ({load: [...]}) the per-box agy state reads the live boxes and their CLIs from, instead of do_spl_lane_map
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ASKS_HOLDER (optional) - as do_spl_asks_tick
# @param SPAWN_GROUP_DIR SPAWN_GROUP_POLL_MIN SPAWN_GROUP_GRACE_MIN (optional) - as do_spl_spawn_group_put
# @example ./run -a do_spl_spawn_place
# @example SPAWN_PLACE_GAP_MIN=0 ./run -a do_spl_spawn_place

declare -F spl_spawn_group_feed >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-group-put.func.sh"

do_spl_spawn_place() {
  spl_asks_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "INFO no fleet hub here: no spawn queue to place"; return 0; }
  local holder rows head why
  SPAWN_PLACE_SHARE=""
  holder="$(spl_asks_holder)"
  [[ -n "$holder" ]] || { do_log "INFO nobody holds the orch role right now: nothing placed"; return 0; }
  [[ "${holder##*@}" == "$ASKS_BOX" ]] || { do_log "INFO the orch role is held on ${holder##*@} ($holder): its machine places"; return 0; }
  exec 6>>"$(spool_asks_dir)/.place.lock"
  flock -n 6 || { do_log "INFO another placer tick is running: skipped"; return 0; }
  spl_spawn_group_feed "$holder"
  rows="$(spl_spawn_q_rows)" || { do_log "WARN the hub did not answer: nothing placed this tick"; return 0; }
  if spl_spawn_place_stalled "$holder" "$rows"; then
    rows="$(spl_spawn_q_rows)" || return 0
  fi
  spl_spawn_place_supply "$holder" "$rows"
  rows="$(spl_spawn_place_mark "$rows")"
  spl_spawn_place_seat_alarm "$holder" "$rows"
  spl_spawn_place_dark_alarm "$holder" "$rows"
  if jq -e 'any(.[]; .state == "acked" and ._l and (._h | not))' >/dev/null <<<"$rows"; then
    do_log "INFO placing $(jq -r '[.[] | select(.state == "acked") | .ask_id[0:8]] | join(" ")' <<<"$rows"): one at a time, $(jq '[.[] | select(.state == "queued")] | length' <<<"$rows") queued"
    return 0
  fi
  rows="$(spl_spawn_place_agy_hold "$rows")"
  rows="$(spl_spawn_place_away_hold "$rows")"
  rows="$(spl_spawn_place_pin_hold "$rows")"
  rows="$(spl_spawn_place_agy_box_hold "$rows")"
  rows="$(spl_spawn_place_dark_hold "$rows")"
  rows="$(spl_spawn_place_line "$rows")"
  spl_spawn_place_band_sample
  head="$(jq -c '.[0] // empty' <<<"$rows")"
  [[ -n "$head" ]] || { do_log "INFO the spawn queue is empty, or holds only asks for the holder while one is with it"; return 0; }
  if why="$(spl_spawn_place_no_room)"; then
    do_log "INFO hold: $why; ask $(jq -r '.ask_id[0:8]' <<<"$head") stays position $(jq -r '"\(.position) of \(.queue_len)"' <<<"$head")"
    return 0
  fi
  head="$(spl_spawn_place_band "$head" "$rows")"
  spl_spawn_place_take_next "$holder" "$head" "$rows"
}

# 4. Takes HEAD; while the launcher answers HOLD (10), the next row of LINE
# the placer can launch, up to SPAWN_PLACE_HOLD_TRIES rows. A held row keeps
# its place. Before, one held grok head stopped 40 rows on sat for over an
# hour (2026-10-29, SPL-4265).
spl_spawn_place_take_next() {  # HOLDER HEAD LINE
  local head="$2" rows="$3" n=1 rc
  while :; do
    rc=0
    spl_spawn_place_take "$1" "$(jq -c 'del(._l, ._h)' <<<"$head")" || rc=$?
    (( rc == 10 && n < ${SPAWN_PLACE_HOLD_TRIES:-5} )) || return 0
    rows="$(jq -c --arg i "$(jq -r '.ask_id' <<<"$head")" '[.[] | select(._l and .ask_id != $i)]' <<<"$rows")"
    rows="$(spl_spawn_place_dark_hold "$rows")"
    head="$(jq -c '.[0] // empty' <<<"$rows")"
    [[ -n "$head" ]] || return 0
    head="$(spl_spawn_place_band "$head" "$rows")"
    n=$((n + 1))
  done
}

# 2. Marks each row: _l = the placer can launch it (a placement and its brief
# file here), _h = it was handed to the holder (<asks dir>/.place.handed, one
# ask_id per line, pruned to the rows still in line). The .place.wait lines of
# asks no longer in the queue are pruned too (SPL-3138).
spl_spawn_place_mark() {  # ROWS
  local f id slug launchable=() handed=()
  spl_spawn_place_wait_keep queued "$(jq -r '.[].ask_id' <<<"$1")"
  f="$(spool_asks_dir)/.place.handed"
  while IFS=$'\t' read -r id slug; do
    [[ -n "$(spl_spawn_place_brief "$slug")" ]] && launchable+=("$id")
  done < <(jq -r '.[] | select((.placement // "") != "") | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")
  [[ -r "$f" ]] && mapfile -t handed < <(grep -xF -f <(jq -r '.[].ask_id' <<<"$1") "$f" | sort -u)
  if { (( ${#handed[@]} == 0 )) || printf '%s\n' "${handed[@]}"; } >"$f.$$"; then mv -f "$f.$$" "$f"; else rm -f "$f.$$"; fi
  jq -c --argjson l "$(spl_spawn_place_json_ids "${launchable[@]}")" --argjson h "$(spl_spawn_place_json_ids "${handed[@]}")" \
    '[.[] | .ask_id as $i | . + {_l: ($l | index($i) != null), _h: ($h | index($i) != null)}]' <<<"$1"
}

# The arguments as a JSON array of strings.
spl_spawn_place_json_ids() {  # ID...
  (( $# > 0 )) || { printf '[]'; return 0; }
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(. != ""))'
}

# 2b. The queued rows that may be taken this tick, in queue order. An ask
# with the holder (handed, acked) blocks nothing the placer can launch
# itself: only those are in line. A handed ask that came back (stalled)
# waits behind every ask the placer can launch.
spl_spawn_place_line() {  # MARKED ROWS
  local held
  held="$(jq -r '[.[] | select(.state == "acked") | .ask_id[0:8]] | join(" ")' <<<"$1")"
  [[ -z "$held" ]] || do_log "INFO ask $held is with the holder: placing only an ask the placer launches itself, $(jq '[.[] | select(.state == "queued" and ._l)] | length' <<<"$1") of $(jq '[.[] | select(.state == "queued")] | length' <<<"$1") queued" >&2
  jq -c 'any(.[]; .state == "acked") as $held | any(.[]; .state == "queued" and ._l) as $any_l
    | [.[] | select(.state == "queued")
       | select(if $held then ._l elif $any_l then ._l or (._h | not) else true end)]
    | sort_by(.position)' <<<"$1"
}

# 0. The supply blocker: refactor or bug under the owner's 24 h band floor
# (SPL_SPAWN_BANDS, the share's .h24; not the phase band), nothing of it
# queued -> ONE blocker to the dispatch lease holder per class per
# SPAWN_SHARE_SUPPLY_MIN. In the supply lead the refactor blocker is the
# lead's (spl_spawn_place_supply_lead). Leaves the share it read in
# SPAWN_PLACE_SHARE.
spl_spawn_place_supply() {  # HOLDER ROWS
  local d c due=() gap=$(( ${SPAWN_SHARE_SUPPLY_MIN:-60} * 60 )) now share to line night
  d="$(spool_asks_dir)"; now="$(date +%s)"
  for c in refactor bug; do
    (( now - $(stat -c %Y "$d/.share.$c.last" 2>/dev/null || echo 0) >= gap )) && due+=("$c")
  done
  (( ${#due[@]} > 0 )) || return 0
  share="$(spl_spawn_share)" || { do_log "WARN the live share could not be read: no supply check this tick"; return 0; }
  SPAWN_PLACE_SHARE="$share"
  (( $(jq '.known' <<<"$share") > 0 )) || return 0
  for c in "${due[@]}"; do
    if [[ "$c" == refactor ]] && night="$(spl_spawn_place_supply_lead "$d")"; then
      spl_spawn_place_supply_lead_send "$1" "$2" "$share" "$night" && continue
    fi
    line="$(jq -r --arg c "$c" --slurpfile rows <(printf '%s' "$2") '
      def cls: (.class // "") | if . == "" or . == "ci" then "bug" else . end;
      .by[$c] as $b | (.h24.by[$c].lo // $b.lo) as $lo
      | select($b.pct < $lo and ([$rows[0][] | select(.state == "queued" and cls == $c)] | length) == 0)
      | "\($c) share \($b.pct)% < \($lo)% (\($b.n) of \(.known) live lanes with a class) and no \($c) row is queued"' <<<"$share")"
    [[ -n "$line" ]] || continue
    to="$(spl_spawn_place_dispatch)"
    [[ -n "$to" ]] || { do_log "WARN $line, and nobody holds the dispatch lease: not told"; continue; }
    if spl_spawn_q_send "$1" "$to" note spawn-share "**SPAWN SHARE: $line.** Request the next $c rows (a $c round / its rows) and queue them with \`SPAWN_CLASS=$c ./run -a do_spl_spawn_enqueue\`. The bands: fleet-rules-index.md (owner msg 8cb6cc7d); the report: \`./run -a do_spl_spawn_share\`."; then
      touch "$d/.share.$c.last"
      do_log "OK supply: $line; $to told"
    fi
  done
}

# 0b. The supply lead (spec 166 row B3, section 4.3): prints the night's
# date (UTC, of its start) and returns 0 when do_spl_rhythm_phase says day
# at RHYTHM_NOW and night SPAWN_SUPPLY_LEAD_MIN later, and DIR's
# .share.refactor.lead does not already name that night. No hour arithmetic
# here: the phase decides.
spl_spawn_place_supply_lead() {  # ASKS_DIR
  local lead="${SPAWN_SUPPLY_LEAD_MIN:-120}" t later night
  [[ "$lead" =~ ^[0-9]+$ ]] && (( lead > 0 )) || return 1
  t="$(spl_spawn_share_now)"; later=$(( t + lead * 60 ))
  night="$(date -u -d "@$later" +%F)" || return 1
  [[ "$(cat "$1/.share.refactor.lead" 2>/dev/null)" != "$night" ]] || return 1
  [[ "$(RHYTHM_NOW="@$t" do_spl_rhythm_phase 2>/dev/null)" == day ]] || return 1
  [[ "$(RHYTHM_NOW="@$later" do_spl_rhythm_phase 2>/dev/null)" == night ]] || return 1
  printf '%s' "$night"
}

# The supply lead's blocker: fewer than twice the night's refactor lanes
# (the night band's floor, SPL_SPAWN_BANDS_NIGHT, of the known live lanes,
# at least 1) queued -> ONE blocker naming NIGHT, stamped for the night and
# as the hourly refactor blocker. Returns 1 when enough rows are queued (the
# hourly check then runs as by day) or the blocker could not be sent.
spl_spawn_place_supply_lead_send() {  # HOLDER ROWS SHARE NIGHT
  local d line to
  d="$(spool_asks_dir)"
  line="$(jq -r --argjson nb "$SPL_SPAWN_BANDS_NIGHT" --slurpfile rows <(printf '%s' "$2") '
      def cls: (.class // "") | if . == "" or . == "ci" then "bug" else . end;
      ((.known * $nb.refactor[0] + 99) / 100 | floor | if . < 1 then 1 else . end) as $m
      | ([$rows[0][] | select(.state == "queued" and cls == "refactor")] | length) as $q
      | select($q < 2 * $m)
      | "\($q) refactor row(s) queued, fewer than 2 x \($m) (the night band floor \($nb.refactor[0])% of \(.known) live lanes with a class)"' <<<"$3")"
  [[ -n "$line" ]] || return 1
  to="$(spl_spawn_place_dispatch)"
  [[ -n "$to" ]] || { do_log "WARN supply lead: the night of $4 starts within ${SPAWN_SUPPLY_LEAD_MIN:-120} min, $line, and nobody holds the dispatch lease: not told"; return 0; }
  spl_spawn_q_send "$1" "$to" note spawn-share "**SPAWN SUPPLY LEAD: the night of $4 starts within ${SPAWN_SUPPLY_LEAD_MIN:-120} min (do_spl_rhythm_phase) and $line.** Request the next refactor rows now (a round's planner runs by day, its rows at night: rounds-rulebook.md 1.4) and queue them with \`SPAWN_CLASS=refactor ./run -a do_spl_spawn_enqueue\`, so they are ready when the night starts. The night bands: spec 166 section 3.1; the report: \`./run -a do_spl_spawn_share\`." || return 1
  touch "$d/.share.refactor.last"
  printf '%s\n' "$4" >"$d/.share.refactor.lead"
  do_log "OK supply lead: the night of $4, $line; $to told"
}

# The dispatch lease holder as <ID>@<box>, or nothing.
spl_spawn_place_dispatch() {
  local h="${SPAWN_SHARE_DISPATCH:-}"
  [[ -n "$h" ]] || { [[ -r "$SPOOL_ROOT/dispatch/lease" ]] && read -r h _ <"$SPOOL_ROOT/dispatch/lease"; }
  case "$h" in none@*|unknown:*|'') return 0 ;; *@*) ;; *) h="$h@$ASKS_BOX" ;; esac
  [[ "$h" =~ ^${SPOOL_PARTICIPANT_RX}@[a-z0-9][a-z0-9-]{0,31}$ ]] && printf '%s' "$h"
  return 0
}

# 3b. The row the bands pick, HEAD when it is ci or flagged, a review seat on
# the owner's review-seat GO next, or HEAD when the share cannot be read (the
# hub's order holds). The share goes to jq as a file, never argv: its bypass
# list is over one argument's 128 KiB (171 KB on sat 2026-10-29, SPL-4156).
spl_spawn_place_band() {  # HEAD ROWS
  local share pick
  if jq -e '(.class // "") == "ci" or (.flag // "") != ""' >/dev/null <<<"$1"; then printf '%s' "$1"; return 0; fi
  pick="$(spl_spawn_place_seat "$2")"
  if [[ -n "$pick" ]]; then
    do_log "INFO review-seat pick: ask $(jq -r '"\(.ask_id[0:8]) (\(.class // "") \(.placement), queue position \(.position))"' <<<"$pick") on owner GO ${SPL_SPAWN_REVIEW_SEAT_GO:0:8}, ahead of the bands" >&2
    printf '%s' "$pick"; return 0
  fi
  share="${SPAWN_PLACE_SHARE:-}"
  [[ -n "$share" ]] || share="$(spl_spawn_share)" || { do_log "WARN the live share could not be read: the queue's order holds" >&2; printf '%s' "$1"; return 0; }
  pick="$(jq -c --slurpfile share <(printf '%s' "$share") '
    def cls: (.class // "") | if . == "" or . == "ci" then "bug" else . end;
    $share[0] as $share | [.[] | select(.state == "queued") | cls as $c | $share.by[$c] as $b
     | (if $b.pct < $b.lo then 0 elif $c == "feature" or $b.pct < $b.hi then 1 else 3 end) as $t0
     | (if ($b.capped // false) and $t0 < 2 then 2 else $t0 end) as $t
     | . + {_t: $t, _o: ({"refactor": 0, "bug": 1, "feature": 2}[$c]), _c: $c, _p: $b.pct,
            _s: (if $t == 0 then ($b.lo - $b.pct) / $b.lo elif $t == 1 and $c != "feature" then ($b.hi - $b.pct) / $b.hi else 0 end)}]
    | sort_by(._t, -._s, ._o, .position) | .[0] // empty' <<<"$2")"
  [[ -n "$pick" ]] || { printf '%s' "$1"; return 0; }
  do_log "INFO band pick: ask $(jq -r '"\(.ask_id[0:8]) (\(._c) at \(._p)%, queue position \(.position))"' <<<"$pick") of $(spl_spawn_share_line "$share")" >&2
  jq -c 'del(._t, ._o, ._c, ._p, ._s)' <<<"$pick"
}

# 3b. A 24 h sample of the live share when one is due, so the samples do not
# depend on a row waiting; the share is kept for the band pick.
spl_spawn_place_band_sample() {
  [[ -z "${SPAWN_PLACE_SHARE:-}" ]] && spl_spawn_share_sample_due || return 0
  SPAWN_PLACE_SHARE="$(spl_spawn_share)" || { SPAWN_PLACE_SHARE=""; do_log "WARN the live share could not be read: no 24 h sample this tick"; }
  return 0
}

# 3b. The first logged review seat of ROWS by position, nothing when none.
spl_spawn_place_seat() {  # ROWS
  jq -c '.[0] // empty' <<<"$(spl_spawn_place_seats "$1")"
}

# The logged review seats of ROWS by position, a JSON array: queued, placement
# slug ending in -reviewer, ask in the local bypass log on the review-seat GO.
# The hub keeps such a row unflagged (a bypass is a feature flag there, rdb
# 0195), so the log is its record (spl_spawn_q_enqueue). The ids go to jq as a
# file: the log only grows (SPL-4156).
spl_spawn_place_seats() {  # ROWS
  local f
  f="$(spool_asks_dir)/bypass.tsv"
  [[ -s "$f" ]] || { echo '[]'; return 0; }
  declare -F spl_spawn_q_review_seat_go >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-enqueue.func.sh"
  jq -c --slurpfile ids <(awk -F'\t' -v m="$SPL_SPAWN_REVIEW_SEAT_GO" '$3 == m { print $2 }' "$f" | jq -R -s -c 'split("\n") | map(select(length > 0))') \
    '$ids[0] as $ids | [.[] | select(.state == "queued" and ((.placement // "") | sub("^[^:]*:"; "") | test("-reviewer$"))
    and (.ask_id as $a | $ids | index($a)))] | sort_by(.position)' <<<"$1"
}

# 2a. May this logged seat pass the weekly hold? Its first "# " heading says review,
# reviewer or R7. The slug alone logs a row by itself (spl_spawn_q_enqueue), so a
# coding lane named -reviewer would pass. All 984 *-reviewer.md briefs on sat say it
# (11-07). "Kind:" cannot be the check: 3 of them carry review, 171 complex_coding.
# This stops a wrong name, not a forged heading: nothing proves a lane only reads.
spl_spawn_place_seat_pass() {  # BRIEF
  grep -qiE '\b(review|reviewer|R7)\b' <<<"$(grep -m1 '^# ' "$1" 2>/dev/null)"
}

# 2a. A logged review seat under a hold: on 11-06 three R7 seats waited 320-406
# min under the weekly hold and their authors sat on written work (spec 146,
# what-broke-20261106 3.2). A seat SPAWN_PLACE_SEAT_ALARM_MIN (30) or more in line
# (wait_s: enqueued_at, kept across a re-queue) that a hold stops alarms ONCE per
# ask: one blocker to the dispatch lease holder (none: HOLDER), one #alerts post.
# The post is ask id8, minutes and count, nothing read from a row or a hold: every
# human of the tenant reads #alerts, a slug can name a customer, and a hold line can
# hold the slug, a brief path or a box (spl_spawn_place_away_hold, _pin_hold).
# The hold is its .place.wait line (a launcher HOLD, a pin, agy out, a brief on
# another box), else the room check without its gap: the gap is a pace, no hold.
# Time in line alone is no alarm: 209 of 412 logged seats since 10-31 took 30 min
# or more from log to close (journal updated_at, an upper bound). At most one
# alarm per SPAWN_PLACE_SEAT_ALARM_GAP_MIN; a seat due meanwhile goes in the next.
# Neither channel took it: retried next tick. Never stops the tick.
spl_spawn_place_seat_alarm() {  # HOLDER MARKED_ROWS
  local d f now gap=$(( ${SPAWN_PLACE_SEAT_ALARM_GAP_MIN:-30} * 60 )) id place min why room="" to text post tail ok=0 lines="" plines="" fired=() out
  d="$(spool_asks_dir)"; f="$d/.place.seat-alarm"; now="$(date +%s)"
  (( now - $(stat -c %Y "$f.last" 2>/dev/null || echo 0) >= gap )) || return 0
  [[ -e "$f" ]] || : >"$f"
  grep -xF -f <(jq -r '.[].ask_id' <<<"$2") "$f" 2>/dev/null | sort -u >"$f.$$"; mv -f "$f.$$" "$f"
  while IFS=$'	' read -r id place min; do
    why="$(awk -F'	' -v i="$id" '$1 == i { print $3; exit }' "$d/.place.wait" 2>/dev/null)"
    if [[ -z "$why" ]]; then
      [[ -n "$room" ]] || room="$(SPAWN_PLACE_GAP_MIN=0 spl_spawn_place_no_room)" || room="-"
      [[ "$room" != - ]] || continue
      why="$room"
    fi
    lines+=$'
'"- ask ${id:0:8} ($place), $min min in line: $why"
    plines+=$'
'"- ask ${id:0:8}, $min min in line"
    fired+=("$id")
  done < <(spl_spawn_place_seats "$2" | jq -r --argjson s "$(( ${SPAWN_PLACE_SEAT_ALARM_MIN:-30} * 60 ))" --rawfile seen "$f" '
    ($seen | split("
")) as $d | .[] | select((.wait_s // 0) >= $s and (.ask_id as $a | $d | index($a) | not))
    | "\(.ask_id)	\(.placement)	\(.wait_s / 60 | floor)"')
  (( ${#fired[@]} > 0 )) || return 0
  tail="A logged seat passes a weekly hold below env.box.quota.review_seat_max_pct, never at 100%; no other hold is passed. The queue: \`./run -a do_spl_spawn_queue\`."
  text="**SPAWN QUEUE: ${#fired[@]} review seat(s) held ${SPAWN_PLACE_SEAT_ALARM_MIN:-30} min or more, and their authors wait on them.**"
  post="$text$plines"$'

'"The dispatch lease holder has the seat and the hold in a blocker. $tail"
  text+="$lines"$'

'"$tail"
  to="$(spl_spawn_place_dispatch)"
  spl_spawn_q_send "$1" "${to:-$1}" blocker spawn-queue "$text" && ok=1
  if out="$(spl_asks_alert_post "${1%@*}" "$post" 6>&-)"; then ok=1; else do_log "WARN the review-seat alarm did not post in #alerts: ${out:0:200}"; fi
  (( ok == 1 )) || { do_log "WARN the review-seat alarm reached nobody: retried next tick"; return 0; }
  printf '%s
' "${fired[@]}" >>"$f"
  touch "$f.last"
  do_log "ALERT review seat(s) held:$(tr '
' ' ' <<<"$lines")"
}

# 1. Placing requests quiet SPAWN_PLACE_LOCK_MIN go back in line, but for a
# launch that exited 0 with no id read (spl_spawn_place_unread). 0 = one did.
spl_spawn_place_stalled() {  # HOLDER ROWS
  local id n=0 lock=$(( ${SPAWN_PLACE_LOCK_MIN:-30} * 60 )) unread
  unread="$(spl_spawn_place_unread_keep "$2")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    spl_spawn_q_op queue "$id" "$1" >/dev/null || continue
    do_log "INFO ask ${id:0:8} was not placed within ${SPAWN_PLACE_LOCK_MIN:-30} min: back in line at its place"
    n=$((n + 1))
  done < <(jq -r --argjson l "$lock" --argjson u "$unread" '.[] | select(.state == "acked" and .quiet_s >= $l
    and (.ask_id as $i | $u | index($i) | not)) | .ask_id' <<<"$2")
  (( n > 0 ))
}

# <asks dir>/.place.unread pruned to the asks of ROWS, printed as a JSON array.
spl_spawn_place_unread_keep() {  # ROWS
  local f ids=()
  f="$(spool_asks_dir)/.place.unread"
  [[ -s "$f" ]] || { printf '[]'; return 0; }
  mapfile -t ids < <(grep -xF -f <(jq -r '.[].ask_id' <<<"$1") "$f" | sort -u)
  if { (( ${#ids[@]} == 0 )) || printf '%s\n' "${ids[@]}"; } >"$f.$$"; then mv -f "$f.$$" "$f"; else rm -f "$f.$$"; fi
  spl_spawn_place_json_ids "${ids[@]}"
}

# 3. Prints why there is no room and returns 0; returns 1 when there is room.
spl_spawn_place_no_room() {
  local n ceil="${SPOOL_AGENT_CEILING:-40}" pick
  n="$(spl_spawn_place_windows)"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf 'the agent windows could not be counted'; return 0; }
  (( n < ceil )) || { printf 'agent windows %s >= the ceiling %s' "$n" "$ceil"; return 0; }
  spl_spawn_place_gap_hold && return 0
  pick="$(spl_spawn_place_pick)"
  [[ "$pick" == hold* ]] && { printf 'the fleet load target says %s' "$pick"; return 0; }
  SPAWN_PLACE_ROOM="windows $n/$ceil, load pick ${pick:-unknown}"
  return 1
}

# The gap after a launch (SDLC row 06): prints why and returns 0 while it
# holds. It ends SPAWN_PLACE_GAP_FLOOR_MIN (3) after the launch once the
# placed lane (<asks dir>/.place.agent, written by its launch) shows progress
# since the launch (spl_spawn_place_progress), else at SPAWN_PLACE_GAP_MIN
# (10). No progress signal at all, or a failed launch (no .place.agent newer
# than .place.last), holds to the ceiling.
spl_spawn_place_gap_hold() {
  local d last now agent="" ceil=$(( ${SPAWN_PLACE_GAP_MIN:-10} * 60 )) floor=$(( ${SPAWN_PLACE_GAP_FLOOR_MIN:-3} * 60 ))
  d="$(spool_asks_dir)"; now="$(date +%s)"
  last="$(stat -c %Y "$d/.place.last" 2>/dev/null || echo 0)"
  (( now - last >= ceil )) && return 1
  (( floor > ceil )) && floor=$ceil
  (( now - last < floor )) && { printf 'the last placement started under %s min ago (the floor)' "${SPAWN_PLACE_GAP_FLOOR_MIN:-3}"; return 0; }
  if (( $(stat -c %Y "$d/.place.agent" 2>/dev/null || echo 0) >= last )); then
    agent="$(head -1 "$d/.place.agent" 2>/dev/null)"
    [[ "$agent" =~ ^${SPOOL_AGENT_ID_NEW_RX}(@[a-z0-9-]+)?$ ]] || agent=""
  fi
  [[ -n "$agent" ]] && spl_spawn_place_progress "$agent" "$last" && return 1
  printf 'the last placement started under %s min ago and %s has no heartbeat or token-burn progress since' "${SPAWN_PLACE_GAP_MIN:-10}" "${agent:-its lane}"
  return 0
}

# 0 when the lane AGENT (<ID>[@<box>]) shows progress since the epoch LAST,
# by the first signal it really produces (SPL-3574):
#   1. its heartbeat.json progress_ts (spool-agent-hook.sh; claude and the
#      hooked vendors), read on this box only;
#   2. token burn: a metered bucket (tokens > 0, the model answered) whose
#      minute ends after LAST. agy writes no heartbeat, but the box's token
#      burn collector meters its brain transcript per lane id
#      (spl-token-burn-collect.func.sh). On this box: the collector's
#      <TOKEN_BURN_STATE_DIR>/buckets.tsv; for a lane on another box: the
#      hub's GET /v1/operator/fleet-tokens by_agent row of <box, ID>
#      (spl_spawn_place_burn_hub), where every box pushes its buckets.
# A pane that is only alive (an unmetered sample) is no progress.
spl_spawn_place_progress() {  # AGENT LAST
  local id="${1%@*}" box="${ASKS_BOX:-}" ts f
  [[ "$1" == *@* ]] && box="${1#*@}"
  if [[ "$box" == "${ASKS_BOX:-}" ]]; then
    ts="$(jq -r '.progress_ts // empty' "$SPOOL_ROOT/$id/heartbeat.json" 2>/dev/null)"
    [[ -n "$ts" ]] && (( $(spl_spawn_place_epoch "$ts") >= $2 )) && return 0
    f="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}/buckets.tsv"
    [[ -r "$f" ]] || return 1
    awk -F'\t' -v a="$id" -v t="$2" '$1 == a && $4 + 60 > t && $5 + $6 + $7 + $8 > 0 { ok = 1 } END { exit !ok }' "$f"
    return
  fi
  ts="$(spl_spawn_place_burn_hub | jq -r --arg a "$id" --arg b "$box" \
    '[.by_agent[]? | select(.agent_id == $a and .box == $b and .is_metered == true) | .last_active] | max // empty' 2>/dev/null)"
  [[ -n "$ts" ]] && (( $(spl_spawn_place_epoch "$ts") + 60 > $2 ))
}

# An ISO-8601 UTC stamp (or an epoch) as an epoch; 0 when it is neither.
spl_spawn_place_epoch() {  # TS
  if [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then date -u -d "$1" +%s 2>/dev/null || echo 0
  elif [[ "$1" =~ ^[0-9]+$ ]]; then echo "$1"
  else echo 0; fi
}

# The hub's token burn of the last hour (GET /v1/operator/fleet-tokens), as
# the env's project service account (do_gcp_pin_account, never the owner
# account), in a subshell so the pinned gcloud config stays in it. Empty when
# this machine has no hub cnf (spl_lane_init did not resolve one) or the hub
# did not answer 200: the gap then holds as before. SPAWN_PLACE_BURN_CMD
# (tests) prints the answer instead.
spl_spawn_place_burn_hub() {
  if [[ -n "${SPAWN_PLACE_BURN_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPAWN_PLACE_BURN_CMD 2>/dev/null; return 0
  fi
  [[ -z "${LANE_HUB_CMD:-}" && -n "${SPL_CNF:-}" && -n "${SPL_HUB_URL:-}" ]] || return 0
  (
    do_gcp_pin_account "$SPL_CNF" >/dev/null 2>&1 || exit 0
    spl_hub_operator_call GET '/v1/operator/fleet-tokens?window=1h' >/dev/null 2>&1 || exit 0
    [[ "$SPL_HUB_OP_STATUS" == 200 ]] && printf '%s' "$SPL_HUB_OP_BODY"
  )
}

# The agent windows on this box (the fleet's ceiling count).
spl_spawn_place_windows() {
  if [[ -n "${SPAWN_PLACE_WINDOWS_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPAWN_PLACE_WINDOWS_CMD; return
  fi
  local sock="${SPAWN_PLACE_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}" names
  names="$(tmux -S "$sock" list-windows -a -F '#{window_name}' 2>/dev/null)" || return 0
  grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)' <<<"$names"
}

# The fleet load target's pick: "<box> ..." or "hold ...", "" when it said nothing.
spl_spawn_place_pick() {
  sed -n 's/^pick=//p' <<<"$(spl_spawn_place_pick_out)" | tail -1
}

# do_spl_box_pick's whole output: one BOX line per box, then the pick line.
spl_spawn_place_pick_out() {
  if [[ -n "${SPAWN_PLACE_PICK_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPAWN_PLACE_PICK_CMD 2>&1
  else
    timeout "${SPAWN_PLACE_TIMEOUT:-60}" bash "$PROJ_PATH/run" -a do_spl_box_pick 2>&1
  fi
}

# A hand-pinned slug (SPL-2088): hand-<box>-<slug> or <box>hand-<slug> ->
# two lines "<box>" "<slug>"; any other slug -> "" "<slug>".
spl_spawn_place_slug() {  # SLUG
  if [[ "$1" =~ ^hand-([a-z0-9]+)-(.+)$ || "$1" =~ ^([a-z0-9]+)hand-(.+)$ ]]; then
    printf '%s\n%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '\n%s\n' "$1"
  fi
}

# Prints why the pinned BOX takes no lane now and returns 0: its BOX line is at
# or past its overflow mark, CORDONED, DEGRADED, RECOVERING or AT CAP. No line for it: returns 1
# (spawn-window judges it). PICK_OUT is do_spl_box_pick's output when the caller
# already read it.
spl_spawn_place_pin_full() {  # BOX [PICK_OUT]
  local line out="${2-}"
  [[ -n "$out" ]] || out="$(spl_spawn_place_pick_out)"
  line="$(grep -E "^BOX $1 " <<<"$out" | tail -1)"
  [[ -n "$line" ]] || return 1
  awk -v b="$1" -v over="${BOX_PICK_OVERFLOW:-200}" '{
    for (i = 1; i <= NF; i++) {
      if (!seen && $i ~ /^[0-9]+%$/) { p = $i + 0; seen = 1 }
      if ($i == "band") { split($(i + 1), h, "[.][.]"); hi = h[2] + 0 }
    }
    if (/  CORDONED /) { printf "box %s is CORDONED (do_spl_box_cordon)", b; exit 0 }
    if (/DEGRADED/) { printf "box %s is DEGRADED", b; exit 0 }
    if (match($0, /RECOVERING \([^)]*\)/)) { printf "box %s is %s: no new lanes until its hold ends", b, substr($0, RSTART, RLENGTH); exit 0 }
    if (/AT CAP/) { printf "box %s is at its CI-busy agent cap", b; exit 0 }
    if (seen && hi > 0 && p >= hi * over / 100) { printf "box %s at %d%% is past its overflow mark (%d%%, %d%% of its high %d%%)", b, p, hi * over / 100, over, hi; exit 0 }
    exit 1 }' <<<"$line"
}

# 4. Take the head: placing, then launch it or hand it to the holder. A head
# pinned to a full box never gets here (spl_spawn_place_pin_hold). Returns 10
# when the launcher says HOLD: .place.last is then put back as it was, a hold
# burns no gap slot (SPL-4265).
spl_spawn_place_take() {  # HOLDER HEAD
  local holder="$1" id place brief vendor closed="" ps=() last prev rc=0
  spl_spawn_place_drop_archived "$holder" "$2" && return 10
  id="$(jq -r '.ask_id' <<<"$2")"
  place="$(jq -r '.placement // ""' <<<"$2")"
  mapfile -t ps < <(spl_spawn_place_slug "${place#*:}")
  brief="$(spl_spawn_place_brief "${place#*:}")"
  [[ -z "$place" || -z "$brief" ]] || closed="$(spl_spawn_place_epic_closed "$brief")"
  [[ "$closed" != *$'\t'auto-closed ]] || closed="$(spl_spawn_place_reopen "$brief" "${place#*:}" "${closed%$'\t'auto-closed}")"
  [[ -n "$closed" || -z "$place" || -z "$brief" ]] || closed="$(spl_spawn_place_no_links "$2" "$brief")"
  spl_spawn_q_op ack "$id" "$holder" >/dev/null || return 0
  if [[ -n "$place" && -n "$brief" && -z "$closed" ]] && ! vendor="$(spl_spawn_place_vendor "${place%%:*}" "$brief" "$id")"; then
    spl_spawn_place_hand "$holder" "$2" "$vendor"
  elif [[ -n "$place" && -n "$brief" && -z "$closed" ]]; then
    last="$(spool_asks_dir)/.place.last"
    prev="$(stat -c %Y "$last" 2>/dev/null)"
    touch "$last"
    spl_spawn_place_category "$holder" "$id" "$brief"
    spl_spawn_place_launch "$holder" "$2" "$vendor" "${ps[1]}" "$brief" "${ps[0]:-$(jq -r '._b // ""' <<<"$2")}" || rc=$?
    (( rc == 10 )) || return "$rc"
    if [[ -n "$prev" ]]; then touch -d "@$prev" "$last"; else rm -f "$last"; fi
    return 10
  else
    spl_spawn_place_hand "$holder" "$2" "$(if [[ -n "$closed" ]]; then echo "$closed"; elif [[ -z "$place" ]]; then echo "no placement was recorded"; else echo "no brief file for ${place#*:} under ${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}"; fi)"
  fi
}

# The topic a row works for, for the archive read: its discussion (a full or
# an 8-hex id), else its topic when that is a full id or dispatch-<topic8>;
# nothing for any other task name.
spl_spawn_place_row_topic() {  # ROW
  local t
  t="$(jq -r '.discussion // ""' <<<"$1")"
  [[ "$t" =~ ^[0-9a-f]{8}((-[0-9a-f]{4}){3}-[0-9a-f]{12})?$ ]] && { printf '%s' "$t"; return 0; }
  t="$(jq -r '.topic // ""' <<<"$1")"
  if [[ "$t" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]]; then printf '%s' "$t"
  elif [[ "$t" =~ ^dispatch-([0-9a-f]{8})$ ]]; then printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# SPL-4955: 0 when ROW's discussion is archived, so it must not be placed. The
# row is declined with the reason and its sender and the holder told; a decline
# the hub refused still returns 0 and the next tick tries again. A row with no
# topic, a live topic or a failed read returns 1 (t1 2e46fcb6: archived
# 11-01 08:59Z, its queued row 1bd6c305 placed 11-06 23:42Z as c-702).
spl_spawn_place_drop_archived() {  # HOLDER ROW
  local topic out at id8 why row
  topic="$(spl_spawn_place_row_topic "$2")"
  [[ -n "$topic" ]] || return 1
  if [[ -n "${SPAWN_PLACE_ARCHIVED_CMD:-}" ]]; then
    out="$($SPAWN_PLACE_ARCHIVED_CMD "$topic" 2>&1)"
  else
    out="$(spl_lane_hub --fleet "$LANE_FLEET" --archived --topic "$topic" 2>&1)"
  fi
  id8="$(jq -r '.ask_id[0:8]' <<<"$2")"
  if ! jq -e '.lanes | type == "array"' >/dev/null 2>&1 <<<"$out"; then
    do_log "WARN ask $id8: the archive state of topic $topic could not be read: placed as before. $(tail -1 <<<"$out" | cut -c1-160)" >&2
    return 1
  fi
  at="$(jq -r '.topic_archived_at // ""' <<<"$out")"
  if [[ -z "$at" ]]; then
    # a topic read always answers no lanes on a hub with SPL-4955: lanes prove
    # that an older binary or hub ignored --topic
    jq -e '.lanes | length > 0' >/dev/null 2>&1 <<<"$out" &&
      do_log "WARN ask $id8: the spool binary or hub is too old to read the archive state of topic $topic: placed as before" >&2
    return 1
  fi
  why="discussion archived: topic $topic was archived at $at, so this row is not placed (SPL-4955)"
  if ! row="$(spl_spawn_q_op decline "$(jq -r '.ask_id' <<<"$2")" "$1" "$why")"; then
    do_log "WARN ask $id8: not placed, its topic $topic is archived, but the decline failed: the next tick tries again" >&2
    return 0
  fi
  spl_spawn_q_reply "$row" "$1" "not placed: $why" || do_log "WARN ask $id8 is declined but its sender was not told" >&2
  spl_spawn_q_send "$1" "$1" note spawn-queue "**SPAWN QUEUE: ask $id8 not placed.** $why. Its summary: $(jq -r '.summary // ""' <<<"$2" | cut -c1-300)" ||
    do_log "WARN ask $id8 is declined but the holder was not told" >&2
  do_log "OK ask $id8 not placed: $why" >&2
  return 0
}

# Writes the row's topic into BRIEF as its one `Ask-Topic:` line, the lane's
# binding when its discussion is archived (do_spl_archived_seats_free): it
# travels with the brief to another box and to lifetime/brief.md. A brief that
# cannot be written is one WARN line: the lane falls back to its own lines.
spl_spawn_place_ask_topic() {  # BRIEF TOPIC
  [[ -n "$2" ]] || return 0
  local body
  if ! { [[ -w "$1" ]] && body="$(grep -v '^Ask-Topic:' "$1")" && printf '%s\n\nAsk-Topic: %s\n' "$body" "$2" >"$1"; } 2>/dev/null; then
    do_log "WARN brief $1 takes no Ask-Topic line: its lane binds by its own lines only" >&2
  fi
  return 0
}

# The brief's work kind and category on the hub's request (spec 143 4.4,
# SPL-2790): its "Kind:" (spl_lane_mix_brief_kind, the picker's read; one
# that is no fleet_asks work_kind is left out) and its line-start
# "Category: <path>". The token rollup by category reads them. A brief with
# neither sends nothing and places as before; a refused or failed record
# (a path the tree does not hold) is one WARN line and the placement goes on.
spl_spawn_place_category() {  # HOLDER ASK_ID BRIEF
  local kind cat out
  declare -F spl_lane_mix_brief_kind >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  kind="$(spl_lane_mix_brief_kind "$3")"
  case " ${SPAWN_PLACE_WORK_KINDS:-specs_and_docs tests simple_coding complex_coding i18n secret review dispatch} " in
    *" $kind "*) ;; *) kind="" ;;
  esac
  cat="$(grep -m1 -oE '^Category:[*_ ]*[a-z0-9_]+(/[a-z0-9_]+)*' "$3" 2>/dev/null | sed -E 's/^Category:[*_ ]*//')"
  [[ -n "$kind$cat" ]] || return 0
  if out="$(spl_asks_hub category --fleet "$LANE_FLEET" --id "$2" --by "$1" --work-kind "$kind" --category "$cat" 2>&1)"; then
    do_log "INFO ask ${2:0:8}: work_kind ${kind:-none}, category ${cat:-none} recorded" >&2
  else
    do_log "WARN ask ${2:0:8}: its category was not recorded (${kind:-none} ${cat:-none}): $(tail -1 <<<"$out" | cut -c1-200); placed without it" >&2
  fi
  return 0
}

# The brief's epic is closed on the hub (li_brief_epic_closed, SPL-2508): the
# lane's issue would be refused at launch (unknown_parent, spawn-window exit
# 12) and the row retried every SPAWN_PLACE_GAP_MIN. An epic the SPL-1729
# close archived (the `auto-closed` field) is reopened and the row launched
# (spl_spawn_place_reopen, SPL-2558: the closer reopens only for a brief on
# its own box). A close by a person or an agent, or a failed reopen, goes to
# the holder once instead, the reason in the blocker; nothing is launched.
spl_spawn_place_epic_closed() {  # BRIEF
  declare -F li_brief_epic_closed >/dev/null ||
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || return 0
  li_brief_epic_closed "$1"
}

# Every lane names its discussion and its issue (spec 153 3.20, SPL-4797;
# owner HUM-10, t1 f94e07bf msg 33f8eecb: "each lane must have at least 1
# link to an issue WHAT It is doing and at least 1 link to a discusion from
# where did it originated", t1 0c2d08a2 msg 08ac07da: "the links must be
# enforced"). Prints why a row may not launch, nothing when it may: no
# discussion = the ask's topic is neither a hub uuid nor dispatch-<topic8>,
# the ask carries no discussion and the brief names none
# (li_discussion_from_brief); no issue = the brief has no `Issue:` key and no
# Epic:/Spec: pair the placer files one under (li_brief_epic_spec). The row
# goes to the holder (spl_spawn_place_hand) with the line to add.
spl_spawn_place_no_links() {  # ROW BRIEF
  local topic disc why=""
  declare -F li_discussion_from_brief >/dev/null ||
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || return 0
  topic="$(jq -r '.topic // ""' <<<"$1")"
  disc="$(jq -r '.discussion // ""' <<<"$1")"
  if [[ ! "$topic" =~ ^([0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}|dispatch-[0-9a-f]{8})$ &&
    ! "$disc" =~ ^[0-9a-f]{8}((-[0-9a-f]{4}){3}-[0-9a-f]{12})?$ ]] &&
    ! li_discussion_from_brief "$2" >/dev/null; then
    why="no discussion: the ask's topic '${topic}' names no hub topic and brief $2 names none (add a 'Topic: <uuid>' line, or report on dispatch-<topic8>)"
  fi
  if ! li_brief_epic_spec "$2" >/dev/null 2>&1; then
    why="${why:+$why; }no issue: brief $2 has no 'Issue: <KEY>' line and no 'Epic: SPL-<n>' + 'Spec: <folder>' pair to file one under"
  fi
  [[ -z "$why" ]] || printf 'lane refused, %s\n' "$why"
}

# Reopen the auto-closed epic BRIEF names (do_spl_epic_reopen) as the lease's
# desk, in a subshell: its ENV / DESK_AGENT stay there. A moved desk re-runs it
# as the desk's owner (spec 069 8.4, R7 W1 of SPL-4985).
# Prints nothing when it reopened, else WHY with the failure for the hand-off.
# COMMENT (optional) replaces the placer's comment on the epic (the enqueue's).
spl_spawn_place_reopen() {  # BRIEF SLUG WHY [COMMENT]
  local epic out
  declare -F li_epic_reopen >/dev/null ||
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || { printf '%s\n' "$3"; return 0; }
  epic="$(li_brief_epic_spec "$1" 2>/dev/null)"; epic="${epic#*$'\t'}"
  if out="$(
    declare -F do_spl_epic_reopen >/dev/null || source "$PROJ_PATH/src/bash/run/spl-epic-reopen.func.sh"
    EPIC_KEY="$epic" DRY_RUN=0 \
      EPIC_COMMENT="${4:-Reopened by do_spl_spawn_place: auto-closed (SPL-1729), head brief $2 names it on its Epic: line, and its lane files its issue under it (SPL-2558).}" \
      do_spl_epic_reopen 2>&1
  )"; then
    do_log "OK $epic reopened: it was auto-closed and brief $2 names it (SPL-2558)" >&2
    return 0
  fi
  do_log "WARN reopening the auto-closed epic $epic failed: $(tail -n 1 <<<"$out")" >&2
  printf '%s; reopening it failed: %s\n' "$3" "$(tail -n 1 <<<"$out")"
}

# The vendor a mistral row launches as, "<vendor>\t<why>": VENDOR and no why
# unless it is mistral on UI work while the cnf switch mistral_ui_allowed is
# not true, or on a coding kind while mistral_coding_allowed is not true (the
# UI and coding rules, spl-lane-mix.func.sh, owner HUM-10 t1 b61851fb). Such a
# row swaps to agy when its brief's kind is specs_and_docs or i18n (agy is the
# main of both, and a review stays cross-vendor to a claude author, SPL-2942),
# else to claude. A brief under the data rule (spl_spawn_place_data_rule,
# SPL-3627) swaps to claude only, never agy or qwen. A review seat
# (spl_spawn_place_review_seat) writes no code, so neither rule swaps it,
# whatever its brief's kind or paths: the coding rule since SPL-3776 (a Kind:
# secret brief read as coding put a claude reviewer on a claude author), the
# UI rule since SPL-3954 (owner HUM-10, t1 1be0e370, msg 594d77e1: "Mistral
# may review them, read-only (it writes no code; your UI-work rule still
# holds for building)"). A mistral review seat on a mistral author
# (spl_spawn_place_authors) prints "refuse\t<why>".
spl_spawn_place_swap() {  # VENDOR BRIEF
  local why kind to=claude dr au cnf="${SPAWN_PLACE_CNF:-$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml}"
  [[ "$1" == mistral ]] || { printf '%s\t\n' "$1"; return 0; }
  declare -F spl_lane_mix_mistral_ui_off >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  kind="$(spl_lane_mix_brief_kind "$2")"
  if spl_spawn_place_review_seat "$2" "$kind"; then
    au="$(spl_spawn_place_authors "$2" | awk -F'\t' '$1 == "mistral" { printf "%s%s", (n++ ? ", " : ""), $2 }')"
    [[ -z "$au" ]] || { printf 'refuse\ta review seat on mistral would review its author'"'"'s vendor (mistral: %s), so it is not placed (SPL-3776)\n' "$au"; return 0; }
    printf '%s\t\n' "$1"; return 0
  fi
  why="$(spl_lane_mix_mistral_ui_off "$cnf" "$2" "")"
  [[ -n "$why" ]] || why="$(spl_lane_mix_mistral_code_off "$cnf" "$kind")"
  [[ -n "$why" ]] || { printf '%s\t\n' "$1"; return 0; }
  dr="$(spl_spawn_place_data_rule "$2" "$kind")"
  if [[ -n "$dr" ]]; then
    why="$why; the brief is under the data rule ($dr): claude, never agy or qwen"
  else
    case "$kind" in specs_and_docs|i18n) to=agy ;; esac
  fi
  printf '%s\t%s\n' "$to" "$why"
}

# A review seat (SPL-3776): its brief's file name, the placement slug, ends in
# -reviewer (the review-seat GO's mechanical mark, spl_spawn_q_review_seat_go),
# or its "Kind:" (KIND) is review or code_review. The wider "review" match of
# spl_spawn_place_review (any heading word) is not one: a coding lane may say
# review in its title.
spl_spawn_place_review_seat() {  # BRIEF KIND
  [[ "$(basename "$1" .md)" == *-reviewer ]] && return 0
  [[ "$2" == review || "$2" == code_review ]]
}

# The author lanes of a review BRIEF, one "<vendor>\t<id>" line each: the id on
# a line-start "Author:" line, else every lane id the brief names but the role
# seats (spl_is_role_seat; a review brief names its author in its row; any
# other lane it names counts too, so a doubt refuses rather than places a
# same-vendor review). The vendor is spl_kind_of_agent_id's.
spl_spawn_place_authors() {  # BRIEF
  local ids id
  [[ -r "$1" ]] || return 0
  declare -F spl_kind_of_agent_id >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  ids="$(grep -m1 -iE '^Author:' "$1" | grep -oE "\b${SPOOL_AGENT_ID_NEW_RX}\b")"
  [[ -n "$ids" ]] || ids="$(grep -oE "\b${SPOOL_AGENT_ID_NEW_RX}\b" "$1")"
  while read -r id; do
    [[ -n "$id" ]] && ! spl_is_role_seat "$id" || continue
    printf '%s\t%s\n' "$(spl_kind_of_agent_id "$id")" "$id"
  done < <(sort -u <<<"$ids")
}

# Why the brief is under the data rule (personal data or secrets: claude,
# grok or mistral only, never agy or qwen; global CLAUDE.md "Spawn an agent"),
# else nothing: its "Kind:" is secret (KIND), a line-start "Data: secret"
# (the marker a dispatcher writes, guide-how-to-be-a-dispatcher.md), or the
# words "Data rule:" anywhere (the prose ask c581963b carried, SPL-3627).
spl_spawn_place_data_rule() {  # BRIEF KIND
  [[ "$2" == secret ]] && { echo "Kind: secret"; return 0; }
  [[ -n "$1" && -r "$1" ]] || return 0
  if grep -qiE '^Data:[*_ ]*secret\b' "$1"; then echo "Data: secret"
  elif grep -qiF 'Data rule:' "$1"; then echo "Data rule:"
  fi
  return 0
}

# The vendor to launch (spl_spawn_place_swap). A swap to agy while agy is out
# on every box (spl_spawn_place_agy_all_out, SPL-3018) launches claude instead,
# unless the row is a review: spl_spawn_place_agy_hold keeps those queued.
# A row queued before the enqueue refused it is launched, not dropped. A
# refused swap (a mistral review seat on a mistral author, SPL-3776) is one WARN
# line, prints why and returns 1: the row is handed to the holder, not placed.
spl_spawn_place_vendor() {  # VENDOR BRIEF ASK_ID
  local sw to why out
  sw="$(spl_spawn_place_swap "$1" "$2")"; to="${sw%%$'\t'*}" why="${sw#*$'\t'}"
  [[ -n "$why" ]] || { echo "$to"; return 0; }
  if [[ "$to" == refuse ]]; then
    do_log "WARN ask ${3:0:8}: placed as mistral, its swap is refused: $why" >&2
    printf '%s\n' "$why"
    return 1
  fi
  if [[ "$to" == agy ]] && ! spl_spawn_place_review "$2" && out="$(spl_spawn_place_agy_all_out)" && [[ -n "$out" ]]; then
    to=claude why="$why; $out"
  fi
  do_log "INFO ask ${3:0:8}: placed as mistral, launched as $to: $why" >&2
  echo "$to"
}

# A review row (SPL-3018; a review seat stays cross-vendor to its author,
# SPL-2942, rounds-rulebook 2.7.2/2.7.3): the brief's "Kind:" is review, or
# its file name or first "# " heading says review ("the cross-vendor R7
# reviewer"). Any other row is not one.
spl_spawn_place_review() {  # BRIEF
  declare -F spl_lane_mix_brief_kind >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  [[ "$(spl_lane_mix_brief_kind "$1")" == review ]] && return 0
  grep -qi 'review' <<<"$(basename "$1") $(grep -m1 '^# ' "$1" 2>/dev/null)"
}

# agy out of quota on this box (SPL-3018): "agy is out of quota until <UTC>
# (<evidence>)", else nothing. Read only, from two records the box keeps:
# lane-mix's verdict (_spl_lane_mix_limit agy: a watchdog S2 kind=limit on an
# a- lane, held LANE_MIX_LIMIT_FRESH s), and agy's own banner "Individual
# quota reached ... Resets in 13h53m38s" in the watchdog's pane capture
# (<wd>/ctx*/a-*/pane; the reset is its mtime + that time). Both fire since
# SPL-3022 made the watchdog read that banner as S2 kind=limit; the banner
# alone also covers a lane the watchdog has not judged yet.
# Only a live lane's record counts (SPL-3846: the captures of every dead a-
# lane stay on disk, and one stale banner held every agy row for 3 days while
# agy answered): live = listed in a fresh agent-run.tsv
# (spl_spawn_place_agy_live). A record not newer than agy's last answered
# probe (<probe-dir>/agy.ok, its mtime) is dropped too. The watchdog rewrites its
# capture and its verdict each pass, so their mtime is no read time: a static
# banner rolled "until" forward for as long as it stayed on screen (SPL-4965).
# A record counts from its first sighting (spl_spawn_place_agy_first), and the
# line says how long ago that was.
spl_spawn_place_agy_out() {
  local wd="${LANE_MIX_WD_DIR:-$SPOOL_ROOT/dispatch/wd}" now f line t best=0 bestat=0 ev="" hit live since=0 id at
  local -a seen=()
  local ok="${SPAWN_PLACE_PROBE_DIR:-$SPOOL_ROOT/dispatch/vendor-probe}/agy.ok"
  now="$(date +%s)"
  live="$(spl_spawn_place_agy_live)"
  [[ -e "$ok" ]] && since="$(stat -c %Y "$ok" 2>/dev/null || echo 0)"
  declare -F _spl_lane_mix_limit >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  hit="$(_spl_lane_mix_limit agy "$SPOOL_ROOT" "${LANE_MIX_REGISTRY:-$SPOOL_ROOT/registry.tsv}" "$since" "$live")"
  if [[ -n "$hit" ]]; then
    id="${hit#*$'\t'}" id="${id%% *}"
    at="$(spl_spawn_place_agy_first "$id S2" "${hit%%$'\t'*}")"
    seen+=("$id S2")
    (( at > since )) && bestat="$at" best=$(( at + ${LANE_MIX_LIMIT_FRESH:-21600} )) ev="${hit#*$'\t'}"
  fi
  for f in "$wd"/ctx*/a-*/pane; do
    id="$(basename "$(dirname "$f")")"
    [[ -z "$live" || "$live" == *"|$id|"* ]] || continue
    line="$(grep -aoE 'Individual quota reached.*Resets in ([0-9]+h)?([0-9]+m)?([0-9]+s)?' "$f" 2>/dev/null | tail -n 1)"
    [[ "$line" =~ Resets\ in\ (([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?$ ]] || continue
    t=$(( 10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 + 10#${BASH_REMATCH[6]:-0} ))
    at="$(spl_spawn_place_agy_first "Resets in ${line##*Resets in }" "$(stat -c %Y "$f" 2>/dev/null || echo 0)")"
    seen+=("Resets in ${line##*Resets in }")
    (( at > since )) || continue
    t=$(( at + t ))
    (( t > best )) && best="$t" bestat="$at" ev="$id banner, Resets in ${line##*Resets in }"
  done
  spl_spawn_place_agy_first_keep "${seen[@]}"
  (( best > now )) || return 0
  (( bestat > 0 )) && ev+=", read $(( (now - bestat) / 60 ))m ago"
  printf 'agy is out of quota until %s (%s)\n' "$(date -u -d "@$best" +%FT%TZ)" "$ev"
}

# The first sighting of agy limit record KEY (a banner's own text, "<id> S2" for
# a verdict), else WHEN, recorded: <probe-dir>/agy-limit-seen.tsv, KEY TAB epoch.
# Best effort: a file that cannot be written answers WHEN, the old behaviour.
spl_spawn_place_agy_first() {  # KEY WHEN
  local f="${SPAWN_PLACE_PROBE_DIR:-$SPOOL_ROOT/dispatch/vendor-probe}/agy-limit-seen.tsv" at
  at="$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$f" 2>/dev/null)"
  if [[ "$at" =~ ^[0-9]+$ ]]; then echo "$at"; return 0; fi
  mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\t%s\n' "$1" "$2" >>"$f" 2>/dev/null
  echo "$2"
}

# Forgets every first sighting but KEYS: a record gone from the watchdog's dir
# is over, and the same text coming back later is a new reading.
spl_spawn_place_agy_first_keep() {  # KEY...
  local f="${SPAWN_PLACE_PROBE_DIR:-$SPOOL_ROOT/dispatch/vendor-probe}/agy-limit-seen.tsv" k
  [[ -s "$f" ]] || return 0
  { for k in "$@"; do printf '%s\n' "$k"; done; } | awk -F'\t' 'NR == FNR { w[$0] = 1; next } $1 in w' - "$f" >"$f.$$" 2>/dev/null &&
    mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$" 2>/dev/null
  return 0
}

# The lane map's JSON ({load: [...]}), or nothing when the hub is silent.
spl_spawn_place_agy_load() {
  if [[ -n "${SPAWN_PLACE_LOAD_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPAWN_PLACE_LOAD_CMD 2>/dev/null
  else
    LANE_FORMAT=json timeout "${SPAWN_SHARE_TIMEOUT:-90}" bash "$PROJ_PATH/run" -a do_spl_lane_map 2>/dev/null | grep -E '^\{' | tail -1
  fi
}

# Each box's agy, one "<box>\t<in|out>\t<why>" line (SPL-5078): judged per
# box, not as one for the fleet as SPL-3998 read it (2026-11-04: every agy row
# waited on a sat banner while a-122 and a-236 answered on the main box; which
# login each box uses is not measured, so two boxes may still share one). The
# boxes are this one and the lane map's live ones. This box is out on
# spl_spawn_place_agy_out, another on its watchdog blocker from a live lane
# (spl_spawn_place_agy_boxes); a blocker from a closed lane only makes that
# box "steer" (SPL-5208): in for the every-box-out judgement, but a row is
# steered off it to a box that is in; either is out when measured without the agy
# program or its login (spool_vendor_clis, the lane map's clis; 2026-11-06:
# sat lost both, and a launch there fails and returns to position 1). No
# measurement = unknown = not out; a hub that is silent lists this box and
# the boxes with a blocker only.
spl_spawn_place_agy_state() {
  local outs load here clis box line
  declare -F spool_vendor_clis >/dev/null || source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  load="$(spl_spawn_place_agy_load)"
  [[ -n "$load" ]] || load='{}'
  outs="$(spl_spawn_place_agy_boxes "$load")"
  here="$(spl_spawn_place_agy_out)"
  clis="$(spool_vendor_clis 2>/dev/null)" || clis="?"
  [[ "$clis" == "?" || ",$clis," == *,agy,* ]] || here="${here:-the agy program or its login is missing on $ASKS_BOX}"
  printf '%s\t%s\t%s\n' "$ASKS_BOX" "$([[ -n "$here" ]] && echo out || echo in)" "$here"
  while IFS= read -r box; do
    [[ -n "$box" && "$box" != "$ASKS_BOX" ]] || continue
    line="$(awk -F'\t' -v b="$box" '$1 == b { print $3 "\t" $2; exit }' <<<"$outs")"
    if [[ "$line" == live$'\t'* ]]; then
      printf '%s\tout\tagy on %s is at its quota limit until %s\n' "$box" "$box" "${line#*$'\t'}"
    elif [[ -n "$line" ]]; then
      printf '%s\tsteer\tagy on %s may be at its quota limit until %s, a closed lane'"'"'s blocker\n' "$box" "$box" "${line#*$'\t'}"
    elif jq -e --arg b "$box" 'any(.load[]?; .box == $b and .clis != null and ((.clis | index("agy")) == null))' <<<"$load" >/dev/null 2>&1; then
      printf '%s\tout\tthe agy program or its login is missing on %s\n' "$box" "$box"
    else
      printf '%s\tin\t\n' "$box"
    fi
  done < <({ jq -r '.load[]? | select(.live) | .box' <<<"$load" 2>/dev/null; cut -f1 <<<"$outs"; } | sort -u)
}

# Every box's why, joined, when no box's agy is in; else nothing. A steer box
# (a closed lane's blocker only) counts as in (SPL-5078 W1).
spl_spawn_place_agy_all_out() {  # [STATE]
  local st="${1:-$(spl_spawn_place_agy_state)}"
  awk -F'\t' '$2 != "out" { exit 1 }' <<<"$st" || return 0
  cut -f3 <<<"$st" | paste -sd ';' - | sed 's/;/; /g'
}

# The other boxes' watchdog limit blockers (SPL-3998) as
# "<id>\t<box>\t<reset epoch>\t<msg_id8>" lines: reset ahead of NOW, sent
# after SINCE (epoch, 0 = any), from a box that is not this one.
spl_spawn_place_agy_recs() {  # SINCE NOW
  local here="${ASKS_BOX:-${SPOOL_DESK_BOX:-}}" f files=()
  for f in "$SPOOL_ROOT"/*/inbox/*--watchdog-093-s2-kind-limit-a-*.json "$SPOOL_ROOT"/*/archive/*--watchdog-093-s2-kind-limit-a-*.json; do
    [[ -e "$f" ]] && files+=("$f")
  done
  (( ${#files[@]} )) || return 0
  jq -r --arg here "$here" --argjson since "$1" --argjson now "$2" '
    (.body // "" | capture("^WATCHDOG \\(093 S2 kind=limit\\): (?<id>a-[0-9]+) is on its usage limit until (?<u>[0-9T:-]+Z).* box (?<b>[a-z0-9-]+),")) as $c
    | select($c.b != $here and ($c.u | fromdate) > $now and ((.ts // "") | try fromdate catch 0) > $since)
    | "\($c.id)\t\($c.b)\t\($c.u | fromdate)\t\(.msg_id // "" | .[0:8])"' "${files[@]}" 2>/dev/null | sort -u
}

# The other boxes whose agy login is on its limit (SPL-4020), one
# "<box>\t<UTC> (<evidence>)\t<live|closed>" line per box, its latest reset.
# A blocker holds while its reset is ahead and its lane is live on its box
# (SPL-5078, the check SPL-3846 set): in that box's busy_ids of LOAD, the lane
# map's JSON, read from its BOX-0 row. A banner from a lane with no window
# proves nothing either way, and with agy.ok unwritten nothing else would
# clear it before its reset, so it is "closed": it holds no box, it only
# steers a row off it (SPL-5208, SPL-4020's a-097). A box with a live blocker
# is live. No load for that box, or only its lane rows (src rows): liveness
# unknown, live. A probe here proves nothing about another box's login, so
# agy.ok is not read.
spl_spawn_place_agy_boxes() {  # LOAD
  local load="$1" id box u m lv
  [[ -n "$load" ]] || load='{}'
  while IFS=$'\t' read -r id box u m; do
    [[ -n "$id" ]] || continue
    lv=1
    jq -e --arg b "$box" --arg i "$id" 'any(.load[]?; .box == $b and .src != "rows" and ((.busy_ids // []) | index($i) == null))' <<<"$load" >/dev/null 2>&1 && lv=0
    printf '%s\t%s\t%s\t%s (%s@%s S2 kind=limit, its watchdog'"'"'s blocker %s)\n' \
      "$box" "$lv" "$u" "$(date -u -d "@$u" +%FT%TZ)" "$id" "$box" "$m"
  done <<<"$(spl_spawn_place_agy_recs 0 "$(date +%s)")" | sort -t $'\t' -k1,1 -k2,2nr -k3,3nr |
    awk -F'\t' '!s[$1]++ { print $1 "\t" $4 "\t" ($2 ? "live" : "closed") }'
}

# The ids with a live process on this box as "|<id>|<id>|" ("|" = none), from
# the lease loop's agent-run.tsv (SPAWN_PLACE_AGENT_RUN, default
# $SPOOL_ROOT/dispatch/agent-run.tsv: "# agent-run v1 <epoch>", then one
# "<id>\t<run|stop>..." row per live id) while it is younger than
# SPAWN_PLACE_RUN_STALE s (default 300). No fresh report prints nothing:
# liveness unknown, every record counts as before.
spl_spawn_place_agy_live() {
  local f="${SPAWN_PLACE_AGENT_RUN:-$SPOOL_ROOT/dispatch/agent-run.tsv}" at="" id ids="|"
  [[ -r "$f" ]] || return 0
  read -r _ _ _ at _ <"$f"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at <= ${SPAWN_PLACE_RUN_STALE:-300} )) || return 0
  while IFS=$'\t' read -r id _; do
    [[ "$id" == \#* || -z "$id" ]] || ids+="$id|"
  done <"$f"
  echo "$ids"
}

# 2c. While agy is out on every box (spl_spawn_place_agy_all_out), a queued row
# the placer launches HOLDS when it is placed as agy (SPL-3024: agy was picked
# on purpose, review or not), or when its swap is to agy (spl_spawn_place_swap)
# and it is a review (spl_spawn_place_review, SPL-3018): claude would break
# the cross-vendor review of a claude author (SPL-2942). A held row stays
# queued and out of this tick's line, so it blocks no other row; one INFO line
# and its .place.wait line name the reset; the agy line of any row not held
# this tick is dropped (SPL-3138: agy back in quota, or the row no longer
# holds). Prints ROWS minus the held ones.
spl_spawn_place_agy_hold() {  # MARKED ROWS
  local out="" id vendor slug brief why held=()
  while IFS=$'\t' read -r id vendor slug; do
    brief="$(spl_spawn_place_brief "$slug")"
    [[ -n "$brief" ]] || continue
    if [[ "$vendor" == agy ]]; then
      why="placed as agy"
    else
      [[ "$(spl_spawn_place_swap mistral "$brief" | cut -f1)" == agy ]] || continue
      spl_spawn_place_review "$brief" || continue
      why="a review row stays cross-vendor (SPL-2942)"
    fi
    [[ -n "$out" ]] || out="$(spl_spawn_place_agy_all_out)"
    [[ -n "$out" ]] || break
    why="$why, and $out"
    spl_spawn_place_wait "$id" "$why"
    do_log "INFO hold: ask ${id:0:8}: $why; it stays queued" >&2
    held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and ._l and ((.placement // "") | test("^(mistral|agy):")))
    | "\(.ask_id)\t\(.placement | sub(":.*$"; ""))\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")
  spl_spawn_place_wait_keep held "$(printf '%s\n' "${held[@]}")" "(placed as agy|stays cross-vendor \\(SPL-2942\\)), and "
  jq -c --argjson h "$(spl_spawn_place_json_ids "${held[@]}")" '[.[] | select(.ask_id as $i | $h | index($i) | not)]' <<<"$1"
}

# 2d. A queued row with a placement but no brief file here, last written on
# another box (writer_box), HOLDS (SPL-3470): briefs are written on the box of
# the dispatcher that queued the row, and the placer moves with the orch role.
# Handing it to the holder would make the holder decline it, and a declined
# ask cannot be queued again (13 rows on 2026-10-25). A held row stays queued
# and out of this tick's line, so it blocks no other row; one INFO line and
# its .place.wait line name the box; the line of a row no longer held is
# dropped. No writer_box, or this box: not held (4b hands it off as before).
# Prints ROWS minus the held ones.
spl_spawn_place_away_hold() {  # MARKED ROWS
  local id slug wb why held=()
  while IFS=$'\t' read -r id slug wb; do
    why="its brief $slug.md is not under ${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs} on $ASKS_BOX: it was queued on $wb, so the file is there; it is placed from $wb, or here once the file is copied here"
    spl_spawn_place_wait "$id" "$why"
    do_log "INFO hold: ask ${id:0:8}: $why; it stays queued" >&2
    held+=("$id")
  done < <(jq -r --arg box "$ASKS_BOX" '.[] | select(.state == "queued" and (._l | not) and (.placement // "") != ""
      and (.writer_box // "") != "" and .writer_box != $box)
    | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))\t\(.writer_box)"' <<<"$1")
  spl_spawn_place_wait_keep held "$(printf '%s\n' "${held[@]}")" "is not under .* on [^:]*: it was queued on "
  jq -c --argjson h "$(spl_spawn_place_json_ids "${held[@]}")" '[.[] | select(.ask_id as $i | $h | index($i) | not)]' <<<"$1"
}

# 2e. A queued row the placer can launch whose slug is hand-pinned to a box
# at or past its overflow mark, CORDONED, DEGRADED, RECOVERING or AT CAP
# (spl_spawn_place_pin_full) HOLDS (SPL-4009): it stays queued, out of this
# tick's line, so it blocks no other row; one INFO line and its .place.wait
# line say why. Before, the hold was judged on the head only, and one row
# pinned to a full box stopped every row behind it (27 queued, none placed,
# 2026-10-28). do_spl_box_pick runs once per tick, only when a row is pinned;
# the line of a row no longer held is dropped. Prints ROWS minus the held ones.
spl_spawn_place_pin_hold() {  # MARKED ROWS
  local id slug box why out="" held=() ps=()
  while IFS=$'\t' read -r id slug; do
    mapfile -t ps < <(spl_spawn_place_slug "$slug")
    box="${ps[0]}"
    [[ -n "$box" ]] || continue
    [[ -n "$out" ]] || out="$(spl_spawn_place_pick_out)"
    why="$(spl_spawn_place_pin_full "$box" "$out")" || continue
    spl_spawn_place_wait "$id" "pinned to $box: $why"
    do_log "INFO hold: ask ${id:0:8} is pinned to $box: $why; it stays queued" >&2
    held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and ._l) | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")
  spl_spawn_place_wait_keep held "$(printf '%s\n' "${held[@]}")" "^pinned to [a-z0-9]+: "
  jq -c --argjson h "$(spl_spawn_place_json_ids "${held[@]}")" '[.[] | select(.ask_id as $i | $h | index($i) | not)]' <<<"$1"
}

# 2f. A queued row the placer would launch as agy (placed as agy, or swapped
# to agy and not turned to claude by spl_spawn_place_vendor) is judged
# against the box it goes to (SPL-4020, SPL-5078): each box's agy login has its own
# quota (2026-10-28: agy answered on sat while every a- seat on the main box
# showed "Individual quota reached" until 11-03), and once those seats were
# closed no record held, so sat launched a-097 onto the main box. While any
# box is out (spl_spawn_place_agy_state), the target is the pinned slug's box,
# else do_spl_box_pick's pick (BOX_PICK_KIND=agy). Target out: an unpinned row
# goes to a box that is in and not full (spl_spawn_place_pin_full), this box
# first, else to a steer box; else it HOLDS, queued, out of this tick's line,
# the why in .place.wait. Target steer (only a closed lane's blocker, SPL-5208):
# an unpinned row goes to a box that is in and not full, else it launches on
# the target; it never holds (SPL-5078 W1). Target in:
# the row carries it as _b, the launch's SPAWN_BOX, so the launch goes where
# it was judged. With no row placed as agy or mistral it returns before the
# state, which runs the lane map (10.6 s on sat, n=1, on a 1-min cron).
# Prints ROWS minus the held ones.
spl_spawn_place_agy_box_hold() {  # MARKED ROWS
  local st outs alt altout a id vendor slug brief pin box pout="" lout="" line sb why full held=() to='{}'
  local rx="^(agy on [a-z0-9-]+ is at its quota limit until |agy is out of quota until |the agy program or its login is missing on )"
  jq -e 'any(.[]; .state == "queued" and ._l and ((.placement // "") | test("^(mistral|agy):")))' <<<"$1" >/dev/null 2>&1 || {
    spl_spawn_place_wait_keep held "" "$rx"; echo "$1"; return 0
  }
  st="$(spl_spawn_place_agy_state)"
  outs="$(awk -F'\t' '$2 != "in"' <<<"$st")"
  [[ -n "$outs" ]] || { spl_spawn_place_wait_keep held "" "$rx"; echo "$1"; return 0; }
  alt="$(spl_spawn_place_agy_alt "$st" in)" altout="$alt"
  [[ -n "$altout" ]] || altout="$(spl_spawn_place_agy_alt "$st" steer)"
  while IFS=$'\t' read -r id vendor slug; do
    brief="$(spl_spawn_place_brief "$slug")"
    [[ -n "$brief" ]] || continue
    if [[ "$vendor" == mistral ]]; then
      [[ "$(spl_spawn_place_swap mistral "$brief" | cut -f1)" == agy ]] || continue
      if ! spl_spawn_place_review "$brief"; then
        [[ -n "$lout" ]] || lout="$(spl_spawn_place_agy_all_out "$st")" lout="${lout:--}"
        [[ "$lout" == - ]] || continue
      fi
    fi
    pin="$(spl_spawn_place_slug "$slug" | sed -n 1p)" box="$pin"
    if [[ -z "$box" ]]; then
      [[ -n "$pout" ]] || pout="$(BOX_PICK_KIND=agy spl_spawn_place_pick_out)"
      box="$(sed -n 's/^pick=\([a-z0-9][a-z0-9-]*\).*$/\1/p' <<<"$pout" | tail -1)"
      [[ -n "$box" && "$box" != hold && "$box" != nokind ]] || continue
    fi
    line="$(awk -F'\t' -v b="$box" '$1 == b { print $2 "\t" $3; exit }' <<<"$outs")"
    sb="${line%%$'\t'*}" why="${line#*$'\t'}" a="$alt" full=""
    [[ "$sb" == out ]] && a="$altout"
    if [[ -n "$sb" && -z "$pin" && -n "$a" ]] && ! full="$(spl_spawn_place_pin_full "$a" "$pout")"; then
      do_log "INFO ask ${id:0:8}: $why: it launches on $a" >&2
      to="$(jq -c --arg i "$id" --arg b "$a" '.[$i] = $b' <<<"$to")"
      continue
    fi
    if [[ "$sb" != out ]]; then
      [[ -n "$pin" ]] || to="$(jq -c --arg i "$id" --arg b "$box" '.[$i] = $b' <<<"$to")"
      continue
    fi
    why="$why, and ${full:-the row is pinned there}"
    spl_spawn_place_wait "$id" "$why"
    do_log "INFO hold: ask ${id:0:8}: $why; it stays queued" >&2
    held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and ._l and ((.placement // "") | test("^(mistral|agy):")))
    | "\(.ask_id)\t\(.placement | sub(":.*$"; ""))\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")
  spl_spawn_place_wait_keep held "$(printf '%s\n' "${held[@]}")" "$rx"
  jq -c --argjson h "$(spl_spawn_place_json_ids "${held[@]}")" --argjson to "$to" \
    '[.[] | select(.ask_id as $i | $h | index($i) | not) | if $to[.ask_id] then ._b = $to[.ask_id] else . end]' <<<"$1"
}

# The first box of STATE (spl_spawn_place_agy_state) whose agy is WHICH (in,
# steer), this box first, or nothing.
spl_spawn_place_agy_alt() {  # STATE WHICH
  awk -F'\t' -v h="$ASKS_BOX" -v w="$2" '$2 == w { if ($1 == h) { print $1; f = 1; exit } if (!a) a = $1 } END { if (!f && a) print a }' <<<"$1"
}

# The brief file of SLUG on this box, or nothing; a hand-pinned SLUG falls
# back to its slug without the hand prefix.
spl_spawn_place_brief() {  # SLUG
  local d="${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}" f c
  [[ -n "$1" ]] || return 0
  c="$(spl_spawn_place_slug "$1" | tail -1)"
  for f in "$d/$1.md" "$d/c001-$1.md" "$d/$c.md" "$d/c001-$c.md"; do
    [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# 4a. The existing launcher. The new id closes the ask; HOLD (returns 10) or
# a failure puts it back in line. PIN (a hand-pinned slug's box) is its
# SPAWN_BOX. A pinned box that gave no reply returns 10 too (SPL-5143): each
# such failure re-armed the gap and the row was picked first again, 4 h with
# nothing placed on any box (2026-11-07). A retry can start the lane again each
# time the box takes the request and only its reply is lost: the pinned path has
# no slug check and nothing caps the retries, so spl_spawn_place_dark_hold only
# paces them to one try per SPAWN_PLACE_DARK_RETRY_MIN. Why not a skip of rows that failed lately: that
# keeps the gap armed, a dark box would still cost a slot on every try.
# spawn-window's REFUSED for a missing vendor CLI (exit 13: the box it would
# start on, a pinned one included, is measured without the program) holds the
# same way, its reason in .place.wait (SPL-5397): no gap slot, no blocker.
spl_spawn_place_launch() {  # HOLDER ROW VENDOR SLUG BRIEF [PIN]
  local holder="$1" id out err rc=0 agent why seat=0
  id="$(jq -r '.ask_id' <<<"$2")"
  err="$(mktemp)" || return 1
  if [[ "$(spl_spawn_place_seats "[$2]")" != '[]' ]]; then
    if spl_spawn_place_seat_pass "$5"; then
      seat=1
      do_log "INFO ask ${id:0:8} is a logged review seat: it launches on the review-seat weekly mark (env.box.quota.review_seat_max_pct)"
    else
      do_log "WARN ask ${id:0:8} is logged as a review seat by its slug ($4), but its brief's first heading does not say review: it launches on the weekly mark"
    fi
  fi
  # The lane row's topic (spec 153 3.4): the ask's topic, set once for both
  # launch lines, when it is a full hub uuid, or the 8 hex of a dispatch-<topic8>
  # task, which the hub resolves to the full uuid at put (3.12); any other
  # task name (dispatch-r47, dispatch-orc-<topic8>) sets nothing; else the
  # ask's discussion (3.20, R7 c-343 W1), which the placer let it launch on
  local ask_topic ask_disc; ask_topic="$(jq -r '.topic // ""' <<<"$2")"; ask_disc="$(jq -r '.discussion // ""' <<<"$2")"
  if [[ "$ask_topic" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]]; then
    local -x SPAWN_LANE_TOPIC="${BASH_REMATCH[0]}"
  elif [[ "$ask_topic" =~ ^dispatch-([0-9a-f]{8})$ ]]; then
    local -x SPAWN_LANE_TOPIC="${BASH_REMATCH[1]}"
  elif [[ "$ask_disc" =~ ^[0-9a-f]{8}((-[0-9a-f]{4}){3}-[0-9a-f]{12})?$ ]]; then
    local -x SPAWN_LANE_TOPIC="${BASH_REMATCH[0]}"
  fi
  spl_spawn_place_ask_topic "$5" "${SPAWN_LANE_TOPIC:-}"
  # stdout is the launcher's "<ID>[@<box>] <PANE>"; its stderr names other ids
  if [[ -n "${SPAWN_PLACE_LAUNCH_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(SPAWN_BOX="${6:-}" BOX_PICK_REVIEW_SEAT="$seat" $SPAWN_PLACE_LAUNCH_CMD "$3" auto "${SPAWN_PLACE_WORKDIR:-$APP_PATH}" "$5" "$4" 2>"$err")" || rc=$?
  else
    out="$(SPAWN_BOX="${6:-}" BOX_PICK_REVIEW_SEAT="$seat" SPOOL_AGENT_ID="${holder%@*}" bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/spawn-window.sh" \
      "$3" auto "${SPAWN_PLACE_WORKDIR:-$APP_PATH}" "$5" "$4" 2>"$err" 6>&-)" || rc=$?
  fi
  out="$out"$'\n'"$(tail -3 "$err")"; rm -f "$err"
  # the id letters every launcher mints, from their one home (SPL-5470: o- was missing)
  [[ -n "${SPOOL_AGENT_ID_NEW_RX:-}" ]] || source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  agent="$(grep -oE "^${SPOOL_AGENT_ID_NEW_RX}(@[a-z0-9][a-z0-9-]{0,31})?( |\$)" <<<"$out" | tail -1 | tr -d ' ')"
  if (( rc == 0 )) && [[ -n "$agent" ]]; then
    [[ "$agent" == *@* ]] || agent="$agent@$ASKS_BOX"
    printf '%s\n' "$agent" >"$(spool_asks_dir)/.place.agent"
    spl_spawn_place_wait "$id" ""
    spl_spawn_place_dark_clear "${6:-}"
    spl_spawn_placed_close "$id" "$holder" "$agent"
    declare -F spl_review_notify_placed >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-review-notify.func.sh"
    spl_review_notify_placed "$holder" "$agent" "$4" "$5"
    return 0
  fi
  (( rc != 0 )) || { spl_spawn_place_unread "$holder" "$id" "$3" "$4" "$out"; return 0; }
  spl_spawn_q_op queue "$id" "$holder" >/dev/null
  if (( rc == 10 )); then
    why="$(sed -n 's/^spawn-window: HOLD [^:]*: //p' <<<"$out" | tail -1 | sed 's/: queue the lane, spawn nothing.*$//; s/\. Queue it; nothing was spawned\.$//')"
    spl_spawn_place_wait "$id" "${why:-every box is past its load mark}"
    do_log "INFO ask ${id:0:8}: the launcher says HOLD (${why:-every box is past its load mark}): back in line at position 1"
    return 10
  fi
  if (( rc == 8 )) && grep -q 'did not start (spawn-remote exit 5)$' <<<"$out"; then
    spl_spawn_place_dark_note "$id" "${6:-}" 1
    why="no reply from ${6:-its box} since $(spl_spawn_place_dark_since "$id")"
    spl_spawn_place_wait "$id" "$why"
    do_log "INFO hold: ask ${id:0:8}: $why: it stays queued, the next row goes this tick"
    return 10
  fi
  why="$(sed -n 's/^spawn-window: REFUSED [^:]*: //p' <<<"$out" | tail -1 | sed 's/; nothing was spawned$//')"
  if (( rc == 13 )) && [[ -n "$why" ]]; then
    spl_spawn_place_wait "$id" "no box to start $3 on: $why"
    do_log "INFO hold: ask ${id:0:8}: no box to start $3 on: $why; it stays queued, the next row goes this tick"
    return 10
  fi
  do_log "WARN ask ${id:0:8}: the launch of $3:$4 failed (exit $rc): back in line"
  spl_spawn_q_send "$holder" "$holder" blocker spawn-queue "**SPAWN QUEUE: the launch of ask ${id:0:8} ($3:$4) failed** (spawn-window exit $rc); it is back at position 1 and the placer retries it in ${SPAWN_PLACE_GAP_MIN:-10} min. Last lines: $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-400)" || true
}

# 4a, exit 0 and no id: the launcher printed no agent id the placer reads. A zero
# exit says it started something: before, the row went back in line as
# "failed (exit 0)" and was launched again (SPL-5470: ask 2d10de53, its box
# had answered o-805@<box>). Now the ask stays acked, handed (.place.handed: the line
# moves on) and in .place.unread, which spl_spawn_place_stalled never puts back
# in line; a human or the orch records it with do_spl_spawn_placed. One WARN
# with the output, one blocker to the holder.
spl_spawn_place_unread() {  # HOLDER ASK_ID VENDOR SLUG OUT
  local d last
  d="$(spool_asks_dir)"; last="$(tail -3 <<<"$5" | tr '\n' ' ' | cut -c1-400)"
  printf '%s\n' "$2" >>"$d/.place.handed"
  printf '%s\n' "$2" >>"$d/.place.unread"
  do_log "WARN ask ${2:0:8}: the launch of $3:$4 exited 0 but printed no agent id; held, not retried, until it is recorded. Output: $last"
  spl_spawn_q_send "$1" "$1" blocker spawn-queue "**SPAWN QUEUE: ask ${2:0:8} ($3:$4) exited 0 with no agent id read**: the launcher may have started a lane. The ask is held and never retried; find the lane, then record it: \`ASK_ID=${2:0:8} PLACED_AS=<ID>@<box> ./run -a do_spl_spawn_placed\`. Last lines: $last" || true
}

# <asks dir>/.place.dark (SPL-5143), one line per row waiting on a silent box:
# "<ask_id>\t<box>\t<first epoch>\t<last try epoch>\t<told 0|1>". TRIED 1 stamps
# this try; a row seen again keeps its first epoch and told flag.
spl_spawn_place_dark_note() {  # ASK_ID BOX TRIED
  local f tmp
  f="$(spool_asks_dir)/.place.dark"; tmp="$f.$$"
  touch "$f"
  awk -F'\t' -v OFS='\t' -v a="$1" -v b="$2" -v t="$3" -v n="$(date +%s)" '
    $1 == a { first = $3; last = $4; told = $5; next } { print }
    END { print a, b, (first ? first : n), (t ? n : last + 0), told + 0 }' "$f" >"$tmp" && mv -f "$tmp" "$f"
}

# When ASK_ID's wait on a silent box began, for its wait line: the timestamp
# of .place.wait moves on every write, so the start is in the text.
spl_spawn_place_dark_since() {  # ASK_ID
  date -u -d "@$(awk -F'\t' -v a="$1" '$1 == a { print $3 }' "$(spool_asks_dir)/.place.dark")" +%Y-%m-%dT%H:%MZ
}

# A launch started on BOX: it answers, its rows go back in line.
spl_spawn_place_dark_clear() {  # BOX
  local f tmp
  f="$(spool_asks_dir)/.place.dark"; tmp="$f.$$"
  [[ -n "$1" && -s "$f" ]] || return 0
  awk -F'\t' -v b="$1" '$2 != b' "$f" >"$tmp" && mv -f "$tmp" "$f"
}

# 2a. A queued row pinned to a box that gave no reply in the last
# SPAWN_PLACE_DARK_RETRY_MIN HOLDS (SPL-5143, R7 W1): out of the line, so it
# uses none of a tick's SPAWN_PLACE_HOLD_TRIES. Before, five such rows took
# all the tries, every tick. Each box costs one 300 s wait per window. It runs
# after spl_spawn_place_agy_box_hold, which sets the _b box of an agy or mistral
# row (R7 W4). Run again after each HOLD, so the other rows of a box that just
# failed go too.
# Prints ROWS minus the held ones.
spl_spawn_place_dark_hold() {  # MARKED ROWS
  local f id slug pin box last now held=() ps=() retry=$(( ${SPAWN_PLACE_DARK_RETRY_MIN:-30} * 60 ))
  f="$(spool_asks_dir)/.place.dark"
  [[ -s "$f" ]] || { echo "$1"; return 0; }
  now="$(date +%s)"
  while IFS=$'\t' read -r id slug pin; do
    mapfile -t ps < <(spl_spawn_place_slug "$slug")
    box="${ps[0]:-$pin}"
    [[ -n "$box" ]] || continue
    last="$(awk -F'\t' -v b="$box" '$2 == b && $4 > m { m = $4 } END { print m + 0 }' "$f")"
    (( now - last < retry )) || continue
    spl_spawn_place_dark_note "$id" "$box" 0
    spl_spawn_place_wait "$id" "no reply from $box since $(spl_spawn_place_dark_since "$id")"
    do_log "INFO hold: ask ${id:0:8} is pinned to $box, which gave no reply: it stays queued, the box is tried again within ${SPAWN_PLACE_DARK_RETRY_MIN:-30} min" >&2
    held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and ._l) | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))\t\(._b // "")"' <<<"$1")
  jq -c --argjson h "$(spl_spawn_place_json_ids "${held[@]}")" '[.[] | select(.ask_id as $i | $h | index($i) | not)]' <<<"$1"
}

# Drops the .place.dark lines of asks no longer in the queue, then one blocker
# to the holder for the rows dark SPAWN_PLACE_DARK_ALARM_MIN or more and not
# told yet (SPL-5143, R7 W2: the HOLD has no end, so somebody must hear of it).
# A blocker that was not delivered is sent again next tick.
spl_spawn_place_dark_alarm() {  # HOLDER MARKED ROWS
  local f tmp due min="${SPAWN_PLACE_DARK_ALARM_MIN:-120}"
  f="$(spool_asks_dir)/.place.dark"; tmp="$f.$$"
  [[ -s "$f" ]] || return 0
  awk -F'\t' -v ids="$(jq -r '[.[].ask_id] | join(" ")' <<<"$2")" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) K[a[i]] = 1 } $1 in K' "$f" >"$tmp" && mv -f "$tmp" "$f"
  due="$(awk -F'\t' -v n="$(date +%s)" -v s="$(( min * 60 ))" '!$5 && n - $3 >= s { print substr($1, 1, 8) " on " $2 }' "$f" | paste -sd, - | sed 's/,/, /g')"
  [[ -n "$due" ]] || return 0
  spl_spawn_q_send "$1" "$1" blocker spawn-queue "**SPAWN QUEUE: rows pinned to a box that gave no reply for ${min} min or more: ${due}.** They stay queued and the placer tries the box every ${SPAWN_PLACE_DARK_RETRY_MIN:-30} min; the box needs a look, or the rows a decline." || return 0
  awk -F'\t' -v OFS='\t' -v n="$(date +%s)" -v s="$(( min * 60 ))" 'n - $3 >= s { $5 = 1 } { print }' "$f" >"$tmp" && mv -f "$tmp" "$f"
}

# Why ASK_ID waits, kept for the queue view: one "<ask_id>\t<epoch>\t<why>"
# line per ask in <asks dir>/.place.wait; WHY "" drops the ask's line.
spl_spawn_place_wait() {  # ASK_ID WHY
  local f tmp
  f="$(spool_asks_dir)/.place.wait"; tmp="$f.$$"
  { grep -v "^$1"$'\t' "$f" 2>/dev/null; [[ -z "$2" ]] || printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "$2"; } >"$tmp"
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# Prunes <asks dir>/.place.wait. queued IDS: keeps only the lines of IDS
# (ask_ids, one per line). held IDS [WHY_RX]: drops every line whose reason
# matches WHY_RX (default "agy is out of quota") and whose ask is not in IDS,
# keeps every other line.
spl_spawn_place_wait_keep() {  # queued|held IDS [WHY_RX]
  local f tmp
  f="$(spool_asks_dir)/.place.wait"; tmp="$f.$$"
  [[ -s "$f" ]] || return 0
  if awk -F'\t' -v m="$1" -v ids="${2//$'\n'/ }" -v rx="${3:-agy is out of quota}" '
    BEGIN { n = split(ids, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") K[a[i]] = 1 }
    m == "queued" { if ($1 in K) print; next }
    !($3 ~ rx && !($1 in K))' "$f" >"$tmp"; then mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"; else rm -f "$tmp"; fi
}

# 4b. The brief needs the orchestrator: one blocker to the holder.
spl_spawn_place_hand() {  # HOLDER ROW WHY
  local id8
  id8="$(jq -r '.ask_id[0:8]' <<<"$2")"
  if spl_spawn_q_send "$1" "$1" blocker spawn-queue "$(jq -r --arg why "$3" --arg room "${SPAWN_PLACE_ROOM:-}" --arg lock "${SPAWN_PLACE_LOCK_MIN:-30}" '
    "**SPAWN QUEUE: place ask \(.ask_id[0:8]) now** - it is next and the box has room (\($room)). It needs you: \($why).\n\n"
    + "- from \(.from), topic \(.topic), in line \((.wait_s // 0) / 60 | floor) min: \(.summary)\n\n"
    + "Place it with the launcher (spawn-window.sh / spawn-remote.sh), then: `ASK_ID=\(.ask_id[0:8]) PLACED_AS=<ID>@<box> ./run -a do_spl_spawn_placed` (tells the sender). "
    + "Not placed within \($lock) min: it goes back to position 1."' <<<"$2")"; then
    do_log "OK ask $id8 handed to $1 to place ($3)"
    jq -r '.ask_id' <<<"$2" >>"$(spool_asks_dir)/.place.handed"
  else
    spl_spawn_q_op queue "$(jq -r '.ask_id' <<<"$2")" "$1" >/dev/null
    do_log "WARN ask $id8 could not be handed to $1: back in line"
  fi
}
