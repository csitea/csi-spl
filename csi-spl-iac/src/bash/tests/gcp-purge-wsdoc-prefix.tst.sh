#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_purge_wsdoc_prefix lists, then deletes, every generation of
#          every object under a doc prefix and its .history/ prefix in one
#          workspace's docs bucket (step 052). gcloud is a function stub that
#          records its argv and serves a fake versioned listing from a file;
#          the cnf, project and account resolvers are stubbed, so nothing
#          reaches GCP. Tenant, prefix and objects are synthetic.
#   1. bash -n, the action exists
#   2. refused before any gcloud call: DRY_RUN=2, a bad TENANT_ID, a
#      WSDOC_PREFIX that is empty, has no trailing /, starts with a dot, holds
#      .. or is absolute, a tenant that is not a 052 workspace, an env with no
#      bucket_prefix
#   3. dry run (the default): one `would delete <name>#<gen>` per generation,
#      the counts, no rm; the bucket is bucket_prefix + tenant; every gcloud
#      call carries --account; the soft-deleted count is reported
#   4. DRY_RUN=0: rm gets exactly the listed <url>#<gen>, the re-list is
#      empty, after: 0; a generation still there after the rm is a FATAL
#   5. a listing gcloud refuses is a FATAL and deletes nothing; no match is
#      an empty listing (counts 0, no rm)
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
F="$RUN/gcp-purge-wsdoc-prefix.func.sh"
SDK="$PROJ_ROOT/lib/bash/funcs/gcp-temp-sdk-config.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

require_action "$F"
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

B=gs://test-prd-docs-w1
cat >"$T/objects" <<EOF
$B/p1/a.md#101
$B/p1/a.md#102
$B/p1/sub/b.md#201
$B/.history/p1/a.md/20260101T000000.000000000Z--u1--put.md#301
$B/.history/p1/a.md/20260102T000000.000000000Z--u1--del.md#302
$B/p10/c.md#401
EOF
cp "$T/objects" "$T/objects.orig"

# run_case [VAR=value ...] - the action in a subshell; output in $T/o, rc in
# $rc, gcloud argv lines in $T/calls.
#   stub knobs: LS=denied (every ls fails)  RM=keep (rm deletes nothing)
#               CNF=noprefix (no bucket_prefix in the cnf)
run_case() {
  : >"$T/calls"
  cp "$T/objects.orig" "$T/objects"
  env -u DRY_RUN -u TENANT_ID -u WSDOC_PREFIX F="$F" SDK="$SDK" TD="$T" ENV=prd \
    TENANT_ID=w1 WSDOC_PREFIX=p1/ "$@" bash -c '
    do_log(){ echo "$*"; }
    do_require_bin(){ :; }
    do_gcp_spl_proj_id(){ PROJ_ID="test-${ENV}"; }
    do_gcp_pin_account(){ GCP_ACCOUNT=stub-sa@example.com; }
    do_spl_merged_cnf(){
      if [[ "${CNF:-}" == noprefix ]]; then
        printf "env:\n  steps:\n    052-gcs-workspace-docs:\n      workspaces: [w1]\n" >"$3"
      else
        printf "env:\n  steps:\n    052-gcs-workspace-docs:\n      bucket_prefix: test-prd-docs-\n      workspaces: [w0, w1]\n" >"$3"
      fi
    }
    gcloud(){
      echo "gcloud $*" >>"$TD/calls"
      local a url=""
      for a in "$@"; do [[ "$a" == gs://* ]] && url="$a"; done
      case "$1 $2" in
        "storage ls")
          [[ "${LS:-}" == denied ]] && { echo "ERROR: 403 permission denied"; return 1; }
          [[ " $* " == *" --soft-deleted "* ]] && { echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects."; return 1; }
          local pre="${url%\*\*}" hit
          hit=$(grep -F "$pre" "$TD/objects" | while IFS= read -r l; do [[ "$l" == "$pre"* ]] && echo "$l"; done)
          [[ -n "$hit" ]] || { echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects."; return 1; }
          echo "$hit" ;;
        "storage rm")
          [[ "${RM:-}" == keep ]] && return 0
          for a in "$@"; do [[ "$a" == gs://* ]] && { grep -vxF "$a" "$TD/objects" >"$TD/objects.n"; mv "$TD/objects.n" "$TD/objects"; }; done; return 0 ;;
      esac
    }
    source "$SDK"
    source "$F"
    do_gcp_purge_wsdoc_prefix
    echo "rc=$?"' >"$T/o" 2>&1
  rc=$(sed -n 's/^rc=//p' "$T/o" | tail -1)
}
no_gcloud() { [[ ! -s "$T/calls" ]]; }
all_in() { # <line> <word>... -> 0 when every word is a word of the line
  local l=" $1 " w; shift
  for w in "$@"; do [[ "$l" == *" $w "* ]] || return 1; done
}

# --- 2. refusals before any gcloud call ---------------------------------------------------
refused() { # <label> <grep>
  if [[ "$rc" == 1 ]] && no_gcloud && grep -q -- "$2" "$T/o"; then pass "$1"; else fail "$1 (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"; fi
}
run_case DRY_RUN=2;              refused "DRY_RUN=2 is refused" 'DRY_RUN must be 0 or 1'
run_case TENANT_ID='W1/x';       refused "a TENANT_ID that is not a slug is refused" 'TENANT_ID must be a workspace slug'
run_case WSDOC_PREFIX=;          refused "an empty WSDOC_PREFIX is refused (no whole-bucket purge)" 'WSDOC_PREFIX must be'
run_case WSDOC_PREFIX=p1;        refused "a WSDOC_PREFIX without a trailing / is refused (p1 would match p10)" 'WSDOC_PREFIX must be'
run_case WSDOC_PREFIX=.history/; refused "a WSDOC_PREFIX starting with a dot is refused" 'WSDOC_PREFIX must be'
run_case WSDOC_PREFIX=../p1/;    refused "a WSDOC_PREFIX with .. is refused" 'WSDOC_PREFIX must be'
run_case WSDOC_PREFIX=/p1/;      refused "an absolute WSDOC_PREFIX is refused" 'WSDOC_PREFIX must be'
run_case TENANT_ID=w9;           refused "a tenant that is not a 052 workspace is refused" 'is not one of ENV=prd'
run_case CNF=noprefix;           refused "an env with no 052 bucket_prefix is refused" 'has no steps.052-gcs-workspace-docs.bucket_prefix'

# --- 3. dry run -----------------------------------------------------------------------------
run_case
if [[ "$rc" == 0 ]] && grep -q "bucket=$B prefix=p1/" "$T/o" &&
  [[ "$(grep -c 'DRY_RUN would delete ' "$T/o")" == 5 ]] &&
  grep -qxF "INFO DRY_RUN would delete p1/a.md#101" "$T/o" &&
  grep -qxF "INFO DRY_RUN would delete .history/p1/a.md/20260102T000000.000000000Z--u1--del.md#302" "$T/o" &&
  ! grep -q 'p10/' "$T/o" &&
  grep -qxF "INFO before: docs=2 history_objects=2 generations=5" "$T/o" &&
  grep -q 'soft-deleted generations .*: 0' "$T/o" &&
  ! grep -q 'storage rm' "$T/calls" && grep -q 'OK DRY_RUN nothing was deleted' "$T/o"; then
  pass "dry run lists every generation under p1/ and .history/p1/ (not p10/), counts them, deletes nothing"
else
  fail "dry run (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"
fi
[[ -s "$T/calls" && "$(grep -vc -- '--account=stub-sa@example.com' "$T/calls")" == 0 ]] &&
  pass "every gcloud call carries --account=<the env SA>" || fail "a gcloud call without --account: $(cat "$T/calls")"
grep -q "storage ls --all-versions $B/p1/\*\*" "$T/calls" && grep -q "storage ls --all-versions $B/.history/p1/\*\*" "$T/calls" &&
  pass "it lists all versions of the doc prefix and of its .history/ prefix" || fail "list calls: $(cat "$T/calls")"

# --- 4. DRY_RUN=0 ---------------------------------------------------------------------------
run_case DRY_RUN=0
rmline=$(grep 'storage rm' "$T/calls")
if [[ "$rc" == 0 ]] && [[ "$(grep -c 'storage rm' "$T/calls")" == 1 ]] &&
  all_in "$rmline" "$B/p1/a.md#101" "$B/p1/a.md#102" "$B/p1/sub/b.md#201" \
    "$B/.history/p1/a.md/20260101T000000.000000000Z--u1--put.md#301" \
    "$B/.history/p1/a.md/20260102T000000.000000000Z--u1--del.md#302" && [[ " $rmline " != *"p10/"* ]] &&
  grep -qxF "INFO after: docs=0 history_objects=0 generations=0" "$T/o" &&
  grep -q 'OK purged 5 generation(s)' "$T/o" && grep -qxF "$B/p10/c.md#401" "$T/objects"; then
  pass "DRY_RUN=0 removes exactly the 5 generations, re-lists 0, leaves p10/ alone"
else
  fail "purge (rc=$rc): $(cat "$T/o") / $rmline"
fi
run_case DRY_RUN=0 RM=keep
[[ "$rc" == 1 ]] && grep -q 'FATAL 5 generation(s) are left' "$T/o" &&
  pass "a generation still there after the rm is a FATAL" || fail "leftover (rc=$rc): $(cat "$T/o")"

# --- 5. list errors, no match ---------------------------------------------------------------
run_case DRY_RUN=0 LS=denied
[[ "$rc" == 1 ]] && grep -q 'FATAL cannot list' "$T/o" && ! grep -q 'storage rm' "$T/calls" &&
  pass "a refused listing is a FATAL and deletes nothing" || fail "denied (rc=$rc): $(cat "$T/o")"
run_case DRY_RUN=0 WSDOC_PREFIX=none/
[[ "$rc" == 0 ]] && grep -qxF "INFO before: docs=0 history_objects=0 generations=0" "$T/o" && ! grep -q 'storage rm' "$T/calls" &&
  pass "no match is an empty listing: counts 0, no rm" || fail "no match (rc=$rc): $(cat "$T/o")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
