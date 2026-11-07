#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_public_dataset_takedown (spec 091 T008, section 10). gcloud
# storage stubbed (fixtures/public-dataset-t008-stub.inc.sh), no cloud.
#   1. refuses without the go (none, another file's, a bad name, no owner message
#      id), dry run or not
#   2. deletes the one file, its manifest and verdicts in daily/ and stable/,
#      latest.json points at the previous good one BEFORE the first delete,
#      other files stay; a previous file without 3/3 is skipped; none left = null
#   3. a file that is not latest leaves latest.json alone; an absent file refuses
#   4. the candidate leaves staging: the next publish cannot put it back, also
#      when the staging removal failed once and a re-run finished it
#   5. prd stays possible while enabled is false; a failed delete is loud
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in yq jq python3 gzip md5sum; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done
# shellcheck source=fixtures/public-dataset-t008-stub.inc.sh
source "$TEST_DIR/fixtures/public-dataset-t008-stub.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/spl-public-dataset-takedown.func.sh"
GO=(PUBLIC_DATASET_FORCE=1 DRY_RUN=0 GCP_SA_KEY_FILE="$T/publish-key.json")
F1=spool-hub-public-2026-11-01-v1.4.0.sql.gz F2=spool-hub-public-2026-11-02-v1.4.1.sql.gz F3=spool-hub-public-2026-11-03-v1.5.0.sql.gz
OWNER_MSG=07f37133-0d1f-443c-9691-26beabae8070
td() { local f="$1"; shift; run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE="$f" TAKEDOWN_GO="$f" TAKEDOWN_OWNER_MSG="$OWNER_MSG" DRY_RUN=0 "$@"; }

# published <candidate> [bad]: publish through the real action, so the fixture is
# what publish writes; bad strips a verdict from its manifest (with the override).
published() {
  stage "$1"
  run_orc do_spl_public_dataset_publish "${GO[@]}" PD_CANDIDATE="$1" || { fail "fixture: publish $1: $(cat "$T/out")"; return 1; }
  if [[ "${2:-}" == bad ]]; then
    local m="$GS/$PUBLIC/daily/spool-hub-public-$1.manifest.json"
    jq '.verdicts |= .[:2]' "$m" >"$T/x" && cp "$T/x" "$m"
  fi
}
three() { reset_gs; published 2026-11-01-v1.4.0; published 2026-11-02-v1.4.1; published 2026-11-03-v1.5.0; }
latest_file() { jq -r .file "$GS/$PUBLIC/latest.json"; }

# --- 1. the go ----------------------------------------------------------------
grep -nE 'set -x' "$FUNC" | grep -vE '^[0-9]+:\s*#' >/dev/null && fail "1. set -x in the action" || pass "1. no set -x in the action"
three; before="$(public_files)"
check_refused() { # <label> <grep>
  [[ $rc -ne 0 && "$(public_files)" == "$before" && "$(grep -c 'storage' "$T/calls.log")" == 0 ]] && grep -q "$2" "$T/out" \
    && pass "1. $1: refused, no storage call" || fail "1. $1: rc=$rc $(cat "$T/out")"
}
run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE="$F3" DRY_RUN=0; rc=$?; check_refused "no go" "FATAL take-down refused: a delete needs the owner's go"
run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE="$F3" TAKEDOWN_GO="$F2" DRY_RUN=0; rc=$?; check_refused "another file's go" "FATAL take-down refused"
run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE="$F3"; rc=$?; check_refused "no go, dry run" "FATAL take-down refused"
run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE='*.sql.gz' TAKEDOWN_GO='*.sql.gz' DRY_RUN=0; rc=$?; check_refused "a glob for a name" "FATAL TAKEDOWN_FILE must be"
run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE="$F3" TAKEDOWN_GO="$F3" DRY_RUN=0; rc=$?; check_refused "the go, no owner message id" "needs the id of the owner's message"
run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE="$F3" TAKEDOWN_GO="$F3" TAKEDOWN_OWNER_MSG=yes DRY_RUN=0; rc=$?; check_refused "the go, an id that is no id" "needs the id of the owner's message"
run_orc do_spl_public_dataset_takedown TAKEDOWN_FILE="$F3" TAKEDOWN_GO="$F3" TAKEDOWN_OWNER_MSG="$OWNER_MSG"; rc=$?
[[ $rc -eq 0 && "$(public_files)" == "$before" && "$(grep -c 'gcloud|storage' "$T/calls.log")" == 0 ]] && grep -q '^OK DRY_RUN nothing was touched' "$T/out" \
  && pass "1. the go, DRY_RUN (default): no storage call" || fail "1. dry: rc=$rc $(cat "$T/out")"

# --- 2. the delete ------------------------------------------------------------
three; N3="${F3%.sql.gz}"; mkdir -p "$GS/$PUBLIC/stable"; cp "$GS/$PUBLIC/daily/$F3" "$GS/$PUBLIC/stable/$F3"; cp "$GS/$PUBLIC/daily/$N3.manifest.json" "$GS/$PUBLIC/stable/$N3.manifest.json"
td "$F3"; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK public dataset take-down (dev): $F3" "$T/out" && grep -qF "on the owner's message $OWNER_MSG" "$T/out" && pass "2. the take-down reports OK" || fail "2. rc=$rc $(cat "$T/out")"
[[ -z "$(public_files | grep -F "$N3")" ]] && pass "2. the file, manifest and verdicts are gone from daily/ and stable/" || fail "2. left: $(public_files)"
[[ -f "$GS/$PUBLIC/daily/$F1" && -f "$GS/$PUBLIC/daily/$F2" && -f "$GS/$PUBLIC/daily/${F2%.sql.gz}.manifest.json" ]] && pass "2. the other files stay" || fail "2. others: $(public_files)"
[[ "$(latest_file)" == "$F2" ]] && jq -e '.object == "daily/'"$F2"'" and (.sha256 | test("^[0-9a-f]{64}$")) and .version == "1.5.0"' "$GS/$PUBLIC/latest.json" >/dev/null \
  && pass "2. latest.json names the previous good file" || fail "2. latest: $(cat "$GS/$PUBLIC/latest.json")"
ln_latest="$(grep -n "cp --cache-control=no-cache .*latest.json" "$T/calls.log" | sed -n 1p | cut -d: -f1)"
ln_rm="$(grep -n "storage rm gs://$PUBLIC/" "$T/calls.log" | sed -n 1p | cut -d: -f1)"
[[ -n "$ln_latest" && -n "$ln_rm" && "$ln_latest" -lt "$ln_rm" ]] && pass "2. latest.json moves before the first public delete, no-cache" || fail "2. order: latest=$ln_latest rm=$ln_rm"
grep -q "storage rm .*--account=$ENV_SA" "$T/calls.log" && [[ -z "$(grep 'gcloud|storage' "$T/calls.log" | grep -v -- '--account=')" ]] && pass "2. every storage call is pinned, as the per-env SA" || fail "2. account: $(grep storage "$T/calls.log")"
three; published 2026-11-04-v1.5.1 bad; F4=spool-hub-public-2026-11-04-v1.5.1.sql.gz; td "$F4"; rc=$?
[[ $rc -eq 0 && "$(latest_file)" == "$F3" ]] && pass "2. control: the previous good file is the newest other" || fail "2. newest: $(cat "$T/out")"
reset_gs; published 2026-11-02-v1.4.1; published 2026-11-03-v1.5.0 ; jq '.verdicts |= .[:2]' "$GS/$PUBLIC/daily/${F2%.sql.gz}.manifest.json" >"$T/x"; cp "$T/x" "$GS/$PUBLIC/daily/${F2%.sql.gz}.manifest.json"; td "$F3"; rc=$?
[[ $rc -eq 0 && "$(latest_file)" == null && -f "$GS/$PUBLIC/daily/$F2" ]] && pass "2. a previous file without three verdicts is never pointed at: latest.json names none" || fail "2. bad prev: rc=$rc $(cat "$GS/$PUBLIC/latest.json")"
reset_gs; published 2026-11-03-v1.5.0; td "$F3"; rc=$?
[[ $rc -eq 0 && "$(public_files)" == latest.json && "$(latest_file)" == null ]] && pass "2. the only file: latest.json names none" || fail "2. only: rc=$rc $(public_files)"

# --- 3. not latest, absent ----------------------------------------------------
three; td "$F1"; rc=$?
[[ $rc -eq 0 && "$(latest_file)" == "$F3" && ! -e "$GS/$PUBLIC/daily/$F1" && "$(grep -c 'cache-control' "$T/calls.log")" == 0 ]] && pass "3. an older file: latest.json is not written" || fail "3. older: rc=$rc $(cat "$T/out")"
td "$F1"; rc=$?
[[ $rc -ne 0 && "$(latest_file)" == "$F3" ]] && grep -q "FATAL $F1 is not in gs://$PUBLIC" "$T/out" && pass "3. a file not in the bucket refuses, nothing moved" || fail "3. absent: rc=$rc $(cat "$T/out")"

# --- 4. it cannot come back ---------------------------------------------------
reset_gs; published 2026-11-03-v1.5.0; td "$F3"; rc=$?
[[ $rc -eq 0 && ! -e "$GS/$STAGING/candidates/2026-11-03-v1.5.0" && ! -e "$GS/$STAGING/verdicts/$SHA" ]] && pass "4. the candidate and its verdicts leave staging" || fail "4. staging: $(find "$GS/$STAGING" -type f)"
run_orc do_spl_public_dataset_publish "${GO[@]}"; rc=$?
[[ $rc -eq 0 && "$(public_files)" == latest.json && "$(latest_file)" == null ]] && grep -q 'no candidate is staged' "$T/out" && pass "4. the next publish finds nothing to put back" || fail "4. republish: rc=$rc $(public_files) $(cat "$T/out")"
for deny in "gs://$STAGING/candidates/" "gs://$STAGING/verdicts/"; do
  reset_gs; published 2026-11-03-v1.5.0; td "$F3" STUB_RM_DENY="$deny"; rc=$?
  [[ $rc -ne 0 && -z "$(public_files | grep -F "${F3%.sql.gz}")" && -d "$GS/$STAGING/candidates/2026-11-03-v1.5.0" ]] && grep -q 'until a re-run finishes it' "$T/out" \
    && pass "4. staging refuses once (${deny##*/$STAGING/}): the public delete goes on, exit 1, the candidate is still there for the re-run" || fail "4. deny $deny: rc=$rc $(cat "$T/out") $(public_files)"
  td "$F3"; rc=$?
  [[ $rc -eq 0 && ! -e "$GS/$STAGING/candidates/2026-11-03-v1.5.0" && ! -e "$GS/$STAGING/verdicts/$SHA" ]] && pass "4. the re-run finishes staging, verdicts too, with the public manifest gone" || fail "4. re-run: rc=$rc $(cat "$T/out") $(find "$GS/$STAGING" -type f)"
  run_orc do_spl_public_dataset_publish "${GO[@]}"; rc=$?
  [[ $rc -eq 0 && "$(public_files)" == latest.json && "$(latest_file)" == null ]] && grep -q 'no candidate is staged' "$T/out" && pass "4. after the re-run the next publish does not bring the file back" || fail "4. back: rc=$rc $(public_files) $(cat "$T/out")"
done

# --- 5. prd, a failed delete --------------------------------------------------
PRD_PUB=$(yq -r '.env.steps."053-gcs-public-dataset".public_bucket_name' "$CNF/prd.env.yaml")
mkdir -p "$GS/$PRD_PUB/daily"; printf 'x\n' >"$GS/$PRD_PUB/daily/$F3"; printf '{"v":1,"file":"%s"}\n' "$F3" >"$GS/$PRD_PUB/latest.json"
td "$F3" ENV=prd; rc=$?
[[ $rc -eq 0 && ! -e "$GS/$PRD_PUB/daily/$F3" ]] && [[ "$(jq -r .file "$GS/$PRD_PUB/latest.json")" == null ]] && pass "5. prd: possible while cnf enabled is false (the switch never holds back a removal)" || fail "5. prd: rc=$rc $(cat "$T/out")"
reset_gs; published 2026-11-03-v1.5.0; td "$F3" STUB_IAM=t007; rc=$?
[[ $rc -ne 0 ]] && grep -q 'could not be removed from' "$T/out" && grep -q "FATAL cannot delete" "$T/out" && grep -q 'may still be in' "$T/out" && pass "5. no delete permission: exit 1 and it says what remains" || fail "5. iam: rc=$rc $(cat "$T/out")"
no_content && pass "5. the output names no row and no name" || fail "5. leak: $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
