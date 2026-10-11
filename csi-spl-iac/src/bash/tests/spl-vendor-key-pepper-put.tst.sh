#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_vendor_key_pepper_put (spec 127 I1) adds the one pepper
#          version to 057's empty slot without the value ever reaching argv,
#          stdout, stderr or a file of ours.
#   1. DRY_RUN=1 (default), empty slot: reports, adds nothing
#   2. DRY_RUN=0, empty slot: one "versions add --data-file=-" fed 32 bytes on
#      stdin; verified by the new version's state (versions describe ->
#      ENABLED), NEVER by reading it back: the project SA is no accessor (only
#      the hub runtime SA is, 4.2), so an access call is refused (applied
#      2026-10-11: the old length check exited 1 after a good add); every call
#      carries --account; the bytes are in no argv and no output
#   2b. CONTROL: an add that names no version -> refused, rc 1
#   3. CONTROL: an enabled version exists -> nothing added (a new pepper would
#      change every stored fingerprint)
#   4. CONTROL: no slot (057 not applied) -> refused, nothing added
#   5. CONTROL: DRY_RUN=2 -> refused before any gcloud call
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-vendor-key-pepper-put.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
require_action "$ACTION"

# the stub keeps the "secret" in $T/store; SLOT=none removes the slot
stub gcloud '
echo "$*" >>"$GC_CALLS"
case "$1 $2 $3" in
  "secrets describe "*) [[ "${SLOT:-yes}" == yes ]] ;;
  "secrets versions list") [[ -s "$STORE" ]] && echo "projects/o-a-dev/secrets/pep-z/versions/1"; exit 0 ;;
  "secrets versions add") cat >"$STORE"; [[ "${ADD_NAME:-yes}" == yes ]] && echo "projects/o-a-dev/secrets/pep-z/versions/1"; exit 0 ;;
  "secrets versions describe") [[ -s "$STORE" ]] && echo ENABLED ;;
  "secrets versions access") echo "PERMISSION_DENIED: secretmanager.versions.access" >&2; exit 1 ;;
  *) exit 9 ;;
esac'

cat >"$T/cnf.yaml" <<'YAML'
env:
  vendor_keys:
    pepper_secret: pep-z
YAML

# run_action [env assignments...] -> rc; output in $T/out, calls in $T/calls.log
run_action() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" STORE="$T/store" ACTION="$ACTION" CNF="$T/cnf.yaml" \
    ENV=dev ORG=o APP=a APP_PATH="$T" "$@" \
    bash -c 'do_log(){ echo "$*"; }; do_require_bin(){ :; }
      do_gcp_spl_proj_id(){ export PROJ_ID=o-a-dev; }
      do_spl_merged_cnf(){ cp "$CNF" "$3"; }
      do_gcp_pin_account(){ export GCP_ACCOUNT=o-a-dev@o-a-dev.iam.gserviceaccount.com; }
      source "$ACTION"; do_spl_vendor_key_pepper_put' >"$T/out" 2>&1
}

# --- 1. dry run ----------------------------------------------------------------------
rm -f "$T/store"; run_action; rc=$?
[[ $rc -eq 0 && ! -e "$T/store" ]] && grep -qF 'DRY_RUN would add' "$T/out" && pass "DRY_RUN default: reports, adds nothing" || fail "dry: rc=$rc out=$(cat "$T/out")"

# --- 2. the add ------------------------------------------------------------------------
rm -f "$T/store"; run_action DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(wc -c <"$T/store")" -eq 32 ]] && grep -qF 'versions/1 is ENABLED' "$T/out" && pass "DRY_RUN=0: a 32-byte version, verified ENABLED by describe" || fail "add: rc=$rc out=$(cat "$T/out")"
grep -q 'versions access' "$T/calls.log" && fail "the action reads the pepper back (the project SA is no accessor)" || pass "the value is never read back"
grep -qE 'versions describe projects/o-a-dev/secrets/pep-z/versions/1 ' "$T/calls.log" && pass "describes the version the add named" || fail "describe call: $(cat "$T/calls.log")"
[[ "$(grep -c 'versions add pep-z' "$T/calls.log")" -eq 1 ]] && grep -qF -- '--data-file=-' "$T/calls.log" && pass "one versions add, value on stdin" || fail "add call: $(cat "$T/calls.log")"
[[ "$(grep -vc -- '--account=o-a-dev@o-a-dev.iam.gserviceaccount.com' "$T/calls.log")" -eq 0 ]] && pass "every gcloud call carries --account" || fail "unpinned: $(cat "$T/calls.log")"
hex=$(od -An -tx1 "$T/store" | tr -d ' \n')
if od -An -tx1 "$T/calls.log" "$T/out" | tr -d ' \n' | grep -F "$hex" >/dev/null; then fail "the pepper bytes reached an argv or the output"; else pass "the pepper is in no argv and no output"; fi

# --- 2b. CONTROL: the add names no version -----------------------------------------------
rm -f "$T/store"; run_action DRY_RUN=0 ADD_NAME=no; rc=$?
[[ $rc -eq 1 ]] && grep -qF 'named no version' "$T/out" && pass "CONTROL: an add that names no version -> rc 1" || fail "CONTROL noname: rc=$rc out=$(cat "$T/out")"

# --- 3. CONTROL: a version exists --------------------------------------------------------
cp "$T/store" "$T/store.before"; run_action DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && cmp -s "$T/store" "$T/store.before" && ! grep -q 'versions add' "$T/calls.log" \
  && pass "CONTROL: an enabled version exists -> nothing added" || fail "CONTROL exists: rc=$rc calls=$(cat "$T/calls.log")"

# --- 4. CONTROL: no slot -------------------------------------------------------------------
rm -f "$T/store"; run_action DRY_RUN=0 SLOT=none; rc=$?
[[ $rc -eq 1 && ! -e "$T/store" ]] && grep -qF 'apply step 057 first' "$T/out" && pass "CONTROL: no slot -> refused, nothing added" || fail "CONTROL noslot: rc=$rc out=$(cat "$T/out")"

# --- 5. CONTROL: a bad DRY_RUN --------------------------------------------------------------
run_action DRY_RUN=2; rc=$?
[[ $rc -eq 2 && ! -s "$T/calls.log" ]] && pass "CONTROL: DRY_RUN=2 -> refused, gcloud never called" || fail "CONTROL dry2: rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
