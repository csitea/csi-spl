#!/bin/sh
#------------------------------------------------------------------------------
# Purpose: print the import table of a terraform step, one line per resource:
#   <address><TAB><import id>
# derived from the step's rendered tfvars. do_tf_import_existing walks this
# table and imports each address that is not already in state, through the
# tf-runner (./run -a do_tf_import). This script only prints; it calls nothing.
#
# A NEW TOOL, not a csi-rel port: csi-rel has no importer for these steps.
# It follows csi-rel's tf-030 importer (tf_get, one entry per declared
# resource, ids from tfvars), and the drift test
# (csi-spl-orc/src/bash/tests/tf-import-existing.tst.sh) fails when a step
# declares a resource this table does not cover, or the reverse.
#
# Steps: 020-gcp-relay-bucket, 040-cloud-sql-postgres. Any other step -> exit 2.
#
# Usage:
#   tf-import-table.sh <step> <vars.tfvars>
#------------------------------------------------------------------------------
set -u

STEP="${1:?usage: $0 <step> <vars.tfvars>}"
VARS_FILE="${2:?usage: $0 <step> <vars.tfvars>}"

[ -f "$VARS_FILE" ] || { echo "FATAL: $VARS_FILE not found" >&2; exit 1; }

# First assignment of KEY from the vars file; strip surrounding double quotes.
tf_get() {
  _k="$1"
  _line=$(grep -E "^[[:space:]]*${_k}[[:space:]]*=" "$VARS_FILE" | head -n 1) || true
  [ -n "$_line" ] || { echo ""; return 0; }
  _val=${_line#*=}
  _val=$(printf '%s' "$_val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  printf '%s' "$_val" | sed -e 's/^"\(.*\)"$/\1/'
}

need() { # <key>...: every key must be set in the tfvars
  for _n in "$@"; do
    [ -n "$(tf_get "$_n")" ] || { echo "FATAL: $_n missing from $VARS_FILE" >&2; exit 1; }
  done
}

row() { printf '%s\t%s\n' "$1" "$2"; }

need gcp_project
project=$(tf_get gcp_project)

case "$STEP" in
  020-gcp-relay-bucket)
    need relay_bucket_name relay_sa_account_id
    bucket=$(tf_get relay_bucket_name)
    sa="$(tf_get relay_sa_account_id)@${project}.iam.gserviceaccount.com"
    row "google_storage_bucket.relay" "${project}/${bucket}"
    row "google_service_account.relay" "projects/${project}/serviceAccounts/${sa}"
    row "google_storage_bucket_iam_member.relay_object_user" \
      "b/${bucket} roles/storage.objectUser serviceAccount:${sa}"
    ;;
  040-cloud-sql-postgres)
    need instance_name database_name dsn_secret_id owner_dsn_secret_id
    instance=$(tf_get instance_name)
    row "google_sql_database_instance.hub" "projects/${project}/instances/${instance}"
    row "google_sql_database.spool" \
      "projects/${project}/instances/${instance}/databases/$(tf_get database_name)"
    row "google_secret_manager_secret.hub_db_dsn" "projects/${project}/secrets/$(tf_get dsn_secret_id)"
    row "google_secret_manager_secret.hub_db_owner_dsn" "projects/${project}/secrets/$(tf_get owner_dsn_secret_id)"
    ;;
  *)
    echo "FATAL: no import table for step '$STEP' (have: 020-gcp-relay-bucket 040-cloud-sql-postgres; 030 has do_tf_030_import_existing_cloud_run)" >&2
    exit 2
    ;;
esac
exit 0
