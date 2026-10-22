#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_audit_wsdoc_buckets (spec 114 9.4 guard 3, tasks R1) finds
#          every breach of the per-workspace docs buckets and exits non-zero
#          on any. gcloud is a function stub serving a fake bucket list,
#          policies and qto-assets listings from files; the hub DB read goes
#          to a fake csi-spl-orc ./run printing psql-like rows; cnf, project
#          and account resolvers are stubbed, so nothing reaches GCP or a DB.
#          Workspaces, buckets, members and digests are synthetic.
#   1. bash -n, the action exists
#   2. refused before any gcloud call: a bad ENV, a failed DB read, a DB with
#      no workspace, an env with no bucket_prefix
#   3. a clean env: 0 findings, rc 0; every gcloud call carries --account;
#      the 051-style bucket without the dash is not a 052 bucket
#   4. red controls, each rc 1 with its FINDING line: allUsers and
#      allAuthenticatedUsers in a policy, a workspace missing from the bucket
#      list, public_access_prevention inherited, uniform access off, a
#      foreign member (a human one printed redacted), an unreadable policy
#   5. on-050: a ref with no qto-assets/<sha> object is a finding, one with
#      it is not; every ref of a workspace with no bucket is a finding
#   6. ORG/APP unset, or as ./run sets them from the checkout dir (APP=<org>-
#      <app>): the action reads them from the project dir's own name and
#      finds <org>-<app>-orc (SPL-2945 send-back)
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
F="$PROJ_ROOT/src/bash/run/gcp-audit-wsdoc-buckets.func.sh"
SDK="$PROJ_ROOT/lib/bash/funcs/gcp-temp-sdk-config.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

# the fake csi-spl-orc: ./run -a do_spl_db_query prints psql-like rows
mkdir -p "$T/app/t-x-orc"
cat >"$T/app/t-x-orc/run" <<'EOF'
#!/bin/bash
[[ -n "${CLOUDSDK_CONFIG:-}" ]] && { echo "orc got the caller's CLOUDSDK_CONFIG"; exit 9; }
[[ "${DBFAIL:-}" == 1 ]] && { echo "FATAL proxy"; exit 1; }
echo " ?column? "; echo "----------"
case "$SQL" in
  *"from tenants"*) sed 's/^/ WS /' "$TD/ws" ;;
  *workspace_doc_item*) sed 's/^/ ASSET /' "$TD/refs" ;;
esac
echo "($(wc -l <"$TD/ws") rows)"
EOF
chmod +x "$T/app/t-x-orc/run"

HUB=serviceAccount:hub-rt@test-prd.iam.gserviceaccount.com
S1=$(printf 'a%.0s' {1..64}) S2=$(printf 'b%.0s' {1..64})
pol() { # <members json array as role=member,...> -> a policy JSON
  local b='{"bindings":[{"role":"roles/storage.legacyBucketOwner","members":["projectOwner:test-prd","projectEditor:test-prd"]},{"role":"roles/storage.legacyBucketReader","members":["projectViewer:test-prd"]},{"role":"roles/storage.objectAdmin","members":["'"$HUB"'"]}'
  local x
  for x in "$@"; do b+=',{"role":"'"${x%%=*}"'","members":["'"${x#*=}"'"]}'; done
  echo "$b],\"etag\":\"x\"}"
}

# fixtures: 3 workspaces, each with a bucket; the 051 bucket has no dash
fixture() {
  rm -f "$T"/pol.* && printf 'w1\nw2\nw3\n' >"$T/ws"
  printf 'w1 %s\n' "$S1" >"$T/refs"
  printf 'p-docs\tTrue\tenforced\np-docs-w1\tTrue\tenforced\np-docs-w2\tTrue\tenforced\np-docs-w3\tTrue\tenforced\np-files\tTrue\tenforced\n' >"$T/buckets"
  printf 'gs://p-docs-w1/qto-assets/%s\n' "$S1" >"$T/assets.w1"
  rm -f "$T/assets.w2" "$T/assets.w3"
}

# run_case [VAR=value ...] - the action in a subshell; output in $T/o, rc in
# $rc, gcloud argv lines in $T/calls. Edit the fixture files before the call.
#   stub knobs: CNF=noprefix (no bucket_prefix); OAP=<resolve-oap.func.sh>
#   sources the real resolver; NOORGAPP=1 unsets ORG and APP
run_case() {
  : >"$T/calls"
  env -u CLOUDSDK_CONFIG -u PROJ_PATH F="$F" SDK="$SDK" TD="$T" ENV=prd APP_PATH="$T/app" ORG=t APP=x "$@" bash -c '
    do_log(){ echo "$*"; }
    [[ -n "${OAP:-}" ]] && source "$OAP"
    [[ "${NOORGAPP:-}" == 1 ]] && unset ORG APP
    do_require_bin(){ :; }
    do_gcp_spl_proj_id(){ PROJ_ID="test-${ENV}"; }
    do_gcp_pin_account(){ GCP_ACCOUNT=stub-sa@example.com; }
    do_spl_merged_cnf(){
      local p="      bucket_prefix: p-docs-\n"
      [[ "${CNF:-}" == noprefix ]] && p=""
      printf "env:\n  hub:\n    runtime_sa_account_id: hub-rt\n  steps:\n    052-gcs-workspace-docs:\n$p      workspaces: [w1]\n" >"$3"
    }
    gcloud(){
      echo "gcloud $*" >>"$TD/calls"
      local a url=""
      for a in "$@"; do [[ "$a" == gs://* ]] && url="$a"; done
      case "$1 $2 ${3:-}" in
        "storage buckets list") cat "$TD/buckets" ;;
        "storage buckets get-iam-policy")
          local b="${url#gs://}"
          [[ -f "$TD/pol.$b" ]] || { echo "{\"bindings\":[{\"role\":\"roles/storage.objectAdmin\",\"members\":[\"serviceAccount:hub-rt@test-prd.iam.gserviceaccount.com\"]}]}"; return 0; }
          [[ "$(cat "$TD/pol.$b")" == DENIED ]] && { echo "ERROR: 403" >&2; return 1; }
          cat "$TD/pol.$b" ;;
        storage\ ls\ *)
          local t="${url#gs://p-docs-}"; t="${t%%/*}"
          [[ -s "$TD/assets.$t" ]] || { echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects."; return 1; }
          cat "$TD/assets.$t" ;;
        *) echo "unexpected gcloud $*"; return 1 ;;
      esac
    }
    source "$SDK"
    source "$F"
    do_gcp_audit_wsdoc_buckets
    echo "rc=$?"' >"$T/o" 2>&1
  rc=$(sed -n 's/^rc=//p' "$T/o" | tail -1)
}
no_gcloud() { [[ ! -s "$T/calls" ]]; }
nfind() { grep -c '^FINDING ' "$T/o"; }

# --- 2. refusals ---------------------------------------------------------------------------
refused() { # <label> <grep>
  if [[ "$rc" == 1 ]] && no_gcloud && grep -q -- "$2" "$T/o"; then pass "$1"; else fail "$1 (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"; fi
}
fixture
run_case ENV=stg;        refused "ENV other than dev/prd is refused" 'ENV must be dev or prd'
run_case DBFAIL=1;       refused "a failed hub DB read is a FATAL, no gcloud call" 'the hub DB read failed'
: >"$T/ws"
run_case;                refused "a DB with no workspace is a FATAL (nothing to audit against)" 'lists no workspace'
fixture
run_case CNF=noprefix
[[ "$rc" == 1 ]] && grep -q 'has no steps.052-gcs-workspace-docs.bucket_prefix' "$T/o" && ! grep -q 'storage buckets' "$T/calls" &&
  pass "an env with no 052 bucket_prefix is refused before any bucket call" || fail "noprefix (rc=$rc): $(cat "$T/o")"

# --- 3. a clean env ------------------------------------------------------------------------
fixture
run_case
if [[ "$rc" == 0 ]] && [[ "$(nfind)" == 0 ]] && grep -q 'OK ENV=prd: 0 findings (3 052 buckets, 3 workspaces, 1 asset refs)' "$T/o" &&
  ! grep -q 'get-iam-policy gs://p-docs ' "$T/calls" && ! grep -q 'gs://p-files' "$T/calls"; then
  pass "a clean env: 0 findings, rc 0; only the <prefix><slug> buckets are audited"
else
  fail "clean (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"
fi
[[ -s "$T/calls" && "$(grep -vc -- '--account=stub-sa@example.com' "$T/calls")" == 0 ]] &&
  pass "every gcloud call carries --account=<the env SA>" || fail "a gcloud call without --account: $(cat "$T/calls")"
pol >"$T/pol.p-docs-w2"
run_case
[[ "$rc" == 0 && "$(nfind)" == 0 ]] && pass "the legacy project bindings and the hub runtime SA are no finding" ||
  fail "legacy (rc=$rc): $(cat "$T/o")"

# --- 4. red controls -----------------------------------------------------------------------
red() { # <label> <finding regex> [count]
  if [[ "$rc" == 1 ]] && grep -qE "^FINDING prd $2" "$T/o" && [[ "$(nfind)" == "${3:-1}" ]] &&
    grep -q "FATAL ENV=prd: ${3:-1} finding(s)" "$T/o"; then pass "$1"; else fail "$1 (rc=$rc): $(cat "$T/o")"; fi
}
fixture; pol roles/storage.objectViewer=allUsers >"$T/pol.p-docs-w2"; run_case
red "a policy with allUsers FAILS" 'public gs://p-docs-w2 roles/storage.objectViewer allUsers$'
fixture; pol roles/storage.objectViewer=allAuthenticatedUsers >"$T/pol.p-docs-w3"; run_case
red "a policy with allAuthenticatedUsers FAILS" 'public gs://p-docs-w3 roles/storage.objectViewer allAuthenticatedUsers$'
fixture; grep -v 'p-docs-w3' "$T/buckets" >"$T/b" && mv "$T/b" "$T/buckets"; run_case
red "a bucket list missing one workspace FAILS, naming it" 'no-bucket w3 \(want gs://p-docs-w3\)$'
fixture; sed -i 's/p-docs-w2\tTrue\tenforced/p-docs-w2\tTrue\tinherited/' "$T/buckets"; run_case
red "public_access_prevention inherited FAILS" 'not-enforced gs://p-docs-w2 public_access_prevention=inherited$'
fixture; sed -i 's/p-docs-w1\tTrue/p-docs-w1\tFalse/' "$T/buckets"; run_case
red "uniform bucket-level access off FAILS" 'not-uniform gs://p-docs-w1 uniform_bucket_level_access=False$'
fixture; pol roles/storage.objectViewer=serviceAccount:other@test-prd.iam.gserviceaccount.com roles/storage.objectAdmin=user:someone@example.com >"$T/pol.p-docs-w1"; run_case
red "a member other than the legacy bindings and the hub SA FAILS" 'member gs://p-docs-w1 roles/storage.objectViewer serviceAccount:other@' 2
if grep -q 'member gs://p-docs-w1 roles/storage.objectAdmin user:<redacted>$' "$T/o" && ! grep -q someone "$T/o"; then
  pass "a human member is a finding, printed redacted"
else
  fail "human member: $(cat "$T/o")"
fi
# every principal kind that can carry a person's address prints redacted
# (SPL-2945 D1); a domain names an organisation, not a person: printed
for x in 'deleted:user:jane.doe@example.com?uid=123=deleted:user:<redacted>' \
  'principal://iam.googleapis.com/locations/global/workforcePools/p/subject/jane.doe@example.com=principal://<redacted>' \
  'principalSet://iam.googleapis.com/locations/global/workforcePools/p/group/jane.doe@example.com=principalSet://<redacted>' \
  'group:jane.doe@example.com=group:<redacted>' 'deleted:group:jane.doe@example.com?uid=7=deleted:group:<redacted>'; do
  mem="${x%=*}"; want="${x##*=}"
  fixture; pol "roles/storage.objectViewer=$mem" >"$T/pol.p-docs-w1"; run_case
  if [[ "$rc" == 1 ]] && grep -qF "member gs://p-docs-w1 roles/storage.objectViewer $want" "$T/o" && ! grep -q jane "$T/o"; then
    pass "${want%<redacted>} member is a finding, printed redacted"
  else
    fail "${want%<redacted>} member not redacted (rc=$rc): $(grep member "$T/o")"
  fi
done
fixture; pol roles/storage.objectViewer=domain:example.com >"$T/pol.p-docs-w1"; run_case
red "a domain member is a finding, printed as is (an organisation, not a person)" 'member gs://p-docs-w1 roles/storage.objectViewer domain:example.com$'
fixture; echo DENIED >"$T/pol.p-docs-w2"; run_case
red "an unreadable policy is a finding, never private" 'unreadable gs://p-docs-w2 IAM policy$'
fixture; sed -i 's/p-docs-w2\tTrue\tenforced/p-docs-w2\tFalse\tinherited/' "$T/buckets"; pol r=allUsers >"$T/pol.p-docs-w2"
grep -v 'p-docs-w3' "$T/buckets" >"$T/b" && mv "$T/b" "$T/buckets"; run_case
red "every finding of a run is listed, not only the first" 'not-uniform gs://p-docs-w2' 4

# --- 5. on-050 -----------------------------------------------------------------------------
fixture; printf 'w1 %s\nw1 %s\n' "$S1" "$S2" >"$T/refs"; run_case
red "a ref with no qto-assets/<sha> object in its bucket is on-050" "on-050 w1 $S2\$"
fixture; printf 'w2 %s\n' "$S2" >"$T/refs"; run_case
red "a ref of a workspace whose qto-assets/ is empty is on-050" "on-050 w2 $S2\$"
fixture; printf 'w3 %s\nw3 %s\n' "$S1" "$S2" >"$T/refs"; grep -v 'p-docs-w3' "$T/buckets" >"$T/b" && mv "$T/b" "$T/buckets"; run_case
red "every ref of a workspace with no bucket is on-050 (+ its no-bucket)" "on-050 w3 $S2\$" 3
grep -q "storage ls gs://p-docs-w3" "$T/calls" && fail "listed qto-assets of a bucket that does not exist" ||
  pass "no listing of a bucket that does not exist"

# --- 6. ORG/APP from the project dir, not the checkout dir --------------------------------
OAPF="$PROJ_ROOT/lib/bash/funcs/resolve-oap.func.sh"
fixture; run_case OAP="$OAPF" PROJ_PATH="$T/app/t-x-iac" NOORGAPP=1
[[ "$rc" == 0 ]] && grep -q 'OK ENV=prd: 0 findings' "$T/o" && pass "ORG/APP unset: read from the project dir, <org>-<app>-orc found" ||
  fail "ORG/APP unset (rc=$rc): $(cat "$T/o")"
fixture; run_case OAP="$OAPF" PROJ_PATH="$T/app/t-x-iac" ORG=t APP=t-x
[[ "$rc" == 0 ]] && grep -q 'OK ENV=prd: 0 findings' "$T/o" && pass "APP=<org>-<app> as ./run sets it from the checkout dir: still <org>-<app>-orc" ||
  fail "APP=t-x (rc=$rc): $(cat "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
