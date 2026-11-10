#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tpl_gen writes <env>.env.json only when a value changed
#          (_tpl_gen_write_json, SPL-5199). The prune cron's push ran the
#          pre-push cnf part in the main checkout every hour; the box's yq
#          printed 1.0 as 1, and the rewrite of an equal file dirtied it.
#   1. equal values, other number formatting -> the file keeps its bytes
#   2. a changed value -> the file is rewritten with it
#   3. no file yet -> written
#   CONTROL: a file that is not JSON -> rewritten (the compare must not pass
#   on a jq error)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# shellcheck source=/dev/null
source "$PROJ_ROOT/src/bash/run/tpl-gen.func.sh"
# shellcheck source=/dev/null
source "$PROJ_ROOT/lib/bash/funcs/require-bin.func.sh"
do_log() { echo "$*"; }

printf 'env:\n  rate: 1.0\n  price: 5.00\n  pcts: [0.5, 1.0]\n' >"$T/in.yaml"
# compact, one line: no yq version prints it this way
committed='{"env":{"rate":1.0,"price":5.00,"pcts":[0.5,1.0]}}'

printf '%s\n' "$committed" >"$T/eq.json"
_tpl_gen_write_json "$T/in.yaml" "$T/eq.json"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/eq.json")" == "$committed" ]] \
  && pass "equal values: the file keeps its bytes" || fail "equal values: rc=$rc, rewritten to $(tr -d ' \n' <"$T/eq.json")"

printf '%s\n' '{"env":{"rate":0.5,"price":5.00,"pcts":[0.5,1.0]}}' >"$T/chg.json"
_tpl_gen_write_json "$T/in.yaml" "$T/chg.json"; rc=$?
[[ $rc -eq 0 ]] && jq -e '.env.rate == 1' "$T/chg.json" >/dev/null \
  && pass "a changed value: rewritten" || fail "a changed value: rc=$rc, $(tr -d ' \n' <"$T/chg.json")"

_tpl_gen_write_json "$T/in.yaml" "$T/new.json"; rc=$?
[[ $rc -eq 0 ]] && jq -e '.env.price == 5' "$T/new.json" >/dev/null \
  && pass "no file yet: written" || fail "no file yet: rc=$rc"

echo 'not json' >"$T/bad.json"
_tpl_gen_write_json "$T/in.yaml" "$T/bad.json"; rc=$?
[[ $rc -eq 0 ]] && jq -e '.env.rate == 1' "$T/bad.json" >/dev/null \
  && pass "control: a file that is not JSON is rewritten" || fail "control: not-JSON file kept: $(cat "$T/bad.json")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
