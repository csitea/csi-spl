#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_kms_check (spec 090 T002) proves the marketing KMS key AS
#          the hub's runtime SA and prints only OK or FAIL.
#   1. a good round trip: stdout is exactly "OK", rc 0; two gcloud kms calls
#      (encrypt piped into decrypt) on the cnf key ring + key, each with --project,
#      --location, --account = the pinned project SA, and
#      --impersonate-service-account = the runtime SA; under a private
#      CLOUDSDK_CONFIG that is gone afterwards
#   2. CONTROL: a decrypt that returns other bytes -> stdout exactly "FAIL", rc 1
#   3. CONTROL: an encrypt that fails (no grant) -> "FAIL", rc 1
#   4. CONTROL: a cnf without marketing.kms_key -> "FAIL", rc 1, gcloud never called
#   5. step 055 grants cryptoKeyEncrypterDecrypter on the KEY only, to the
#      runtime SA only, and rotates within 90 days
#   6. 030 creates both LinkedIn marketing slots and, while
#      marketing.linkedin.inject is "false", injects neither (Cloud Run
#      refuses a revision whose secret has no version)
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-kms-check.func.sh"
TF="$PROJ_ROOT/src/terraform/055-gcp-kms-marketing"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
require_action "$ACTION"

# the stub "encrypts" by prefixing CT:, "decrypts" by stripping it; KMS_MODE
# breaks one side for the controls
stub gcloud '
echo "${CLOUDSDK_CONFIG:-<unset>}|$*" >>"$GC_CALLS"
[[ -d "${CLOUDSDK_CONFIG:-/nonexistent}" ]] && echo seen >>"$GC_CALLS.cfg"
case "$2:${KMS_MODE:-ok}" in
  encrypt:noenc) echo "PERMISSION_DENIED" >&2; exit 1 ;;
  encrypt:*) printf "CT:"; cat ;;
  decrypt:baddec) cat >/dev/null; printf "something else" ;;
  decrypt:*) sed "s/^CT://" ;;
esac'

cat >"$T/cnf.yaml" <<'YAML'
env:
  gcp:
    gcp_region: europe-north1
  hub:
    runtime_sa_account_id: o-a-hub-dev
  marketing:
    kms_key:
      key_ring: ring-x
      crypto_key: key-y
YAML
sed '/marketing:/,$d' "$T/cnf.yaml" >"$T/cnf-nokey.yaml"

# run_action <cnf> [env assignments...] -> rc; stdout in $T/out, calls in $T/calls.log
run_action() {
  local cnf="$1"; shift
  : >"$T/calls.log"; rm -f "$T/calls.log.cfg"
  env -u CLOUDSDK_CONFIG PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" ACTION="$ACTION" CNF="$cnf" \
    ENV=dev ORG=o APP=a APP_PATH="$T" "$@" \
    bash -c 'do_log(){ echo "$*"; }; do_require_bin(){ :; }
      do_gcp_spl_proj_id(){ export PROJ_ID=o-a-dev; }
      do_spl_merged_cnf(){ cp "$CNF" "$3"; }
      do_gcp_pin_account(){ export GCP_ACCOUNT=o-a-dev@o-a-dev.iam.gserviceaccount.com; }
      source "$ACTION"; do_spl_kms_check' >"$T/out" 2>"$T/err"
}

# --- 1. a good round trip ---------------------------------------------------------
run_action "$T/cnf.yaml"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == OK ]] && pass "round trip: stdout is exactly OK, rc 0" || fail "round trip: rc=$rc out='$(cat "$T/out")' err=$(cat "$T/err")"
want='--project=o-a-dev --location=europe-north1 --keyring=ring-x --key=key-y --account=o-a-dev@o-a-dev.iam.gserviceaccount.com --impersonate-service-account=o-a-hub-dev@o-a-dev.iam.gserviceaccount.com'
# the two calls are one pipe, so they start (and log) in either order
verbs=$(cut -d'|' -f2 "$T/calls.log" | awk '{print $1, $2}' | sort | tr '\n' ' ')
[[ "$verbs" == "kms decrypt kms encrypt " ]] && pass "two calls: kms encrypt piped into kms decrypt" || fail "calls: $(cat "$T/calls.log")"
[[ "$(grep -cF -- "$want" "$T/calls.log")" -eq 2 ]] && pass "both calls: the cnf ring + key, the project SA, impersonating the runtime SA" || fail "flags: $(cat "$T/calls.log")"
cfg=$(head -1 "$T/calls.log" | cut -d'|' -f1)
[[ "$cfg" != "<unset>" && -s "$T/calls.log.cfg" && ! -e "$cfg" ]] && pass "a private CLOUDSDK_CONFIG, removed afterwards" || fail "config dir: '$cfg'"

# --- 2. CONTROL: a mismatching decrypt --------------------------------------------
run_action "$T/cnf.yaml" KMS_MODE=baddec; rc=$?
[[ $rc -eq 1 && "$(cat "$T/out")" == FAIL ]] && pass "CONTROL: a mismatching decrypt -> FAIL, rc 1" || fail "CONTROL baddec: rc=$rc out='$(cat "$T/out")'"

# --- 3. CONTROL: no grant -----------------------------------------------------------
run_action "$T/cnf.yaml" KMS_MODE=noenc; rc=$?
[[ $rc -eq 1 && "$(cat "$T/out")" == FAIL ]] && pass "CONTROL: a refused encrypt -> FAIL, rc 1" || fail "CONTROL noenc: rc=$rc out='$(cat "$T/out")'"

# --- 4. CONTROL: no key in the cnf -------------------------------------------------
run_action "$T/cnf-nokey.yaml"; rc=$?
[[ $rc -eq 1 && "$(cat "$T/out")" == FAIL && ! -s "$T/calls.log" ]] && pass "CONTROL: no marketing.kms_key -> FAIL, gcloud never called" || fail "CONTROL nokey: rc=$rc out='$(cat "$T/out")' calls=$(cat "$T/calls.log")"

# --- 5. step 055: the key, its rotation and its one grant ---------------------------
[[ "$(cat "$TF"/*.tf | grep -cE '^resource "google_kms_crypto_key_iam_(member|binding|policy)"')" == 1 ]] \
  && grep -qE '^\s*role\s*=\s*"roles/cloudkms.cryptoKeyEncrypterDecrypter"' "$TF/04-hub-key-grant.tf" \
  && grep -qE '^\s*member\s*=\s*"serviceAccount:\$\{var.hub_runtime_sa_account_id\}@' "$TF/04-hub-key-grant.tf" \
  && pass "055: one key grant (the KMS encrypt+decrypt role) to the runtime SA" || fail "055 key grant is not exactly one KMS encrypt+decrypt grant for the runtime SA"
grep -qE '^resource "google_(project|kms_key_ring)_iam_' "$TF"/*.tf && fail "055 grants on the project or the key ring" || pass "055 grants nothing on the project or the key ring"
grep -qE '^\s*purpose\s*=\s*"ENCRYPT_DECRYPT"' "$TF/03-kms-key.tf" && pass "055: a symmetric ENCRYPT_DECRYPT key" || fail "055 key purpose"
for env in dev prd; do
  grep -qx 'rotation_period = "7776000s"' "$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/055-gcp-kms-marketing.vars.tfvars" \
    && pass "$env 055 rotates every 90 days" || fail "$env 055 rotation_period is not 7776000s"
done


# --- 6. 030: the two LinkedIn slots exist, injected only after inject=true ----------
for env in dev prd; do
  v="$APP_ROOT/csi-spl-cnf/csi-spl/$env/tf/030-cloud-run-hub.vars.tfvars"
  inj=$(yq -r '.env.marketing.linkedin.inject' "$APP_ROOT/csi-spl-cnf/csi-spl/$env.env.json" 2>/dev/null)
  ids=$(grep -E '^auth_secret_ids ' "$v"); sec=$(grep -E '^secret_environment_variables ' "$v")
  grep -qF '"csi-spl-hub-marketing-linkedin-client-id"' <<<"$ids" && grep -qF '"csi-spl-hub-marketing-linkedin-client-secret"' <<<"$ids" \
    && pass "$env 030 creates both LinkedIn marketing slots" || fail "$env 030 auth_secret_ids lacks a LinkedIn marketing slot"
  if [[ "$inj" == false ]]; then
    grep -qF 'SPOOL_HUB_MARKETING_LINKEDIN' <<<"$sec" && fail "$env 030 injects a LinkedIn marketing secret while inject is false" \
      || pass "$env 030 injects no LinkedIn marketing secret while inject is false"
  else
    grep -qF '"SPOOL_HUB_MARKETING_LINKEDIN_CLIENT_SECRET": "csi-spl-hub-marketing-linkedin-client-secret"' <<<"$sec" \
      && pass "$env 030 injects the LinkedIn marketing secrets (inject=$inj)" || fail "$env 030 inject=$inj but the secrets are not injected"
  fi
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
