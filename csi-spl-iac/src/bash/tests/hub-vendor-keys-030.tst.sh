#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 159 (SPL-4623) -- step 030 gives the hub its two vendor key
#          settings, so /v1/vendor-keys stops answering 503 vendor_keys_off:
#          - while cnf vendor_keys.inject is "true": SPOOL_HUB_VENDOR_KEYS_KMS_KEY
#            is the full CryptoKey name of step 057's key, a plain env value;
#            the pepper is 32 raw bytes, so a secret volume file at a pinned
#            version (SPOOL_HUB_VENDOR_KEYS_PEPPER_FILE), never an env value and
#            never an env secret, which a NUL would cut;
#          - 030 creates no slot and no version, and binds nothing on the slot:
#            057 owns the one member its grant check allows.
#          CONTROL: a scratch render flips inject: false drops both settings and
#          keeps the slot id; a pepper planted as a plain value or an env secret
#          and a wrong key name in the template each go red. A missing tpl-gen
#          venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
KMS=SPOOL_HUB_VENDOR_KEYS_KMS_KEY
PEP=SPOOL_HUB_VENDOR_KEYS_PEPPER_FILE
RAW=SPOOL_HUB_VENDOR_KEYS_PEPPER
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
TFD="$PROJ_ROOT/src/terraform/030-cloud-run-hub"

for e in "$KMS" "$PEP"; do
  grep -qF "env:\"$e\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
    && pass "the hub reads exactly $e" || fail "config.go does not name $e"
done
grep -qF "env:\"$RAW\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go" \
  && fail "the hub still reads the pepper from env $RAW" || pass "the hub no longer reads the pepper from an env value"

# on_shape <tfvars text> <want kms name> <want slot> <want pepper file> -> OK, or what is wrong
on_shape() {
  python3 -c '
import json, re, sys
t, kms, slot, file = sys.stdin.read(), sys.argv[1], sys.argv[2], sys.argv[3]
def m(k):
    r = re.search(r"^" + k + r"\s*=\s*(\{.*\})\s*$", t, re.M)
    return json.loads(r.group(1)) if r else {}
e, s, v = m("environment_variables"), m("secret_environment_variables"), m("secret_versions")
ver = re.search(r"^vendor_keys_pepper_version\s*=\s*\"(.*)\"\s*$", t, re.M)
bad = []
if e.get("SPOOL_HUB_VENDOR_KEYS_KMS_KEY") != kms: bad.append("kms=" + str(e.get("SPOOL_HUB_VENDOR_KEYS_KMS_KEY")))
if "SPOOL_HUB_VENDOR_KEYS_PEPPER" in e: bad.append("pepper is a plain env value")
if "SPOOL_HUB_VENDOR_KEYS_PEPPER" in s or slot in s.values() or slot in v: bad.append("pepper is an env secret")
if e.get("SPOOL_HUB_VENDOR_KEYS_PEPPER_FILE") != file: bad.append("file=" + str(e.get("SPOOL_HUB_VENDOR_KEYS_PEPPER_FILE")))
if not (ver and re.fullmatch(r"[1-9][0-9]*", ver.group(1))): bad.append("pin=" + (ver.group(1) if ver else "None"))
print("OK" if not bad else " ".join(bad))' "$1" "$2" "$3"
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
  file=$(yq -r '.env.vendor_keys.pepper_file' "$CNF/$env.env.json")
  r=$(on_shape "$want" "$slot" "$file" <"$v")
  [[ "$r" == OK ]] && pass "$env 030 carries the key name of 057 and the pepper file at its pin" || fail "$env 030: $r"
  pin=$(yq -r ".env.hub.secret_versions[\"$slot\"]" "$CNF/$env.env.json")
  grep -qx "vendor_keys_pepper_version *= \"$pin\"" "$v" && pass "$env 030 mounts the cnf pin $pin" || fail "$env 030 does not mount the cnf pin $pin"
done

grep -q 'resource "google_secret_manager_secret_version"' "$TFD"/*.tf && fail "030 has a secret version resource" || pass "030 has no secret version resource (no value in state)"
grep -q 'vendor_keys_pepper' "$TFD/03-runtime-sa.tf" && fail "03 names the pepper: 057 holds the only binding" || pass "03 does not bind the pepper (bound once, in 057)"
grep -q 'secret = var.vendor_keys_pepper_secret_id' "$TFD/04-cloud-run-service.tf" && grep -q 'version = volumes.value' "$TFD/04-cloud-run-service.tf" \
  && pass "04 mounts the pepper as a secret volume at its pin" || fail "04 does not mount the pepper at its pin"
# Run API v2 reads cloudsql back last: the config must list it last too, or dev plans
# a swap forever and the dev-leads-prd gate refuses every prd apply of 030.
pepper_before_cloudsql() {
  awk -v block="$1" '
    index($0, "\"" block "\"") && /dynamic/ { p = NR }
    $0 ~ "^ *" block " \\{" { s = NR }
    END { exit !(p && s && p < s) }' "$2"
}
for b in volumes volume_mounts; do
  pepper_before_cloudsql "$b" "$TFD/04-cloud-run-service.tf" \
    && pass "04 lists the pepper's $b before cloudsql" || fail "04 lists cloudsql's $b first: the plan swaps them forever"
  bad="$(mktemp)"
  awk -v block="$b" '
    index($0, "dynamic \"" block "\"") { held = $0; next }
    { print }
    END { print held }' "$TFD/04-cloud-run-service.tf" >"$bad"
  pepper_before_cloudsql "$b" "$bad" \
    && fail "control: $b with cloudsql first stays green" || pass "control: $b with cloudsql first goes red"
  rm -f "$bad"
done
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
  TPL_FILE="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl"
  render() { (cd "$TPG" && TPL="$TPL_FILE" CNF="$tmp/dev.env.yaml" \
    .venv/bin/python -c '
import os, yaml, jinja2
cnf = yaml.safe_load(open(os.environ["CNF"]))["env"]
tpl = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(open(os.environ["TPL"]).read())
print(tpl.render(**{**cnf, "ORG": "csi", "APP": "spl", "ENV": "dev"}))' 2>&1); }
  slot=$(yq -r '.env.vendor_keys.pepper_secret' "$tmp/dev.env.yaml")
  file=$(yq -r '.env.vendor_keys.pepper_file' "$tmp/dev.env.yaml")
  # the key name comes from 057's tfvars, never from the render under test
  k="$CNF/dev/tf/057-gcp-kms-vendor-keys.vars.tfvars"
  tfv() { sed -nE "s/^$1 *= *\"(.*)\"/\\1/p" "$k"; }
  want="projects/$(tfv gcp_project)/locations/$(tfv gcp_region)/keyRings/$(tfv key_ring)/cryptoKeys/$(tfv crypto_key)"
  out=$(render)
  [[ "$(on_shape "$want" "$slot" "$file" <<<"$out")" == OK ]] \
    && pass "control: inject=true renders both settings" || fail "control inject=true: $(head -c 300 <<<"$out")"
  planted=$(sed -E "s/^(environment_variables *= *\{)/\1\"$RAW\": \"planted\", /" <<<"$out")
  r=$(on_shape "$want" "$slot" "$file" <<<"$planted")
  [[ "$r" == *"plain env value"* ]] && pass "control: a pepper planted as a plain value goes red ($r)" || fail "control planted: $r"
  planted=$(sed -E "s/^(secret_environment_variables *= *\{)/\1\"$RAW\": \"$slot\", /" <<<"$out")
  r=$(on_shape "$want" "$slot" "$file" <<<"$planted")
  [[ "$r" == *"env secret"* ]] && pass "control: a pepper planted as an env secret goes red ($r)" || fail "control env secret: $r"
  sed 's|"/cryptoKeys/" ~ vk|"/cryptoKeys/WRONG-" ~ vk|' "$TPL_FILE" >"$tmp/wrong.tpl"
  r=$(on_shape "$want" "$slot" "$file" <<<"$(TPL_FILE="$tmp/wrong.tpl" render)")
  [[ "$r" == *"kms="*"WRONG-"* ]] && pass "control: a wrong key name in the template goes red" || fail "control wrong key name: $r"
  yq -i '.env.vendor_keys.inject = "false"' "$tmp/dev.env.yaml"
  out=$(render)
  ! grep -qF "SPOOL_HUB_VENDOR_KEYS_" <<<"$out" && grep -qx "vendor_keys_pepper_secret_id *= \"$slot\"" <<<"$out" && grep -qx 'vendor_keys_pepper_version *= ""' <<<"$out" \
    && pass "control: inject=false drops both and the volume, keeps the slot id" || fail "control inject=false: ${out:0:300}"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $APP_ROOT/tpl-gen or \$TPL_GEN_PATH (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
