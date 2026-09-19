#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 020 / 040 import tools import, through the tf-runner, and only import.
#   table (src/bash/scripts/tf-import-table.sh), by sh, real dev + prd tfvars:
#   1. drift guard both ways: every row is a resource the step declares, and
#      every resource the step declares has a row
#   2. ids derived from the tfvars (bucket, SA email, instance, db, secret)
#   3. an unknown step -> exit 2; missing tfvars -> exit 1
#   action (do_tf_import_existing), docker stubbed:
#   4. ENV / STEP outside the allowed sets -> refused, docker never called
#   5. tf-runner not running -> refused, no exec
#   6. every exec goes to con-csi-csi-spl-tf-runner with ORG=csi APP=spl ENV STEP,
#      and runs only do_tf_state_list or do_tf_import (CONTROL: stub logs calls)
#   7. an address already in state is skipped, not re-imported
#   8. a failed import (NotFound) is non-fatal: rc 0, failed=N
#   9. DRY_RUN=1 reads the state and imports nothing
#  10. state list failing -> rc 1, imports nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
TABLE="$PROJ_ROOT/src/bash/scripts/tf-import-table.sh"
CON=con-csi-csi-spl-tf-runner
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---- the table --------------------------------------------------------------
for s in 020-gcp-relay-bucket 040-cloud-sql-postgres; do
  declared=$(command grep -hoE '^resource "[^"]+" "[^"]+"' "$APP_ROOT/csi-spl-iac/src/terraform/$s"/*.tf |
    sed -E 's/^resource "([^"]+)" "([^"]+)"/\1.\2/' | sort -u)
  for e in dev prd; do
    vars="$APP_ROOT/csi-spl-cnf/csi-spl/$e/tf/$s.vars.tfvars"
    tbl=$(sh "$TABLE" "$s" "$vars"); rc=$?
    [[ $rc -eq 0 ]] || { fail "$s $e: table rc=$rc"; continue; }
    rows=$(cut -f1 <<<"$tbl" | sort -u)
    [[ "$rows" == "$declared" ]] && pass "$s $e: table == declared resources ($(wc -l <<<"$rows"))" \
      || fail "$s $e: drift. table: $(echo $rows) declared: $(echo $declared)"
    project=$(sed -nE 's/^gcp_project *= *"([^"]+)".*/\1/p' "$vars")
    get() { sed -nE "s/^$1 *= *\"([^\"]+)\".*/\1/p" "$vars"; }
    case $s in
      020-*) sa="$(get relay_sa_account_id)@$project.iam.gserviceaccount.com"; b=$(get relay_bucket_name)
             want=$'google_storage_bucket.relay\t'"$project/$b"$'\ngoogle_service_account.relay\tprojects/'"$project/serviceAccounts/$sa"$'\ngoogle_storage_bucket_iam_member.relay_object_user\tb/'"$b roles/storage.objectUser serviceAccount:$sa" ;;
      040-*) i=$(get instance_name)
             want=$'google_sql_database_instance.hub\tprojects/'"$project/instances/$i"$'\ngoogle_sql_database.spool\tprojects/'"$project/instances/$i/databases/$(get database_name)"$'\ngoogle_secret_manager_secret.hub_db_dsn\tprojects/'"$project/secrets/$(get dsn_secret_id)" ;;
    esac
    [[ "$tbl" == "$want" ]] && pass "$s $e: ids from tfvars" || fail "$s $e: ids: $tbl"
  done
done
sh "$TABLE" 030-cloud-run-hub "$APP_ROOT/csi-spl-cnf/csi-spl/dev/tf/030-cloud-run-hub.vars.tfvars" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "unknown step -> exit 2" || fail "unknown step not refused"
sh "$TABLE" 040-cloud-sql-postgres "$T/nope.tfvars" >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "missing tfvars -> exit 1" || fail "missing tfvars not refused"

# ---- the action -------------------------------------------------------------
# docker stub: `ps` lists $RUNNING; `exec` logs one line per call
# (EXEC <container> <action> ORG= APP= ENV= STEP= TARGET= ID=), then answers:
#   do_tf_state_list -> $STATE_FIXTURE (or fails when STATE_FAIL=1)
#   do_tf_import     -> OK, unless TARGET is in $FAIL_ADDRS (NotFound)
mkdir -p "$T/stub"
cat >"$T/stub/docker" <<'EOF'
#!/bin/bash
[ "$1" = ps ] && { printf '%s\n' ${RUNNING:-}; exit 0; }
[ "$1" = exec ] || { echo "UNEXPECTED docker $*" >>"$DOCKER_LOG"; exit 1; }
shift; declare -A kv=()
while [ "$1" = -e ]; do kv[${2%%=*}]=${2#*=}; shift 2; done
con=$1; shift
echo "EXEC $con $* | ORG=${kv[ORG]:-} APP=${kv[APP]:-} ENV=${kv[ENV]:-} STEP=${kv[STEP]:-} TARGET=${kv[TARGET]:-} ID=${kv[ID]:-}" >>"$DOCKER_LOG"
case "$*" in
  "./run -a do_tf_state_list")
    [ "${STATE_FAIL:-0}" = 1 ] && { echo "Error: backend init failed"; exit 1; }
    echo "+ terraform state list"; [ -n "${STATE_FIXTURE:-}" ] && cat "$STATE_FIXTURE"; exit 0 ;;
  "./run -a do_tf_import")
    case " ${FAIL_ADDRS:-} " in *" ${kv[TARGET]} "*)
      echo "Error: Cannot import non-existent remote object"; echo "FATAL Failed to import resource"; exit 0 ;; esac
    echo "OK Resource imported successfully: ${kv[TARGET]} -> ${kv[ID]}"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/stub/docker"

run_action() { # env assignments...
  : >"$T/docker.log"
  env DOCKER_LOG="$T/docker.log" PATH="$T/stub:$PATH" RUNNING="$CON" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "'"$PROJ_ROOT"'/src/bash/run/tf-import-existing.func.sh"
    do_tf_import_existing' 2>&1
}

# 4.
for bad in "ENV= STEP=040-cloud-sql-postgres" "ENV=qa STEP=040-cloud-sql-postgres" "ENV=dev STEP=030-cloud-run-hub" "ENV=dev STEP="; do
  out=$(run_action $bad); rc=$?
  [[ $rc -ne 0 && ! -s "$T/docker.log" ]] && pass "refused: $bad" || fail "not refused: $bad (rc=$rc)"
done
# 5.
out=$(run_action ENV=dev STEP=040-cloud-sql-postgres RUNNING=other-con); rc=$?
[[ $rc -ne 0 && "$out" == *"is not running"* && ! -s "$T/docker.log" ]] && pass "tf-runner down -> refused" || fail "tf-runner down: rc=$rc"

# 6. happy path, both steps, both envs
for s in 020-gcp-relay-bucket 040-cloud-sql-postgres; do
  for e in dev prd; do
    out=$(run_action ENV=$e STEP=$s); rc=$?
    [[ $rc -eq 0 && "$out" == *"imported=3 skipped=0 failed=0"* ]] && pass "$s $e: 3 imported" || fail "$s $e: rc=$rc $(tail -3 <<<"$out")"
    [[ $(command grep -c . "$T/docker.log") -eq 4 ]] && pass "$s $e: 1 state list + 3 imports" || fail "$s $e: calls: $(cat "$T/docker.log")"
    command grep -v "^EXEC $CON ./run -a do_tf_\(state_list\|import\) | ORG=csi APP=spl ENV=$e STEP=$s " "$T/docker.log" | command grep -q . \
      && fail "$s $e: an exec outside the contract: $(cat "$T/docker.log")" || pass "$s $e: every exec = tf-runner, state_list|import, ORG/APP/ENV/STEP"
    command grep -qE 'apply|destroy|taint|state_(rm|push|remove)' "$T/docker.log" && fail "$s $e: mutating action" || pass "$s $e: no apply/destroy"
  done
done
command grep -qF "TARGET=google_sql_database.spool ID=projects/csi-spl-prd/instances/csi-spl-prd-pg/databases/spool" "$T/docker.log" \
  && pass "TARGET/ID reach do_tf_import intact" || fail "TARGET/ID: $(cat "$T/docker.log")"

# 7.
printf '%s\n' google_sql_database_instance.hub google_sql_database.spool >"$T/state.txt"
out=$(run_action ENV=dev STEP=040-cloud-sql-postgres STATE_FIXTURE="$T/state.txt")
[[ "$out" == *"imported=1 skipped=2 failed=0"* ]] && pass "in-state addresses skipped" || fail "skip: $(tail -3 <<<"$out")"
command grep -q 'TARGET=google_sql_database_instance.hub' "$T/docker.log" && fail "in-state instance re-imported" || pass "in-state instance not re-imported"

# 8.
out=$(run_action ENV=dev STEP=020-gcp-relay-bucket FAIL_ADDRS="google_storage_bucket.relay google_service_account.relay"); rc=$?
[[ $rc -eq 0 && "$out" == *"imported=1 skipped=0 failed=2"* && "$out" == *"WARN  could not import google_storage_bucket.relay"* ]] \
  && pass "NotFound imports non-fatal (rc 0, failed=2)" || fail "failed imports: rc=$rc $(tail -3 <<<"$out")"

# 9.
out=$(run_action ENV=prd STEP=040-cloud-sql-postgres DRY_RUN=1 STATE_FIXTURE="$T/state.txt"); rc=$?
[[ $rc -eq 0 && "$out" == *"planned=1"* && $(command grep -c do_tf_import "$T/docker.log") -eq 0 ]] \
  && pass "DRY_RUN=1 imports nothing" || fail "dry run: $(cat "$T/docker.log")"

# 10.
out=$(run_action ENV=dev STEP=040-cloud-sql-postgres STATE_FAIL=1); rc=$?
[[ $rc -ne 0 && $(command grep -c do_tf_import "$T/docker.log") -eq 0 ]] && pass "state list failure -> rc 1, no import" || fail "state fail: rc=$rc"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
