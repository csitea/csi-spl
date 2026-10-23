#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wsdoc_assets_move (spec 114 9.3, tasks R4) copies each
#          workspace Qto picture from 050 t/<tenant>/files/<sha> to its 052
#          bucket qto-assets/<sha> and counts a copy moved only when the
#          copy's bytes hash to its name. gcloud is a stub over a fake GCS
#          (one dir per bucket under $T/gcs); the hub DB read is a function
#          stub; the cnf is the repo's dev cnf. Digests and bytes are
#          synthetic.
#   1. refusals before any gcloud call: a bad ENV, DRY_RUN=2, a failed DB read
#   2. dry run: each 050 object verified, would_copy counted, no upload
#   3. DRY_RUN=0: moved counted, the 052 copy holds the same bytes, the 050
#      object is still there (no `storage rm`), the upload never overwrites
#   4. a second run: already counted, no upload
#   5. RED CONTROL: a copy whose bytes differ is FAIL copy-differs, exit 1,
#      and not counted moved
#   6. FAIL cases: src-differs (no upload), src-missing, no-bucket,
#      dst-differs (the 052 object is left as is)
#   7. every gcloud call carries --account; a picture's bytes never reach
#      the output
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
F="$PROJ_ROOT/src/bash/run/spl-wsdoc-assets-move.func.sh"
[[ -f "$F" ]] && pass "the action exists" || { fail "no $F"; echo "FAILED: $fails"; exit 1; }
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

FILES=csi-spl-dev-files PFX=csi-spl-dev-docs-
mkdir -p "$T/stub"
# the fake GCS: gs://<bucket>/<key> is $T/gcs/<bucket>/<key>; CORRUPT=1 makes
# an upload store other bytes than it was given
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/bash
echo "gcloud $*" >>"$STUB_LOG"
p() { printf '%s' "$T/gcs/${1#gs://}"; }
case "$1 $2 $3" in
  "storage buckets describe") [[ -d "$(p "$4")" ]]; exit ;;
  "storage objects describe") [[ -f "$(p "$4")" ]]; exit ;;
  "storage cp gs://"*) [[ -f "$(p "$3")" ]] && cp "$(p "$3")" "$4"; exit ;;
  "storage cp "*)
    d="$(p "$4")"
    [[ "$*" == *--if-generation-match=0* && -e "$d" ]] && { echo "PreconditionFailed" >&2; exit 1; }
    mkdir -p "$(dirname "$d")" && cp "$3" "$d"
    [[ "${CORRUPT:-0}" == 1 ]] && printf 'x' >>"$d"
    exit 0 ;;
esac
echo "unexpected gcloud $*" >&2; exit 1
STUB
chmod +x "$T/stub/gcloud"

# two synthetic pictures; the marker must never reach the output
printf 'PICTURE-BYTES-ONE' >"$T/p1"; printf 'PICTURE-BYTES-TWO' >"$T/p2"
S1=$(sha256sum "$T/p1" | cut -d' ' -f1) S2=$(sha256sum "$T/p2" | cut -d' ' -f1)
NOSUCH=$(printf 'c%.0s' {1..64})

plant() { # refs on stdin as "<tenant> <sha>" lines
  rm -rf "$T/gcs" && mkdir -p "$T/gcs/$FILES/t/w1/files" "$T/gcs/${PFX}w1"
  cp "$T/p1" "$T/gcs/$FILES/t/w1/files/$S1"
  cp "$T/p2" "$T/gcs/$FILES/t/w1/files/$S2"
  cat >"$T/refs"
  : >"$T/calls.log"
}
# do_spl_db_query is stubbed after the libs; it prints psql-like rows
STUBS='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };
eval "$(declare -f do_spl_cloud_cnf | sed 1s/do_spl_cloud_cnf/_orig_cnf/)";
do_spl_cloud_cnf(){ _orig_cnf || return 1; do_gcp_require_live_account(){ return 0; }; };
do_spl_db_query(){ [[ "${DBFAIL:-0}" == 1 ]] && { echo "FATAL proxy"; return 1; };
  [[ "$SQL" == *"attrs ->"* || "$SQL" == *"attrs->"* ]] || { echo "unexpected SQL"; return 1; };
  echo " ?column? "; echo "---------"; sed "s/^/ ASSET /" "$T/refs"; echo "(n rows)"; };'
move() { SNIPPET="$STUBS do_spl_wsdoc_assets_move" in_orc T="$T" HOME="$T/home" "$@"; }
uploads() { grep -c "^gcloud storage cp $T/" "$T/calls.log"; }

# --- 1. refusals ---------------------------------------------------------------------------
printf 'w1 %s\n' "$S1" | plant
for bad in ENV=stg DRY_RUN=2 DBFAIL=1; do
  o=$(move "$bad" 2>&1) && fail "accepts $bad" || pass "refuses $bad"
done
[[ ! -s "$T/calls.log" ]] && pass "refusals: no gcloud call" || fail "a refusal called gcloud: $(cat "$T/calls.log")"

# --- 2. dry run ----------------------------------------------------------------------------
printf 'w1 %s\nw1 %s\n' "$S1" "$S2" | plant
o=$(move 2>&1); rc=$?
((rc == 0)) && grep -q 'OK DRY RUN ENV=dev wsdoc assets: refs=2 moved=0 already=0 would_copy=2 failed=0' <<<"$o" &&
  pass "dry run: exit 0, would_copy=2" || fail "dry rc=$rc: $o"
[[ "$(uploads)" == 0 && ! -e "$T/gcs/${PFX}w1/qto-assets" ]] && pass "dry run: no upload" || fail "dry run uploaded: $(cat "$T/calls.log")"

# --- 3. DRY_RUN=0 --------------------------------------------------------------------------
o=$(move DRY_RUN=0 2>&1); rc=$?
((rc == 0)) && grep -q 'OK ENV=dev wsdoc assets: refs=2 moved=2 already=0 would_copy=0 failed=0' <<<"$o" &&
  pass "DRY_RUN=0: moved=2" || fail "move rc=$rc: $o"
grep -q "^moved dev w1 $S1\$" <<<"$o" && pass "one moved line per ref: tenant + sha256" || fail "moved line: $o"
cmp -s "$T/p1" "$T/gcs/${PFX}w1/qto-assets/$S1" && cmp -s "$T/p2" "$T/gcs/${PFX}w1/qto-assets/$S2" &&
  pass "the 052 copies hold the same bytes" || fail "052 copies differ or are missing"
[[ -f "$T/gcs/$FILES/t/w1/files/$S1" && -f "$T/gcs/$FILES/t/w1/files/$S2" ]] && ! grep -q 'storage rm' "$T/calls.log" &&
  pass "never deletes from 050" || fail "a 050 object is gone"
[[ "$(grep "^gcloud storage cp $T/" "$T/calls.log" | grep -vc -- '--if-generation-match=0')" == 0 ]] &&
  pass "every upload is --if-generation-match=0" || fail "an upload may overwrite: $(cat "$T/calls.log")"

# --- 4. second run -------------------------------------------------------------------------
: >"$T/calls.log"
o=$(move DRY_RUN=0 2>&1); rc=$?
((rc == 0)) && grep -q 'refs=2 moved=0 already=2 would_copy=0 failed=0' <<<"$o" && [[ "$(uploads)" == 0 ]] &&
  pass "a second run: already=2, no upload" || fail "rerun rc=$rc: $o"

# --- 5. RED CONTROL: a copy whose bytes differ ---------------------------------------------
printf 'w1 %s\n' "$S1" | plant
o=$(move DRY_RUN=0 CORRUPT=1 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w1 $S1 copy-differs\$" <<<"$o" &&
  grep -q 'FATAL ENV=dev wsdoc assets: refs=1 moved=0 already=0 would_copy=0 failed=1' <<<"$o" &&
  pass "RED CONTROL: a copy whose bytes differ is FAIL, exit 1, moved=0" || fail "corrupt copy rc=$rc: $o"

# --- 6. FAIL cases -------------------------------------------------------------------------
printf 'w1 %s\n' "$S2" | plant
cp "$T/p1" "$T/gcs/$FILES/t/w1/files/$S2"
o=$(move DRY_RUN=0 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w1 $S2 src-differs\$" <<<"$o" && [[ "$(uploads)" == 0 ]] &&
  pass "a 050 object whose bytes differ from its name: FAIL src-differs, no upload" || fail "src-differs rc=$rc: $o"
printf 'w1 %s\n' "$NOSUCH" | plant
o=$(move DRY_RUN=0 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w1 $NOSUCH src-missing\$" <<<"$o" && pass "a ref with no 050 object: FAIL src-missing" || fail "src-missing rc=$rc: $o"
printf 'w1 %s\nw2 %s\n' "$S1" "$S2" | plant
o=$(move DRY_RUN=0 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w2 $S2 no-bucket gs://${PFX}w2\$" <<<"$o" && grep -q 'moved=1 .* failed=1' <<<"$o" &&
  pass "a workspace with no 052 bucket: FAIL no-bucket; the others still move" || fail "no-bucket rc=$rc: $o"
printf 'w1 %s\n' "$S1" | plant
mkdir -p "$T/gcs/${PFX}w1/qto-assets" && cp "$T/p2" "$T/gcs/${PFX}w1/qto-assets/$S1"
o=$(move DRY_RUN=0 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w1 $S1 dst-differs (left as is)\$" <<<"$o" && cmp -s "$T/p2" "$T/gcs/${PFX}w1/qto-assets/$S1" &&
  pass "a 052 object with other bytes: FAIL dst-differs, left as is" || fail "dst-differs rc=$rc: $o"

# --- 7. pinned, no bytes printed ---------------------------------------------------------------
printf 'w1 %s\nw1 %s\n' "$S1" "$S2" | plant
o=$(move DRY_RUN=0 2>&1)
[[ -s "$T/calls.log" && "$(grep -vc -- '--account=tester@example.com' "$T/calls.log")" == 0 ]] &&
  pass "every gcloud call carries --account" || fail "a gcloud call without --account: $(cat "$T/calls.log")"
grep -q 'PICTURE-BYTES' <<<"$o" && fail "a picture's bytes reached the output" || pass "no picture bytes in the output"

((fails == 0)) || { echo "FAILED: $fails"; exit 1; }
echo "ALL PASS"
