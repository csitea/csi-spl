#!/bin/bash
#------------------------------------------------------------------------------
# @description A review seat's authors hear it started (spec 157 Rule 3, row
# @description B6, SPL-4109; owner HUM-10, t1 99ffa592 msg a99676b7: "What
# @description could be automated to be done without any intelligence?").
# @description The placer (spl_spawn_place_launch) runs it right after it
# @description launches a review seat; by hand it re-sends for one brief.
# @description   1. reads the author lanes of REVIEW_NOTIFY_BRIEF, two forms:
# @description      a markdown table cell holding only an id, decorated or not
# @description      (`| a-213@sat (agy) |`, ids of 3+ digits), and an author
# @description      line or phrase, `Author: c-372@boxa` / `Author c-372@boxa` /
# @description      `(author c-418, vendor claude)`, any case. The spec's
# @description      `^Author:` form alone matched 0 of 352 reviewer briefs on
# @description      2026-10-28; the phrase form matched 130, the cell form 12.
# @description      Role seats (spl_is_role_seat) and the reviewer itself are
# @description      left out; an id named twice is notified once.
# @description   2. routes each author to the box its cell names (`@sat`),
# @description      else this box. An author on this box with no live row in
# @description      $SPOOL_ROOT/registry.tsv and no spool dir is skipped:
# @description      `SKIP: author <id> already retired` when
# @description      registry.retired.tsv names it, else `SKIP: author <id>
# @description      unknown`. An author on another box is sent through the
# @description      relay (spool-send.sh --to <id>@<box>), which refuses an id
# @description      that box does not know: this box's registry cannot judge it.
# @description   3. sends each author a note on the brief's first "task
# @description      dispatch-<...>" (else review-<reviewer id>), naming the
# @description      reviewer, the review branch and the brief.
# @description A brief with no author id: a WARN line in
# @description $SPOOL_ROOT/dispatch/queue.log, a note to the dispatcher, 0
# @description notes to anyone else, exit 1. A failed send exits 1 too (the
# @description others are still sent). Every run appends one line per
# @description author (and one for a brief with none) to
# @description $SPOOL_ROOT/dispatch/automation.log (spec 157 5.1.3): time,
# @description reviewer, action, actor, brief, author, box, send exit code.
# @description Dry run unless DRY_RUN=0: PLAN lines, nothing sent or logged.
# @param REVIEW_NOTIFY_BRIEF (required) - the review seat's brief file
# @param REVIEW_NOTIFY_REVIEWER (required) - the review seat, <ID>[@<box>]
# @param REVIEW_NOTIFY_FROM (optional) - the sender, default role seat 1 (lease.conf LEASE_ORCH)
# @param REVIEW_NOTIFY_DISPATCHER (optional) - who hears of a brief with no author, default the dispatch lease holder, else the sender
# @param SPAWN_QUEUE_SEND (optional) - the sender script, default spawn-agents/scripts/spool-send.sh (tests)
# @param DRY_RUN (optional) - 1 (default) or 0; the placer's hook passes 0
# @example REVIEW_NOTIFY_BRIEF=/var/spool-hub/dispatch/briefs/c002-x-reviewer.md REVIEW_NOTIFY_REVIEWER=a-213@sat ./run -a do_spl_spawn_review_notify
# @example DRY_RUN=0 REVIEW_NOTIFY_BRIEF=<brief> REVIEW_NOTIFY_REVIEWER=a-213@sat ./run -a do_spl_spawn_review_notify
#------------------------------------------------------------------------------
do_spl_spawn_review_notify() {
  local brief="${REVIEW_NOTIFY_BRIEF:-}" rev="${REVIEW_NOTIFY_REVIEWER:-}" dry="${DRY_RUN:-1}"
  [[ -r "$brief" ]] || { do_log "FATAL REVIEW_NOTIFY_BRIEF must be a readable brief file, got: '$brief'"; return 1; }
  [[ "$rev" =~ ^[acgmq]-[0-9]{3,}(@[a-z0-9][a-z0-9-]{0,31})?$ ]] || { do_log "FATAL REVIEW_NOTIFY_REVIEWER must be <ID>[@<box>], got: '$rev'"; return 1; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  declare -F spl_is_role_seat >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  declare -F spl_spawn_q_send >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-spawn-queue.func.sh"
  local d="${SPOOL_ROOT:-/var/spool-hub}/dispatch" box from task branch authors
  box="${ASKS_BOX:-$(spl_desk_box_default)}"
  local ASKS_BOX="$box"  # spl_spawn_q_send sends <id>@<this box> as <id>
  [[ "$rev" == *@* ]] || rev="$rev@$box"
  from="${REVIEW_NOTIFY_FROM:-$(spl_role_seat 1)}"; from="${from%@*}"
  [[ -n "$from" ]] || { do_log "FATAL no sender: set REVIEW_NOTIFY_FROM or LEASE_ORCH in lease.conf"; return 1; }
  [[ "$dry" == 1 ]] || { mkdir -p "$d" && touch "$d/automation.log" "$d/queue.log"; } ||
    { do_log "FATAL cannot write $d/automation.log"; return 1; }
  task="$(grep -m1 -oiE 'task[[:space:]`]+dispatch-[a-z0-9][a-z0-9-]*[a-z0-9]' "$brief")" || true
  task="${task%%$'\n'*}"; task="${task##*[[:space:]\`]}"; task="${task:-review-${rev%@*}}"
  branch="$(grep -m1 -oE '\breview/[A-Za-z0-9._/-]*[A-Za-z0-9]' "$brief")" || true
  branch="${branch%%$'\n'*}"; branch="${branch:-(no review/ branch named)}"
  authors="$(spl_review_notify_authors "$brief" "${rev%@*}")"
  if [[ -z "$authors" ]]; then
    spl_review_notify_none "$d" "$brief" "$rev" "$from" "$task" "$dry"
    return 1
  fi
  local id abox n=0 bad=0 rc
  while IFS=$'\t' read -r id abox; do
    rc=0; spl_review_notify_one "$d" "$brief" "$rev" "$from" "$task" "$branch" "$id" "${abox:-$box}" "$box" "$dry" || rc=$?
    (( rc == 0 )) && n=$((n + 1)); (( rc == 2 )) && bad=$((bad + 1))
  done <<<"$authors"
  do_log "$( ((bad)) && echo WARN || echo OK) review notify: $rev, $n of $(wc -l <<<"$authors") author(s) told, $bad send(s) failed$([[ "$dry" == 1 ]] && echo ' (DRY_RUN: planned, nothing sent)')"
  (( bad == 0 ))
}

# The placer's post-launch hook (spl_spawn_place_launch): when the seat AGENT
# it just placed on SLUG's BRIEF is a review seat (spl_spawn_place_review_seat:
# a -reviewer slug or Kind: review / code_review; or a slug ending -review),
# tell its authors, from HOLDER. In a subshell: nothing it sets or fails
# reaches the placer.
spl_review_notify_placed() {  # HOLDER AGENT SLUG BRIEF
  declare -F spl_lane_mix_brief_kind >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-mix.func.sh"
  spl_spawn_place_review_seat "$4" "$(spl_lane_mix_brief_kind "$4")" || [[ "$3" == *-review ]] || return 0
  ( DRY_RUN=0 REVIEW_NOTIFY_BRIEF="$4" REVIEW_NOTIFY_REVIEWER="$2" REVIEW_NOTIFY_FROM="${1%@*}" do_spl_spawn_review_notify ) ||
    do_log "WARN review seat $2: its authors were not all told (brief $(basename "$4"))"
  return 0
}

# The author lanes of BRIEF, one "<id>\t<box or empty>" line each, first seen
# first: an id alone in a table cell (decorated `| a-213@sat (agy) |`) or after
# "author" (`Author: c-372@boxa`, `(author c-418, ...)`). Role seats and SELF
# (the reviewer's bare id) are left out.
spl_review_notify_authors() {  # BRIEF SELF
  local cell='\|[[:space:]]*[acgmq]-[0-9]{3,}(@[A-Za-z0-9._-]+)?([[:space:]]*\([^)]+\))?[[:space:]]*\|'
  local phrase='(^|[^A-Za-z])[Aa][Uu][Tt][Hh][Oo][Rr]:?[[:space:]]+[acgmq]-[0-9]{3,}(@[A-Za-z0-9._-]+)?'
  local hit id box seen=" "
  while read -r hit; do
    [[ "$hit" =~ ([acgmq]-[0-9]{3,})(@([A-Za-z0-9._-]*[A-Za-z0-9]))? ]] || continue
    id="${BASH_REMATCH[1]}"; box="${BASH_REMATCH[3]:-}"
    [[ "$id" == "$2" || "$seen" == *" $id "* ]] && continue
    spl_is_role_seat "$id" && continue
    seen+="$id "
    printf '%s\t%s\n' "$id" "$box"
  done < <({ grep -E '^[[:space:]]*\|' "$1" | grep -oE "$cell"; grep -oE "$phrase" "$1"; } 2>/dev/null)
}

# On this box: "live" when registry.tsv has a row for ID (its 6th column is
# "-" or absent: not ended) or its spool dir exists, else "retired" when
# registry.retired.tsv names it, else "unknown". Ids are reused, so a retired
# row of an id that is live again does not make it retired.
spl_review_notify_state() {  # ID
  local r="${SPOOL_ROOT:-/var/spool-hub}"
  if [[ -d "$r/$1" ]] || awk -F'\t' -v id="$1" '$1 == id && (NF < 6 || $6 == "-") { f = 1 } END { exit !f }' "$r/registry.tsv" 2>/dev/null; then
    echo live
  elif awk -F'\t' -v id="$1" '$1 == id { f = 1 } END { exit !f }' "$r/registry.retired.tsv" 2>/dev/null; then
    echo retired
  else
    echo unknown
  fi
}

# One author: skip it (retired or unknown on this box) or send it the note;
# one automation.log line either way. Returns 0 sent (or planned), 1 skipped,
# 2 the send failed.
spl_review_notify_one() {  # DIR BRIEF REV FROM TASK BRANCH ID ABOX BOX DRY
  local state=live rc=0 action=sent slug body
  slug="$(basename "$2" .md)"
  [[ "$8" != "$9" ]] || state="$(spl_review_notify_state "$7")"
  if [[ "$state" != live ]]; then
    do_log "INFO SKIP: author $7 $([[ "$state" == retired ]] && echo already retired || echo "unknown on $9")"
    [[ "${10}" == 1 ]] || spl_review_notify_log "$1" "$3" "skip-$state" "$4" "$slug" "$7@$8" -
    return 1
  fi
  body="Your R7 reviewer **$3** started on \`$6\` (brief $slug). It may ask you questions on task $5: answer them there. Push nothing more to \`$6\` while it reviews unless it asks."
  if [[ "${10}" == 1 ]]; then
    do_log "PLAN note $4 -> $7@$8 on $5: $body"
    return 0
  fi
  spl_spawn_q_send "$4" "$7@$8" note "$5" "$body" || { rc=2; action=send-failed; }
  spl_review_notify_log "$1" "$3" "$action" "$4" "$slug" "$7@$8" "$rc"
  (( rc == 0 )) && do_log "OK told $7@$8 that $3 reviews $6"
  return "$rc"
}

# A brief with no author id: WARN in queue.log, a note to the dispatcher.
spl_review_notify_none() {  # DIR BRIEF REV FROM TASK DRY
  local slug to rc=0 msg
  slug="$(basename "$2" .md)"
  to="${REVIEW_NOTIFY_DISPATCHER:-$(LEASE_CMD=show do_spl_dispatch_lease 2>/dev/null | awk '$1 != "none" { print $1 }')}"
  to="${to:-$4}"
  msg="review seat $3 placed on brief $slug, which names no author lane (no \`| <id> |\` cell, no \`Author: <id>\`): nobody was told it started"
  do_log "WARN $msg"
  if [[ "$6" == 1 ]]; then do_log "PLAN note $4 -> $to on $5: $msg"; return 0; fi
  printf '%s WARN %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >>"$1/queue.log"
  spl_spawn_q_send "$4" "$to" note "$5" "**REVIEW NOTIFY**: $msg. Tell its author yourself." || rc=1
  spl_review_notify_log "$1" "$3" no-author "$4" "$slug" "$to" "$rc"
}

# One spec 157 5.1.3 line in DIR/automation.log.
spl_review_notify_log() {  # DIR REV ACTION ACTOR SLUG TO RC
  printf '%s review-notify %s action=%s actor=%s brief=%s to=%s send_rc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$5" "$6" "$7" >>"$1/automation.log"
}
