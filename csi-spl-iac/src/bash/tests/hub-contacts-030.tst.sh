#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 154 S4 (SPL-4263) -- cnf contacts reaches the hub as
#          SPOOL_HUB_CONTACTS_WORKSPACES (the workspace ids joined with
#          commas, or the literal "all") and SPOOL_HUB_CONTACTS_SCOPES;
#          nothing while contacts.workspaces is empty (off: every
#          /v1/me/contacts route answers 404).
#          CONTROL: a scratch render with [] (no SPOOL_HUB_CONTACTS_ key) and
#          with a list; a missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
CFG="$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go"
for v in WORKSPACES SCOPES; do
  grep -qF "env:\"SPOOL_HUB_CONTACTS_$v\"" "$CFG" \
    && pass "the hub reads SPOOL_HUB_CONTACTS_$v" || fail "config.go does not name SPOOL_HUB_CONTACTS_$v"
done

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  want=$(yq -r '.env.contacts.workspaces | (select(type == "!!seq") | join(",")) // .' "$CNF/$env.env.json")
  line=$(grep -E '^environment_variables ' "$v")
  if [[ -z "$want" ]]; then
    grep -qF '"SPOOL_HUB_CONTACTS_' <<<"$line" \
      && fail "$env 030 carries SPOOL_HUB_CONTACTS_* while contacts.workspaces is empty" || pass "$env 030: contacts off, no SPOOL_HUB_CONTACTS_*"
    continue
  fi
  grep -qF "\"SPOOL_HUB_CONTACTS_WORKSPACES\": \"$want\"" <<<"$line" \
    && pass "$env 030 carries SPOOL_HUB_CONTACTS_WORKSPACES=\"$want\" from cnf" || fail "$env 030 lacks SPOOL_HUB_CONTACTS_WORKSPACES=\"$want\""
  scopes=$(yq -r '.env.contacts.scopes' "$CNF/$env.env.json")
  grep -qF "\"SPOOL_HUB_CONTACTS_SCOPES\": \"$scopes\"" <<<"$line" \
    && pass "$env 030 carries SPOOL_HUB_CONTACTS_SCOPES=\"$scopes\"" || fail "$env 030 lacks SPOOL_HUB_CONTACTS_SCOPES"
done

# --- control: [] renders no contacts key, a list joins with commas ----------
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
  yq -i '.env.contacts.workspaces = []' "$tmp/dev.env.yaml"
  out=$(render)
  if grep -qE '^environment_variables ' <<<"$out"; then
    grep -E '^environment_variables ' <<<"$out" | grep -F '"SPOOL_HUB_CONTACTS_' >/dev/null \
      && fail "control []: a SPOOL_HUB_CONTACTS_ key rendered" || pass "control: [] renders no SPOOL_HUB_CONTACTS_ key"
  else
    fail "control []: no render: $(head -c 300 <<<"$out")"
  fi
  yq -i '.env.contacts.workspaces = ["t1", "ws-a"]' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F '"SPOOL_HUB_CONTACTS_WORKSPACES": "t1,ws-a"' >/dev/null \
    && pass "control: a list renders comma-joined" || fail "control list: $(head -c 300 <<<"$out")"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
