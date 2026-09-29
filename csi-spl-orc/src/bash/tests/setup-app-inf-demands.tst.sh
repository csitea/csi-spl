#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the infra stack targets demand only what the stack reads
#          (spec 047 W8, SPL-1168). Nothing in src/docker reads
#          BITBUCKET_APP_PASSWORD, so no setup-app-inf target may demand it,
#          and every compose call in those targets names the compose file
#          (a mistyped var expands empty: `docker compose -f  down`).
#          1. `grep -c BITBUCKET setup-app-inf.func.mk` -> 0 (the W8 metric)
#          2. `make -n` of each target with only GITHUB_TOKEN set renders no
#             BITBUCKET demand (make -n prints a demand_var recipe, it does not run it)
#          3. each rendered `docker compose -f` carries a compose file
#          CONTROL: the same `make -n` with a demand_var-BITBUCKET_APP_PASSWORD
#          prerequisite planted renders the demand, so check 2 can see a stray demand.
#          Static, needs make only; no container is started.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
MK=src/make/setup-app-inf.func.mk
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

cd "$ORC" || exit 1
n=$(grep -c BITBUCKET "$MK")
[[ "$n" == 0 ]] && pass "grep -c BITBUCKET $MK -> 0" || fail "grep -c BITBUCKET $MK -> $n"
[[ -z "$(grep -rl BITBUCKET src/docker 2>/dev/null)" ]] && pass "nothing in src/docker reads BITBUCKET_*" \
  || fail "src/docker reads BITBUCKET_*: the demand may be needed after all"

for tgt in do-setup-app-inf do-setup-app-inf-no-cache do-setup-app-inf-up do-echo-setup-app-inf; do
  out=$(env -u BITBUCKET_APP_PASSWORD GITHUB_TOKEN=x make --no-print-directory -n "$tgt" 2>&1); rc=$?
  if (( rc == 0 )) && ! grep -q 'BITBUCKET' <<<"$out"; then
    pass "make -n $tgt with only GITHUB_TOKEN set"
  else
    fail "make -n $tgt (rc $rc): $(grep -m1 -i 'not set\|error' <<<"$out")"
  fi
  if grep -qE 'compose -f +(down|up|build|--verbose)' <<<"$out"; then
    fail "make -n $tgt renders a docker compose -f with no file"
  else
    pass "make -n $tgt: every docker compose -f names its file"
  fi
done

# CONTROL: a planted demand must turn check 2 red
out=$(env -u BITBUCKET_APP_PASSWORD GITHUB_TOKEN=x make --no-print-directory -n \
  --eval 'zz-ctl: demand_var-BITBUCKET_APP_PASSWORD ; @true' zz-ctl 2>&1)
grep -q BITBUCKET <<<"$out" && pass "control: a planted BITBUCKET demand is seen by check 2" \
  || fail "control: a planted BITBUCKET demand passed make -n without rendering it (check 2 is blind)"

echo "fails=$fails"
exit $(( fails > 0 ))
