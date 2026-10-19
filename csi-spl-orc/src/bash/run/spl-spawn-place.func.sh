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
# @description      after it once the placed lane's heartbeat progress_ts moved
# @description      past the launch, else SPAWN_PLACE_GAP_MIN (10) after it (no
# @description      heartbeat = the ceiling). No room: it stays queued, one
# @description      INFO line says why
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
# @description      otherwise the queued row of the class furthest under its band
# @description      of the live lanes (do_spl_spawn_share) is taken, a class over
# @description      its band only when no other class waits; ties refactor > bug
# @description      > feature, then the queue's order. The rule's one home:
# @description      csi-spl-doc/doc/md/fleet-rules-index.md
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
# @description         (.place.last); a hand-off (4b) or a hold burns none
# @description      HAND-PINNED SLUG (SPL-2088), the dispatcher's convention:
# @description         hand-<box>-<slug> or <box>hand-<slug> (box id letters and
# @description         digits only) pins the lane to <box>. Its brief is
# @description         <slug>.md (the full slug's file wins when it exists), the
# @description         launch is `SPAWN_BOX=<box> spawn-window.sh ... <slug>`;
# @description         <box> at or past its overflow mark (do_spl_box_pick's BOX
# @description         line: load% >= high * BOX_PICK_OVERFLOW / 100), DEGRADED
# @description         or AT CAP -> HOLD: it stays queued, the reason in
# @description         .place.wait, nothing acked
# @description      UI RULE (owner HUM-10, t1 b61851fb): a mistral placement whose
# @description         brief names csi-spl-wui/ launches claude instead while
# @description         cnf env.box.agent_split.mistral_ui_allowed is not true
# @description         (spl_lane_mix_mistral_ui_off, do_spl_vendor_ui_retest)
# @description      CODING RULE (owner HUM-10, t1 b61851fb, msg 91bf8278): a
# @description         mistral placement whose brief's "Kind:" is not
# @description         specs_and_docs or i18n (none counts as coding) launches
# @description         claude instead while cnf
# @description         env.box.agent_split.mistral_coding_allowed is not true
# @description         (spl_lane_mix_mistral_code_off); do_spl_spawn_enqueue
# @description         refuses such a placement up front
# @description      b. otherwise (no placement, no brief file here, or a brief
# @description         whose epic is done, diss or archived on the hub, SPL-2508:
# @description         the brief needs judgement) the holder gets ONE blocker
# @description         "place ask X now" with the summary and the close command
# @description         (do_spl_spawn_placed); 1 brings it back if it is not placed
# @description Installed by do_spl_spawn_place_install_cron (every minute).
# @param SPAWN_PLACE_LOCK_MIN (optional) - minutes a placing request may stay unclosed before it goes back in line, default 30
# @param SPAWN_PLACE_GAP_MIN (optional) - minutes between two placements at most (the ceiling), default 10
# @param SPAWN_PLACE_GAP_FLOOR_MIN (optional) - minutes between two placements at least, when the placed lane's heartbeat moved, default 3
# @param SPOOL_AGENT_CEILING (optional) - the agent window ceiling, default 40
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where <slug>.md (or c001-<slug>.md) is, default <spool root>/dispatch/briefs
# @param SPAWN_PLACE_CNF (optional) - the cnf whose mistral_ui_allowed and mistral_coding_allowed the UI and coding rules read, default <APP_PATH>/csi-spl-cnf/csi-spl/all.env.yaml
# @param SPAWN_PLACE_WORKDIR (optional) - the launcher's WORKDIR, default the checkout this action runs from
# @param SPAWN_PLACE_TMUX_SOCKET (optional) - the box user's tmux socket, default /tmp/tmux-<uid>/default
# @param SPAWN_PLACE_WINDOWS_CMD SPAWN_PLACE_PICK_CMD SPAWN_PLACE_LAUNCH_CMD (optional, tests) - print the window count / the box pick / run the launch
# @param SPAWN_SHARE_SUPPLY_MIN (optional) - minutes between two supply blockers of one class, default 60
# @param SPAWN_SHARE_DISPATCH (optional) - the dispatch lease holder <ID>@<box>; default the lease file <spool root>/dispatch/lease
# @param SPAWN_SHARE_LANES_CMD (optional, tests) - as do_spl_spawn_share
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
  rows="$(spl_spawn_place_line "$rows")"
  head="$(jq -c '.[0] // empty' <<<"$rows")"
  [[ -n "$head" ]] || { do_log "INFO the spawn queue is empty, or holds only asks for the holder while one is with it"; return 0; }
  if why="$(spl_spawn_place_no_room)"; then
    do_log "INFO hold: $why; ask $(jq -r '.ask_id[0:8]' <<<"$head") stays position $(jq -r '"\(.position) of \(.queue_len)"' <<<"$head")"
    return 0
  fi
  head="$(spl_spawn_place_band "$head" "$rows")"
  spl_spawn_place_take "$holder" "$(jq -c 'del(._l, ._h)' <<<"$head")"
}

# 2. Marks each row: _l = the placer can launch it (a placement and its brief
# file here), _h = it was handed to the holder (<asks dir>/.place.handed, one
# ask_id per line, pruned to the rows still in line).
spl_spawn_place_mark() {  # ROWS
  local f id slug launchable=() handed=()
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

# 0. The supply blocker: refactor or bug under its band, nothing of it
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
    line="$(jq -r --arg c "$c" --argjson rows "$2" '
      def cls: (.class // "") | if . == "" or . == "ci" then "bug" else . end;
      .by[$c] as $b | select($b.pct < $b.lo and ([$rows[] | select(.state == "queued" and cls == $c)] | length) == 0)
      | "\($c) share \($b.pct)% < \($b.lo)% (\($b.n) of \(.known) live lanes with a class) and no \($c) row is queued"' <<<"$share")"
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

# 3b. The row the bands pick, HEAD when it is ci or flagged, or when the
# share cannot be read (the hub's order holds).
spl_spawn_place_band() {  # HEAD ROWS
  local share pick
  if jq -e '(.class // "") == "ci" or (.flag // "") != ""' >/dev/null <<<"$1"; then printf '%s' "$1"; return 0; fi
  share="${SPAWN_PLACE_SHARE:-}"
  [[ -n "$share" ]] || share="$(spl_spawn_share)" || { do_log "WARN the live share could not be read: the queue's order holds" >&2; printf '%s' "$1"; return 0; }
  pick="$(jq -c --argjson share "$share" '
    def cls: (.class // "") | if . == "" or . == "ci" then "bug" else . end;
    [.[] | select(.state == "queued") | cls as $c | $share.by[$c] as $b
     | (if $b.pct < $b.lo then 0 elif $c == "feature" or $b.pct < $b.hi then 1 else 3 end) as $t
     | . + {_t: $t, _o: ({"refactor": 0, "bug": 1, "feature": 2}[$c]), _c: $c, _p: $b.pct,
            _s: (if $t == 0 then ($b.lo - $b.pct) / $b.lo elif $t == 1 and $c != "feature" then ($b.hi - $b.pct) / $b.hi else 0 end)}]
    | sort_by(._t, -._s, ._o, .position) | .[0] // empty' <<<"$2")"
  [[ -n "$pick" ]] || { printf '%s' "$1"; return 0; }
  do_log "INFO band pick: ask $(jq -r '"\(.ask_id[0:8]) (\(._c) at \(._p)%, queue position \(.position))"' <<<"$pick") of $(spl_spawn_share_line "$share")" >&2
  jq -c 'del(._t, ._o, ._c, ._p, ._s)' <<<"$pick"
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
# placed lane (<asks dir>/.place.agent, written by its launch) moved its
# heartbeat's progress_ts past the launch, else at SPAWN_PLACE_GAP_MIN (10).
# A missing or unreadable heartbeat, a lane on another box or a failed launch
# (no .place.agent newer than .place.last) holds to the ceiling.
spl_spawn_place_gap_hold() {
  local d last now agent="" hb ts="" ceil=$(( ${SPAWN_PLACE_GAP_MIN:-10} * 60 )) floor=$(( ${SPAWN_PLACE_GAP_FLOOR_MIN:-3} * 60 ))
  d="$(spool_asks_dir)"; now="$(date +%s)"
  last="$(stat -c %Y "$d/.place.last" 2>/dev/null || echo 0)"
  (( now - last >= ceil )) && return 1
  (( floor > ceil )) && floor=$ceil
  (( now - last < floor )) && { printf 'the last placement started under %s min ago (the floor)' "${SPAWN_PLACE_GAP_FLOOR_MIN:-3}"; return 0; }
  if (( $(stat -c %Y "$d/.place.agent" 2>/dev/null || echo 0) >= last )); then
    agent="$(head -1 "$d/.place.agent" 2>/dev/null)"
    [[ "$agent" =~ ^[acgmq]-[0-9]{3}(@[a-z0-9-]+)?$ ]] || agent=""
    for hb in "$SPOOL_ROOT/$agent/heartbeat.json" "$SPOOL_ROOT/${agent%@"$ASKS_BOX"}/heartbeat.json"; do
      [[ -n "$agent" && -r "$hb" ]] || continue
      ts="$(jq -r '.progress_ts // empty' "$hb" 2>/dev/null)"
      [[ -n "$ts" ]] && break
    done
  fi
  if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then ts="$(date -u -d "$ts" +%s 2>/dev/null || echo 0)"
  elif [[ ! "$ts" =~ ^[0-9]+$ ]]; then ts=0; fi
  (( ts > 0 && ts >= last )) && return 1
  printf 'the last placement started under %s min ago and %s has no heartbeat progress since' "${SPAWN_PLACE_GAP_MIN:-10}" "${agent:-its lane}"
  return 0
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
# (spawn-window judges it).
spl_spawn_place_pin_full() {  # BOX
  local line
  line="$(grep -E "^BOX $1 " <<<"$(spl_spawn_place_pick_out)" | tail -1)"
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

# 4. Take the head: placing, then launch it or hand it to the holder.
spl_spawn_place_take() {  # HOLDER HEAD
  local holder="$1" id place brief why closed="" ps=()
  id="$(jq -r '.ask_id' <<<"$2")"
  place="$(jq -r '.placement // ""' <<<"$2")"
  mapfile -t ps < <(spl_spawn_place_slug "${place#*:}")
  brief="$(spl_spawn_place_brief "${place#*:}")"
  if [[ -n "$place" && -n "$brief" && -n "${ps[0]}" ]] && why="$(spl_spawn_place_pin_full "${ps[0]}")"; then
    spl_spawn_place_wait "$id" "pinned to ${ps[0]}: $why"
    do_log "INFO hold: ask ${id:0:8} is pinned to ${ps[0]}: $why; it stays queued"
    return 0
  fi
  [[ -z "$place" || -z "$brief" ]] || closed="$(spl_spawn_place_epic_closed "$brief")"
  spl_spawn_q_op ack "$id" "$holder" >/dev/null || return 0
  if [[ -n "$place" && -n "$brief" && -z "$closed" ]]; then
    touch "$(spool_asks_dir)/.place.last"
    spl_spawn_place_launch "$holder" "$2" "$(spl_spawn_place_vendor "${place%%:*}" "$brief" "$id")" "${ps[1]}" "$brief" "${ps[0]}"
  else
    spl_spawn_place_hand "$holder" "$2" "$(if [[ -n "$closed" ]]; then echo "$closed"; elif [[ -z "$place" ]]; then echo "no placement was recorded"; else echo "no brief file for ${place#*:} under ${SPAWN_PLACE_BRIEF_DIR:-$SPOOL_ROOT/dispatch/briefs}"; fi)"
  fi
}

# The brief's epic is closed on the hub (li_brief_epic_closed, SPL-2508): the
# lane's issue would be refused at launch (unknown_parent, spawn-window exit
# 12) and the row retried every SPAWN_PLACE_GAP_MIN. It goes to the holder
# once instead, the reason in the blocker; nothing is launched.
spl_spawn_place_epic_closed() {  # BRIEF
  declare -F li_brief_epic_closed >/dev/null ||
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || return 0
  li_brief_epic_closed "$1"
}

# The vendor to launch: VENDOR, except mistral on UI work while the cnf
# switch mistral_ui_allowed is not true, or on a coding kind while
# mistral_coding_allowed is not true -> claude (the UI and coding rules,
# spl-lane-mix.func.sh, owner HUM-10 t1 b61851fb). A row queued before the
# enqueue refused it is launched, not dropped.
spl_spawn_place_vendor() {  # VENDOR BRIEF ASK_ID
  local why cnf="${SPAWN_PLACE_CNF:-$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml}"
  [[ "$1" == mistral ]] || { echo "$1"; return 0; }
  declare -F spl_lane_mix_mistral_ui_off >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  why="$(spl_lane_mix_mistral_ui_off "$cnf" "$2" "")"
  [[ -n "$why" ]] || why="$(spl_lane_mix_mistral_code_off "$cnf" "$(spl_lane_mix_brief_kind "$2")")"
  [[ -n "$why" ]] || { echo "$1"; return 0; }
  do_log "INFO ask ${3:0:8}: placed as mistral, launched as claude: $why" >&2
  echo claude
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

# 4a. The existing launcher. The new id closes the ask; HOLD or a failure
# puts it back in line. PIN (a hand-pinned slug's box) is its SPAWN_BOX.
spl_spawn_place_launch() {  # HOLDER ROW VENDOR SLUG BRIEF [PIN]
  local holder="$1" id out err rc=0 agent why
  id="$(jq -r '.ask_id' <<<"$2")"
  err="$(mktemp)" || return 1
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
    return 0
  fi
  spl_spawn_q_op queue "$id" "$holder" >/dev/null
  if (( rc == 10 )); then
    why="$(sed -n 's/^spawn-window: HOLD [^:]*: //p' <<<"$out" | tail -1 | sed 's/: queue the lane, spawn nothing.*$//; s/\. Queue it; nothing was spawned\.$//')"
    spl_spawn_place_wait "$id" "${why:-every box is past its load mark}"
    do_log "INFO ask ${id:0:8}: the launcher says HOLD (${why:-every box is past its load mark}): back in line at position 1"
    return 0
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
