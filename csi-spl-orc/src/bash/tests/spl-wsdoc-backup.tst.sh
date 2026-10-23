#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wsdoc_backup (spec 114 9.5, tasks R6) writes each
#          workspace's Qto doc rows to ITS OWN 052 bucket backup/<date>/ and
#          reads them back to count. gcloud is a stub over a fake GCS (one dir
#          per bucket under $T/gcs); psql (spl_pg_env) is a function stub
#          that answers each `\o '<file>'` of the script with a fixture of the
#          tenant named by -v t=; the cnf is the repo's dev cnf. Rows are
#          synthetic.
#   1. refusals before any gcloud call: a bad ENV, DRY_RUN=2, a bad date,
#      TENANT_ID=system, a bad slug
#   2. dry run: both workspaces would_write, no upload
#   3. DRY_RUN=0: each workspace's files in its own bucket only, counts and
#      sha256 in the manifest; the SQL is read only, operator scope, and
#      every SELECT names the tenant
#   4. RED CONTROL: a backup of workspace A written to B's bucket is
#      refused before any upload; rows of B exported for A are FAIL
#      foreign-row, nothing uploaded
#   5. RED CONTROL: a backup missing one doc fails the count check, exit 1
#   6. no-bucket: that workspace FAILs, the other is still written
#   7. TENANT_ID: one workspace, no workspace-list read
#   8. every gcloud call carries --account; a doc's text never reaches the
#      output
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
F="$PROJ_ROOT/src/bash/run/spl-wsdoc-backup.func.sh"
[[ -f "$F" ]] && pass "the action exists" || { fail "no $F"; echo "FAILED: $fails"; exit 1; }
bash -n "$F" && pass "bash -n $(basename "$F")" || fail "bash -n $(basename "$F")"

PFX=csi-spl-dev-docs- DAY=2026-10-23
mkdir -p "$T/stub"
# the fake GCS: gs://<bucket>/<key> is $T/gcs/<bucket>/<key>; DROP=<file>
# makes the upload of that file lose its last line
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/bash
echo "gcloud $*" >>"$STUB_LOG"
p() { printf '%s' "$T/gcs/${1#gs://}"; }
case "$1 $2 $3" in
  "storage buckets describe") [[ -d "$(p "$4")" ]]; exit ;;
  "storage cp gs://"*) [[ -f "$(p "$3")" ]] && cp "$(p "$3")" "$4"; exit ;;
  "storage cp "*)
    d="$(p "$4")"
    mkdir -p "$(dirname "$d")" && cp "$3" "$d"
    [[ -n "${DROP:-}" && "$(basename "$d")" == "$DROP" ]] && sed -i '$d' "$d"
    exit 0 ;;
esac
echo "unexpected gcloud $*" >&2; exit 1
STUB
chmod +x "$T/stub/gcloud"

# fixtures: $T/db/<tenant>/<file>; SECRET-TEXT must never reach the output
mkdir -p "$T/db/w1" "$T/db/w2"
printf 'w1\nw2\n' >"$T/db/tenants"
cat >"$T/db/w1/docs.jsonl" <<'J'
{"id":"d1","tenant_id":"w1","title":"SECRET-TEXT one"}
{"id":"d2","tenant_id":"w1","title":"SECRET-TEXT two"}
J
cat >"$T/db/w1/items.jsonl" <<'J'
{"id":"i1","tenant_id":"w1","doc_id":"d1","parent_id":null,"body":"SECRET-TEXT","attrs":{"assets":{"a.png":"aa"}}}
{"id":"i2","tenant_id":"w1","doc_id":"d1","parent_id":"i1","body":"SECRET-TEXT","attrs":{}}
{"id":"i3","tenant_id":"w1","doc_id":"d2","parent_id":null,"body":"SECRET-TEXT","attrs":{}}
J
echo '{"id":"n1","tenant_id":"w1","kind":"root"}' >"$T/db/w1/nodes.jsonl"
echo '2 3 1' >"$T/db/w1/counts"
echo '{"id":"d9","tenant_id":"w2","title":"SECRET-TEXT w2"}' >"$T/db/w2/docs.jsonl"
echo '{"id":"i9","tenant_id":"w2","doc_id":"d9","parent_id":null,"body":"SECRET-TEXT","attrs":{}}' >"$T/db/w2/items.jsonl"
: >"$T/db/w2/nodes.jsonl"
echo '1 1 0' >"$T/db/w2/counts"

plant() { rm -rf "$T/gcs" && mkdir -p "$T/gcs/${PFX}w1" "$T/gcs/${PFX}w2"; : >"$T/calls.log"; : >"$T/sql.log"; }
# psql is stubbed after the libs; DB_AS=<tenant> answers every tenant's
# read with that tenant's rows (the foreign-row control)
STUBS='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };
eval "$(declare -f do_spl_cloud_cnf | sed 1s/do_spl_cloud_cnf/_orig_cnf/)";
do_spl_cloud_cnf(){ _orig_cnf || return 1; do_gcp_require_live_account(){ return 0; }; };
spl_via_proxy(){ echo "PROXY" >>"$STUB_LOG"; SPL_PROXY_DSN=x "$@"; };
spl_pg_env(){ local t="" a l src; for a in "$@"; do [[ "$a" == t=* ]] && t="${a#t=}"; done;
  [[ "${DBFAIL:-0}" == 1 ]] && return 1; local s; s="$(cat)"; printf "PSQL t=%s %s\n%s\n" "$t" "$*" "$s" >>"$T/sql.log";
  local q; q="$(printf "\x27")"; while IFS= read -r l; do [[ "$l" == "\\o "* ]] || continue; a="${l#\\o }"; a="${a//$q/}";
    src="$T/db/${DB_AS:-$t}/$(basename "$a")"; [[ -z "$t" ]] && src="$T/db/$(basename "$a")";
    if [[ -f "$src" ]]; then cp "$src" "$a"; else : >"$a"; fi; done <<<"$s"; };'
bk() { SNIPPET="$STUBS do_spl_wsdoc_backup" in_orc T="$T" HOME="$T/home" WSDOC_BACKUP_DATE="$DAY" "$@"; }
uploads() { grep -c "^gcloud storage cp $T/\|^gcloud storage cp /tmp" "$T/calls.log"; }
obj() { printf '%s' "$T/gcs/$PFX$1/backup/$DAY/$2"; }

# --- 1. refusals ---------------------------------------------------------------------------
plant
for bad in ENV=stg DRY_RUN=2 WSDOC_BACKUP_DATE=23-10-2026 TENANT_ID=system TENANT_ID=Bad_Slug; do
  o=$(bk "$bad" 2>&1) && fail "accepts $bad" || pass "refuses $bad"
done
[[ ! -s "$T/calls.log" ]] && pass "refusals: no gcloud call" || fail "a refusal called gcloud: $(cat "$T/calls.log")"
plant
o=$(bk DBFAIL=1 2>&1) && fail "a failed DB read passes" || pass "a failed DB read is FATAL"

# --- 2. dry run ----------------------------------------------------------------------------
plant
o=$(bk 2>&1); rc=$?
((rc == 0)) && grep -q "OK DRY RUN ENV=dev wsdoc backup $DAY: workspaces=2 ok=0 would_write=2 failed=0" <<<"$o" &&
  pass "dry run: exit 0, would_write=2" || fail "dry rc=$rc: $o"
grep -q "^would-write dev w1 gs://${PFX}w1/backup/$DAY/ docs=2 items=3 nodes=1 assets=1\$" <<<"$o" &&
  pass "dry run: one line per workspace with its counts" || fail "dry line: $o"
[[ "$(uploads)" == 0 && -z "$(find "$T/gcs" -type f)" ]] && pass "dry run: no upload" || fail "dry run uploaded: $(cat "$T/calls.log")"

# --- 3. DRY_RUN=0 --------------------------------------------------------------------------
plant
o=$(bk DRY_RUN=0 2>&1); rc=$?
((rc == 0)) && grep -q "OK ENV=dev wsdoc backup $DAY: workspaces=2 ok=2 would_write=0 failed=0" <<<"$o" &&
  pass "DRY_RUN=0: ok=2" || fail "backup rc=$rc: $o"
grep -q "^ok dev w2 gs://${PFX}w2/backup/$DAY/ docs=1 items=1 nodes=0 assets=0\$" <<<"$o" &&
  pass "ok line: tenant, its own prefix, counts" || fail "ok line: $o"
for f in docs.jsonl items.jsonl nodes.jsonl assets.tsv manifest.json; do
  [[ -f "$(obj w1 $f)" && -f "$(obj w2 $f)" ]] || fail "missing $f"
done
cmp -s "$T/db/w1/items.jsonl" "$(obj w1 items.jsonl)" && pass "w1 items stored byte for byte" || fail "w1 items differ"
[[ "$(jq -r '"\(.tenant) \(.date) \(.docs) \(.items) \(.nodes) \(.assets)"' "$(obj w1 manifest.json)")" == "w1 $DAY 2 3 1 1" ]] &&
  pass "manifest: tenant, date, counts" || fail "manifest: $(cat "$(obj w1 manifest.json)")"
[[ "$(jq -r '.sha256["docs.jsonl"]' "$(obj w1 manifest.json)")" == "$(sha256sum "$(obj w1 docs.jsonl)" | cut -d' ' -f1)" ]] &&
  pass "manifest: sha256 of each file" || fail "manifest sha256"
[[ "$(printf 'd1\ta.png\taa')" == "$(cat "$(obj w1 assets.tsv)")" ]] && pass "assets index: doc, path, sha256" || fail "assets.tsv: $(cat "$(obj w1 assets.tsv)")"
! grep -rq '"tenant_id":"w1"' "$T/gcs/${PFX}w2" && ! grep -rq '"tenant_id":"w2"' "$T/gcs/${PFX}w1" &&
  pass "each bucket holds its own workspace's rows only" || fail "a row in the other workspace's bucket"
[[ "$(grep "^gcloud storage cp $T/\|^gcloud storage cp /" "$T/calls.log" | tail -1)" == *"${PFX}w2/backup/$DAY/manifest.json "* ]] &&
  pass "the manifest is uploaded last" || fail "upload order: $(cat "$T/calls.log")"
grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' "$T/sql.log" &&
  grep -q "SET LOCAL app.rls_scope = 'operator'" "$T/sql.log" && grep -q 'ROLLBACK' "$T/sql.log" &&
  pass "SQL: read only, one snapshot, operator scope, rolled back" || fail "SQL frame: $(cat "$T/sql.log")"
n_sel=$(grep -c '^SELECT .* FROM workspace_doc' "$T/sql.log")
n_bad=$(grep '^SELECT .* FROM workspace_doc' "$T/sql.log" | grep -v "tenant_id <> 'system'" | grep -vc "tenant_id = :'t'")
((n_sel == 9 && n_bad == 0)) && pass "SQL: every per-workspace SELECT names :'t' (n=$((n_sel - 1)))" || fail "SQL selects n=$n_sel unscoped=$n_bad"

# --- 4. RED CONTROL: workspace A's backup into B's bucket ----------------------------------
plant
mkdir -p "$T/w" && cp "$T/db/w1/"* "$T/w/" && echo '{"tenant":"w1"}' >"$T/w/manifest.json"
o=$(SNIPPET="$STUBS GCP_ACCOUNT=tester@example.com WSDOC_BPREFIX=$PFX WSDOC_DAY=$DAY _spl_wsdoc_backup_put w1 ${PFX}w2 $T/w" in_orc T="$T" 2>&1); rc=$?
((rc == 1)) && grep -q "refused: the backup of w1 goes to gs://${PFX}w1 only, not gs://${PFX}w2" <<<"$o" && [[ "$(uploads)" == 0 ]] &&
  pass "RED CONTROL: a backup of w1 written to w2's bucket is refused, 0 uploads" || fail "A->B rc=$rc uploads=$(uploads): $o"
plant
o=$(bk DRY_RUN=0 DB_AS=w2 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w1 gs://${PFX}w1/backup/$DAY/ foreign-row\$" <<<"$o" && [[ -z "$(find "$T/gcs/${PFX}w1" -type f)" ]] &&
  pass "w2's rows exported for w1: FAIL foreign-row, nothing in w1's bucket" || fail "foreign rc=$rc: $o"

# --- 5. RED CONTROL: a backup missing one doc ----------------------------------------------
plant
o=$(bk DRY_RUN=0 DROP=docs.jsonl TENANT_ID=w1 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w1 gs://${PFX}w1/backup/$DAY/ count-docs restored=1 db=2\$" <<<"$o" &&
  grep -q "FATAL ENV=dev wsdoc backup $DAY: workspaces=1 ok=0 would_write=0 failed=1" <<<"$o" &&
  pass "RED CONTROL: a backup missing one doc fails the count check, exit 1" || fail "drop rc=$rc: $o"

# --- 6. no-bucket ---------------------------------------------------------------------------
plant; rm -rf "$T/gcs/${PFX}w2"
o=$(bk DRY_RUN=0 2>&1); rc=$?
((rc == 1)) && grep -q "^FAIL dev w2 gs://${PFX}w2/backup/$DAY/ no-bucket\$" <<<"$o" && grep -q '^ok dev w1 ' <<<"$o" &&
  [[ ! -e "$T/gcs/${PFX}w2" ]] && pass "no bucket: that workspace FAILs, the other is written" || fail "no-bucket rc=$rc: $o"

# --- 7. TENANT_ID ---------------------------------------------------------------------------
plant
o=$(bk DRY_RUN=0 TENANT_ID=w2 2>&1); rc=$?
((rc == 0)) && grep -q 'workspaces=1 ok=1 ' <<<"$o" && [[ -z "$(find "$T/gcs/${PFX}w1" -type f)" ]] &&
  ! grep -q "tenant_id <> 'system'" "$T/sql.log" && pass "TENANT_ID=w2: that workspace only, no list read" || fail "one rc=$rc: $o"

# --- 8. --account, no text ------------------------------------------------------------------
plant
o=$(bk DRY_RUN=0 2>&1)
[[ "$(grep -c '^gcloud ' "$T/calls.log")" -gt 0 && "$(grep '^gcloud ' "$T/calls.log" | grep -vc -- '--account=tester@example.com')" == 0 ]] &&
  pass "every gcloud call carries --account" || fail "a gcloud call without --account: $(cat "$T/calls.log")"
! grep -q SECRET-TEXT <<<"$o" && pass "no doc text in the output" || fail "doc text leaked: $o"

echo
((fails == 0)) && echo "ALL PASSED" || echo "FAILED: $fails"
exit $((fails > 0))
