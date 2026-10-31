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
# @description      blocker asking for the next rows of that class
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
# @description         also tells the holder). A HOLD's reason (e.g. "waiting:
# @description         claude weekly >= 90% on box-a, box-b", SPL-2035) is kept
# @description         in <asks dir>/.place.wait and do_spl_spawn_queue shows it.
# @description         Only a launch starts the SPAWN_PLACE_GAP_MIN slot
# @description         (.place.last); a hand-off (4b) or a hold burns none:
# @description         a HOLD puts .place.last back as it was (SPL-4265),
# @description         and the tick takes the next row the placer can
# @description         launch, the held one keeping its place, up to
# @description         SPAWN_PLACE_HOLD_TRIES rows a tick
# @description      HAND-PINNED SLUG (SPL-2088), the dispatcher's convention:
# @description         hand-<box>-<slug> or <box>hand-<slug> (box id letters and
# @description         digits only) pins the lane to <box>. Its brief is
# @description         <slug>.md (the full slug's file wins when it exists), the
# @description         launch is `SPAWN_BOX=<box> spawn-window.sh ... <slug>`;
# @description         <box> at or past its overflow mark (do_spl_box_pick's BOX
# @description         line: load% >= high * BOX_PICK_OVERFLOW / 100), DEGRADED
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
# @description      AGY OUT (SPL-3018): while agy is out of quota on this box
# @description         (agy's banner in the watchdog's pane capture, or an S2
# @description         kind=limit verdict on an a- lane), a row swapped to agy
# @description         HOLDS when it is a review (brief Kind: review, or
# @description         "review" in its file name or first heading): queued, out
# @description         of the line, the reset in .place.wait; any other such
# @description         row launches claude. A row placed directly as agy:<slug>
# @description         HOLDS too, review or not (SPL-3024): agy was picked on
# @description         purpose, claude would change the vendor. The quota is
# @description         one for the fleet (SPL-3998): the other box's watchdog
# @description         blocker for a live a- lane there holds too
# @description      AGY TARGET BOX (SPL-4020): while another box's watchdog
# @description         limit blocker has its reset ahead (live lane or not),
# @description         an agy row is judged against the box it launches on (a
# @description         pinned slug's box, else do_spl_box_pick's pick with
# @description         BOX_PICK_KIND=agy): that box out -> this box when it is
# @description         not full, else HOLD (queued, out of the line, the
# @description         reset in .place.wait); the box judged is the launch's
# @description         SPAWN_BOX
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
# @description      CATEGORY (spec 143 4.4, SPL-2790): before a launch (4a) the
# @description         brief's "Kind:" and "Category: <path>" are recorded on
# @description         the request (fleet_asks work_kind, category_path) for
# @description         the token rollup by category; a brief without them
# @description         places as before, a refused path is one WARN line
# @description Installed by do_spl_spawn_place_install_cron (every minute).
# @param SPAWN_PLACE_LOCK_MIN (optional) - minutes a placing request may stay unclosed before it goes back in line, default 30
# @param SPAWN_PLACE_GAP_MIN (optional) - minutes between two placements at most (the ceiling), default 10
# @param SPAWN_PLACE_HOLD_TRIES (optional) - rows one tick tries while the launcher answers HOLD (SPL-4265), default 5
# @param SPAWN_PLACE_GAP_FLOOR_MIN (optional) - minutes between two placements at least, when the placed lane shows progress, default 3
# @param TOKEN_BURN_STATE_DIR (optional) - the token burn collector's state dir, whose buckets.tsv shows a lane's progress on this box, default /var/csi/csi-spl/token-burn
# @param SPAWN_PLACE_BURN_CMD (optional, tests) - prints the hub's fleet-tokens answer ({by_agent: [...]}) instead of GET /v1/operator/fleet-tokens
# @param SPOOL_AGENT_CEILING (optional) - the agent window ceiling, default 40
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where <slug>.md (or c001-<slug>.md) is, default <spool root>/dispatch/briefs
# @param SPAWN_PLACE_CNF (optional) - the cnf whose mistral_ui_allowed and mistral_coding_allowed the UI and coding rules read, default <APP_PATH>/csi-spl-cnf/csi-spl/all.env.yaml
# @param SPAWN_PLACE_WORKDIR (optional) - the launcher's WORKDIR, default the checkout this action runs from
# @param SPAWN_PLACE_TMUX_SOCKET (optional) - the box user's tmux socket, default /tmp/tmux-<uid>/default
# @param SPAWN_PLACE_WINDOWS_CMD SPAWN_PLACE_PICK_CMD SPAWN_PLACE_LAUNCH_CMD (optional, tests) - print the window count / the box pick / run the launch
# @param SPAWN_SHARE_SUPPLY_MIN (optional) - minutes between two supply blockers of one class, default 60
# @param SPAWN_SHARE_DISPATCH (optional) - the dispatch lease holder <ID>@<box>; default the lease file <spool root>/dispatch/lease
# @param SPAWN_SHARE_LANES_CMD (optional, tests) - as do_spl_spawn_share
# @param SPAWN_PLACE_LOAD_CMD (optional, tests) - prints the lane map's JSON ({load: [...]}) the other box's agy limit reads liveness from, instead of do_spl_lane_map
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
  if jq -e 'any(.[]; .state == "acked" and ._l and (._h | not))' >/dev/null <<<"$rows"; then
    do_log "INFO placing $(jq -r '[.[] | select(.state == "acked") | .ask_id[0:8]] | join(" ")' <<<"$rows"): one at a time, $(jq '[.[] | select(.state == "queued")] | length' <<<"$rows") queued"
    return 0
  fi
  rows="$(spl_spawn_place_agy_hold "$rows")"
  rows="$(spl_spawn_place_away_hold "$rows")"
  rows="$(spl_spawn_place_pin_hold "$rows")"
  rows="$(spl_spawn_place_agy_box_hold "$rows")"
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
# SPAWN_SHARE_SUPPLY_MIN. Leaves the share it read in SPAWN_PLACE_SHARE.
spl_spawn_place_supply() {  # HOLDER ROWS
  local d c due=() gap=$(( ${SPAWN_SHARE_SUPPLY_MIN:-60} * 60 )) now share to line
  d="$(spool_asks_dir)"; now="$(date +%s)"
  for c in refactor bug; do
    (( now - $(stat -c %Y "$d/.share.$c.last" 2>/dev/null || echo 0) >= gap )) && due+=("$c")
  done
  (( ${#due[@]} > 0 )) || return 0
  share="$(spl_spawn_share)" || { do_log "WARN the live share could not be read: no supply check this tick"; return 0; }
  SPAWN_PLACE_SHARE="$share"
  (( $(jq '.known' <<<"$share") > 0 )) || return 0
  for c in "${due[@]}"; do
    line="$(jq -r --arg c "$c" --slurpfile rows <(printf '%s' "$2") '
      def cls: (.class // "") | if . == "" or . == "ci" then "bug" else . end;
      .by[$c] as $b | (.h24.by[$c].lo // $b.lo) as $lo
      | select($b.pct < $lo and ([$rows[0][] | select(.state == "queued" and cls == $c)] | length) == 0)
      | "\($c) share \($b.pct)% < \($lo)% (\($b.n) of \(.known) live lanes with a class) and no \($c) row is queued"' <<<"$share")"
    [[ -n "$line" ]] || continue
    to="$(spl_spawn_place_dispatch)"
    [[ -n "$to" ]] || { do_log "WARN $line, and nobody holds the dispatch lease: not told"; continue; }
    if spl_spawn_q_send "$1" "$to" blocker spawn-share "**SPAWN SHARE: $line.** Request the next $c rows (a $c round / its rows) and queue them with \`SPAWN_CLASS=$c ./run -a do_spl_spawn_enqueue\`. The bands: fleet-rules-index.md (owner msg 8cb6cc7d); the report: \`./run -a do_spl_spawn_share\`."; then
      touch "$d/.share.$c.last"
      do_log "OK supply: $line; $to told"
    fi
  done
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

# 3b. The queued review seat (placement slug ending in -reviewer) whose ask the
# local bypass log holds on the review-seat GO, first by position; nothing
# when none. The hub keeps such a row unflagged (a bypass is a feature flag
# there, rdb 0195), so the log is its record (spl_spawn_q_enqueue). The ids
# go to jq as a file: the log only grows (SPL-4156).
spl_spawn_place_seat() {  # ROWS
  local f
  f="$(spool_asks_dir)/bypass.tsv"
  [[ -s "$f" ]] || return 0
  declare -F spl_spawn_q_review_seat_go >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-enqueue.func.sh"
  jq -c --slurpfile ids <(awk -F'\t' -v m="$SPL_SPAWN_REVIEW_SEAT_GO" '$3 == m { print $2 }' "$f" | jq -R -s -c 'split("\n") | map(select(length > 0))') \
    '$ids[0] as $ids | [.[] | select(.state == "queued" and ((.placement // "") | sub("^[^:]*:"; "") | test("-reviewer$"))
    and (.ask_id as $a | $ids | index($a)))] | sort_by(.position) | .[0] // empty' <<<"$1"
}

# 1. Placing requests quiet SPAWN_PLACE_LOCK_MIN go back in line. 0 = one did.
spl_spawn_place_stalled() {  # HOLDER ROWS
  local id n=0 lock=$(( ${SPAWN_PLACE_LOCK_MIN:-30} * 60 ))
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    spl_spawn_q_op queue "$id" "$1" >/dev/null || continue
    do_log "INFO ask ${id:0:8} was not placed within ${SPAWN_PLACE_LOCK_MIN:-30} min: back in line at its place"
    n=$((n + 1))
  done < <(jq -r --argjson l "$lock" '.[] | select(.state == "acked" and .quiet_s >= $l) | .ask_id' <<<"$2")
  (( n > 0 ))
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
    [[ "$agent" =~ ^[acgmq]-[0-9]{3}(@[a-z0-9-]+)?$ ]] || agent=""
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
# or past its overflow mark, CORDONED, DEGRADED or AT CAP. No line for it: returns 1
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
  id="$(jq -r '.ask_id' <<<"$2")"
  place="$(jq -r '.placement // ""' <<<"$2")"
  mapfile -t ps < <(spl_spawn_place_slug "${place#*:}")
  brief="$(spl_spawn_place_brief "${place#*:}")"
  [[ -z "$place" || -z "$brief" ]] || closed="$(spl_spawn_place_epic_closed "$brief")"
  [[ "$closed" != *$'\t'auto-closed ]] || closed="$(spl_spawn_place_reopen "$brief" "${place#*:}" "${closed%$'\t'auto-closed}")"
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

# Reopen the auto-closed epic BRIEF names (li_epic_reopen) as the lease's desk
# (spl_lane_issue_desk, in a subshell: its ENV / DESK_AGENT stay there).
# Prints nothing when it reopened, else WHY with the failure for the hand-off.
# COMMENT (optional) replaces the placer's comment on the epic (the enqueue's).
spl_spawn_place_reopen() {  # BRIEF SLUG WHY [COMMENT]
  local epic out
  declare -F li_epic_reopen >/dev/null ||
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || { printf '%s\n' "$3"; return 0; }
  epic="$(li_brief_epic_spec "$1" 2>/dev/null)"; epic="${epic#*$'\t'}"
  if out="$(
    declare -F spl_lane_issue_desk >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-issue.func.sh"
    spl_lane_issue_desk "${SPOOL_ROOT:-/var/spool-hub}" 0 &&
      li_epic_reopen "$epic" "${4:-Reopened by do_spl_spawn_place: auto-closed (SPL-1729), head brief $2 names it on its Epic: line, and its lane files its issue under it (SPL-2558).}" 2>&1
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
  ids="$(grep -m1 -iE '^Author:' "$1" | grep -oE '\b[acgmq]-[0-9]{3}\b')"
  [[ -n "$ids" ]] || ids="$(grep -oE '\b[acgmq]-[0-9]{3}\b' "$1")"
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
# of quota here (spl_spawn_place_agy_out, SPL-3018) launches claude instead,
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
  if [[ "$to" == agy ]] && ! spl_spawn_place_review "$2" && out="$(spl_spawn_place_agy_out)" && [[ -n "$out" ]]; then
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
# probe (<probe-dir>/agy.ok, its mtime) is dropped too.
spl_spawn_place_agy_out() {
  local wd="${LANE_MIX_WD_DIR:-$SPOOL_ROOT/dispatch/wd}" now f line t best=0 ev="" hit live since=0 id
  local ok="${SPAWN_PLACE_PROBE_DIR:-$SPOOL_ROOT/dispatch/vendor-probe}/agy.ok"
  now="$(date +%s)"
  live="$(spl_spawn_place_agy_live)"
  [[ -e "$ok" ]] && since="$(stat -c %Y "$ok" 2>/dev/null || echo 0)"
  declare -F _spl_lane_mix_limit >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  hit="$(_spl_lane_mix_limit agy "$SPOOL_ROOT" "${LANE_MIX_REGISTRY:-$SPOOL_ROOT/registry.tsv}" "$since" "$live")"
  [[ -z "$hit" ]] || best=$(( ${hit%%$'\t'*} + ${LANE_MIX_LIMIT_FRESH:-21600} )) ev="${hit#*$'\t'}"
  for f in "$wd"/ctx*/a-*/pane; do
    id="$(basename "$(dirname "$f")")"
    [[ -z "$live" || "$live" == *"|$id|"* ]] || continue
    line="$(grep -aoE 'Individual quota reached.*Resets in ([0-9]+h)?([0-9]+m)?([0-9]+s)?' "$f" 2>/dev/null | tail -n 1)"
    [[ "$line" =~ Resets\ in\ (([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?$ ]] || continue
    t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    (( t > since )) || continue
    t=$(( t + 10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 + 10#${BASH_REMATCH[6]:-0} ))
    (( t > best )) && best="$t" ev="$id banner, Resets in ${line##*Resets in }"
  done
  hit="$(spl_spawn_place_agy_remote "$since" "$now")"
  [[ -z "$hit" ]] || (( ${hit%%$'\t'*} <= best )) || best="${hit%%$'\t'*}" ev="${hit#*$'\t'}"
  (( best > now )) || return 0
  printf 'agy is out of quota until %s (%s)\n' "$(date -u -d "@$best" +%FT%TZ)" "$ev"
}

# agy out of quota on ANOTHER box (SPL-3998): "<reset epoch>\t<evidence>" for
# the latest reset, else nothing. The records above are this box's watchdog's
# only, so a limit on the other box never held a row placed from here (sat
# launched a-963 onto the main box 2026-10-28 00:45Z, 5 min after a-958 and
# a-960 hit it there). agy's quota is one for the fleet, not one per box: on 2026-10-27
# the a- lanes of both boxes hit it within 35 min and 8 of the 9 blockers named
# the same reset (2026-10-30T22:01..22:04Z), so the hold is fleet-wide. The
# record is the other box's watchdog blocker to the orchestrator
# ("WATCHDOG (093 S2 kind=limit): <id> is on its usage limit until <UTC>...
# box <box>,"), which the hub relays into an inbox here and the ack archives:
# $SPOOL_ROOT/*/{inbox,archive}/*--watchdog-093-s2-kind-limit-a-*.json. It
# counts while its reset is ahead, it is newer than <since> (agy.ok) and the
# lane is live on its box (SPL-3846): in that box's busy_ids of the lane map
# load, read from its BOX-0 row (src box). No load for that box, or only its
# lane rows (src rows): liveness unknown, the record counts.
spl_spawn_place_agy_remote() {  # SINCE NOW
  local recs load="" id box u f
  recs="$(spl_spawn_place_agy_recs "$1" "$2")"
  [[ -n "$recs" ]] || return 0
  if [[ -n "${SPAWN_PLACE_LOAD_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    load="$($SPAWN_PLACE_LOAD_CMD 2>/dev/null)"
  else
    load="$(LANE_FORMAT=json timeout "${SPAWN_SHARE_TIMEOUT:-90}" bash "$PROJ_PATH/run" -a do_spl_lane_map 2>/dev/null | grep -E '^\{' | tail -1)"
  fi
  [[ -n "$load" ]] || load='{}'
  while IFS=$'\t' read -r id box u f; do
    jq -e --arg b "$box" --arg i "$id" 'any(.load[]?; .box == $b and .src != "rows" and ((.busy_ids // []) | index($i) == null))' <<<"$load" >/dev/null 2>&1 && continue
    printf '%s\t%s\n' "$u" "$id@$box S2 kind=limit, its watchdog's blocker $f"
  done <<<"$recs" | sort -n | tail -n 1
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
# "<box>\t<UTC> (<evidence>)" line per box, its latest reset. Every blocker
# whose reset is ahead counts, live lane or not and whatever this box's
# agy.ok says: a closed seat leaves its box's login on the limit, and a probe
# here proves nothing about another box's login.
spl_spawn_place_agy_boxes() {
  local id box u m
  while IFS=$'\t' read -r id box u m; do
    [[ -n "$id" ]] && printf '%s\t%s\t%s (%s@%s S2 kind=limit, its watchdog'"'"'s blocker %s)\n' \
      "$box" "$u" "$(date -u -d "@$u" +%FT%TZ)" "$id" "$box" "$m"
  done <<<"$(spl_spawn_place_agy_recs 0 "$(date +%s)")" | sort -t $'\t' -k1,1 -k2,2nr | awk -F'\t' '!s[$1]++ { print $1 "\t" $3 }'
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

# 2c. While agy is out of quota here (spl_spawn_place_agy_out), a queued row
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
    [[ -n "$out" ]] || out="$(spl_spawn_place_agy_out)"
    [[ -n "$out" ]] || break
    why="$why, and $out"
    spl_spawn_place_wait "$id" "$why"
    do_log "INFO hold: ask ${id:0:8}: $why; it stays queued" >&2
    held+=("$id")
  done < <(jq -r '.[] | select(.state == "queued" and ._l and ((.placement // "") | test("^(mistral|agy):")))
    | "\(.ask_id)\t\(.placement | sub(":.*$"; ""))\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$1")
  spl_spawn_place_wait_keep held "$(printf '%s\n' "${held[@]}")"
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
# at or past its overflow mark, CORDONED, DEGRADED or AT CAP
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
# against the box it goes to (SPL-4020): each box's agy login has its own
# quota (2026-10-28: agy answered on sat while every a- seat on the main box
# showed "Individual quota reached" until 11-03), and once those seats were
# closed no record held, so sat launched a-097 onto the main box. While
# another box's watchdog limit blocker has its reset ahead
# (spl_spawn_place_agy_boxes), the target is the pinned slug's box, else
# do_spl_box_pick's pick (BOX_PICK_KIND=agy). Target out: an unpinned row
# goes to this box when it is not full (spl_spawn_place_pin_full); else it
# HOLDS, queued, out of this tick's line, the reset in .place.wait. Target in:
# the row carries it as _b, the launch's SPAWN_BOX, so the launch goes where
# it was judged. Prints ROWS minus the held ones.
spl_spawn_place_agy_box_hold() {  # MARKED ROWS
  local outs id vendor slug brief pin box pout="" lout="" line why full held=() to='{}'
  local rx="^agy on [a-z0-9-]+ is at its quota limit until "
  outs="$(spl_spawn_place_agy_boxes)"
  [[ -n "$outs" ]] || { spl_spawn_place_wait_keep held "" "$rx"; echo "$1"; return 0; }
  while IFS=$'\t' read -r id vendor slug; do
    brief="$(spl_spawn_place_brief "$slug")"
    [[ -n "$brief" ]] || continue
    if [[ "$vendor" == mistral ]]; then
      [[ "$(spl_spawn_place_swap mistral "$brief" | cut -f1)" == agy ]] || continue
      if ! spl_spawn_place_review "$brief"; then
        [[ -n "$lout" ]] || lout="$(spl_spawn_place_agy_out)" lout="${lout:--}"
        [[ "$lout" == - ]] || continue
      fi
    fi
    pin="$(spl_spawn_place_slug "$slug" | sed -n 1p)" box="$pin"
    if [[ -z "$box" ]]; then
      [[ -n "$pout" ]] || pout="$(BOX_PICK_KIND=agy spl_spawn_place_pick_out)"
      box="$(sed -n 's/^pick=\([a-z0-9][a-z0-9-]*\).*$/\1/p' <<<"$pout" | tail -1)"
      [[ -n "$box" && "$box" != hold && "$box" != nokind ]] || continue
    fi
    line="$(awk -F'\t' -v b="$box" '$1 == b { print $2; exit }' <<<"$outs")"
    if [[ -z "$line" ]]; then
      [[ -n "$pin" ]] || to="$(jq -c --arg i "$id" --arg b "$box" '.[$i] = $b' <<<"$to")"
      continue
    fi
    why="agy on $box is at its quota limit until $line" full=""
    if [[ -z "$pin" ]] && ! full="$(spl_spawn_place_pin_full "$ASKS_BOX" "$pout")"; then
      do_log "INFO ask ${id:0:8}: $why: it launches on $ASKS_BOX" >&2
      to="$(jq -c --arg i "$id" --arg b "$ASKS_BOX" '.[$i] = $b' <<<"$to")"
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
# SPAWN_BOX.
spl_spawn_place_launch() {  # HOLDER ROW VENDOR SLUG BRIEF [PIN]
  local holder="$1" id out err rc=0 agent why
  id="$(jq -r '.ask_id' <<<"$2")"
  err="$(mktemp)" || return 1
  # The lane row's topic (spec 153 3.4): the ask's topic, set once for both
  # launch lines, only when it is a full hub uuid (a dispatch-<topic8> alias
  # is a spool task, not a hub topic: it sets nothing)
  if [[ "$(jq -r '.topic // ""' <<<"$2")" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]]; then
    local -x SPAWN_LANE_TOPIC="${BASH_REMATCH[0]}"
  fi
  # stdout is the launcher's "<ID>[@<box>] <PANE>"; its stderr names other ids
  if [[ -n "${SPAWN_PLACE_LAUNCH_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(SPAWN_BOX="${6:-}" $SPAWN_PLACE_LAUNCH_CMD "$3" auto "${SPAWN_PLACE_WORKDIR:-$APP_PATH}" "$5" "$4" 2>"$err")" || rc=$?
  else
    out="$(SPAWN_BOX="${6:-}" SPOOL_AGENT_ID="${holder%@*}" bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/spawn-window.sh" \
      "$3" auto "${SPAWN_PLACE_WORKDIR:-$APP_PATH}" "$5" "$4" 2>"$err" 6>&-)" || rc=$?
  fi
  out="$out"$'\n'"$(tail -3 "$err")"; rm -f "$err"
  agent="$(grep -oE '^[acgmq]-[0-9]{3}(@[a-z0-9][a-z0-9-]{0,31})?( |$)' <<<"$out" | tail -1 | tr -d ' ')"
  if (( rc == 0 )) && [[ -n "$agent" ]]; then
    [[ "$agent" == *@* ]] || agent="$agent@$ASKS_BOX"
    printf '%s\n' "$agent" >"$(spool_asks_dir)/.place.agent"
    spl_spawn_place_wait "$id" ""
    spl_spawn_placed_close "$id" "$holder" "$agent"
    declare -F spl_review_notify_placed >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-review-notify.func.sh"
    spl_review_notify_placed "$holder" "$agent" "$4" "$5"
    return 0
  fi
  spl_spawn_q_op queue "$id" "$holder" >/dev/null
  if (( rc == 10 )); then
    why="$(sed -n 's/^spawn-window: HOLD [^:]*: //p' <<<"$out" | tail -1 | sed 's/: queue the lane, spawn nothing.*$//; s/\. Queue it; nothing was spawned\.$//')"
    spl_spawn_place_wait "$id" "${why:-every box is past its load mark}"
    do_log "INFO ask ${id:0:8}: the launcher says HOLD (${why:-every box is past its load mark}): back in line at position 1"
    return 10
  fi
  do_log "WARN ask ${id:0:8}: the launch of $3:$4 failed (exit $rc): back in line"
  spl_spawn_q_send "$holder" "$holder" blocker spawn-queue "**SPAWN QUEUE: the launch of ask ${id:0:8} ($3:$4) failed** (spawn-window exit $rc); it is back at position 1 and the placer retries it in ${SPAWN_PLACE_GAP_MIN:-10} min. Last lines: $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-400)" || true
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
