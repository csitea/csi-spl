#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_backup / do_spl_db_backup_verify, offline (no cloud call):
#   1. the bucket comes from the cnf, never from a guessed name, and an env
#      without the 045 block is refused
#   2. the object name ends .sql.gz (Cloud SQL compresses on that suffix) and
#      carries a UTC stamp, so every dump is a new object
#   3. DRY_RUN defaults to 1: the plan prints the uri and NOTHING is exported.
#      CONTROL: DRY_RUN=0 does reach gcloud (the stub log records it)
#   4. spl_db_backup_check refuses a missing object and a stub-sized one - an
#      export that "succeeds" into a 0-byte object is the failure it exists for
#   5. spl_db_backup_compare is red for what a BROKEN dump looks like (a live
#      table missing, or restored empty while live has rows) and green for a
#      plain count difference, which is just two reads at two instants
#   5b. a dump at migration N versus a live schema at N+2 is green, and the
#      two tables created later are listed as expected missing. A table the
#      dump's own level should hold, missing, is still exit 5
#   6. every gcloud call is pinned with --account
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/spl-db-backup.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in docker psql; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done
# gcloud answers only the three verbs the action uses. It must answer
# `auth print-access-token`: do_spl_cloud_cnf SOURCES gcp-require-live-account,
# so a shell-level override of that function is overwritten before the action
# runs, and the credential check is reached for real.
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  *"print-access-token"*) head -c 1024 /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
  *"objects describe"*)   [ -n "$STUB_SIZE" ] && echo "$STUB_SIZE"; exit "${STUB_DESCRIBE_RC:-0}" ;;
  *"buckets describe"*)   [ "${STUB_NO_BUCKET:-0}" = 1 ] && exit 1; echo "a-bucket"; exit 0 ;;
  *) exit "${STUB_RC:-0}" ;;
esac
STUB
chmod +x "$T/stub/gcloud"

# the identity resolution itself is exercised elsewhere (gcloud-account-pinned);
# here only the account is fixed, so the test needs no key on disk
PIN='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };'

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" \
    STUB_SIZE="${STUB_SIZE:-}" STUB_RC="${STUB_RC:-0}" STUB_DESCRIBE_RC="${STUB_DESCRIBE_RC:-0}" \
    STUB_NO_BUCKET="${STUB_NO_BUCKET:-0}" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. the bucket comes from the cnf --------------------------------------------
for e in dev prd; do
  b=$(SNIPPET="do_spl_cloud_cnf >/dev/null && spl_db_backup_bucket" in_orc ENV="$e" SPL_STATE_DIR="$T/state-$e" 2>&1)
  [[ "$b" == "csi-spl-$e-db-backups" ]] && pass "$e: the bucket is csi-spl-$e-db-backups, read from the cnf" ||
    fail "$e bucket: $b"
done
cp "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml" "$T/no045.yaml"
python3 - "$T/no045.yaml" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = s.replace('backups_bucket_name: csi-spl-dev-db-backups', 'backups_bucket_name:')
open(p, 'w').write(s)
PY
o=$(SNIPPET='SPL_CNF="'"$T/no045.yaml"'"; spl_db_backup_bucket' in_orc 2>&1) && fail "an empty bucket was accepted: $o" ||
  pass "an env without a 045 bucket name is refused"
grep -q 'backups_bucket_name is empty' <<<"$o" && pass "the refusal names the cnf key" || fail "refusal text: $o"

# --- 2. the object name ------------------------------------------------------------
n=$(SNIPPET='SPL_DB_NAME=spool; spl_db_backup_object_name' in_orc 2>&1)
[[ "$n" == spool-*.sql.gz ]] && pass "the object is <db>-<stamp>.sql.gz: $n" || fail "object name: $n"
[[ "$n" =~ ^spool-[0-9]{8}T[0-9]{6}Z\.sql\.gz$ ]] && pass "the stamp is ISO-8601 UTC" || fail "stamp: $n"
n2=$(SNIPPET='SPL_DB_NAME=spool; spl_db_backup_object_name' in_orc 2>&1)
[[ -n "$n2" ]] && pass "a second call also produces a name" || fail "no second name"

# --- 3. DRY_RUN is the default ------------------------------------------------------
: >"$T/calls.log"
o=$(SNIPPET="$PIN do_spl_db_backup" in_orc 2>&1)
rc=$?
(( rc == 0 )) && pass "the default run succeeds as a plan" || fail "dry run rc=$rc: $o"
grep -q 'DRY RUN' <<<"$o" && pass "the plan says it exported nothing" || fail "no DRY RUN line: $o"
grep -q 'uri=gs://csi-spl-dev-db-backups/dev/spool-' <<<"$o" && pass "the plan prints the target uri" || fail "no uri: $o"
grep -q 'sql export' "$T/calls.log" && fail "DRY_RUN=1 still called export: $(cat "$T/calls.log")" ||
  pass "DRY_RUN=1: no export call"
: >"$T/calls.log"
STUB_SIZE=999999 SNIPPET="$PIN do_spl_db_backup" in_orc DRY_RUN=0 >/dev/null 2>&1
grep -q 'sql export' "$T/calls.log" && pass "CONTROL: DRY_RUN=0 does reach gcloud sql export" ||
  fail "CONTROL: DRY_RUN=0 made no export call: $(cat "$T/calls.log")"
grep -q -- '--account=tester@example.com' "$T/calls.log" && pass "the export is pinned with --account" ||
  fail "no --account in: $(cat "$T/calls.log")"

# --- 4. the object check ------------------------------------------------------------
check() { # <stub size> -> "rc=<n> <output>"
  local out rc
  out=$(STUB_SIZE="$1" SNIPPET='GCP_ACCOUNT=tester@example.com spl_db_backup_check gs://b/o' in_orc 2>&1); rc=$?
  echo "rc=$rc $out"
}
o=$(check "")
[[ "$o" == rc=4* ]] && pass "a missing object is exit 4" || fail "missing object: $o"
[[ "$o" == *"does not exist"* ]] && pass "the refusal says the object is not there" || fail "text: $o"
o=$(check 12)
[[ "$o" == rc=4* ]] && pass "a 12-byte object is exit 4 (a stub dump is not a backup)" || fail "small object: $o"
o=$(check 999999)
[[ "$o" == rc=0* ]] && pass "CONTROL: a 999999-byte object passes" || fail "big object: $o"

# --- 4b. a missing 045 bucket is a NAMED refusal, not a raw gcloud error ------------
: >"$T/calls.log"
o=$(STUB_NO_BUCKET=1 STUB_SIZE=999999 SNIPPET="$PIN do_spl_db_backup" in_orc DRY_RUN=0 2>&1); rc=$?
(( rc == 2 )) && pass "a missing 045 bucket is exit 2" || fail "missing bucket rc=$rc: $o"
[[ "$o" == *"does not exist"* && "$o" == *"045-gcs-db-backups"* && "$o" == *"make do-provision"* ]] &&
  pass "the refusal names the step AND the command that fixes it" || fail "refusal text: $o"
grep -q 'sql export' "$T/calls.log" && fail "it exported despite no bucket" ||
  pass "no bucket: nothing is exported"
: >"$T/calls.log"
STUB_NO_BUCKET=0 STUB_SIZE=999999 SNIPPET="$PIN do_spl_db_backup" in_orc DRY_RUN=0 >/dev/null 2>&1
grep -q 'sql export' "$T/calls.log" && pass "CONTROL: with the bucket present the export runs" ||
  fail "CONTROL: no export with a present bucket: $(cat "$T/calls.log")"

# --- 5. the restore verdict ----------------------------------------------------------
cmp_v() { # <restored> <live> -> "rc=<n> <output>"
  printf '%s\n' "$1" >"$T/r.txt"; printf '%s\n' "$2" >"$T/l.txt"
  local out rc
  out=$(SNIPPET="spl_db_backup_compare '$T/r.txt' '$T/l.txt'" in_orc 2>&1); rc=$?
  echo "rc=$rc $out"
}
o=$(cmp_v $'messages 177\ntenants 12' $'messages 177\ntenants 12')
[[ "$o" == rc=0* ]] && pass "identical counts: exit 0" || fail "identical: $o"
o=$(cmp_v $'messages 177\ntenants 12' $'messages 181\ntenants 12')
[[ "$o" == rc=0* ]] && pass "a plain count drift is exit 0 (two reads, two instants)" || fail "drift: $o"
o=$(cmp_v $'messages 177' $'messages 177\ntenants 12')
[[ "$o" == rc=5* && "$o" == *"missing from the restore"*tenants* ]] &&
  pass "a live table missing from the restore is exit 5 and is named" || fail "missing table: $o"
o=$(cmp_v $'messages 0\ntenants 12' $'messages 177\ntenants 12')
[[ "$o" == rc=5* && "$o" == *"restored EMPTY"*messages* ]] &&
  pass "a table restored EMPTY while live has rows is exit 5 (the RLS-blanked dump)" || fail "blank table: $o"
o=$(cmp_v '' $'messages 177')
[[ "$o" == rc=5* ]] && pass "an empty restore is exit 5" || fail "empty restore: $o"
o=$(cmp_v $'messages 177\ntenants 12' $'messages 177\ntenants 12')
[[ "$o" == *"TABLE RESTORED LIVE"* && "$o" == *"messages 177 177"* ]] &&
  pass "the per-table comparison is printed, not just the verdict" || fail "no table printed: $o"

# --- 5b. the dump's migration level, not the live schema --------------------------------
mkdir -p "$T/mig"
printf '%s\n' 'CREATE TABLE keep_me (id int);' >"$T/mig/0001_core.sql"
printf '%s\n' 'CREATE TABLE newer_a (id int);' >"$T/mig/0002_a.sql"
printf '%s\n' 'CREATE TABLE newer_b (id int);' >"$T/mig/0003_b.sql"
cmp_at() { # <restored> <live> <dump max filename>
  printf '%s\n' "$1" >"$T/r.txt"; printf '%s\n' "$2" >"$T/l.txt"
  local out rc
  out=$(SPL_DB_BACKUP_MIGRATIONS_DIR="$T/mig" SNIPPET="spl_db_backup_compare '$T/r.txt' '$T/l.txt' '$3'" in_orc 2>&1); rc=$?
  echo "rc=$rc $out"
}
o=$(cmp_at $'keep_me 4' $'keep_me 4\nnewer_a 1\nnewer_b 2' '0001_core.sql')
[[ "$o" == rc=0* ]] && pass "a dump at level N versus live at N+2 is exit 0" || fail "level N: $o"
[[ "$o" == *"newer_a"*"expected missing (newer than the dump: 0002_a.sql)"* ]] &&
  pass "newer_a is listed with its migration" || fail "newer_a: $o"
[[ "$o" == *"newer_b"*"expected missing (newer than the dump: 0003_b.sql)"* ]] &&
  pass "newer_b is listed with its migration" || fail "newer_b: $o"
o=$(cmp_at $'newer_a 1' $'keep_me 9\nnewer_a 1\nnewer_b 2' '0001_core.sql')
[[ "$o" == rc=5* && "$o" == *"missing from the restore"*keep_me* ]] &&
  pass "CONTROL: a table the dump's level should hold, missing, is still exit 5" || fail "control: $o"
o=$(cmp_v $'keep_me 4' $'keep_me 4\nnewer_a 1')
[[ "$o" == rc=5* && "$o" == *"missing from the restore"*newer_a* ]] &&
  pass "without the dump's migration max, a later table is still exit 5" || fail "no max: $o"
# the two tables the 2026-10-04 drill flagged, against the real migration files
printf '%s\n' 'messages 10' >"$T/r.txt"
printf '%s\n' $'messages 10\nbox_stats 5\noperator_audit 0' >"$T/l.txt"
o=$(SNIPPET="spl_db_backup_compare '$T/r.txt' '$T/l.txt' '0114_release_note_cycle.sql'" in_orc 2>&1); rc=$?
o="rc=$rc $o"
[[ "$o" == rc=0* ]] && pass "dump at 0114 versus live box_stats and operator_audit is exit 0" || fail "0114: $o"
[[ "$o" == *"box_stats"*"expected missing (newer than the dump: 0117_box_stats.sql)"* ]] &&
  pass "box_stats is listed as newer than the dump (0117)" || fail "box_stats: $o"
[[ "$o" == *"operator_audit"*"expected missing (newer than the dump: 0115_operator_workspaces.sql)"* ]] &&
  pass "operator_audit is listed as newer than the dump (0115)" || fail "operator_audit: $o"
# cnf SPOOL_HUB_MIGRATIONS_DIR is the path inside the hub image, not on this box
o=$(SPL_MIGRATIONS_DIR=/opt/spool/sql/postgres/spool-hub SNIPPET="spl_db_backup_compare '$T/r.txt' '$T/l.txt' '0114_release_note_cycle.sql'" in_orc 2>&1); rc=$?
o="rc=$rc $o"
[[ "$o" == rc=0* && "$o" == *"box_stats"*"0117_box_stats.sql"* ]] &&
  pass "the image-internal migrations path is not read as a host directory" || fail "image path: $o"
printf '%s\n' 'tenants 2' >"$T/r.txt"
printf '%s\n' $'tenants 2\nmessages 10\nbox_stats 5' >"$T/l.txt"
o=$(SNIPPET="spl_db_backup_compare '$T/r.txt' '$T/l.txt' '0114_release_note_cycle.sql'" in_orc 2>&1); rc=$?
o="rc=$rc $o"
[[ "$o" == rc=5* && "$o" == *"missing from the restore"*messages* ]] &&
  pass "CONTROL: messages, created before 0114, missing, is still exit 5" || fail "messages control: $o"

# --- 6. every gcloud call carries --account -------------------------------------------
# join backslash continuations first: the export spans two lines and its
# --account sits on the second, so a per-LINE grep reads it as unpinned
bad=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$ACTION" |
      grep -E '(^|[^_[:alnum:]])gcloud[[:space:]]' |
      grep -vE '^[[:space:]]*#' | grep -v 'do_require_bin' | grep -v -- '--account')
[[ -z "$bad" ]] && pass "every gcloud invocation in the action carries --account" || fail "unpinned gcloud: $bad"
grep -q 'enable-row-security' "$ACTION" && pass "the action explains the RLS trap a proxied pg_dump would hit" ||
  fail "no note on the RLS trap"

(( fails == 0 )) && echo "OK spl-db-backup: all checks passed" || { echo "FAIL spl-db-backup: $fails check(s)"; exit 1; }
