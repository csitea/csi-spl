#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_pre_push selects the right suites for what a push carries.
#          The heavy suites are never run here -- PRE_PUSH_PLAN=1 prints the
#          selection and exits, so this test proves the CHANGED-INPUTS routing
#          that FAST mode does and the FULL-mode / unknown-base behaviour.
#   1. FULL mode -> every part
#   2. FAST, only csi-spl-wui touched -> hygiene + wui, NOT api/iac/orc/cnf
#   3. FAST, only csi-spl-api touched -> hygiene + api
#   4. FAST, csi-spl-cnf touched -> cnf AND iac (cnf feeds the iac gates)
#   5. FAST, a .github/workflows file touched -> iac (workflow parity tests)
#   6. FAST, only a doc touched -> hygiene alone (it always runs)
#   7. FAST with an UNKNOWN base ref -> widens to FULL, never skips silently
#   8. an untracked new file under a tree still selects that tree
#   do_log and do_check_dist_hygiene are stubbed; PLAN mode returns before
#   either would run, so the routing is all that is under test.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- $2"; fails=$((fails + 1)); }

# A throwaway git repo with a base commit on a 'base' ref and HEAD one ahead.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$T" init -q
mkdir -p "$T/csi-spl-api" "$T/csi-spl-iac" "$T/csi-spl-orc" "$T/csi-spl-cnf" "$T/csi-spl-wui" "$T/doc" "$T/.github/workflows"
echo x >"$T/doc/seed.md"; git -C "$T" add -A; git -C "$T" commit -qm seed
git -C "$T" branch base
git -C "$T" commit -q --allow-empty -m head

# Source the action and stub the run.sh callables it uses.
do_log() { :; }
do_check_dist_hygiene() { return 0; }
APP_PATH="$T"
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

# Run PLAN mode and echo just the parts= field.
plan() {  # extra changed files staged relative to base, via env before call
  PRE_PUSH_PLAN=1 PRE_PUSH_TREE="$T" PRE_PUSH_BASE="${PP_BASE:-base}" PRE_PUSH_MODE="${PP_MODE:-fast}" \
    do_check_pre_push 2>/dev/null | sed -n 's/^PRE_PUSH_PLAN mode=[a-z]* parts=//p'
}
has()   { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
reset_tree() { git -C "$T" checkout -q -- . 2>/dev/null; git -C "$T" clean -fdq >/dev/null 2>&1; }

# 1. FULL -> everything
p="$(PP_MODE=full plan)"
{ has "$p" hygiene && has "$p" api && has "$p" iac && has "$p" orc && has "$p" cnf && has "$p" wui; } \
  && pass "1. FULL selects every part" || fail "1. FULL selects every part" "$p"

# 2. only WUI
echo a >"$T/csi-spl-wui/a.ts"; git -C "$T" add -A; git -C "$T" commit -qm wui
p="$(plan)"
{ has "$p" hygiene && has "$p" wui && ! has "$p" api && ! has "$p" iac && ! has "$p" orc && ! has "$p" cnf; } \
  && pass "2. FAST wui-only -> hygiene+wui" || fail "2. FAST wui-only -> hygiene+wui" "$p"
git -C "$T" reset -q --hard base; git -C "$T" commit -q --allow-empty -m head

# 3. only API
echo a >"$T/csi-spl-api/a.go"; git -C "$T" add -A; git -C "$T" commit -qm api
p="$(plan)"
{ has "$p" api && ! has "$p" wui && ! has "$p" iac; } \
  && pass "3. FAST api-only -> hygiene+api" || fail "3. FAST api-only -> hygiene+api" "$p"
git -C "$T" reset -q --hard base; git -C "$T" commit -q --allow-empty -m head

# 4. CNF -> cnf AND iac
echo a >"$T/csi-spl-cnf/a.yaml"; git -C "$T" add -A; git -C "$T" commit -qm cnf
p="$(plan)"
{ has "$p" cnf && has "$p" iac && ! has "$p" api && ! has "$p" wui; } \
  && pass "4. FAST cnf -> cnf+iac" || fail "4. FAST cnf -> cnf+iac" "$p"
git -C "$T" reset -q --hard base; git -C "$T" commit -q --allow-empty -m head

# 5. a workflow file -> iac
echo a >"$T/.github/workflows/99.yml"; git -C "$T" add -A; git -C "$T" commit -qm wf
p="$(plan)"
{ has "$p" iac && ! has "$p" api; } \
  && pass "5. FAST workflow -> iac" || fail "5. FAST workflow -> iac" "$p"
git -C "$T" reset -q --hard base; git -C "$T" commit -q --allow-empty -m head

# 6. only a doc -> hygiene alone
echo a >"$T/doc/b.md"; git -C "$T" add -A; git -C "$T" commit -qm doc
p="$(plan)"
{ has "$p" hygiene && ! has "$p" api && ! has "$p" iac && ! has "$p" orc && ! has "$p" cnf && ! has "$p" wui; } \
  && pass "6. FAST doc-only -> hygiene alone" || fail "6. FAST doc-only -> hygiene alone" "$p"
git -C "$T" reset -q --hard base; git -C "$T" commit -q --allow-empty -m head

# 7. unknown base -> widen to FULL
p="$(PP_BASE=origin/does-not-exist plan)"
{ has "$p" api && has "$p" wui && has "$p" iac; } \
  && pass "7. FAST unknown-base widens to FULL" || fail "7. FAST unknown-base widens to FULL" "$p"

# 8. an UNTRACKED new file still selects its tree
echo a >"$T/csi-spl-orc/new.sh"
p="$(plan)"
has "$p" orc && pass "8. an untracked orc file selects orc" || fail "8. an untracked orc file selects orc" "$p"
rm -f "$T/csi-spl-orc/new.sh"

echo "-- check-pre-push.tst.sh: $((8 - fails))/8 passed"
[[ "$fails" -eq 0 ]]
