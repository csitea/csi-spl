#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_s3_download_all creates each bucket's target dir with a plain
#          `mkdir -p`, as every sibling gcp-* action does. It used to read
#          `sudo -u <DEV_USER> mkdir -p ...`: bash parses `<DEV_USER>` as an
#          input redirection from a file named DEV_USER, so the line failed
#          for every bucket and the action always returned 1.
#   1. With gcloud / gsutil / sudo stubbed, one non-empty bucket is synced:
#      rc 0, the target dir exists, gsutil rsync ran into it, sudo never ran.
#   2. CONTROL: the same run with the old line put back returns 1, reports
#      "mkdir failed" and never reaches rsync, so 1 proves the fix.
#   3. Static: no command line of the action carries an unquoted <UPPER_CASE>
#      placeholder (a redirection in disguise).
# The action's absolute /opt/google-cloud-sdk/bin is pointed at the stubs in
# a copy of the action; nothing reaches GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export T

fails=0
ACTION="$RUN/gcp-s3-download-all.func.sh"
require_action "$ACTION"

stub gcloud 'echo "gcloud|$*" >>"$STUB_LOG"'
stub sudo   'echo "sudo|$*" >>"$STUB_LOG"'
stub gsutil 'echo "gsutil|$*" >>"$STUB_LOG"
case "$1 $2" in
  "ls -p") echo "gs://b1/" ;;
  "ls gs://b1/") echo "gs://b1/obj.txt" ;;
esac
exit 0'
mkdir -p "$T/home/.gcp/.csi"; : >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# drive <action-file> - runs it with every helper stubbed; prints the rc,
# argv log in $T/calls.log, output in $T/out.log
drive() {
  : >"$T/calls.log"; rm -rf "${T:?}/var"
  sed "s|/opt/google-cloud-sdk/bin|$T/bin|g" "$1" >"$T/action.sh"
  ( cd "$T" && env -u GCP_PROJECT -u TARGET_BASE HOME="$T/home" PATH="$T/bin:$PATH" \
      STUB_LOG="$T/calls.log" ORG=csi APP=spl ENV=dev TARGET_BASE="$T/var" \
    bash -c 'do_log() { echo "$*"; }; do_require_var() { :; }
      source "$T/action.sh"; do_gcp_s3_download_all' >"$T/out.log" 2>&1 )
  echo $?
}
TGT="$T/var/csi-spl-dev/dat/s3/b1"

# --- 1. the fixed action -------------------------------------------------------
rc=$(drive "$ACTION")
[[ "$rc" == 0 ]] && pass "1. the action returns 0" || fail "1. rc=$rc: $(tail -3 "$T/out.log")"
[[ -d "$TGT" ]] && pass "1. the bucket target dir was created" || fail "1. no $TGT"
grep -qxF "gsutil|-m rsync -r gs://b1/ $TGT" "$T/calls.log" \
  && pass "1. gsutil rsync ran into the target dir" || fail "1. no rsync into $TGT"
! grep -q '^sudo|' "$T/calls.log" && pass "1. sudo never ran" || fail "1. sudo ran: $(grep '^sudo|' "$T/calls.log")"

# --- 2. CONTROL: the old line --------------------------------------------------
sed 's|^\( *\)mkdir -p "\${BUCKET_TARGET}"$|\1sudo -u <DEV_USER> mkdir -p "${BUCKET_TARGET}"|' "$ACTION" >"$T/old.sh"
if grep -qF 'sudo -u <DEV_USER> mkdir' "$T/old.sh"; then
  rc=$(drive "$T/old.sh")
  [[ "$rc" == 1 ]] && pass "2. CONTROL: the old line makes the action return 1" || fail "2. CONTROL: old line rc=$rc"
  grep -q 'mkdir failed' "$T/out.log" && pass "2. CONTROL: the old line reports mkdir failed" \
    || fail "2. CONTROL: no 'mkdir failed' in the output"
  ! grep -q 'rsync' "$T/calls.log" && pass "2. CONTROL: the old line never reaches rsync" \
    || fail "2. CONTROL: rsync ran under the old line"
else
  fail "2. CONTROL: could not put the old line back (the mkdir line moved)"
fi

# --- 3. static -----------------------------------------------------------------
if grep -nE '^[^#]*[^"'"'"'#]<[A-Z_]{3,}>' "$ACTION" | grep -vE '^[0-9]+: *(do_log|echo) '; then
  fail "3. an unquoted <UPPER_CASE> placeholder sits on a command line"
else pass "3. no unquoted <UPPER_CASE> placeholder on a command line"; fi

[[ $fails -eq 0 ]] && pass "all $(basename "$0") assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
