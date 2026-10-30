#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_push_master (SPL-1578) on a temp bare origin, the pre-push
# hook stubbed by a script whose mode a file selects.
#   1. a clean push -> PUSHED <sha>, landed_rc=0, tries=1
#   2. start returns within seconds while the hook sleeps; status says
#      RUNNING (exit 3) meanwhile, then PUSHED
#   3. a race: origin moves while the hook runs -> rebase + retry -> PUSHED,
#      both commits on origin; control: the same race with PUSH_RETRIES=1
#      -> GAVE-UP (the retry is what lands it)
#   4. a red hook -> REFUSED with the hook's tail, origin unchanged
#   5. SPL_PREPUSH_OVERRIDE=1 in the caller's env never reaches the hook
#   6. refusals at start: a dirty tracked tree; a wrong committer identity is
#      refused by the worker before any push
#   7. AGENT_ID in the caller's env never reaches the hook (SPL-1583): a hook
#      that fails when it is set -> PUSHED; control: the same hook fails when
#      AGENT_ID is exported to it
#   8. the R7 review-line gate (round 10 row 10, round 11 row 04): a
#      `refactor(r99-01-x)` commit whose review line is missing, has a 39-char
#      sha, a 40-char sha that does not resolve, or no `| log:` -> REFUSED round
#      row <sha> review line: <reason>, not on origin; the full line, its sha
#      only on origin's review/r99-01 (fetched) -> PUSHED; a `chore(r99-01-x)`
#      and a `docs(...)` commit with no line -> PUSHED. The gate agrees with
#      the retro checker (SPL-4066): a `ran:` that names its tests only as a
#      brace token `check-pre-push-{a,b}.tst.sh` plus a `$t` loop (c-585's
#      r36-02 line) -> REFUSED `checker: ran: names no test ...`, and
#      do_spl_review_line_check REVIEW_LINE_SYNTAX=1 refuses it too (exit 1)
#      while it passes the line the gate lands (exit 0)
#   9. the lane closes while its push runs (m-595, SPL-2264): the hook moves
#      the state dir away as agent-id-retire does, then is red -> the moved dir
#      reads REFUSED, not RUNNING; the same with a green hook -> PUSHED there.
#      The hook waits 2 s before its mv, so the poll runs first: a status read
#      mkdir -p's its state dir, and a poll of the target before the mv nested
#      the moved dir inside it (TIMEOUT, CI run 39896056302)
#  10. AGENT_ID names a lane, the tree is not its worktree (m-181, SPL-2312):
#      the main checkout, another lane's worktree, PUSH_WORKTREE at the main
#      checkout, and an id with no worktree at all -> exit 1, a FATAL naming
#      both paths and `cd <worktree>/csi-spl-orc`, no status file; control:
#      the same start from the lane's own worktree is not refused (case 7)
#  11. the lane's own worktree, 0 commits ahead of origin -> NOTHING-TO-PUSH
#      <sha>, status exit 5, never PUSHED / landed_rc
#  12. HEAD moves after the sha is logged (c-462, SPL-2574): a `git` wrapper
#      switches the tree to origin's head right before the push -> the logged
#      sha itself is pushed: PUSHED <sha>, on origin, the log says `HEAD moved
#      during the push`; a push that exits 0 but lands nothing -> GAVE-UP
#      naming the sha, never PUSHED
#  13. origin's URL carries embedded credentials (2026-10-26: an empty token
#      in `https://x-access-token:@github.com/...` broke every push of a box):
#      `https://x-access-token:@...`, `https://user:tok@...`, a bare-user
#      `https://user@...` and the same in pushurl -> start exits 1, names the
#      repo, says `origin URL carries embedded credentials`, never prints the
#      userinfo, prints `git -C <repo> remote set-url origin <url without
#      userinfo>` (`--push` for a pushurl), no status file, nothing pushed,
#      the URL not rewritten;
#      control: `git@github.com:x/y.git` and `ssh://git@github.com/x/y.git`
#      push. url.<temp origin>.insteadOf maps each URL onto the temp origin:
#      no network, and without the guard the creds URL lands (the red)
#  14. PUSH_BRANCH names a branch that is not on origin yet (the first push of
#      a review/ ref, c-954 msg 3d6597dd, SPL-4317): origin master moved first
#      -> the worker fetches master, rebases onto origin/master and pushes the
#      new ref with no force: PUSHED <sha>, tries=1, the sha on the new ref with
#      origin master below it, master itself unchanged; the red before the fix
#      was `GAVE-UP the fetch of origin/<branch> failed`. Then a second commit
#      to the same, now existing, branch -> PUSHED on today's path
#  15. the new-branch check asks for the exact ref (SPL-4378, R7 c-662 W1-W3):
#      origin holds only `other/<branch>` -> <branch> still counts as new:
#      PUSHED on a created ref, master unchanged (the red: `ls-remote --heads
#      origin <branch>` matched the suffix, GAVE-UP); an unreachable origin
#      (ls-remote rc 128, not 2) -> no switch to master, `GAVE-UP the fetch of
#      origin/<branch> failed` (not origin/master); a new branch whose
#      fetch of master fails (a stub PUSH_FETCH_SCRIPT) -> the GAVE-UP names
#      origin/master, the ref actually fetched (the red named origin/<branch>)
#  16. the worker's stderr reaches <state>/log (SPL-4437): a fetch stub's line
#      on fd 2 is in the log, and case 14's first push logs `<branch> is not on
#      origin yet`, so its second push's `! grep` checks something; the red:
#      the fd-closing loop's `2>/dev/null` left the worker's fd 2 on /dev/null
#  17. no PUSH_* knob in the caller's env (BRANCH, REMOTE, RETRIES, GIT_EMAIL;
#      run adds WORKTREE, STATE_DIR) reaches the hook (SPL-4437): a hook that
#      fails when one is set -> PUSHED
#      on review/c-999-s17; the red: a review/ push sent the orc tests the hook
#      runs to review/<x> on their temp origins (12 FAILs)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
# A lane running this suite exports its own AGENT_ID: cases 1-9 run with none.
# Nor a caller's PUSH_* knobs: each case names the ones it wants (case 17).
unset AGENT_ID PUSH_REMOTE PUSH_BRANCH PUSH_RETRIES PUSH_CMD PUSH_WORKTREE PUSH_STATE_DIR \
  PUSH_GIT_NAME PUSH_GIT_EMAIL PUSH_FETCH_SCRIPT

B="$T/origin.git" L="$T/lane" O="$T/other" S="$T/state"
EM=lane@example.com
G=(-c user.name=lane -c "user.email=$EM" -c init.defaultBranch=master -c advice.detachedHead=false)
git "${G[@]}" init -q --bare "$B"
git "${G[@]}" clone -q "$B" "$L" 2>/dev/null
printf 'base\n' >"$L/base.txt"
git -C "$L" add base.txt && git -C "$L" "${G[@]}" commit -qm base && git -C "$L" push -q origin HEAD:master
git -C "$L" switch -q -c lane-branch
git "${G[@]}" clone -q "$B" "$O"
# Their own identity: a runner has no global one, and the hook's pull --rebase
# in the other clone needs a committer (CI red e3145e1d3, run 38330391482).
for r in "$L" "$O"; do git -C "$r" config user.name lane; git -C "$r" config user.email "$EM"; done
mkdir -p "$T/hooks"
# The stub hook: $T/hook.mode = ok | sleep | race | red | race-always.
cat >"$T/hooks/pre-push" <<EOF
#!/bin/bash
echo "override=\${SPL_PREPUSH_OVERRIDE:-unset}" >>"$T/hook.calls"
echo "agent=\${AGENT_ID:-unset}" >>"$T/hook.calls"
mode="\$(cat "$T/hook.mode" 2>/dev/null || echo ok)"
case "\$mode" in
  sleep) sleep 6 ;;
  race|race-always)
    [ "\$mode" = race ] && echo ok >"$T/hook.mode"
    n=\$(date +%s%N)
    echo "\$n" >"$O/o-\$n.txt"
    git -C "$O" add "o-\$n.txt" && git -C "$O" ${G[*]} commit -qm "other \$n" && git -C "$O" pull -q --rebase origin master 2>/dev/null
    git -C "$O" push -q origin HEAD:master || { echo "STUB: the other push failed"; exit 1; } ;;
  red) echo "deploy-gate FAILED: lint-shellcheck GATE-RED-MARKER"; exit 1 ;;
  retire-red|retire-ok)
    sleep 2; mv "$S" "\$(cat "$T/retire.to")"
    [ "\$mode" = retire-red ] && { echo "deploy-gate FAILED: RETIRE-RED-MARKER"; exit 1; } ;;
  agent-red) [ -n "\${AGENT_ID:-}" ] && { echo "STUB: AGENT_ID=\$AGENT_ID reached the hook"; exit 1; } ;;
  knob-red) env | grep -E '^PUSH_(REMOTE|BRANCH|RETRIES|CMD|WORKTREE|STATE_DIR|GIT_NAME|GIT_EMAIL|FETCH_SCRIPT)=' && { echo "STUB: a PUSH_* knob reached the hook"; exit 1; } ;;
esac
exit 0
EOF
chmod +x "$T/hooks/pre-push"
git -C "$L" config core.hooksPath "$T/hooks"

commit() { printf '%s\n' "$1" >"$L/$1.txt"; git -C "$L" add "$1.txt" && git -C "$L" "${G[@]}" commit -qm "$1"; }
# SPOOL_ROOT: the checker's registry lookup (case 8) reads a temp one, never the box's.
run() { SNIPPET='do_spl_push_master' in_orc PUSH_WORKTREE="$L" PUSH_STATE_DIR="$S" FETCH_FRESH_MAX_AGE=0 SPOOL_ROOT="$T/spool" "$@" 2>&1; }
# verdict - polls status (each call short) until it is not RUNNING; prints it.
verdict() {
  local out rc
  for _ in $(seq 1 60); do
    out="$(run PUSH_CMD=status)"; rc=$?
    [ "$rc" -ne 3 ] && { printf '%s\n' "$out"; return "$rc"; }
    sleep 0.5
  done
  printf 'TIMEOUT\n%s\n' "$out"; return 9
}
on_origin() { git --git-dir="$B" merge-base --is-ancestor "$1" master 2>/dev/null; }

# 1
echo ok >"$T/hook.mode"; commit one
out="$(run)"; rc=$?
v="$(verdict)"; vrc=$?
sha="$(git -C "$L" rev-parse HEAD)"
[ "$rc" -eq 0 ] && [ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && grep -qx 'landed_rc=0' <<<"$v" && grep -qx 'tries=1' <<<"$v" && on_origin "$sha" \
  && pass "1. a clean push -> PUSHED <sha>, landed_rc=0, tries=1" || fail "1. clean push (rc $rc/$vrc: $out | $v)"

# 2
echo sleep >"$T/hook.mode"; commit two
t0=$(date +%s); out="$(run)"; rc=$?; dt=$(( $(date +%s) - t0 ))
mid="$(run PUSH_CMD=status)"; mrc=$?
[ "$rc" -eq 0 ] && [ "$dt" -le 3 ] && pass "2. start returned in ${dt} s while the hook sleeps 6 s" || fail "2. start took ${dt} s (rc $rc: $out)"
[ "$mrc" -eq 3 ] && grep -qx RUNNING <<<"$mid" && pass "2. status meanwhile: RUNNING, exit 3" || fail "2. mid status (rc $mrc: $mid)"
out="$(run)"; rc=$?
[ "$rc" -eq 3 ] && grep -q 'already running' <<<"$out" && pass "2. a second start while one runs -> exit 3, no second worker" || fail "2. second start (rc $rc: $out)"
v="$(verdict)"; vrc=$?
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $(git -C "$L" rev-parse HEAD)" <<<"$v" && pass "2. then PUSHED" || fail "2. verdict (rc $vrc: $v)"

# 3 control first: a race on every try with one try allowed -> GAVE-UP
echo race-always >"$T/hook.mode"; commit three-c
run PUSH_RETRIES=1 >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 1 ] && grep -q '^GAVE-UP .*moved during each of 1 pushes' <<<"$v" && ! on_origin "$(git -C "$L" rev-parse HEAD)" \
  && pass "3. control: the race with PUSH_RETRIES=1 -> GAVE-UP, not on origin" || fail "3. control (rc $vrc: $v)"
echo race >"$T/hook.mode"; commit three
run >/dev/null; v="$(verdict)"; vrc=$?
sha="$(git -C "$L" rev-parse HEAD)"
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && grep -qx 'tries=2' <<<"$v" && on_origin "$sha" \
  && [ "$(git --git-dir="$B" log --format=%s master | grep -c '^other ')" -ge 2 ] \
  && pass "3. a race: origin moved during the hook -> rebase + retry -> PUSHED on try 2, the other commits kept" \
  || fail "3. race (rc $vrc: $v | log: $(tail -n 8 "$S/log"))"

# 4
echo red >"$T/hook.mode"; commit four; before="$(git --git-dir="$B" rev-parse master)"
run >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 1 ] && grep -q '^REFUSED push of ' <<<"$v" && grep -q 'GATE-RED-MARKER' <<<"$v" && [ "$(git --git-dir="$B" rev-parse master)" = "$before" ] \
  && pass "4. a red hook -> REFUSED with the hook's tail, origin unchanged" || fail "4. red hook (rc $vrc: $v)"

# 5
echo ok >"$T/hook.mode"; : >"$T/hook.calls"
run SPL_PREPUSH_OVERRIDE=1 >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 0 ] && grep -qx 'override=unset' "$T/hook.calls" && ! grep -q 'override=1' "$T/hook.calls" \
  && pass "5. SPL_PREPUSH_OVERRIDE=1 in the caller's env never reaches the hook" || fail "5. override ($(cat "$T/hook.calls") | $v)"

# 6
printf 'dirty\n' >>"$L/base.txt"
out="$(run)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'uncommitted tracked changes' <<<"$out" && pass "6. a dirty tracked tree is refused at start" || fail "6. dirty (rc $rc: $out)"
git -C "$L" checkout -q -- base.txt
commit six; git -C "$L" -c user.name=x -c user.email=wrong@example.com commit -q --amend --no-edit --reset-author
run PUSH_GIT_EMAIL=$EM >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 1 ] && grep -q '^REFUSED WRONG-IDENTITY-DO-NOT-PUSH' <<<"$v" && ! on_origin "$(git -C "$L" rev-parse HEAD)" \
  && pass "6. a wrong identity -> REFUSED before any push" || fail "6. identity (rc $vrc: $v)"

# 7 control first: the stub is red when AGENT_ID reaches it. A lane id pushes
# from its own worktree (case 10): c-999's is a linked worktree named c-999.
git -C "$L" -c user.name=lane -c "user.email=$EM" commit -q --amend --no-edit --reset-author
W7="$T/lane-wt/c-999"
git -C "$L" worktree add -q -b c-999-t7 "$W7" HEAD 2>/dev/null
echo agent-red >"$T/hook.mode"; : >"$T/hook.calls"
out="$(AGENT_ID=c-999 "$T/hooks/pre-push" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'AGENT_ID=c-999 reached' <<<"$out" \
  && pass "7. control: the agent-red stub fails when AGENT_ID reaches it" || fail "7. control (rc $rc: $out)"
: >"$T/hook.calls"
run AGENT_ID=c-999 PUSH_WORKTREE="$W7" >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $(git -C "$W7" rev-parse HEAD)" <<<"$v" && grep -qx 'agent=unset' "$T/hook.calls" \
  && pass "7. AGENT_ID=c-999 in the caller's env never reaches the hook -> PUSHED" || fail "7. AGENT_ID ($(cat "$T/hook.calls") | $v)"

# 8 red controls first: a round row whose review line is void is refused
echo ok >"$T/hook.mode"
rcommit() { printf '%s\n' "$1" >"$L/$1.txt"; git -C "$L" add "$1.txt" && git -C "$L" "${G[@]}" commit -qm "$2" ${3:+-m "$3"}; }
# The reviewed sha lives only on origin's review/r99-01: the gate must fetch it.
git -C "$O" switch -q -c review-r99 && commit_o() { printf 'r\n' >"$O/rev.txt"; git -C "$O" add rev.txt && git -C "$O" "${G[@]}" commit -qm reviewed; }
commit_o && git -C "$O" push -q origin HEAD:refs/heads/review/r99-01 && RS="$(git -C "$O" rev-parse HEAD)"; git -C "$O" switch -q master
TAIL='ran: bash spl-push-master.tst.sh | read: diff | log: m-999@sat:/x/journal.jsonl'
BRACE="ran: bash check-pre-push-{a,b}.tst.sh; for t in x; do bash \$t; done | read: diff | log: m-999@sat:/x/journal.jsonl"
red8() {
  git -C "$L" "${G[@]}" commit -q --amend -m 'refactor(r99-01-x): a round row' -m "$2"
  run >/dev/null; v="$(verdict)"; vrc=$?
  short="$(git -C "$L" rev-parse --short HEAD)"
  [ "$vrc" -eq 1 ] && grep -qxF "REFUSED round row $short review line: $3" <<<"$v" && ! on_origin "$(git -C "$L" rev-parse HEAD)" \
    && pass "8. red control: $1 -> REFUSED round row $short review line: $3" || fail "8. red control $1 (rc $vrc: $v)"
}
rcommit eight 'refactor(r99-01-x): a round row'
red8 'no PASS line' 'review: m-999 mistral FAIL 0123456 no box, no PASS' "none of the form 'review: <id>@<box> <vendor> PASS <sha> ...'"
red8 'a 39-char sha' "review: m-999@sat mistral PASS ${RS:0:39} $TAIL" "sha '${RS:0:39}' is not 40 hex"
red8 'an unresolvable 40-char sha' "review: m-999@sat mistral PASS $(printf 'f%.0s' $(seq 40)) $TAIL" "sha $(printf 'f%.0s' $(seq 40)) does not resolve (fetched review/r99-01)"
red8 'no log:' "review: m-999@sat mistral PASS $RS ran: tests | read: diff" "no '| log: <id>@<box>:<path>'"
red8 'a brace-token ran: (c-585, SPL-4066)' "review: m-999@sat mistral PASS $RS $BRACE" \
  'checker: ran: names no test (*.tst.sh, *.test.mjs, *_test.go, go test, pnpm run)'
# The checker itself, on the same two lines: the gate refuses what it refuses.
chk8() { SNIPPET='do_spl_review_line_check' in_orc REVIEW_LINE="review: m-999@sat mistral PASS $RS $1" REVIEW_LINE_SYNTAX=1 \
  REVIEW_LINE_BOX=other REVIEW_LINE_REPO="$L" SPOOL_ROOT="$T/spool" 2>&1; }
out="$(chk8 "$BRACE")"; rc=$?
[ "$rc" -eq 1 ] && grep -q '^SYNTAX FAIL ran: names no test' <<<"$out" \
  && pass "8. the checker (REVIEW_LINE_SYNTAX=1) refuses the brace-token line too" || fail "8. checker brace (rc $rc: $out)"
out="$(chk8 "$TAIL")"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^SYNTAX OK' <<<"$out" \
  && pass "8. the checker passes the line the gate lands" || fail "8. checker full line (rc $rc: $out)"
git -C "$L" "${G[@]}" commit -q --amend -m 'refactor(r99-01-x): a round row' -m "review: m-999@sat mistral PASS $RS $TAIL"
run >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $(git -C "$L" rev-parse HEAD)" <<<"$v" \
  && pass "8. the same row with the full line, its sha fetched from review/r99-01 -> PUSHED" || fail "8. with line (rc $vrc: $v)"
rcommit eight-c 'chore(r99-01-x): not a round row type'
rcommit eight-d 'docs(doc): not a round row'
run >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $(git -C "$L" rev-parse HEAD)" <<<"$v" \
  && pass "8. a chore(r99-01-x) and a docs(...) commit with no line -> PUSHED" || fail "8. chore/docs (rc $vrc: $v)"

# 9 the state dir moves while the hook runs
retire9() {
  local mode="$1" to="$T/retired-$1/lifetime/push-master"
  mkdir -p "${to%/*}"; echo "$to" >"$T/retire.to"; echo "$mode" >"$T/hook.mode"; mkdir -p "$S"
  commit "nine-$mode"; sha="$(git -C "$L" rev-parse HEAD)"
  run >/dev/null; v="$(verdict_in "$to")"; vrc=$?
}
# verdict_in <dir> - verdict() for the dir the hook moves the state to. It
# reads status only once <dir>/status exists: the status read creates <dir>,
# and the hook's mv would then nest the state dir inside it.
verdict_in() {
  local out="no status file in $1" rc
  for _ in $(seq 1 60); do
    if [ -f "$1/status" ]; then
      out="$(SNIPPET='do_spl_push_master' in_orc PUSH_WORKTREE="$L" PUSH_STATE_DIR="$1" PUSH_CMD=status 2>&1)"; rc=$?
      [ "$rc" -ne 3 ] && { printf '%s\n' "$out"; return "$rc"; }
    fi
    sleep 0.5
  done
  printf 'TIMEOUT\n%s\n' "$out"; return 9
}
retire9 retire-red
[ "$vrc" -eq 1 ] && grep -q "^REFUSED push of $sha" <<<"$v" && grep -q 'RETIRE-RED-MARKER' <<<"$v" && [ ! -e "$S" ] \
  && grep -q 'the state dir moved' "$T/retired-retire-red/lifetime/push-master/log" \
  && pass "9. the lane's dir moved away during a red push -> REFUSED written where it is now, not RUNNING" || fail "9. retire red (rc $vrc: $v)"
retire9 retire-ok
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && on_origin "$sha" && [ ! -e "$T/retired-retire-ok/lifetime/push-master/${S##*/}" ] \
  && pass "9. ...and a green push from a moved dir -> PUSHED written there, not nested" || fail "9. retire ok (rc $vrc: $v)"

# 10 a lane id outside its own worktree is refused at start, nothing written
W10="$T/lane-wt/c-998"
git -C "$L" worktree add -q -b c-998-t10 "$W10" HEAD 2>/dev/null
echo ok >"$T/hook.mode"; before="$(git --git-dir="$B" rev-parse master)"
refuse10() {
  local s10="$T/state10-$1" out rc
  out="$(SNIPPET='do_spl_push_master' in_orc PUSH_STATE_DIR="$s10" FETCH_FRESH_MAX_AGE=0 AGENT_ID="$2" PUSH_WORKTREE="$3" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && grep -qF "FATAL PUSH: AGENT_ID=$2 pushes only from its own worktree $4, not from $3. Fix: cd $4/csi-spl-orc" <<<"$out" \
    && [ ! -e "$s10/status" ] && [ "$(git --git-dir="$B" rev-parse master)" = "$before" ] \
    && pass "10. $1 -> exit 1, FATAL names $4 and $3, no status file" || fail "10. $1 (rc $rc: $out)"
}
refuse10 'the main checkout' c-999 "$L" "$W7"
refuse10 "another lane's worktree" c-999 "$W10" "$W7"
refuse10 'an id with no worktree' c-997 "$L" "$L-wt/c-997"
out="$(cd "$L" && SNIPPET='do_spl_push_master' in_orc PUSH_STATE_DIR="$T/state10-pwd" AGENT_ID=c-999 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -qF "not from $L." <<<"$out" && pass "10. no PUSH_WORKTREE, cwd the main checkout -> refused" || fail "10. cwd (rc $rc: $out)"

# 11 the lane's own worktree, nothing ahead of origin: never PUSHED
run AGENT_ID=c-999 PUSH_WORKTREE="$W7" >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 5 ] && grep -qx "NOTHING-TO-PUSH $(git -C "$W7" rev-parse HEAD)" <<<"$v" && ! grep -qE '^PUSHED|landed_rc' <<<"$v" \
  && pass "11. own worktree, 0 commits ahead -> NOTHING-TO-PUSH, exit 5, not PUSHED" || fail "11. nothing ahead (rc $vrc: $v)"

# 12 HEAD moves between the logged sha and the push: a git wrapper on PATH
# runs before the real git's push (switch: the tree goes to origin's head, as
# a lane rotation did; noop: the push prints up-to-date and pushes nothing).
REAL_GIT="$(command -v git)"; mkdir -p "$T/gitwrap"
cat >"$T/gitwrap/git" <<EOF
#!/bin/bash
if [ "\$1" = push ]; then
  case "\$(cat "$T/git.mode" 2>/dev/null)" in
    switch) "$REAL_GIT" checkout -q -B "moved-\$\$" origin/master ;;
    noop) echo "Everything up-to-date"; exit 0 ;;
  esac
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/gitwrap/git"
echo ok >"$T/hook.mode"; echo switch >"$T/git.mode"
commit twelve; sha="$(git -C "$L" rev-parse HEAD)"
run PATH="$T/gitwrap:$PATH" >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && on_origin "$sha" && grep -q "HEAD moved during the push: $sha -> " "$S/log" \
  && pass "12. HEAD switched to origin's head before the push -> the logged sha is pushed and on origin, the log says HEAD moved" \
  || fail "12. switch (rc $vrc: $v | on origin: $(on_origin "$sha" && echo yes || echo no) | log: $(tail -n 6 "$S/log"))"
git -C "$L" switch -q lane-branch; echo noop >"$T/git.mode"
commit twelve-b; sha="$(git -C "$L" rev-parse HEAD)"
run PATH="$T/gitwrap:$PATH" >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 1 ] && grep -q "^GAVE-UP .*$sha is not on origin/master" <<<"$v" && ! on_origin "$sha" \
  && pass "12. a push that exits 0 but lands nothing -> GAVE-UP naming the sha, not PUSHED" || fail "12. noop (rc $vrc: $v)"

# 13 an origin URL with embedded credentials is refused at start, never rewritten
git -C "$L" switch -q lane-branch 2>/dev/null; rm -f "$T/git.mode"; echo ok >"$T/hook.mode"
creds13() {
  local url="$1" clean="$2" secret="$3" key="${4:-url}" s13="$T/state13-$RANDOM" out rc before c
  git -C "$L" config "url.$B.insteadOf" "$url"
  git -C "$L" config "remote.origin.$key" "$url"
  commit "thirteen-$RANDOM"; c="$(git -C "$L" rev-parse HEAD)"; before="$(git --git-dir="$B" rev-parse master)"
  out="$(SNIPPET='do_spl_push_master' in_orc PUSH_WORKTREE="$L" PUSH_STATE_DIR="$s13" FETCH_FRESH_MAX_AGE=0 GIT_TERMINAL_PROMPT=0 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then S="$s13" verdict >/dev/null; fi
  [ "$rc" -eq 1 ] && grep -qF "FATAL PUSH: $L: origin URL carries embedded credentials" <<<"$out" \
    && grep -qxF "  git -C $L remote set-url $([ "$key" = pushurl ] && echo "--push ")origin $clean" <<<"$out" && ! grep -qF -- "$secret" <<<"$out" \
    && [ ! -e "$s13/status" ] && [ "$(git --git-dir="$B" rev-parse master)" = "$before" ] && ! on_origin "$c" \
    && [ "$(git -C "$L" config --get "remote.origin.$key")" = "$url" ] \
    && pass "13. origin $key $5 -> exit 1, names the repo and the set-url fix, token masked, nothing pushed, URL kept" \
    || fail "13. $key $5 (rc $rc: $out | on origin: $(on_origin "$c" && echo yes || echo no))"
  git -C "$L" config --unset "url.$B.insteadOf"
  if [ "$key" = url ]; then git -C "$L" remote set-url origin "$B"; else git -C "$L" config --unset remote.origin.pushurl; fi
  git -C "$L" reset -q --hard "$(git --git-dir="$B" rev-parse master)"
}
creds13 'https://x-access-token:@github.com/x/y.git' 'https://github.com/x/y.git' 'x-access-token' url 'https://x-access-token:@... (empty token)'
creds13 'https://user:tok-SECRET13@github.com/x/y.git' 'https://github.com/x/y.git' 'tok-SECRET13' url 'https://user:tok@...'
creds13 'https://user13@github.com/x/y.git' 'https://github.com/x/y.git' 'user13' url 'https://user@... (no password)'
creds13 'https://user:tok-SECRET13@github.com/x/y.git' 'https://github.com/x/y.git' 'tok-SECRET13' pushurl 'https://user:tok@...'
ssh13() {
  local url="$1" out rc c
  git -C "$L" config "url.$B.insteadOf" "$url"; git -C "$L" remote set-url origin "$url"
  commit "thirteen-ssh-$RANDOM"; c="$(git -C "$L" rev-parse HEAD)"
  out="$(run GIT_TERMINAL_PROMPT=0)"; rc=$?; v="$(verdict)"; vrc=$?
  [ "$rc" -eq 0 ] && [ "$vrc" -eq 0 ] && grep -qx "PUSHED $c" <<<"$v" && on_origin "$c" \
    && pass "13. control: origin $url (ssh, no credential) -> PUSHED" || fail "13. control $url (rc $rc/$vrc: $out | $v)"
  git -C "$L" config --unset "url.$B.insteadOf"; git -C "$L" remote set-url origin "$B"
}
ssh13 'git@github.com:x/y.git'
ssh13 'ssh://git@github.com/x/y.git'

# 14 a PUSH_BRANCH that is not on origin yet: fetch master, rebase onto it, push the new ref
NB=review/c-999-s14-new
echo ok >"$T/hook.mode"; git -C "$L" switch -q lane-branch
git -C "$O" switch -q master && git -C "$O" pull -q --rebase origin master 2>/dev/null
printf '14\n' >"$O/o-14.txt"; git -C "$O" add o-14.txt && git -C "$O" "${G[@]}" commit -qm 'other 14' && git -C "$O" push -q origin HEAD:master
m14="$(git --git-dir="$B" rev-parse master)"
commit fourteen
run PUSH_BRANCH="$NB" >/dev/null; v="$(verdict)"; vrc=$?
sha="$(git -C "$L" rev-parse HEAD)"
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && grep -qx 'tries=1' <<<"$v" \
  && [ "$(git --git-dir="$B" rev-parse "refs/heads/$NB" 2>/dev/null)" = "$sha" ] \
  && git --git-dir="$B" merge-base --is-ancestor "$m14" "$sha" && [ "$(git --git-dir="$B" rev-parse master)" = "$m14" ] \
  && grep -q "$NB is not on origin yet: rebase onto origin/master" "$S/log" \
  && pass "14. a PUSH_BRANCH not on origin -> rebased onto origin/master, the new ref pushed: PUSHED, master unchanged, the log says not on origin yet" \
  || fail "14. new branch (rc $vrc: $v | log: $(tail -n 6 "$S/log"))"
commit fourteen-b
run PUSH_BRANCH="$NB" >/dev/null; v="$(verdict)"; vrc=$?
sha="$(git -C "$L" rev-parse HEAD)"
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && [ "$(git --git-dir="$B" rev-parse "refs/heads/$NB")" = "$sha" ] \
  && ! grep -q "not on origin yet" "$S/log" && [ "$(git --git-dir="$B" rev-parse master)" = "$m14" ] \
  && pass "14. the same branch, now on origin -> today's path: PUSHED on it, master unchanged" \
  || fail "14. existing branch (rc $vrc: $v | log: $(tail -n 6 "$S/log"))"

# 15 the new-branch check asks for refs/heads/<branch>, not a suffix
NB=review/c-999-s15
git -C "$O" push -q origin "HEAD:refs/heads/other/$NB"
commit fifteen
run PUSH_BRANCH="$NB" >/dev/null; v="$(verdict)"; vrc=$?
sha="$(git -C "$L" rev-parse HEAD)"
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && [ "$(git --git-dir="$B" rev-parse "refs/heads/$NB" 2>/dev/null)" = "$sha" ] \
  && [ "$(git --git-dir="$B" rev-parse master)" = "$m14" ] \
  && pass "15. origin holds only other/$NB -> $NB counts as new: PUSHED on the created ref" \
  || fail "15. suffix ref (rc $vrc: $v | log: $(tail -n 6 "$S/log"))"
NB=review/c-999-s15-gone
git -C "$L" remote set-url origin "$T/gone.git"
commit fifteen-b
run PUSH_BRANCH="$NB" >/dev/null; v="$(verdict)"; vrc=$?
git -C "$L" remote set-url origin "$B"
[ "$vrc" -eq 1 ] && grep -qx "GAVE-UP the fetch of origin/$NB failed" <<<"$v" \
  && pass "15. an unreachable origin -> no switch to master, GAVE-UP names origin/$NB" \
  || fail "15. unreachable (rc $vrc: $v | log: $(tail -n 6 "$S/log"))"
NB=review/c-999-s15-nomaster
printf '#!/bin/bash\n[[ " $* " == *" --branch master "* ]] && { echo "STUB: master fetch failed"; exit 1; }\nexit 0\n' >"$T/fetch-stub.sh"
run PUSH_BRANCH="$NB" PUSH_FETCH_SCRIPT="$T/fetch-stub.sh" >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 1 ] && grep -qx "GAVE-UP the fetch of origin/master failed" <<<"$v" \
  && pass "15. a new branch whose master fetch fails -> GAVE-UP names origin/master, the ref fetched" \
  || fail "15. master fetch (rc $vrc: $v | log: $(tail -n 6 "$S/log"))"

# 16 the worker's stderr lands in <state>/log (SPL-4437)
printf '#!/bin/bash\necho "STDERR-MARKER-16 $$" >&2\nexec bash "%s" "$@"\n' \
  "$TEST_DIR/../features/spawn-agents/scripts/git-fetch-fresh.sh" >"$T/fetch-stderr.sh"
git -C "$L" switch -q lane-branch && git -C "$L" reset -q --hard "$(git --git-dir="$B" rev-parse master)"
commit sixteen
run PUSH_FETCH_SCRIPT="$T/fetch-stderr.sh" >/dev/null; v="$(verdict)"; vrc=$?
sha="$(git -C "$L" rev-parse HEAD)"
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && grep -q '^STDERR-MARKER-16 ' "$S/log" \
  && pass "16. the worker's stderr (a fetch stub's fd 2) lands in <state>/log" \
  || fail "16. worker stderr (rc $vrc: $v | log: $(tail -n 6 "$S/log"))"

# 17 the caller's PUSH_* knobs never reach the hook
echo knob-red >"$T/hook.mode"; commit seventeen
run PUSH_BRANCH=review/c-999-s17 PUSH_REMOTE=origin PUSH_RETRIES=2 PUSH_GIT_EMAIL="$EM" >/dev/null; v="$(verdict)"; vrc=$?
sha="$(git -C "$L" rev-parse HEAD)"
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && [ "$(git --git-dir="$B" rev-parse refs/heads/review/c-999-s17 2>/dev/null)" = "$sha" ] \
  && pass "17. the caller's PUSH_* knobs never reach the hook -> PUSHED" \
  || fail "17. knobs reached the hook (rc $vrc: $v)"
echo ok >"$T/hook.mode"

echo "spl-push-master: $fails failure(s)"
[ "$fails" -eq 0 ]
