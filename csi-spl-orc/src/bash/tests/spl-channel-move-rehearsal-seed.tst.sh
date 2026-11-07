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
sql=$(SNIPPET='spl_cmr_purge_after_sql' in_orc ENV=dev 2>&1)
grep -q "tenant_hosts WHERE tenant_id IN ('seed-move-src', 'seed-move-dst') AND status <> 'removed'" <<<"$sql" &&
  pass "the read counts the host rows too" || fail "after SQL: $sql"

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

echo
((fails == 0)) && { echo "PASS: all spl-channel-move-rehearsal-seed.tst.sh assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
