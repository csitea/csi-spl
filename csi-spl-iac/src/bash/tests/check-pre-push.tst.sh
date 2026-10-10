#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_pre_push selects the right suites for what a push carries.
#          The heavy suites are never run here -- PRE_PUSH_PLAN=1 prints the
#          selection and exits, so this test proves the CHANGED-INPUTS routing
#          that FAST mode does and the FULL-mode / unknown-base behaviour.
#   The gated suites are hygiene + api + iac + orc + wui (cnf replaces iac only
#   on a cnf-only push, so FULL does not list it).
#   1. FULL mode -> every gated part (hygiene api iac orc wui)
#   2. FAST, only csi-spl-wui touched -> hygiene + wui, NOT api/iac
#   3. FAST, only csi-spl-api touched -> hygiene + api
#   4. FAST, csi-spl-cnf touched -> iac (cnf feeds the iac gates), NOT api/wui
#   5. FAST, a .github/workflows file touched -> iac (workflow parity tests)
#   6. FAST, only a doc touched -> hygiene alone (it always runs)
#   7. FAST with an UNKNOWN base ref -> widens to FULL, never skips silently
#   8. an untracked new file under csi-spl-api still selects api
#   8c. (r5-07) an orc-only change selects the orc part (no iac, no api)
#   11. (r5-07) the real orc part on a temp repo: green on trunk, REFUSES a
#       lane break a test names, and never runs a test naming no touched file
#   do_log and do_check_dist_hygiene are stubbed; PLAN mode returns before
#   either would run, so the routing is all that is under test.
#------------------------------------------------------------------------------
set -uo pipefail
# Defensive git-env scrub: this test creates commits in throwaway repos; a leaked
# GIT_DIR/GIT_INDEX_FILE (e.g. when run through the pre-push hook) would override
# "git -C" and land commits on the real pushing branch. The hook scrubs them; do
# it here too so the test is safe however it is invoked.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

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
    do_check_pre_push 2>/dev/null | sed -n 's/^PRE_PUSH_PLAN mode=[a-z]* tier=[a-z]* parts=//p'
}
has()   { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
reset_tree() { git -C "$T" checkout -q -- . 2>/dev/null; git -C "$T" clean -fdq >/dev/null 2>&1; }

# 1. FULL -> every gated part
p="$(PP_MODE=full plan)"
{ has "$p" hygiene && has "$p" api && has "$p" iac && has "$p" orc && has "$p" wui && has "$p" wui-vendor && ! has "$p" cnf; } \
  && pass "1. FULL selects hygiene api iac orc wui wui-vendor" || fail "1. FULL selects hygiene api iac orc wui wui-vendor" "$p"

# 2. only WUI -> the WUI parts INCLUDING the payment-vendor gate (which reads WUI)
echo a >"$T/csi-spl-wui/a.ts"; git -C "$T" add -A; git -C "$T" commit -qm wui
p="$(plan)"
{ has "$p" hygiene && has "$p" wui && has "$p" wui-vendor && ! has "$p" api && ! has "$p" iac; } \
  && pass "2. FAST wui-only -> hygiene+wui+wui-vendor" || fail "2. FAST wui-only -> hygiene+wui+wui-vendor" "$p"
git -C "$T" reset -q --hard base; git -C "$T" commit -q --allow-empty -m head

# 3. only API
echo a >"$T/csi-spl-api/a.go"; git -C "$T" add -A; git -C "$T" commit -qm api
p="$(plan)"
{ has "$p" api && ! has "$p" wui && ! has "$p" iac; } \
  && pass "3. FAST api-only -> hygiene+api" || fail "3. FAST api-only -> hygiene+api" "$p"
git -C "$T" reset -q --hard base; git -C "$T" commit -q --allow-empty -m head

# 4. CNF -> iac (cnf feeds the iac gates), not api/wui
echo a >"$T/csi-spl-cnf/a.yaml"; git -C "$T" add -A; git -C "$T" commit -qm cnf
p="$(plan)"
{ has "$p" iac && ! has "$p" api && ! has "$p" wui; } \
  && pass "4. FAST cnf -> iac" || fail "4. FAST cnf -> iac" "$p"
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
mkdir -p "$T/csi-spl-api"; echo a >"$T/csi-spl-api/new.go"
p="$(plan)"
has "$p" api && pass "8. an untracked api file selects api" || fail "8. an untracked api file selects api" "$p"
rm -f "$T/csi-spl-api/new.go"

# 8b. spec 111 T004: a blog post (or the check itself) selects the blog part;
#     a doc outside csi-spl-doc/blog does not, and FULL carries it
mkdir -p "$T/csi-spl-doc/blog/posts/en"; echo a >"$T/csi-spl-doc/blog/posts/en/2026-10-09-x.md"
p="$(plan)"
{ has "$p" blog && ! has "$p" iac && ! has "$p" api; } \
  && pass "8b. a post under csi-spl-doc/blog selects the blog part" || fail "8b. a post selects blog" "$p"
rm -rf "$T/csi-spl-doc"
mkdir -p "$T/csi-spl-orc/src/bash/run"; echo a >"$T/csi-spl-orc/src/bash/run/spl-blog-check.func.sh"
p="$(plan)"
has "$p" blog && pass "8b. a change to spl-blog-check.func.sh selects the blog part" || fail "8b. the check selects blog" "$p"
rm -f "$T/csi-spl-orc/src/bash/run/spl-blog-check.func.sh"
p="$(plan)"
! has "$p" blog && pass "8b. no blog path: no blog part" || fail "8b. no blog path" "$p"
p="$(PP_MODE=full plan)"
has "$p" blog && pass "8b. FULL carries the blog part" || fail "8b. FULL carries blog" "$p"

# 8c. r5-07: an orc-only change selects the orc part, and only it
mkdir -p "$T/csi-spl-orc/src/bash/run"; echo a >"$T/csi-spl-orc/src/bash/run/x.func.sh"
p="$(plan)"
{ has "$p" orc && ! has "$p" iac && ! has "$p" api && ! has "$p" wui; } \
  && pass "8c. FAST orc-only -> hygiene+orc" || fail "8c. FAST orc-only -> hygiene+orc" "$p"
rm -f "$T/csi-spl-orc/src/bash/run/x.func.sh"

# 9. functional control: the payment-vendor gate (run on a WUI change) REFUSES a
#    planted vendor word in a WUI file -- the "stripe" that FAST used to miss.
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
VT="$APP_ROOT/csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh"
if [ -r "$VT" ]; then
  T2=$(mktemp -d)
  mkdir -p "$T2/csi-spl-api/src/bash/tests" "$T2/csi-spl-wui/src/utils" "$T2/csi-spl-wui/tests/unit" "$T2/csi-spl-wui/components"
  cp "$VT" "$T2/csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh"
  : >"$T2/csi-spl-wui/src/utils/card-element.mjs"
  : >"$T2/csi-spl-wui/tests/unit/card-element.test.mjs"
  echo "<!-- card ui -->" >"$T2/csi-spl-wui/components/Ok.vue"
  _pp_part_wui_vendor "$T2" >/dev/null 2>&1 && pass "9. vendor gate passes a clean WUI" || fail "9. vendor gate passes a clean WUI"
  printf '<!-- stripe payment -->\n' >"$T2/csi-spl-wui/components/Bad.vue"
  _pp_part_wui_vendor "$T2" >/dev/null 2>&1 && fail "9. vendor gate REFUSES a planted vendor word in WUI" || pass "9. vendor gate refuses a planted 'stripe' in a WUI file"
  rm -rf "$T2"
else
  fail "9. cannot find the real no-payment-vendor-wui.tst.sh at $VT"
fi

# 10. the WUI part owns its install: a node_modules SYMLINK into another
#     checkout is replaced by a real install (the link's target untouched), an
#     install matching pnpm-lock.yaml is re-used, a changed lockfile re-installs.
#     pnpm is a stub that logs its verb and lays down node_modules.
W="$(mktemp -d)"; mkdir -p "$W/csi-spl-wui" "$W/bin" "$W/shared/node_modules"
echo keep >"$W/shared/node_modules/marker"
echo "lock: 1" >"$W/csi-spl-wui/pnpm-lock.yaml"
cat >"$W/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$PNPM_LOG"
if [ "$1" = install ]; then mkdir -p node_modules/.pnpm && cp pnpm-lock.yaml node_modules/.pnpm/lock.yaml; fi
exit 0
STUB
chmod +x "$W/bin/pnpm"
ln -s "$W/shared/node_modules" "$W/csi-spl-wui/node_modules"
installs() { grep -cx install "$W/pnpm.log" 2>/dev/null || true; }
PATH="$W/bin:$PATH" PNPM_LOG="$W/pnpm.log" _pp_part_wui "$W" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "10. symlinked node_modules -> the part passes" || fail "10. symlinked node_modules -> the part passes" "rc=$rc"
[ ! -L "$W/csi-spl-wui/node_modules" ] && [ -d "$W/csi-spl-wui/node_modules" ] \
  && pass "10. ... the link is replaced by a real install" || fail "10. ... the link is replaced by a real install"
[ -f "$W/shared/node_modules/marker" ] && pass "10. ... the link's target is untouched" || fail "10. ... the link's target is untouched"
[ "$(installs)" = 1 ] && pass "10. ... installed once" || fail "10. ... installed once" "$(installs)"
PATH="$W/bin:$PATH" PNPM_LOG="$W/pnpm.log" _pp_part_wui "$W" >/dev/null 2>&1
[ "$(installs)" = 1 ] && pass "10. an install matching the lockfile is re-used" || fail "10. an install matching the lockfile is re-used" "$(installs)"
echo "lock: 2" >"$W/csi-spl-wui/pnpm-lock.yaml"
PATH="$W/bin:$PATH" PNPM_LOG="$W/pnpm.log" _pp_part_wui "$W" >/dev/null 2>&1
[ "$(installs)" = 2 ] && pass "10. a changed lockfile re-installs" || fail "10. a changed lockfile re-installs" "$(installs)"
rm -rf "$W"

# 11. r5-07 functional control: the real orc part, on a temp repo laid out like
#     the real one (the real run-all-tests.sh + changed-tests.sh, a stub
#     bash-cleancode): foo.tst.sh names do_foo_x; unrelated.tst.sh always fails
#     and names nothing, so it must never run.
O="$(mktemp -d)"; OR="$O/r"; OD="$OR/csi-spl-orc/src/bash/tests"
mkdir -p "$OD" "$OR/csi-spl-orc/lib/bash/funcs" "$OR/csi-spl-iac/src/bash/tests"
cp "$APP_ROOT/csi-spl-orc/src/bash/tests/run-all-tests.sh" "$APP_ROOT/csi-spl-orc/src/bash/tests/changed-tests.sh" "$OD/"
echo 'echo "PASS: cleancode stub"' >"$OR/csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh"
echo 'do_foo_x() { echo good; }' >"$OR/csi-spl-orc/lib/bash/funcs/foo.func.sh"
printf '%s\n' '# tests do_foo_x' '. "$(dirname "$0")/../../../lib/bash/funcs/foo.func.sh"' '[ "$(do_foo_x)" = good ]' >"$OD/foo.tst.sh"
echo 'echo ran-unrelated; exit 1' >"$OD/unrelated.tst.sh"
git -C "$OR" init -q; git -C "$OR" add -A; git -C "$OR" commit -qm seed; git -C "$OR" branch trunk
orc() { ( base=trunk _PP_TOP="$OR" _pp_part_orc "$OR" ) >"$O/out" 2>&1; }
echo 'do_foo_x() { echo good; } # comment' >"$OR/csi-spl-orc/lib/bash/funcs/foo.func.sh"
orc && pass "11. orc part passes a harmless orc change" || fail "11. orc part passes a harmless orc change" "$(cat "$O/out")"
grep -q 'changed-only: run foo.tst.sh' "$O/out" && pass "11. ... it ran the test naming the touched file" || fail "11. ... ran foo.tst.sh" "$(cat "$O/out")"
grep -q ran-unrelated "$O/out" && fail "11. CONTROL: a test naming no touched file must not run" "$(cat "$O/out")" \
  || pass "11. CONTROL: a test naming no touched file did not run"
echo 'do_foo_x() { echo BROKEN; }' >"$OR/csi-spl-orc/lib/bash/funcs/foo.func.sh"
orc && fail "11. orc part REFUSES a lane break foo.tst.sh catches" "$(cat "$O/out")" || pass "11. orc part refuses a lane break foo.tst.sh catches"
rm -rf "$O"

echo "-- check-pre-push.tst.sh: $fails failed"
[[ "$fails" -eq 0 ]]
