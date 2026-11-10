#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: `make do-spl-merged-cnf` (the make tf-render path) writes
#          <env>.env.json only when a value changed, through the same
#          _tpl_gen_write_json as do_tpl_gen (SPL-5242, W1 of SPL-5199's
#          review). It wrote `yq -o json .` unconditionally, so a committed
#          json that formats a number another way (1.0 vs the box yq's 1)
#          was dirtied by every render.
#   1. equal values, other number formatting -> the file keeps its bytes
#   2. a changed value -> rewritten
#   3. jq off PATH -> the target fails with one FATAL line, json kept
# The target runs against a scratch APP_PATH (a copy of the iac lib and the
# tpl-gen action, a two-key cnf): no docker, no terraform, no live cnf.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

A="$T/app"; cnf="$A/csi-spl-cnf/csi-spl"
mkdir -p "$cnf" "$A/csi-spl-iac/lib/bash" "$A/csi-spl-iac/src/bash/run"
cp -r "$ORC/../csi-spl-iac/lib/bash/funcs" "$A/csi-spl-iac/lib/bash/"
cp "$ORC/../csi-spl-iac/src/bash/run/tpl-gen.func.sh" "$A/csi-spl-iac/src/bash/run/"
# env_subdomain "" as prd's cnf has it: with no key the derived fqdn is
# null + "." + BASE_DOMAIN, which yq versions print differently (the box
# example.com, CI's .example.com), so the expected json would drift.
printf 'env:\n  rate: 1.0\n  dns:\n    BASE_DOMAIN: example.com\n    env_subdomain: ""\n' >"$cnf/all.env.yaml"
printf 'env:\n  price: 5.00\n' >"$cnf/dev.env.yaml"

# run_make [PATH] -> output; rc in $rc
run_make() {
  out=$(cd "$ORC" && env PATH="${1:-$PATH}" SPL_PRIVATE_CNF=/nonexistent \
    make --no-print-directory APP_PATH="$A" ENV=dev do-spl-merged-cnf 2>&1); rc=$?
}

# compact, 1.0 / 5.00: no yq version prints it this way
committed='{"env":{"rate":1.0,"dns":{"BASE_DOMAIN":"example.com","env_subdomain":"","fqdn":"example.com","api_fqdn":"api.example.com"},"price":5.00}}'
printf '%s\n' "$committed" >"$cnf/dev.env.json"
run_make
[[ $rc -eq 0 && "$(cat "$cnf/dev.env.json")" == "$committed" ]] \
  && pass "equal values: the file keeps its bytes" \
  || fail "equal values: rc=$rc, rewritten to $(tr -d ' \n' <"$cnf/dev.env.json") $out"

printf '%s\n' '{"env":{"rate":0.5}}' >"$cnf/dev.env.json"
run_make
[[ $rc -eq 0 ]] && jq -e '.env.rate == 1 and .env.price == 5' "$cnf/dev.env.json" >/dev/null \
  && pass "a changed value: rewritten" || fail "a changed value: rc=$rc, $(tr -d ' \n' <"$cnf/dev.env.json")"

mkdir -p "$T/nojq"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
  for b in "$d"/*; do
    n=${b##*/}
    [[ -x "$b" && "$n" != jq && ! -e "$T/nojq/$n" ]] && ln -s "$b" "$T/nojq/$n"
  done
done
printf '%s\n' '{"env":{"rate":0.5}}' >"$cnf/dev.env.json"
run_make "$T/nojq"
nfatal=$(grep -c FATAL <<<"$out")
[[ $rc -ne 0 && "$nfatal" -eq 1 && "$(cat "$cnf/dev.env.json")" == '{"env":{"rate":0.5}}' ]] \
  && pass "no jq: rc=$rc, one FATAL line, json kept" \
  || fail "no jq: rc=$rc, $nfatal FATAL line(s), json now $(tr -d ' \n' <"$cnf/dev.env.json")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
