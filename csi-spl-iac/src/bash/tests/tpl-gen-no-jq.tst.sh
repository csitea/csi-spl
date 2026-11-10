#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tpl_gen refuses to run without jq (SPL-5242, W2 of SPL-5199's
#          review). _tpl_gen_write_json skips the write when jq says the
#          values are equal; a jq that is not there "fails" that compare, so
#          the json was rewritten with no message: the unconditional write of
#          SPL-5199, back in silence.
#   1. jq off PATH -> do_tpl_gen returns non-zero with one FATAL line, and
#      the committed <env>.env.json keeps its bytes
#   CONTROL: the same scratch tree with jq on PATH renders (rc 0), so case 1
#   fails on the missing jq and not on the scratch tree
# A scratch APP_PATH holds a fake tpl-gen (a git repo pinned by its own
# cnf/tpl-gen.ref, a venv python that does nothing): no network, no render.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for f in "$PROJ_ROOT"/lib/bash/funcs/{resolve-oap,require-var,require-bin,spl-merged-cnf,spl-private-cnf}.func.sh \
  "$PROJ_ROOT/src/bash/run/tpl-gen.func.sh"; do
  # shellcheck source=/dev/null
  source "$f"
done
do_log() { echo "$*"; }

APP_PATH="$T/app"; PROJ_PATH="$APP_PATH/csi-spl-iac"
cnf="$APP_PATH/csi-spl-cnf/csi-spl"
venv="$APP_PATH/tpl-gen/src/python/tpl-gen/.venv/bin"
mkdir -p "$cnf" "$PROJ_PATH/cnf" "$venv"
printf 'env:\n  rate: 1.0\n  dns:\n    BASE_DOMAIN: example.com\n' >"$cnf/all.env.yaml"
printf 'env:\n  price: 5.00\n' >"$cnf/dev.env.yaml"
printf '#!/bin/sh\nexit 0\n' >"$venv/python"; chmod +x "$venv/python"
git -C "$APP_PATH/tpl-gen" init -q
git -C "$APP_PATH/tpl-gen" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m t
git -C "$APP_PATH/tpl-gen" rev-parse HEAD >"$PROJ_PATH/cnf/tpl-gen.ref"
# a value that differs from the render: any write shows
committed='{"env":{"rate":0.5}}'
printf '%s\n' "$committed" >"$cnf/dev.env.json"
export APP_PATH PROJ_PATH ENV=dev ORG=csi APP=spl

# a PATH with every command of the box but jq
mkdir -p "$T/nojq"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
  for b in "$d"/*; do
    n=${b##*/}
    [[ -x "$b" && "$n" != jq && ! -e "$T/nojq/$n" ]] && ln -s "$b" "$T/nojq/$n"
  done
done

out=$(PATH="$T/nojq" do_tpl_gen 2>&1); rc=$?
nfatal=$(grep -c FATAL <<<"$out")
[[ $rc -ne 0 && "$nfatal" -eq 1 && "$(cat "$cnf/dev.env.json")" == "$committed" ]] \
  && pass "no jq: rc=$rc, one FATAL line, json kept" \
  || fail "no jq: rc=$rc, $nfatal FATAL line(s), json now $(tr -d ' \n' <"$cnf/dev.env.json")"

out=$(do_tpl_gen 2>&1); rc=$?
[[ $rc -eq 0 ]] && jq -e '.env.rate == 1' "$cnf/dev.env.json" >/dev/null \
  && pass "control: with jq the scratch tree renders" || fail "control: with jq rc=$rc: $out"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
