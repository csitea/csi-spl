#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the wui-e2e part's baseline re-run (SPL-5345). A failed part is
#          re-run on the base ref with the same e2e file list; a file the push
#          ADDS is not on the base tree, and the e2e runner dies "file(s) not
#          found" before it runs anything. The base signature was then empty,
#          so a red that trunk shares read "NEW on your tree" (c-582's land,
#          e62913d0b: mobile-overlay-route.test.mjs). Hermetic: a throwaway
#          repo, a stub bundle build and a stub runner that behaves as
#          run-e2e-tests.mjs does (a missing path: die before any file runs).
#   1. the push adds new.test.mjs (green) and old.test.mjs is red on both
#      trees -> WARN pre-existing, and one INFO line names the left-out file
#   2. the added file is red too -> FAIL, NEW names only the added file; the
#      old one reads pre-existing
#   3. only the added file is selected (nothing is left on base) -> it says
#      so, and the verdict stays FAIL (today's)
#   4. control: old.test.mjs green on base, red on the tree -> FAIL (NEW)
#   Red control: PP_FUNC_FROM=<check-pre-push-e2e.func.sh before SPL-5345>
#   sources that part instead; 1, 2, 3 and 4 FAIL there (4: the base run dies
#   too, so the green trunk reads red).
#------------------------------------------------------------------------------
set -uo pipefail
unset PRE_PUSH_NO_CACHE PRE_PUSH_MODE PRE_PUSH_SKIP_PASSED PRE_PUSH_ONLY PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_CROSS PRE_PUSH_E2E PRE_PUSH_FEATURES 2>/dev/null || true
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
do_log() { echo "$*"; }
# shellcheck source=/dev/null
source "$FUNC"
# shellcheck disable=SC1090
[[ -n "${PP_FUNC_FROM:-}" ]] && . "$PP_FUNC_FROM"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

cat >"$T/gen" <<'EOF'
#!/bin/bash
mkdir -p .output/public/_nuxt; echo 'x' >.output/public/_nuxt/entry.js
for d in index 200; do echo '<script type="module" src="/_nuxt/entry.js"></script>' >".output/public/$d.html"; done
EOF
# as run-e2e-tests.mjs: a missing path dies before any file runs; a file
# holding RED prints the runner's FAIL line
cat >"$T/run" <<'EOF'
#!/bin/bash
missing=""; for f in "$@"; do [[ -f "$f" ]] || missing+="${missing:+, }$f"; done
[[ -z "$missing" ]] || { echo "e2e runner: file(s) not found: $missing"; exit 1; }
rc=0; for f in "$@"; do grep -q RED "$f" && { echo "  FAIL $f (exit 1)"; rc=1; }; done
exit "$rc"
EOF
chmod +x "$T/gen" "$T/run"

# repo <old-on-base> <old-on-tree> <new-on-tree>: base has old.test.mjs; the
# tree commit edits FooBar.vue (old.test.mjs names its testid) and adds
# new.test.mjs. Prints the repo path.
repo() {
  local R="$T/r$RANDOM$RANDOM" W
  W="$R/csi-spl-wui"
  mkdir -p "$W/src/components" "$W/tests/e2e" "$W/src/node/test" "$W/node_modules/.pnpm" \
    "$R/csi-spl-orc/src/bash/scripts" "$R/csi-spl-doc/specs/027-spool-performance/contracts"
  echo '<template><div data-testid="foo-panel" /></template>' >"$W/src/components/FooBar.vue"
  printf "await page.click('[data-testid=\"foo-panel\"]')\n%s\n" "$1" >"$W/tests/e2e/old.test.mjs"
  echo lock >"$W/pnpm-lock.yaml"; cp "$W/pnpm-lock.yaml" "$W/node_modules/.pnpm/lock.yaml"
  echo '.output' >"$R/.gitignore"
  cp "$PROJ_ROOT/../csi-spl-orc/src/bash/scripts/perf-budget.py" "$R/csi-spl-orc/src/bash/scripts/"
  echo '{"ceilings": {"ci_initial_gzip_kb": 2.0, "ci_home_gzip_kb": 2.0}}' \
    >"$R/csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json"
  { git -C "$R" init -q && git -C "$R" add -A && git -C "$R" commit -qm base && git -C "$R" branch trunkbase; } >/dev/null
  printf "await page.click('[data-testid=\"foo-panel\"]')\n%s\n" "$2" >"$W/tests/e2e/old.test.mjs"
  echo '<!-- edit -->' >>"$W/src/components/FooBar.vue"
  [[ -n "$3" ]] && printf "await page.click('[data-testid=\"foo-panel\"]')\n%s\n" "$3" >"$W/tests/e2e/new.test.mjs"
  { git -C "$R" add -A && git -C "$R" commit -qm tree; } >/dev/null
  echo "$R"
}

# verdict <repo> <changed> -> "<failed>|<stat>|<label>"; the gate's output in $T/out
verdict() {
  local R="$1" changed="$2"
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT="" _PP_TIER=fast
  export PRE_PUSH_E2E_GENERATE="$T/gen" PRE_PUSH_E2E_RUNNER="$T/run" PRE_PUSH_E2E_BUNDLES="$T/bundles" \
    CHROME_PATH=/bin/true TMPDIR="$T"
  _ppe_plan "$changed" "$R" || { echo "not-selected"; return; }
  _pp_run "wui-e2e" _pp_part_wui_e2e "$R" trunkbase >"$T/out" 2>&1
  _pp_baseline_cleanup "$R" >/dev/null 2>&1
  printf '%s|%s|%s' "$_PP_FAILED" "${_PP_STAT[0]:-}" "${_PP_NAMES[0]:-}"
}
show() { sed 's/^/    | /' "$T/out"; }
both=$'csi-spl-wui/src/components/FooBar.vue\ncsi-spl-wui/tests/e2e/new.test.mjs'

# --- 1. a lane-added file, a red trunk shares -------------------------------------
R="$(repo RED RED green)"; got="$(verdict "$R" "$both")"
if [[ "$got" == "0|WARN|"* ]] \
   && [[ "$(grep -c 'INFO wui-e2e: .*new.test.mjs' "$T/out")" == 1 ]] && ! grep -q 'file(s) not found' "$T/out"; then
  pass "1. the added file is left out on base, one INFO line names it; old.test.mjs red on both -> WARN pre-existing"
else
  fail "1. got '$got', want WARN pre-existing"; show
fi
# --- 2. the added file is red too: it alone is NEW ----------------------------------
R="$(repo RED RED RED)"; got="$(verdict "$R" "$both")"
if [[ "$got" == "1|FAIL|"*"NEW on your tree: e2e-file tests/e2e/new.test.mjs)" ]] \
   && grep -q 'pre-existing: e2e-file tests/e2e/old.test.mjs' "$T/out"; then
  pass "2. a red added file is NEW (no baseline); the shared red old.test.mjs reads pre-existing"
else
  fail "2. got '$got', want FAIL NEW naming new.test.mjs only"; show
fi
# --- 3. nothing left on base ----------------------------------------------------------
R="$(repo RED RED RED)"; got="$(verdict "$R" csi-spl-wui/tests/e2e/new.test.mjs)"
if [[ "$got" == "1|FAIL|"* ]] && grep -q 'no selected e2e file is on this tree' "$T/out"; then
  pass "3. only the added file selected: the base run says no file is left; the verdict stays FAIL"
else
  fail "3. got '$got', want FAIL and the no-file line"; show
fi
# --- 4. control: green trunk, a break on the tree -> NEW ------------------------------
R="$(repo green RED green)"; got="$(verdict "$R" "$both")"
if [[ "$got" == "1|FAIL|wui-e2e" ]] && grep -q 'a NEW failure your commits introduce' "$T/out"; then
  pass "4. control: old.test.mjs green on base, red on the tree -> FAIL (NEW)"
else
  fail "4. got '$got', want FAIL NEW"; show
fi

if [[ $fails -eq 0 ]]; then
  echo "PASS: all check-pre-push-e2e-baseline.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in check-pre-push-e2e-baseline.tst.sh"
fi
[[ $fails -eq 0 ]]
