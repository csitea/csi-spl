#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the controls CLE-77824 promised for the diff-scoped, cached, loud
#          pre-push gate -- end to end through do_check_pre_push, with STUB parts
#          (a part passes iff <tree>/<its dir>/flag says 'good', and appends its
#          name to a run counter), so nothing heavy runs.
#     1. green trunk + a NEW break in a touched part     -> REFUSED (rc 1, FAIL logged)
#     2. red trunk + a fix                               -> ALLOWED (rc 0)
#     3. red trunk + still red                           -> ALLOWED, WARN-pre-existing logged with the trunk sha
#     4. a push touching only csi-spl-orc                -> runs neither iac nor api (SKIP-untouched logged)
#     5. a rebase over commits that touch OTHER parts    -> the green api verdict is RE-USED (no re-run)
#        ... and a change under csi-spl-api re-runs it
#     6. yq missing                                      -> FAIL naming yq, the part never runs
#     7. a part that exits 127 (command not found) on
#        HEAD and trunk alike                            -> FAIL, never a pre-existing WARN
#     8. every part writes exactly one verdict line with a duration
#------------------------------------------------------------------------------
set -uo pipefail
# Defensive git-env scrub: this test creates commits in throwaway repos; a leaked
# GIT_DIR/GIT_INDEX_FILE (e.g. when run through the pre-push hook) would override
# "git -C" and land commits on the real pushing branch.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

do_log() { :; }
do_check_dist_hygiene() { return 0; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

# Stub parts: count every run, pass iff <tree>/<dir>/flag contains 'good'.
COUNT="$ROOT/count"
_stub() { echo "$1" >>"$COUNT"; grep -q good "$2/$1/flag" 2>/dev/null; }
_pp_part_api() { _stub csi-spl-api "$1"; }
_pp_part_iac() { _stub csi-spl-iac "$1"; }
_pp_part_wui() { _stub csi-spl-wui "$1"; }
_pp_part_wui_vendor() { _stub csi-spl-wui "$1"; }
runs() { grep -cx "$1" "$COUNT" 2>/dev/null || true; }

# A repo whose 'trunk' branch plays origin/master; HEAD is a lane branch.
mkrepo() {  # <dir>
  local R="$1"
  git init -q "$R"
  for d in csi-spl-api csi-spl-iac csi-spl-wui csi-spl-orc; do mkdir -p "$R/$d"; echo good >"$R/$d/flag"; done
  git -C "$R" add -A; git -C "$R" commit -qm seed
  git -C "$R" branch trunk
  git -C "$R" checkout -q -b lane
}
# The stub repos carry no toolchain scaffold, so the tool preflight is stubbed
# to "nothing missing" -- except in case 6, which runs the real one (TOOLS=real).
gate() {  # <repo> [env...] -> rc; per-part log in $R.log
  local R="$1" pre='_pp_missing_tools() { :; }'; shift
  [ "${TOOLS:-stub}" = real ] && pre=':'
  ( env "$@" PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$R.log" PRE_PUSH_CACHE="$R.cache" \
      bash -c '. "$0"; '"$pre"'; '"$(declare -f do_log do_check_dist_hygiene _stub _pp_part_api _pp_part_iac _pp_part_wui _pp_part_wui_vendor)"'; COUNT="'"$COUNT"'"; do_check_pre_push' "$FUNC" ) >/dev/null 2>&1
}
verdict() { awk -v p="$2" '$3=="PART" && $4==p {v=$5} END{print v}' "$1.log"; }

# 1. green trunk + a NEW break in api -> REFUSED
R="$ROOT/r1"; mkrepo "$R" >/dev/null 2>&1
echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "break api"
gate "$R"; eq "1. green trunk + NEW api break -> REFUSED" 1 "$?"
eq "1. ... logged FAIL for api" FAIL "$(verdict "$R" api)"
grep -q 'PART api FAIL .*trunk=[0-9a-f]*-green' "$R.log" \
  && pass "1. ... as a NEW failure (trunk green)" || fail "1. ... as a NEW failure (trunk green)" "$(cat "$R.log")"

# 2. red trunk + a fix -> ALLOWED
R="$ROOT/r2"; mkrepo "$R" >/dev/null 2>&1
git -C "$R" checkout -q trunk; echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "trunk red"
git -C "$R" checkout -q lane; git -C "$R" reset -q --hard trunk
echo good >"$R/csi-spl-api/flag"; echo fix >"$R/csi-spl-api/fix.go"; git -C "$R" add -A; git -C "$R" commit -qm fix
gate "$R"; eq "2. red trunk + a fix -> ALLOWED" 0 "$?"
eq "2. ... logged PASS for api" PASS "$(verdict "$R" api)"

# 3. red trunk + still red -> ALLOWED with WARN-pre-existing naming the trunk sha
R="$ROOT/r3"; mkrepo "$R" >/dev/null 2>&1
git -C "$R" checkout -q trunk; echo bad >"$R/csi-spl-api/flag"; git -C "$R" commit -qam "trunk red"
git -C "$R" checkout -q lane; git -C "$R" reset -q --hard trunk
echo x >"$R/csi-spl-api/other.go"; git -C "$R" add -A; git -C "$R" commit -qm unrelated
gate "$R"; eq "3. red trunk + still red -> ALLOWED" 0 "$?"
tsha="$(git -C "$R" rev-parse --short trunk)"
grep -q "PART api WARN-pre-existing .* trunk=$tsha" "$R.log" \
  && pass "3. ... logged WARN-pre-existing with trunk=$tsha" || fail "3. ... logged WARN-pre-existing with the trunk sha" "$(cat "$R.log")"

# 4. orc-only push -> no iac, no api
R="$ROOT/r4"; mkrepo "$R" >/dev/null 2>&1; : >"$COUNT"
echo y >"$R/csi-spl-orc/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm orc
gate "$R"; eq "4. orc-only push -> passes" 0 "$?"
eq "4. ... the iac suite never ran" 0 "$(runs csi-spl-iac)"
eq "4. ... the api suite never ran" 0 "$(runs csi-spl-api)"
eq "4. ... api logged SKIP-untouched" SKIP-untouched "$(verdict "$R" api)"
eq "4. ... iac logged SKIP-untouched" SKIP-untouched "$(verdict "$R" iac)"

# 5. rebase over unrelated commits re-uses the green api verdict
R="$ROOT/r5"; mkrepo "$R" >/dev/null 2>&1; : >"$COUNT"
echo a >"$R/csi-spl-api/a.go"; git -C "$R" add -A; git -C "$R" commit -qm api
gate "$R"; eq "5. first api push -> green" 0 "$?"
eq "5. ... the api suite ran once" 1 "$(runs csi-spl-api)"
git -C "$R" checkout -q trunk; echo w >"$R/csi-spl-wui/w.ts"; echo o >"$R/csi-spl-orc/o.sh"
git -C "$R" add -A; git -C "$R" commit -qm "someone else's wui+orc"; git -C "$R" checkout -q lane
git -C "$R" rebase -q trunk
gate "$R"; eq "5. after a rebase over unrelated commits -> green" 0 "$?"
eq "5. ... the api suite did NOT re-run (verdict re-used)" 1 "$(runs csi-spl-api)"
eq "5. ... logged PASS-cached for api" PASS-cached "$(verdict "$R" api)"
git -C "$R" checkout -q trunk; echo b >"$R/csi-spl-api/b.go"; git -C "$R" add -A; git -C "$R" commit -qm "someone else's api"
git -C "$R" checkout -q lane; git -C "$R" rebase -q trunk
gate "$R"; eq "5. after a rebase over another api change -> green" 0 "$?"
eq "5. ... the api suite DID re-run (its paths changed)" 2 "$(runs csi-spl-api)"
echo dirty >>"$R/csi-spl-api/a.go"
gate "$R"; eq "5. ... and a dirty api file re-runs it too (uncacheable)" 3 "$(runs csi-spl-api)"

# 6. yq missing -> FAIL naming yq; the iac part never runs
R="$ROOT/r6"; mkrepo "$R" >/dev/null 2>&1; : >"$COUNT"
echo y >"$R/csi-spl-iac/a.sh"; git -C "$R" add -A; git -C "$R" commit -qm iac
NB="$ROOT/noyq"; mkdir -p "$NB"
for t in bash env git sha1sum cut grep date mkdir wc tail mv paste sort head cat id dirname basename mktemp timeout sed rm awk tr jq python3 ls; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NB/$t"
done
TOOLS=real gate "$R" PATH="$NB"; eq "6. yq missing -> REFUSED" 1 "$?"
eq "6. ... the iac suite never ran" 0 "$(runs csi-spl-iac)"
grep -q 'PART iac FAIL .*missing-tool=yq' "$R.log" \
  && pass "6. ... the log names the missing tool (yq)" || fail "6. ... the log names the missing tool" "$(cat "$R.log")"
out="$( PATH="$NB" _pp_missing_tools iac "$R" )"
case "$out" in yq\ --\ install*) pass "6. ... and the message says how to install it" ;; *) fail "6. ... the message names yq and the fix" "$out" ;; esac

# 7. rc 127 on HEAD and on trunk alike -> FAIL, never WARN
R="$ROOT/r7"; mkrepo "$R" >/dev/null 2>&1
echo z >"$R/csi-spl-api/z.go"; git -C "$R" add -A; git -C "$R" commit -qm api
( env PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$R.log" PRE_PUSH_CACHE="$R.cache" \
    bash -c '. "$0"; do_log(){ :; }; do_check_dist_hygiene(){ return 0; }; _pp_missing_tools(){ :; }; _pp_part_api(){ return 127; }; do_check_pre_push' "$FUNC" ) >/dev/null 2>&1
eq "7. rc 127 on HEAD and trunk -> REFUSED (not a pre-existing WARN)" 1 "$?"
grep -q 'PART api FAIL .*rc=127' "$R.log" && pass "7. ... logged FAIL rc=127" || fail "7. ... logged FAIL rc=127" "$(cat "$R.log")"

# 8. one verdict line per part, each with a duration
R="$ROOT/r1"
for p in hygiene iac wui-vendor wui api; do
  n="$(awk -v p="$p" '$3=="PART" && $4==p' "$R.log" | wc -l)"
  eq "8. one verdict line for $p" 1 "$n"
done
awk '$3=="PART" && $6 !~ /^[0-9]+s$/ {bad=1} END{exit bad}' "$R.log" \
  && pass "8. every verdict line carries a duration" || fail "8. every verdict line carries a duration" "$(cat "$R.log")"

echo "-- check-pre-push-scope.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
