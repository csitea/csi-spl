#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: 028-gcp-artifact-registry is the hub image store (spec 007 T007,
#          pas-psf step number): one Docker repository per env, ADC not a
#          baked key, no shop entities, cleanup untagged-only. 001 enables
#          the Artifact Registry API; this step creates the repository.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
S="$PROJ_ROOT/src/terraform/028-gcp-artifact-registry"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

[[ -d "$S" ]] && pass "028-gcp-artifact-registry step exists" || fail "028-gcp-artifact-registry step missing"

# --- 1. rendered ids + 001 API ------------------------------------------------
for env in dev prd; do
  v="$CNF/$env/tf/028-gcp-artifact-registry.vars.tfvars"
  [[ -f "$v" ]] || { fail "$env: $v not rendered"; continue; }
  grep -qx "repository_id = \"csi-spl-$env-hub\"" "$v" \
    && pass "$env 028 repository is csi-spl-$env-hub" || fail "$env 028 repository_id"
  grep -qx "immutable_tags = true" "$v" \
    && pass "$env 028 immutable_tags" || fail "$env 028 immutable_tags is not true"
  grep -qx "untagged_max_age_days = 7" "$v" \
    && pass "$env 028 untagged_max_age_days = 7" || fail "$env 028 untagged_max_age_days"
  grep -q "artifactregistry.googleapis.com" "$CNF/$env/tf/001-enable-gcp-services.vars.tfvars" \
    && pass "$env 001 enables artifactregistry.googleapis.com" \
    || fail "$env 001 does not enable artifactregistry"
  grep -qx "prefix = \"terraform/028-gcp-artifact-registry\"" \
    "$CNF/$env/tf/028-gcp-artifact-registry.backend-config.tfvars" \
    && pass "$env 028 backend prefix" || fail "$env 028 backend prefix"
done

# --- 2. morph hygiene (pas-psf 028, strip shop, no key) -----------------------
grep -qE "credentials[[:space:]]*=[[:space:]]*file\(" "$S"/*.tf \
  && fail "028 bakes a credentials file() path" || pass "028 uses ADC (no credentials file())"
grep -qE "format[[:space:]]*=[[:space:]]*\"DOCKER\"" "$S"/03-docker-repository.tf \
  && pass "028 format is DOCKER" || fail "028 format is not DOCKER"
grep -q "google_artifact_registry_repository" "$S"/03-docker-repository.tf \
  && pass "028 creates google_artifact_registry_repository" \
  || fail "028 has no google_artifact_registry_repository"
grep -q "tag_state  = \"UNTAGGED\"" "$S"/03-docker-repository.tf \
  && pass "028 cleanup is untagged-only" || fail "028 cleanup is not untagged-only"
grep -qiE "wordpress|recaptcha|stripe|bin-dataset" "$S"/*.tf \
  && fail "028 still carries shop entities" || pass "028 has no shop entities"
grep -qE "resource \"(random_password|google_secret_manager_secret_version|google_service_account_key)\"" "$S"/*.tf \
  && fail "028 has a state-borne secret resource" || pass "028 has no key, secret version or password"

# --- 3. the URI 030 / do_build_push_hub_image consume -------------------------
grep -q "docker.pkg.dev" "$S"/05-outputs.tf \
  && pass "028 output names docker.pkg.dev" || fail "028 output is not a docker.pkg.dev URL"
tpl="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/028-gcp-artifact-registry.vars.tfvars.tpl"
[[ -f "$tpl" ]] && pass "028 vars tpl exists" || fail "028 vars tpl missing"
grep -q "steps\[\"028-gcp-artifact-registry\"\]" "$tpl" \
  && pass "028 vars tpl reads the 028 step keys" || fail "028 vars tpl does not iterate 028 keys"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
