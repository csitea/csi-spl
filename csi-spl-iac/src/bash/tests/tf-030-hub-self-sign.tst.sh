#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 190 row T2 (SPL-6152, gap G9; owner poll fd47ab36 Q2 B): the
#          hub's runtime SA may sign a GCS V4 URL as itself (IAM Credentials
#          signBlob, no key), statically (no terraform, no network):
#   1. 030 holds exactly one google_service_account_iam_member: role
#      roles/iam.serviceAccountTokenCreator, service_account_id =
#      google_service_account.hub.name, member = the same SA's email.
#   2. nothing in 030 grants a token or sign role on the PROJECT, nor
#      through an authoritative *_iam_binding / *_iam_policy, and 030 makes
#      no key.
#   3. CONTROLS on a copy of the step: the grant moved to the project, the
#      member changed to another SA, the grant dropped, and a planted
#      service-account key each fail 1 or 2.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
STEP=030-cloud-run-hub
SD="$PROJ_ROOT/src/terraform/$STEP"
fails=0
tmp_dir

[[ -d "$SD" ]] && pass "$STEP exists" || { fail "$STEP dir missing"; exit 1; }

# blocks_of <dir> <resource type> - each such resource block on one line,
# spaces and comments dropped
blocks_of() {
  sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//' "$1"/*.tf | awk -v t="$2" '
    $0 ~ "^[[:space:]]*resource[[:space:]]+\"?" t "\"?[[:space:]]" { r = 1; d = 0; b = "" }
    r { b = b $0; l = $0; n = gsub(/\{/, "{", l); m = gsub(/\}/, "}", l); d += n - m
        if (d == 0) { gsub(/[[:space:]]+/, "", b); print b; r = 0 } }'
}

# self_sign <dir> - the one SA member is tokenCreator of the hub SA on itself
self_sign() {
  local all
  all=$(blocks_of "$1" google_service_account_iam_member)
  [[ $(grep -c . <<<"$all") == 1 ]] || return 1
  grep -F 'service_account_id=google_service_account.hub.name' <<<"$all" \
    | grep -F 'role="roles/iam.serviceAccountTokenCreator"' \
    | grep -F 'member="serviceAccount:${google_service_account.hub.email}"' >/dev/null
}

# no_wide_grant <dir> - no project token/sign role, no binding/policy, no key
no_wide_grant() {
  local code
  code=$(sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//' "$1"/*.tf)
  ! blocks_of "$1" google_project_iam_member | grep -iE 'serviceAccountTokenCreator|signBlob|serviceAccountUser|iam\.serviceAccount' >/dev/null || return 1
  ! grep -qE 'google_(project|service_account)_iam_(binding|policy)|google_service_account_key' <<<"$code"
}

self_sign "$SD" && pass "1. one google_service_account_iam_member: roles/iam.serviceAccountTokenCreator of the hub SA on itself" \
  || fail "1. no self-sign grant: $(blocks_of "$SD" google_service_account_iam_member | paste -sd ';')"
no_wide_grant "$SD" && pass "2. no project-level token/sign role, no SA binding/policy, no key" \
  || fail "2. 030 grants a token role on the project, an authoritative SA policy or a key"

# --- 3. controls --------------------------------------------------------------------
F=08-hub-self-sign.tf
plant() { rm -rf "$T/s"; cp -r "$SD" "$T/s"; }
plant; printf 'resource "google_project_iam_member" "hub_sign" {\n  project = var.gcp_project\n  role    = "roles/iam.serviceAccountTokenCreator"\n  member  = "serviceAccount:${google_service_account.hub.email}"\n}\n' >"$T/s/$F"
! self_sign "$T/s" && ! no_wide_grant "$T/s" && pass "3. CONTROL: the grant on the project fails 1 and 2" || fail "3. a project grant passed"
plant; [[ -f "$T/s/$F" ]] && sed -i 's|member *= *"serviceAccount:${google_service_account.hub.email}"|member = "serviceAccount:other@example.com"|' "$T/s/$F"
! self_sign "$T/s" && pass "3. CONTROL: another SA as the member fails 1" || fail "3. another member passed"
plant; rm -f "$T/s/$F"
! self_sign "$T/s" && pass "3. CONTROL: the grant dropped fails 1" || fail "3. no grant passed"
plant; printf '\nresource "google_service_account_key" "k" {\n  service_account_id = google_service_account.hub.name\n}\n' >>"$T/s/03-runtime-sa.tf"
! no_wide_grant "$T/s" && pass "3. CONTROL: a planted key fails 2" || fail "3. a planted key passed"

[[ $fails -eq 0 ]] && { echo "PASS: all"; exit 0; } || { echo "FAIL: $fails"; exit 1; }
