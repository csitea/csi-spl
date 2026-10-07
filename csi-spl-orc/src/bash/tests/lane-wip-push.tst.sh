#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_wip_push and the pre-push wip exemption (spec 102
# section 5.4, tasks.md T007) on a bare remote and a throwaway spool root.
#   1. a dirty tree -> one wip commit on refs/heads/wip/<branch>, canonical
#      author, the lane's index, HEAD and files unchanged; the push went
#      through the real pre-push hook, whose gate (a stub) would refuse
#   2. a second run with no change -> no push
#   3. a new change -> a new wip commit, still on HEAD (force-with-lease)
#   4. control: any ref outside refs/heads/wip/ (master) -> refused, exit 1
#   5. mid-rebase -> ORIG_HEAD on the wip ref + the dirty diff as a patch file
#   6. refusals: detached HEAD, the live spool root under SPOOL_TEST
#   7. the hook: wip-only stdin skips the gate; control: a mixed push (wip +
#      a branch) and a branch-only push still run it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
HOOK="$PROJ_ROOT/src/bash/features/spawn-agents/hooks/pre-push"

R="$T/spool" B="$T/remote.git" L="$T/lane"
G=(-c user.name=wip-test -c user.email=wip-test@example.com -c init.defaultBranch=master -c advice.detachedHead=false)
mkdir -p "$R/c-901" "$T/hooks" "$T/pplog"
git "${G[@]}" init -q --bare "$B"
git "${G[@]}" init -q "$L"
mkdir -p "$L/csi-spl-iac"
printf '#!/bin/sh\necho gate >>"%s/gate.calls"\nexit 1\n' "$T" >"$L/csi-spl-iac/run"
chmod +x "$L/csi-spl-iac/run"
printf 'one\n' >"$L/f.txt"
git -C "$L" "${G[@]}" add -A && git -C "$L" "${G[@]}" commit -qm base
git -C "$L" remote add origin "$B" && git -C "$L" push -q origin master
git -C "$L" switch -q -c c-901-s1-t1
git -C "$L" config user.name wip-test && git -C "$L" config user.email wip-test@example.com
cp "$HOOK" "$T/hooks/pre-push" && git -C "$L" config core.hooksPath "$T/hooks"
printf 'c-901\tclaude\t%%1\t%s\t20261007T080000Z\tc-001\n' "$L" >"$R/registry.tsv"

run() { SNIPPET='do_spl_lane_wip_push' in_orc SPOOL_ROOT="$R" SPL_PREPUSH_LOG_DIR="$T/pplog" "$@" 2>&1; }
wip() { git --git-dir="$B" rev-parse -q --verify refs/heads/wip/c-901-s1-t1 2>/dev/null; }

head0="$(git -C "$L" rev-parse HEAD)"
idx0="$(git -C "$L" ls-files -s | md5sum)"
printf 'two\n' >>"$L/f.txt"; printf 'new\n' >"$L/u.txt"
out="$(run ID=c-901)"; rc=$?
w1="$(wip)"
[ "$rc" -eq 0 ] && [ -n "$w1" ] && grep -q '^OK WIP c-901' <<<"$out" && pass "1. a dirty tree is pushed to wip/<branch>" || fail "1. push (rc $rc: $out)"
[ "$(git --git-dir="$B" rev-parse "$w1^")" = "$head0" ] && [ "$(git --git-dir="$B" show "$w1:u.txt")" = new ] \
  && [ "$(git --git-dir="$B" show "$w1:f.txt" | tail -1)" = two ] && pass "1. one commit on HEAD carrying tracked + untracked changes" || fail "1. wip commit shape"
[ "$(git --git-dir="$B" log -1 --format='%an <%ae>|%cn <%ce>|%s' "$w1" | sed 's/: [0-9TZ]* handoff/: TS handoff/')" = 'wip-test <wip-test@example.com>|wip-test <wip-test@example.com>|wip(c-901): TS handoff' ] \
  && pass "1. canonical author and committer, message wip(<id>): <ts> handoff" || fail "1. author ($(git --git-dir="$B" log -1 --format='%an %ae %cn %ce %s' "$w1"))"
[ "$(git -C "$L" rev-parse HEAD)" = "$head0" ] && [ "$(git -C "$L" ls-files -s | md5sum)" = "$idx0" ] \
  && [ "$(git -C "$L" status --porcelain | tr '\n' ' ')" = ' M f.txt ?? u.txt ' ] && pass "1. the lane's HEAD, index and tree are unchanged" || fail "1. lane touched ($(git -C "$L" status --porcelain | tr '\n' ' '))"
[ ! -e "$T/gate.calls" ] && grep -q 'SKIP-WIP' "$T/pplog/pre-push.log" 2>/dev/null \
  && pass "1. the real pre-push hook skipped its gate for the wip ref" || fail "1. hook ($(cat "$T/gate.calls" "$T/pplog/pre-push.log" 2>/dev/null))"

out="$(run ID=c-901)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^SKIP WIP c-901: unchanged' <<<"$out" && [ "$(wip)" = "$w1" ] \
  && pass "2. no change since the last push -> no push" || fail "2. unchanged (rc $rc: $out)"

printf 'three\n' >>"$L/f.txt"
out="$(run ID=c-901)"; rc=$?
w2="$(wip)"
[ "$rc" -eq 0 ] && [ -n "$w2" ] && [ "$w2" != "$w1" ] && [ "$(git --git-dir="$B" rev-parse "$w2^")" = "$head0" ] \
  && pass "3. a new change -> a new wip commit on HEAD, force-with-lease over the old" || fail "3. re-push (rc $rc: $out)"

master0="$(git --git-dir="$B" rev-parse refs/heads/master)"
printf 'four\n' >>"$L/f.txt"
for ref in refs/heads/master master refs/heads/c-901-s1-t1 refs/heads/wip/../master refs/tags/wip/x; do
  out="$(run ID=c-901 WIP_REF="$ref")"; rc=$?
  [ "$rc" -eq 1 ] && grep -q 'refused ref' <<<"$out" && pass "4. control: WIP_REF=$ref -> refused, exit 1" || fail "4. WIP_REF=$ref (rc $rc: $out)"
done
[ "$(git --git-dir="$B" rev-parse refs/heads/master)" = "$master0" ] && [ "$(wip)" = "$w2" ] \
  && [ "$(git --git-dir="$B" for-each-ref --format=x | wc -l)" -eq 2 ] && pass "4. ...and the remote is untouched" || fail "4. remote changed"
git -C "$L" checkout -q -- f.txt && rm -f "$L/u.txt"

# 5. mid-rebase: the branch and master both change f.txt, the rebase stops
printf 'lane\n' >"$L/f.txt"; git -C "$L" "${G[@]}" commit -qam lane
tip="$(git -C "$L" rev-parse HEAD)"
git -C "$L" switch -q master; printf 'trunk\n' >"$L/f.txt"; git -C "$L" "${G[@]}" commit -qam trunk; git -C "$L" switch -q c-901-s1-t1
git -C "$L" "${G[@]}" rebase -q master >/dev/null 2>&1
if [ -d "$L/.git/rebase-merge" ] || [ -d "$L/.git/rebase-apply" ]; then
  out="$(run ID=c-901)"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(wip)" = "$tip" ] && pass "5. mid-rebase -> ORIG_HEAD on the wip ref" || fail "5. mid-rebase (rc $rc: $out, wip $(wip), tip $tip)"
  p="$(ls "$R/c-901/lifetime/"wip-*.patch 2>/dev/null | sed -n 1p)"
  [ -n "$p" ] && grep -q '^diff --git a/f.txt' "$p" && grep -q 'patch=' <<<"$out" && pass "5. ...and the dirty diff as a patch file" || fail "5. patch ($p)"
  [ -d "$L/.git/rebase-merge" ] || [ -d "$L/.git/rebase-apply" ] && pass "5. the rebase is left as it was" || fail "5. rebase state lost"
  git -C "$L" rebase --abort
else
  fail "5. fixture: the rebase did not stop on a conflict"
fi

git -C "$L" switch -q --detach HEAD
out="$(run ID=c-901)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'detached' <<<"$out" && pass "6. a detached HEAD is refused" || fail "6. detached (rc $rc: $out)"
git -C "$L" switch -q c-901-s1-t1
out="$(run ID=c-901 SPOOL_LIVE_ROOT="$R")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'live root' <<<"$out" && pass "6. SPOOL_TEST refuses the live spool root" || fail "6. live root (rc $rc: $out)"
out="$(run ID='c-901;x')"; rc=$?
[ "$rc" -eq 1 ] && pass "6. a malformed ID is refused" || fail "6. bad ID (rc $rc)"

# 7. the hook alone, against the failing gate stub
hook() { (cd "$L" && printf '%s\n' "$@" | SPL_PREPUSH_LOG_DIR="$T/pplog" bash "$HOOK" origin "$B" >/dev/null 2>&1); }
z=0000000000000000000000000000000000000000
rm -f "$T/gate.calls"
hook "HEAD $head0 refs/heads/wip/c-901-s1-t1 $z"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$T/gate.calls" ] && pass "7. wip-only stdin -> the gate is skipped" || fail "7. wip-only (rc $rc)"
hook "HEAD $head0 refs/heads/wip/a $z" "HEAD $head0 refs/heads/wip/b $z"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$T/gate.calls" ] && pass "7. two wip refs -> still skipped" || fail "7. two wip refs (rc $rc)"
hook "HEAD $head0 refs/heads/wip/c-901-s1-t1 $z" "HEAD $head0 refs/heads/master $z"; rc=$?
[ "$rc" -eq 1 ] && [ -s "$T/gate.calls" ] && pass "7. control: a mixed push (wip + master) runs the gate" || fail "7. mixed push skipped the gate (rc $rc)"
rm -f "$T/gate.calls"
hook "HEAD $head0 refs/heads/master $z"; rc=$?
[ "$rc" -eq 1 ] && [ -s "$T/gate.calls" ] && pass "7. control: a branch-only push runs the gate" || fail "7. branch push (rc $rc)"
rm -f "$T/gate.calls"
hook "HEAD $head0 refs/heads/wip/ $z"; rc=$?
[ "$rc" -eq 1 ] && [ -s "$T/gate.calls" ] && pass "7. control: a bare refs/heads/wip/ is not exempt" || fail "7. empty wip name (rc $rc)"

echo "lane-wip-push: ${fails} failure(s)"
[ "$fails" -eq 0 ]
