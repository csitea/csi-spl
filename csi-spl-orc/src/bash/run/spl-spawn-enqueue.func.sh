#!/bin/bash
# @description Put a spawn request in line (owner HUM-10, t1 c9beaa77; rdb
# @description 0180): the ask goes queued on the hub with its position, and its
# @description sender is told on its task "queued, position N of M, placed when
# @description the box has room". From then on the asks tick never re-raises,
# @description escalates or dead-letters it; the placer (do_spl_spawn_place)
# @description takes it when it is position 1 and the box has room. The
# @description acting orchestrator runs this instead of acking a spawn request
# @description it cannot place now. Enqueueing a queued ask again keeps its
# @description place (and sets a new placement when one is given).
# @description Every request carries its work class (SPL-1817, rdb 0195): the
# @description queue places by class and the placer keeps the bands of the live
# @description lanes; the rule's one home is
# @description csi-spl-doc/doc/md/fleet-rules-index.md.
# @description A SPAWN_PLACE brief with no `Issue:` key names a spec folder on
# @description origin/master (`Spec:` line) and its epic (`Epic: SPL-<n>`, or
# @description the spec's pin), or the ask is not queued (one FATAL line): the
# @description placer would file its issue, and there is no issue without an
# @description epic and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6).
# @description An epic that is done, diss or archived on the hub refuses the
# @description ask the same way (SPL-2508): the hub would refuse the lane's
# @description issue under it ("unknown_parent") at launch. An epic the hub
# @description auto-closed (SPL-1729) is reopened instead, never refused (SPL-3060).
# @description A SPAWN_PLACE brief that names no discussion, on an ask whose
# @description topic is no hub topic (a dispatch-<word> task), is refused the
# @description same way, with the placer's "lane refused, no discussion" line
# @description (SPL-5325; the placer's check, spl_spawn_place_no_links).
# @description An ask whose topic (its discussion, else a hub topic or a
# @description dispatch-<topic8> task) or ASK_DISCUSSION is archived on the hub
# @description is refused the same way (SPL-5671), with the placer's read
# @description (spl_spawn_topic_archived): at the head the placer would decline
# @description it (SPL-4955). Re-raise the request on a live task. A read that
# @description fails, or a binary or hub too old for it, queues as before with
# @description one WARN line.
# @description SPAWN_AFTER (spec 157 4.2, SPL-5874) makes a dependent row: it
# @description is written into the row's brief as `After: <x>` (+ `After-Delay:`)
# @description and the placer holds the row until <x> has landed on origin/master
# @description (spl-spawn-after.func.sh). An unknown key or slug, a diss key, the
# @description row's own slug or a row with no brief here is refused (one FATAL
# @description line, nothing queued); a hand-written After: line is checked the same.
# @description A docs lane on a key it does not own shares it (SPL-6167): a
# @description SPAWN_PLACE brief of kind specs_and_docs with an `Issue: <KEY>`
# @description line and no `Issue-Role:` line gets `Issue-Role: shared`
# @description appended once KEY's card is read from the hub (its scope is never
# @description this placement's lane, which does not exist yet), so the lane
# @description can /exit-clean without closing KEY. A failed card read leaves
# @description the brief as it is, with one WARN line.
# @param SPAWN_CLASS (required) - ci (a CI-red fix on trunk), refactor, bug or feature; no default, never guessed
# @param SPAWN_URGENT (optional) - 1: a bug placed even over its band (owner-reported prd breakage; the dispatcher's call)
# @param SPAWN_BYPASS (optional) - the owner message id (a UUID) that explicitly asked for this feature outside the bands; ONLY on the owner's ask, recorded and listed by do_spl_spawn_share. The owner's review-seat GO (SPL_SPAWN_REVIEW_SEAT_GO) also takes a review seat of class refactor or bug (SPL-3349), queued as a feature + bypass, the hub's one flag ahead of the bands (SPL-5638); unset on a review seat (a SPAWN_PLACE slug ending in -reviewer, no SPAWN_URGENT) it IS that GO (SPL-3762)
# @param ASK_ID (required) - the ask id, or its first 8 hex digits (do_spl_asks_open prints them)
# @param SPAWN_PLACE (optional) - <vendor>:<slug>: the placer launches it itself, `spawn-window.sh <vendor> auto <workdir> <brief> <slug>`, with the brief file <slug>.md under SPAWN_PLACE_BRIEF_DIR on the orch box. Unset: the placer hands it to the orchestrator when it is next
# @param SPAWN_KIND (optional) - the lane's task kind (spec 115); unset reads the "Kind:" of the brief <slug>.md. A mistral placement of any kind but specs_and_docs or i18n is refused (owner HUM-10, t1 b61851fb, msg 91bf8278: mistral does docs and reviews only) while cnf env.box.agent_split.mistral_coding_allowed is not true; a mistral placement of a review seat (Kind: review, reviews or code_review, or a -reviewer, -review or panel-seat slug) is refused while env.box.agent_split.mistral_review_allowed is not true (owner HUM-10, t1 91992830, msgs 65a45673 and 591ca574)
# @param ASK_DISCUSSION (optional) - the owner topic the ask works for, a lowercase UUID (spec 150 row B10b): the queue ranks by its priority. The hub fills it while the ask has none, never overwrites; unset, the hub's resolve of a topic dispatch-<topic8> stands
# @param SPAWN_PARENT_LANE (optional) - the agent id (<ID> or <ID>@<box>) of the live lane this is a helper of (spec 153 3.22.9, row Q9): needs SPAWN_PLACE; the parent's priority (its issue's, 1..5) allows cnf env.box.prio_helpers helpers at once (queued or live, counted by the `Parent-Lane:` line of their briefs); at the allowance the ask is refused (one FATAL line, nothing queued), under it the brief gets `Parent-Lane: <ID>` and the ask the parent's discussion
# @param SPAWN_PARENT_PRIO_CMD (optional) - test seam: <cmd> <issue key> prints that issue's priority; unset reads it from the hub through the desk
# @param SPAWN_AFTER (optional) - an issue key (SPL-123) or a row slug the row waits on: placed only once it has landed on origin/master (an issue key: a commit closing it by the close rule; a slug: its lane's issue so); needs SPAWN_PLACE and its brief here
# @param SPAWN_AFTER_DELAY (optional) - whole minutes after that landing before the row is placed, default 0 (none); the rounds rulebook R16 allows 30
# @param ASK_BY (optional) - the acting agent, <ID>@<box>; default this machine's orchestrator
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=refactor ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=bug SPAWN_PLACE=claude:hub-pg-split ./run -a do_spl_spawn_enqueue
# @example ASK_ID=9d54a51b SPAWN_CLASS=feature SPAWN_PLACE=claude:c002-spec170-b3 SPAWN_AFTER=SPL-5001 SPAWN_AFTER_DELAY=30 ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=feature SPAWN_PLACE=claude:c091-helper-tests SPAWN_PARENT_LANE=c-091 ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=bug ASK_DISCUSSION=59f725e4-08ca-4e6e-8490-1902a708eba3 ./run -a do_spl_spawn_enqueue
# @example ASK_ID=8a70dfd7 SPAWN_CLASS=feature SPAWN_BYPASS=8cb6cc7d-7628-4ac3-be00-86e427bb3487 ./run -a do_spl_spawn_enqueue
# @example ASK_ID=de5714db SPAWN_CLASS=bug SPAWN_BYPASS=994f2257-8ad1-4010-88c8-4f0a16230937 SPAWN_PLACE=agy:c002-ar1-05-agy-r7-reviewer ./run -a do_spl_spawn_enqueue

do_spl_spawn_enqueue() {
  local by id row pos len rc=0
  spl_spawn_q_init || return 1
  spl_asks_discussion_ok || return 1
  by="$(spl_asks_by)" || return 1
  id="$(spl_spawn_q_resolve)" || return 1
  # before the archive read: a helper takes its parent's discussion (spec 153 3.22.9)
  spl_spawn_q_parent "$id" || return 1
  spl_spawn_q_enqueue_archived "$id" || return 1
  # before the queue op: the position it answers ranks by this discussion's priority
  spl_spawn_q_discussion "$id"
  row="$(spl_spawn_q_enqueue "$id" "$by" "${SPAWN_PLACE:-}" "${SPAWN_CLASS:-}" "${SPAWN_URGENT:-0}" "${SPAWN_BYPASS:-}")" || rc=$?
  (( rc == 0 )) || return "$rc"
  pos="$(jq -r '.position // 0' <<<"$row")"
  len="$(jq -r '.queue_len // 0' <<<"$row")"
  if ! spl_spawn_q_reply "$row" "$by" "queued, position $pos of $len, placed when the box has room${SPAWN_AFTER:+ and $SPAWN_AFTER has landed on origin/master} (ask ${id:0:8}; the queue: \`./run -a do_spl_spawn_queue\`)"; then
    do_log "WARN ask ${id:0:8} is queued but its sender was not told"
  fi
}

# ASK_DISCUSSION onto an ask the hub already has (spec 150 row B10b): the put
# fills it while the row has none, and the answer goes to the journal (a direct
# put, not the sync's replay: a queued ask has no op to replay). Never fails the
# enqueue: the ask is queued at the priority it has, and the WARN says so.
spl_spawn_q_discussion() {  # ID
  [[ -n "${ASK_DISCUSSION:-}" ]] || return 0
  local rec out row got
  rec="$(spool_ask_journal_get "$1")" || { do_log "WARN ask ${1:0:8} is not in this machine's journal: discussion not set" >&2; return 0; }
  rec="$(jq -c --arg d "$ASK_DISCUSSION" '. + {discussion: $d}' <<<"$rec")"
  if ! out="$(spl_asks_put_rec "$rec" 2>&1)"; then
    do_log "WARN the hub did not take the discussion of ask ${1:0:8} (run this enqueue again): $(tail -1 <<<"$out" | cut -c1-200)" >&2
    return 0
  fi
  row="$(jq -c '.asks[0] // empty' <<<"$out" 2>/dev/null)"
  [[ -n "$row" ]] || { do_log "WARN the hub's put answer of ask ${1:0:8} has no row" >&2; return 0; }
  spl_asks_mirror "[$row]" >&2
  got="$(jq -r '.discussion // ""' <<<"$row")"
  if [[ -z "$got" ]]; then
    do_log "WARN the hub did not store the discussion of ask ${1:0:8} (an older hub?)" >&2
  elif [[ "$got" != "$ASK_DISCUSSION" ]]; then
    do_log "WARN ask ${1:0:8} keeps its discussion ${got:0:8}: a set one is never overwritten" >&2
  fi
  return 0
}

# Spec 153 3.22.9 (row Q9, case C125; decided O3 = A: a lower number gets
# more): a lane may queue helper lanes up to an allowance by its priority,
# cnf env.box.prio_helpers. SPAWN_PARENT_LANE=<ID>[@<box>] names the parent,
# a live lane of the lane map; its issue's priority (1..5, the hub's 5 when
# unset) picks the allowance, and its open helpers are the briefs whose
# `Parent-Lane: <ID>` line names it and whose row is queued or placing, or
# whose lane is live. At the allowance the ask is refused with the numbers;
# under it the brief gets that line and the ask the parent's discussion, so
# the helper follows the parent's priority. A helper is a normal request: its
# own brief, issue and lane. Every read that fails refuses (if-else, never a
# guess): a helper that cannot be counted is not queued.
spl_spawn_q_parent() {  # ID
  [[ -n "${SPAWN_PARENT_LANE:-}" ]] || return 0
  local id="$1" par="${SPAWN_PARENT_LANE%@*}" box="" brief lanes row topic key prio allow open n
  [[ "$SPAWN_PARENT_LANE" != *@* ]] || box="${SPAWN_PARENT_LANE#*@}"
  [[ "$par" =~ ^[acgmoqu]-[0-9]{3}$ ]] || { spl_spawn_q_parent_no "$id" "SPAWN_PARENT_LANE must be an agent id <ID> or <ID>@<box>"; return 1; }
  [[ -n "${SPAWN_PLACE:-}" ]] || { spl_spawn_q_parent_no "$id" "a helper needs SPAWN_PLACE (its own brief and lane)"; return 1; }
  declare -F spl_spawn_place_brief >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
  brief="$(SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spl_spawn_place_brief "${SPAWN_PLACE#*:}")"
  [[ -n "$brief" ]] || { spl_spawn_q_parent_no "$id" "no brief for placement $SPAWN_PLACE"; return 1; }
  ! grep -qiE '^Parent-Lane: *' "$brief" || grep -qixE "Parent-Lane: *$par *" "$brief" ||
    { spl_spawn_q_parent_no "$id" "brief $brief names another parent ($(grep -m1 -iE '^Parent-Lane:' "$brief"))"; return 1; }
  lanes="$(spl_spawn_q_parent_lanes)" || { spl_spawn_q_parent_no "$id" "the lane map could not be read from the hub"; return 1; }
  row="$(jq -c --arg p "$par" --arg b "$box" 'first(.[] | select(.agent_id == $p and ($b == "" or .agent_box == $b))) // empty' <<<"$lanes")"
  [[ -n "$row" ]] || { spl_spawn_q_parent_no "$id" "no live lane $SPAWN_PARENT_LANE in the lane map"; return 1; }
  topic="$(jq -r '.topic // ""' <<<"$row")"; key="$(jq -r '.issue_key // ""' <<<"$row")"
  [[ "$key" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || { spl_spawn_q_parent_no "$id" "the parent lane has no issue (issue_key '${key}'), so no priority"; return 1; }
  prio="$(spl_spawn_q_parent_prio "$key")" || { spl_spawn_q_parent_no "$id" "the priority of its issue $key could not be read"; return 1; }
  allow="$(P="$prio" yq -r '.env.box.prio_helpers[env(P)] // ""' "${SPAWN_PLACE_CNF:-$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml}" 2>/dev/null)"
  [[ "$allow" =~ ^[0-9]+$ ]] || { spl_spawn_q_parent_no "$id" "cnf env.box.prio_helpers has no number for priority $prio"; return 1; }
  open="$(set -o pipefail; spl_spawn_q_parent_open "$par" "$brief" "$lanes" | sort)" || { spl_spawn_q_parent_no "$id" "the spawn queue could not be read from the hub"; return 1; }
  n="$(grep -c . <<<"$open")"
  (( n < allow )) || { spl_spawn_q_parent_no "$id" "the parent is at priority $prio, which allows $allow helper(s) at once (cnf env.box.prio_helpers), and has $n open${open:+: $(tr '\n' ' ' <<<"$open" | sed 's/ $//')}"; return 1; }
  if [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    [[ -z "${ASK_DISCUSSION:-}" || "$ASK_DISCUSSION" == "$topic" ]] ||
      { spl_spawn_q_parent_no "$id" "ASK_DISCUSSION $ASK_DISCUSSION is not the parent's discussion $topic: a helper works for its parent's"; return 1; }
    ASK_DISCUSSION="$topic"
  fi
  grep -qixE "Parent-Lane: *$par *" "$brief" ||
    { { [[ ! -s "$brief" || -z "$(tail -c1 "$brief")" ]] || printf '\n'; printf 'Parent-Lane: %s\n' "$par"; } >>"$brief"; } ||
    { spl_spawn_q_parent_no "$id" "cannot write Parent-Lane: $par into $brief"; return 1; }
  do_log "INFO ask ${id:0:8} is helper $((n + 1)) of $allow of lane $par (priority $prio, cnf env.box.prio_helpers)${ASK_DISCUSSION:+, with its discussion ${ASK_DISCUSSION:0:8}}: Parent-Lane: $par in $brief" >&2
}

# One FATAL line: ask ID is not queued as a helper, and WHY.
spl_spawn_q_parent_no() {  # ID WHY
  do_log "FATAL ask ${1:0:8} not queued: helper of $SPAWN_PARENT_LANE: $2 (spec 153 3.22.9)" >&2
}

# The live lanes of the lane map, as a JSON array; rc 1 when the hub did not
# answer (a local-only map would miss a parent or a helper on another box).
# SPAWN_SHARE_LANES_CMD is the share's lane map seam (spl_spawn_share_lanes).
spl_spawn_q_parent_lanes() {
  local out
  if [[ -n "${SPAWN_SHARE_LANES_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_SHARE_LANES_CMD 2>/dev/null)"
  else
    out="$(LANE_FORMAT=json timeout "${SPAWN_SHARE_TIMEOUT:-90}" bash "$PROJ_PATH/run" -a do_spl_lane_map 2>/dev/null | grep -E '^\{' | tail -1)"
  fi
  jq -e -c 'select((.hub // "ok") == "ok") | [.lanes[] | select(.state == "live")]' <<<"$out" 2>/dev/null
}

# The priority 1..5 of issue KEY: SPAWN_PARENT_PRIO_CMD <key> (tests), else
# the hub's issue get (0 or none = the hub's default 5); rc 1 when unread.
spl_spawn_q_parent_prio() {  # KEY
  local p
  if [[ -n "${SPAWN_PARENT_PRIO_CMD:-}" ]]; then
    p="$(timeout "${LI_HUB_TIMEOUT:-20}" "$SPAWN_PARENT_PRIO_CMD" "$1" 2>/dev/null </dev/null)" || return 1
  else
    p="$(spl_spawn_q_issue_get "$1" | jq -r '.priority // 0' 2>/dev/null)" || return 1
  fi
  [[ "$p" =~ ^[0-5]$ ]] || return 1
  (( p > 0 )) || p=5
  printf '%s\n' "$p"
}

# The open helpers of lane PARENT, one brief name per line: each brief of the
# briefs dir with `Parent-Lane: PARENT`, but OWN (the brief being queued),
# whose row is queued or placing (its placement names that brief) or whose
# lane is live (its branch is <ID>-<slug of that brief>). A placed row and its
# live lane are one helper. rc 1 when the queue could not be read.
spl_spawn_q_parent_open() {  # PARENT OWN LANES
  local d="${SPAWN_PLACE_BRIEF_DIR:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/briefs}" rows f slug
  local -A kid=() one=()
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != "$2" ]] && kid["$f"]=1
  done < <(grep -lixE "Parent-Lane: *$1 *" "$d"/*.md 2>/dev/null)
  (( ${#kid[@]} )) || return 0
  rows="$(spl_spawn_q_rows)" || return 1
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    f="$(spl_spawn_place_brief "$slug")"
    [[ -n "$f" && -n "${kid[$f]:-}" && -z "${one[$f]:-}" ]] || continue
    one["$f"]=1; basename "$f" .md
  done < <(jq -r '.[] | .placement // "" | sub("^[^:]*:"; "")' <<<"$rows" 2>/dev/null
    jq -r '.[] | (.branch // "") as $b | (.agent_id + "-") as $p | if ($b | startswith($p)) then $b[($p | length):] else "" end' <<<"$3" 2>/dev/null)
}

# One ask into the queue: the checks, the hub's queue op, the bypass record;
# the hub's row on stdout, the log on stderr. The one path every queue row
# takes: a single enqueue, and each row a work group feeds
# (spl-spawn-group-put.func.sh; a single ask is a group of one row, width 1).
spl_spawn_q_enqueue() {  # ID BY PLACE CLASS URGENT(0|1) BYPASS_MSG
  # bymsg, never msg: the run's do_log sets a GLOBAL msg, which would overwrite a local msg here (SPL-3762)
  local id="$1" by="$2" place="$3" class="$4" bymsg="$6" flag="" seat="" row rc=0
  [[ -z "$place" || "$place" =~ ^[a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
    { do_log "FATAL SPAWN_PLACE must be <vendor>:<slug> (lowercase), got '$place'" >&2; return 1; }
  spl_spawn_enqueue_mistral_ok "$place" >&2 || return 1
  [[ "$class" =~ ^(ci|refactor|bug|feature)$ ]] ||
    { do_log "FATAL SPAWN_CLASS must be ci, refactor, bug or feature (got '$class'; no default: classify the request)" >&2; return 1; }
  declare -F spl_spawn_after_enqueue >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-after.func.sh"
  [[ -n "$place" ]] || spl_spawn_after_enqueue "$id" "" "" || return 1
  [[ "$5" == 1 ]] && flag=urgent
  if [[ -z "$bymsg" && "$5" != 1 ]] && spl_spawn_q_review_seat_go "$place" "$SPL_SPAWN_REVIEW_SEAT_GO"; then
    bymsg="$SPL_SPAWN_REVIEW_SEAT_GO"  # SPL-3762: the standing GO, as SPAWN_BYPASS=<GO> would record it
    do_log "INFO ask ${id:0:8} is a review seat ($place) with no SPAWN_BYPASS: the standing review-seat GO ${bymsg:0:8} applies" >&2
  fi
  if [[ -n "$bymsg" ]]; then
    [[ "$bymsg" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
      { do_log "FATAL SPAWN_BYPASS must be the owner's message id (a full lowercase UUID), got '$bymsg'" >&2; return 1; }
    flag=bypass
  fi
  [[ "$flag" != bypass || "$class" == feature ]] || ! spl_spawn_q_review_seat_go "$place" "$bymsg" || seat=1
  [[ "$flag" != urgent || "$class" == bug ]] || { do_log "FATAL SPAWN_URGENT goes with SPAWN_CLASS=bug only" >&2; return 1; }
  [[ "$flag" != bypass || "$class" == feature || -n "$seat" ]] ||
    { do_log "FATAL SPAWN_BYPASS goes with SPAWN_CLASS=feature only (the review-seat GO ${SPL_SPAWN_REVIEW_SEAT_GO:0:8} also takes a review seat: a SPAWN_PLACE slug ending in -reviewer)" >&2; return 1; }
  [[ -z "$bymsg" || "$5" != 1 ]] || { do_log "FATAL SPAWN_URGENT and SPAWN_BYPASS exclude each other" >&2; return 1; }
  if [[ -n "$seat" ]]; then  # the hub flags bypass on a feature only (rdb 0195): an unflagged seat sat at its class's place (SPL-5638)
    do_log "INFO ask ${id:0:8} is a $class review seat ($place): queued as feature + bypass on the review-seat GO ${bymsg:0:8} (SPL-5638)" >&2
    class=feature
  fi
  if [[ -n "$place" ]]; then  # the placer files the lane's issue from this brief: refuse it here, not at placement
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" >&2 || return 1
    declare -F spl_spawn_place_brief >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
    local brief; brief="$(SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spl_spawn_place_brief "${place#*:}")"
    [[ -z "$brief" ]] || LI_REFUSED="ask not queued" li_brief_epic_spec "$brief" >/dev/null || return 1
    local closed; closed="$([[ -z "$brief" ]] || li_brief_epic_closed "$brief")"
    [[ "$closed" != *$'\t'auto-closed ]] || { spl_spawn_q_enqueue_reopen "$brief" "${place#*:}" "${closed%$'\t'auto-closed}"; closed=""; }
    [[ -z "$closed" ]] || { do_log "FATAL ask not queued: $closed" >&2; return 1; }
    [[ -z "$brief" ]] || spl_spawn_q_enqueue_links "$id" "$brief" || return 1
    spl_spawn_after_enqueue "$id" "$place" "$brief" || return 1  # spec 157 4.2: the dependent row
    [[ -z "$brief" ]] || spl_spawn_q_enqueue_shared "$id" "$brief"  # SPL-6167
  fi
  row="$(spl_spawn_q_op queue "$id" "$by" "" "$place" "$class" "$flag" "$bymsg")" || rc=$?
  (( rc == 0 )) || return "$rc"
  if [[ "$flag" == bypass ]]; then
    local what="feature "; [[ -z "$seat" ]] || what="review-seat "
    spl_spawn_share_bypass_record "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" "$bymsg" "$by" "$(jq -r '.summary // ""' <<<"$row")" ||
      do_log "WARN the bypass of ask ${id:0:8} is not in the local bypass log" >&2
    do_log "INFO ask ${id:0:8} is a ${what}BYPASS on owner msg ${bymsg:0:8}: recorded, listed by do_spl_spawn_share${seat:+, placed ahead of the bands}" >&2
  fi
  do_log "OK ask ${id:0:8} queued ($class${flag:+, $flag}): position $(jq -r '.position // 0' <<<"$row") of $(jq -r '.queue_len // 0' <<<"$row")${place:+, placement $place}" >&2
  printf '%s\n' "$row"
}

# SPL-6167 (bug round 33 row 01, the holder's option A, msg 08e9399f): a
# docs lane placed on an issue it does not own shares that issue. For a
# placed brief of kind specs_and_docs (SPAWN_KIND, else its Kind:) with an
# `Issue: <KEY>` line and no `Issue-Role:` line, KEY's card is read once from
# the hub; unless its scope is the brief of this placement's lane, the brief
# gets `Issue-Role: shared`, which the exit gate's li_review_lane honours
# (c-655 on SPL-6086, ae541e19: its docs commit never closed the key, so
# /exit-clean refused it). A discussion key, an earlier lane's key and a card
# with no scope line all share. The placer writes a filed key only into the
# lane's lifetime/brief.md, and at the enqueue no lane exists yet, so no card
# names this placement's lane: every card read shares. A failed read changes
# nothing and logs one WARN, never a guess. SPL-6181 (b34-02): the line goes on
# a line of its own: a brief whose last byte is not a newline gets one first,
# so the ^-anchored greps (the guard below, li_review_lane) see it and a
# re-queue appends nothing; a brief that ends in a newline gets no blank line.
spl_spawn_q_enqueue_shared() {  # ID BRIEF
  local brief="$2" kind key
  kind="${SPAWN_KIND:-}"
  declare -F spl_lane_mix_brief_kind >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  [[ -n "$kind" ]] || kind="$(spl_lane_mix_brief_kind "$brief")"
  [[ "$kind" == specs_and_docs ]] || return 0
  key="$(li_key_from_brief "$brief")" || return 0
  ! grep -qiE '^[-*_ >]*Issue[- ]Role[*_ ]*:' "$brief" || return 0
  if ! spl_spawn_q_issue_card "$key" >/dev/null; then
    do_log "WARN ask ${1:0:8}: the card of $key could not be read: brief $brief left as it is (no Issue-Role: line, so the lane may not exit on $key)" >&2
    return 0
  fi
  { [[ ! -s "$brief" || -z "$(tail -c1 "$brief")" ]] || printf '\n'; printf 'Issue-Role: shared\n'; } >>"$brief" ||
    { do_log "WARN ask ${1:0:8}: cannot write Issue-Role: shared into $brief" >&2; return 0; }
  do_log "INFO ask ${1:0:8}: $key is not this lane's own issue (a docs lane on it): Issue-Role: shared written into $brief (SPL-6167)" >&2
}

# spl_spawn_q_issue_card KEY -> the description (the card) of issue KEY on the
# hub, through the lease's desk as do_spl_issue_status reads it; rc 1 when the
# read fails or has no description. The test seam LI_HUB_CARD_CMD <key>
# prints it, the twin of li_hub_read's LI_HUB_STATUS_CMD; under SPOOL_TEST=1
# without the seam nothing is read (rc 1).
spl_spawn_q_issue_card() {  # KEY
  local out
  if [[ -n "${LI_HUB_CARD_CMD:-}" ]]; then
    out="$(timeout "${LI_HUB_TIMEOUT:-20}" "$LI_HUB_CARD_CMD" "$1" 2>/dev/null </dev/null)" || return 1
  else
    out="$(spl_spawn_q_issue_get "$1" | jq -er '.description // empty' 2>/dev/null)" || return 1
  fi
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# spl_spawn_q_issue_get KEY -> issue KEY as the hub's agent issue get answers
# it (one JSON object), through the lease's desk; rc 1 when the read fails.
# Under SPOOL_TEST=1 nothing is read (rc 1): a test sets its command seam.
spl_spawn_q_issue_get() {  # KEY
  [[ "${SPOOL_TEST:-}" != 1 ]] || return 1
  (
    declare -F spl_lane_issue_desk >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-issue.func.sh"
    spl_lane_issue_desk "${SPOOL_ROOT:-/var/spool-hub}" 0 >&2 || exit 1
    spl_desk_issue_run get --ref "$1" 2>/dev/null </dev/null | tail -n 1 |
      jq -ec '(.result.issue // .result) | select(type == "object")' 2>/dev/null
  )
}

# The placer's links check (spl_spawn_place_no_links, SPL-4797) at the enqueue
# (SPL-5325): a placed brief that names no discussion, on an ask whose topic is
# no hub topic (a dispatch-<word> task), is refused now, while its writer can
# fix it, not when the row reaches the head (3 rows on 2026-11-11, one lost its
# slot). The row is the journal's (the hub's mirror), else the loaded book; an
# ask in neither is left to the placer.
spl_spawn_q_enqueue_links() {  # ID BRIEF
  local row why
  row="$(spl_spawn_q_row "$1")"
  [[ -n "$row" ]] || return 0
  why="$(spl_spawn_place_no_links "$row" "$2")"
  [[ -z "$why" ]] || { do_log "FATAL ask not queued: $why" >&2; return 1; }
}

# The row of ask ID: the journal's (the hub's mirror), else the loaded book's;
# nothing for an ask in neither.
spl_spawn_q_row() {  # ID
  local row
  row="$(spool_ask_journal_get "$1" 2>/dev/null)" ||
    row="$(jq -c --arg i "$1" 'first(.[] | select(.ask_id == $i)) // empty' <<<"${ASKS_ROWS:-[]}" 2>/dev/null)"
  printf '%s' "$row"
}

# SPL-5671: the placer's archive read (spl_spawn_topic_archived) at the
# enqueue. An ask whose topic (spl_spawn_place_row_topic) or ASK_DISCUSSION is
# archived is refused now, while its sender can re-raise it on a live task, not
# declined at the head (asks db9ba132, 8b754281, 75457836, e1de40f2, 34ba5041
# on 2026-11-15/16, each re-raised by hand). A failed or too-old read is one
# WARN line and the ask queues as before.
spl_spawn_q_enqueue_archived() {  # ID
  local row topic at rc seen=" "
  declare -F spl_spawn_topic_archived >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
  row="$(spl_spawn_q_row "$1")"
  for topic in "${ASK_DISCUSSION:-}" "$([[ -z "$row" ]] || spl_spawn_place_row_topic "$row")"; do
    [[ -n "$topic" && "$seen" != *" $topic "* ]] || continue
    seen+="$topic "
    rc=0; at="$(spl_spawn_topic_archived "$topic")" || rc=$?
    case "$rc" in
      0) do_log "FATAL ask ${1:0:8} not queued: its topic $topic was archived at $at, so the placer would decline it (SPL-4955): re-raise the request on a live task (SPL-5671)" >&2
         return 1 ;;
      2) do_log "WARN ask ${1:0:8}: the archive state of topic $topic could not be read: queued as before. $at" >&2 ;;
      3) do_log "WARN ask ${1:0:8}: the spool binary or hub is too old to read the archive state of topic $topic: queued as before" >&2 ;;
    esac
  done
  return 0
}

# The owner's review-seat GO (HUM-10, msg 994f2257, 2026-10-16): every review
# seat is queued ahead of features, whatever its class (SPL-3349). A review
# seat is a placement whose slug ends in -reviewer: mechanical, the slug is in
# hand at enqueue and at placement; a brief's Kind:/title is not (Kind:
# specs_and_docs is every docs lane too). Any other bypass id stays
# feature-only. A refactor or bug seat is queued as a feature + bypass: the hub
# flags bypass on a feature only (rdb 0195), and an unflagged seat sat at its
# class's queue place (SPL-5638, n = 4). The placer also takes a logged seat
# first (spl_spawn_place_band).
SPL_SPAWN_REVIEW_SEAT_GO=994f2257-8ad1-4010-88c8-4f0a16230937
spl_spawn_q_review_seat_go() {  # PLACE MSG -> 0: the review-seat GO on a review seat
  [[ "$2" == "$SPL_SPAWN_REVIEW_SEAT_GO" && -n "$1" && "${1#*:}" =~ -reviewer$ ]]
}

# An epic the SPL-1729 close archived (li_brief_epic_closed's `auto-closed`
# field) never refuses the ask (SPL-3060): a spec epic is auto-closed as soon
# as its spec-writing issue lands, before any build row is filed (SPL-3028,
# SPL-3030 on 2026-10-23). It is reopened here the way the placer does
# (spl_spawn_place_reopen); a failed reopen is one WARN and the ask queues
# anyway: the placer tries the reopen again before it launches the row.
spl_spawn_q_enqueue_reopen() {  # BRIEF SLUG WHY
  local failed
  failed="$(spl_spawn_place_reopen "$1" "$2" "$3" "Reopened by do_spl_spawn_enqueue: auto-closed (SPL-1729), queued brief $2 names it on its Epic: line, and its lane files its issue under it (SPL-3060).")"
  [[ -z "$failed" ]] || do_log "WARN ask queued with its epic still closed: $failed; the placer tries the reopen again before it launches" >&2
  return 0
}

# spl_spawn_enqueue_mistral_ok <placement> -> refuses (one FATAL line) a
# mistral placement that is a review seat (spl_lane_mix_review_target: its
# kind, SPAWN_KIND else the brief's "Kind:", or its slug; owner HUM-10 t1
# 91992830, 2026-11-24) or whose kind (none counting as coding) is coding:
# the review and coding rules of spl-lane-mix.func.sh
spl_spawn_enqueue_mistral_ok() {
  local why kind="${SPAWN_KIND:-}" brief cnf="${SPAWN_PLACE_CNF:-$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml}"
  [[ "$1" == mistral:* ]] || return 0
  declare -F spl_lane_mix_mistral_code_off >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-mix.func.sh"
  declare -F spl_spawn_place_brief >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
  brief="$(spl_spawn_place_brief "${1#mistral:}")"
  [[ -n "$kind" ]] || kind="$(spl_lane_mix_brief_kind "$brief")"
  why="$(spl_lane_mix_mistral_review_off "$cnf" "$brief" "$kind")"
  if [[ -n "$why" ]]; then
    do_log "FATAL SPAWN_PLACE=$1 refused: $why; place it as agy:${1#mistral:} (claude:${1#mistral:} for an agy author or a data-rule brief)"
    return 1
  fi
  why="$(spl_lane_mix_mistral_code_off "$cnf" "$kind")"
  [[ -z "$why" ]] && return 0
  do_log "FATAL SPAWN_PLACE=$1 refused: $why; place it as claude:${1#mistral:}"
  return 1
}
