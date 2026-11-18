#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 162 case C46 (row T7a, SPL-5882; owner poll 00d28227 Q1 B):
#          terraform step 071-gcp-evlog-reader-sa makes the read-only
#          event-log reader SA and nothing else, statically (no terraform,
#          no network; fast tier):
#   1. exactly two resources: one google_service_account (account_id from
#      var.evlog_reader_sa_id) and one google_project_iam_member, role
#      roles/logging.viewer, on var.gcp_project, for that SA. Resource
#      headers are read in any form (quoted or bare labels, indented).
#   2. no key and no other grant: no google_service_account_key, no
#      local_file / local_sensitive_file, no *_iam_binding / *_iam_policy,
#      no other role, no module, no *.tf.json (which these checks do not
#      read); no output names a key.
#   3. the cnf: all.env.yaml sets env.gcp.evlog_reader_sa_id: spl-evlog-reader
#      (one key), and the rendered dev and prd tfvars carry it, their own
#      project and state bucket, under prefix terraform/071-gcp-evlog-reader-sa.
#   4. checkov: the baseline has no row for this step (it must pass clean).
#   5. CONTROLS on a copy of the step: a planted google_service_account_key,
#      a planted key in bare-label form, a second role, roles/owner in place
#      of the viewer role and a planted *.tf.json each fail 1 or 2.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
STEP=071-gcp-evlog-reader-sa
SD="$PROJ_ROOT/src/terraform/$STEP"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0
tmp_dir

[[ -d "$SD" ]] && pass "$STEP exists" || { fail "$STEP dir missing"; exit 1; }

# code_of <dir> - every .tf of the step, comments dropped
code_of() { sed -E 's/^[[:space:]]*(#|\/\/).*$//; s/[[:space:]]+(#|\/\/).*$//' "$1"/*.tf; }

# two_resources <dir> - exactly the SA and one project member, logging.viewer
two_resources() {
  local all got
  all=$(code_of "$1")
  got=$(sed -nE 's/^[[:space:]]*resource[[:space:]]+"?([A-Za-z0-9_-]+)"?[[:space:]]+"?([A-Za-z0-9_-]+)"?.*/\1.\2/p' <<<"$all" | sort | tr '\n' ' ')
  [[ "$got" == 'google_project_iam_member.evlog_reader_logging_viewer google_service_account.evlog_reader ' ]] || return 1
  [[ "$(grep -E '^[[:space:]]*role[[:space:]]*=' <<<"$all" | tr -d ' ')" == 'role="roles/logging.viewer"' ]] || return 1
  grep -qE '^[[:space:]]*account_id[[:space:]]*=[[:space:]]*var\.evlog_reader_sa_id$' <<<"$all" || return 1
  awk '/^resource "google_project_iam_member"/ { r = 1 }
       r && /project *= *var\.gcp_project$/ { p = 1 }
       r && /member *= *"serviceAccount:\$\{google_service_account\.evlog_reader\.email\}"$/ { m = 1 }
       r && /^}/ { r = 0 } END { exit !(p && m) }' <<<"$all"
}

# no_key_no_grant <dir> - no key, no file, no authoritative IAM, no module,
# no *.tf.json, no output naming a key
no_key_no_grant() {
  local all
  compgen -G "$1/*.tf.json" >/dev/null && return 1
  all=$(code_of "$1")
  ! grep -qE 'google_service_account_key|local_(sensitive_)?file|_iam_(binding|policy)|private_key|^[[:space:]]*module[[:space:]]' <<<"$all" || return 1
  ! awk '/^[[:space:]]*output[[:space:]]/ { o = 1 } o && /key/ { f = 1 } o && /^}/ { o = 0 } END { exit !f }' <<<"$all"
}

two_resources "$SD" && pass "1. one SA (account_id = var.evlog_reader_sa_id) and one project member, roles/logging.viewer on var.gcp_project" \
  || fail "1. the step's resources or role differ: $(code_of "$SD" | grep -E '^[[:space:]]*(resource|role[[:space:]]*=)' | tr -s ' ' | paste -sd ';')"
no_key_no_grant "$SD" && pass "2. no key, no key file, no binding/policy, no module, no *.tf.json, no key output" \
  || fail "2. the step makes a key, a file or another grant"

# --- 3. the cnf and the renders ------------------------------------------------
[[ "$(yq -r '.env.gcp.evlog_reader_sa_id // ""' "$CNF/all.env.yaml")" == spl-evlog-reader ]] \
  && [[ $(grep -c 'evlog_reader_sa_id:' "$CNF/all.env.yaml") == 1 ]] \
  && pass "3. all.env.yaml: env.gcp.evlog_reader_sa_id: spl-evlog-reader, once" || fail "3. all.env.yaml lacks env.gcp.evlog_reader_sa_id: spl-evlog-reader"
for e in dev prd; do
  v="$CNF/$e/tf/$STEP.vars.tfvars"; b="$CNF/$e/tf/$STEP.backend-config.tfvars"
  grep -qx 'evlog_reader_sa_id = "spl-evlog-reader"' "$v" 2>/dev/null && grep -qE "^gcp_project += \"csi-spl-$e\"$" "$v" \
    && grep -qE "^env += \"$e\"$" "$v" && grep -qx "bucket = \"csi-spl-$e-tfstate\"" "$b" 2>/dev/null \
    && grep -qx "prefix = \"terraform/$STEP\"" "$b" \
    && pass "3. $e render: the SA id, project csi-spl-$e, its state bucket, prefix terraform/$STEP" || fail "3. $e render: $(cat "$v" "$b" 2>&1)"
done

# --- 4. checkov: no baseline row ------------------------------------------------
! grep -q "/$STEP/" "$PROJ_ROOT/src/terraform/.checkov.baseline" && pass "4. the checkov baseline has no row for $STEP" || fail "4. the checkov baseline lists $STEP"

# --- 5. controls --------------------------------------------------------------------
plant() { rm -rf "$T/s"; cp -r "$SD" "$T/s"; }
plant; printf '\nresource "google_service_account_key" "k" {\n  service_account_id = google_service_account.evlog_reader.name\n}\n' >>"$T/s/03-sa.tf"
! two_resources "$T/s" && ! no_key_no_grant "$T/s" && pass "5. CONTROL: a planted google_service_account_key fails 1 and 2" || fail "5. a planted key passed"
plant; printf '\n  resource google_service_account_key k {\n  service_account_id = google_service_account.evlog_reader.name\n}\n' >>"$T/s/03-sa.tf"
! two_resources "$T/s" && pass "5. CONTROL: a planted key in bare-label form fails 1" || fail "5. a bare-label key passed"
plant; printf '\nresource "google_project_iam_member" "x" {\n  project = var.gcp_project\n  role    = "roles/logging.admin"\n  member  = "serviceAccount:${google_service_account.evlog_reader.email}"\n}\n' >>"$T/s/03-sa.tf"
! two_resources "$T/s" && pass "5. CONTROL: a second role fails 1" || fail "5. a second role passed"
plant; sed -i 's|roles/logging.viewer|roles/owner|' "$T/s/03-sa.tf"
! two_resources "$T/s" && pass "5. CONTROL: roles/owner in place of logging.viewer fails 1" || fail "5. roles/owner passed"
plant; echo '{"resource":{"google_service_account_key":{"k":{}}}}' >"$T/s/09-key.tf.json"
! no_key_no_grant "$T/s" && pass "5. CONTROL: a planted *.tf.json fails 2" || fail "5. a *.tf.json passed"

[[ $fails -eq 0 ]] && { echo "PASS: all"; exit 0; } || { echo "FAIL: $fails"; exit 1; }
