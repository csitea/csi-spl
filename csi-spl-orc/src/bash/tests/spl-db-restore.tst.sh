#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_restore, offline (no cloud call):
#   1. the target guard: an unknown target, a throwaway name that is not
#      spool_restore_*, and prd's own database without ALLOW_PRD_RESTORE=1
#      are refused. CONTROL: the same prd call WITH the flag passes the guard
#   2. DRY_RUN defaults to 1: the plan resolves the newest dump and its age
#      (the RPO) and creates, imports and drops nothing
#   3. a BACKUP_URI outside the env's 045 bucket is refused
#   4. CONTROL: DRY_RUN=0 TARGET=database:<x> creates the throwaway database,
#      imports AS THE SCHEMA OWNER (the default import user cannot run the
#      dump's ALTER DEFAULT PRIVILEGES FOR ROLE <owner>) and drops it again
#   5. TARGET=env refuses a database that already holds tables, before any
#      import: a restore never merges into live data
#   6. every gcloud call is pinned with --account
#   7. topic heads (spec 099 T007): TARGET=env, once the compare is green,
#      runs REBUILD=all DRY_RUN=0 do_spl_topic_head_backfill; a dump older than
#      rdb 0144 skips it and names the command; a failed backfill fails the
#      restore. CONTROL: a database:<x> target never backfills
#   8. TOPIC_HEAD_VERIFY=1 (TARGET=local only) runs the topic-head verify on
#      the restored throwaway container through the SPL_RESTORE_CHECK hook,
#      over its bridge address; one mismatch fails it (CONTROL: 0 passes)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/spl-db-restore.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in docker psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  *"print-access-token"*) head -c 1024 /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
  *"storage ls"*)         echo "gs://$STUB_BUCKET/$ENV/spool-20260101T000000Z.sql.gz"
                          echo "gs://$STUB_BUCKET/$ENV/spool-20260102T000000Z.sql.gz"; exit 0 ;;
  *"objects describe"*)   echo "2026-01-02T00:00:00+00:00"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/stub/gcloud"

# These checks stub the ENV 045 bucket, so they pin the default BACKUP_SOURCE to
# env by forcing cnf copy_enabled=false. The shipped cnf carries copy_enabled=true
# since the bkp project was bootstrapped (CLE-35114, 2026-09-29), which would flip
# the default to bkp (spl-db-restore.func.sh:55) and reach for the csi-spl-bkp key
# this hermetic stub does not have. The bkp read-back is proven live, not here.
PIN='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };
eval "$(declare -f do_spl_cloud_cnf | sed 1s/do_spl_cloud_cnf/_orig_cnf/)"; do_spl_cloud_cnf(){ _orig_cnf || return 1; yq -i ".env.steps.\"046-gcs-offsite-backups\".copy_enabled = false" "$SPL_CNF"; };'
# the proxy is the cloud; here it answers the two reads the action makes
PROXY='spl_via_proxy(){ echo "proxy $1" >>"$STUB_LOG"; case "$1" in _spl_db_restore_table_count) echo "${STUB_TABLES:-0}" ;; _spl_db_restore_schema_max) printf "%s\n" "${STUB_SCHEMA_MAX:-0114_release_note_cycle.sql}" ;; *) printf "messages 5\ntenants 2\n" ;; esac; };'

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" \
    STUB_BUCKET="csi-spl-${ENV_:-dev}-db-backups" STUB_TABLES="${STUB_TABLES:-0}" \
    PATH="$T/stub:$PATH" ENV="${ENV_:-dev}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. the target guard --------------------------------------------------------
for t in bogus database:spool database:prod_copy 'database:spool_restore_X'; do
  o=$(SNIPPET="$PIN do_spl_db_restore" in_orc TARGET="$t" 2>&1) && fail "TARGET=$t was accepted: $o" ||
    pass "TARGET=$t is refused"
done
o=$(ENV_=prd SNIPPET="$PIN do_spl_db_restore" in_orc TARGET=env SPL_STATE_DIR="$T/state-prd" 2>&1) &&
  fail "prd TARGET=env without the flag was accepted: $o" || pass "prd TARGET=env without ALLOW_PRD_RESTORE=1 is refused"
grep -q 'ALLOW_PRD_RESTORE=1' <<<"$o" && pass "the refusal names the flag" || fail "refusal text: $o"
o=$(ENV_=prd SNIPPET="$PIN do_spl_db_restore" in_orc TARGET=env ALLOW_PRD_RESTORE=1 SPL_STATE_DIR="$T/state-prd" 2>&1) &&
  pass "CONTROL: prd TARGET=env WITH the flag passes the guard (dry run)" || fail "CONTROL prd with flag: $o"

# --- 2. DRY_RUN is the default ----------------------------------------------------
: >"$T/calls.log"
o=$(SNIPPET="$PIN do_spl_db_restore" in_orc 2>&1); rc=$?
(( rc == 0 )) && pass "the default run succeeds as a plan" || fail "dry run rc=$rc: $o"
grep -q 'uri=gs://csi-spl-dev-db-backups/dev/spool-20260102T000000Z.sql.gz target=local rpo_s=[0-9]' <<<"$o" &&
  pass "latest = the newest object, and the plan prints its age (RPO)" || fail "plan line: $o"
grep -qE 'sql import|databases (create|delete)|storage cp' "$T/calls.log" &&
  fail "DRY_RUN=1 touched something: $(cat "$T/calls.log")" || pass "DRY_RUN=1: no create, import, drop or download"

# --- 3. a foreign uri is refused ----------------------------------------------------
o=$(SNIPPET="$PIN do_spl_db_restore" in_orc BACKUP_URI=gs://someone-else/x.sql.gz 2>&1) &&
  fail "a foreign BACKUP_URI was accepted: $o" || pass "a BACKUP_URI outside the 045 bucket is refused"

# --- 4. CONTROL: the throwaway database round trip ---------------------------------
: >"$T/calls.log"
o=$(SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=database:spool_restore_t 2>&1); rc=$?
(( rc == 0 )) && pass "CONTROL: DRY_RUN=0 into a throwaway database succeeds" || fail "round trip rc=$rc: $o"
grep -q 'databases create spool_restore_t' "$T/calls.log" && pass "it creates the throwaway database" ||
  fail "no create: $(cat "$T/calls.log")"
grep -q 'sql import sql .*--database=spool_restore_t --user=spool_hub ' "$T/calls.log" &&
  pass "it imports into it AS THE SCHEMA OWNER" || fail "import line: $(grep import "$T/calls.log")"
grep -q 'databases delete spool_restore_t' "$T/calls.log" && pass "it drops the throwaway afterwards" ||
  fail "no drop: $(cat "$T/calls.log")"
grep -q 'rto_s=[0-9]' <<<"$o" && pass "the run prints its RTO" || fail "no rto: $o"
grep -q 'proxy _spl_db_restore_schema_max' "$T/calls.log" &&
  pass "the cloud restore reads the dump's migration max before the compare" ||
  fail "no schema-max call: $(cat "$T/calls.log")"
: >"$T/calls.log"
SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=database:spool_restore_t KEEP=1 >/dev/null 2>&1
grep -q 'databases delete' "$T/calls.log" && fail "KEEP=1 still dropped it" || pass "KEEP=1 keeps the throwaway"

# --- 5. TARGET=env never merges into a populated database -----------------------------
: >"$T/calls.log"
o=$(STUB_TABLES=36 SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=env 2>&1) &&
  fail "a populated env database was restored into: $o" || pass "TARGET=env with 36 tables present is refused"
grep -q 'sql import' "$T/calls.log" && fail "it imported anyway" || pass "the refusal comes before any import"
: >"$T/calls.log"
STUB_TABLES=0 SNIPPET="$PIN $PROXY do_spl_db_restore" in_orc DRY_RUN=0 TARGET=env >/dev/null 2>&1
grep -q 'sql import sql .*--database=spool ' "$T/calls.log" &&
  pass "CONTROL: an EMPTY env database is imported into" || fail "CONTROL empty env: $(cat "$T/calls.log")"

# --- 6. every gcloud call carries --account -------------------------------------------
bad=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$ACTION" |
      grep -E '(^|[^_[:alnum:]])gcloud[[:space:]]' |
      grep -vE '^[[:space:]]*#' | grep -v 'do_require_bin' | grep -v -- '--account')
[[ -z "$bad" ]] && pass "every gcloud invocation in the action carries --account" || fail "unpinned gcloud: $bad"

# --- 7. topic heads after a restore into the env -----------------------------------
BACKFILL='do_spl_topic_head_backfill(){ echo "backfill ENV=$ENV REBUILD=${REBUILD:-} DRY_RUN=${DRY_RUN:-}" >>"$STUB_LOG"; return "${STUB_BACKFILL_RC:-0}"; };'
: >"$T/calls.log"
o=$(SNIPPET="$PIN $PROXY $BACKFILL do_spl_db_restore" in_orc DRY_RUN=0 TARGET=env STUB_SCHEMA_MAX=0144_topic_heads.sql 2>&1); rc=$?
(( rc == 0 )) && grep -qx 'backfill ENV=dev REBUILD=all DRY_RUN=0' "$T/calls.log" &&
  pass "TARGET=env rebuilds the topic heads: REBUILD=all DRY_RUN=0 do_spl_topic_head_backfill" ||
  fail "env backfill rc=$rc: $o $(cat "$T/calls.log")"
awk '/sql import sql/{i=NR} /^backfill /{b=NR} END{exit !(i && b > i)}' "$T/calls.log" &&
  pass "the backfill runs after the import" || fail "order: $(cat "$T/calls.log")"
: >"$T/calls.log"
o=$(SNIPPET="$PIN $PROXY $BACKFILL do_spl_db_restore" in_orc DRY_RUN=0 TARGET=env STUB_SCHEMA_MAX=0149_fleet_agent_kinds_off.sql STUB_BACKFILL_RC=1 2>&1); rc=$?
(( rc == 7 )) && grep -q 'topic-head backfill failed' <<<"$o" && pass "a failed backfill fails the restore (rc 7) and names the re-run" ||
  fail "backfill failure rc=$rc: $o"
: >"$T/calls.log"
o=$(SNIPPET="$PIN $PROXY $BACKFILL do_spl_db_restore" in_orc DRY_RUN=0 TARGET=env 2>&1); rc=$?
(( rc == 0 )) && ! grep -q '^backfill' "$T/calls.log" && grep -q 'predates 0144_topic_heads.sql.*REBUILD=all DRY_RUN=0 ./run -a do_spl_topic_head_backfill' <<<"$o" &&
  pass "a dump older than rdb 0144 skips the backfill and names the command" || fail "pre-0144 dump rc=$rc: $o $(cat "$T/calls.log")"
: >"$T/calls.log"
SNIPPET="$PIN $PROXY $BACKFILL do_spl_db_restore" in_orc DRY_RUN=0 TARGET=database:spool_restore_t STUB_SCHEMA_MAX=0144_topic_heads.sql >/dev/null 2>&1
grep -q '^backfill' "$T/calls.log" && fail "CONTROL: a throwaway database target backfilled" ||
  pass "CONTROL: a database:<x> target never backfills"

# --- 8. TOPIC_HEAD_VERIFY on the local throwaway ------------------------------------
for g in "TARGET=database:spool_restore_t|needs TARGET=local" "TOPIC_HEAD_VERIFY=yes|must be 0 or 1"; do
  o=$(SNIPPET="$PIN do_spl_db_restore" in_orc TOPIC_HEAD_VERIFY="${g%%=yes*}" "${g%%|*}" 2>&1) &&
    fail "${g%%|*} with TOPIC_HEAD_VERIFY accepted: $o" ||
    { grep -q "${g#*|}" <<<"$o" && pass "TOPIC_HEAD_VERIFY: ${g%%|*} is refused" || fail "refusal text: $o"; }
done
o=$(SNIPPET="$PIN do_spl_db_restore" in_orc TOPIC_HEAD_VERIFY=1 2>&1) &&
  pass "CONTROL: TOPIC_HEAD_VERIFY=1 with TARGET=local plans" || fail "CONTROL local verify plan: $o"
# the wiring: spl_db_restore_local hands the check to the restore container
: >"$T/calls.log"
WIRE='gunzip(){ :; }; spl_db_backup_restore_counts(){ echo "counts check=${SPL_RESTORE_CHECK:-} image=${SPL_RESTORE_IMAGE:-}" >>"$STUB_LOG"; return 9; };'
for v in 1 0; do
  SNIPPET="$PIN $WIRE do_spl_db_restore" in_orc DRY_RUN=0 TOPIC_HEAD_VERIFY=$v >/dev/null 2>&1
done
SNIPPET="$PIN $WIRE do_spl_db_restore" in_orc DRY_RUN=0 TOPIC_HEAD_VERIFY=1 SPL_RESTORE_IMAGE=my:img >/dev/null 2>&1
[[ "$(grep '^counts' "$T/calls.log" | paste -sd,)" == "counts check=spl_db_restore_topic_head_verify image=postgres:16,counts check= image=,counts check=spl_db_restore_topic_head_verify image=my:img" ]] &&
  pass "TOPIC_HEAD_VERIFY=1 sets SPL_RESTORE_CHECK and the glibc image (an explicit image wins); 0 leaves both unset" ||
  fail "wiring: $(cat "$T/calls.log")"
# the hook in spl_db_backup_restore_counts: called with the live container, its
# output kept off the count list, its failure failing the check
DOCKER='docker(){ echo "docker $*" >>"$STUB_LOG"; case "$1" in run|rm) return 0 ;; esac
  case "$*" in *"SELECT 1"*) return 0 ;; *information_schema*) echo messages ;; *"count(*) FROM"*) echo 3 ;; esac; };'
CHK='mycheck(){ echo "CHECKED $1"; echo "check $1" >>"$STUB_LOG"; return "${STUB_CHECK_RC:-0}"; };'
printf 'SELECT 1;\n' >"$T/dump.sql"
: >"$T/calls.log"
o=$(SNIPPET="$DOCKER $CHK spl_db_backup_restore_counts $T/dump.sql 2>/dev/null" in_orc SPL_RESTORE_CHECK=mycheck); rc=$?
(( rc == 0 )) && grep -qx 'messages 3' <<<"$o" && ! grep -q CHECKED <<<"$o" && grep -q '^check spl-restorecheck-dev-' "$T/calls.log" &&
  pass "the restore-check hook runs on the live container; stdout stays the count list" || fail "hook rc=$rc out=[$o] $(cat "$T/calls.log")"
awk '/^check /{c=NR} /^docker rm /{r=NR} END{exit !(c && r > c)}' "$T/calls.log" &&
  pass "the hook runs before the container is removed" || fail "hook order: $(cat "$T/calls.log")"
SNIPPET="$DOCKER $CHK spl_db_backup_restore_counts $T/dump.sql" in_orc SPL_RESTORE_CHECK=mycheck STUB_CHECK_RC=1 >/dev/null 2>&1 &&
  fail "a failing restore check passed" || pass "a failing restore check fails the restore"
# the verify itself: the do_spl_topic_head_verify read over the bridge address
VDOCK='docker(){ case "$1" in exec) echo "${STUB_HAS:-1}" ;; inspect) echo 172.17.0.9 ;; esac; };
spl_pg_env(){ echo "pg $1" >>"$STUB_LOG"; cat >/dev/null; printf "%b" "$STUB_PG"; };'
: >"$T/calls.log"
o=$(SNIPPET="$VDOCK spl_db_restore_topic_head_verify con1" in_orc STUB_PG='topics=12 tenants=2 marked=2 mismatches=0\n' 2>&1); rc=$?
(( rc == 0 )) && grep -q 'OK dev topic heads: topics=12 tenants=2 marked=2 mismatches=0' <<<"$o" &&
  grep -qx 'pg postgres://postgres:restorecheck@172.17.0.9:5432/restorecheck' "$T/calls.log" &&
  pass "CONTROL: 0 mismatches on the restored copy passes, read over the bridge address" || fail "verify 0: rc=$rc $o $(cat "$T/calls.log")"
o=$(SNIPPET="$VDOCK spl_db_restore_topic_head_verify con1" in_orc STUB_PG='topics=12 tenants=2 marked=2 mismatches=1\nt1 aaaaaaaa-0000-4000-8000-000000000001 head\n' 2>&1); rc=$?
(( rc == 1 )) && grep -q 'FAIL dev topic heads: .*mismatches=1' <<<"$o" &&
  pass "one mismatch on the restored copy fails the verify" || fail "verify 1: rc=$rc $o"
: >"$T/calls.log"
o=$(SNIPPET="$VDOCK spl_db_restore_topic_head_verify con1" in_orc STUB_HAS=0 2>&1); rc=$?
(( rc == 0 )) && grep -q 'no topic_head_diff' <<<"$o" && [[ ! -s "$T/calls.log" ]] &&
  pass "a dump older than rdb 0144 says so and reads nothing" || fail "pre-0144 verify: rc=$rc $o"

(( fails == 0 )) && echo "OK spl-db-restore: all checks passed" || { echo "FAIL spl-db-restore: $fails check(s)"; exit 1; }
