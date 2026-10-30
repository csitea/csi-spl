#!/usr/bin/env bash
#------------------------------------------------------------------------------
# do_spl_dedicated_bind (rdb 0219 dedicated_agents, specs/144, spec 158,
# SPL-4273):
#   1. bad input is refused before any cloud call (BOUND_BY missing or not a
#      HUM-*, agent / box / scope ids, the command, DRY_RUN)
#   2. bind runs as the env's project SA through the proxy, in the tenant's
#      RLS scope; values reach psql as -v variables, never spliced; a dry
#      run is READ ONLY in Postgres (PGOPTIONS) and writes nothing
#   3. each VERDICT maps to its refusal (not seated, no such scope, not an
#      owner, bound to another scope) or to a no-op (already bound)
#   4. unbind and list
#   5. on a throwaway Postgres (skipped without local initdb): the statement
#      itself refuses an unseated agent, a scope of another workspace, a
#      non-owner BOUND_BY and a rebind; a dry run writes no row; bind, the
#      same bind again, unbind and list do what they say
# gcloud and psql are stubbed in 1-4 and record every call (an absent call
# means "not made", not "not recorded").
# Red control (the commit body): drop the agent_seats WHEN in the action's
# SQL and case 5 prints "FAIL: 5. an agent not seated ...".
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d)
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
cleanup() {
  [[ -x "${PG_BIN:-/nonexistent}/pg_ctl" && -d "$T/pgdata" ]] && "$PG_BIN/pg_ctl" -D "$T/pgdata" -m immediate stop >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
DSN_PW="pw$RANDOM$RANDOM"
TOPIC=0b5e1c7a-1111-4a2b-9c3d-123456789abc
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<EOF
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:$DSN_PW@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
EOF
# psql: record PGOPTIONS, argv and stdin; answer $PSQL_OUT. Case 5 (PG_DSN
# set) hands the call to the real client.
REAL_PSQL="$(command -v psql)"
cat >"$T/stub/psql" <<EOF
#!/usr/bin/env bash
[[ -n "\${PG_DSN:-}" ]] && exec "$REAL_PSQL" "\$@"
EOF
cat >>"$T/stub/psql" <<'EOF'
printf 'psql PGOPTIONS=[%s]' "${PGOPTIONS:-}" >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
printf '%b' "${PSQL_OUT-VERDICT ok\n}"
EOF
chmod +x "$T/stub/"*

# in_orc <snippet> [VAR=val ...]: the snippet in a shell that sourced every
# orc function, the proxy stubbed (PG_DSN set = a real local Postgres).
in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u DEDICATED_CMD HOME="$T/home" PATH="$T/stub:$PATH" \
    STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    if [[ -n "${PG_DSN:-}" ]]; then
      spl_via_proxy() { echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; SPL_PROXY_DSN="$PG_DSN" "$@"; }
    fi
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

B=(TENANT_ID=ws-a AGENT_ID=c-123 BOX_ID=box-a SCOPE_TYPE=channel SCOPE_ID=general BOUND_BY=HUM-4)

# --- 1. input refused before any call -------------------------------------------------
for bad in 'BOUND_BY=' 'BOUND_BY=bob' "BOUND_BY=HUM-4' or '1'='1" 'AGENT_ID=bob' 'AGENT_ID=' 'BOX_ID=Box_A' \
    'TENANT_ID=T 1' 'SCOPE_TYPE=dm' 'SCOPE_ID=Gen eral' "SCOPE_TYPE=topic" "SCOPE_ID=${TOPIC^^}" \
    'DEDICATED_CMD=drop' 'DRY_RUN=yes'; do
  args=("${B[@]}" "$bad")
  [[ "$bad" == "SCOPE_ID=${TOPIC^^}" ]] && args+=(SCOPE_TYPE=topic)
  in_orc do_spl_dedicated_bind "${args[@]}" DRY_RUN=0; rc=$?
  [[ "$bad" == DRY_RUN=yes ]] && { in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=yes; rc=$?; }
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. bind $bad refused before any call" || fail "1. bind $bad: rc=$rc $(cat "$T/out")"
done
in_orc do_spl_dedicated_bind "${B[@]}" BOUND_BY= DRY_RUN=0
grep -q 'FATAL BOUND_BY is required' "$T/out" && pass "1. a missing BOUND_BY names itself" || fail "1. BOUND_BY message: $(cat "$T/out")"
in_orc do_spl_dedicated_bind TENANT_ID=ws-a AGENT_ID=c-123 BOX_ID=box-a DEDICATED_CMD=unbind DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. unbind without BOUND_BY refused before any call" || fail "1. unbind no BOUND_BY: rc=$rc"

# --- 2. bind: identity, variables, dry run --------------------------------------------
in_orc do_spl_dedicated_bind "${B[@]}"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN would bind c-123@box-a to channel:general' "$T/out" && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "2. bind DRY_RUN (default) runs the checks as the env SA $DEV_SA and prints the plan" || fail "2. dry: rc=$rc $(cat "$T/out" "$T/calls.log")"
grep -q 'PGOPTIONS=\[-c default_transaction_read_only=on\]' "$T/calls.log" && grep -q '\[dry=1\]' "$T/calls.log" \
  && pass "2. the dry run is READ ONLY in Postgres and passes dry=1" || fail "2. dry not read-only: $(cat "$T/calls.log")"
in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=0 PSQL_OUT='VERDICT ok\nBOUND c-123@box-a channel:general by HUM-4 at 2026-10-29\n'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK ws-a (dev, '"$DEV_SA"'): BOUND c-123@box-a' "$T/out" && grep -q '\[dry=0\]' "$T/calls.log" \
  && grep -q 'PGOPTIONS=\[\]' "$T/calls.log" && pass "2. bind DRY_RUN=0 writes and prints the BOUND row" || fail "2. real: rc=$rc $(cat "$T/out" "$T/calls.log")"
for v in tenant=ws-a agent=c-123 box=box-a stype=channel sid=general by=HUM-4; do
  grep -qF "[$v]" "$T/calls.log" || fail "2. -v $v missing"
done
! grep -qE 'ws-a|c-123|box-a|HUM-4|general' "$T/stdin" && pass "2. values reach psql as -v variables; the SQL holds only :'var' references" || fail "2. a value is spliced into the SQL"
grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" && pass "2. the statement runs in the tenant's RLS scope" || fail "2. no tenant scope"
grep -q 'FROM agent_seats WHERE' "$T/stdin" && grep -q 'FROM channels WHERE' "$T/stdin" && grep -q 'FROM messages WHERE' "$T/stdin" \
  && grep -q "FROM tenant_memberships WHERE" "$T/stdin" && pass "2. the seat, scope and owner checks are in the writing statement" || fail "2. a check is missing from the SQL"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" && fail "2. the DSN password leaked" || pass "2. the DSN password is in neither output nor argv"
in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=0 PSQL_OUT='VERDICT ok\n'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no BOUND row' "$T/out" && pass "2. ok without a BOUND row is a FATAL, not a silent success" || fail "2. no BOUND: rc=$rc"

# --- 3. verdicts ----------------------------------------------------------------------
check_verdict() {
  local v="$1" want_rc="$2" want="$3"
  in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=0 PSQL_OUT="VERDICT $v\n"; local rc=$?
  [[ $rc -eq $want_rc ]] && grep -q "$want" "$T/out" && pass "3. VERDICT $v -> rc $want_rc, '$want'" || fail "3. VERDICT $v: rc=$rc $(cat "$T/out")"
}
check_verdict not_seated 1 'c-123@box-a is not seated in ws-a (agent_seats)'
check_verdict no_scope 1 'channel:general is not a channel of ws-a'
check_verdict not_owner 1 'BOUND_BY HUM-4 is not an owner / admin member of ws-a'
check_verdict 'bound_elsewhere topic:'"$TOPIC" 1 "already dedicated to topic:$TOPIC in ws-a: one agent, one scope"
check_verdict already 0 'already dedicated to channel:general in ws-a (dev): nothing to do'
in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=0 PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no VERDICT' "$T/out" && pass "3. no VERDICT line is a FATAL" || fail "3. no verdict: rc=$rc"

# --- 4. unbind, list ------------------------------------------------------------------
U=(TENANT_ID=ws-a AGENT_ID=c-123 BOX_ID=box-a BOUND_BY=HUM-4 DEDICATED_CMD=unbind)
in_orc do_spl_dedicated_bind "${U[@]}" DRY_RUN=0 PSQL_OUT='UNBOUND c-123@box-a channel:general\n'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'UNBOUND c-123@box-a channel:general' "$T/out" && grep -q "DELETE FROM dedicated_agents WHERE tenant_id = :'tenant'" "$T/stdin" \
  && pass "4. unbind DRY_RUN=0 deletes the one binding" || fail "4. unbind: rc=$rc $(cat "$T/out")"
in_orc do_spl_dedicated_bind "${U[@]}" PSQL_OUT='UNBOUND c-123@box-a channel:general\n'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'DRY_RUN would unbind' "$T/out" && grep -q 'default_transaction_read_only=on' "$T/calls.log" \
  && pass "4. unbind dry run is read-only and says what it would remove" || fail "4. unbind dry: rc=$rc $(cat "$T/out")"
in_orc do_spl_dedicated_bind "${U[@]}" DRY_RUN=0 PSQL_OUT=''; rc=$?
[[ $rc -eq 0 ]] && grep -q 'nothing to unbind' "$T/out" && pass "4. unbinding an absent binding is a no-op that says so" || fail "4. unbind absent: rc=$rc"
in_orc do_spl_dedicated_bind TENANT_ID=ws-a DEDICATED_CMD=list PSQL_OUT='c-123 | box-a | channel | general | HUM-4 | 2026-10-29\n'; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'BEGIN TRANSACTION READ ONLY;' "$T/stdin" && grep -q 'c-123 | box-a' "$T/out" \
  && pass "4. list is read-only and prints the rows" || fail "4. list: rc=$rc $(cat "$T/out")"
in_orc do_spl_dedicated_bind TENANT_ID=ws-a DEDICATED_CMD=list PSQL_OUT=''; rc=$?
[[ $rc -eq 2 ]] && pass "4. list exits 2 when there is none" || fail "4. list none: rc=$rc"

# --- identity: never the owner account -------------------------------------------------
in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json" HOME="$T/nohome"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" && pass "2. no SA key: refused, no proxy, no psql" || fail "2. no key: rc=$rc $(cat "$T/calls.log")"

# --- 5. the statement on a throwaway Postgres ------------------------------------------
# pg_up -> PGPORT of a throwaway server, user/password spool, db spool:
# local server binaries (initdb) when installed, else a locally CACHED
# postgres image (never pulled), the rdb dedicated-agents-rls.tst.sh shape;
# with neither it fails, and case 5 skips.
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
pg_up() {
  if [[ -n "$PG_BIN" && -x "$PG_BIN/initdb" ]]; then
    PGPORT=$(( 20000 + RANDOM % 20000 ))
    printf 'spool\n' >"$T/pw"
    "$PG_BIN/initdb" -D "$T/pgdata" -U spool --pwfile="$T/pw" -A md5 >/dev/null 2>&1 &&
      "$PG_BIN/pg_ctl" -D "$T/pgdata" -o "-p $PGPORT -k $T -c listen_addresses=127.0.0.1" -l "$T/pg.log" -w start >/dev/null 2>&1 &&
      "$PG_BIN/createdb" -h 127.0.0.1 -p "$PGPORT" -U spool spool
  elif command -v docker >/dev/null && docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
    PG_CTR="spool-orc-dedicated-bind-test-$$"
    docker run -d --rm --label "csi-spl.lane=${AGENT_ID:-${SPOOL_AGENT_ID:-}}" --pull never --name "$PG_CTR" \
      -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool -e POSTGRES_DB=spool -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null || return 1
    # shellcheck source=pg-throwaway.inc.sh
    source "$TEST_DIR/pg-throwaway.inc.sh"
    PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
    local _
    for _ in $(seq 1 60); do
      PGPASSWORD=spool psql -X -q -h 127.0.0.1 -p "$PGPORT" -U spool -d spool -c 'SELECT 1' >/dev/null 2>&1 && return 0
      sleep 0.5
    done
    return 1
  else
    return 1
  fi
}
PG_CTR=""
trap 'cleanup; [[ -n "$PG_CTR" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1' EXIT
if ! command -v psql >/dev/null || ! PGPASSWORD=spool pg_up; then
  echo "SKIP: 5. no throwaway Postgres (no local initdb, no cached $PG_IMAGE)"
else
  export PGPASSWORD=spool
  # The columns the statement reads, as rdb 0002 / 0107 / 0219 spell them
  # (no RLS here: case 2 proves the tenant scope is set).
  psql -X -q -h 127.0.0.1 -p "$PGPORT" -U spool -d spool -v ON_ERROR_STOP=1 >/dev/null <<SQL || fail "5. schema"
CREATE TABLE agent_seats (tenant_id text, box_id text, agent_id text, PRIMARY KEY (tenant_id, box_id, agent_id));
CREATE TABLE channels (tenant_id text, channel_id text, PRIMARY KEY (tenant_id, channel_id));
CREATE TABLE messages (tenant_id text, task_id uuid);
CREATE TABLE tenant_memberships (tenant_id text, human_id text, role text);
CREATE TABLE dedicated_agents (tenant_id text NOT NULL, agent_id text NOT NULL, box_id text NOT NULL,
  scope_type text NOT NULL CHECK (scope_type IN ('channel', 'topic')), scope_id text NOT NULL,
  bound_by text NOT NULL, bound_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (tenant_id, agent_id, box_id));
INSERT INTO agent_seats VALUES ('ws-a', 'box-a', 'c-123'), ('ws-a', 'box-a', 'c-124'), ('ws-b', 'box-a', 'c-125');
INSERT INTO channels VALUES ('ws-a', 'general'), ('ws-b', 'other');
INSERT INTO messages VALUES ('ws-a', '$TOPIC');
INSERT INTO tenant_memberships VALUES ('ws-a', 'HUM-4', 'biz_owner'), ('ws-a', 'HUM-7', 'member');
SQL
  PGR=(PG_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool")
  rows() { psql -X -At -h 127.0.0.1 -p "$PGPORT" -U spool -d spool -c "SELECT count(*) FROM dedicated_agents ${1:-}"; }
  in_orc do_spl_dedicated_bind "${B[@]}" AGENT_ID=c-125 DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -ne 0 && "$(rows)" == 0 ]] && grep -q 'is not seated in ws-a' "$T/out" \
    && pass "5. an agent not seated in the workspace is refused; no row" || fail "5. an agent not seated in the workspace: rc=$rc rows=$(rows) $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" SCOPE_ID=other DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -ne 0 && "$(rows)" == 0 ]] && grep -q 'channel:other is not a channel of ws-a' "$T/out" \
    && pass "5. a channel of another workspace is refused; no row" || fail "5. foreign channel: rc=$rc $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" SCOPE_TYPE=topic SCOPE_ID=0b5e1c7a-2222-4a2b-9c3d-123456789abc DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -ne 0 && "$(rows)" == 0 ]] && grep -q 'is not a topic of ws-a' "$T/out" \
    && pass "5. an unknown topic is refused; no row" || fail "5. unknown topic: rc=$rc $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" BOUND_BY=HUM-7 DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -ne 0 && "$(rows)" == 0 ]] && grep -q 'not an owner / admin member' "$T/out" \
    && pass "5. a BOUND_BY that is a member, not an owner, is refused; no row" || fail "5. non-owner: rc=$rc $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 && "$(rows)" == 0 ]] && grep -q 'DRY_RUN would bind' "$T/out" \
    && pass "5. a dry run passes every check and writes no row" || fail "5. dry run: rc=$rc rows=$(rows) $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 && "$(rows "WHERE agent_id = 'c-123' AND scope_id = 'general' AND bound_by = 'HUM-4'")" == 1 ]] \
    && pass "5. bind DRY_RUN=0 writes the one row" || fail "5. bind: rc=$rc rows=$(rows) $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 && "$(rows)" == 1 ]] && grep -q 'nothing to do' "$T/out" && pass "5. the same bind again is a no-op" || fail "5. rebind same: rc=$rc $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" SCOPE_TYPE=topic SCOPE_ID="$TOPIC" DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -ne 0 && "$(rows "WHERE scope_type = 'topic'")" == 0 ]] && grep -q 'already dedicated to channel:general' "$T/out" \
    && pass "5. a bind to another scope is refused (one agent, one scope)" || fail "5. rebind other: rc=$rc $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${B[@]}" AGENT_ID=c-124 SCOPE_TYPE=topic SCOPE_ID="$TOPIC" DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 && "$(rows "WHERE agent_id = 'c-124' AND scope_type = 'topic'")" == 1 ]] && pass "5. a topic bind writes its row" || fail "5. topic: rc=$rc $(cat "$T/out")"
  in_orc do_spl_dedicated_bind TENANT_ID=ws-a DEDICATED_CMD=list "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 ]] && grep -q '^c-123 | box-a | channel | general | HUM-4 | ' "$T/out" && grep -q '^c-124 | box-a | topic | ' "$T/out" \
    && pass "5. list prints both bindings" || fail "5. list: rc=$rc $(cat "$T/out")"
  in_orc do_spl_dedicated_bind "${U[@]}" "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 && "$(rows)" == 2 ]] && grep -q 'DRY_RUN would unbind' "$T/out" && pass "5. an unbind dry run removes nothing" || fail "5. unbind dry: rc=$rc rows=$(rows)"
  in_orc do_spl_dedicated_bind "${U[@]}" DRY_RUN=0 "${PGR[@]}"; rc=$?
  [[ $rc -eq 0 && "$(rows "WHERE agent_id = 'c-123'")" == 0 && "$(rows)" == 1 ]] && pass "5. unbind DRY_RUN=0 removes only that agent's row" || fail "5. unbind: rc=$rc rows=$(rows)"
fi

echo "dedicated-bind: $fails failure(s)"
[[ $fails -eq 0 ]]
