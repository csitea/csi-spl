#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_spawn_review_notify (spec 157 Rule 3, row B6, SPL-4109)
#          tells each author lane of a review seat's brief that its reviewer
#          started, and only those lanes. A sandbox: its own SPOOL_ROOT
#          (registry.tsv, registry.retired.tsv, lease), the sender a stub that
#          logs its args. No network, no hub, no live spool.
#     1. RED CONTROL a brief with no author id -> rc 1, 0 author notes, one
#        note to the dispatcher, a WARN in dispatch/queue.log, a no-author
#        automation.log line
#     2. RED CONTROL the decorated cell `| a-213@sat (agy) |` -> a-213 is
#        found and sent to a-213@sat
#     3. RED CONTROL an author only in registry.retired.tsv -> no note,
#        "SKIP: author <id> already retired", a skip-retired log line; the
#        same id live again (a registry.tsv row not ended) is told
#     4. GREEN authors a-213@sat and c-168@boxb -> rc 0, one note each, from
#        the holder, on the brief's dispatch task, naming the reviewer and
#        the review branch; one automation.log line each
#     5. role seats, the reviewer itself and a repeated id are not told
#     6. the Author line / phrase forms; a local author goes out as its bare id
#     7. the dry run plans, sends nothing, logs nothing
#     8. the dispatcher defaults to the dispatch lease holder
#     9. a failed send is logged send-failed and exits 1; the others are sent
#    10. bad args are refused
#    11. the placer's hook: a -reviewer seat tells its authors, a coding lane
#        sends nothing; the hook line sits in spl_spawn_place_launch
#   REVIEW_NOTIFY_FUNC points the test at another copy of the action: the red
#   controls run it against a mutant (see the commit that added this file).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="${REVIEW_NOTIFY_FUNC:-$PROJ_ROOT/src/bash/run/spl-spawn-review-notify.func.sh}"

# the sender stub logs its args; SEND_RC_FOR=<to> makes the send to <to> fail
# shellcheck disable=SC2016 # the stub expands its own args at run time
printf '#!/bin/bash\necho "SEND $*" >>"$SEND_LOG"\nfor a in "$@"; do [[ -n "${SEND_RC_FOR:-}" && "$a" == "$SEND_RC_FOR" ]] && exit 12; done\nexit 0\n' >"$T/send.sh"

# reset: a fresh sandbox; c-168 and c-372 live here, c-140 retired, c-147
# retired and live again
reset() {
  rm -rf "$T/s" && mkdir -p "$T/s/dispatch/briefs" "$T/s/c-372"
  printf 'c-168\tclaude\t%%1\t/w/c-168\t20261028T000000Z\t-\nc-147\tclaude\t%%2\t/w/c-147\t20261028T000000Z\t-\n' >"$T/s/registry.tsv"
  printf 'c-140\tclaude\t%%3\t/w/c-140\t20261003T000000Z\t20261003T010000Z\nc-147\tclaude\t%%4\t/w/c-147\t20261003T000000Z\t20261003T010000Z\n' >"$T/s/registry.retired.tsv"
  printf 'c-003@boxa %s\n' "$(date +%s)" >"$T/s/dispatch/lease"
  printf 'LEASE_ORCH=c-001\nLEASE_MACHINE=boxa\n' >"$T/s/dispatch/lease.conf"
  : >"$T/s/sends.log"
}
# brief <name> <text>: a brief file
brief() { printf '%s\n' "$2" >"$T/s/dispatch/briefs/$1.md"; echo "$T/s/dispatch/briefs/$1.md"; }
# run [VAR=value]...: the action in a fresh bash; stdout+stderr in $T/out, rc returned
run() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$T/s" ASKS_BOX=boxa SEND_LOG="$T/s/sends.log" \
    SPAWN_QUEUE_SEND="$T/send.sh" SPL_SPOOL=/nonexistent/spool REVIEW_NOTIFY_FROM=c-001 \
    REVIEW_NOTIFY_DISPATCHER=c-002 DRY_RUN=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$0" || { echo "FATAL cannot source $0"; exit 97; }
    ${RUN_SNIPPET:-do_spl_spawn_review_notify}' "$FUNC" >"$T/out" 2>&1
}
sends() { grep -c '^SEND ' "$T/s/sends.log"; }
sent_to() { grep -qE "^SEND .*--to $1 " "$T/s/sends.log"; }

GOOD="# R7 reviewer seat: review/c-168-x (SPL-1)

Report on task dispatch-99ffa592 to the holder.

| lane | role |
|---|---|
| a-213@sat (agy) | author of the wui half |
|   c-168@boxb   | author of the hub half |
| c-001 | orchestrator |"

# 1. RED CONTROL: no author id
reset; b="$(brief c002-none-reviewer "# R7 reviewer seat

Review the branch review/x. Nobody is named here.")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500@boxa; rc=$?
(( rc == 1 )) && [[ "$(sends)" == 1 ]] && sent_to c-002 && grep -q 'WARN review seat g-500@boxa placed on brief c002-none-reviewer, which names no author' "$T/s/dispatch/queue.log" &&
  grep -q ' review-notify g-500@boxa action=no-author actor=c-001 brief=c002-none-reviewer to=c-002 send_rc=0$' "$T/s/dispatch/automation.log" &&
  pass "1. RED CONTROL no author: rc 1, 0 author notes, the dispatcher told, queue.log WARN" ||
  fail "1. no author rc=$rc sends=$(sends): $(cat "$T/out" "$T/s/sends.log")"

# 2. RED CONTROL: the decorated cell
reset; b="$(brief c002-cell-reviewer "Review review/c-x.

| a-213@sat (agy) |")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500@boxa; rc=$?
(( rc == 0 )) && [[ "$(sends)" == 1 ]] && sent_to a-213@sat &&
  pass "2. RED CONTROL decorated cell | a-213@sat (agy) |: a-213 found, sent to a-213@sat" ||
  fail "2. decorated cell rc=$rc: $(cat "$T/out" "$T/s/sends.log")"

# 3. RED CONTROL: a retired author is skipped; one live again is told
reset; b="$(brief c002-ret-reviewer "Author: c-140
| c-147 |
Branch review/c-140-y.")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500; rc=$?
(( rc == 0 )) && ! sent_to c-140 && sent_to c-147 && [[ "$(sends)" == 1 ]] && grep -q 'SKIP: author c-140 already retired' "$T/out" &&
  grep -q 'action=skip-retired actor=c-001 brief=c002-ret-reviewer to=c-140@boxa send_rc=-$' "$T/s/dispatch/automation.log" &&
  pass "3. RED CONTROL retired c-140 skipped and logged; c-147, live again, told" ||
  fail "3. retired rc=$rc: $(cat "$T/out" "$T/s/sends.log")"

# 4. GREEN: two authors on two boxes
reset; b="$(brief c002-good-reviewer "$GOOD")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500@boxa; rc=$?
want='--from c-001 --to a-213@sat --kind note --task dispatch-99ffa592 --no-ask --body Your R7 reviewer **g-500@boxa** started on `review/c-168-x` (brief c002-good-reviewer).'
(( rc == 0 )) && [[ "$(sends)" == 2 ]] && grep -qF "SEND $want" "$T/s/sends.log" && sent_to c-168@boxb &&
  [[ "$(grep -c ' review-notify g-500@boxa action=sent actor=c-001 brief=c002-good-reviewer ' "$T/s/dispatch/automation.log")" == 2 ]] &&
  grep -q 'OK review notify: g-500@boxa, 2 of 2 author(s) told, 0 send(s) failed' "$T/out" &&
  pass "4. GREEN a-213@sat + c-168@boxb: rc 0, one note each with reviewer + branch, 2 log lines" ||
  fail "4. green rc=$rc: $(cat "$T/out" "$T/s/sends.log")"

# 5. role seats, the reviewer itself, a repeated id
reset; b="$(brief c002-self-reviewer "| c-001 |
| g-500 (grok) |
| c-168 |
Author: c-168")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500; rc=$?
(( rc == 0 )) && [[ "$(sends)" == 1 ]] && sent_to c-168 && ! sent_to c-001 && ! sent_to g-500 &&
  grep -q 'task review-g-500 ' "$T/s/sends.log" && grep -q 'started on `(no review/ branch named)`' "$T/s/sends.log" &&
  pass "5. role seat, the reviewer and a repeat left out; no task/branch named -> review-<id>, said so" ||
  fail "5. rc=$rc: $(cat "$T/out" "$T/s/sends.log")"

# 6. the Author forms; a local author goes out as its bare id
reset; b="$(brief c002-phr-reviewer "You are a READ-ONLY reviewer (author c-372, vendor claude).
Author c-168@boxa. on review/c-372-z")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500; rc=$?
(( rc == 0 )) && [[ "$(sends)" == 2 ]] && sent_to c-372 && sent_to c-168 && ! grep -q -- "--to c-168@" "$T/s/sends.log" &&
  pass "6. (author c-372, ...) and 'Author c-168@boxa.' found; c-372 has a spool dir: live; this box's @boxa goes out bare" ||
  fail "6. rc=$rc: $(cat "$T/out" "$T/s/sends.log")"
reset; b="$(brief c002-unk-reviewer "Author: c-999")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500; rc=$?
(( rc == 0 )) && [[ "$(sends)" == 0 ]] && grep -q 'SKIP: author c-999 unknown on boxa' "$T/out" &&
  pass "6. a local author this box does not know is skipped" || fail "6. unknown rc=$rc: $(cat "$T/out")"

# 7. the dry run
reset; b="$(brief c002-good-reviewer "$GOOD")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500 DRY_RUN=1; rc=$?
(( rc == 0 )) && [[ "$(sends)" == 0 ]] && [[ ! -e "$T/s/dispatch/automation.log" ]] && [[ "$(grep -c '^PLAN note c-001 -> ' "$T/out")" == 2 ]] &&
  pass "7. dry run: 2 PLAN lines, nothing sent or logged" || fail "7. dry rc=$rc: $(cat "$T/out")"

# 8. the dispatcher defaults to the dispatch lease holder
reset; b="$(brief c002-none-reviewer "Nobody.")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500 REVIEW_NOTIFY_DISPATCHER=; rc=$?
(( rc == 1 )) && [[ "$(sends)" == 1 ]] && sent_to c-003 &&
  pass "8. no REVIEW_NOTIFY_DISPATCHER: the dispatch lease holder c-003 is told" || fail "8. rc=$rc: $(cat "$T/out" "$T/s/sends.log")"

# 9. a failed send
reset; b="$(brief c002-good-reviewer "$GOOD")"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER=g-500 SEND_RC_FOR=a-213@sat; rc=$?
(( rc == 1 )) && [[ "$(sends)" == 2 ]] && grep -q 'action=send-failed .* to=a-213@sat send_rc=2$' "$T/s/dispatch/automation.log" &&
  grep -q 'action=sent .* to=c-168@boxb send_rc=0$' "$T/s/dispatch/automation.log" &&
  pass "9. a failed send: logged send-failed, rc 1, the other author still told" || fail "9. rc=$rc: $(cat "$T/out" "$T/s/dispatch/automation.log")"

# 10. bad args
reset; b="$(brief c002-good-reviewer "$GOOD")"
run REVIEW_NOTIFY_BRIEF="$T/nope.md" REVIEW_NOTIFY_REVIEWER=g-500; rc=$?
(( rc == 1 )) && grep -q 'FATAL REVIEW_NOTIFY_BRIEF' "$T/out" && pass "10. a missing brief is refused" || fail "10. brief rc=$rc"
run REVIEW_NOTIFY_BRIEF="$b" REVIEW_NOTIFY_REVIEWER='g-500;rm'; rc=$?
(( rc == 1 )) && grep -q 'FATAL REVIEW_NOTIFY_REVIEWER' "$T/out" && [[ "$(sends)" == 0 ]] && pass "10. a bad reviewer id is refused" || fail "10. reviewer rc=$rc"

# 11. the placer's hook
reset; b="$(brief c002-good-reviewer "$GOOD")"
run RUN_SNIPPET="spl_review_notify_placed c-001@boxa g-500@boxa c002-good-reviewer $b"; rc=$?
(( rc == 0 )) && [[ "$(sends)" == 2 ]] && pass "11. hook: a -reviewer seat tells its 2 authors" || fail "11. hook rc=$rc: $(cat "$T/out")"
reset; b="$(brief c002-code-lane "Kind: complex_coding
$GOOD")"
run RUN_SNIPPET="spl_review_notify_placed c-001@boxa c-500@boxa c002-code-lane $b"; rc=$?
(( rc == 0 )) && [[ "$(sends)" == 0 ]] && pass "11. hook: a coding lane sends nothing" || fail "11. coding lane rc=$rc: $(cat "$T/out" "$T/s/sends.log")"
reset; b="$(brief c002-none-reviewer "Nobody.")"
run RUN_SNIPPET="spl_review_notify_placed c-001@boxa g-500@boxa c002-none-reviewer $b"; rc=$?
(( rc == 0 )) && grep -q 'WARN review seat g-500@boxa: its authors were not all told' "$T/out" &&
  pass "11. hook: a brief with no author warns, the placer goes on (rc 0)" || fail "11. none rc=$rc: $(cat "$T/out")"
hook="$(awk '/^spl_spawn_place_launch\(\)/,/^}/' "$PROJ_ROOT/src/bash/run/spl-spawn-place.func.sh" | grep -A2 'spl_spawn_placed_close "\$id" "\$holder" "\$agent"')"
grep -q 'spl_review_notify_placed "\$holder" "\$agent" "\$4" "\$5"' <<<"$hook" && pass "11. spl_spawn_place_launch runs the hook after a placed seat" ||
  fail "11. no hook after spl_spawn_placed_close in spl_spawn_place_launch"

echo "spl-spawn-review-notify: ${fails} failure(s)"
[ "$fails" -eq 0 ]
