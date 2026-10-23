#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 025 box owner lock 6.4 (row B6, SPL-3014) -- cnf
#          hub.box_locks_expected reaches the hub as ONE plain env value,
#          SPOOL_HUB_BOX_LOCKS_EXPECTED: "<tenant>:<box>:<lock_pubkey>"
#          entries joined with commas, "" for an empty list.
#          CONTROL: a scratch render with two entries; a missing tpl-gen
#          venv is a SKIP. No real box or key: fixture values only.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
ENVVAR=SPOOL_HUB_BOX_LOCKS_EXPECTED
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
grep -qF "env:\"$ENVVAR\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
  && pass "the hub reads exactly $ENVVAR (config.go BoxLocksExpected)" || fail "config.go does not name $ENVVAR"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  want=$(yq -r '[.env.hub.box_locks_expected[] | .tenant + ":" + .box + ":" + .lock_pubkey] | join(",")' "$CNF/$env.env.json")
  grep -E '^environment_variables ' "$v" | grep -F "\"$ENVVAR\": \"$want\"" >/dev/null \
    && pass "$env 030 carries $ENVVAR=\"$want\" from cnf" || fail "$env 030 lacks $ENVVAR=\"$want\""
done

# --- control: two entries render as one comma-joined value ------------------
TPG="$APP_ROOT/tpl-gen/src/python/tpl-gen"
if [[ -x "$TPG/.venv/bin/python" ]]; then
  tmp=$(mktemp -d)
  # shellcheck disable=SC1091
  source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"
  do_spl_merged_cnf "$CNF" dev "$tmp/dev.env.yaml"
  render() { (cd "$TPG" && TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl" CNF="$tmp/dev.env.yaml" \
    .venv/bin/python -c '
import os, yaml, jinja2
cnf = yaml.safe_load(open(os.environ["CNF"]))["env"]
tpl = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(open(os.environ["TPL"]).read())
print(tpl.render(**{**cnf, "ORG": "csi", "APP": "spl", "ENV": "dev"}))' 2>&1); }
  k1=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  k2=/////////////////////////////////////////w=
  yq -i ".env.hub.box_locks_expected = [{\"tenant\": \"ws-a\", \"box\": \"box-a\", \"lock_pubkey\": \"$k1\"}, {\"tenant\": \"ws-b\", \"box\": \"box-b\", \"lock_pubkey\": \"$k2\"}]" "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"ws-a:box-a:$k1,ws-b:box-b:$k2\"" >/dev/null \
    && pass "control: two entries render comma-joined" || fail "control list: $(head -c 300 <<<"$out")"
  yq -i '.env.hub.box_locks_expected = []' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"\"" >/dev/null \
    && pass "control: an empty list renders \"\"" || fail "control empty: $(head -c 300 <<<"$out")"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
