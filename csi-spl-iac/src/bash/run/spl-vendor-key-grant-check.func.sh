#!/bin/bash
#------------------------------------------------------------------------------
# @description The daily grant check of spec 127 (section 5.1, lane I1): read
# @description the LIVE IAM policies around the vendor-key KMS key and the
# @description fingerprint pepper (step 057) and prove that the hub's runtime SA
# @description (cnf hub.runtime_sa_account_id) is the only member that can use
# @description them. Prints exactly one line on stdout: OK, FAIL, or SKIP (cnf
# @description vendor_keys.grant_check is not "true": 057 is not applied in that
# @description env yet). Each finding goes to stderr as "<scope> <role> <member>",
# @description a user: member shown as user:<redacted> (the run log is public).
# @description FAIL when:
# @description   key     any binding other than cryptoKeyEncrypterDecrypter = [runtime SA]
# @description   ring    any binding at all
# @description   project a roles/cloudkms.* role other than viewer, or a
# @description           secretmanager admin/accessor role (reads every secret)
# @description   pepper  any binding other than secretAccessor = [runtime SA]
# @description   or a policy that cannot be read (no key, no rights).
# @description NOT covered: custom roles and the basic roles owner/editor (the
# @description project owner is the stated residual of 5.1); their member
# @description COUNT is logged. Runs as the env's project SA in a private gcloud
# @description config. Read-only: nothing in GCP changes. Workflow 48 runs it daily.
# @param ENV - required: dev or prd
# @example ENV=dev ./run -a do_spl_vendor_key_grant_check
#------------------------------------------------------------------------------
do_spl_vendor_key_grant_check() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  local p region ring key pepper rt enabled
  if ! spl_vkgc_target >&2; then
    echo FAIL
    return 1
  fi
  if [[ "$enabled" != true ]]; then
    do_log "INFO $ENV vendor_keys.grant_check is '$enabled', not \"true\": 057 not applied here yet" >&2
    echo SKIP
    return 0
  fi
  local d="$_spl_sdk_dir" bad=0
  spl_vkgc_policies "$d" || { echo FAIL; return 1; }
  spl_vkgc_findings "$d" >"$d/findings" || bad=1
  if [[ -s "$d/findings" || "$bad" -ne 0 ]]; then
    sed 's/^/FINDING /' "$d/findings" >&2
    do_log "ERROR $ENV: a member other than $rt can use the vendor-key KMS key or pepper" >&2
    echo FAIL
    return 1
  fi
  do_log "INFO $ENV: only $rt holds the vendor-key KMS key and pepper; basic-role members: $(spl_vkgc_basic_count "$d/project.json")" >&2
  echo OK
}

# spl_vkgc_target - sets p, region, ring, key, pepper, rt and enabled (the
# caller's locals) from the merged cnf of $ENV, and pins GCP_ACCOUNT.
spl_vkgc_target() {
  do_require_bin yq jq gcloud || return 1
  do_gcp_spl_proj_id || return 1
  p="$PROJ_ID"
  local cnf="$CLOUDSDK_CONFIG/cnf.yaml" rt_id
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  region="$(yq -r '.env.gcp.gcp_region // ""' "$cnf")"
  ring="$(yq -r '.env.vendor_keys.kms_key.key_ring // ""' "$cnf")"
  key="$(yq -r '.env.vendor_keys.kms_key.crypto_key // ""' "$cnf")"
  pepper="$(yq -r '.env.vendor_keys.pepper_secret // ""' "$cnf")"
  enabled="$(yq -r '.env.vendor_keys.grant_check // ""' "$cnf")"
  rt_id="$(yq -r '.env.hub.runtime_sa_account_id // ""' "$cnf")"
  [[ -n "$region" && -n "$ring" && -n "$key" && -n "$pepper" && -n "$rt_id" ]] ||
    { do_log "FATAL the $ENV cnf lacks env.gcp.gcp_region, env.vendor_keys.{kms_key.key_ring,kms_key.crypto_key,pepper_secret} or env.hub.runtime_sa_account_id"; return 1; }
  rt="serviceAccount:$rt_id@$p.iam.gserviceaccount.com"
  [[ "$enabled" == true ]] || return 0
  do_gcp_pin_account || return 1
}

# spl_vkgc_policies <dir> - the four live policies as JSON files in <dir>.
spl_vkgc_policies() {
  local d="$1"
  gcloud kms keys get-iam-policy "$key" --keyring="$ring" --location="$region" --project="$p" --account="$GCP_ACCOUNT" --format=json >"$d/key.json" 2>/dev/null ||
    { do_log "ERROR cannot read the IAM policy of key $ring/$key in $p" >&2; return 1; }
  gcloud kms keyrings get-iam-policy "$ring" --location="$region" --project="$p" --account="$GCP_ACCOUNT" --format=json >"$d/ring.json" 2>/dev/null ||
    { do_log "ERROR cannot read the IAM policy of key ring $ring in $p" >&2; return 1; }
  gcloud projects get-iam-policy "$p" --account="$GCP_ACCOUNT" --format=json >"$d/project.json" 2>/dev/null ||
    { do_log "ERROR cannot read the IAM policy of project $p" >&2; return 1; }
  gcloud secrets get-iam-policy "$pepper" --project="$p" --account="$GCP_ACCOUNT" --format=json >"$d/pepper.json" 2>/dev/null ||
    { do_log "ERROR cannot read the IAM policy of secret $pepper in $p" >&2; return 1; }
}

# spl_vkgc_findings <dir> - one "<scope> <role> <member>" line per binding the
# rules of the header refuse; nothing when all four policies are clean.
spl_vkgc_findings() {
  local d="$1" f
  f='def who: if startswith("user:") then "user:<redacted>" else . end;
     [.bindings[]? | .role as $r | .members[]? | {r: $r, m: .}]'
  jq -r --arg rt "$rt" "$f"' | .[] | select(.r != "roles/cloudkms.cryptoKeyEncrypterDecrypter" or .m != $rt) | "key \(.r) \(.m | who)"' "$d/key.json" || return 1
  jq -r "$f"' | .[] | "ring \(.r) \(.m | who)"' "$d/ring.json" || return 1
  jq -r "$f"' | .[] | select((.r | test("^roles/cloudkms\\.")) and .r != "roles/cloudkms.viewer"
     or (.r | test("^roles/secretmanager\\.(admin|secretAccessor)$"))) | "project \(.r) \(.m | who)"' "$d/project.json" || return 1
  jq -r --arg rt "$rt" "$f"' | .[] | select(.r != "roles/secretmanager.secretAccessor" or .m != $rt) | "pepper \(.r) \(.m | who)"' "$d/pepper.json" || return 1
}

# spl_vkgc_basic_count <project.json> - members of roles/owner + roles/editor.
spl_vkgc_basic_count() {
  jq '[.bindings[]? | select(.role == "roles/owner" or .role == "roles/editor") | .members[]?] | length' "$1"
}
