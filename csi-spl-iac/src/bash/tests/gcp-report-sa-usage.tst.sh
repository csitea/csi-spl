#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_report_sa_usage + sa-usage-report.py (security round 1 row 1,
#          spec 139), offline: gcloud is a stub that records every call.
#   1. SA_USAGE_DAYS / SA_USAGE_TARGET wrong -> refused before any gcloud call.
#   2. Read-only: every non-auth call pinned --account=<env SA>, in a private
#      gcloud config, no mutating verb; the filter names the principal and
#      the window.
#   3. The report: counts per service, method and permission from the
#      fixture, a DENIED permission kept apart, caller classes from the user
#      agent, the producing commands printed, no IP and no key path.
#   4. Files 0600 in a 0700 dir.
#   6. The IAM recommender insights: the target's exercised permissions per
#      role listed; another member's insight ignored; an unreadable list is
#      reported "unreadable", never as none.
#   5. A failing `logging read` -> rc != 0, FATAL, no report.
#   CONTROL: one more fixture entry moves the count (numbers come from data).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
F="$PROJ_ROOT/src/bash/run/gcp-report-sa-usage.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# entry <log> <service> <method> <ua> <perm> <granted>
entry() {
  printf '{"logName":"projects/csi-spl-dev/logs/cloudaudit.googleapis.com%%2F%s","timestamp":"2026-10-1%sT00:00:00Z","protoPayload":{"serviceName":"%s","methodName":"%s","requestMetadata":{"callerSuppliedUserAgent":"%s","callerIp":"198.51.100.7"},"authorizationInfo":[{"permission":"%s","granted":%s}]}}' \
    "$1" "${7:-1}" "$2" "$3" "$4" "$5" "$6"
}
TF='Terraform/1.9.8 (+https://www.terraform.io) terraform-provider-google/6.0'
GC='google-cloud-sdk gcloud/540.0.0 command/gcloud.run.deploy'
{
  echo '['
  entry activity run.googleapis.com google.cloud.run.v1.Services.ReplaceService "$GC" run.services.update true; echo ,
  entry activity run.googleapis.com google.cloud.run.v1.Services.ReplaceService "$GC" run.services.update true 2; echo ,
  entry data_access cloudsql.googleapis.com cloudsql.instances.connect "" cloudsql.instances.connect true; echo ,
  entry activity iam.googleapis.com SetIamPolicy "$TF" resourcemanager.projects.setIamPolicy true; echo ,
  entry data_access secretmanager.googleapis.com AccessSecretVersion "$TF" secretmanager.versions.access false
  echo ']'
} >"$T/entries.json"
jq '. + [.[0]]' "$T/entries.json" >"$T/entries-plus.json"

cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "projects get-iam-policy"*) echo '{"auditConfigs":[{"service":"allServices","auditLogConfigs":[{"logType":"DATA_READ"},{"logType":"ADMIN_READ"}]}]}' ;;
  "recommender insights list"*) [[ "${INS_FAIL:-}" == 1 ]] && exit 1
    echo '[{"observationPeriod":"7776000s","content":{"member":"serviceAccount:csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com","role":"roles/owner","currentTotalPermissionsCount":"9000","exercisedPermissions":[{"permission":"run.services.update"},{"permission":"secretmanager.versions.access"}],"inferredPermissions":[{"permission":"run.services.get"}]}},{"content":{"member":"user:other@example.com","role":"roles/viewer","exercisedPermissions":[{"permission":"other.only.perm"}]}}]' ;;
  "logging read"*) [[ "${READ_FAIL:-}" == 1 ]] && { echo "ERROR: PERMISSION_DENIED" >&2; exit 1; }; cat "$ENTRIES" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    ENTRIES="$T/entries.json" SA_USAGE_DIR="$T/out-dir" ORG=csi APP=spl \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/gcp-report-sa-usage.func.sh; do source "$f"; done
    do_gcp_report_sa_usage' >"$T/out" 2>&1
}
MUT='(add-iam-policy-binding|remove-iam-policy-binding|set-iam-policy| create | delete | update |versions add|versions destroy|storage rm)'

# --- 1. input guards -----------------------------------------------------------
for bad in 0 401 abc; do
  act SA_USAGE_DAYS="$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'FATAL SA_USAGE_DAYS' "$T/out" && pass "1. SA_USAGE_DAYS=$bad refused before gcloud" || fail "1. SA_USAGE_DAYS=$bad: rc=$rc $(cat "$T/out")"
done
act SA_USAGE_TARGET='x" OR true'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'logging read' "$T/calls.log" && pass "1. a target that is not an email is refused before the read" || fail "1. bad target: rc=$rc"

# --- 2. read-only, pinned --------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 ]] && pass "2. a clean run (rc=0)" || fail "2. run: rc=$rc $(tail -5 "$T/out")"
n=$(grep -vE '\|auth ' "$T/calls.log" | wc -l); na=$(grep -vE '\|auth ' "$T/calls.log" | grep -c -- "--account=$DEV_SA")
[[ $n -eq 3 && $na -eq 3 ]] && pass "2. all 3 gcloud calls pinned --account=$DEV_SA" || fail "2. $na of $n calls pinned: $(cat "$T/calls.log")"
grep -q '<unset>|' "$T/calls.log" && fail "2. a call ran under the shared config" || pass "2. every call ran in a private gcloud config"
grep -qE "$MUT" "$T/calls.log" && fail "2. a mutating verb: $(grep -E "$MUT" "$T/calls.log")" || pass "2. no mutating gcloud verb"
grep -q "principalEmail=\"$DEV_SA\" AND timestamp>=\"20" <<<"$(grep 'logging read' "$T/calls.log")" && pass "2. the filter names the env SA and the window start" || fail "2. filter: $(grep 'logging read' "$T/calls.log")"

# --- 3. report -------------------------------------------------------------------
md=$(find "$T/out-dir" -name 'dev-*.md' | sed -n 1p)
[[ -s "$md" ]] && pass "3. the report lands ($(basename "$md"))" || fail "3. no report in $T/out-dir"
grep -q 'Entries: \*\*5\*\*' "$md" && pass "3. 5 entries counted" || fail "3. entries: $(grep Entries "$md")"
grep -q '^### run.googleapis.com (2 entries)' "$md" && grep -q '| `google.cloud.run.v1.Services.ReplaceService` | 2 |' "$md" && pass "3. per service and method counts" || fail "3. run counts: $(grep -A4 'run.googleapis' "$md")"
grep -q 'secretmanager.versions.access' <<<"$(grep -A3 'permission (DENIED)' "$md")" && ! grep -q '^- `secretmanager.versions.access`' <<<"$(sed -n '/^## All distinct/,/^## IAM recommender/p' "$md")" && pass "3. a denied permission is kept apart, not in the granted list" || fail "3. denied: $(grep -A3 DENIED "$md")"
grep -q '^## All distinct granted permissions (3)' "$md" && pass "3. 3 distinct granted permissions" || fail "3. distinct: $(grep 'All distinct' "$md")"
grep -q '| terraform | iam.googleapis.com | 1 |' "$md" && grep -q '| gcloud | run.googleapis.com | 2 |' "$md" && grep -q '| (no user agent) | cloudsql.googleapis.com | 1 |' "$md" \
  && pass "3. caller classes from the user agent" || fail "3. callers: $(grep -A8 'caller class' "$md")"
grep -q 'Produced by: `gcloud logging read' "$md" && grep -q 'Produced by: `gcloud projects get-iam-policy' "$md" && pass "3. each section names its command" || fail "3. commands missing"
grep -q '`allServices`: ADMIN_READ, DATA_READ' "$md" && pass "3. the enabled data-access logs are listed" || fail "3. auditConfigs: $(grep -A3 'Audit logs' "$md")"
grep -qE '198\.51\.100\.7|\.gcp/|key-csi' "$md" "$T/out" && fail "3. an IP or a key path reached the report" || pass "3. no IP, no key path in the report or output"

# --- 4. modes ---------------------------------------------------------------------
[[ "$(stat -c %a "$T/out-dir")" == 700 && "$(stat -c %a "$md")" == 600 ]] && pass "4. dir 0700, report 0600" || fail "4. modes: $(stat -c '%a %n' "$T/out-dir" "$md")"

# --- 6. recommender insights -----------------------------------------------------
grep -q '| `roles/owner` | 2 | 1 | 9000 | 7776000s |' "$md" && grep -q '^- `secretmanager.versions.access`$' "$md" && pass "6. the target's exercised permissions per role" || fail "6. insights: $(grep -A12 'IAM recommender' "$md")"
grep -q 'other.only.perm' "$md" && fail "6. another member's insight leaked in" || pass "6. another member's insight ignored"
rm -rf "$T/out-dir"; act INS_FAIL=1; rc=$?
md=$(find "$T/out-dir" -name 'dev-*.md' | sed -n 1p)
[[ $rc -eq 0 ]] && grep -q '\*\*unreadable\*\*' "$md" && grep -q 'WARN gcloud recommender' "$T/out" && pass "6. an unreadable insight list: reported unreadable, the audit-log part still lands" || fail "6. ins fail: rc=$rc $(grep -A3 'IAM recommender' "$md")"

# --- 5. failing read -----------------------------------------------------------------
rm -rf "$T/out-dir"; act READ_FAIL=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL gcloud logging read' "$T/out" && [[ -z "$(find "$T/out-dir" -name '*.md' -size +0)" ]] && pass "5. a failing read: rc=$rc, FATAL, no report" || fail "5. read fail: rc=$rc $(tail -3 "$T/out")"

# --- CONTROL ------------------------------------------------------------------------
rm -rf "$T/out-dir"; act ENTRIES="$T/entries-plus.json"
md=$(find "$T/out-dir" -name 'dev-*.md' | sed -n 1p)
grep -q 'Entries: \*\*6\*\*' "$md" && grep -q '| `google.cloud.run.v1.Services.ReplaceService` | 3 |' "$md" && pass "CONTROL: one more entry moves the counts to 6 and 3" || fail "CONTROL: $(grep Entries "$md")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
