#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_public_dataset_publish (spec 091 T008, sections 6, 8.4). gcloud
# storage and the hub are stubbed (fixtures/public-dataset-t008-stub.inc.sh), no cloud.
#   1. the code: no set -x, every gcloud pinned; the switch: prd refuses while
#      cnf enabled is false, with or without the force
#   2. dry run touches nothing; another account than the publish SA is refused
#   3. anything less than 3/3 publishes nothing and notes the class, content free
#   4. 3/3: the exact objects, the consolidated manifest the loader accepts,
#      latest.json last and no-cache, no name list public, both gone from staging
#   5. the candidate past the ttl is dropped with its name lists; the note never
#      says "not published" about a public file
#   6. a planted name list, a taken name and a crc that cannot be read refuse
#      before latest.json; a re-run is safe; a newer latest.json is kept
#   7. under the IAM step 053 grants today, the name lists stay and it says so
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in yq jq python3 gzip md5sum; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done
# shellcheck source=fixtures/public-dataset-t008-stub.inc.sh
source "$TEST_DIR/fixtures/public-dataset-t008-stub.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/spl-public-dataset-publish.func.sh"
GO=(PUBLIC_DATASET_FORCE=1 DRY_RUN=0 GCP_SA_KEY_FILE="$T/publish-key.json")
pub() { run_orc do_spl_public_dataset_publish "$@"; }
cnt() { local n; n=$(grep -c -- "$1" "$T/calls.log" 2>/dev/null); echo "${n:-0}"; }

# --- 1. the code and the switch -----------------------------------------------
grep -nE 'set -x|pg_dump|psql' "$FUNC" | grep -vE '^[0-9]+:\s*#' >/dev/null && fail "1. set -x, pg_dump or psql in the action" || pass "1. no set -x, no database in the action"
[[ "$(yq -r '.env.public_dataset.enabled' "$CNF/all.env.yaml")" == false ]] && ! yq -e '.env.public_dataset | has("enabled")' "$CNF/prd.env.yaml" >/dev/null 2>&1 \
  && pass "1. cnf public_dataset.enabled is false and prd does not override it" || fail "1. cnf enabled is not false"
reset_gs; stage 2026-11-03-v1.5.0
for f in "" PUBLIC_DATASET_FORCE=1; do
  pub ENV=prd DRY_RUN=0 $f; rc=$?
  [[ $rc -ne 0 && $(cnt 'gcloud|') -eq 0 ]] && grep -q 'refused: cnf public_dataset.enabled is false' "$T/out" \
    && pass "1. prd refuses while enabled is false (${f:-no force}), no gcloud call" || fail "1. prd ${f:-no force}: rc=$rc $(cat "$T/out")"
done
pub DRY_RUN=0; rc=$?
[[ $rc -ne 0 && $(cnt 'gcloud|') -eq 0 ]] && grep -q 'refused: cnf public_dataset.enabled is false' "$T/out" \
  && pass "1. dev without the force refuses too" || fail "1. dev: rc=$rc $(cat "$T/out")"
printf 'env:\n  public_dataset:\n    enabled: true\n' >"$T/on.yaml"
run_orc 'SPL_CNF="$T/on.yaml" spl_pd_publish_switch' ENV=prd; rc=$?
[[ $rc -eq 0 ]] && pass "1. control: prd passes the switch once cnf enabled is true" || fail "1. control: rc=$rc $(cat "$T/out")"

# --- 2. dry run, the account --------------------------------------------------
pub PUBLIC_DATASET_FORCE=1; rc=$?
[[ $rc -eq 0 && $(cnt 'storage') -eq 0 && -z "$(public_files)" ]] && grep -q '^OK DRY_RUN nothing was touched' "$T/out" \
  && pass "2. DRY_RUN (default): no storage call" || fail "2. dry: rc=$rc $(cat "$T/out")"
pub PUBLIC_DATASET_FORCE=1 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && $(cnt 'gcloud|storage') -eq 0 ]] && grep -q "FATAL the publish runs as the publish SA $PUBLISH_SA only" "$T/out" \
  && pass "2. the per-env SA is refused: the publish runs as the publish SA only" || fail "2. account: rc=$rc $(cat "$T/out")"

# --- 3. anything less ---------------------------------------------------------
vfile() { echo "$GS/$STAGING/verdicts/$SHA/$1.json"; }
vedit() { jq "$2" "$(vfile "$1")" >"$T/x" && cp "$T/x" "$(vfile "$1")"; }
refused() { # <label> <class>
  pub "${GO[@]}"; local rc=$?
  [[ $rc -ne 0 && -z "$(public_files)" ]] && grep -q "nothing published for $CAND. Missing: .*$2" "$T/out" &&
    grep -q "spool|send --from c-900 --to ALL-0 --to-box box-wui --task $TOPIC --kind note --body .*Missing: .*$2" "$T/calls.log" && no_content &&
    [[ -f "$GS/$STAGING/candidates/$CAND/names/names.tsv" ]] \
    && pass "3. $1: nothing published, the note names $2, no content" || fail "3. $1: rc=$rc public=[$(public_files)] $(cat "$T/out")"
}
fresh() { reset_gs; stage 2026-11-03-v1.5.0; }
fresh; rm "$(vfile grok)"; refused "2 of 3 verdicts" verdict-count
fresh; vedit grok '.lane_kind = "claude" | .lane_id = "c-104"'; cp "$(vfile grok)" "$(dirname "$(vfile grok)")/claude2.json"; rm "$(vfile grok)"; refused "two claude verdicts" lane-kinds
fresh; vedit agy '.verdict = "FAIL"'; refused "a FAIL" verdict-not-pass
fresh; vedit grok '.file_sha256 = ("0" * 64)'; refused "a verdict on another sha256" sha256-mismatch
fresh; printf 'tampered' | gzip -n >"$GS/$STAGING/candidates/$CAND/$NAME.sql.gz"; refused "a staged file that is not its manifest's" sha256-mismatch
fresh; vedit claude '.lane_id = "g-103"'; refused "a lane_id with the wrong prefix" lane-id-prefix
fresh; jq -c 'if .from == "a-101" then .from = "a-999" else . end' "$T/tail.ndjson" >"$T/x"; cp "$T/x" "$T/tail.ndjson"; refused "a hub_msg_id from another sender" hub-msg-sender
fresh; vedit agy '.hub_msg_id = "00000000-0000-4000-8000-000000000000"'; refused "a hub_msg_id the hub does not hold" hub-msg-missing
fresh; jq -c '.body = "verdict PASS sha256 " + ("0" * 64)' "$T/tail.ndjson" >"$T/x"; cp "$T/x" "$T/tail.ndjson"; refused "a hub message on another sha256" hub-msg-content
fresh; jq -c '.body |= sub("PASS"; "FAIL")' "$T/tail.ndjson" >"$T/x"; cp "$T/x" "$T/tail.ndjson"; refused "a hub message with another verdict" hub-msg-content
fresh; jq -c '.task_id = "11111111-1111-4111-8111-111111111111"' "$T/tail.ndjson" >"$T/x"; cp "$T/x" "$T/tail.ndjson"; refused "a hub message on another topic" hub-msg-topic
fresh; vedit agy '.v = 2'; refused "a verdict of another version" verdict-schema
fresh; vedit grok '.lane_id = "a-101"'; refused "one lane twice" lane-id-duplicate
fresh; pub "${GO[@]}" STUB_HUB=down; rc=$?
[[ $rc -ne 0 && -z "$(public_files)" ]] && grep -q 'Missing: .*hub-unreachable' "$T/out" && pass "3. the hub not answering: nothing published" || fail "3. hub down: rc=$rc $(cat "$T/out")"
fresh; pub "${GO[@]}" PD_CANDIDATE=2026-11-02-v1.4.0; rc=$?
[[ $rc -ne 0 && -z "$(public_files)" ]] && grep -q 'Missing: candidate-missing' "$T/out" && pass "3. a named candidate that is not staged: nothing published" || fail "3. no candidate: rc=$rc $(cat "$T/out")"

# --- 4. 3/3 -------------------------------------------------------------------
fresh; pub "${GO[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK public dataset published (dev): gs://$PUBLIC/daily/$NAME.sql.gz sha256 $SHA" "$T/out" && pass "4. 3/3 publishes" || fail "4. rc=$rc $(cat "$T/out")"
want="daily/$NAME.manifest.json daily/$NAME.sql.gz daily/$NAME.verdicts/agy.json daily/$NAME.verdicts/claude.json daily/$NAME.verdicts/grok.json latest.json"
[[ "$(public_files | tr '\n' ' ')" == "$want " ]] && pass "4. the public bucket holds exactly the five objects and latest.json" || fail "4. objects: $(public_files)"
M="$GS/$PUBLIC/daily/$NAME.manifest.json" L="$GS/$PUBLIC/latest.json"
cmp -s "$GS/$PUBLIC/daily/$NAME.sql.gz" "$GS/$STAGING/candidates/$CAND/$NAME.sql.gz" && grep -qF "storage cp --no-clobber gs://$STAGING/candidates/$CAND/$NAME.sql.gz gs://$PUBLIC/daily/$NAME.sql.gz --account=$PUBLISH_SA" "$T/calls.log" \
  && pass "4. the file is a server-side copy, staging to public, no overwrite, as the publish SA" || fail "4. copy: $(grep 'sql.gz' "$T/calls.log")"
jq -e --arg s "$SHA" '.sha256 == $s and (.verdicts | map(.lane_kind)) == ["agy", "claude", "grok"] and all(.verdicts[]; .verdict == "PASS" and .file_sha256 == $s) and (.published_at | test("Z$"))' "$M" >/dev/null \
  && pass "4. the manifest consolidates the three verdicts" || fail "4. manifest: $(cat "$M")"
jq -e --arg f "$NAME.sql.gz" --arg s "$SHA" '.file == $f and .object == ("daily/" + $f) and .sha256 == $s and .version == "1.5.0"' "$L" >/dev/null \
  && pass "4. latest.json names the file" || fail "4. latest: $(cat "$L")"
writes="$(grep -E "gcloud\|storage cp .* gs://$PUBLIC/" "$T/calls.log")"
[[ "$(tail -1 <<<"$writes")" == *"--cache-control=no-cache"*"gs://$PUBLIC/latest.json"* && "$(grep -c latest.json <<<"$writes")" == 1 ]] \
  && pass "4. latest.json is the LAST public write, with Cache-Control: no-cache" || fail "4. order: $writes"
cp "$T/calls.log" "$T/calls.pub"; cp "$T/out" "$T/out.pub"
run_orc 'spl_pdl_manifest_check "$M" "$S"' M="$M" S="$SHA"; rc=$?
[[ $rc -eq 0 ]] && pass "4. the loader's own check (T010) accepts the published manifest" || fail "4. loader: rc=$rc $(cat "$T/out")"
cp "$T/calls.pub" "$T/calls.log"; cp "$T/out.pub" "$T/out"
! (cd "$GS/$PUBLIC" && grep -rlE 'NAMECANARY|namecanary' . >/dev/null) && [[ -z "$(public_files | grep -E 'names')" ]] && ! grep -E "storage cp .*names" "$T/calls.log" >/dev/null \
  && pass "4. a name list never reaches the public side (by path and by content; no copy call names one)" || fail "4. name list public: $(public_files)"
[[ ! -e "$GS/$STAGING/candidates/$CAND/names" && -f "$GS/$STAGING/candidates/$CAND/$NAME.sql.gz" ]] \
  && pass "4. both name lists are deleted from staging, the candidate stays" || fail "4. staging: $(find "$GS/$STAGING" -type f)"
no_content && pass "4. the output names no row and no name" || fail "4. leak: $(cat "$T/out")"

# --- 5. the ttl drop ----------------------------------------------------------
reset_gs; stage 2026-11-01-v1.4.0 "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"; OLD=$CAND OLDSHA=$SHA; pub "${GO[@]}"; rc=$?
[[ $rc -eq 0 && -z "$(public_files)" && ! -e "$GS/$STAGING/candidates/$OLD" && ! -e "$GS/$STAGING/verdicts/$OLDSHA" ]] &&
  grep -q 'past candidate_ttl_hours: dropped with its name lists' "$T/out" && grep -q 'spool|send .*dropped, older than candidate_ttl_hours and not published' "$T/calls.log" \
  && pass "5. a candidate of 25 h is dropped with its name lists, even with three good verdicts; nothing published" || fail "5. drop: rc=$rc $(cat "$T/out") $(find "$GS" -type f)"
reset_gs; stage 2026-11-01-v1.4.0 "$(date -u -d '23 hours ago' +%Y-%m-%dT%H:%M:%SZ)"; pub "${GO[@]}"; rc=$?
[[ $rc -eq 0 && -f "$GS/$PUBLIC/daily/$NAME.sql.gz" ]] && pass "5. control: a candidate of 23 h publishes" || fail "5. control: rc=$rc $(cat "$T/out")"
reset_gs; stage 2026-11-01-v1.4.0 "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"; pub "${GO[@]}" PD_CANDIDATE=2026-11-01-v1.4.0; rc=$?
[[ $rc -ne 0 && -z "$(public_files)" ]] && grep -q 'Missing: candidate-expired' "$T/out" && pass "5. the named candidate past the ttl: dropped, exit 1" || fail "5. named: rc=$rc $(cat "$T/out")"
reset_gs; stage 2026-11-01-v1.4.0 "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"; OLD=$CAND; stage 2026-11-03-v1.5.0; pub "${GO[@]}"; rc=$?
[[ $rc -eq 0 && -f "$GS/$PUBLIC/daily/$NAME.sql.gz" && ! -e "$GS/$STAGING/candidates/$OLD" ]] && pass "5. the old one drops, the newest publishes" || fail "5. both: rc=$rc $(cat "$T/out")"
fresh; pub "${GO[@]}" >/dev/null; S="$GS/$STAGING/candidates/$CAND/$NAME.manifest.json"; jq --arg at "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '.exported_at = $at' "$S" >"$T/x"; cp "$T/x" "$S"; pub "${GO[@]}"; rc=$?
[[ $rc -eq 0 && ! -e "$GS/$STAGING/candidates/$CAND" && -f "$GS/$PUBLIC/daily/$NAME.sql.gz" && -f "$GS/$PUBLIC/latest.json" ]] && grep -q 'stays public' "$T/out" && ! grep -q 'spool|send' "$T/calls.log" \
  && pass "5. a published candidate past the ttl: its staged copy goes, the file stays, no note says not published" || fail "5. published drop: rc=$rc $(cat "$T/out") $(grep 'spool|send' "$T/calls.log")"
reset_gs; stage 2026-11-01-v1.4.0 "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"; pub "${GO[@]}" STUB_LS_DOWN="gs://$PUBLIC/daily/"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'spool|send .*whether it was published could not be read' "$T/calls.log" && ! grep -q 'spool|send .*not published' "$T/calls.log" \
  && pass "5. the public bucket not answering: the note says it could not be read, never not published" || fail "5. unknown: rc=$rc $(cat "$T/out") $(grep 'spool|send' "$T/calls.log")"

# --- 6. refusals at the copy, re-run ------------------------------------------
fresh; mkdir -p "$GS/$PUBLIC/daily"; printf 'x\n' >"$GS/$PUBLIC/daily/names.tsv"; pub "${GO[@]}"; rc=$?
[[ $rc -ne 0 && ! -e "$GS/$PUBLIC/latest.json" && -f "$GS/$STAGING/candidates/$CAND/names/names.tsv" ]] && grep -q 'class name-list-public' "$T/out" \
  && pass "6. a name list in the public bucket: FATAL, latest.json not written" || fail "6. plant: rc=$rc $(cat "$T/out")"
fresh; mkdir -p "$GS/$PUBLIC/daily"; printf 'x\n' >"$GS/$PUBLIC/daily/$NAME.sql.gz"; pub "${GO[@]}"; rc=$?
[[ $rc -ne 0 && ! -e "$GS/$PUBLIC/latest.json" && ! -e "$GS/$PUBLIC/daily/$NAME.manifest.json" ]] && grep -q 'a different file holds that name' "$T/out" \
  && pass "6. another file under the name: FATAL, no manifest, latest.json not written" || fail "6. taken: rc=$rc $(cat "$T/out")"
for d in empty fail; do
  fresh; mkdir -p "$GS/$PUBLIC/daily"; printf 'x\n' >"$GS/$PUBLIC/daily/$NAME.sql.gz"; pub "${GO[@]}" STUB_DESCRIBE=$d; rc=$?
  [[ $rc -ne 0 && ! -e "$GS/$PUBLIC/latest.json" && ! -e "$GS/$PUBLIC/daily/$NAME.manifest.json" ]] && grep -q 'no crc32c to compare' "$T/out" \
    && pass "6. another file under the name, describe $d on both sides: FATAL, latest.json not written" || fail "6. describe $d: rc=$rc $(cat "$T/out")"
done
fresh; pub "${GO[@]}" STUB_DESCRIBE=empty; rc=$?
[[ $rc -ne 0 && ! -e "$GS/$PUBLIC/latest.json" ]] && grep -q 'no crc32c to compare' "$T/out" && pass "6. no other file, describe empty: still no proof, latest.json not written" || fail "6. describe empty alone: rc=$rc $(cat "$T/out")"
fresh; mkdir -p "$GS/$PUBLIC/daily"; printf 'x\n' >"$GS/$PUBLIC/daily/$NAME.extra"; pub "${GO[@]}"; rc=$?
[[ $rc -ne 0 && ! -e "$GS/$PUBLIC/latest.json" ]] && grep -q 'class public-object-set' "$T/out" \
  && pass "6. an object it did not copy under the name: FATAL, latest.json not written" || fail "6. extra: rc=$rc $(cat "$T/out")"
fresh; pub "${GO[@]}" >/dev/null; before="$(cat "$GS/$PUBLIC/daily/$NAME.manifest.json")"; pub "${GO[@]}"; rc=$?
[[ $rc -eq 0 && "$before" == "$(cat "$GS/$PUBLIC/daily/$NAME.manifest.json")" ]] && pass "6. a re-run is safe: exit 0, the manifest unchanged" || fail "6. rerun: rc=$rc $(cat "$T/out")"
fresh; printf '{"v":1,"file":"spool-hub-public-2026-11-09-v1.6.0.sql.gz"}\n' >"$GS/$PUBLIC/latest.json"; pub "${GO[@]}"; rc=$?
[[ $rc -ne 0 && "$(public_files)" == latest.json ]] && grep -q 'Missing: .*newer-published' "$T/out" && jq -e '.file | test("2026-11-09")' "$GS/$PUBLIC/latest.json" >/dev/null \
  && pass "6. latest.json already names a newer file: nothing published, it stays" || fail "6. newer: rc=$rc $(cat "$T/out")"

# --- 7. the IAM of step 053 today ---------------------------------------------
fresh; pub "${GO[@]}" STUB_IAM=t007; rc=$?
[[ $rc -ne 0 && -f "$GS/$PUBLIC/latest.json" && -f "$GS/$STAGING/candidates/$CAND/names/names.tsv" ]] && grep -q "IS published, but its name lists could not be proved gone" "$T/out" \
  && pass "7. no objects.delete on staging: exit 1, and it says the file IS published and the lists remain" || fail "7. iam: rc=$rc $(cat "$T/out")"
reset_gs; stage 2026-11-01-v1.4.0 "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)"; pub "${GO[@]}" STUB_IAM=t007; rc=$?
[[ $rc -ne 0 && -z "$(public_files)" ]] && grep -q 'could NOT be dropped from staging' "$T/out" \
  && pass "7. no objects.delete: the drop fails loud, exit 1, nothing published" || fail "7. iam drop: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
