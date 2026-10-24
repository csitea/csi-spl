#!/usr/bin/env bash
# The internal/store Postgres run is split into sequential processes
# (store-pg-groups.inc.sh, run by hub-pg.tst.sh). Every test `go test -list`
# names in internal/store runs in exactly ONE process: the wsdoc run or one
# store group (none lost, none twice), and hub-pg.tst.sh runs every group.
# CONTROLS: each group dropped in turn goes red naming a test that runs in 0
# processes; a group listed twice goes red naming a test that runs in 2.
# No Postgres needed: -list only compiles the package.
# Usage: bash csi-spl-api/src/bash/tests/store-pg-groups.tst.sh
set -euo pipefail
# -trimpath: worktrees share the build cache (SPL-3171, see run-all-tests.sh)
export GOFLAGS="-mod=mod -trimpath" GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path
# shellcheck source=store-pg-groups.inc.sh
source "$HERE/store-pg-groups.inc.sh"
MOD="$HERE/../../go/spool-hub-api"

tests="$(cd "$MOD" && go test -list . ./internal/store/ | grep -E '^(Test|Fuzz|Example)')"
n_tests="$(grep -c . <<<"$tests")"
[ "$n_tests" -gt 0 ] || { echo "FAIL - go test -list found no store tests"; exit 1; }

# coverage <group>...: prints "<runs> <test>" per test, where runs counts the
# processes that select it: the wsdoc run plus each group whose -run matches
# and whose -skip does not, the selection hub-pg.tst.sh passes to go test.
coverage() {
  local g sel=()
  for g in "$@"; do sel+=("$(store_pg_group_run "$g")" "$(store_pg_group_skip "$g")"); done
  awk -v wsdoc="$STORE_PG_WSDOC" -v sel="$(printf '%s\n' "${sel[@]}")" '
    BEGIN { n = split(sel, re, "\n") }
    { runs = ($0 ~ wsdoc); for (i = 1; i < n; i += 2) if ($0 ~ re[i] && $0 !~ re[i + 1]) runs++; print runs, $0 }' <<<"$tests"
}
# check <group>...: 0 when every test runs exactly once, else prints the first offender
check() {
  local bad
  bad="$(coverage "$@" | awk '$1 != 1 && !bad++')" # reads it all: no early exit under pipefail
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}

fails=0
if out="$(check "${STORE_PG_GROUPS[@]}")"; then
  echo "ok   - all $n_tests store tests run in exactly one process (wsdoc + groups ${STORE_PG_GROUPS[*]})"
else echo "FAIL - store test not run exactly once: '$out' (runs, test)"; fails=$((fails + 1)); fi

for g in "${STORE_PG_GROUPS[@]}"; do
  n_sel="$(coverage "$g" | awk -v ws="$STORE_PG_WSDOC" '$1 == 1 && $2 !~ ws' | wc -l)"
  echo "ok   - group $g (-run $(store_pg_group_run "$g") -skip $(store_pg_group_skip "$g")): $n_sel tests"
  [ "$n_sel" -gt 0 ] || { echo "FAIL - group $g selects no test"; fails=$((fails + 1)); }
  rest=()
  for h in "${STORE_PG_GROUPS[@]}"; do [ "$h" = "$g" ] || rest+=("$h"); done
  if out="$(check "${rest[@]}")"; then
    echo "FAIL - CONTROL: with group $g dropped every test still ran once"; fails=$((fails + 1))
  elif [ "${out%% *}" = 0 ]; then echo "ok   - CONTROL: group $g dropped -> red, '$out' runs in 0 processes"
  else echo "FAIL - CONTROL: group $g dropped went red for the wrong reason: '$out'"; fails=$((fails + 1)); fi
done

g="${STORE_PG_GROUPS[0]}"
if out="$(check "${STORE_PG_GROUPS[@]}" "$g")"; then
  echo "FAIL - CONTROL: group $g listed twice stayed green"; fails=$((fails + 1))
elif [ "${out%% *}" = 2 ]; then echo "ok   - CONTROL: group $g listed twice -> red, '$out' runs in 2 processes"
else echo "FAIL - CONTROL: group $g listed twice went red for the wrong reason: '$out'"; fails=$((fails + 1)); fi

# hub-pg.tst.sh must run each group, by this list, with this selection.
# shellcheck disable=SC2016 # the literal source lines, not their expansion
for want in 'for g in "${STORE_PG_GROUPS[@]}"' '-run "$(store_pg_group_run "$g")" -skip "$(store_pg_group_skip "$g")"' '-run "$STORE_PG_WSDOC"'; do
  if grep -qF -- "$want" "$HERE/hub-pg.tst.sh"; then echo "ok   - hub-pg.tst.sh carries: $want"
  else echo "FAIL - hub-pg.tst.sh lost: $want"; fails=$((fails + 1)); fi
done

[ "$fails" -eq 0 ] || { echo "FAIL - store-pg-groups: $fails failure(s)"; exit 1; }
echo "ALL store-pg-groups CHECKS PASSED"
