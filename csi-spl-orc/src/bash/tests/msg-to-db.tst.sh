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
#   6. do_spl_box_msg_probe's defaults past the specs/061 legacy cutoff: the
#      default agent is not a retired id, and a key already on disk with no
#      local pin record is reused (pinned again, no --force) when the hub pins
#      that same key. CONTROL: a key the hub does not pin is refused and kept,
#      never overwritten (a stub spool keeps the hub's pin in a file).
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

# --- 6. probe defaults past the legacy cutoff, key reuse -------------------------------
LATE=2026-10-07T07:45:00Z
out=$(SNIPPET=do_spl_box_msg_probe in_orc SPOOL_NOW=$LATE TENANT_ID=t1 ROOT_KEY_JSON="$T/t1.json" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "mode 0600" <<<"$out" && pass "late: still refuses the 0644 key file" || fail "late 0644: rc=$rc $out"
chmod 600 "$T/t1.json"
out=$(SNIPPET=do_spl_box_msg_probe in_orc SPOOL_NOW=$LATE TENANT_ID=t1 ROOT_KEY_JSON="$T/t1.json" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && pass "late: the default PROBE_AGENT passes the 061 id check" \
  || fail "late: default PROBE_AGENT refused: rc=$rc $out"
SNIPPET=do_spl_box_msg_probe in_orc SPOOL_NOW=$LATE TENANT_ID=t1 ROOT_KEY_JSON="$T/t1.json" PROBE_AGENT=ORC-1 >"$T/o" 2>&1 \
  && fail "late: accepts the retired ORC-1" || pass "late: CONTROL refuses the retired ORC-1"
# a stub spool: keygen refuses an existing key as the real one does; hub-pin keeps
# the hub's pin in $HUB_PIN and answers a different key with the hub's 409
cat >"$T/stub/spool-probe" <<'EOF_STUB'
#!/usr/bin/env python3
import base64, json, os, sys
v, a = sys.argv[1], sys.argv[2:]
open(os.environ["STUB_LOG"], "a").write("spool " + " ".join(sys.argv[1:]) + "\n")
arg = lambda f: a[a.index(f) + 1]
kf = os.path.join(os.environ["SPOOL_KEYS_DIR"], "box-%s.key" % os.environ["SPOOL_BOX_ID"])
hub = os.environ["HUB_PIN"]
if v == "keygen":
    if os.path.exists(kf) and "--force" not in a:
        sys.exit("key for %s already exists (use --force to overwrite): %s" % (os.environ["SPOOL_BOX_ID"], kf))
    k = os.urandom(64)
    open(kf, "w").write(base64.b64encode(k).decode() + "\n")
    print(base64.b64encode(k[32:]).decode())
elif v == "hub-pin":
    if os.path.exists(hub) and open(hub).read() != arg("--pubkey") and "--force" not in a:
        sys.exit("hub: 409 pin_conflict: box_id is pinned to a different key or revoked (use force)")
    open(hub, "w").write(arg("--pubkey"))
elif v == "hub-sync":
    print('{"pushed":1}')
elif v == "send":
    print(json.dumps({"msg_id": "m-1", "task_id": "tk-1", "from": arg("--from")}))
elif v == "hub-tail":
    print('{"msg_id": "m-1"}')
EOF_STUB
chmod +x "$T/stub/spool-probe"
mkkey() {  # KEYFILE PUBFILE
  python3 -c 'import base64,os,sys; k=os.urandom(64); open(sys.argv[1],"w").write(base64.b64encode(k).decode()+"\n"); open(sys.argv[2],"w").write(base64.b64encode(k[32:]).decode())' "$1" "$2"
}
probe_live() {
  SNIPPET='spl_host_spool() { SPL_SPOOL="$PROBE_SPOOL"; }; do_spl_box_msg_probe' in_orc SPOOL_NOW=$LATE TENANT_ID=t1 \
    ROOT_KEY_JSON="$T/t1.json" DRY_RUN=0 PROBE_SPOOL="$T/stub/spool-probe" HUB_PIN="$T/hub.pin" 2>&1
}
PD="$T/state/dev/probe/t1/box-orc-probe"
# 6a: the state found on dev: a key on disk, no local pin record, the hub pins that key
mkdir -p "$PD/keys"; mkkey "$PD/keys/box-box-orc-probe.key" "$T/hub.pin"; k0=$(md5sum <"$PD/keys/box-box-orc-probe.key")
: >"$T/calls.log"
out=$(probe_live); rc=$?
[[ $rc -eq 0 ]] && grep -q "OK probe note sent by c-901@box-orc-probe" <<<"$out" && pass "reuse: an existing key the hub pins: PASS as c-901" \
  || fail "reuse: rc=$rc $out"
grep -q '^spool keygen' "$T/calls.log" && fail "reuse: keygen was called: $(cat "$T/calls.log")" || pass "reuse: no keygen over an existing key"
grep -q "^spool hub-pin --box box-orc-probe --pubkey $(cat "$T/hub.pin") " "$T/calls.log" && ! grep -q -- '--force' "$T/calls.log" \
  && pass "reuse: re-pins the key's own public key, no --force" || fail "reuse: hub-pin call: $(grep hub-pin "$T/calls.log")"
[[ "$(md5sum <"$PD/keys/box-box-orc-probe.key")" == "$k0" && "$(cat "$PD/pinned")" == "$(cat "$T/hub.pin")" ]] \
  && pass "reuse: key kept, local pin record written" || fail "reuse: key or record changed"
# 6b: the second run in a row: the record matches the key, so no keygen and no hub-pin
: >"$T/calls.log"
out=$(probe_live); rc=$?
[[ $rc -eq 0 ]] && ! grep -qE '^spool (hub-pin|keygen)' "$T/calls.log" && pass "second run: PASS, no keygen, no hub-pin" \
  || fail "second run: rc=$rc calls=$(cat "$T/calls.log") $out"
# 6c CONTROL: the hub pins ANOTHER key: refused before any send, the key on disk survives
rm -f "$PD/pinned"; mkkey "$T/other.key" "$T/hub.pin"
: >"$T/calls.log"
out=$(probe_live); rc=$?
[[ $rc -ne 0 ]] && grep -q "pin_conflict" <<<"$out" && ! grep -q '^spool send' "$T/calls.log" && pass "CONTROL: a key/pin mismatch is refused before any send" \
  || fail "CONTROL mismatch: rc=$rc calls=$(cat "$T/calls.log") $out"
[[ "$(md5sum <"$PD/keys/box-box-orc-probe.key")" == "$k0" && ! -e "$PD/pinned" ]] && ! grep -q -- '--force' "$T/calls.log" \
  && pass "CONTROL: a mismatch keeps the key, writes no pin record, never --force" || fail "CONTROL: key overwritten or forced"
# 6d: a stale local record (it names another key) is checked at the hub, not trusted
echo stale >"$PD/pinned"
out=$(probe_live); rc=$?
[[ $rc -ne 0 ]] && grep -q "pin_conflict" <<<"$out" && pass "a stale local pin record does not bypass the hub check" || fail "stale record: rc=$rc $out"
# 6e: a fresh box (no key): keygen once, pinned, PASS
rm -rf "$PD" "$T/hub.pin"
out=$(probe_live); rc=$?
[[ $rc -eq 0 && -s "$PD/keys/box-box-orc-probe.key" && "$(cat "$PD/pinned" 2>/dev/null)" == "$(cat "$T/hub.pin" 2>/dev/null)" ]] \
  && pass "fresh box: keygen + pin + PASS" || fail "fresh box: rc=$rc $out"

(( fails == 0 )) && echo "OK msg-to-db: all checks passed" || { echo "msg-to-db: $fails failure(s)"; exit 1; }
