#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 158 10.6 item 3 (row P2, SPL-5020) -- cnf
#          hub.box_wui_pin_sweep reaches the hub as SPOOL_HUB_BOX_WUI_PIN_SWEEP,
#          "true" or "false"; no key renders "false" (the hub's default).
#          CONTROL: a scratch render with the key true, then with it removed;
#          a missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
ENVVAR=SPOOL_HUB_BOX_WUI_PIN_SWEEP
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
grep -qF "env:\"$ENVVAR\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
  && pass "the hub reads exactly $ENVVAR (config.go BoxWUIPinSweep)" || fail "config.go does not name $ENVVAR"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  want=$(yq -r '.env.hub.box_wui_pin_sweep // false' "$CNF/$env.env.json")
  grep -E '^environment_variables ' "$v" | grep -F "\"$ENVVAR\": \"$want\"" >/dev/null \
    && pass "$env 030 carries $ENVVAR=\"$want\" from cnf" || fail "$env 030 lacks $ENVVAR=\"$want\""
done

# --- control: true renders "true", no key renders "false" ---------------------
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
  yq -i '.env.hub.box_wui_pin_sweep = true' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"true\"" >/dev/null \
    && pass "control: true renders \"true\"" || fail "control true: ${out:0:300}"
  yq -i 'del(.env.hub.box_wui_pin_sweep)' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"false\"" >/dev/null \
    && pass "control: no key renders \"false\"" || fail "control no key: ${out:0:300}"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
