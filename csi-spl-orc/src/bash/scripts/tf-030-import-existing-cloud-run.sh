#!/bin/sh
#------------------------------------------------------------------------------
# Purpose: bring the hub Cloud Run service (and the other 030 addresses that
# already exist LIVE) under the 030-cloud-run-hub state, so a plain
# `terraform apply` of the step does not CREATE over objects that are already
# there (409 "already exists") after a lost or reset state.
#
# Ported from csi-rel-orc tf-030-import-existing-cloud-run.sh. The framework is
# unchanged (tf_get / is_empty / is_true / try_import, idempotent, import only,
# non-fatal skip). The ADDRESS TABLE is not: csi-spl's 030-cloud-run-hub
# declares a different resource set from csi-rel's 030-gcp-cloud-run, so each
# section below maps one resource of csi-spl-iac/src/terraform/030-cloud-run-hub
# (see csi-spl-doc/specs/007-spool-hub-api-infra/csi-rel-tf-callers.md).
# Imports are idempotent: an address already in state is skipped, and a
# resource that does not exist live is reported and skipped (non-fatal).
#
# HARD RULES encoded here (do not "fix" them to make a plan clean):
#   - IMPORT ONLY. This script never runs apply, targeted or otherwise.
#   - `google_service_account.hub` is imported as the Terraform-declared
#     account `<runtime_sa_account_id>@<project>`. NEVER import any other
#     account (e.g. the default compute SA) into that address.
#   - Credentials are the per-env project key at
#     `$HOME/.gcp/.<org>/key-<org>-<app>-<env>.json`.
#
# Run INSIDE a terraform-initialised working copy of the step (cwd = step dir,
# `terraform init -backend-config=…` already done), with the env's credentials
# in GOOGLE_APPLICATION_CREDENTIALS (and/or the provider `credentials = file()`
# path). POSIX sh — runs under the busybox sh of the hashicorp/terraform image
# as well as bash.
#
# `terraform import` evaluates the root module, so the step's tfvars must be
# passed just like on plan/apply — without it the import dies on
# "No value for required variable gcp_project".
#
# Usage:
#   tf-030-import-existing-cloud-run.sh <vars.tfvars>
# Example (throwaway container, from a scratch copy of the step):
#   docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/work/030:/tf" -w /tf \
#     -v "$HOME/.gcp:/home/tf/.gcp:ro" -e HOME=/home/tf \
#     -e GOOGLE_APPLICATION_CREDENTIALS=/home/tf/.gcp/.csi/key-csi-spl-dev.json \
#     -e TF_VAR_STEP=030-cloud-run-hub -e TF_VAR_proj_path=/tf \
#     -e TF_VAR_base_path=/ -e TF_VAR_TERRAFORM_VERSION=1.9 \
#     -e TF_VAR_INFRA_VERSION=0 -e TF_VAR_CNF_VER=import --entrypoint sh \
#     hashicorp/terraform:1.9 /tf/tf-030-import-existing-cloud-run.sh \
#       030-cloud-run-hub.vars.tfvars
#------------------------------------------------------------------------------
set -u

VARS_FILE="${1:?usage: $0 <vars.tfvars>}"

[ -f "$VARS_FILE" ] || { echo "FATAL: $VARS_FILE not found" >&2; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "FATAL: terraform not on PATH" >&2; exit 1; }

# First assignment of KEY from the vars file; strip surrounding double quotes.
tf_get() {
  _k="$1"
  _line=$(grep -E "^[[:space:]]*${_k}[[:space:]]*=" "$VARS_FILE" | head -n 1) || true
  [ -n "$_line" ] || { echo ""; return 0; }
  _val=${_line#*=}
  _val=$(printf '%s' "$_val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  printf '%s' "$_val" | sed -e 's/^"\(.*\)"$/\1/'
}

is_empty() {
  [ -z "$1" ] || [ "$1" = "[]" ] || [ "$1" = "{}" ] || [ "$1" = "null" ]
}

is_true() {
  [ "$1" = "true" ] || [ "$1" = "True" ] || [ "$1" = "TRUE" ]
}

# One item per line: the string elements of a one-line list ["a", "b"].
list_items() {
  printf '%s' "$1" | sed -e 's/^\[//' -e 's/\]$//' | tr ',' '\n' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' |
    grep -v '^$' || true
}

# One item per line: the string VALUES of a one-line map {"K": "v", ...}.
map_values() {
  printf '%s' "$1" | grep -oE '"[^"]*"[[:space:]]*:[[:space:]]*"[^"]*"' |
    sed -e 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' || true
}

org=$(tf_get org)
app=$(tf_get app)
env=$(tf_get env)
project=$(tf_get gcp_project)
region=$(tf_get gcp_region)
service=$(tf_get service_name)
sa_account_id=$(tf_get runtime_sa_account_id)
allow_unauth=$(tf_get allow_unauthenticated)
files_bucket=$(tf_get files_bucket_name)
secret_envs=$(tf_get secret_environment_variables)
auth_ids=$(tf_get auth_secret_ids)

[ -n "$project" ] || { echo "FATAL: gcp_project missing from $VARS_FILE" >&2; exit 1; }
[ -n "$region" ] || { echo "FATAL: gcp_region missing from $VARS_FILE" >&2; exit 1; }
[ -n "$service" ] || { echo "FATAL: service_name missing from $VARS_FILE" >&2; exit 1; }
[ -n "$sa_account_id" ] || { echo "FATAL: runtime_sa_account_id missing from $VARS_FILE" >&2; exit 1; }
[ -n "$org" ] && [ -n "$app" ] && [ -n "$env" ] || {
  echo "FATAL: org/app/env missing from $VARS_FILE" >&2
  exit 1
}

# Terraform-declared SA — NEVER the default compute SA.
declared_sa="${sa_account_id}@${project}.iam.gserviceaccount.com"

in_state=$(terraform state list 2>/dev/null || true)
imported=0; skipped=0; failed=0

try_import() {
  addr="$1"
  id="$2"

  if printf '%s\n' "$in_state" | grep -qxF "$addr"; then
    echo "SKIP  already in state: $addr"
    skipped=$((skipped + 1))
    return 0
  fi

  echo "IMPORT $addr  <-  $id"
  if out=$(terraform import -input=false -lock-timeout=120s -var-file="$VARS_FILE" "$addr" "$id" 2>&1); then
    echo "OK    imported $addr"
    imported=$((imported + 1))
  else
    echo "WARN  could not import $addr (not live, or not in config — skipped, non-fatal):"
    echo "$out" | grep -i "error" | head -n 3
    failed=$((failed + 1))
  fi
}

# --- 1. google_service_account.hub (always declared) -----------------------
try_import "google_service_account.hub" \
  "projects/${project}/serviceAccounts/${declared_sa}"

# --- 2. Cloud SQL client IAM (always declared) -----------------------------
try_import "google_project_iam_member.hub_cloudsql_client" \
  "${project} roles/cloudsql.client serviceAccount:${declared_sa}"

# --- 3. auth secret slots (for_each = auth_secret_ids) ---------------------
# Before the accessor bindings: an injected auth secret's slot lives here.
if is_empty "$auth_ids"; then
  echo "SKIP  google_secret_manager_secret.auth (auth_secret_ids empty)"
  skipped=$((skipped + 1))
else
  for sid in $(list_items "$auth_ids"); do
    try_import "google_secret_manager_secret.auth[\"${sid}\"]" \
      "projects/${project}/secrets/${sid}"
  done
fi

# --- 4. per-secret accessor (for_each = values(secret_environment_variables))
if is_empty "$secret_envs"; then
  echo "SKIP  google_secret_manager_secret_iam_member.hub_secret_accessor (secret_environment_variables empty)"
  skipped=$((skipped + 1))
else
  for sid in $(map_values "$secret_envs" | sort -u); do
    try_import "google_secret_manager_secret_iam_member.hub_secret_accessor[\"${sid}\"]" \
      "projects/${project}/secrets/${sid} roles/secretmanager.secretAccessor serviceAccount:${declared_sa}"
  done
fi

# --- 5. files-bucket object user (always declared) -------------------------
if is_empty "$files_bucket"; then
  echo "SKIP  google_storage_bucket_iam_member.hub_files_object_user (files_bucket_name empty)"
  skipped=$((skipped + 1))
else
  try_import "google_storage_bucket_iam_member.hub_files_object_user" \
    "b/${files_bucket} roles/storage.objectUser serviceAccount:${declared_sa}"
fi

# --- 6. Cloud Run v2 service (always declared) -----------------------------
try_import "google_cloud_run_v2_service.hub" \
  "projects/${project}/locations/${region}/services/${service}"

# --- 7. unauthenticated invoker (count = allow_unauthenticated) ------------
if is_true "$allow_unauth"; then
  try_import "google_cloud_run_v2_service_iam_member.public_invoker[0]" \
    "projects/${project}/locations/${region}/services/${service} roles/run.invoker allUsers"
else
  echo "SKIP  google_cloud_run_v2_service_iam_member.public_invoker[0] (allow_unauthenticated is not true; count=0)"
  skipped=$((skipped + 1))
fi

echo "----------------------------------------------------------------"
echo "imported=$imported skipped=$skipped failed=$failed"
echo "Next: terraform plan -var-file=$VARS_FILE"
echo "This script does not apply. An apply of 030 is the owner's decision;"
echo "a WARN above is a resource the next plan will still want to CREATE."
echo "Do not apply to 'make the plan clean'."
exit 0
