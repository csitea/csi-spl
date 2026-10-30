#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_review_go (spec 157 Rule 1, row B4, SPL-4101) sends GO <sha>
#          to the author only for a verified cross-vendor review PASS. A
#          sandbox: its own SPOOL_ROOT (lease, lease.conf, briefs, spools), a
#          bare origin with the review branch, a reviewer session log; the
#          sender is a stub that logs its args. do_spl_review_line_check runs
#          for real. No network, no hub, no live spool.
#     1. RED CONTROL a FAIL verdict -> rc 1, no GO, one hold note, refused
#     2. RED CONTROL reviewer and author share the vendor -> rc 2, no GO
#     3. RED CONTROL the reviewer's brief does not assign the author -> rc 3
#     4. RED CONTROL the author brief names owner-go keywords (APPLY,
#        do-provision, ENV=prd) with no Owner-go line -> rc 4; an Owner-go
#        id that is no HUM message -> rc 4; one that is -> GO
#     5. RED CONTROL the branch moved past the reviewed sha -> rc 5
#     6. RED CONTROL the reviewer's log is on another box -> rc 6
#     7. the author brief is not on this box -> rc 7
#     8. a docs-only line (no test in ran:), a test not in the log -> rc 8
#     9. GREEN a valid PASS -> rc 0, GO <sha> to the author on the row's
#        task from the holder, the PASS line in automation.log
#    10. the cron scan: the holder's spool, once per message, only from the
#        reviewer the line names, only within REVIEW_GO_MAX_AGE
#    11. the lease held elsewhere, stale, none -> nothing; never written
#    12. the dry run prints PLAN, sends and logs nothing
#    13. the install cron: dry run, one exact line, idempotent, check, remove;
#        RED CONTROL the installed line run as cron runs it, SPOOL_ROOT unset,
#        under run.sh's set -u: on the default spool root, no unbound
#        variable (both live ticks died on line 96, SPL-4316)
#    14. a retired reviewer: its brief is dispatch/briefs/<title of its newest
#        retired identity record>.md, the author in prose (one author, the
#        sha or task named), the author brief from its Author brief: line
#        (dispatch/briefs only) -> GO; RED CONTROLS two authors, no sha/task
#        -> rc 3, an Author brief: elsewhere -> rc 7
#    15. RED CONTROL a PASS header whose read: says FAIL (g-161's `grok PASS
#        ... read: JUDGMENT FAIL W1`, msg 95d5ed90) -> rc 1, no GO; control: a
#        red control's FAIL count in read: -> GO (SPL-4251)
#    16. a second review seat (spec 155 B5: grok R7 + agy strings, SPL-4251):
#        RED CONTROL the grok PASS while another placed brief names the same
#        author and sha -> rc 10, no GO, WAIT in automation.log; the agy PASS
#        then -> one GO, one PASS line; both in one tick -> one GO; controls:
#        a sibling brief of another sha or another author holds nothing
#    17. a re-placed seat (SPL-4316, m-874 -> g-636): RED CONTROL the sibling
#        seat retired with no review line for the sha -> GO (was rc 10 WAIT
#        forever); controls: a sibling placed but not yet spawned, live, or
#        retired with its PASS or FAIL in the holder's spool still holds (rc
#        10); the retired seat's PASS in one tick -> one GO
#    18. a seat placed on another box (SPL-4427), the lane map read through a
#        hub stub: RED CONTROLS a reviewer on boxb with no records here -> its
#        brief by the lane row's branch slug, or (rotated) its scope -> GO;
#        the same id here as another seat -> not judged on it (rc 3, or GO
#        on boxb's own brief); an author on boxb -> its lane map brief, not
#        the same id's here; a scope matching two different briefs -> rc 7;
#        no brief anywhere -> rc 3 / rc 7 naming the boxes; the real line
#        (log on boxb) -> [6]
#   REVIEW_GO_FUNC points the test at another copy of the action: the red
#   controls run it against a mutant (see the commit that added this file).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="${REVIEW_GO_FUNC:-$PROJ_ROOT/src/bash/run/spl-review-go.func.sh}"

NOW=2026-10-28T12:00:00Z
TASK=1c120227-ce10-5ffd-895a-2168872fce83
S="$T/s/spool"
LOG="$S/dispatch/automation.log"
G=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master)

# the sender stub logs its args
# shellcheck disable=SC2016 # the stub expands its own args at run time
printf '#!/bin/sh\necho "SEND $*" >>"$SEND_LOG"\nexit "${SEND_RC:-0}"\n' >"$T/send.sh"

# the repo: a bare origin, a clone, the review branch two commits deep
"${G[@]}" init -q --bare "$T/origin.git"
"${G[@]}" clone -q "$T/origin.git" "$T/repo" 2>/dev/null
echo a >"$T/repo/a.txt" && "${G[@]}" -C "$T/repo" add a.txt && "${G[@]}" -C "$T/repo" commit -qm base
"${G[@]}" -C "$T/repo" push -q origin HEAD:master
echo b >"$T/repo/a.txt" && "${G[@]}" -C "$T/repo" commit -qam change
SHA=$("${G[@]}" -C "$T/repo" rev-parse HEAD)
"${G[@]}" -C "$T/repo" push -q origin HEAD:refs/heads/review/c002-x

# reset [holder [age]]: a fresh spool; lease held by <holder> (default c-002@boxa)
reset() {
  rm -rf "$T/s" && mkdir -p "$S/dispatch" "$S/c-002/inbox" "$S/c-002/archive" "$T/s/logs"
  printf '%s %s\n' "${1:-c-002@boxa}" "$(( $(date +%s) - ${2:-5} ))" >"$S/dispatch/lease"
  printf 'LEASE_ORCH=c-001\nLEASE_MACHINE=boxa\nLEASE_ENV=prd\n' >"$S/dispatch/lease.conf"
  : >"$T/s/sent.log"
  rbrief g-111 "c-222@boxa (claude), SPL-1" "${SHA:0:12}"
  abrief c-222 "Do: a small orc fix. Tests green. Push only with do_spl_push_master."
  rlog g-111 "bash csi-spl-orc/src/bash/tests/foo.tst.sh"
}
# rbrief <reviewer> <author cell> <sha cell> [task]: the reviewer's placed brief
rbrief() {
  mkdir -p "$S/$1/lifetime"
  printf '# Lane brief: review\n\n## The row\n| author | review branch | sha | base | task |\n|---|---|---|---|---|\n| %s | review/c002-x | %s | origin/master | %s |\n\nSend the verdict.\n' \
    "$2" "$3" "${4:-$TASK}" >"$S/$1/lifetime/brief.md"
}
# abrief <author> <text>: the author's brief
abrief() { mkdir -p "$S/$1/lifetime"; printf '# Lane brief\n\n%s\n' "$2" >"$S/$1/lifetime/brief.md"; }
# rlog <reviewer> <command>: the reviewer's session log, one command in it
rlog() {
  mkdir -p "$T/s/logs/-opt-csi-csi-spl-wt-$1"
  python3 -c 'import json,sys; print(json.dumps({"type":"assistant","input":{"command":sys.argv[1]}}))' "$2" \
    >"$T/s/logs/-opt-csi-csi-spl-wt-$1/s.jsonl"
}
# line <reviewer> <vendor> <verdict> [ran] [log box]: an R7 review line
line() {
  printf 'review: %s@boxa %s %s %s ran: %s | read: 1 PASS 0 failures | log: %s@%s:%s' "$1" "$2" "$3" "$SHA" \
    "${4:-bash csi-spl-orc/src/bash/tests/foo.tst.sh}" "$1" "${5:-boxa}" "$T/s/logs/-opt-csi-csi-spl-wt-$1/s.jsonl"
}
# msg <file-ts> <from> <body> <msg id> [kind] [dir]: one message in the holder's spool; prints its path
msg() {
  local f="$S/c-002/${6:-inbox}/$1--$2--review-${4:0:8}.json"
  python3 -c 'import json,sys; print(json.dumps({"body":sys.argv[1],"files":[],"from":sys.argv[2],"kind":sys.argv[5],
    "msg_id":sys.argv[3],"task_id":sys.argv[4],"to":"c-002","ts":sys.argv[6],"v":1}))' \
    "$3" "$2" "$4" "$TASK" "${5:-result}" "${1:0:4}-${1:4:2}-${1:6:2}T${1:9:2}:${1:11:2}:${1:13:2}Z" >"$f"
  echo "$f"
}
# run [VAR=value]...: the action in a fresh bash; output in $T/out, rc returned
run() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$S" SPL_STATE_DIR="$T/s/state" \
    REVIEW_GO_NOW="$NOW" REVIEW_GO_SEND="$T/send.sh" SEND_LOG="$T/s/sent.log" REVIEW_GO_REPO="$T/repo" \
    REVIEW_LINE_BOX=boxa DRY_RUN=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$0" || { echo "FATAL cannot source $0"; exit 97; }
    do_spl_review_go' "$FUNC" >"$T/out" 2>&1
}
count() { local n; n=$(grep -c -- "${2:-.}" "$1" 2>/dev/null); echo "${n:-0}"; }
gos() { count "$T/s/sent.log" ' --kind task '; }
holds() { count "$T/s/sent.log" ' --to c-002 --kind note --task review-go '; }
# refused <case> <rc> <want rc> <log grep>: rc, no GO, one hold note, one refused log line
refused() {
  if (( $2 == $3 )) && [[ $(gos) == 0 && $(holds) == 1 && $(count "$LOG" "review-go .* action=refused rc=$3 ") == 1 ]] &&
    ! grep -q '^PASS ' "$LOG" && grep -q -- "$4" "$LOG"; then
    pass "$1: rc $3, no GO, the holder told once, logged refused"
  else fail "$1: rc=$2 (want $3) gos=$(gos) holds=$(holds) log=$(cat "$LOG" 2>/dev/null) out=$(tail -3 "$T/out")"; fi
}

# --- 1. RED CONTROL: FAIL verdict ----------------------------------------------------
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok FAIL)" 01000000-0000-4000-8000-000000000001)
run REVIEW_GO_MSG="$f"; refused "1. RED CONTROL: a FAIL verdict escalates" $? 1 "REVIEW FAIL from g-111@boxa"
grep -q 'REJECT' "$T/s/sent.log" && fail "1. a REJECT was sent" || pass "1. no automated REJECT or send-back"

# --- 2. RED CONTROL: same vendor ------------------------------------------------------
reset
rbrief c-333 "c-222@boxa (claude)" "${SHA:0:12}"; rlog c-333 "bash csi-spl-orc/src/bash/tests/foo.tst.sh"
f=$(msg 20261028T115900Z c-333@boxa "$(line c-333 claude PASS)" 02000000-0000-4000-8000-000000000002)
run REVIEW_GO_MSG="$f"; refused "2. RED CONTROL: same vendor (claude reviews claude) refused" $? 2 "shares the vendor of author c-222"

# --- 3. RED CONTROL: unassigned reviewer ----------------------------------------------
reset
rbrief g-111 "c-999@boxa" "0123456789ab" 99999999-0000-4000-8000-000000000000
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 03000000-0000-4000-8000-000000000003)
run REVIEW_GO_MSG="$f"; refused "3. RED CONTROL: a brief whose row is neither the sha nor the task refused" $? 3 "author not assigned"
reset
rm -rf "$S/g-111/lifetime"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 03000000-0000-4000-8000-000000000004)
run REVIEW_GO_MSG="$f"; refused "3. an unplaced reviewer (no lifetime brief) refused" $? 3 "unplaced reviewer"

# --- 4. RED CONTROL: owner-go keywords --------------------------------------------------
reset
abrief c-222 "terraform step 030-cloud-run-hub APPLY, dev then prd: make do-provision ENV=prd"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 04000000-0000-4000-8000-000000000004)
run REVIEW_GO_MSG="$f"; refused "4. RED CONTROL: an APPLY / do-provision / ENV=prd brief with no Owner-go line refused" $? 4 "owner-go keyword 'APPLY'"
reset
abrief c-222 $'Rotate the IAM binding.\nOwner-go: 4b8ef139-0000-4000-8000-000000000000'
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 04000000-0000-4000-8000-000000000005)
run REVIEW_GO_MSG="$f"; refused "4. an Owner-go id that is no HUM message here refused" $? 4 "is no HUM-<n> message"
reset
abrief c-222 $'Rotate the IAM binding.\nOwner-go: 4b8ef139-0000-4000-8000-000000000000'
msg 20261028T110000Z HUM-10 "go for the IAM change" 4b8ef139-0000-4000-8000-000000000000 note archive >/dev/null
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 04000000-0000-4000-8000-000000000006)
run REVIEW_GO_MSG="$f"; rc=$?
(( rc == 0 )) && [[ $(gos) == 1 ]] && pass "4. control: an Owner-go id that is a HUM-10 message lets the GO through" || fail "4. owner-go ok rc=$rc out=$(tail -3 "$T/out")"
for kw in 'DRY_RUN=0' 'PROBE_PRD_GO' 'billing' 'service account key' '/etc/hosts' 'do-tf-apply'; do
  reset; abrief c-222 "run it with $kw here"
  f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 04000000-0000-4000-8000-000000000007)
  run REVIEW_GO_MSG="$f"; rc=$?
  (( rc == 4 )) && [[ $(gos) == 0 ]] || fail "4. keyword '$kw' not refused (rc $rc)"
done
pass "4. each keyword (DRY_RUN=0, PROBE_PRD_GO, billing, service account key, /etc/, do-tf-apply) refused alone"
reset; abrief c-222 "deployed dev AND prd; cite the issue key; appliance names stay"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 04000000-0000-4000-8000-000000000008)
run REVIEW_GO_MSG="$f"; rc=$?
(( rc == 0 )) && pass "4. bare prd, key and 'appliance' are no owner-go keywords" || fail "4. false positive rc=$rc out=$(tail -2 "$T/out")"

# --- 5. RED CONTROL: branch moved ---------------------------------------------------------
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 05000000-0000-4000-8000-000000000005)
echo c >"$T/repo/a.txt" && "${G[@]}" -C "$T/repo" commit -qam more && "${G[@]}" -C "$T/repo" push -q origin HEAD:refs/heads/review/c002-x
run REVIEW_GO_MSG="$f"; refused "5. RED CONTROL: the branch moved past the reviewed sha refused" $? 5 "branch 'review/c002-x' on origin is"
"${G[@]}" -C "$T/repo" push -q -f origin "$SHA:refs/heads/review/c002-x"

# --- 6. RED CONTROL: remote log --------------------------------------------------------------
reset
rm -rf "$T/s/logs"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS 'bash csi-spl-orc/src/bash/tests/foo.tst.sh' boxb)" 06000000-0000-4000-8000-000000000006)
run REVIEW_GO_MSG="$f"; refused "6. RED CONTROL: a log on box boxb refused (never fetched)" $? 6 "log is on box"

# --- 7. the author brief is not here -----------------------------------------------------------
reset
rm -rf "$S/c-222"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 07000000-0000-4000-8000-000000000007)
run REVIEW_GO_MSG="$f"; refused "7. an author brief not on this box refused (not verified)" $? 7 "has no brief on this box"

# --- 8. the review line check ---------------------------------------------------------------------
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS 'git diff --stat; do_check_dist_hygiene')" 08000000-0000-4000-8000-000000000008)
run REVIEW_GO_MSG="$f"; refused "8. a docs-only line (no test in ran:) refused" $? 8 "ran: names no test"
reset
rlog g-111 "git status"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 08000000-0000-4000-8000-000000000009)
run REVIEW_GO_MSG="$f"; refused "8. a test ran: names but the log never ran refused" $? 8 "MISSING foo.tst.sh"

# --- 9. GREEN ------------------------------------------------------------------------------------
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)"$'\n\nW1 none.' 09000000-0000-4000-8000-000000000009)
run REVIEW_GO_MSG="$f"; rc=$?
if (( rc == 0 )) && [[ $(gos) == 1 && $(holds) == 0 ]] && grep -qxF "SEND --from c-002 --to c-222@boxa --kind task --task $TASK --body GO $SHA" "$T/s/sent.log"; then
  pass "9. GREEN: GO <sha> to c-222@boxa on the row's task, from the holder"
else fail "9. rc=$rc sent=$(cat "$T/s/sent.log") out=$(tail -4 "$T/out")"; fi
if [[ $(count "$LOG") == 1 ]] && grep -qE "^PASS 20[0-9-]+T[0-9:]+Z 09000000-0000-4000-8000-000000000009 $TASK c-222 g-111 $SHA$" "$LOG"; then
  pass "9. automation.log: PASS <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha>"
else fail "9. log=$(cat "$LOG" 2>/dev/null)"; fi
run REVIEW_GO_MSG="$f"; rc=$?
(( rc == 0 )) && [[ $(gos) == 1 ]] && pass "9. the same message again sends no second GO" || fail "9. resent rc=$rc gos=$(gos)"
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 09000000-0000-4000-8000-00000000000a)
run REVIEW_GO_MSG="$f" SEND_RC=1; rc=$?
(( rc == 9 )) && [[ ! -s "$LOG" ]] && pass "9. a failed GO send logs nothing (the next run tries again)" || fail "9. send fail rc=$rc log=$(cat "$LOG")"

# --- 10. the cron scan -----------------------------------------------------------------------------
reset
msg 20261028T115800Z g-111@boxa "$(line g-111 grok PASS)" 10000001-0000-4000-8000-000000000001 result archive >/dev/null
msg 20261028T115900Z c-002 "fwd: $(line g-111 grok PASS)"$'\n'"$(line g-111 grok PASS)" 10000002-0000-4000-8000-000000000002 >/dev/null
msg 20261028T100000Z g-111@boxa "$(line g-111 grok PASS)" 10000003-0000-4000-8000-000000000003 >/dev/null
msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 10000004-0000-4000-8000-000000000004 task >/dev/null
run; rc=$?
if (( rc == 0 )) && [[ $(gos) == 1 && $(holds) == 0 ]] && grep -q "^PASS .* 10000001-0000-4000-8000-000000000001 " "$LOG" && [[ $(count "$LOG") == 1 ]]; then
  pass "10. one GO: a relayed copy, an hour-old message and a kind task message are not read"
else fail "10. rc=$rc gos=$(gos) log=$(cat "$LOG") out=$(tail -3 "$T/out")"; fi
run; [[ $(gos) == 1 && $(count "$LOG") == 1 ]] && pass "10. the next tick sends nothing again" || fail "10. retick gos=$(gos)"
run REVIEW_GO_MAX_AGE=180; [[ $(gos) == 2 ]] && pass "10. control: a wider window reads the older message" || fail "10. window gos=$(gos)"
reset
msg 20261028T115900Z g-111@boxa "$(line g-111 grok FAIL)" 10000005-0000-4000-8000-000000000005 >/dev/null
run; run; [[ $(holds) == 1 && $(gos) == 0 ]] && pass "10. a refusal is told to the holder once, not every tick" || fail "10. holds=$(holds)"
run REVIEW_GO_MAX_AGE=x; (( $? == 1 )) && grep -q 'FATAL REVIEW_GO_MAX_AGE' "$T/out" && pass "10. a bad REVIEW_GO_MAX_AGE is refused" || fail "10. bad max"

# --- 11. the lease -----------------------------------------------------------------------------------
for lease in "c-002@sat 5" "c-002@boxa 999" "none 0"; do
  # shellcheck disable=SC2086 # holder and age, split on purpose
  reset $lease
  msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 11000000-0000-4000-8000-000000000001 >/dev/null
  [[ "$lease" == none* ]] && rm -f "$S/dispatch/lease"
  run; rc=$?
  if (( rc == 0 )) && [[ $(gos) == 0 && ! -s "$LOG" ]] && grep -qE 'another machine|no live dispatch lease holder' "$T/out"; then
    pass "11. lease '$lease': nothing sent on this machine"
  else fail "11. lease '$lease' rc=$rc out=$(tail -3 "$T/out")"; fi
done
reset
cp -p "$S/dispatch/lease" "$T/lease.before"
run; cmp -s "$T/lease.before" "$S/dispatch/lease" && [[ ! -e "$S/dispatch/lease.log" ]] &&
  pass "11. the lease is read, never written" || fail "11. the lease changed"

# --- 12. dry run ----------------------------------------------------------------------------------------
reset
msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 12000000-0000-4000-8000-000000000001 >/dev/null
msg 20261028T115900Z g-111@boxa "$(line g-111 grok FAIL)" 12000002-0000-4000-8000-000000000002 >/dev/null
run DRY_RUN=1; rc=$?
if (( rc == 0 )) && grep -q "^PLAN GO $SHA to c-222@boxa on task $TASK" "$T/out" && grep -q '^PLAN HOLD msg 12000002-0000-4000-8000-000000000002 (rc 1)' "$T/out" &&
  [[ ! -s "$T/s/sent.log" && ! -e "$LOG" ]]; then
  pass "12. the dry run prints PLAN GO and PLAN HOLD, sends and logs nothing"
else fail "12. rc=$rc out=$(tail -4 "$T/out")"; fi

# --- 13. the install cron ---------------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc"
# the shared checkout's ./run: run.sh's set -u, the action under test, the
# lease and the spool read stubbed (it never reads the live root it defaults to)
cat >"$SRC/csi-spl-orc/run" <<'EOF'
#!/bin/bash
set -u -o pipefail
do_log() { echo "$*"; }
do_require_bin() { return 0; }
for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
source "$STUB_FUNC"
spl_lease_init() { LEASE_DIR="$STUB_DIR"; LEASE_STALE=180; }
spl_lease_conf() { :; }
_spl_review_go_holder() { echo c-002; }
_spl_review_go_scan() { echo "SCAN $2" >>"$STUB_DIR/scan.log"; }
"$2"
EOF
chmod +x "$SRC/csi-spl-orc/run"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n* * * * * x # csi-spl:review-go-not-this\n' >"$T/crontab"
cron() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" \
    REVIEW_GO_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_review_go_install_cron' >"$T/o" 2>&1
}
before="$(md5sum <"$T/crontab")"
cron; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q 'do_spl_review_go >> .*/cron.out 2>&1 # csi-spl:review-go$' "$T/o" &&
  pass "13. dry run: the diff, nothing written" || fail "13. dry rc=$rc $(cat "$T/o")"
cron REVIEW_GO_CRON_ACTION=check && fail "13. check passed with no line" || pass "13. check fails while not installed"
cron DRY_RUN=0; rc=$?
# shellcheck disable=SC2016 # $HOME stays literal in the line
want="* * * * * cd $SRC/csi-spl-orc && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n $T/log/review-go.cron.lock env DRY_RUN=0 ./run -a do_spl_review_go >> $T/log/cron.out 2>&1 # csi-spl:review-go"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" && grep -q 'review-go-not-this$' "$T/crontab" &&
  pass "13. DRY_RUN=0: one exact every-minute line, the other lines kept" || fail "13. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
mkdir -p "$T/stub"
# shellcheck disable=SC2016 # the line is run by a fresh shell, as cron does
env -u SPOOL_ROOT PROJ_PATH="$PROJ_ROOT" STUB_FUNC="$FUNC" STUB_DIR="$T/stub" bash -c "$(grep '# csi-spl:review-go$' "$T/crontab" | cut -d' ' -f6-)"; rc=$?
if (( rc == 0 )) && grep -qxF 'SCAN /var/spool-hub/c-002' "$T/stub/scan.log" && ! grep -q 'unbound variable' "$T/log/cron.out"; then
  pass "13. RED CONTROL: the installed line, SPOOL_ROOT unset, set -u: reads the default spool root"
else fail "13. installed line rc=$rc scan=$(cat "$T/stub/scan.log" 2>/dev/null) out=$(tail -3 "$T/log/cron.out" 2>/dev/null)"; fi
cp "$T/crontab" "$T/ct.1"; cron DRY_RUN=0
cmp -s "$T/crontab" "$T/ct.1" && [[ $(grep -c '# csi-spl:review-go$' "$T/crontab") == 1 ]] && pass "13. a second install changes nothing" || fail "13. idempotent: $(cat "$T/crontab")"
cron REVIEW_GO_CRON_ACTION=check && grep -q 'OK the review GO is installed' "$T/o" && pass "13. check passes once installed" || fail "13. check: $(cat "$T/o")"
cron DRY_RUN=0 REVIEW_GO_CRON_ACTION=remove
! grep -q '# csi-spl:review-go$' "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" && grep -q 'review-go-not-this$' "$T/crontab" &&
  pass "13. remove takes only its line" || fail "13. remove: $(cat "$T/crontab")"
cron REVIEW_GO_CRON_ACTION=bogus; rc=$?
(( rc == 1 )) && grep -q 'FATAL REVIEW_GO_CRON_ACTION' "$T/o" && pass "13. a bad action is refused" || fail "13. bad action rc=$rc"

# --- 14. a retired reviewer, a prose brief, an author on another box ------------------------------------------
# pbrief <slug> <text>: a placement brief in dispatch/briefs (the prose form)
# shellcheck disable=SC2016 # the backticks are markdown, not an expansion
pbrief() { printf '# Lane brief: review\n\nPlacement slug `%s`. %s\n' "$1" "$2" >"$S/dispatch/briefs/$1.md"; }
# retire <reviewer> <spawned> <slug>: the seat is gone; its retired identity record keeps the slug as title
retire() {
  rm -rf "${S:?}/$1" && mkdir -p "$S/agents/retired" "$S/dispatch/briefs"
  printf '{"id":"%s","title":"%s","v":1}\n' "$1" "$3" >"$S/agents/retired/$1.$2.json"
}
prose() { echo "Author c-222@boxa (claude). Branch \`review/c002-x\` at \`$SHA\`. Author brief: $S/dispatch/briefs/c002-x.md;"; }
reset14() {
  reset; retire g-111 20261028T100000Z c002-x-grok-reviewer; rm -rf "${S:?}/c-222"
  pbrief c002-x-grok-reviewer "$(prose)"; pbrief c002-x "Do: a small orc fix. Tests green."
}
reset14
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 14000000-0000-4000-8000-000000000001)
run REVIEW_GO_MSG="$f"; rc=$?
(( rc == 0 )) && grep -qxF "SEND --from c-002 --to c-222@boxa --kind task --task $TASK --body GO $SHA" "$T/s/sent.log" &&
  grep -qE "^PASS [^ ]+ 14000000-0000-4000-8000-000000000001 $TASK c-222 g-111 $SHA$" "$LOG" &&
  pass "14. GREEN: retired reviewer (dispatch/briefs/<title>.md), prose author, author brief from its Author brief: line" ||
  fail "14. green rc=$rc sent=$(cat "$T/s/sent.log") out=$(tail -3 "$T/out")"
reset14; printf '{"id":"g-111","title":"other-slug","v":1}\n' >"$S/agents/retired/g-111.20261027T100000Z.json"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 14000000-0000-4000-8000-000000000002)
run REVIEW_GO_MSG="$f"; (( $? == 0 && $(gos) == 1 )) && pass "14. the newest retired record of the id is read" || fail "14. newest: $(tail -3 "$T/out")"
reset14; pbrief c002-x-grok-reviewer "Author c-222@boxa (claude), with author c-333@boxa. Branch \`review/c002-x\` at \`$SHA\`."
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 14000000-0000-4000-8000-000000000003)
run REVIEW_GO_MSG="$f"; refused "14. RED CONTROL: a prose brief naming two authors" $? 3 "unplaced reviewer or author not assigned in $S/dispatch/briefs/c002-x-grok-reviewer.md"
reset14; pbrief c002-x-grok-reviewer "Author c-222@boxa (claude). Branch \`review/c002-x\` at \`0123456789abcdef\`, task 0f0f0f0f."
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 14000000-0000-4000-8000-000000000004)
run REVIEW_GO_MSG="$f"; refused "14. RED CONTROL: a prose brief naming neither the sha nor the task (an id reused for another seat)" $? 3 "author not assigned"
reset14; rm -f "$S/agents/retired/"*.json
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 14000000-0000-4000-8000-000000000005)
run REVIEW_GO_MSG="$f"; refused "14. a retired reviewer with no identity record" $? 3 "author not assigned in $S/g-111/lifetime/brief.md"
reset14; mkdir -p "$T/elsewhere" && echo 'Do: it.' >"$T/elsewhere/c002-x.md"
pbrief c002-x-grok-reviewer "$(prose | sed "s|$S/dispatch/briefs/c002-x.md|$T/elsewhere/c002-x.md|")"
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 14000000-0000-4000-8000-000000000006)
run REVIEW_GO_MSG="$f"; refused "14. RED CONTROL: an Author brief: outside dispatch/briefs is not read" $? 7 "author c-222 has no brief on this box"
reset14; pbrief c002-x "Do: then ENV=prd ./run -a do_x."
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 14000000-0000-4000-8000-000000000007)
run REVIEW_GO_MSG="$f"; refused "14. the owner-go scan reads the Author brief: copy" $? 4 "owner-go keyword 'ENV=prd'"

# --- 15. a PASS header whose read: says FAIL -------------------------------------------------------------------
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS | sed 's/read: 1 PASS 0 failures/read: 9 PASS; JUDGMENT FAIL W1 a.sh:3 drops the lock/')" 15000000-0000-4000-8000-000000000001)
run REVIEW_GO_MSG="$f"; refused "15. RED CONTROL: a PASS header whose read: says JUDGMENT FAIL W1" $? 1 "read: says FAIL"
reset
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS | sed 's/read: 1 PASS 0 failures/read: 9 PASS, red control 2 FAIL, restored 9 PASS/')" 15000000-0000-4000-8000-000000000002)
run REVIEW_GO_MSG="$f"; rc=$?
(( rc == 0 && $(gos) == 1 )) && pass "15. control: a red control's FAIL count in read: still GOes" || fail "15. red-control count rc=$rc out=$(tail -3 "$T/out")"

# --- 16. a second review seat for the same author and sha ----------------------------------------------------------
waits() { count "$LOG" '^WAIT '; }
reset16() {
  reset14; retire a-333 20261028T100000Z c002-x-agy-strings; rlog a-333 "bash csi-spl-orc/src/bash/tests/foo.tst.sh"
  pbrief c002-x-agy-strings "Author c-222@boxa (claude). Author brief: $S/dispatch/briefs/c002-x.md; Branch \`review/c002-x\` at \`${SHA:0:12}\`. Strings only."
}
# live <id> <slug>: the seat is up; its live identity record has the slug as title
live() { mkdir -p "$S/agents"; printf '{"id":"%s","title":"%s","v":1}\n' "$1" "$2" >"$S/agents/$1.json"; }
reset16; live a-333 c002-x-agy-strings
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 16000000-0000-4000-8000-000000000001)
run REVIEW_GO_MSG="$f"; rc=$?
if (( rc == 10 )) && [[ $(gos) == 0 && $(holds) == 1 && $(waits) == 1 ]] && ! grep -q '^PASS ' "$LOG" &&
  grep -qE "^WAIT [^ ]+ 16000000-0000-4000-8000-000000000001 $TASK c-222 g-111 $SHA c002-x-grok-reviewer$" "$LOG" &&
  grep -q 'c002-x-agy-strings' "$T/s/sent.log"; then
  pass "16. RED CONTROL: the grok PASS waits for the live agy seat of the same author and sha (rc 10, no GO, WAIT logged, holder told)"
else fail "16. wait rc=$rc gos=$(gos) holds=$(holds) log=$(cat "$LOG" 2>/dev/null) out=$(tail -3 "$T/out")"; fi
run REVIEW_GO_MSG="$f"; [[ $(gos) == 0 && $(holds) == 1 ]] && pass "16. the waiting message is not checked again" || fail "16. rechecked holds=$(holds)"
f=$(msg 20261028T115930Z a-333@boxa "$(line a-333 agy PASS)" 16000000-0000-4000-8000-000000000002)
run REVIEW_GO_MSG="$f"; rc=$?
if (( rc == 0 )) && [[ $(gos) == 1 ]] && grep -qxF "SEND --from c-002 --to c-222@boxa --kind task --task $TASK --body GO $SHA" "$T/s/sent.log" &&
  [[ $(count "$LOG" '^PASS ') == 1 ]] && grep -qE "^PASS [^ ]+ 16000000-0000-4000-8000-000000000002 $TASK c-222 a-333 $SHA$" "$LOG"; then
  pass "16. the agy PASS then sends the one GO and the one PASS line"
else fail "16. second rc=$rc gos=$(gos) log=$(cat "$LOG") out=$(tail -3 "$T/out")"; fi
reset16
msg 20261028T115900Z a-333@boxa "$(line a-333 agy PASS)" 16000000-0000-4000-8000-000000000003 >/dev/null
msg 20261028T115930Z g-111@boxa "$(line g-111 grok PASS)" 16000000-0000-4000-8000-000000000004 >/dev/null
run; run; rc=$?
(( rc == 0 )) && [[ $(gos) == 1 && $(waits) == 1 && $(count "$LOG" '^PASS ') == 1 ]] && grep -q "^PASS .* 16000000-0000-4000-8000-000000000004 " "$LOG" &&
  pass "16. both PASS in one tick (agy first): one WAIT, one GO, the next tick nothing" || fail "16. one tick gos=$(gos) log=$(cat "$LOG") out=$(tail -3 "$T/out")"
reset16; live a-333 c002-x-agy-strings
msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 16000000-0000-4000-8000-000000000005 >/dev/null
run DRY_RUN=1; rc=$?
(( rc == 0 )) && grep -q '^PLAN WAIT msg 16000000-0000-4000-8000-000000000005 (rc 10): .*c002-x-agy-strings' "$T/out" && [[ ! -s "$T/s/sent.log" && ! -e "$LOG" ]] &&
  pass "16. the dry run prints PLAN WAIT, sends and logs nothing" || fail "16. dry rc=$rc out=$(tail -3 "$T/out")"
for other in "another sha|Author c-222@boxa (claude). Branch \`review/c002-x\` at \`0123456789abcdef\`." \
             "another author|Author c-444@boxa (claude). Branch \`review/c002-y\` at \`${SHA:0:12}\`."; do
  reset16; pbrief c002-x-agy-strings "${other#*|}"
  f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 16000000-0000-4000-8000-000000000006)
  run REVIEW_GO_MSG="$f"; rc=$?
  (( rc == 0 && $(gos) == 1 && $(waits) == 0 )) && pass "16. control: a brief of ${other%%|*} holds nothing" || fail "16. ${other%%|*} rc=$rc out=$(tail -3 "$T/out")"
done

# --- 17. a re-placed seat: the sibling retired with no review line -----------------------------------------
# the sat case (msg 7f1bd557): m-874 (c002-x-mistral-reviewer) failed 2 tries, retired, re-placed by g-111
reset17() {
  reset16; rm -f "$S/dispatch/briefs/c002-x-agy-strings.md"; retire m-874 20261028T090000Z c002-x-mistral-reviewer
  pbrief c002-x-mistral-reviewer "Author c-222@boxa (claude). Author brief: $S/dispatch/briefs/c002-x.md; Branch \`review/c002-x\` at \`${SHA:0:12}\`."
}
reset17
f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 17000000-0000-4000-8000-000000000001)
run REVIEW_GO_MSG="$f"; rc=$?
if (( rc == 0 )) && [[ $(gos) == 1 && $(waits) == 0 ]] && grep -qxF "SEND --from c-002 --to c-222@boxa --kind task --task $TASK --body GO $SHA" "$T/s/sent.log" &&
  grep -qE "^PASS [^ ]+ 17000000-0000-4000-8000-000000000001 $TASK c-222 g-111 $SHA$" "$LOG" &&
  grep -q 'review seat c002-x-mistral-reviewer (m-874) retired with no review line' "$T/out"; then
  pass "17. RED CONTROL: a sibling seat retired with no review line (re-placed) holds nothing: rc 0, one GO"
else fail "17. re-placed rc=$rc gos=$(gos) log=$(cat "$LOG" 2>/dev/null) out=$(tail -3 "$T/out")"; fi
for held in "placed, not yet spawned|rm -f $S/agents/retired/m-874.*.json" \
            "live again under the same slug|live m-875 c002-x-mistral-reviewer" \
            "retired, its PASS in the holder's spool|msg 20261028T115800Z m-874@boxa \"\$(line m-874 mistral PASS)\" 17000000-0000-4000-8000-000000000010 result archive" \
            "retired, its FAIL in the holder's spool|msg 20261028T115800Z m-874@boxa \"\$(line m-874 mistral FAIL)\" 17000000-0000-4000-8000-000000000011 result archive"; do
  reset17; eval "${held#*|}" >/dev/null
  f=$(msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 17000000-0000-4000-8000-000000000002)
  run REVIEW_GO_MSG="$f"; rc=$?
  (( rc == 10 && $(gos) == 0 && $(waits) == 1 )) && grep -q 'c002-x-mistral-reviewer' "$T/s/sent.log" &&
    pass "17. control: a sibling seat ${held%%|*} still holds the GO (rc 10)" || fail "17. ${held%%|*} rc=$rc gos=$(gos) out=$(tail -3 "$T/out")"
done
reset17
msg 20261028T115900Z g-111@boxa "$(line g-111 grok PASS)" 17000000-0000-4000-8000-000000000003 >/dev/null
msg 20261028T115930Z m-874@boxa "$(line m-874 mistral PASS)" 17000000-0000-4000-8000-000000000004 >/dev/null
rlog m-874 "bash csi-spl-orc/src/bash/tests/foo.tst.sh"
run; rc=$?
(( rc == 0 )) && [[ $(gos) == 1 && $(waits) == 1 && $(count "$LOG" '^PASS ') == 1 ]] && grep -q "^PASS .* 17000000-0000-4000-8000-000000000004 " "$LOG" &&
  pass "17. the retired seat's PASS in the same tick (grok first): one WAIT, one GO" || fail "17. one tick rc=$rc gos=$(gos) log=$(cat "$LOG" 2>/dev/null) out=$(tail -3 "$T/out")"

# --- 18. a seat placed on another box (SPL-4427) ----------------------------------------------------------
# the hub stub prints the lane map rows of $LANES_JSON; the lane read is do_spl_lane_map's (spl_lane_hub_read)
printf '#!/bin/sh\ncat "$LANES_JSON"\n' >"$T/hub.sh" && chmod +x "$T/hub.sh"
# lanes <id@box|branch|scope>...: the lane map's rows
lanes() {
  local r rows=() id box br sc
  for r in "$@"; do
    IFS='|' read -r id br sc <<<"$r"; box="${id#*@}" id="${id%@*}"
    rows+=("$(jq -cn --arg i "$id" --arg b "$box" --arg br "$br" --arg s "$sc" \
      '{agent_id: $i, agent_box: $b, branch: $br, scope: $s, state: "done", updated_at: "2026-10-28T11:00:00Z"}')")
  done
  printf '{"lanes":[%s]}\n' "$(IFS=,; echo "${rows[*]}")" >"$T/s/lanes.json"
}
# dbrief <slug> <author cell> <heading>: a reviewer brief (the table row) in dispatch/briefs
dbrief() {
  mkdir -p "$S/dispatch/briefs"
  printf '# %s\n\n| author | review branch | sha | base | task |\n|---|---|---|---|---|\n| %s | review/c002-x | %s | origin/master | %s |\n' \
    "$3" "$2" "${SHA:0:12}" "$TASK" >"$S/dispatch/briefs/$1.md"
}
# reset18: the reviewer g-111 runs on boxb: no lifetime dir, no identity record here
reset18() {
  reset; rm -rf "${S:?}/g-111"; : >"$T/s/lanes.json"
  dbrief c002-x-grok-reviewer "c-222@boxa (claude)" "Seat brief: R7 review of the c002-x orc fix"
}
run18() { run LANE_FLEET=main LANE_BOX=boxa LANE_HUB_CMD="$T/hub.sh" LANES_JSON="$T/s/lanes.json" "$@"; }
# go18 <case> <msg id> <rc>: a GO to c-222@<box> and its PASS line
go18() {
  (( $3 == 0 )) && grep -qxF "SEND --from c-002 --to c-222@${4:-boxa} --kind task --task $TASK --body GO $SHA" "$T/s/sent.log" &&
    grep -qE "^PASS [^ ]+ $2 $TASK c-222 g-111 $SHA$" "$LOG" && pass "$1" ||
    fail "$1: rc=$3 sent=$(cat "$T/s/sent.log") out=$(tail -3 "$T/out")"
}
reset18; lanes "g-111@boxb|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000001)
run18 REVIEW_GO_MSG="$f"; go18 "18. RED CONTROL: a reviewer on boxb (no lifetime dir, no identity record here): its brief from the lane map's branch slug -> GO" 18000000-0000-4000-8000-000000000001 $?
reset18; lanes "g-111@boxb|g-111-rotate|Seat brief: R7 review of the c002-x orc fix"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000002)
run18 REVIEW_GO_MSG="$f"; go18 "18. a rotated reviewer (branch g-111-rotate): its brief by the lane row's scope = the brief's heading -> GO" 18000000-0000-4000-8000-000000000002 $?
reset18; lanes "g-111@boxb|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS "" boxb | sed 's/@boxa /@boxb /')" 18000000-0000-4000-8000-000000000003)
run18 REVIEW_GO_MSG="$f"; refused "18. the real cross-box line (log on boxb): [3] and [7] pass, the hold is [6]" $? 6 "log is on box boxb"
reset18; lanes "g-111@boxb|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000004)
run REVIEW_GO_MSG="$f"; refused "18. no fleet (no lane map): a reviewer on boxb holds, both boxes named" $? 3 "reviewer g-111@boxb runs on box boxb: no brief for it on this box boxa"
reset18; lanes "g-111@boxc|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000005)
run18 REVIEW_GO_MSG="$f"; refused "18. RED CONTROL: a brief nowhere (the lane row is g-111@boxc's) holds, both boxes named" $? 3 "brief on another box, not judged"
reset; lanes
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000006)
run18 REVIEW_GO_MSG="$f"; refused "18. RED CONTROL: g-111 here is another seat (its brief assigns c-222): g-111@boxb is not judged on it" $? 3 "reviewer g-111@boxb runs on box boxb"
reset18; rbrief g-111 "c-333@boxa (claude)" 0123456789ab 0f0f0f0f-0000-4000-8000-000000000000
lanes "g-111@boxb|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000007)
run18 REVIEW_GO_MSG="$f"; go18 "18. RED CONTROL: g-111 here is another seat (one id, two seats on two boxes): g-111@boxb's own brief -> GO" 18000000-0000-4000-8000-000000000007 $?
# the author on boxb: c-222 here is another seat whose brief needs an owner go
reset18; dbrief c002-x-grok-reviewer "c-222@boxb (claude)" "Seat brief: R7 review of the c002-x orc fix"
abrief c-222 "Do: then ENV=prd ./run -a do_x."; printf '# Lane brief: the c002-x orc fix\n\nDo: a small orc fix.\n' >"$S/dispatch/briefs/c002-x.md"
lanes "g-111@boxb|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix" "c-222@boxb|c-222-c002-x|Lane brief: the c002-x orc fix"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000008)
run18 REVIEW_GO_MSG="$f"; go18 "18. RED CONTROL: the author on boxb: its brief from the lane map, not c-222's here (ENV=prd) -> GO" 18000000-0000-4000-8000-000000000008 $? boxb
lanes "g-111@boxb|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix" "c-222@boxb|c-222-rotate|Lane brief: the c002-x orc fix"
cp "$S/dispatch/briefs/c002-x.md" "$S/dispatch/briefs/c002-x-2.md"; : >"$T/s/sent.log"; : >"$LOG"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-000000000009)
run18 REVIEW_GO_MSG="$f"; go18 "18. the author by its scope: two copies of one brief (a re-placement) count as one" 18000000-0000-4000-8000-000000000009 $? boxb
printf '# Lane brief: the c002-x orc fix\n\nDo: then ENV=prd ./run -a do_x.\n' >"$S/dispatch/briefs/c002-x-2.md"; : >"$T/s/sent.log"; : >"$LOG"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-00000000000a)
run18 REVIEW_GO_MSG="$f"; refused "18. RED CONTROL: the author's scope matches two different briefs: none is read" $? 7 "author box boxb"
lanes "g-111@boxb|g-111-c002-x-grok-reviewer|Seat brief: R7 review of the c002-x orc fix"; : >"$T/s/sent.log"; : >"$LOG"
f=$(msg 20261028T115900Z g-111@boxb "$(line g-111 grok PASS)" 18000000-0000-4000-8000-00000000000b)
run18 REVIEW_GO_MSG="$f"; refused "18. the author on boxb with no brief here holds, its box named" $? 7 "author c-222 has no brief on this box boxa (author box boxb"

echo "spl-review-go: ${fails} failure(s)"
[ "$fails" -eq 0 ]
