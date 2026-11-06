#!/usr/bin/env bash
#------------------------------------------------------------------------------
# do_spl_agent_seats_prune (rdb 0107 agent_seats, spec 061 3.6, SPL-4918):
#   1. bad input is refused before any call: a pattern, a role seat in the
#      current form or from lease.conf, a duplicate, an empty list
#   2. a retired legacy id passes the guards, also the CLE-001 form
#   3. stubbed psql: the dry run writes nothing, values reach psql as -v
#      variables, each refusal and a count mismatch end non-zero
#   4. on a throwaway Postgres with the real rdb 0107 table, as a non-owner
#      login so RLS binds (skipped without local initdb or a cached image): a
#      seat with a roster row, another tenant's seat, a count mismatch rolling
#      back, the dry run, and the delete of exactly the named rows
# gcloud and psql are stubbed in 1-3 and record every call (an absent call
# means "not made", not "not recorded").
# Red control (the commit body): make the action's SQL COMMIT on a mismatch and
# case 4 prints "FAIL: 4. a count mismatch rolls back".
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d)
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PG_CTR=""
cleanup() {
  [[ -x "${PG_BIN:-/nonexistent}/pg_ctl" && -d "$T/pgdata" ]] && "$PG_BIN/pg_ctl" -D "$T/pgdata" -m immediate stop >/dev/null 2>&1
  [[ -n "$PG_CTR" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/spool/dispatch"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
printf 'LEASE_MASTER=c-222\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$T/spool/dispatch/lease.conf"

cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
case "$*" in
  "auth activate-service-account"*) for a; do [[ "$a" == --key-file=* ]] && jq -r .client_email "${a#*=}" >"$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:pw@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
EOF
# psql: record PGOPTIONS, argv and stdin; answer $PSQL_PLAN for the read and
# $PSQL_DEL for the delete. Case 4 (PG_DSN set) hands the call to the real one.
REAL_PSQL="$(command -v psql)"
cat >"$T/stub/psql" <<EOF
#!/usr/bin/env bash
[[ -n "\${PG_DSN:-}" ]] && exec "$REAL_PSQL" "\$@"
EOF
cat >>"$T/stub/psql" <<'EOF'
printf 'psql PGOPTIONS=[%s]' "${PGOPTIONS:-}" >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
in="$(cat)"; printf '%s\n' "$in" >>"$T_STDIN"
if grep -q 'DELETE FROM agent_seats' <<<"$in"; then echo DELETE-SENT >>"$STUB_LOG"; printf '%b' "${PSQL_DEL:-}"; else printf '%b' "${PSQL_PLAN:-}"; fi
EOF
chmod +x "$T/stub/"*

# in_orc [VAR=val ...]: the action in a shell that sourced every orc function,
# the proxy stubbed (PG_DSN set = a real local Postgres).
in_orc() {
  : >"$T/calls.log"; : >"$T/stdin"
  ( cd "$T/glob" && env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u AGENT_IDS -u TENANT_ID -u BOX_ID HOME="$T/home" PATH="$T/stub:$PATH" \
    STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    SPOOL_ROOT="$T/spool" SPOOL_TEST=1 ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    if [[ -n "${PG_DSN:-}" ]]; then
      spl_via_proxy() { echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; SPL_PROXY_DSN="$PG_DSN" "$@"; }
    fi
    do_spl_agent_seats_prune' ) >"$T/out" 2>&1 </dev/null
}
# A file a glob in AGENT_IDS would expand to, if the action let it expand.
mkdir -p "$T/glob"; : >"$T/glob/CLE-1"

B=(TENANT_ID=ws-a BOX_ID=box-a)

# --- 1. input refused before any call -------------------------------------------------
refused() { # <label> <needle> <env assignments...>
  local label="$1" needle="$2"; shift 2
  in_orc "${B[@]}" DRY_RUN=0 "$@"; local rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "$needle" "$T/out" \
    && pass "1. $label refused before any call" || fail "1. $label: rc=$rc $(cat "$T/out" "$T/calls.log")"
}
refused "a glob"                    "not a whole agent id" 'AGENT_IDS=CLE-*'
refused "a glob after a good id"    "not a whole agent id" 'AGENT_IDS=CLE-1 CLE-3*'
refused "a LIKE pattern"            "not a whole agent id" 'AGENT_IDS=CLE-%'
refused "a regex"                   "not a whole agent id" 'AGENT_IDS=CLE-[0-9]+'
refused "a quote"                   "not a whole agent id" "AGENT_IDS=CLE-1' or '1'='1"
refused "a human id"                "not a whole agent id" 'AGENT_IDS=HUM-10'
refused "an empty list"             "AGENT_IDS is required" 'AGENT_IDS='
refused "a blank list"              "AGENT_IDS is required" 'AGENT_IDS=   '
refused "a duplicate"               "names CLE-1 twice"     'AGENT_IDS=CLE-1 CLE-1'
for seat in c-001 c-002 c-003 g-001 g-002 g-003; do
  refused "role seat $seat" "$seat is an orchestrator or dispatcher seat" "AGENT_IDS=CLE-1 $seat"
done
refused "lease.conf id c-222, no 001..003 number" "c-222 is an orchestrator or dispatcher seat" 'AGENT_IDS=c-222'
refused "a bad TENANT_ID"           "TENANT_ID must be a tenant slug" TENANT_ID=T_1 AGENT_IDS=CLE-1
refused "a bad BOX_ID"              "is not a box id"       BOX_ID=Box_A AGENT_IDS=CLE-1
refused "a bad DRY_RUN"             "DRY_RUN must be"       DRY_RUN=yes AGENT_IDS=CLE-1

FUNC="$PROJ_ROOT/src/bash/run/spl-agent-seats-prune.func.sh"
other_writes="$(grep -E '^[^#]*(DELETE FROM|UPDATE|INSERT INTO|TRUNCATE) ' "$FUNC" | grep -v 'DELETE FROM agent_seats')"
[[ -z "$other_writes" ]] && pass "1. agent_seats is the only table the action writes" || fail "1. the action writes another table: $other_writes"

# --- 2. a retired legacy id passes the guards -----------------------------------------
PLAN='CLE-001|prune|f|2026-10-24\nCLE-35013|prune|f|2026-10-24\nc-001|keep|t|2026-11-03\n'
L=("${B[@]}" 'AGENT_IDS=CLE-001 CLE-35013' "PSQL_PLAN=$PLAN")
in_orc "${L[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN would prune 2 seat(s) from dev/ws-a/box-a: CLE-001 CLE-35013' "$T/out" \
  && pass "2. the retired CLE-001 and CLE-35013 pass the guards" || fail "2. legacy ids: rc=$rc $(cat "$T/out")"

# --- 3. stubbed psql ------------------------------------------------------------------
in_orc "${L[@]}"
grep -q 'DELETE-SENT' "$T/calls.log" && fail "3. the dry run sent the delete" || pass "3. DRY_RUN (default) never sends the delete"
grep -qx "proxy-start as $DEV_SA" "$T/calls.log" && pass "3. it runs as the env SA $DEV_SA" || fail "3. identity: $(cat "$T/calls.log")"
grep -q 'PGOPTIONS=\[-c default_transaction_read_only=on\]' "$T/calls.log" \
  && pass "3. the plan is READ ONLY in Postgres" || fail "3. plan not read-only: $(cat "$T/calls.log")"
grep -q '^c-001|keep|t|' "$T/out" && grep -q '^CLE-001|prune|f|' "$T/out" \
  && pass "3. the dry run prints every seat with prune/keep" || fail "3. list: $(cat "$T/out")"
in_orc "${L[@]}" DRY_RUN=0 PSQL_DEL='2 t CLE-001 CLE-35013\n'; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK pruned 2 seat(s) from dev/ws-a/box-a ($DEV_SA): CLE-001 CLE-35013" "$T/out" \
  && pass "3. DRY_RUN=0 reports what it deleted" || fail "3. real: rc=$rc $(cat "$T/out")"
for v in tenant=ws-a box=box-a 'agents=CLE-001 CLE-35013' want=2; do
  grep -qF "[$v]" "$T/calls.log" && pass "3. -v $v" || fail "3. -v $v missing: $(cat "$T/calls.log")"
done
! grep -qE 'ws-a|box-a|CLE-' "$T/stdin" && pass "3. values reach psql as -v variables; the SQL holds only :'var' references" || fail "3. a value is spliced into the SQL"
[[ "$(grep -cx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin")" == 2 ]] \
  && pass "3. plan and delete both run in the tenant's RLS scope" || fail "3. tenant scope: $(cat "$T/stdin")"
in_orc "${L[@]}" DRY_RUN=0 PSQL_DEL='1 f CLE-001\n'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL 1 of 2 seat(s) matched in dev/ws-a/box-a: ROLLED BACK' "$T/out" \
  && pass "3. a count mismatch is a FATAL" || fail "3. mismatch: rc=$rc $(cat "$T/out")"
in_orc "${B[@]}" AGENT_IDS=CLE-404 DRY_RUN=0 "PSQL_PLAN=$PLAN"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no seat in dev/ws-a/box-a: CLE-404' "$T/out" && ! grep -q DELETE-SENT "$T/calls.log" \
  && pass "3. an id with no seat is refused; no delete sent" || fail "3. no seat: rc=$rc $(cat "$T/out")"
in_orc "${B[@]}" AGENT_IDS=CLE-7 DRY_RUN=0 'PSQL_PLAN=CLE-7|prune|t|2026-10-24\n'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL a live roster row in dev/ws-a/box-a: CLE-7' "$T/out" && ! grep -q DELETE-SENT "$T/calls.log" \
  && pass "3. an id with a roster row is refused; no delete sent" || fail "3. roster: rc=$rc $(cat "$T/out")"

# --- 4. the SQL on a throwaway Postgres -----------------------------------------------
# pg_up -> PGPORT of a throwaway server, user/password spool, db spool: local
# server binaries when installed, else a locally CACHED image (never pulled).
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
pg_up() {
  if [[ -n "$PG_BIN" && -x "$PG_BIN/initdb" ]]; then
    PGPORT=$(( 20000 + RANDOM % 20000 ))
    printf 'spool\n' >"$T/pw"
    "$PG_BIN/initdb" -D "$T/pgdata" -U spool --pwfile="$T/pw" -A md5 >/dev/null 2>&1 &&
      "$PG_BIN/pg_ctl" -D "$T/pgdata" -o "-p $PGPORT -k $T -c listen_addresses=127.0.0.1" -l "$T/pg.log" -w start >/dev/null 2>&1 &&
      "$PG_BIN/createdb" -h 127.0.0.1 -p "$PGPORT" -U spool spool
  elif command -v docker >/dev/null && docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
    PG_CTR="spool-orc-agent-seats-prune-test-$$"
    docker run -d --rm --label "csi-spl.lane=${AGENT_ID:-${SPOOL_AGENT_ID:-}}" --pull never --name "$PG_CTR" \
      -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool -e POSTGRES_DB=spool -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null || return 1
    # shellcheck source=pg-throwaway.inc.sh
    source "$TEST_DIR/pg-throwaway.inc.sh"
    PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
    local _
    for _ in $(seq 1 60); do
      PGPASSWORD=spool "$REAL_PSQL" -X -q -h 127.0.0.1 -p "$PGPORT" -U spool -d spool -c 'SELECT 1' >/dev/null 2>&1 && return 0
      sleep 0.5
    done
    return 1
  else
    return 1
  fi
}
if ! PGPASSWORD=spool pg_up; then
  echo "SKIP: 4. no throwaway Postgres (no local initdb, no cached $PG_IMAGE)"
else
  owner() { PGPASSWORD=spool "$REAL_PSQL" -X -q -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGPORT" -U spool -d spool "$@"; }
  # The real rdb 0107 table with its FK and RLS, the parents cut to the columns
  # it needs. A non-owner login: only then does FORCE ROW LEVEL SECURITY bind.
  owner -c "CREATE TABLE boxes (tenant_id text, box_id text, PRIMARY KEY (tenant_id, box_id));" >/dev/null || fail "4. schema"
  owner -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub/0107_agent_seats.sql" >/dev/null || fail "4. rdb 0107"
  owner >/dev/null <<'SQL' || fail "4. seed"
CREATE TABLE roster (tenant_id text, box_id text, agent_id text, PRIMARY KEY (tenant_id, box_id, agent_id));
CREATE TABLE messages (tenant_id text, from_id text);
CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt';
GRANT SELECT, DELETE ON agent_seats TO spool_rt;
GRANT SELECT ON roster TO spool_rt;
INSERT INTO boxes VALUES ('ws-a', 'box-a'), ('ws-a', 'box-b'), ('ws-b', 'box-a');
SET app.rls_scope = 'operator';
INSERT INTO agent_seats (tenant_id, box_id, agent_id, seated_at) VALUES
  ('ws-a', 'box-a', 'CLE-001', now()), ('ws-a', 'box-a', 'CLE-11', now()), ('ws-a', 'box-a', 'CLE-12', now()),
  ('ws-a', 'box-a', 'CLE-13', now()), ('ws-a', 'box-a', 'CLE-77', now()), ('ws-a', 'box-a', 'c-001', now()),
  ('ws-a', 'box-b', 'CLE-11', now()), ('ws-b', 'box-a', 'CLE-99', now());
INSERT INTO roster VALUES ('ws-a', 'box-a', 'CLE-77'), ('ws-a', 'box-a', 'c-001');
INSERT INTO messages VALUES ('ws-a', 'CLE-11');
SQL
  PGR=(PG_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool")
  seats() { owner -c "SET app.rls_scope = 'operator'; SELECT string_agg(tenant_id || '/' || box_id || '/' || agent_id, ' ' ORDER BY tenant_id, box_id, agent_id) FROM agent_seats" | tail -n1; }
  START="$(seats)"

  in_orc "${B[@]}" 'AGENT_IDS=CLE-11 CLE-12' "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 && "$(seats)" == "$START" ]] && grep -q '^CLE-11|prune|f|' "$T/out" && grep -q '^CLE-77|keep|t|' "$T/out" && ! grep -q 'CLE-99' "$T/out" \
    && pass "4. the dry run deletes nothing and lists this box's seats, no other tenant's" || fail "4. dry run: rc=$rc $(cat "$T/out")"
  in_orc "${B[@]}" 'AGENT_IDS=CLE-11 CLE-77' DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -ne 0 && "$(seats)" == "$START" ]] && grep -q 'a live roster row in dev/ws-a/box-a: CLE-77' "$T/out" \
    && pass "4. a seat with a roster row is refused; CLE-11 survives too" || fail "4. roster: rc=$rc $(cat "$T/out")"
  in_orc "${B[@]}" AGENT_IDS=CLE-99 DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -ne 0 && "$(seats)" == "$START" ]] && grep -q 'no seat in dev/ws-a/box-a: CLE-99' "$T/out" \
    && pass "4. another tenant's seat reads as no seat (rdb 0107 RLS), and survives" || fail "4. cross-tenant: rc=$rc $(cat "$T/out")"

  # The race the plan cannot see: the roster row appears after the plan, so the
  # delete itself must hold CLE-77 back, match 1 of 2 and undo CLE-11.
  (
    export PROJ_PATH="$PROJ_ROOT"
    do_log() { :; }
    # shellcheck source=/dev/null
    source "$PROJ_ROOT/src/bash/run/spl-agent-seats-prune.func.sh"
    _spl_agent_seats_prune_sql | PGPASSWORD=rt "$REAL_PSQL" -X -q -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGPORT" -U spool_rt -d spool \
      -v tenant=ws-a -v box=box-a -v agents='CLE-11 CLE-77' -v want=2
  ) >"$T/mismatch" 2>&1; rc=$?
  [[ $rc -eq 0 && "$(tail -n1 "$T/mismatch")" == "1 f CLE-11" && "$(seats)" == "$START" ]] \
    && pass "4. a count mismatch rolls back: 1 of 2 matched, CLE-11 is still there" || fail "4. a count mismatch rolls back: rc=$rc $(cat "$T/mismatch") seats=$(seats)"

  in_orc "${B[@]}" 'AGENT_IDS=CLE-001 CLE-11 CLE-12' DRY_RUN=0 "${PGR[@]}"; rc=$?
  WANT='ws-a/box-a/c-001 ws-a/box-a/CLE-13 ws-a/box-a/CLE-77 ws-a/box-b/CLE-11 ws-b/box-a/CLE-99'
  got="$(tr ' ' '\n' <<<"$(seats)" | LC_ALL=C sort | tr '\n' ' ')"; want="$(tr ' ' '\n' <<<"$WANT" | LC_ALL=C sort | tr '\n' ' ')"
  [[ $rc -eq 0 && "$got" == "$want" ]] && grep -q 'OK pruned 3 seat(s) from dev/ws-a/box-a' "$T/out" \
    && pass "4. DRY_RUN=0 deletes exactly the named rows of that box" || fail "4. delete: rc=$rc got=[$got] want=[$want] $(cat "$T/out")"
  [[ "$(owner -c "SELECT count(*) FROM roster") $(owner -c "SELECT count(*) FROM messages") $(owner -c "SELECT count(*) FROM boxes")" == "2 1 3" ]] \
    && pass "4. roster, messages and boxes are untouched" || fail "4. a kept table changed"
fi

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
