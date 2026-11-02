#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 159 (SPL-4623) -- step 030 gives the hub its two vendor key
#          settings, so /v1/vendor-keys stops answering 503 vendor_keys_off:
#          - while cnf vendor_keys.inject is "true": SPOOL_HUB_VENDOR_KEYS_KMS_KEY
#            is the full CryptoKey name of step 057's key, a plain env value;
#            SPOOL_HUB_VENDOR_KEYS_PEPPER is a Secret Manager reference to 057's
#            slot at a pinned version, never a plain env value;
#          - 03's generic binding skips the slot: 057 owns the one member its
#            grant check allows, and 030 creates no slot and no version.
#          CONTROL: a scratch render flips inject: false drops both settings and
#          keeps the slot id; the two checks below go red on a pepper planted as
#          a plain value. A missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
KMS=SPOOL_HUB_VENDOR_KEYS_KMS_KEY
PEP=SPOOL_HUB_VENDOR_KEYS_PEPPER
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
TFD="$PROJ_ROOT/src/terraform/030-cloud-run-hub"

for e in "$KMS" "$PEP"; do
  grep -qF "env:\"$e\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
    && pass "the hub reads exactly $e" || fail "config.go does not name $e"
done

# on_shape <tfvars text> <want kms name> <want slot> -> OK, or what is wrong
on_shape() {
  python3 -c '
import json, re, sys
t, kms, slot = sys.stdin.read(), sys.argv[1], sys.argv[2]
def m(k):
    r = re.search(r"^" + k + r"\s*=\s*(\{.*\})\s*$", t, re.M)
    return json.loads(r.group(1)) if r else {}
e, s, v = m("environment_variables"), m("secret_environment_variables"), m("secret_versions")
bad = []
if e.get("SPOOL_HUB_VENDOR_KEYS_KMS_KEY") != kms: bad.append("kms=" + str(e.get("SPOOL_HUB_VENDOR_KEYS_KMS_KEY")))
if "SPOOL_HUB_VENDOR_KEYS_PEPPER" in e: bad.append("pepper is a plain env value")
if s.get("SPOOL_HUB_VENDOR_KEYS_PEPPER") != slot: bad.append("pepper ref=" + str(s.get("SPOOL_HUB_VENDOR_KEYS_PEPPER")))
if not re.fullmatch(r"[1-9][0-9]*", str(v.get(slot, ""))): bad.append("pin=" + str(v.get(slot)))
print("OK" if not bad else " ".join(bad))' "$1" "$2"
}

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  k="$CNF/$env/tf/057-gcp-kms-vendor-keys.vars.tfvars"
  tfv() { sed -nE "s/^$1 *= *\"(.*)\"/\\1/p" "$k"; }
  want="projects/$(tfv gcp_project)/locations/$(tfv gcp_region)/keyRings/$(tfv key_ring)/cryptoKeys/$(tfv crypto_key)"
  slot=$(tfv pepper_secret_id)
  [[ -n "$slot" ]] && pass "$env 057 names the pepper slot $slot" || fail "$env 057 names no pepper slot"
  grep -qx "vendor_keys_pepper_secret_id *= \"$slot\"" "$v" && pass "$env 030 knows 057's slot" || fail "$env 030 vendor_keys_pepper_secret_id is not $slot"
  grep -E '^auth_secret_ids ' "$v" | grep -F "\"$slot\"" >/dev/null && fail "$env $slot is an auth slot (06 would create it)" || pass "$env $slot is not an auth_secret_ids slot"
  r=$(on_shape "$want" "$slot" <"$v")
  [[ "$r" == OK ]] && pass "$env 030 carries the key name of 057 and the pinned pepper reference" || fail "$env 030: $r"
done

grep -q 'resource "google_secret_manager_secret_version"' "$TFD"/*.tf && fail "030 has a secret version resource" || pass "030 has no secret version resource (no value in state)"
grep -q 'var.vendor_keys_pepper_secret_id\])' "$TFD/03-runtime-sa.tf" \
  && pass "03's generic binding skips the pepper (bound once, in 057)" || fail "03 would bind the pepper a second time"
grep -q 'hub_pepper_accessor' "$PROJ_ROOT/src/terraform/057-gcp-kms-vendor-keys/04-hub-grants.tf" \
  && pass "057 holds the runtime SA's read on the pepper" || fail "057 no longer grants the pepper read"

# --- control: inject flips both settings, never the slot id; the shape check
# --- goes red on a pepper planted as a plain value ---------------------------
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
  slot=$(yq -r '.env.vendor_keys.pepper_secret' "$tmp/dev.env.yaml")
  out=$(render)
  [[ "$(on_shape "$(grep -oE "\"$KMS\": \"[^\"]+\"" <<<"$out" | sed -E 's/.*: "(.*)"/\1/')" "$slot" <<<"$out")" == OK ]] \
    && pass "control: inject=true renders both settings" || fail "control inject=true: $(head -c 300 <<<"$out")"
  planted=$(sed -E "s/^(environment_variables *= *\{)/\1\"$PEP\": \"planted\", /" <<<"$out")
  r=$(on_shape "x" "$slot" <<<"$planted")
  [[ "$r" == *"plain env value"* ]] && pass "control: a pepper planted as a plain value goes red ($r)" || fail "control planted: $r"
  yq -i '.env.vendor_keys.inject = "false"' "$tmp/dev.env.yaml"
  out=$(render)
  ! grep -qF "SPOOL_HUB_VENDOR_KEYS_" <<<"$out" && grep -qx "vendor_keys_pepper_secret_id *= \"$slot\"" <<<"$out" \
    && pass "control: inject=false drops both, keeps the slot id" || fail "control inject=false: ${out:0:300}"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $APP_ROOT/tpl-gen or \$TPL_GEN_PATH (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
