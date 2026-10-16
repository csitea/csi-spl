#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: Cloud Run radar step 6 (SPL-2251) -- the hub reads every Secret
#          Manager secret at a PINNED version, never `latest`:
#          - cnf hub.secret_versions (dev, prd) maps each secret id to a
#            version number; 030's tfvars carry secret_versions with exactly
#            the injected secrets (secret_environment_variables' values), each
#            a number;
#          - 04 injects lookup(var.secret_versions, ...) and holds no
#            "latest"; its precondition fails a plan with an unpinned secret;
#            02 refuses a pin that is not a number.
#          CONTROL: a scratch render with one pin removed misses that secret
#          (the check below then fails), and a pin of a non-injected secret is
#          never rendered; a missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
TFD="$PROJ_ROOT/src/terraform/030-cloud-run-hub"

# pins_match <tfvars text> - prints "OK <n>" when secret_versions holds every
# injected secret id once, each a version number, and nothing else; else why.
pins_match() {
  python3 -c '
import json, re, sys
t = sys.stdin.read()
def m(k):
    r = re.search(r"^" + k + r"\s*=\s*(\{.*\})\s*$", t, re.M)
    return json.loads(r.group(1)) if r else None
sec, ver = m("secret_environment_variables"), m("secret_versions")
if sec is None or ver is None: print("no secret_environment_variables or secret_versions line"); sys.exit()
want = set(sec.values())
miss, extra = sorted(want - set(ver)), sorted(set(ver) - want)
bad = sorted(k for k, v in ver.items() if not re.fullmatch(r"[1-9][0-9]*", str(v)))
print(f"OK {len(want)}" if not (miss or extra or bad) else f"missing={miss} extra={extra} not-a-number={bad}")'
}

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  r=$(pins_match <"$v")
  [[ "$r" == OK* ]] && pass "$env 030 pins all ${r#OK } injected secrets to a version number" || fail "$env 030 pins: $r"
  n=$(yq -r '.env.hub.secret_versions // {} | length' "$CNF/$env.env.json")
  [[ "$n" -gt 0 ]] && pass "$env cnf hub.secret_versions holds $n pins" || fail "$env cnf has no hub.secret_versions"
done

f04="$TFD/04-cloud-run-service.tf"
grep -q '"latest"' "$f04" && fail "04 still names version latest" || pass "04 names no latest version"
grep -q 'version = lookup(var.secret_versions, env.value, "")' "$f04" \
  && pass "04 injects each secret at its secret_versions pin" || fail "04 does not read var.secret_versions"
grep -q 'setsubtract(toset(values(var.secret_environment_variables)), toset(keys(var.secret_versions)))' "$f04" \
  && grep -q 'precondition {' "$f04" && pass "04 precondition fails a plan with an unpinned secret" || fail "04 lacks the unpinned-secret precondition"
grep -q 'regex("^\[1-9\]\[0-9\]\*\$", v)' "$TFD/02-variables.tf" \
  && pass "02 refuses a pin that is not a version number" || fail "02 lacks the secret_versions validation"

# --- control: a removed pin is caught, a non-injected pin is never rendered --
TPG="$APP_ROOT/tpl-gen/src/python/tpl-gen"
[[ -x "$TPG/.venv/bin/python" ]] || TPG="${TPL_GEN_PATH:-/nonexistent}/src/python/tpl-gen"
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
  r=$(render | pins_match)
  [[ "$r" == OK* ]] && pass "control: the scratch render matches (${r#OK } pins)" || fail "control baseline: $r"
  yq -i 'del(.env.hub.secret_versions["csi-spl-hub-db-dsn"])' "$tmp/dev.env.yaml"
  r=$(render | pins_match)
  [[ "$r" == *"missing=['csi-spl-hub-db-dsn']"* ]] && pass "control: a removed pin is caught ($r)" || fail "control removed pin: $r"
  yq -i '.env.hub.secret_versions["csi-spl-hub-db-dsn"] = "2" | .env.hub.secret_versions["csi-spl-hub-auth-xai-client-secret"] = "1"' "$tmp/dev.env.yaml"
  r=$(render | pins_match)
  [[ "$r" == OK* ]] && pass "control: a pin of a non-injected secret is not rendered" || fail "control extra pin: $r"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $APP_ROOT/tpl-gen or \$TPL_GEN_PATH (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
