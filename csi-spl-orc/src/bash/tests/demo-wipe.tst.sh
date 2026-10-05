#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_demo_wipe (spec 077 T017), the nightly wipe of the demo
#          workspace. Part A stubs the cloud (spl_via_proxy records its call);
#          part B runs the SQL against a REAL throwaway Postgres with the real
#          rdb migrations, as a NON-owner login so rdb 0014 row-level security
#          binds (SKIP when no docker / psql / cached postgres image).
#   A1. ENV must be dev or prd
#   A2. CONTROL guard 1: DEMO_WIPE_WORKSPACE naming a workspace that is not
#       cnf env.demo.workspace is refused before any DB call
#   A3. env.demo.enabled not true: skipped, exit 0, no DB call
#   A4. DRY_RUN defaults to 1 (the count path); DRY_RUN=0 is the delete path
#   A5. the pinned-welcome hook: says T019 is missing, runs it once it exists
#   A6. the seeded channels equal the hub's store.DefaultChannels
#   B1. dry run: exact counts, nothing deleted
#   B2. the wipe deletes the demo workspace's messages (and their topics,
#       deliveries, reactions), read marks and topic watches, re-seeds a
#       missing default channel, keeps an admin's channel
#   B3. CONTROL: the other workspace's rows are untouched
#   B4. CONTROL guard 2: the SQL itself refuses a workspace with a member
#       whose role is not demo_user / admin / biz_owner, and deletes nothing
#   B5. a missing workspace is refused; a second wipe is a no-op
#   B6. the ban list (rdb 0130 demo_bans, T016 part B) survives the wipe: a
#       banned visitor stays banned after the night
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-demo-wipe.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# A ---------------------------------------------------------------------------
# runa <enabled> [VAR=val ...]: the action with the cloud stubbed
runa() {
  local on="$1"; shift
  : >"$T/calls"
  printf 'env:\n  demo:\n    enabled: %s\n    workspace: demo\n' "$on" >"$T/cnf.yaml"
  env -u DRY_RUN -u DEMO_WIPE_WORKSPACE FUNC="$FUNC" T="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_via_proxy() { echo "proxy $DEMO_WS dry=$DEMO_DRY $*" >>"$T/calls"; echo "\"messages\":0" >"$2"; }
    [[ -n "${GREET:-}" ]] && do_spl_demo_greeting_seed() { echo "greet $DEMO_WS" >>"$T/calls"; }
    do_spl_demo_wipe' >"$T/o" 2>"$T/e"
}

runa true ENV=lde; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. ENV=lde refused before any DB call" || fail "A1. rc=$rc $(cat "$T/calls")"

runa true ENV=dev DRY_RUN=0 DEMO_WIPE_WORKSPACE=t1; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 't1 is not the demo workspace' "$T/e" &&
  pass "A2. CONTROL: DEMO_WIPE_WORKSPACE=t1 is refused, no DB call" || fail "A2. rc=$rc $(cat "$T/calls" "$T/e")"
runa true ENV=dev DRY_RUN=0 DEMO_WIPE_WORKSPACE=demo; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy demo dry=0 _spl_demo_wipe_run' "$T/calls" &&
  pass "A2. DEMO_WIPE_WORKSPACE equal to the cnf id runs" || fail "A2. same id rc=$rc $(cat "$T/calls" "$T/e")"

runa false ENV=prd DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q '"skipped":"demo_disabled"' "$T/o" &&
  pass "A3. demo off: skipped, exit 0, no DB call" || fail "A3. rc=$rc $(cat "$T/calls" "$T/o")"

runa true ENV=dev; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy demo dry=1 ' "$T/calls" && grep -q '"dry_run":true,"messages":0' "$T/o" &&
  ! grep -q '^greet' "$T/calls" &&
  pass "A4. DRY_RUN defaults to 1: the count path, no welcome" || fail "A4. rc=$rc $(cat "$T/calls" "$T/o")"

runa true ENV=dev DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '"dry_run":false' "$T/o" && grep -q 'do_spl_demo_greeting_seed (077 T019) is not built yet' "$T/e" &&
  pass "A5. no greeting seed yet: the wipe says so" || fail "A5. rc=$rc $(cat "$T/o" "$T/e")"
runa true ENV=dev DRY_RUN=0 GREET=1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'greet demo' "$T/calls" &&
  pass "A5. once T019 lands, the wipe runs do_spl_demo_greeting_seed for the demo id" || fail "A5. hook rc=$rc $(cat "$T/calls")"

go_def="$(sed -n 's/^var DefaultChannels = \[\]string{\(.*\)}$/\1/p' "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/store/channels.go")"
want=""
for c in ${go_def//,/ }; do
  v="$(sed -n "s/^[[:space:]]*${c}[[:space:]]*= \"\(.*\)\"$/\1/p" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/store/channels.go")"
  want+="${want:+,}$v"
done
have="$(sed -n "s/^SPL_DEMO_WIPE_CHANNELS='{\(.*\)}'$/\1/p" "$FUNC")"
[[ -n "$want" && "$have" == "$want" ]] && pass "A6. seeded channels {$have} = store.DefaultChannels" ||
  fail "A6. seeded channels '{$have}' != store.DefaultChannels '{$want}'"

# B ---------------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: part B, no docker / psql / cached $PG_IMAGE image"
  (( fails == 0 )) && { echo "ALL PASS"; exit 0; }; echo "$fails FAILED"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-demo-wipe-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

# demo (an admin, a visitor) and t1 (a developer): two topics + a DM each
q "INSERT INTO humans (human_id) VALUES ('HUM-1'), ('HUM-2'), ('HUM-3')" >/dev/null
for t in demo t1; do
  q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null
  q "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, expires_at)
     SELECT '$t', gen_random_uuid(), ('00000000-0000-4000-8000-00000000000' || (i % 2 + 1))::uuid, 'lobby', now(),
            'box-wui', 'HUM-2', 'box-demo', 'c-001', 'note', 'm' || i, '{}'::jsonb, 'sig', '\\x00'::bytea, now() + interval '1 day'
       FROM generate_series(1, 4) AS i
     UNION ALL
     SELECT '$t', gen_random_uuid(), '00000000-0000-4000-8000-000000000009', NULL, now(),
            'box-wui', 'HUM-2', 'box-demo', 'c-001', 'note', 'dm', '{}'::jsonb, 'sig', '\\x00'::bytea, now() + interval '1 day'" >/dev/null
  q "INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at) SELECT tenant_id, msg_id, 'box-demo', now() + interval '1 day' FROM messages WHERE tenant_id = '$t'" >/dev/null
  q "INSERT INTO read_marks (tenant_id, member_id, mark_key, at) VALUES ('$t', 'HUM-2', 'ch:lobby', now()), ('$t', 'HUM-2', 't:00000000-0000-4000-8000-000000000001', now())" >/dev/null
  q "INSERT INTO flow_watches (tenant_id, task_id, member_id, since) VALUES ('$t', '00000000-0000-4000-8000-000000000001', 'HUM-2', now())" >/dev/null
  q "INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('$t', 'try-an-agent', 'try-an-agent', 'HUM-1')" >/dev/null
done
q "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
     ('demo', 'HUM-1', 'admin', 'operator'), ('demo', 'HUM-2', 'demo_user', 'operator'),
     ('t1', 'HUM-1', 'biz_owner', 'operator'), ('t1', 'HUM-3', 'developer', 'HUM-1')" >/dev/null
q "DELETE FROM channels WHERE tenant_id = 'demo' AND channel_id = 'feedback'" >/dev/null
q "INSERT INTO demo_bans (tenant_id, key, banned_by) VALUES ('demo', 'acct:' || repeat('a', 64), 'HUM-1'), ('demo', 'mail:' || repeat('b', 64), 'HUM-1')" >/dev/null
bans() { q "SELECT count(*) FROM demo_bans WHERE tenant_id = 'demo'"; }

# runb <ws> <dry>: the SQL path of the action, through the real DB as the runtime login
runb() {
  env FUNC="$FUNC" DEMO_WS="$1" DEMO_DRY="$2" SPL_PROXY_DSN="$RT_DSN" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$FUNC"
    _spl_demo_wipe_run /dev/stdout' >"$T/o" 2>&1
}
counts() { q "SELECT (SELECT count(*) FROM messages WHERE tenant_id = '$1') || ' ' || (SELECT count(*) FROM deliveries WHERE tenant_id = '$1') || ' ' || (SELECT count(*) FROM read_marks WHERE tenant_id = '$1') || ' ' || (SELECT count(*) FROM flow_watches WHERE tenant_id = '$1')"; }

runb demo 1; rc=$?
[[ $rc -eq 0 ]] && grep -qx '"messages":5,"topics":3,"read_marks":2,"flow_watches":1,"channels_reseeded":1' "$T/o" &&
  [[ "$(counts demo)" == "5 5 2 1" ]] &&
  pass "B1. dry run: 5 messages, 3 topics, 2 read marks, 1 watch, 1 channel to re-seed; nothing deleted" ||
  fail "B1. rc=$rc $(cat "$T/o") counts=$(counts demo)"

runb demo 0; rc=$?
[[ $rc -eq 0 ]] && grep -qx '"messages":5,"topics":3,"read_marks":2,"flow_watches":1,"channels_reseeded":1' "$T/o" &&
  [[ "$(counts demo)" == "0 0 0 0" ]] &&
  pass "B2. the wipe deleted the demo messages, topics, deliveries, read marks and watches" ||
  fail "B2. rc=$rc $(cat "$T/o") counts=$(counts demo)"
[[ "$(q "SELECT string_agg(channel_id, ',' ORDER BY channel_id) FROM channels WHERE tenant_id = 'demo'")" == "alerts,feedback,lobby,try-an-agent" ]] &&
  pass "B2. the default channels are re-seeded, the admin's channel is kept" ||
  fail "B2. channels: $(q "SELECT string_agg(channel_id, ',' ORDER BY channel_id) FROM channels WHERE tenant_id = 'demo'")"

[[ "$(counts t1)" == "5 5 2 1" ]] && pass "B3. CONTROL: t1's rows are untouched" || fail "B3. t1 counts=$(counts t1)"

runb t1 0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'has members with role(s) developer: not a demo workspace, refused' "$T/o" &&
  [[ "$(counts t1)" == "5 5 2 1" ]] &&
  pass "B4. CONTROL: the SQL refuses t1 (a developer member) and deletes nothing" ||
  fail "B4. rc=$rc $(cat "$T/o") t1 counts=$(counts t1)"

runb nope 0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'workspace nope does not exist' "$T/o" && pass "B5. a missing workspace is refused" || fail "B5. rc=$rc $(cat "$T/o")"
runb demo 0; rc=$?
[[ $rc -eq 0 ]] && grep -qx '"messages":0,"topics":0,"read_marks":0,"flow_watches":0,"channels_reseeded":0' "$T/o" &&
  pass "B5. a second wipe is a no-op" || fail "B5. rerun rc=$rc $(cat "$T/o")"
[[ "$(bans)" == "2" ]] && pass "B6. the ban list survives two wipes (2 rows)" || fail "B6. demo_bans rows after the wipes: $(bans)"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
