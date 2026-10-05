#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 090 switch -- the outer marketing allow-list, cnf
#          marketing.workspaces, reaches the hub as ONE plain env value,
#          SPOOL_HUB_MARKETING_WORKSPACES: the workspace ids joined with
#          commas, or the literal "all" (any workspace may turn it on).
#          CONTROL: a scratch render with a list and with "all"; a missing
#          tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
ENVVAR=SPOOL_HUB_MARKETING_WORKSPACES
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
grep -qF "env:\"$ENVVAR\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
  && pass "the hub reads exactly $ENVVAR (config.go MarketingWorkspaces)" || fail "config.go does not name $ENVVAR"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  want=$(yq -r '.env.marketing.workspaces | (select(type == "!!seq") | join(",")) // .' "$CNF/$env.env.json")
  grep -E '^environment_variables ' "$v" | grep -F "\"$ENVVAR\": \"$want\"" >/dev/null \
    && pass "$env 030 carries $ENVVAR=\"$want\" from cnf" || fail "$env 030 lacks $ENVVAR=\"$want\""
done

# --- control: a list joins with commas, the string "all" passes through -----
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
  yq -i '.env.marketing.workspaces = ["t1", "spool"]' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"t1,spool\"" >/dev/null \
    && pass "control: a list renders comma-joined" || fail "control list: $(head -c 300 <<<"$out")"
  yq -i '.env.marketing.workspaces = "all"' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"all\"" >/dev/null \
    && pass "control: \"all\" renders as all" || fail "control all: $(head -c 300 <<<"$out")"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
