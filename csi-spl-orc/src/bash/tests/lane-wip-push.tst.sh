#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_wip_push and the pre-push wip exemption (spec 102
# section 5.4, tasks.md T007) on a bare remote and a throwaway spool root.
#   1. a dirty tree -> one wip commit on refs/heads/wip/<branch>, canonical
#      author, the lane's index, HEAD and files unchanged; the push went
#      through the real pre-push hook, whose gate (a stub) would refuse;
#      tracked edits and a staged new file ride, an untracked STATE-x.md with
#      a 40-hex string never does (SPL-2191: the ref is public, gitleaks
#      scans every ref)
#   2. a second run with no change -> no push
#   3. a new change -> a new wip commit, still on HEAD (force-with-lease)
#   4. control: any ref outside refs/heads/wip/ (master) -> refused, exit 1
#   5. mid-rebase -> ORIG_HEAD on the wip ref + the dirty diff as a patch file
#   6. refusals: detached HEAD, the live spool root under SPOOL_TEST
#   7. the hook: wip-only stdin skips the gate; control: a mixed push (wip +
#      a branch) and a branch-only push still run it
#   8. SPL-2513: a new untracked source file under csi-spl-*/ rides; the
#      lane's STATE-*.md / .lane-state-*.md, a screenshot, an ignored file, a
#      top-level file and a file over WIP_UNTRACKED_MAX_BYTES (logged) do not;
#      red control: on the tracked-only code the new file is missing
#      (runs before 5, which needs a clean tree)
#  10. SPL-4296: a generated build dir (.output.ppe-keep/, node_modules/,
#      .nuxt/) and an untracked tree over WIP_UNTRACKED_TREE_MAX_BYTES stay
#      out, each logged once; a small new source dir rides; the repo's
#      .gitignore ignores .output.ppe-keep/; red control: on the per-file-cap
#      code the build output rides
#   9. DRY_RUN=1 plans and pushes nothing; a noreply author is refused; a
#      clean tree pushes HEAD itself, no wip commit (runs before 7, in this
#      order: under a broken dry run G would read red too)
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
printf 'two\n' >>"$L/f.txt"; printf 'new\n' >"$L/u.txt"
printf 'spool /var/spool-hub/x\nsha 0123456789abcdef0123456789abcdef01234567\n' >"$L/STATE-x.md"
printf 'staged\n' >"$L/s.txt" && git -C "$L" add s.txt
idx0="$(git -C "$L" ls-files -s | md5sum)"
out="$(run ID=c-901)"; rc=$?
w1="$(wip)"
[ "$rc" -eq 0 ] && [ -n "$w1" ] && grep -q '^OK WIP c-901' <<<"$out" && pass "1. a dirty tree is pushed to wip/<branch>" || fail "1. push (rc $rc: $out)"
[ "$(git --git-dir="$B" rev-parse "$w1^")" = "$head0" ] && [ "$(git --git-dir="$B" show "$w1:s.txt")" = staged ] \
  && [ "$(git --git-dir="$B" show "$w1:f.txt" | tail -1)" = two ] && pass "1. one commit on HEAD carrying the tracked edit and the staged new file" || fail "1. wip commit shape"
[ "$(git --git-dir="$B" ls-tree --name-only "$w1" | tr '\n' ' ')" = 'csi-spl-iac f.txt s.txt ' ] \
  && ! git --git-dir="$B" grep -q 0123456789abcdef0123456789abcdef01234567 "$w1" \
  && pass "1. untracked STATE-x.md and u.txt are NOT in the wip commit (SPL-2191)" || fail "1. untracked rode along ($(git --git-dir="$B" ls-tree --name-only "$w1" | tr '\n' ' '))"
[ "$(git --git-dir="$B" log -1 --format='%an <%ae>|%cn <%ce>|%s' "$w1" | sed 's/: [0-9TZ]* handoff/: TS handoff/')" = 'wip-test <wip-test@example.com>|wip-test <wip-test@example.com>|wip(c-901): TS handoff' ] \
  && pass "1. canonical author and committer, message wip(<id>): <ts> handoff" || fail "1. author ($(git --git-dir="$B" log -1 --format='%an %ae %cn %ce %s' "$w1"))"
[ "$(git -C "$L" rev-parse HEAD)" = "$head0" ] && [ "$(git -C "$L" ls-files -s | md5sum)" = "$idx0" ] \
  && [ "$(git -C "$L" status --porcelain | tr '\n' ' ')" = ' M f.txt A  s.txt ?? STATE-x.md ?? u.txt ' ] && pass "1. the lane's HEAD, index and tree are unchanged" || fail "1. lane touched ($(git -C "$L" status --porcelain | tr '\n' ' '))"
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
git -C "$L" checkout -q -- f.txt && git -C "$L" rm -q --cached s.txt && rm -f "$L/u.txt" "$L/s.txt" "$L/STATE-x.md"

# 8. SPL-2513: a lane's NEW source files ride (c-999's WIP of 2026-10-18 lost
# its 6 new files); its scratch, screenshots, ignored files, files outside a
# csi-spl-*/ tree and files over the size cap do not
I="$L/csi-spl-iac"
printf 'edit\n' >>"$I/run"
mkdir -p "$I/sub dir"
printf 'new step\n' >"$I/sub dir/y17 step.sh"
printf 'sha 0123456789abcdef0123456789abcdef01234567\n' >"$I/STATE-c-901.md"
printf 'note\n' >"$I/.lane-state-c-901.md"
printf 'png\n' >"$I/shot.PNG"
printf 'ignored\n' >"$I/build.log" && printf '*.log\n' >>"$L/.git/info/exclude"
printf 'top\n' >"$L/top-scratch.txt"
head -c 200 /dev/zero >"$I/big.bin"
st0="$(git -C "$L" status --porcelain | md5sum)"; idx0="$(git -C "$L" ls-files -s | md5sum)"
out="$(run ID=c-901 WIP_UNTRACKED_MAX_BYTES=100)"; rc=$?
w8="$(wip)"; files="$(git --git-dir="$B" ls-tree -r --name-only "$w8" 2>/dev/null | tr '\n' '|')"
[ "$rc" -eq 0 ] && [ "$w8" != "$w2" ] && [ "$(git --git-dir="$B" show "$w8:csi-spl-iac/sub dir/y17 step.sh")" = 'new step' ] \
  && [ "$(git --git-dir="$B" show "$w8:csi-spl-iac/run" | tail -1)" = edit ] \
  && pass "8. the tracked edit and the new source file (csi-spl-*/, a space in its path) are in the wip commit" || fail "8. new file missing (rc $rc: $out; files $files)"
[ "$files" = 'csi-spl-iac/run|csi-spl-iac/sub dir/y17 step.sh|f.txt|' ] && ! git --git-dir="$B" grep -q 0123456789abcdef0123456789abcdef01234567 "$w8" \
  && pass "8. STATE-*.md, .lane-state-*.md, a screenshot, an ignored file, a top-level file and a file over the cap are NOT" || fail "8. scratch rode along ($files)"
grep -q 'SKIP WIP c-901: new file csi-spl-iac/big.bin is 200 bytes, over the 100 cap' <<<"$out" \
  && pass "8. the file over the cap is logged" || fail "8. cap not logged ($out)"
[ "$(git -C "$L" status --porcelain | md5sum)" = "$st0" ] && [ "$(git -C "$L" ls-files -s | md5sum)" = "$idx0" ] \
  && pass "8. the lane's index and tree are unchanged" || fail "8. lane touched ($(git -C "$L" status --porcelain | tr '\n' ' '))"
out="$(run ID=c-901 WIP_UNTRACKED_MAX_BYTES=1x)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'must be a byte count' <<<"$out" && pass "8. control: a malformed cap is refused" || fail "8. bad cap (rc $rc: $out)"
git -C "$L" checkout -q -- csi-spl-iac/run
rm -rf "$I/sub dir" "$I/STATE-c-901.md" "$I/.lane-state-c-901.md" "$I/shot.PNG" "$I/build.log" "$I/big.bin" "$L/top-scratch.txt"

# 10. SPL-4296: a fence's wip push of c-954 (4a54d616f, 2026-10-29) carried a
# left-behind csi-spl-wui/.output.ppe-keep/ (1961 files, 93 MB, every file
# under the 1 MB file cap). A generated build dir never rides, nor does any
# untracked tree over WIP_UNTRACKED_TREE_MAX_BYTES; both are logged once per
# dir, and a small new source dir still rides (in the fixture's tracked
# csi-spl-iac/, as csi-spl-wui/ is tracked in the repo)
W="$L/csi-spl-iac"
mkdir -p "$W/.output.ppe-keep/public/_nuxt" "$W/node_modules/x" "$W/.nuxt" "$W/bulk" "$W/src/new"
for i in 1 2 3; do printf 'chunk %s\n' "$i" >"$W/.output.ppe-keep/public/_nuxt/c$i.js"; done
printf 'm\n' >"$W/node_modules/x/i.js"; printf 'n\n' >"$W/.nuxt/app.js"
for i in 1 2 3 4; do head -c 60 /dev/zero >"$W/bulk/b$i.dat"; done
printf 'export const a = 1\n' >"$W/src/new/a.ts"; printf 'export const b = 2\n' >"$W/src/new/b.ts"
out="$(run ID=c-901 WIP_UNTRACKED_MAX_BYTES=100 WIP_UNTRACKED_TREE_MAX_BYTES=200)"; rc=$?
files="$(git --git-dir="$B" ls-tree -r --name-only "$(wip)" 2>/dev/null | grep '^csi-spl-iac/' | tr '\n' '|')"
[ "$rc" -eq 0 ] && [ "$files" = 'csi-spl-iac/run|csi-spl-iac/src/new/a.ts|csi-spl-iac/src/new/b.ts|' ] \
  && pass "10. .output.ppe-keep/, node_modules/, .nuxt/ and a tree over the tree cap stay out; the new source dir rides" || fail "10. build output rode (rc $rc: $out; files $files)"
grep -q 'SKIP WIP c-901: build dir csi-spl-iac/.output.ppe-keep/ (3 files)' <<<"$out" \
  && grep -q 'SKIP WIP c-901: new tree csi-spl-iac/bulk/ is 240 bytes in 4 files, over the 200 tree cap' <<<"$out" \
  && [ "$(grep -c 'SKIP WIP c-901: build dir' <<<"$out")" -eq 3 ] \
  && pass "10. each skipped dir is logged once, with its count" || fail "10. skip log ($out)"
out="$(run ID=c-901 WIP_UNTRACKED_TREE_MAX_BYTES=2x)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'WIP_UNTRACKED_TREE_MAX_BYTES must be a byte count' <<<"$out" \
  && pass "10. control: a malformed tree cap is refused" || fail "10. bad tree cap (rc $rc: $out)"
REPO="$(cd "$PROJ_ROOT/.." && pwd)"
git -C "$REPO" check-ignore -q --no-index csi-spl-wui/.output.ppe-keep/public/x.js \
  && git -C "$REPO" check-ignore -q --no-index csi-spl-wui/.output/public/x.js \
  && pass "10. the repo's .gitignore ignores csi-spl-wui/.output.ppe-keep/ next to .output/" || fail "10. .output.ppe-keep is not ignored by the repo"
rm -rf "$W/.output.ppe-keep" "$W/node_modules" "$W/.nuxt" "$W/bulk" "$W/src"

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

# 9. the dry run, the noreply author and the clean tree
w9="$(wip)"
printf 'nine\n' >>"$L/f.txt"
out="$(run ID=c-901 DRY_RUN=1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^PLAN WIP c-901' <<<"$out" && [ "$(wip)" = "$w9" ] \
  && pass "9. DRY_RUN=1 prints the plan and pushes nothing" || fail "9. dry run (rc $rc: $out, wip $(wip))"
out="$(run ID=c-901 WIP_GIT_EMAIL=1+x@users.noreply.github.com)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no canonical author' <<<"$out" && [ "$(wip)" = "$w9" ] \
  && pass "9. a noreply author is refused, nothing pushed" || fail "9. noreply author (rc $rc: $out, wip $(wip))"
git -C "$L" "${G[@]}" commit -qam probe
out="$(run ID=c-901)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(wip)" = "$(git -C "$L" rev-parse HEAD)" ] \
  && pass "9. a clean tree pushes HEAD itself, no wip commit" || fail "9. clean tree (rc $rc: $out, wip $(wip), HEAD $(git -C "$L" rev-parse HEAD))"

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
