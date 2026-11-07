#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_channel_move_rehearsal_seed (spec 169 row T13), offline:
#   1. it refuses prd (seed and purge), a bad REHEARSAL_CMD and a bad
#      REHEARSAL_MSGS BEFORE gcloud or psql is called, by the check itself and not
#      by a later failure of a key
#   2. a dry run calls no cloud, seed or purge. CONTROL for 1: dev with valid knobs
#      is accepted
#   3. the seed SQL names only the two seed- workspaces, seats nobody, gives
#      <DST> another key than <SRC> (F10) and c-001 on its roster (W2)
#      every post's msg holds its body, as a real row's does
#   4. the purge SQL is exactly its text: the two seed-move- tenant rows, nothing else
#   5. the seed closes its host rows; the purge reads what it left and fails on a
#      remaining tenant or open host row
#   6. the blob rm names exactly the two t/seed-move-*/ paths; only "matched no
#      objects" passes as nothing to remove
#   7. the purge command runs the purge SQL, its read and the blob rm; a failure
#      of any step fails it and prints no OK
#   8. the seed command writes the blobs, then runs the seed SQL; a failure of
#      either fails it and prints no OK
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
for b in gcloud psql docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\n[ -z "$STUB_ERR" ] || echo "$STUB_ERR" >&2\nexit "${STUB_RC:-1}"\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. refusals before any cloud call ----------------------------------------
: >"$T/calls.log"
refused() { # <text the refusal must print> <env assignments...>
  local want=$1 out; shift
  out=$(SNIPPET='do_spl_channel_move_rehearsal_seed; echo rc=$?' in_orc "$@" 2>&1)
  grep -q "FATAL.*$want" <<<"$out" && grep -q 'rc=1' <<<"$out" && pass "$* refused" || fail "$* not refused: $out"
}
for dry in 0 1; do
  refused 'DEV only' ENV=prd DRY_RUN=$dry
  refused 'DEV only' ENV=prd REHEARSAL_CMD=purge DRY_RUN=$dry
done
refused 'DEV only' ENV= DRY_RUN=0
refused 'REHEARSAL_CMD must be' ENV=dev REHEARSAL_CMD=drop DRY_RUN=0
refused 'REHEARSAL_MSGS must be' ENV=dev REHEARSAL_MSGS=5 DRY_RUN=0
refused 'REHEARSAL_MSGS must be' ENV=dev 'REHEARSAL_MSGS=1;x' DRY_RUN=0
[[ ! -s "$T/calls.log" ]] && pass "no gcloud / psql call on a refusal" || fail "a refusal called out: $(cat "$T/calls.log")"

# --- 2. a dry run calls no cloud; CONTROL for the rc=1 above --------------------
out=$(SNIPPET='do_spl_channel_move_rehearsal_seed; echo rc=$?' in_orc ENV=dev DRY_RUN=1 2>&1)
grep -q 'rc=0' <<<"$out" && grep -q 'nothing written' <<<"$out" && pass "dry run writes nothing" || fail "dry run: $out"
out=$(SNIPPET='do_spl_channel_move_rehearsal_seed; echo rc=$?' in_orc ENV=dev REHEARSAL_CMD=purge DRY_RUN=1 2>&1)
grep -q 'rc=0' <<<"$out" && grep -q '^DELETE FROM tenants' <<<"$out" && grep -q 'nothing written (purge' <<<"$out" &&
  pass "purge dry run prints its SQL and writes nothing" || fail "purge dry run: $out"
[[ ! -s "$T/calls.log" ]] && pass "dry run calls no cloud" || fail "dry run called out: $(cat "$T/calls.log")"

# --- 3. the seed SQL --------------------------------------------------------------
sql=$(SNIPPET='spl_cmr_args && spl_cmr_seed_sql' in_orc ENV=dev 2>&1)
grep -q 'generate_series(0, 3650 - 1)' <<<"$sql" && pass "default is 3650 posts (F13)" || fail "post count: $sql"
ten=$(grep -oE "^ *\('[a-z0-9-]+'|VALUES \('[a-z0-9-]+'|SELECT '[a-z0-9-]+'|tenant_id = '[a-z0-9-]+'" <<<"$sql" | grep -oE "'[a-z0-9-]+'" | tr -d "'" | sort -u | tr '\n' ' ')
[[ "$ten" == "seed-move-dst seed-move-src " ]] && pass "only the two seed- workspaces" || fail "tenant literals: $ten"
for t in tenant_memberships channel_humans channel_subscriptions dedicated_agents; do
  ! grep -q "INSERT INTO $t" <<<"$sql" && pass "seats nobody: no $t" || fail "the seed writes $t"
done
grep -q "('seed-move-src', 'box-seed', decode(md5('seed-move-src-pin')" <<<"$sql" &&
  grep -q "('seed-move-dst', 'box-seed', decode(md5('seed-move-dst-pin')" <<<"$sql" &&
  pass "box-seed is pinned in both under different keys (F10)" || fail "pins: $sql"
grep -q "INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('seed-move-dst', 'box-seed', 'c-001')" <<<"$sql" &&
  pass "<DST> has its orchestrator seat" || fail "roster: $sql"
# messages.msg carries the body as a real row does, so P7's scan reads both columns
! grep -q "'{}'::jsonb" <<<"$sql" && pass "no post has an empty msg" || fail "an empty msg: $sql"
[[ $(grep -c "jsonb_build_object('body', " <<<"$sql") == 5 ]] && pass "every post's msg holds its body" || fail "msg bodies: $sql"
grep -q "'see /t/' || md5('seed-move-src-t-1')::uuid, '\[\]'::jsonb, jsonb_build_object('body', 'see /t/' || md5('seed-move-src-t-1')::uuid)" <<<"$sql" &&
  pass "the staying link is in body and msg" || fail "link msg: $sql"
# Every statement starts at column 0 and its other lines are indented: this is the
# list of the lines at column 0, so one added, dropped or moved there is red. It does
# not read an indented line, so a statement hidden in one stays green.
shape=$(grep -E '^[^ ]' <<<"$sql" | cut -d' ' -f1-3)
want_shape=$(cat <<'TXT'
SET statement_timeout =
SELECT set_config('app.rls_scope', 'operator',
BEGIN;
INSERT INTO tenants
UPDATE tenant_hosts SET
INSERT INTO boxes
INSERT INTO pins
INSERT INTO roster
INSERT INTO channels
INSERT INTO issue_counters
INSERT INTO messages
SELECT 'seed-move-src', md5('seed-move-src-m-'
INSERT INTO message_reactions
INSERT INTO message_revisions
INSERT INTO deliveries
INSERT INTO issues
INSERT INTO issue_discussions
INSERT INTO messages
COMMIT;
SELECT count(*) AS
TXT
)
[[ "$shape" == "$want_shape" ]] && pass "the seed's statements are its list" || fail "seed shape: $shape"
! grep -qiE '\b(truncate|drop|alter|delete)\b' <<<"$sql" && pass "the seed removes nothing" || fail "seed removes: $sql"

# --- 4. the purge SQL, whole: a line added or changed is red ------------------------
want=$(cat <<'SQL'
SET statement_timeout = 0;
SELECT set_config('app.rls_scope', 'operator', false);
BEGIN;
DELETE FROM tenants WHERE tenant_id IN ('seed-move-src', 'seed-move-dst') AND tenant_id LIKE 'seed-move-%';
UPDATE tenant_hosts SET status = 'removed', detail = 'throwaway rehearsal workspace, no host (spec 169 T13)', updated_at = now()
  WHERE tenant_id IN ('seed-move-src', 'seed-move-dst') AND status IN ('pending', 'failed', 'removing');
COMMIT;
SQL
)
sql=$(SNIPPET='spl_cmr_purge_sql' in_orc ENV=dev 2>/dev/null)
[[ "$sql" == "$want" ]] && pass "the purge SQL is exactly its text" || fail "purge SQL: $sql"

# --- 5. no open tenant_hosts row for the reconcile (wf 40) -------------------------
# <first> before <then> before COMMIT, in the SQL on stdin
in_order() {
  awk -v a="$1" -v b="$2" 'index($0, a) && !x { x = NR } index($0, b) && x && !y { y = NR } /^COMMIT;/ && y && !z { z = NR } END { exit !z }'
}
sql=$(SNIPPET='spl_cmr_args && spl_cmr_seed_sql' in_orc ENV=dev 2>&1)
in_order 'INSERT INTO tenants' 'UPDATE tenant_hosts' <<<"$sql" && pass "seed closes the host row after the insert, before COMMIT" || fail "seed host row: $sql"
grep -q "SET status = 'removed'" <<<"$sql" && grep -q "status IN ('pending', 'failed', 'removing')" <<<"$sql" &&
  pass "seed closes every open status as removed" || fail "seed statuses: $sql"

# the purge's read of what it left. The fake psql answers only the second call, the -At one.
after_read() { # <the after line> -> the output of _spl_cmr_psql_purge and its rc
  SNIPPET='SPL_PROXY_DSN=x; spl_pg_env() { cat >/dev/null; [[ "$*" == *-At* ]] && echo "$AFTER_LINE"; return 0; }; _spl_cmr_psql_purge; echo rc=$?' \
    in_orc ENV=dev "AFTER_LINE=$1" 2>&1
}
out=$(after_read 'after 0 0')
grep -q 'rc=0' <<<"$out" && pass "purge: nothing left passes" || fail "purge after 0 0: $out"
for line in 'after 1 0' 'after 0 1' ''; do
  out=$(after_read "$line")
  grep -q 'FATAL after the purge' <<<"$out" && grep -q 'rc=1' <<<"$out" && pass "purge: '$line' fails" || fail "purge '$line': $out"
done
want_after=$(cat <<'SQL'
SET app.rls_scope = 'operator';
SELECT 'after', (SELECT count(*) FROM tenants WHERE tenant_id IN ('seed-move-src', 'seed-move-dst')),
       (SELECT count(*) FROM tenant_hosts WHERE tenant_id IN ('seed-move-src', 'seed-move-dst') AND status <> 'removed');
SQL
)
sql=$(SNIPPET='spl_cmr_purge_after_sql' in_orc ENV=dev 2>&1)
[[ "$sql" == "$want_after" ]] && pass "the read of what is left is exactly its text" || fail "after SQL: $sql"

# --- 6. the blob rm ---------------------------------------------------------------
blobs_rm() { # <env assignments...>
  : >"$T/calls.log"
  SNIPPET='GCP_ACCOUNT=a; SPL_PROJECT=p; spl_cmr_blobs_rm bkt; echo rc=$?' in_orc ENV=dev "$@" 2>&1
}
out=$(blobs_rm STUB_RC=0)
urls=$(grep -oE 'gs://[^ ]*' "$T/calls.log" | tr '\n' ' ')
[[ "$urls" == "gs://bkt/t/seed-move-src/ gs://bkt/t/seed-move-dst/ " ]] && grep -q 'rc=0' <<<"$out" &&
  pass "blob rm names exactly the two seed paths" || fail "blob rm: $urls $out"
out=$(blobs_rm 'STUB_ERR=ERROR: The following URLs matched no objects or files:')
grep -q 'INFO no blobs left' <<<"$out" && grep -q 'rc=0' <<<"$out" && pass "matched no objects is no failure" || fail "no objects: $out"
out=$(blobs_rm 'STUB_ERR=ERROR: 403 does not have storage.objects.delete access')
grep -q 'FATAL the blobs' <<<"$out" && grep -q 'rc=1' <<<"$out" && pass "a permission failure fails" || fail "403: $out"

# --- 7. the purge command, live mode, on fakes: the DB step, then the blob step --------
# The fake spl_pg_env logs each script; PG_FAIL fails one call: the first script or the -At read.
live_action() { # <env assignments...> -> the action's output and its rc
  : >"$T/calls.log"; : >"$T/sql.log"
  SNIPPET='SPL_CNF=x GCP_ACCOUNT=a SPL_PROJECT=p SPL_PROXY_DSN=x
    do_spl_cloud_cnf() { :; }; do_gcp_pin_account() { :; }; do_gcp_require_live_account() { :; }; yq() { echo bkt; }
    spl_via_proxy() { "$@"; }
    spl_pg_env() {
      cat >>"$SQL_LOG"
      if [[ "$*" == *-At* ]]; then [[ "${PG_FAIL:-}" != after ]] || return 1; echo "$AFTER_LINE"; return 0; fi
      [[ "${PG_FAIL:-}" != delete ]]
    }
    do_spl_channel_move_rehearsal_seed; echo rc=$?' \
    in_orc ENV=dev DRY_RUN=0 SQL_LOG="$T/sql.log" "AFTER_LINE=after 0 0" STUB_RC=0 "$@" 2>&1
}
purge_action() { live_action REHEARSAL_CMD=purge "$@"; }
out=$(purge_action)
grep -q 'rc=0' <<<"$out" && grep -q 'OK removed' <<<"$out" && pass "purge action: all steps pass" || fail "purge action: $out"
[[ "$(cat "$T/sql.log")" == "$want"$'\n'"$want_after" ]] && pass "purge action: the DB step is the purge, then its read" || fail "purge action SQL: $(cat "$T/sql.log")"
urls=$(grep -E '^gcloud storage rm ' "$T/calls.log" | grep -oE 'gs://[^ ]*' | tr '\n' ' ')
[[ "$urls" == "gs://bkt/t/seed-move-src/ gs://bkt/t/seed-move-dst/ " ]] && pass "purge action: the blob step ran" || fail "purge action blobs: $(cat "$T/calls.log")"
for bad in PG_FAIL=delete PG_FAIL=after 'AFTER_LINE=after 1 0' 'STUB_RC=1'; do
  out=$(purge_action 'STUB_ERR=ERROR: 403 denied' "$bad")
  grep -q 'rc=1' <<<"$out" && ! grep -q 'OK removed' <<<"$out" && pass "purge action: '$bad' fails, no OK" || fail "purge action '$bad': $out"
done
purge_action PG_FAIL=delete >/dev/null
[[ ! -s "$T/calls.log" ]] && pass "purge action: no blob is touched after a failed DB step" || fail "blobs after a failed DB step: $(cat "$T/calls.log")"

# --- 8. the seed command, live mode, on the same fakes: the blobs, then the DB step ----
seed_action() { live_action REHEARSAL_CMD=seed "$@"; }
want_seed=$(SNIPPET='spl_cmr_args && spl_cmr_seed_sql' in_orc ENV=dev 2>/dev/null)
out=$(seed_action)
grep -q 'rc=0' <<<"$out" && grep -q 'OK seeded' <<<"$out" && pass "seed action: all steps pass" || fail "seed action: $out"
[[ "$(cat "$T/sql.log")" == "$want_seed" ]] && pass "seed action: the DB step is the seed, once" || fail "seed action SQL: $(cat "$T/sql.log")"
urls=$(grep -E '^gcloud storage cp ' "$T/calls.log" | grep -oE 'gs://bkt/t/seed-move-src/files/' | tr '\n' ' ')
[[ "$urls" == "gs://bkt/t/seed-move-src/files/ gs://bkt/t/seed-move-src/files/ " ]] && pass "seed action: both blobs are written to <SRC>" || fail "seed action blobs: $(cat "$T/calls.log")"
out=$(seed_action PG_FAIL=delete)
grep -q 'rc=1' <<<"$out" && ! grep -q 'OK seeded' <<<"$out" && pass "seed action: a failed DB step fails, no OK" || fail "seed action DB: $out"
out=$(seed_action STUB_RC=1)
grep -q 'FATAL a rehearsal blob' <<<"$out" && grep -q 'rc=1' <<<"$out" && ! grep -q 'OK seeded' <<<"$out" &&
  pass "seed action: a failed blob write fails, no OK" || fail "seed action blob write: $out"
[[ ! -s "$T/sql.log" ]] && pass "seed action: no SQL after a failed blob write" || fail "SQL after a failed blob write: $(cat "$T/sql.log")"

echo
((fails == 0)) && { echo "PASS: all spl-channel-move-rehearsal-seed.tst.sh assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
