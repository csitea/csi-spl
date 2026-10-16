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
#      and a `docs(...)` commit with no line -> PUSHED
#   9. the lane closes while its push runs (m-595, SPL-2264): the hook moves
#      the state dir away as agent-id-retire does, then is red -> the moved dir
#      reads REFUSED, not RUNNING; the same with a green hook -> PUSHED there
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

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
    mv "$S" "\$(cat "$T/retire.to")"
    [ "\$mode" = retire-red ] && { echo "deploy-gate FAILED: RETIRE-RED-MARKER"; exit 1; } ;;
  agent-red) [ -n "\${AGENT_ID:-}" ] && { echo "STUB: AGENT_ID=\$AGENT_ID reached the hook"; exit 1; } ;;
esac
exit 0
EOF
chmod +x "$T/hooks/pre-push"
git -C "$L" config core.hooksPath "$T/hooks"

commit() { printf '%s\n' "$1" >"$L/$1.txt"; git -C "$L" add "$1.txt" && git -C "$L" "${G[@]}" commit -qm "$1"; }
run() { SNIPPET='do_spl_push_master' in_orc PUSH_WORKTREE="$L" PUSH_STATE_DIR="$S" FETCH_FRESH_MAX_AGE=0 "$@" 2>&1; }
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

# 7 control first: the stub is red when AGENT_ID reaches it
git -C "$L" -c user.name=lane -c "user.email=$EM" commit -q --amend --no-edit --reset-author
echo agent-red >"$T/hook.mode"; : >"$T/hook.calls"
out="$(AGENT_ID=c-999 "$T/hooks/pre-push" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'AGENT_ID=c-999 reached' <<<"$out" \
  && pass "7. control: the agent-red stub fails when AGENT_ID reaches it" || fail "7. control (rc $rc: $out)"
: >"$T/hook.calls"
run AGENT_ID=c-999 >/dev/null; v="$(verdict)"; vrc=$?
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $(git -C "$L" rev-parse HEAD)" <<<"$v" && grep -qx 'agent=unset' "$T/hook.calls" \
  && pass "7. AGENT_ID=c-999 in the caller's env never reaches the hook -> PUSHED" || fail "7. AGENT_ID ($(cat "$T/hook.calls") | $v)"

# 8 red controls first: a round row whose review line is void is refused
echo ok >"$T/hook.mode"
rcommit() { printf '%s\n' "$1" >"$L/$1.txt"; git -C "$L" add "$1.txt" && git -C "$L" "${G[@]}" commit -qm "$2" ${3:+-m "$3"}; }
# The reviewed sha lives only on origin's review/r99-01: the gate must fetch it.
git -C "$O" switch -q -c review-r99 && commit_o() { printf 'r\n' >"$O/rev.txt"; git -C "$O" add rev.txt && git -C "$O" "${G[@]}" commit -qm reviewed; }
commit_o && git -C "$O" push -q origin HEAD:refs/heads/review/r99-01 && RS="$(git -C "$O" rev-parse HEAD)"; git -C "$O" switch -q master
TAIL='ran: tests | read: diff | log: m-999@sat:/x/journal.jsonl'
red8() {
  git -C "$L" "${G[@]}" commit -q --amend -m 'refactor(r99-01-x): a round row' -m "$2"
  run >/dev/null; v="$(verdict)"; vrc=$?
  short="$(git -C "$L" rev-parse --short HEAD)"
  [ "$vrc" -eq 1 ] && grep -qx "REFUSED round row $short review line: $3" <<<"$v" && ! on_origin "$(git -C "$L" rev-parse HEAD)" \
    && pass "8. red control: $1 -> REFUSED round row $short review line: $3" || fail "8. red control $1 (rc $vrc: $v)"
}
rcommit eight 'refactor(r99-01-x): a round row'
red8 'no PASS line' 'review: m-999 mistral FAIL 0123456 no box, no PASS' "none of the form 'review: <id>@<box> <vendor> PASS <sha> ...'"
red8 'a 39-char sha' "review: m-999@sat mistral PASS ${RS:0:39} $TAIL" "sha '${RS:0:39}' is not 40 hex"
red8 'an unresolvable 40-char sha' "review: m-999@sat mistral PASS $(printf 'f%.0s' $(seq 40)) $TAIL" "sha $(printf 'f%.0s' $(seq 40)) does not resolve (fetched review/r99-01)"
red8 'no log:' "review: m-999@sat mistral PASS $RS ran: tests | read: diff" "no '| log: <id>@<box>:<path>'"
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
verdict_in() {
  local out rc
  for _ in $(seq 1 60); do
    out="$(SNIPPET='do_spl_push_master' in_orc PUSH_WORKTREE="$L" PUSH_STATE_DIR="$1" PUSH_CMD=status 2>&1)"; rc=$?
    [ "$rc" -ne 3 ] && [ -f "$1/status" ] && { printf '%s\n' "$out"; return "$rc"; }
    sleep 0.5
  done
  printf 'TIMEOUT\n%s\n' "$out"; return 9
}
retire9 retire-red
[ "$vrc" -eq 1 ] && grep -q "^REFUSED push of $sha" <<<"$v" && grep -q 'RETIRE-RED-MARKER' <<<"$v" && [ ! -e "$S" ] \
  && grep -q 'the state dir moved' "$T/retired-retire-red/lifetime/push-master/log" \
  && pass "9. the lane's dir moved away during a red push -> REFUSED written where it is now, not RUNNING" || fail "9. retire red (rc $vrc: $v)"
retire9 retire-ok
[ "$vrc" -eq 0 ] && grep -qx "PUSHED $sha" <<<"$v" && on_origin "$sha" \
  && pass "9. ...and a green push from a moved dir -> PUSHED written there" || fail "9. retire ok (rc $vrc: $v)"

echo "spl-push-master: $fails failure(s)"
[ "$fails" -eq 0 ]
