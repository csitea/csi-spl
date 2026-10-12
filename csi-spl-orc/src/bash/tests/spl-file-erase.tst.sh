#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_file_erase (erase one owner-discarded file_id), offline:
#   1. refusals: FILE_ID not 64 hex, a bad leg switch, every leg 0, a bad
#      tenant, DRY_RUN=2
#   2. dry run: lists the hub object and the box copies, deletes nothing
#      (no `storage rm`, every planted copy still there)
#   3. DRY_RUN=0: `storage rm` of exactly t/<tenant>/files/<id>, every copy
#      under every root removed, a neighbour file kept; reads back absent
#   4. CONTROL: a copy the rm cannot remove (a stubbed rm that does nothing)
#      fails the run with exit 3 and names the copy left behind
#   5. CONTROL: an object still present after the delete fails the hub leg
#   6. backup leg reports, never deletes: no rm against the bkp bucket
#   7. every gcloud call carries --account
# All ids are synthetic; no gcloud, curl or rm leaves the stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

FID=$(printf 'a%.0s' {1..64})
OTHER=$(printf 'b%.0s' {1..64})
mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  *"storage objects describe gs://csi-spl-dev-files/"*) [ -f "$T/obj" ] && exit 0; exit 1 ;;
  *"storage rm gs://csi-spl-dev-files/"*) [ "${OBJ_STICKS:-0}" = 1 ] || rm -f "$T/obj"; exit 0 ;;
  *"storage ls gs://csi-spl-bkp-dev/"*) [ -f "$T/bkp" ] && { printf '%s\n' "$3"; exit 0; }
    echo "ERROR: One or more URLs matched no objects." >&2; exit 1 ;;
esac
exit 0
STUB
cat >"$T/stub/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >>"$STUB_LOG"
printf '%s' "${HUB_CODE:-404}"
STUB
chmod +x "$T/stub/gcloud" "$T/stub/curl"

# do_spl_cloud_cnf sources the live-account check, so the stub goes in after it.
PIN='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };
eval "$(declare -f do_spl_cloud_cnf | sed 1s/do_spl_cloud_cnf/_orig_cnf/)";
do_spl_cloud_cnf(){ _orig_cnf || return 1; do_gcp_require_live_account(){ return 0; }; };'

plant() {
  rm -rf "$T/r1" "$T/r2"
  mkdir -p "$T/r1/u1/.local/share/x/desk/t1/b1/spool/files" "$T/r2/tmp"
  : >"$T/r1/u1/.local/share/x/desk/t1/b1/spool/files/$FID"
  : >"$T/r2/tmp/$FID.part"
  : >"$T/r2/tmp/$OTHER"
  : >"$T/obj"
  : >"$T/calls.log"
}
erase() {
  SNIPPET="$PIN do_spl_file_erase" in_orc T="$T" HOME="$T/home" FILE_ERASE_SUDO= \
    FILE_ERASE_ROOTS="$T/r1:$T/r2" FILE_ID="$FID" TENANT=t1 "$@"
}

# --- 1. refusals ---------------------------------------------------------------------------
plant
for bad in "FILE_ID=abc" "FILE_ID=${FID^^}" "FILE_ID=${FID}0" "HUB_LEG=2" "TENANT=T1" "DRY_RUN=2"; do
  if erase "$bad" >"$T/o" 2>&1; then fail "accepts $bad"; else pass "refuses $bad"; fi
done
erase HUB_LEG=0 BOX_LEG=0 BKP_LEG=0 >"$T/o" 2>&1 && fail "accepts every leg 0" || pass "refuses every leg 0"
grep -q 'storage rm' "$T/calls.log" && fail "a refusal still deleted" || pass "refusals: no storage rm"

# --- 2. dry run ----------------------------------------------------------------------------
plant
o=$(erase 2>&1); rc=$?
(( rc == 0 )) && grep -q 'DRY RUN: nothing was deleted' <<<"$o" && pass "dry run: exit 0, says so" || fail "dry rc=$rc: $o"
grep -q 'hub_object=present (dry run)' <<<"$o" && grep -q 'box_copies=2 (dry run)' <<<"$o" && pass "dry run lists the object and the 2 copies" || fail "dry plan: $o"
grep -q 'storage rm' "$T/calls.log" && fail "DRY_RUN=1 ran storage rm" || pass "DRY_RUN=1: no storage rm"
[[ -f "$T/r1/u1/.local/share/x/desk/t1/b1/spool/files/$FID" && -f "$T/r2/tmp/$FID.part" && -f "$T/obj" ]] && pass "DRY_RUN=1: every copy still there" || fail "DRY_RUN=1 deleted something"

# --- 3. erase ------------------------------------------------------------------------------
plant
o=$(erase DRY_RUN=0 2>&1); rc=$?
(( rc == 0 )) && pass "DRY_RUN=0: exit 0" || fail "erase rc=$rc: $o"
[[ $(grep -c "storage rm gs://csi-spl-dev-files/t/t1/files/$FID " "$T/calls.log") == 1 ]] && pass "one storage rm of exactly t/t1/files/<id>" || fail "rm calls: $(grep 'storage rm' "$T/calls.log")"
grep -q 'hub_object=absent hub_get=404' <<<"$o" && pass "hub read-back: absent, GET 404" || fail "hub read-back: $o"
grep -q 'box_copies=0 roots=2' <<<"$o" && pass "box read-back: 0 copies under 2 roots" || fail "box read-back: $o"
[[ -z "$(find "$T/r1" "$T/r2" -name "*$FID*")" ]] && pass "no copy left on disk" || fail "copies left: $(find "$T/r1" "$T/r2" -name "*$FID*")"
[[ -f "$T/r2/tmp/$OTHER" ]] && pass "a neighbour file is kept" || fail "the neighbour file was deleted"

# --- 4. CONTROL: a copy left behind fails --------------------------------------------------
plant
printf '#!/bin/sh\necho "rm $*" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/rm" && chmod +x "$T/stub/rm"
o=$(erase DRY_RUN=0 HUB_LEG=0 BKP_LEG=0 2>&1); rc=$?
rm -f "$T/stub/rm"
(( rc == 1 )) && grep -q 'box_copies=2' <<<"$o" && pass "CONTROL: copies left behind fail the run" || fail "copy left: rc=$rc $o"
grep -q "FAIL box: 2 copy(ies) left, first: .*$FID" <<<"$o" && pass "CONTROL: the failure names a copy left" || fail "copy-left text: $o"

# --- 5. CONTROL: an object that stays fails ------------------------------------------------
plant
o=$(erase DRY_RUN=0 BOX_LEG=0 BKP_LEG=0 OBJ_STICKS=1 2>&1); rc=$?
(( rc == 1 )) && grep -q 'hub_object=present' <<<"$o" && pass "CONTROL: an object still there fails the hub leg" || fail "sticky object: rc=$rc $o"
plant
o=$(erase DRY_RUN=0 BOX_LEG=0 BKP_LEG=0 HUB_CODE=200 2>&1); rc=$?
(( rc == 1 )) && pass "CONTROL: a GET answering 200 fails the hub leg" || fail "GET 200: rc=$rc $o"

# --- 6. backup leg: report only ------------------------------------------------------------
plant; : >"$T/bkp"
o=$(erase DRY_RUN=0 HUB_LEG=0 BOX_LEG=0 2>&1); rc=$?
(( rc == 0 )) && grep -q 'bkp_object=yes bkp_bucket=csi-spl-bkp-dev retention_days=' <<<"$o" && pass "bkp: reports the object held and the retention" || fail "bkp held: rc=$rc $o"
grep -q "owner's go for THAT delete" <<<"$o" && pass "bkp: says the delete needs the owner's go" || fail "bkp text: $o"
rm -f "$T/bkp"
o=$(erase DRY_RUN=0 HUB_LEG=0 BOX_LEG=0 2>&1)
grep -q 'bkp_object=no' <<<"$o" && pass "bkp: reports an absent object" || fail "bkp absent: $o"
grep -qE 'storage rm gs://csi-spl-bkp' "$T/calls.log" && fail "the bkp leg deleted" || pass "bkp: never a storage rm"

# --- 7. every gcloud call pinned --------------------------------------------------------------
plant; erase DRY_RUN=0 >/dev/null 2>&1
unpinned=$(grep '^gcloud ' "$T/calls.log" | grep -vc -- '--account=tester@example.com')
(( unpinned == 0 )) && pass "every gcloud call carries --account" || fail "$unpinned gcloud call(s) without --account"
grep -q "^gcloud storage objects describe" "$T/calls.log" && pass "CONTROL: the stub log records gcloud calls" || fail "CONTROL: no gcloud call recorded"

(( fails == 0 )) || { echo "FAILED: $fails"; exit 1; }
echo "ALL PASS"
