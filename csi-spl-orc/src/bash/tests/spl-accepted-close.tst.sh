#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_accepted_close (spec 157 Rule 2, row B5, SPL-4102) sends a
#          lane its ACCEPTED only when its reviewed work, and nothing else,
#          landed. A sandbox: a temp bare origin, the lane's clone (its
#          registry.tsv worktree), another clone that moves master, its own
#          SPOOL_ROOT (lease, lease.conf, the holder's archive, automation.log)
#          and REAL do_spl_push_master runs that write pushes.log. The review
#          line is re-checked by the REAL do_spl_review_line_check on a fake
#          journal. Stubs: gh, the sender, do_check_lane_served (network) and
#          _spl_review_go_row (row B4's author lookup, tested by B4). No
#          network, no hub, no live spool.
#   Red controls (spec 157 Rule 2 section 6), each: that exit code, no ACCEPTED:
#     1. an empty reviewed + landed commit -> 1
#     2. a 2-commit review, 1 commit landed -> 2
#     3. two real pushes: push 1 an unreviewed fixup, then the review, push 2
#        the reviewed commit; pushes.log holds both ranges -> 3
#     4. a PASS row whose journal lacks the run (and one whose sha differs
#        from the message) -> 4
#     5. the reviewed commit landed with a changed code line -> 5
#     6. no PASS row -> 6
#     7. a failed workflow -> 7; the holder is told once, not every run
#   Green:
#     8. 2 reviewed commits rebased over another lane's context change ->
#        rc 0, ACCEPTED (auto, spec 157 rule 2, automation.log <msg>): on
#        master <landed>, from the holder, kind result, on the row's task;
#        an audit note; one accepted line; the next run sends nothing
#   Defers and guards:
#     9. CI running, deploy lag -> 8, nothing sent; a cancelled run with a
#        newer master success -> 0; a missing issue key -> 9
#    10. the lease on another machine, or stale -> rc 0, nothing judged;
#        the dry run prints PLAN and sends nothing
#    11. the install cron: dry run, one exact line, idempotent, check, remove
#   ACCEPT_FUNC points the test at another copy of the action: the red
#   controls run it against a mutant (see the commit that added this file).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
unset AGENT_ID
FUNC="${ACCEPT_FUNC:-$PROJ_ROOT/src/bash/run/spl-accepted-close.func.sh}"

B="$T/origin.git" L="$T/wt/c-901" O="$T/other" SP="$T/spool"
EM=lane@example.com TASK=dispatch-b5test
G=(-c user.name=lane -c "user.email=$EM" -c init.defaultBranch=master -c advice.detachedHead=false)
LOG="$SP/dispatch/automation.log"
mkdir -p "$T/nohooks"
# shellcheck disable=SC2016 # the stubs expand their own args at run time
printf '#!/bin/sh\necho "SEND $*" >>"$SEND_LOG"\n' >"$T/send.sh"
# the gh stub: `run list --commit` prints $T/gh.runs, `--workflow` $T/gh.succ
cat >"$T/gh" <<'EOF'
#!/bin/sh
case "$*" in *--workflow*) cat "$GH_DIR/gh.succ" 2>/dev/null ;; *) cat "$GH_DIR/gh.runs" ;; esac
EOF
chmod +x "$T/gh"
GREEN='[{"workflowName":"10 ci","status":"completed","conclusion":"success"},{"workflowName":"20 hub","status":"completed","conclusion":"skipped"}]'

# fresh: new origin, lane clone, other clone, spool (lease held here by c-002)
fresh() {
  rm -rf "$B" "$T/wt" "$O" "$SP" && mkdir -p "$T/wt" "$SP/dispatch" "$SP/c-002/archive" "$SP/c-901/lifetime/push-master" "$SP/g-901/lifetime"
  git "${G[@]}" init -q --bare "$B"
  git "${G[@]}" clone -q "$B" "$L" 2>/dev/null
  seq 1 12 >"$L/f.txt"
  git -C "$L" add f.txt && git -C "$L" "${G[@]}" commit -qm base && git -C "$L" push -q origin HEAD:master
  git -C "$L" switch -q -c c-901-b5test
  git "${G[@]}" clone -q "$B" "$O"
  for r in "$L" "$O"; do git -C "$r" config user.name lane; git -C "$r" config user.email "$EM"; git -C "$r" config core.hooksPath "$T/nohooks"; done
  printf 'c-002@boxa %s\n' "$(date +%s)" >"$SP/dispatch/lease"
  printf 'LEASE_ORCH=c-001\nLEASE_MACHINE=boxa\n' >"$SP/dispatch/lease.conf"
  printf 'c-901\tclaude\t%%1\t%s\t20261028T000000Z\ng-901\tgrok\t%%2\t%s/g\t20261028T000000Z\n' "$L" "$T" >"$SP/registry.tsv"
  printf '%s\n' "$GREEN" >"$T/gh.runs"; : >"$T/gh.succ"; : >"$T/sends.log"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash spl-x.tst.sh"}}]}}' >"$T/journal.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git log -1"}}]}}' >"$T/journal-empty.jsonl"
}
# lc <line no> <text> <subject>: the lane edits one line of f.txt and commits
lc() { sed -i "$1s/.*/$2/" "$L/f.txt"; git -C "$L" add f.txt && git -C "$L" "${G[@]}" commit -qm "$3"; }
# other <line no> <text>: another lane moves master (the lane's rebase makes new shas)
other() { sed -i "$1s/.*/$2/" "$O/f.txt"; git -C "$O" add f.txt && git -C "$O" "${G[@]}" commit -qm "other lane" && git -C "$O" pull -q --rebase origin master && git -C "$O" push -q origin HEAD:master; }
# review <msg id> [journal] [row sha]: the review of the lane's HEAD: review/b5test
# on origin, the reviewer's message in the holder's archive, the brief, a PASS row
review() {
  local msg="$1" j="${2:-$T/journal.jsonl}" sha
  sha="$(git -C "$L" rev-parse HEAD)"; RSHA="$sha"
  git -C "$L" push -q origin HEAD:refs/heads/review/b5test
  python3 -c 'import json,sys; print(json.dumps({"v":1,"msg_id":sys.argv[1],"task_id":sys.argv[2],"from":"g-901","to":"c-002","kind":"result","ts":"2026-10-28T12:00:00Z",
    "body":"review done\nreview: g-901@boxa grok PASS "+sys.argv[3]+" ran: bash spl-x.tst.sh | read: 1 PASS | log: g-901@boxa:"+sys.argv[4]}))' \
    "$msg" "$TASK" "$sha" "$j" >"$SP/c-002/archive/20261028T120000Z--g-901--${msg:0:8}.json"
  printf '| author | task | sha |\n|---|---|---|\n| c-901@boxa (claude) | %s | %s |\n' "$TASK" "${sha:0:12}" >"$SP/g-901/lifetime/brief.md"
  printf 'PASS %s %s %s c-901 g-901 %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" "$TASK" "${3:-$sha}" >>"$LOG"
}
# push: a REAL do_spl_push_master of the lane, polled to its verdict
push() {
  local out
  SNIPPET='do_spl_push_master' in_orc PUSH_WORKTREE="$L" PUSH_STATE_DIR="$SP/c-901/lifetime/push-master" FETCH_FRESH_MAX_AGE=0 SPOOL_ROOT="$SP" >/dev/null 2>&1
  for _ in $(seq 1 60); do
    out="$(SNIPPET='do_spl_push_master' in_orc PUSH_CMD=status PUSH_WORKTREE="$L" PUSH_STATE_DIR="$SP/c-901/lifetime/push-master" SPOOL_ROOT="$SP" 2>&1)"
    [[ "$out" == PUSHED* ]] && return 0
    [[ "$out" == RUNNING* ]] || { echo "push: $out"; return 1; }
    sleep 0.5
  done
  echo "push: TIMEOUT $out"; return 1
}
# acc [VAR=value]...: the action in a fresh bash; output in $T/out, rc returned
acc() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$SP" ACCEPT_SEND="$T/send.sh" SEND_LOG="$T/sends.log" \
    ACCEPT_GH="$T/gh" GH_DIR="$T" REVIEW_LINE_BOX=boxa FETCH_FRESH_MAX_AGE=0 DRY_RUN=0 ACCEPT_AUTHOR=c-901 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$0" || { echo "FATAL cannot source $0"; exit 97; }
    do_check_lane_served() { echo "SERVED $BASE..$SHA" >>"$SEND_LOG.served"; echo "PASS dev=n/a prd=n/a"; return "${SERVED_RC:-0}"; }
    _spl_review_go_row() { local a; a="$(grep -F "${2:0:12}" "$1" | grep -oE "[acgmq]-[0-9]{3}" | sed -n 1p)"; [[ -n "$a" ]] && printf "%s\tboxa\tb\t%s\n" "$a" "$3"; }
    do_spl_accepted_close' "$FUNC" >"$T/out" 2>&1
}
# the ACCEPTED results sent (an audit or refusal note quotes the word too)
accepted() { grep -c -- '--kind result .*--body ACCEPTED' "$T/sends.log" 2>/dev/null; }
# red <n> <label> <want rc> <rc>: a red control's verdict: that rc, no ACCEPTED sent
red() {
  if (( $4 == $3 )) && [[ "$(accepted)" == 0 ]] && grep -q '^REFUSED: ' "$T/out"; then
    pass "$1. RED CONTROL $2 -> rc $3, no ACCEPTED: $(grep -m 1 '^REFUSED: ' "$T/out")"
  else fail "$1. $2: rc=$4 (want $3) sends=$(cat "$T/sends.log") out=$(tail -4 "$T/out")"; fi
}
M1=11111111-0000-4000-8000-000000000001 M2=22222222-0000-4000-8000-000000000002

# --- 1. RED CONTROL: an empty commit -------------------------------------------------------
fresh
git -C "$L" "${G[@]}" commit -q --allow-empty -m "feat(orc, SPL-1): empty"
review "$M1"; push || fail "1. push"
acc; red 1 "an empty reviewed + landed commit" 1 $?
grep -q " accepted-close $M1 action=refused rc=1 " "$LOG" && pass "1. the refusal is logged in automation.log" || fail "1. log: $(cat "$LOG")"

# --- 2. RED CONTROL: a partial landing ------------------------------------------------------
fresh
lc 3 alpha "feat(orc, SPL-1): alpha"; lc 9 beta "feat(orc, SPL-1): beta"
review "$M1"
git -C "$L" reset -q --hard HEAD~1
push || fail "2. push"
acc; red 2 "a 2-commit review with 1 commit landed" 2 $?

# --- 3. RED CONTROL: an unreviewed commit in push 1 of 2 real pushes --------------------------
fresh
lc 3 fixup "fix(orc, SPL-1): unreviewed fixup"
push || fail "3. push 1"
sleep 1; lc 9 reviewed "feat(orc, SPL-1): reviewed"; review "$M1"; sleep 1
push || fail "3. push 2"
[[ $(grep -cE '^20[0-9-]+T[0-9:]+Z [0-9a-f]{40}\.\.[0-9a-f]{40}$' "$SP/c-901/lifetime/push-master/pushes.log") == 2 ]] &&
  pass "3. do_spl_push_master appended both pushed ranges to pushes.log" || fail "3. pushes.log: $(cat "$SP/c-901/lifetime/push-master/pushes.log")"
acc; red 3 "an unreviewed fixup in push 1, the reviewed commit in push 2" 3 $?
grep -q 'unreviewed extra commit landed on master' "$T/out" && pass "3. it names the unreviewed extra commit" || fail "3. out: $(cat "$T/out")"

# --- 4. RED CONTROL: a forged PASS row ------------------------------------------------------
fresh
lc 3 alpha "feat(orc, SPL-1): alpha"
review "$M1" "$T/journal-empty.jsonl"; push || fail "4. push"
acc; red 4 "a PASS row whose reviewer journal never ran the test" 4 $?
fresh
lc 3 alpha "feat(orc, SPL-1): alpha"
review "$M1" "$T/journal.jsonl" "$(printf 'f%.0s' {1..40})"; push || fail "4b. push"
acc; red 4 "a PASS row whose sha is not the review message's" 4 $?

# --- 5. RED CONTROL: the rebase changed a code line ------------------------------------------
fresh
lc 6 alpha "feat(orc, SPL-1): alpha"
review "$M1"
sed -i '6s/.*/alpha-changed/' "$L/f.txt"; git -C "$L" add f.txt && git -C "$L" "${G[@]}" commit -q --amend --no-edit
push || fail "5. push"
acc; red 5 "the reviewed commit landed with a changed code line" 5 $?

# --- 6. RED CONTROL: no PASS row --------------------------------------------------------------
fresh
lc 3 alpha "feat(orc, SPL-1): alpha"; push || fail "6. push"
acc; red 6 "no PASS row in automation.log" 6 $?

# --- 7. RED CONTROL: CI red -------------------------------------------------------------------
fresh
lc 3 alpha "feat(orc, SPL-1): alpha"; review "$M1"; push || fail "7. push"
printf '%s\n' '[{"workflowName":"10 ci","status":"completed","conclusion":"failure"}]' >"$T/gh.runs"
acc; red 7 "a failed workflow" 7 $?
acc
[[ $(grep -c 'SEND .*--to c-002 --kind note' "$T/sends.log") == 1 && $(grep -c " accepted-close $M1 action=refused rc=7 " "$LOG") == 1 ]] &&
  pass "7. the holder is told once, not on every run" || fail "7. sends=$(cat "$T/sends.log")"

# --- 8. GREEN: a clean rebased landing --------------------------------------------------------
fresh
lc 6 alpha "feat(orc, SPL-1): alpha"; lc 10 beta "feat(orc, SPL-1): beta"
review "$M1"
other 4 other-lane
push || fail "8. push"
landed="$(git --git-dir="$B" rev-parse master)"
acc; rc=$?
want="SEND --from c-002 --to c-901 --kind result --task $TASK --body ACCEPTED (auto, spec 157 rule 2, automation.log $M1): on master $landed"
if (( rc == 0 )) && [[ "$(accepted)" == 1 ]] && grep -qxF "$want" "$T/sends.log" && [[ "$landed" != "$RSHA" ]]; then
  pass "8. GREEN: rc 0, the holder sends ACCEPTED (auto, spec 157 rule 2, automation.log <msg>): on master <landed> (rebased: $landed != reviewed $RSHA)"
else fail "8. rc=$rc sends=$(cat "$T/sends.log") out=$(tail -5 "$T/out")"; fi
grep -q -- "--from c-001 --to c-002 --kind note --task $TASK --body accepted-close audit (spec 157 rule 2): .* msg $M1, task $TASK, author c-901, reviewer g-901, reviewed $RSHA, landed $landed" "$T/sends.log" &&
  pass "8. the holder gets the audit note (msg, task, author, reviewer, both shas)" || fail "8. audit: $(cat "$T/sends.log")"
grep -qE "^20[0-9-]+T[0-9:]+Z accepted-close $M1 action=accepted actor=c-002 task=$TASK author=c-901 reviewer=g-901 reviewed=$RSHA landed=$landed ranges=[0-9a-f]{40}\.\.$landed send_rc=0 audit_rc=0$" "$LOG" &&
  pass "8. one accepted line in automation.log" || fail "8. log: $(cat "$LOG")"
acc
[[ "$(accepted)" == 1 ]] && pass "8. the next run sends nothing again" || fail "8. resent: $(cat "$T/sends.log")"

# --- 9. defers and the issue key --------------------------------------------------------------
fresh
lc 3 alpha "feat(orc, SPL-1): alpha"; review "$M1"; push || fail "9. push"
printf '%s\n' '[{"workflowName":"10 ci","status":"in_progress","conclusion":""}]' >"$T/gh.runs"
acc; rc=$?
(( rc == 8 )) && [[ "$(accepted)" == 0 && ! -s "$T/sends.log" ]] && grep -q 'DEFER .*CI not finished' "$T/out" && pass "9. CI running -> DEFER rc 8, nothing sent" || fail "9. running rc=$rc $(tail -3 "$T/out")"
printf '%s\n' "$GREEN" >"$T/gh.runs"
acc SERVED_RC=3; rc=$?
(( rc == 8 )) && [[ "$(accepted)" == 0 ]] && grep -q 'DEFER .*deploy lag' "$T/out" && pass "9. a lagging deploy -> DEFER rc 8" || fail "9. lag rc=$rc $(tail -3 "$T/out")"
printf '%s\n' '[{"workflowName":"10 ci","status":"completed","conclusion":"cancelled"}]' >"$T/gh.runs"
acc; rc=$?
(( rc == 8 )) && [[ "$(accepted)" == 0 ]] && pass "9. a cancelled run with no newer success -> DEFER rc 8" || fail "9. cancelled rc=$rc $(tail -3 "$T/out")"
other 11 later; git --git-dir="$B" rev-parse master >"$T/gh.succ"
acc; rc=$?
(( rc == 0 )) && [[ "$(accepted)" == 1 ]] && pass "9. a cancelled run superseded by a newer master success -> rc 0, ACCEPTED" || fail "9. superseded rc=$rc $(tail -3 "$T/out")"
fresh
lc 3 alpha "feat(orc): no key"; review "$M2"; push || fail "9b. push"
acc; red 9 "a landed commit without an issue key" 9 $?

# --- 10. the lease and the dry run ------------------------------------------------------------
fresh
lc 3 alpha "feat(orc, SPL-1): alpha"; review "$M1"; push || fail "10. push"
printf 'c-002@boxb %s\n' "$(date +%s)" >"$SP/dispatch/lease"
acc; rc=$?
(( rc == 0 )) && [[ ! -s "$T/sends.log" ]] && grep -q 'on another machine' "$T/out" && pass "10. the lease held on another machine -> rc 0, nothing judged" || fail "10. remote rc=$rc $(cat "$T/out")"
printf 'c-002@boxa %s\n' "$(( $(date +%s) - 999 ))" >"$SP/dispatch/lease"
acc; rc=$?
(( rc == 0 )) && [[ ! -s "$T/sends.log" ]] && grep -q 'no live dispatch lease holder' "$T/out" && pass "10. a stale lease -> rc 0, nothing judged" || fail "10. stale rc=$rc $(cat "$T/out")"
printf 'c-002@boxa %s\n' "$(date +%s)" >"$SP/dispatch/lease"
cp "$LOG" "$T/log.before"
acc DRY_RUN=1; rc=$?
(( rc == 0 )) && [[ ! -s "$T/sends.log" ]] && cmp -s "$LOG" "$T/log.before" && grep -q '^PLAN c-002 -> c-901 .*ACCEPTED (auto' "$T/out" &&
  pass "10. the dry run prints PLAN, sends and logs nothing" || fail "10. dry rc=$rc $(cat "$T/out")"

# --- 11. the install cron -----------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; mkdir -p "$SRC/csi-spl-orc"; printf '#!/bin/sh\n' >"$SRC/csi-spl-orc/run"; chmod +x "$SRC/csi-spl-orc/run"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n* * * * * x # csi-spl:accepted-close-not-this\n' >"$T/crontab"
cron() {
  # shellcheck disable=SC2016 # the script is single-quoted on purpose
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" \
    ACCEPT_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_accepted_close_install_cron' >"$T/o" 2>&1
}
before="$(md5sum <"$T/crontab")"
cron; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q 'do_spl_accepted_close >> .*/cron.out 2>&1 # csi-spl:accepted-close$' "$T/o" &&
  pass "11. dry run: the diff, nothing written" || fail "11. dry rc=$rc $(cat "$T/o")"
cron ACCEPT_CRON_ACTION=check && fail "11. check passed with no line" || pass "11. check fails while not installed"
cron DRY_RUN=0; rc=$?
# shellcheck disable=SC2016 # $HOME stays literal in the line
want="* * * * * cd $SRC/csi-spl-orc && PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin flock -n $T/log/accepted-close.cron.lock env DRY_RUN=0 ./run -a do_spl_accepted_close >> $T/log/cron.out 2>&1 # csi-spl:accepted-close"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" && grep -q 'accepted-close-not-this$' "$T/crontab" &&
  pass "11. DRY_RUN=0: one exact every-minute line, the other lines kept" || fail "11. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cp "$T/crontab" "$T/ct.1"; cron DRY_RUN=0
cmp -s "$T/crontab" "$T/ct.1" && [[ $(grep -c '# csi-spl:accepted-close$' "$T/crontab") == 1 ]] && pass "11. a second install changes nothing" || fail "11. idempotent: $(cat "$T/crontab")"
cron ACCEPT_CRON_ACTION=check && grep -q 'OK the accepted close is installed' "$T/o" && pass "11. check passes once installed" || fail "11. check: $(cat "$T/o")"
cron DRY_RUN=0 ACCEPT_CRON_ACTION=remove
! grep -q '# csi-spl:accepted-close$' "$T/crontab" && grep -q 'desk-reconcile$' "$T/crontab" && grep -q 'accepted-close-not-this$' "$T/crontab" &&
  pass "11. remove takes only its line" || fail "11. remove: $(cat "$T/crontab")"
cron ACCEPT_CRON_ACTION=bogus; rc=$?
(( rc == 1 )) && grep -q 'FATAL ACCEPT_CRON_ACTION' "$T/o" && pass "11. a bad action is refused" || fail "11. bad action rc=$rc"

echo "spl-accepted-close: ${fails} failure(s)"
[ "$fails" -eq 0 ]
