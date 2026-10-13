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
mkdir -p "$T/hooks"
# The stub hook: $T/hook.mode = ok | sleep | race | red | race-always.
cat >"$T/hooks/pre-push" <<EOF
#!/bin/bash
echo "override=\${SPL_PREPUSH_OVERRIDE:-unset}" >>"$T/hook.calls"
mode="\$(cat "$T/hook.mode" 2>/dev/null || echo ok)"
case "\$mode" in
  sleep) sleep 6 ;;
  race|race-always)
    [ "\$mode" = race ] && echo ok >"$T/hook.mode"
    n=\$(date +%s%N)
    echo "\$n" >"$O/o-\$n.txt"
    git -C "$O" add "o-\$n.txt" && git -C "$O" ${G[*]} commit -qm "other \$n" && git -C "$O" pull -q --rebase origin master 2>/dev/null
    git -C "$O" push -q origin HEAD:master ;;
  red) echo "deploy-gate FAILED: lint-shellcheck GATE-RED-MARKER"; exit 1 ;;
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

echo "spl-push-master: $fails failure(s)"
[ "$fails" -eq 0 ]
