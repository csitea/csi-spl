#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_db_owner_split + the owner-run bootstrap (017 T029).
#   1. DRY_RUN (default) calls no cloud in every mode; bad flags are refused
#   2. split: the owner DSN is copied to the owner slot, the runtime role +
#      grants run AS THE OWNER before the runtime DSN is added, the runtime
#      login is verified, only then are the older runtime versions disabled;
#      the verifier travels on stdin, no password in argv or output
#   3. refusals: an unknown login in the runtime slot; a verify failure
#      disables nothing
#   4. re-run once split: grants only, no new version; ROLLBACK=1 puts the
#      owner DSN back; ROTATE_OWNER=1 refuses while the owner has sessions
#   5. bootstrap migrates with the OWNER DSN and re-applies the grants
#   6. REAL Postgres (a cached postgres:16-alpine image; SKIP without):
#      the SCRAM verifier logs in, runtime-role.sql + runtime-grants.sql as
#      a non-superuser owner give a login spl_db_runtime_verify accepts, and
#      the owner itself is refused (CONTROL)
# gcloud, psql, spool and curl are stubbed and record every call; the secret
# store is a directory of numbered versions.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); PG_CTR=""
trap '[ -n "$PG_CTR" ] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
OWNER_PW="ownerpw$RANDOM$RANDOM"
OWNER_DSN="postgres://spool_hub:$OWNER_PW@/spool?host=/cloudsql/csi-spl-dev:europe-north1:csi-spl-dev-pg"
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# secret store: $SEC/<id>/<n> (n = 1, 2, ...), $SEC/<id>/<n>.disabled
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud|$*" >>"$STUB_LOG"
sec_of() { for a; do [[ "$a" == --secret=* ]] && echo "${a#--secret=}"; done; }
latest() { ls "$SEC/$1" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1; }
case "$*" in
  "auth activate-service-account"*) for a; do [[ "$a" == --key-file=* ]] && jq -r .client_email "${a#*=}" >"$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access latest"*) s=$(sec_of "$@"); n=$(latest "$s"); [[ -n "$n" ]] && cat "$SEC/$s/$n" || exit 1 ;;
  "secrets versions add "*) s="$4"; mkdir -p "$SEC/$s"; n=$(( $(latest "$s" || echo 0) + 1 )); cat >"$SEC/$s/$n"; echo "ADD $s $n" >>"$STUB_LOG" ;;
  "secrets versions list "*) s="$4"; for n in $(ls "$SEC/$s" 2>/dev/null | grep -E '^[0-9]+$' | sort -rn); do [[ -e "$SEC/$s/$n.disabled" ]] || echo "$n"; done ;;
  "secrets versions disable "*) s=$(sec_of "$@"); touch "$SEC/$s/$4.disabled"; echo "DISABLE $s $4" >>"$STUB_LOG" ;;
  "sql users list"*) echo spool_hub ;;
  "sql operations wait"*) : ;;
esac
exit 0
EOF
# psql: records the login (PGUSER) and stdin; answers the facts query from
# $FACTS, refuses the two probes like Postgres, counts sessions from $SESSIONS
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
in=$(cat); { echo "psql as=$PGUSER"; printf '%s\n' "$in"; } >>"$T_STDIN"
echo "psql as=$PGUSER $(grep -oE '^[A-Z]+( [A-Z]+)?' <<<"$in" | tr '\n' ' ')" >>"$STUB_LOG"
case "$in" in
  *"ALTER TABLE messages"*) echo "ERROR:  must be owner of table messages" >&2; exit 3 ;;
  *"GRANT \""*) echo "ERROR:  permission denied to grant role \"spool_hub\"" >&2; exit 3 ;;
  *json_build_object*) echo "$FACTS" ;;
  *pg_stat_activity*) echo "${SESSIONS:-0}" ;;
esac
exit 0
EOF
cat >"$T/stub/spool" <<'EOF'
#!/usr/bin/env bash
u=$(SPL_DSN_IN="$SPOOL_HUB_DB_DSN" python3 -c 'import os,urllib.parse as u; print(u.urlsplit(os.environ["SPL_DSN_IN"]).username)')
echo "spool $1 as=$u" >>"$STUB_LOG"
EOF
printf '#!/usr/bin/env bash\necho "curl $*" >>"$STUB_LOG"; echo "{\\"name\\":\\"op1\\"}"\n' >"$T/stub/curl"
chmod +x "$T/stub/"*
GOOD='{"role":"spool_hub_rt","superuser":false,"bypassrls":false,"createrole":false,"createdb":false,"member_of":0,"owns":0,"schema_create":false,"tenants":3}'

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    T_STDIN="$T/stdin" SEC="$T/sec" FACTS="$GOOD" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    spl_host_spool() { SPL_SPOOL=$(command -v spool); }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
seed() { rm -rf "$T/sec"; mkdir -p "$T/sec/csi-spl-hub-db-dsn"; printf '%s' "$OWNER_DSN" >"$T/sec/csi-spl-hub-db-dsn/1"; }
newest() { local s="$T/sec/$1" n; n=$(ls "$s" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1); [[ -n "$n" ]] && cat "$s/$n"; }
user_of() { SPL_DSN_IN="$1" python3 -c 'import os,urllib.parse as u; print(u.urlsplit(os.environ["SPL_DSN_IN"]).username or "")'; }
line() { grep -n -m1 -F "$1" "$T/calls.log" | cut -d: -f1; }
no_leak() { # <label>: no owner or runtime password in output, stdout of calls, argv
  local rt_pw; rt_pw=$(SPL_DSN_IN="$(newest csi-spl-hub-db-dsn)" python3 -c 'import os,urllib.parse as u; print(u.urlsplit(os.environ["SPL_DSN_IN"]).password or "none")')
  if grep -qF -e "$OWNER_PW" -e "$rt_pw" "$T/out" "$T/calls.log" "$T/stdin"; then fail "$1: a password leaked (output / argv / psql stdin)"
  else pass "$1: no password in output, argv or psql stdin"; fi
}

# --- 1. DRY_RUN + flags -----------------------------------------------------------
for m in "" ROLLBACK=1 ROTATE_OWNER=1; do
  seed; in_orc do_spl_db_owner_split $m; rc=$?
  [[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'OK DRY_RUN nothing was touched' "$T/out" \
    && pass "1. DRY_RUN ${m:-split}: no cloud call" || fail "1. dry ${m:-split}: rc=$rc $(cat "$T/calls.log" "$T/out")"
done
seed; in_orc do_spl_db_owner_split
grep -q 'create runtime role spool_hub_rt' "$T/out" && grep -q 'csi-spl-hub-db-owner-dsn' "$T/out" \
  && pass "1. DRY_RUN names the runtime role and the owner slot from cnf" || fail "1. dry names: $(cat "$T/out")"
for bad in "ROLLBACK=1 ROTATE_OWNER=1" "ROLLBACK=yes" "DRY_RUN=2"; do
  seed; in_orc do_spl_db_owner_split DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. $bad refused before any call" || fail "1. $bad: rc=$rc"
done

# --- 2. split -----------------------------------------------------------------------
seed; in_orc do_spl_db_owner_split DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q 'is split: owner spool_hub' "$T/out" && pass "2. split exit 0" || fail "2. split: rc=$rc $(cat "$T/out")"
[[ "$(newest csi-spl-hub-db-owner-dsn)" == "$OWNER_DSN" ]] && pass "2. the owner slot holds the old hub DSN (spool_hub)" || fail "2. owner slot: $(newest csi-spl-hub-db-owner-dsn)"
[[ "$(user_of "$(newest csi-spl-hub-db-dsn)")" == spool_hub_rt ]] && pass "2. the runtime slot's newest version is spool_hub_rt" || fail "2. runtime slot user: $(user_of "$(newest csi-spl-hub-db-dsn)")"
grep -q '^psql as=spool_hub .*SELECT' "$T/calls.log" && grep -q "\\\\set runtime_verifier 'SCRAM-SHA-256\$4096:" "$T/stdin" \
  && grep -q 'CREATE ROLE %I LOGIN' "$T/stdin" && grep -q 'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES' "$T/stdin" \
  && pass "2. runtime-role.sql (SCRAM verifier on stdin) and runtime-grants.sql ran as the owner spool_hub" || fail "2. roles sql: $(cat "$T/calls.log")"
a=$(line 'ADD csi-spl-hub-db-dsn'); g=$(grep -n 'psql as=spool_hub ' "$T/calls.log" | tail -1 | cut -d: -f1); v=$(line 'psql as=spool_hub_rt'); d=$(line 'DISABLE csi-spl-hub-db-dsn')
[[ -n "$a" && -n "$g" && -n "$v" && -n "$d" && $g -lt $a && $a -lt $v && $v -lt $d ]] \
  && pass "2. order: grants as owner < runtime DSN added < verify as runtime < older versions disabled" || fail "2. order g=$g a=$a v=$v d=$d"
[[ -e "$T/sec/csi-spl-hub-db-dsn/1.disabled" && ! -e "$T/sec/csi-spl-hub-db-dsn/2.disabled" ]] \
  && pass "2. the old owner version of the runtime slot is disabled, the new one is not" || fail "2. disable: $(ls "$T/sec/csi-spl-hub-db-dsn")"
grep -q 'OK refused as spool_hub_rt: ALTER TABLE messages NO FORCE' "$T/out" && grep -q 'OK refused as spool_hub_rt: GRANT "spool_hub" TO CURRENT_USER' "$T/out" \
  && pass "2. both lift probes ran as the runtime login and were refused" || fail "2. probes: $(cat "$T/out")"
no_leak "2. split"
grep -q "$(yq -r '.env.gcp.gcp_account_owner_email' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")" "$T/calls.log" "$T/out" \
  && fail "2. the owner Google account was used" || pass "2. only the env SA ($DEV_SA) was used"

# --- 3. refusals --------------------------------------------------------------------
seed; printf '%s' "${OWNER_DSN/spool_hub:/stranger:}" >"$T/sec/csi-spl-hub-db-dsn/1"
in_orc do_spl_db_owner_split DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^ADD' "$T/calls.log" && pass "3. a stranger in the runtime slot and an empty owner slot: refused, nothing written" || fail "3. stranger: rc=$rc $(cat "$T/calls.log")"
seed; in_orc do_spl_db_owner_split DRY_RUN=0 FACTS="${GOOD/\"owns\":0/\"owns\":31}"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'NOT split: owns=31' "$T/out" && ! grep -q '^DISABLE' "$T/calls.log" \
  && pass "3. a runtime login that owns tables fails verify and disables nothing" || fail "3. verify fail: rc=$rc $(cat "$T/out")"

# --- 4. re-run, rollback, rotate ------------------------------------------------------
seed; in_orc do_spl_db_owner_split DRY_RUN=0; cp -r "$T/sec" "$T/sec.split"
in_orc do_spl_db_owner_split DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^ADD' "$T/calls.log" && grep -q 'GRANT SELECT' "$T/stdin" && ! grep -q 'runtime_verifier' "$T/stdin" \
  && pass "4. re-run once split: grants re-applied, no new password, no new version" || fail "4. re-run: rc=$rc $(cat "$T/calls.log")"
in_orc do_spl_db_owner_split DRY_RUN=0 ROLLBACK=1; rc=$?
[[ $rc -eq 0 && "$(newest csi-spl-hub-db-dsn)" == "$OWNER_DSN" ]] && pass "4. ROLLBACK=1: the runtime slot's newest version is the owner DSN again" || fail "4. rollback: rc=$rc"
rm -rf "$T/sec"; cp -r "$T/sec.split" "$T/sec"
in_orc do_spl_db_owner_split DRY_RUN=0 ROTATE_OWNER=1 SESSIONS=2; rc=$?
[[ $rc -ne 0 ]] && grep -q '2 other session(s)' "$T/out" && ! grep -q '^curl' "$T/calls.log" \
  && pass "4. ROTATE_OWNER=1 with owner sessions open: refused, no Admin API call" || fail "4. rotate busy: rc=$rc $(cat "$T/out")"
in_orc do_spl_db_owner_split DRY_RUN=0 ROTATE_OWNER=1 SESSIONS=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^curl -sS -X PUT' "$T/calls.log" && [[ "$(user_of "$(newest csi-spl-hub-db-owner-dsn)")" == spool_hub ]] \
  && [[ "$(newest csi-spl-hub-db-owner-dsn)" != "$OWNER_DSN" && -e "$T/sec/csi-spl-hub-db-owner-dsn/1.disabled" ]] \
  && pass "4. ROTATE_OWNER=1 idle: PUT the owner user, new owner version, old one disabled" || fail "4. rotate: rc=$rc $(cat "$T/out")"
grep -qF "$OWNER_PW" "$T/calls.log" && fail "4. rotate: a password in argv" || pass "4. rotate: no password in argv"

# --- 5. bootstrap as the owner ----------------------------------------------------------
rm -rf "$T/sec"; cp -r "$T/sec.split" "$T/sec"
in_orc do_spl_db_bootstrap DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^spool migrate as=spool_hub$' "$T/calls.log" && grep -q 'GRANT SELECT' "$T/stdin" && ! grep -q '^ADD' "$T/calls.log" \
  && pass "5. bootstrap (split env): spool migrate as the OWNER, then grants re-applied, no secret written" || fail "5. bootstrap split: rc=$rc $(cat "$T/calls.log" "$T/out")"
seed; in_orc do_spl_db_bootstrap DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^spool migrate as=spool_hub$' "$T/calls.log" && grep -q 'run do_spl_db_owner_split' "$T/out" && ! grep -q '^ADD' "$T/calls.log" \
  && pass "5. bootstrap (not split yet): migrates with the owner DSN, writes nothing, points at the split" || fail "5. bootstrap owner: rc=$rc $(cat "$T/out")"
rm -rf "$T/sec"; mkdir -p "$T/sec"
in_orc do_spl_db_bootstrap DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(user_of "$(newest csi-spl-hub-db-owner-dsn)")" == spool_hub && "$(user_of "$(newest csi-spl-hub-db-dsn)")" == spool_hub_rt ]] \
  && grep -q '^spool migrate as=spool_hub$' "$T/calls.log" && pass "5. bootstrap (fresh env): owner via Admin API, migrate as owner, runtime role + its DSN" \
  || fail "5. bootstrap fresh: rc=$rc $(cat "$T/out")"

# --- 6. real Postgres ---------------------------------------------------------------------
IMG="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if command -v docker >/dev/null && docker image inspect "$IMG" >/dev/null 2>&1 && command -v psql >/dev/null; then
  PG_CTR="spl-owner-split-tst-$$"
  docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=su -e POSTGRES_PASSWORD=su -e POSTGRES_DB=spool \
    -p 127.0.0.1::5432 "$IMG" >/dev/null
  PORT=$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')
  for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U su -d spool -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 1
  docker exec -i "$PG_CTR" psql -q -v ON_ERROR_STOP=1 -U su -d spool >/dev/null <<'EOF'
CREATE ROLE own LOGIN PASSWORD 'own' CREATEROLE;
ALTER DATABASE spool OWNER TO own;
ALTER SCHEMA public OWNER TO own;
SET ROLE own;
CREATE TABLE tenants (tenant_id text PRIMARY KEY);
CREATE TABLE messages (tenant_id text NOT NULL REFERENCES tenants, body text);
ALTER TABLE messages ENABLE ROW LEVEL SECURITY; ALTER TABLE messages FORCE ROW LEVEL SECURITY;
CREATE TABLE spool_schema_migrations (filename text PRIMARY KEY);
INSERT INTO tenants VALUES ('t1'), ('t2');
-- rdb 0143's search door: runtime-grants.sql names it, so a migrated schema has it
CREATE FUNCTION spool_search_candidates(q tsquery, cap int) RETURNS SETOF text LANGUAGE sql STABLE AS 'SELECT NULL::text LIMIT 0';
EOF
  RPW="rt$RANDOM$RANDOM"
  real() { env PATH="$PATH" SPL_DB_USER=rt SPL_DB_OWNER_USER=own SPL_DB_ROLES_SQL="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles" \
    PROJ_PATH="$PROJ_ROOT" RPW="$RPW" SNIPPET="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    eval "$SNIPPET"' 2>&1; }
  ODSN="postgres://own:own@127.0.0.1:$PORT/spool"
  out=$(real "ver=\$(printf %s \"\$RPW\" | spl_scram_verifier); spl_db_roles_psql '$ODSN' runtime-role.sql \"\\\\set runtime_verifier '\$ver'\" && spl_db_roles_psql '$ODSN' runtime-grants.sql"); rc=$?
  [[ $rc -eq 0 ]] && pass "6. runtime-role.sql + runtime-grants.sql run as a non-superuser owner" || fail "6. roles sql: rc=$rc $out"
  PGPASSWORD="$RPW" psql -X -q -At -h 127.0.0.1 -p "$PORT" -U rt -d spool -c 'select 1' 2>/dev/null | grep -x 1 >/dev/null \
    && pass "6. the runtime login authenticates with the password behind the client-side SCRAM verifier" || fail "6. SCRAM login failed"
  PGPASSWORD="wrong" psql -X -q -At -h 127.0.0.1 -p "$PORT" -U rt -d spool -c 'select 1' >/dev/null 2>&1 \
    && fail "6. CONTROL: a wrong password logged in" || pass "6. CONTROL: a wrong password is refused"
  docker exec "$PG_CTR" psql -At -U su -d spool -c "select rolpassword like 'SCRAM-SHA-256\$4096:%' from pg_authid where rolname='rt'" | grep -x t >/dev/null \
    && pass "6. the server stores the verifier (never saw the clear text)" || fail "6. stored password is not the SCRAM verifier"
  out=$(real "spl_db_runtime_verify 'postgres://rt:$RPW@127.0.0.1:$PORT/spool'"); rc=$?
  [[ $rc -eq 0 ]] && grep -q '"owns" : 0\|"owns":0\|owns 0' <<<"$out" && grep -q 'OK refused as rt: ALTER TABLE messages' <<<"$out" && grep -q 'OK refused as rt: GRANT "own"' <<<"$out" \
    && pass "6. spl_db_runtime_verify accepts the real runtime login (owns 0, both lift probes refused by Postgres)" || fail "6. verify runtime: rc=$rc $out"
  out=$(real "SPL_DB_USER=own spl_db_runtime_verify 'postgres://own:own@127.0.0.1:$PORT/spool'"); rc=$?
  [[ $rc -ne 0 ]] && grep -q 'NOT split' <<<"$out" && pass "6. CONTROL: the owner itself fails spl_db_runtime_verify" || fail "6. owner control: rc=$rc $out"
  out=$(real "spl_db_roles_psql '$ODSN' runtime-grants.sql && echo again-ok"); grep -q again-ok <<<"$out" && pass "6. runtime-grants.sql is idempotent" || fail "6. re-grant: $out"
  docker exec -i "$PG_CTR" psql -q -v ON_ERROR_STOP=1 -U su -d spool -c "SET ROLE own; CREATE TABLE later (tenant_id text)" >/dev/null
  PGPASSWORD="$RPW" psql -X -q -At -h 127.0.0.1 -p "$PORT" -U rt -d spool -c "insert into later values ('t1') returning 1" 2>/dev/null | grep -x 1 >/dev/null \
    && pass "6. default privileges: a table the owner creates later is writable by the runtime login" || fail "6. default privileges"
  PGPASSWORD="$RPW" psql -X -q -At -h 127.0.0.1 -p "$PORT" -U rt -d spool -c "insert into spool_schema_migrations values ('x')" >/dev/null 2>&1 \
    && fail "6. the runtime login wrote the migration ledger" || pass "6. the runtime login cannot write spool_schema_migrations"
else
  echo "SKIP: 6. no cached $IMG image or no psql: real-Postgres leg not run"
fi

(( fails == 0 )) && echo "OK db-owner-split: all checks passed" || { echo "FAIL db-owner-split: $fails check(s)"; exit 1; }
