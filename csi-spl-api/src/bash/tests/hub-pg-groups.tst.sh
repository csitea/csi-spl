#!/usr/bin/env bash
# The internal/hub Postgres run is split into sequential processes
# (hub-pg-groups.inc.sh, run by hub-pg.tst.sh). Every test `go test -list`
# names in internal/hub runs in exactly ONE group process (none lost, none
# twice), and hub-pg.tst.sh runs every group. CONTROLS: each group dropped in
# turn goes red naming a test that runs in 0 processes; a group listed twice
# goes red naming a test that runs in 2.
# No Postgres needed: -list only compiles the package.
# Usage: bash csi-spl-api/src/bash/tests/hub-pg-groups.tst.sh
set -euo pipefail
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path
# shellcheck source=hub-pg-groups.inc.sh
source "$HERE/hub-pg-groups.inc.sh"
MOD="$HERE/../../go/spool-hub-api"

tests="$(cd "$MOD" && go test -list . ./internal/hub/ | grep -E '^(Test|Fuzz|Example)')"
n_tests="$(grep -c . <<<"$tests")"
[ "$n_tests" -gt 0 ] || { echo "FAIL - go test -list found no hub tests"; exit 1; }

# coverage <group>...: prints "<runs> <test>" per test, where runs counts the
# groups whose -run selects it, the selection hub-pg.tst.sh passes to go test.
coverage() {
  local g sel=()
  for g in "$@"; do sel+=("$(hub_pg_group_run "$g")"); done
  awk -v sel="$(printf '%s\n' "${sel[@]}")" '
    BEGIN { n = split(sel, re, "\n") }
    { runs = 0; for (i = 1; i <= n; i++) if ($0 ~ re[i]) runs++; print runs, $0 }' <<<"$tests"
}
# check <group>...: 0 when every test runs exactly once, else prints the first offender
check() {
  local bad
  bad="$(coverage "$@" | awk '$1 != 1 && !bad++')" # reads it all: no early exit under pipefail
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}

fails=0
if out="$(check "${HUB_PG_GROUPS[@]}")"; then
  echo "ok   - all $n_tests hub tests run in exactly one process (groups ${HUB_PG_GROUPS[*]})"
else echo "FAIL - hub test not run exactly once: '$out' (runs, test)"; fails=$((fails + 1)); fi

for g in "${HUB_PG_GROUPS[@]}"; do
  n_sel="$(coverage "$g" | awk '$1 == 1' | wc -l)"
  echo "ok   - group $g (-run $(hub_pg_group_run "$g")): $n_sel tests"
  [ "$n_sel" -gt 0 ] || { echo "FAIL - group $g selects no test"; fails=$((fails + 1)); }
  rest=()
  for h in "${HUB_PG_GROUPS[@]}"; do [ "$h" = "$g" ] || rest+=("$h"); done
  if out="$(check "${rest[@]}")"; then
    echo "FAIL - CONTROL: with group $g dropped every test still ran once"; fails=$((fails + 1))
  elif [ "${out%% *}" = 0 ]; then echo "ok   - CONTROL: group $g dropped -> red, '$out' runs in 0 processes"
  else echo "FAIL - CONTROL: group $g dropped went red for the wrong reason: '$out'"; fails=$((fails + 1)); fi
done

g="${HUB_PG_GROUPS[0]}"
if out="$(check "${HUB_PG_GROUPS[@]}" "$g")"; then
  echo "FAIL - CONTROL: group $g listed twice stayed green"; fails=$((fails + 1))
elif [ "${out%% *}" = 2 ]; then echo "ok   - CONTROL: group $g listed twice -> red, '$out' runs in 2 processes"
else echo "FAIL - CONTROL: group $g listed twice went red for the wrong reason: '$out'"; fails=$((fails + 1)); fi

# hub-pg.tst.sh must run each group, by this list, with this selection.
# shellcheck disable=SC2016 # the literal source lines, not their expansion
for want in 'for g in "${HUB_PG_GROUPS[@]}"' 'pg_go_test spool_hub_hub hub "hub-$g" -run "$(hub_pg_group_run "$g")"' 'hub) hub_groups & ;;'; do
  if grep -qF -- "$want" "$HERE/hub-pg.tst.sh"; then echo "ok   - hub-pg.tst.sh carries: $want"
  else echo "FAIL - hub-pg.tst.sh lost: $want"; fails=$((fails + 1)); fi
done

[ "$fails" -eq 0 ] || { echo "FAIL - hub-pg-groups: $fails failure(s)"; exit 1; }
echo "ALL hub-pg-groups CHECKS PASSED"
