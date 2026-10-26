#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push part wui-e2e (spec 133 action 7, L6) maps a WUI change
#          to the e2e files it touches and runs them, capped. Hermetic: a
#          throwaway WUI tree; the bundle build and the browser run are stubs
#          (PRE_PUSH_E2E_GENERATE / PRE_PUSH_E2E_RUNNER) that count calls.
#   1. a component change selects the tests that name a testid it declares,
#      exact or by a bound prefix ('foo-row-' + id); never a ci-skip.txt file,
#      never a test naming only a longer id (foo-panelx), never the shell's
#   2. a composable change selects the tests of the component that uses it
#   3. a page change selects the tests that open its route
#   4. an edited e2e test selects itself first (score 100); an edited helper
#      the tests that import it
#   5. the cap: PRE_PUSH_E2E_MAX=1 runs the best file, the rest print CUT; a
#      budget smaller than every file still runs the top one
#   6. no WUI path, or PRE_PUSH_E2E=0 -> the part is not selected
#   7. the run: the runner gets the selected files; a second run on the same
#      tree re-uses the bundle (1 build for 2 runs); a .output that was there
#      before is put back; none is left behind
#   8. the cap in time: a runner past PRE_PUSH_E2E_TIMEOUT -> rc 124
#   9. the real _ppe_generate stamps the bundle with the tree's HEAD (wf 10:
#      GITHUB_SHA), so build-watch.test.mjs finds a 40-hex commit
#  10. a component's direct test (it names a data-test="x" the component
#      declares) is kept first under PRE_PUSH_E2E_MAX=1, ahead of a generic
#      test that scores higher through the component's user (SPL-3190:
#      phone-composer-target was CUT behind 6 generic tests)
#   CONTROL a. with the users-of step off (_ppe_names prints nothing) check 2
#              selects nothing: the closure is what finds it
#   CONTROL b. a dirty WUI source -> no cache key -> 2 builds for 2 runs, so
#              check 7's single build comes from the key
#   CONTROL c. outside a git tree the stamp is empty: check 9 reads HEAD
#   CONTROL d. in check 10 the generic test's score IS higher, so the order
#              comes from the direct tier, not the score
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
do_log() { echo "$*"; }
# shellcheck source=/dev/null
source "$FUNC"

R="$T/repo"; W="$R/csi-spl-wui"
mkdir -p "$W/src/components" "$W/src/composables" "$W/src/pages" "$W/src/layouts" "$W/tests/e2e/lib" "$W/src/node/test"
g() { git -c user.name=t -c user.email=t@example.com -C "$R" "$@"; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
cat >"$W/src/components/FooBar.vue" <<'EOF'
<template><div data-testid="foo-panel"><p v-for="id in ids" :data-testid="'foo-row-' + id" /></div></template>
EOF
echo 'export function useThingState() { return 1 }' >"$W/src/composables/useThing.ts"
cat >"$W/src/components/ThingView.vue" <<'EOF'
<script setup>const s = useThingState()</script>
<template><div data-testid="thing-view" /></template>
EOF
echo '<template><main data-testid="reports-page" /></template>' >"$W/src/pages/reports.vue"
echo '<template><FooBar /><nav data-testid="shell-rail" /></template>' >"$W/src/layouts/default.vue"
echo "await page.waitForSelector('[data-testid=\"foo-panel\"]')" >"$W/tests/e2e/foo.test.mjs"
echo "await page.click('[data-testid=\"foo-row-3\"]')" >"$W/tests/e2e/foo-rows.test.mjs"
echo "await page.click('[data-testid=\"foo-panelx\"]')" >"$W/tests/e2e/foo-panelx.test.mjs"
echo "await page.click('[data-testid=\"thing-view\"]')" >"$W/tests/e2e/thing.test.mjs"
echo 'await page.goto(`${BASE_URL}/reports`)' >"$W/tests/e2e/reports.test.mjs"
echo "await page.click('[data-testid=\"shell-rail\"]')" >"$W/tests/e2e/shell.test.mjs"
echo "await page.click('[data-testid=\"foo-panel\"]')" >"$W/tests/e2e/skipped.test.mjs"
echo "import { h } from './lib/helper.mjs'" >"$W/tests/e2e/uses-helper.test.mjs"
echo 'export const h = 1' >"$W/tests/e2e/lib/helper.mjs"
echo '<template><span data-test="dock-chip" /></template>' >"$W/src/components/DockBox.vue"
echo '<template><DockBox /><i data-testid="host-a" /><i data-testid="host-b" /><i data-testid="host-c" /><i data-testid="host-d" /></template>' >"$W/src/components/DockHost.vue"
echo "await page.click('[data-test=dock-chip]')" >"$W/tests/e2e/dock-chip.test.mjs"
echo 'for (const k of ["host-a", "host-b", "host-c", "host-d"]) await page.click(`[data-testid=${k}]`)' >"$W/tests/e2e/dock-host.test.mjs"
printf '# reasons\nskipped.test.mjs   needs a live hub\n' >"$W/tests/e2e/ci-skip.txt"
printf 'tests/e2e/foo.test.mjs 20\ntests/e2e/foo-rows.test.mjs 10\ntests/e2e/thing.test.mjs 30\n' >"$W/src/node/test/e2e-shard-weights.txt"
echo lock >"$W/pnpm-lock.yaml"; mkdir -p "$W/node_modules/.pnpm"; cp "$W/pnpm-lock.yaml" "$W/node_modules/.pnpm/lock.yaml"
printf 'node_modules\n.output\n' >"$R/.gitignore"
g init -q; g add -A; g commit -qm base

sel() { PRE_PUSH_TREE="$R" WUI_E2E_CHANGED="$*" do_check_pre_push_e2e; }
runs() { grep -v '^CUT ' | cut -d' ' -f1 | sort | paste -sd' ' -; }

# --- 1. a component -----------------------------------------------------------
got="$(sel csi-spl-wui/src/components/FooBar.vue | runs)"
[[ "$got" == "tests/e2e/foo-rows.test.mjs tests/e2e/foo.test.mjs" ]] \
  && pass "1. FooBar.vue selects foo and foo-rows (exact id, bound prefix); not skipped, not foo-panelx, not the shell's" \
  || fail "1. FooBar.vue selected '$got'"
# --- 2. a composable, through its user --------------------------------------------
got="$(sel csi-spl-wui/src/composables/useThing.ts)"
[[ "$(runs <<<"$got")" == "tests/e2e/thing.test.mjs" ]] && grep -q '^tests/e2e/thing.test.mjs 3 ' <<<"$got" \
  && pass "2. useThing.ts selects thing.test.mjs through ThingView.vue (weight 3)" \
  || fail "2. useThing.ts selected '$got'"
# --- 3. a page, by its route ----------------------------------------------------------
got="$(sel csi-spl-wui/src/pages/reports.vue | runs)"
[[ "$got" == "tests/e2e/reports.test.mjs" ]] && pass "3. pages/reports.vue selects the test that opens /reports" \
  || fail "3. pages/reports.vue selected '$got'"
# --- 4. an edited e2e test, an edited helper --------------------------------------------
got="$(sel csi-spl-wui/tests/e2e/shell.test.mjs csi-spl-wui/src/components/FooBar.vue)"
[[ "$(head -1 <<<"$got")" == "tests/e2e/shell.test.mjs 100 20" ]] \
  && pass "4. an edited test runs first (score 100, the median CI weight 20)" || fail "4. edited test: '$got'"
got="$(sel csi-spl-wui/tests/e2e/lib/helper.mjs | runs)"
[[ "$got" == "tests/e2e/uses-helper.test.mjs" ]] && pass "4. an edited helper selects the test that imports it" \
  || fail "4. helper selected '$got'"
# --- 5. the cap -----------------------------------------------------------------------
got="$(PRE_PUSH_E2E_MAX=1 sel csi-spl-wui/src/components/FooBar.vue)"
[[ "$(grep -vc '^CUT ' <<<"$got")" == 1 && "$(grep -c '^CUT ' <<<"$got")" == 1 ]] \
  && pass "5. PRE_PUSH_E2E_MAX=1: one file runs, the other prints CUT" || fail "5. MAX=1 gave '$got'"
got="$(PRE_PUSH_E2E_BUDGET=1 sel csi-spl-wui/src/components/FooBar.vue)"
[[ "$(grep -vc '^CUT ' <<<"$got")" == 1 ]] && pass "5. a budget under every file still runs the top one" \
  || fail "5. BUDGET=1 gave '$got'"
# --- 6. not selected ----------------------------------------------------------------------
_ppe_plan "csi-spl-api/x.go" "$R" && fail "6. a non-WUI change selected the part" \
  || pass "6. a non-WUI change does not select the part"
PRE_PUSH_E2E=0 _ppe_plan "csi-spl-wui/src/components/FooBar.vue" "$R" && fail "6. PRE_PUSH_E2E=0 still selected it" \
  || pass "6. PRE_PUSH_E2E=0: not selected"

# --- 7. the run, the bundle cache -----------------------------------------------------------
cat >"$T/gen" <<'EOF'
#!/bin/bash
echo build >>"$PPE_T/builds"; mkdir -p .output/public; echo ok >.output/public/index.html
EOF
cat >"$T/run" <<'EOF'
#!/bin/bash
echo "$*" >>"$PPE_T/ran"; [[ -f .output/public/index.html ]] || { echo "FAIL: no bundle"; exit 1; }
sleep "${PPE_SLEEP:-0}"
EOF
chmod +x "$T/gen" "$T/run"
part() {
  ( export PPE_T="$T" PRE_PUSH_E2E_GENERATE="$T/gen" PRE_PUSH_E2E_RUNNER="$T/run" PRE_PUSH_E2E_BUNDLES="$T/bundles" \
      CHROME_PATH=/bin/true TMPDIR="$T"
    _ppe_plan "csi-spl-wui/src/components/FooBar.vue" "$R" && _pp_part_wui_e2e "$R" ) >>"$T/out" 2>&1
}
mkdir -p "$W/.output"; echo mine >"$W/.output/keep"
part; r1=$?; part; r2=$?
if [[ "$r1" == 0 && "$r2" == 0 && "$(wc -l <"$T/builds")" == 1 && "$(wc -l <"$T/ran")" == 2 ]] \
   && grep -qx 'tests/e2e/foo-rows.test.mjs tests/e2e/foo.test.mjs' "$T/ran" \
   && [[ "$(cat "$W/.output/keep" 2>/dev/null)" == mine && ! -e "$W/.output/public" ]]; then
  pass "7. 2 runs: the runner got the selected files, 1 build (re-used), the old .output put back"
else
  fail "7. rc $r1/$r2, builds $(wc -l <"$T/builds" 2>/dev/null), runs $(wc -l <"$T/ran" 2>/dev/null)"; sed 's/^/    | /' "$T/out" "$T/ran"
fi
rm -rf "$W/.output"
# --- 8. the time cap ------------------------------------------------------------------------
PPE_SLEEP=20 PRE_PUSH_E2E_TIMEOUT=2 part; r=$?
[[ "$r" == 124 ]] && pass "8. a run past PRE_PUSH_E2E_TIMEOUT stops with rc 124" || fail "8. time cap: rc $r"

# --- 9. the stamp -----------------------------------------------------------------------------
cat >"$T/pnpm" <<'EOF2'
#!/bin/bash
echo "${NUXT_PUBLIC_BUILD_COMMIT:-}"
EOF2
chmod +x "$T/pnpm"
got="$( _pp_pnpm() { echo "$T/pnpm"; }; cd "$W" && _ppe_generate )"
[[ "$got" =~ ^[0-9a-f]{40}$ && "$got" == "$(g rev-parse HEAD)" ]] && pass "9. _ppe_generate stamps the bundle with HEAD ($got)" \
  || fail "9. the bundle stamp is '$got', want HEAD $(g rev-parse HEAD)"

# --- 10. the direct test first ------------------------------------------------------------
got="$(PRE_PUSH_E2E_MAX=1 sel csi-spl-wui/src/components/DockBox.vue)"
[[ "$(runs <<<"$got")" == "tests/e2e/dock-chip.test.mjs" ]] && grep -q '^CUT tests/e2e/dock-host.test.mjs ' <<<"$got" \
  && pass "10. DockBox.vue under MAX=1 keeps its data-test test (dock-chip), cuts the generic one (dock-host)" \
  || fail "10. DockBox.vue under MAX=1 gave '$got'"
# --- CONTROL d. the generic test outscores it ---------------------------------------------
sd="$(awk '$1 == "tests/e2e/dock-chip.test.mjs" { print $2 }' <<<"$got")"
sh="$(awk '$2 == "tests/e2e/dock-host.test.mjs" { print $3 }' <<<"$got")"
[[ -n "$sd" && -n "$sh" && "$sh" -gt "$sd" ]] \
  && pass "CONTROL d. dock-host scores $sh > dock-chip $sd, so check 10's order is the direct tier, not the score" \
  || fail "CONTROL d. want dock-host to outscore dock-chip, got '$sh' vs '$sd': check 10 proves nothing"

# --- CONTROL a. no users-of step ----------------------------------------------------------
got="$( _ppe_names() { :; }; sel csi-spl-wui/src/composables/useThing.ts | runs )"
[[ -z "$got" ]] && pass "CONTROL a. without the users-of step useThing.ts selects nothing, so check 2 needs the closure" \
  || fail "CONTROL a. useThing.ts still selected '$got' without the closure: check 2 proves nothing"
# --- CONTROL b. dirty source -> no cache ----------------------------------------------------
: >"$T/builds"; echo '<!-- wip -->' >>"$W/src/components/FooBar.vue"
part; part
[[ "$(wc -l <"$T/builds")" == 2 ]] && pass "CONTROL b. a dirty WUI source builds every run (2 for 2), so check 7's re-use comes from the key" \
  || fail "CONTROL b. want 2 builds on a dirty tree, got $(wc -l <"$T/builds")"

# --- CONTROL c. no git tree -> no stamp -----------------------------------------------------
mkdir -p "$T/nogit"
got="$( _pp_pnpm() { echo "$T/pnpm"; }; cd "$T/nogit" && GIT_CEILING_DIRECTORIES="$T" _ppe_generate )"
[[ -z "$got" ]] && pass "CONTROL c. outside a git tree the stamp is empty, so check 9's commit comes from HEAD" \
  || fail "CONTROL c. want no stamp outside a git tree, got '$got'"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all check-pre-push-e2e.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in check-pre-push-e2e.tst.sh"
fi
[[ $fails -eq 0 ]]
