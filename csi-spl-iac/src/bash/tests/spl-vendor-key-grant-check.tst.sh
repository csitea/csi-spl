#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_vendor_key_grant_check (spec 127 I1, section 5.1) proves the
#          hub runtime SA is the ONLY member that can use the vendor-key KMS
#          key and pepper, and prints only OK, FAIL or SKIP.
#   1. clean policies: stdout exactly "OK", rc 0; four read-only gcloud calls
#      (key, ring, project, secret get-iam-policy), each with --account = the
#      pinned project SA, under a private CLOUDSDK_CONFIG gone afterwards
#   2. CONTROL: a second member on the key -> FAIL, the finding on stderr
#   3. CONTROL: any binding on the ring -> FAIL
#   4. CONTROL: a project-level cryptoKeyDecrypter -> FAIL, a user: member
#      shown redacted; a project-level secretAccessor -> FAIL
#   5. CONTROL: a second pepper accessor -> FAIL
#   6. CONTROL: an unreadable policy (no key yet) -> FAIL
#   7. vendor_keys.grant_check not "true" -> SKIP, rc 0, gcloud never called
#   8. step 057: one key grant + one pepper grant, both to the runtime SA,
#      nothing on the ring or the project, no secret version in terraform,
#      90-day rotation in dev and prd, KMS Data Access logs on
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-vendor-key-grant-check.func.sh"
TF="$PROJ_ROOT/src/terraform/057-gcp-kms-vendor-keys"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
require_action "$ACTION"
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

RT='serviceAccount:o-a-hub-dev@o-a-dev.iam.gserviceaccount.com'
mkdir -p "$T/pol"
# the stub answers "<group> get-iam-policy" from $POL/<scope>.json; a missing
# file is a refused read
stub gcloud '
echo "${CLOUDSDK_CONFIG:-<unset>}|$*" >>"$GC_CALLS"
[[ -d "${CLOUDSDK_CONFIG:-/nonexistent}" ]] && echo seen >>"$GC_CALLS.cfg"
case "$1 $2" in
  "kms keys") f=key ;; "kms keyrings") f=ring ;; "projects get-iam-policy") f=project ;; "secrets get-iam-policy") f=pepper ;; *) exit 9 ;;
esac
[[ -f "$POL/$f.json" ]] || { echo "NOT_FOUND" >&2; exit 1; }
cat "$POL/$f.json"'

clean() {
  rm -f "$T/pol"/*.json
  printf '{"bindings":[{"role":"roles/cloudkms.cryptoKeyEncrypterDecrypter","members":["%s"]}]}' "$RT" >"$T/pol/key.json"
  echo '{}' >"$T/pol/ring.json"
  echo '{"bindings":[{"role":"roles/owner","members":["serviceAccount:o-a-dev@o-a-dev.iam.gserviceaccount.com","user:someone@example.com"]},{"role":"roles/cloudkms.viewer","members":["group:ops@example.com"]}]}' >"$T/pol/project.json"
  printf '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["%s"]}]}' "$RT" >"$T/pol/pepper.json"
}

cnf() {
  cat <<YAML
env:
  gcp:
    gcp_region: europe-north1
  hub:
    runtime_sa_account_id: o-a-hub-dev
  vendor_keys:
    kms_key:
      key_ring: ring-v
      crypto_key: key-w
    pepper_secret: pep-z
    grant_check: "$1"
YAML
}
cnf true >"$T/cnf.yaml"
cnf false >"$T/cnf-off.yaml"

# run_action <cnf> -> rc; stdout in $T/out, stderr in $T/err, calls in $T/calls.log
run_action() {
  : >"$T/calls.log"; rm -f "$T/calls.log.cfg"
  env -u CLOUDSDK_CONFIG PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" POL="$T/pol" ACTION="$ACTION" CNF="$1" \
    ENV=dev ORG=o APP=a APP_PATH="$T" \
    bash -c 'do_log(){ echo "$*"; }; do_require_bin(){ :; }
      do_gcp_spl_proj_id(){ export PROJ_ID=o-a-dev; }
      do_spl_merged_cnf(){ cp "$CNF" "$3"; }
      do_gcp_pin_account(){ export GCP_ACCOUNT=o-a-dev@o-a-dev.iam.gserviceaccount.com; }
      source "$ACTION"; do_spl_vendor_key_grant_check' >"$T/out" 2>"$T/err"
}

# expect_fail <label> <stderr fragment>
expect_fail() {
  run_action "$T/cnf.yaml"; local rc=$?
  [[ $rc -eq 1 && "$(cat "$T/out")" == FAIL ]] && grep -qF -- "$2" "$T/err" \
    && pass "CONTROL: $1 -> FAIL, finding '$2'" || fail "CONTROL $1: rc=$rc out='$(cat "$T/out")' err=$(cat "$T/err")"
}

# --- 1. clean ------------------------------------------------------------------
clean; run_action "$T/cnf.yaml"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == OK ]] && pass "clean policies: stdout is exactly OK, rc 0" || fail "clean: rc=$rc out='$(cat "$T/out")' err=$(cat "$T/err")"
[[ "$(grep -c 'get-iam-policy' "$T/calls.log")" -eq 4 && "$(grep -c -- '--account=o-a-dev@o-a-dev.iam.gserviceaccount.com' "$T/calls.log")" -eq 4 ]] \
  && pass "four get-iam-policy reads, each with --account = the project SA" || fail "calls: $(cat "$T/calls.log")"
grep -qE 'kms keys get-iam-policy key-w --keyring=ring-v --location=europe-north1 --project=o-a-dev' "$T/calls.log" \
  && grep -qE 'secrets get-iam-policy pep-z --project=o-a-dev' "$T/calls.log" \
  && pass "reads the cnf key, ring and pepper" || fail "targets: $(cat "$T/calls.log")"
grep -vE 'get-iam-policy' "$T/calls.log" | grep . >/dev/null && fail "a gcloud call that is not a read: $(cat "$T/calls.log")" || pass "read-only: no other gcloud call"
cfg=$(head -1 "$T/calls.log" | cut -d'|' -f1)
[[ "$cfg" != "<unset>" && -s "$T/calls.log.cfg" && ! -e "$cfg" ]] && pass "a private CLOUDSDK_CONFIG, removed afterwards" || fail "config dir: '$cfg'"
grep -qF 'basic-role members: 2' "$T/err" && pass "logs the basic-role member count" || fail "basic count: $(cat "$T/err")"
grep -qF 'someone@example.com' "$T/err" "$T/out" && fail "a user email reached the log" || pass "no user email in the log"

# --- 2..5. CONTROLS -------------------------------------------------------------
clean; printf '{"bindings":[{"role":"roles/cloudkms.cryptoKeyEncrypterDecrypter","members":["%s","serviceAccount:x@o-a-dev.iam.gserviceaccount.com"]}]}' "$RT" >"$T/pol/key.json"
expect_fail "a second member on the key" "key roles/cloudkms.cryptoKeyEncrypterDecrypter serviceAccount:x@"
clean; printf '{"bindings":[{"role":"roles/cloudkms.cryptoKeyEncrypterDecrypter","members":["%s"]},{"role":"roles/cloudkms.cryptoKeyDecrypter","members":["%s"]}]}' "$RT" "$RT" >"$T/pol/key.json"
expect_fail "a second role on the key" "key roles/cloudkms.cryptoKeyDecrypter"
clean; echo '{"bindings":[{"role":"roles/cloudkms.cryptoKeyDecrypter","members":["serviceAccount:y@o-a-dev.iam.gserviceaccount.com"]}]}' >"$T/pol/ring.json"
expect_fail "a binding on the ring" "ring roles/cloudkms.cryptoKeyDecrypter serviceAccount:y@"
clean; echo '{"bindings":[{"role":"roles/cloudkms.cryptoKeyDecrypter","members":["user:intruder@example.com"]}]}' >"$T/pol/project.json"
expect_fail "a project-level KMS decrypt role" "project roles/cloudkms.cryptoKeyDecrypter user:<redacted>"
grep -qF 'intruder@example.com' "$T/err" "$T/out" && fail "the user email reached the log" || pass "a user: member is redacted"
clean; echo '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["serviceAccount:z@o-a-dev.iam.gserviceaccount.com"]}]}' >"$T/pol/project.json"
expect_fail "a project-level secretAccessor" "project roles/secretmanager.secretAccessor serviceAccount:z@"
clean; printf '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["%s","serviceAccount:w@o-a-dev.iam.gserviceaccount.com"]}]}' "$RT" >"$T/pol/pepper.json"
expect_fail "a second pepper accessor" "pepper roles/secretmanager.secretAccessor serviceAccount:w@"

# --- 6. CONTROL: unreadable ----------------------------------------------------------
clean; rm -f "$T/pol/key.json"
expect_fail "an unreadable key policy" "cannot read the IAM policy of key ring-v/key-w"

# --- 7. SKIP while 057 is not applied ------------------------------------------------
clean; run_action "$T/cnf-off.yaml"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == SKIP && ! -s "$T/calls.log" ]] && pass "grant_check off -> SKIP, rc 0, gcloud never called" || fail "skip: rc=$rc out='$(cat "$T/out")' calls=$(cat "$T/calls.log")"

# --- 8. step 057 ---------------------------------------------------------------------
[[ "$(cat "$TF"/*.tf | grep -cE '^resource "google_kms_crypto_key_iam_(member|binding|policy)"')" == 1 ]] \
  && grep -qE '^\s*role\s*=\s*"roles/cloudkms.cryptoKeyEncrypterDecrypter"' "$TF/04-hub-grants.tf" \
  && pass "057: one key grant, the KMS encrypt+decrypt role" || fail "057 key grant is not exactly one encrypt+decrypt grant"
[[ "$(cat "$TF"/*.tf | grep -cE '^resource "google_secret_manager_secret_iam_(member|binding|policy)"')" == 1 ]] \
  && grep -qE '^\s*role\s*=\s*"roles/secretmanager.secretAccessor"' "$TF/04-hub-grants.tf" \
  && pass "057: one pepper grant, secretAccessor" || fail "057 pepper grant is not exactly one secretAccessor"
[[ "$(grep -cE '^\s*member\s*=\s*local.hub_member$' "$TF/04-hub-grants.tf")" == 2 ]] \
  && grep -qE 'hub_member = "serviceAccount:\$\{var.hub_runtime_sa_account_id\}@' "$TF/04-hub-grants.tf" \
  && pass "057: both grants name the runtime SA only" || fail "057 grant members"
grep -qE '^resource "google_(project|kms_key_ring)_iam_(member|binding|policy)"' "$TF"/*.tf && fail "057 grants on the project or the key ring" || pass "057 grants nothing on the project or the key ring"
grep -qE '^resource "google_secret_manager_secret_version"' "$TF"/*.tf && fail "057 puts a pepper version into state" || pass "057 creates the pepper slot only, no version"
grep -qE '^\s*service\s*=\s*"cloudkms.googleapis.com"' "$TF/06-kms-audit-logs.tf" && grep -qF '"DATA_READ"' "$TF/06-kms-audit-logs.tf" \
  && pass "057: KMS Data Access audit logs on" || fail "057 KMS audit config"
for env in dev prd; do
  grep -qx 'rotation_period  = "7776000s"' "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/057-gcp-kms-vendor-keys.vars.tfvars" \
    && pass "$env 057 rotates every 90 days" || fail "$env 057 rotation_period is not 7776000s"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
