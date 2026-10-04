#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the message-to-db proof actions stay read-only, secret-free and
#          injection-proof, offline (no cloud call).
#   1. do_spl_db_message_show's filter: MSG_ID / TASK_ID must be uuids, LAST
#      1..50, TENANT_ID a slug; a quote-carrying value is refused before any
#      SQL is built. CONTROL: the good values yield the expected WHERE.
#   2. the SQL selects no body, env or env_sig column (hash + length only)
#   3. spl_psql_ro: the login reaches psql through PG* env only, never argv,
#      and runs BEGIN READ ONLY with default_transaction_read_only=on
#      (a stub psql records argv, env and stdin)
#   4. with no key readable, do_spl_db_message_show stops before gcloud
#   5. do_spl_box_msg_probe's dry run makes no spool, gcloud or curl call;
#      bad box / agent / label / key-file mode are refused. CONTROL: the stub
#      log records a call when one is made.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
for b in gcloud curl docker cloud-sql-proxy; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
cat >"$T/stub/psql" <<'EOF'
#!/bin/sh
{ echo "argv: $*"; env | grep '^PG' | sort; echo "stdin:"; cat; } >"$PSQL_LOG"
echo '{"msg_id":"stub"}'
EOF
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PSQL_LOG="$T/psql.log" PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

U=0f8fad5b-d9cb-469f-a165-70867728950e

# --- 1. filter ---------------------------------------------------------------------
out=$(SNIPPET=spl_db_message_filter in_orc TENANT_ID=t1 MSG_ID=$U 2>&1)
[[ "$out" == "m.tenant_id = 't1' AND m.msg_id = '$U'" ]] && pass "MSG_ID filter" || fail "MSG_ID filter: $out"
out=$(SNIPPET=spl_db_message_filter in_orc TENANT_ID=t1 TASK_ID=$U 2>&1)
[[ "$out" == "m.tenant_id = 't1' AND m.task_id = '$U'" ]] && pass "TASK_ID filter" || fail "TASK_ID filter: $out"
out=$(SNIPPET=spl_db_message_filter in_orc TENANT_ID=t1 2>&1)
[[ "$out" == *"ORDER BY m.received_at DESC LIMIT 5" ]] && pass "LAST defaults to 5" || fail "LAST default: $out"
for bad in "MSG_ID=$U' OR '1'='1" "TASK_ID=x" "LAST=0" "LAST=51" "LAST=5;drop" "TENANT_ID=t1'--" "TENANT_ID="; do
  if SNIPPET=spl_db_message_filter in_orc TENANT_ID=t1 "$bad" >"$T/o" 2>&1; then
    fail "refuses $bad: $(cat "$T/o")"
  else
    pass "refuses $bad"
  fi
done

# --- 2. SQL carries no body / envelope bytes ---------------------------------------
sql=$(SNIPPET='spl_db_message_sql "m.tenant_id = '"'"'t1'"'"'"' in_orc 2>&1)
grep -qE "'body'|m\.env\b|env_sig|'env'" <<<"$sql" && fail "SQL selects body/env: $(grep -E "body|env" <<<"$sql" | sed -n 1,2p)" \
  || pass "SQL selects no body, env or env_sig"
grep -q "body_sha256_16" <<<"$sql" && grep -q "FROM deliveries d" <<<"$sql" && pass "SQL: body hash + deliveries" \
  || fail "SQL lacks the hash or deliveries"

# --- 3. psql: env-only login, read-only --------------------------------------------
: >"$T/psql.log"
SNIPPET='spl_psql_ro "postgres://spool:s3cr%40t@127.0.0.1:55499/spool?sslmode=disable" "SELECT 1;"' in_orc >/dev/null 2>&1
grep -q '^argv: .*s3cr' "$T/psql.log" && fail "password in psql argv" || pass "no password in psql argv"
grep -qx 'PGPASSWORD=s3cr@t' "$T/psql.log" && pass "password (url-decoded) via PGPASSWORD" || fail "PGPASSWORD: $(grep PGPASS "$T/psql.log")"
grep -qx 'PGOPTIONS=-c default_transaction_read_only=on' "$T/psql.log" && pass "default_transaction_read_only=on" || fail "PGOPTIONS missing"
grep -qx 'BEGIN READ ONLY;' "$T/psql.log" && grep -qx 'ROLLBACK;' "$T/psql.log" && pass "BEGIN READ ONLY ... ROLLBACK" || fail "not a read-only txn"
grep -qx "SET LOCAL app.rls_scope = 'operator';" "$T/psql.log" && pass "operator RLS scope, transaction-local (rdb 0014)" || fail "no operator RLS scope: every tenant table reads empty under 0014"

# --- 4. no key: stops before gcloud --------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_db_message_show in_orc TENANT_ID=t1 LAST=1 SPL_SA_KEY="$T/none.json" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "no service-account key" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "no key: refused, no gcloud call" \
  || fail "no key: rc=$rc calls=$(cat "$T/calls.log") out=$out"

# --- 5. probe dry run and refusals -----------------------------------------------------
printf '{"root_private_key":"x"}\n' >"$T/t1.json"; chmod 600 "$T/t1.json"
printf '#!/bin/sh\necho "spool $*" >>"$STUB_LOG"\nexit 1\n' >"$T/stub/spool"; chmod +x "$T/stub/spool"
: >"$T/calls.log"
out=$(SNIPPET=do_spl_box_msg_probe in_orc TENANT_ID=t1 ROOT_KEY_JSON="$T/t1.json" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "probe dry run: no call" \
  || fail "probe dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "box-orc-probe under t1 at https://" <<<"$out" && ! grep -q "https://t1\." <<<"$out" && pass "probe dry run names box-orc-probe, tenant t1 and the API host (specs/026: no tenant host)" || fail "probe dry run text: $out"
out=$(SNIPPET=do_spl_box_msg_probe in_orc TENANT_ID=t1 ROOT_KEY_JSON="$T/t1.json" PROBE_TASK=00000000-0000-4000-8000-000000000001 2>&1)
grep -q "into task 00000000-0000-4000-8000-000000000001" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "probe dry run names PROBE_TASK, no call" || fail "PROBE_TASK dry run: $out"
for bad in "PROBE_BOX=box-wui" "PROBE_BOX=Bad_Box" "PROBE_AGENT=orc-1" "PROBE_LABEL=a;b" "TENANT_ID=T1" "PROBE_TASK=lobby" "PROBE_TASK=00000000-0000-4000-8000-00000000000Z"; do
  if SNIPPET=do_spl_box_msg_probe in_orc TENANT_ID=t1 ROOT_KEY_JSON="$T/t1.json" "$bad" >"$T/o" 2>&1; then
    fail "probe accepts $bad"
  else
    pass "probe refuses $bad"
  fi
done
chmod 644 "$T/t1.json"
SNIPPET=do_spl_box_msg_probe in_orc TENANT_ID=t1 ROOT_KEY_JSON="$T/t1.json" >"$T/o" 2>&1 && fail "probe accepts a 0644 key file" \
  || { grep -q "mode 0600" "$T/o" && pass "probe refuses a 0644 key file" || fail "0644 refusal text: $(cat "$T/o")"; }
# CONTROL: the stub log does record a call when one is made
SNIPPET='spool version' in_orc >/dev/null 2>&1
grep -q '^spool version' "$T/calls.log" && pass "CONTROL: stub records calls" || fail "CONTROL: stub recorded nothing"

(( fails == 0 )) && echo "OK msg-to-db: all checks passed" || { echo "msg-to-db: $fails failure(s)"; exit 1; }
