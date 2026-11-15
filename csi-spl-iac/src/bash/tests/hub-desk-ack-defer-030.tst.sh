#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: SPL-5594 (owner poll answer B on SPL-5514) -- cnf
#          box.desk_ack_defer_s (seconds) reaches the hub as ONE plain env
#          value, SPOOL_HUB_DESK_ACK_DEFER: "<n>s", so the unanswered
#          escalation waits the take / ack deferral plus the grace.
#          CONTROL: a scratch render with 45 -> "45s", and with the key
#          removed -> no variable; a missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
ENVVAR=SPOOL_HUB_DESK_ACK_DEFER
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
grep -qF "env:\"$ENVVAR\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
  && pass "the hub reads exactly $ENVVAR (config.go DeskAckDefer)" || fail "config.go does not name $ENVVAR"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  s=$(yq -r '.env.box.desk_ack_defer_s' "$CNF/$env.env.json")
  [[ "$s" =~ ^[0-9]+$ ]] || { fail "$env cnf box.desk_ack_defer_s is not a number: '$s'"; continue; }
  grep -E '^environment_variables ' "$v" | grep -F "\"$ENVVAR\": \"${s}s\"" >/dev/null \
    && pass "$env 030 carries $ENVVAR=\"${s}s\" from cnf" || fail "$env 030 lacks $ENVVAR=\"${s}s\""
done

# --- control: the value follows the cnf key; no key, no variable -----------
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
  yq -i '.env.box.desk_ack_defer_s = 45' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"45s\"" >/dev/null \
    && pass "control: desk_ack_defer_s 45 renders \"45s\"" || fail "control 45: $(head -c 300 <<<"$out")"
  yq -i 'del(.env.box.desk_ack_defer_s)' "$tmp/dev.env.yaml"
  out=$(render)
  envline=$(grep -E '^environment_variables ' <<<"$out")
  if [[ -n "$envline" ]] && ! grep -F "\"$ENVVAR\"" <<<"$envline" >/dev/null; then
    pass "control: no cnf key renders no $ENVVAR"
  else
    fail "control no key: $(head -c 300 <<<"$out")"
  fi
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
