#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_reflection_gather (spec 166 row B8) gathers the last 24 h at
# night and queues one refactor lane whose brief carries the gathered file.
#   1. a fixture repo with one revert in the window (and one before it), a
#      fake CI report with 2 reds in the window (and one before it), 2 owner
#      msg ids, one diss issue in the window: the gathered file lists the
#      revert, both reds and both msg ids, and none of the older ones
#   2. the enqueued brief carries Class: refactor, Kind, Epic: and Spec: lines
#      and the gathered file, and passes the existing enqueue gate (the real
#      do_spl_spawn_enqueue, li_brief_epic_spec on a fixture specs repo): the
#      queue op is called with refactor and claude:reflection-<night>; the
#      ask goes to the hub once; the night is stamped
#   3. nothing is written to git: the fixture repo's refs and status, and this
#      checkout's status, are the same before and after
#   4. red control: the same brief without its Spec: line is refused by the
#      existing gate (one FATAL line), no queue op, no stamp
#   5. by day nothing runs: no read, no gathered file, no stamp
#   6. a second tick the same night does nothing
#   7. DRY_RUN=1 (the default): the gathered file and the brief are printed,
#      no ask, no queue op
#   8. not the dispatch holder's box: nothing
#   9. a reader that fails is one "(not read" line; the lane is still queued
#  10. the lane mix gives no vendor fit for private data: nothing queued, rc 1,
#      no stamp
#  11. the cron row: manifest row reflection every 15 min after zombie-topics,
#      its script is executable, refuses a worktree, passes REFLECTION_DRY_RUN
#      from lease.conf
#  12. the brief names its discussion, the owner topic c0b0d572, on a
#      Discussion: line, so li_discussion_from_brief never picks a topic of
#      the gathered owner messages
#  13. the owner SQL on a real Postgres (rdb migrations, runtime login): an
#      owner with role admin and a biz_owner are listed; a tester, a developer,
#      an older post, another workspace are not. Red control: the old
#      role = 'owner' join lists nobody (SPL-5460)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
NIGHT_NOW=2026-01-15T19:30Z
NIGHT=2026-01-15
SLUG="reflection-$NIGHT"
TPL="$PROJ_ROOT/src/bash/features/dispatch/brief-reflection.tpl.md"

mkdir -p "$T/spool/dispatch" "$T/bin"
echo "c-002@box-a 1793464017" >"$T/spool/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"
printf '#!/bin/bash\necho "mix kind=$LANE_MIX_KIND sensitive=$LANE_MIX_SENSITIVE" >>"%s/mix.log"\necho "pick=${PICK:-claude}"\n' "$T" >"$T/bin/mix"
chmod +x "$T/bin/mix"

# The fixture repo: a bare origin, a clone with the spec folder and four
# commits, two of them reverts (one before the window, one in it).
R="$T/repo"
g() { git -C "$R" -c user.name='FirstName LastName' -c user.email=dev@example.com "$@"; }
at() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" g commit -q --allow-empty -m "$2"; }
git init -q --bare "$T/origin.git" && git init -q -b master "$R"
mkdir -p "$R/csi-spl-doc/specs/166-orchestrator-daily-rhythm"
echo "# Spec 166" >"$R/csi-spl-doc/specs/166-orchestrator-daily-rhythm/spec.md"
g add -A && GIT_AUTHOR_DATE=2026-01-13T10:00:00Z GIT_COMMITTER_DATE=2026-01-13T10:00:00Z g commit -q -m "feat: base"
at 2026-01-13T12:00:00Z 'Revert "feat(old): before the window"'
at 2026-01-15T08:00:00Z 'feat(x): a thing'
at 2026-01-15T09:00:00Z 'Revert "feat(x): a thing"'
g remote add origin "$T/origin.git" && g push -q origin master 2>/dev/null
OLD_REV="$(g rev-parse --short 'HEAD~2')"; NEW_REV="$(g rev-parse --short HEAD)"

cat >"$T/ci.txt" <<'EOF'
== 10_ci-quality.yml on master -- last 100 run(s), 2026-01-09T00:00:00Z .. 2026-01-15T18:00:00Z
== failed runs, newest first
   9001  2026-01-15T10:00:00Z  abc1234  wui-e2e  || FAIL: a shard
   9000  2026-01-15T09:00:00Z  abc1230  iac-suite
   8000  2026-01-10T09:00:00Z  abc0000  old-job
== first red per JOB, over the 3 failed run(s)
      1 wui-e2e
EOF
M1=11111111-0000-4000-8000-000000000001
M2=22222222-0000-4000-8000-000000000002
printf '%s\tt-aaaa\t2026-01-15T07:00:00Z\n%s\tt-bbbb\t2026-01-15T11:00:00Z\n' "$M1" "$M2" >"$T/owner.tsv"
cat >"$T/diss.json" <<'EOF'
{"op": "list", "result": {"issues": [
 {"key": "SPL-901", "title": "a lane dropped by its gate", "status": "diss", "canceled_at": "2026-01-15T12:00:00.5Z", "updated_at": "2026-01-15T12:00:01Z"},
 {"key": "SPL-800", "title": "an old one", "status": "diss", "canceled_at": "2026-01-10T12:00:00Z", "updated_at": "2026-01-10T12:00:00Z"}]}}
EOF
echo "2026-01-15T19:01:00Z OK zombie sweep, night of 2026-01-15 (DRY_RUN=1, cap 500, idle 7 d): 3 candidate(s); would archive 1" >"$T/zombie.log"

# The hub and the readers, replaced (SNIPPET of in_orc): calls land in
# $T/calls.log. The real do_spl_spawn_enqueue and its gate run.
STUBS='
spl_reflection_ci_report() { [[ "${CI_FAIL:-0}" == 1 ]] && { echo "gh: no token"; return 1; }; echo ci >>"$T/reads"; cat "$T/ci.txt"; }
spl_reflection_owner_msgs() { cat "$T/owner.tsv"; }
spl_reflection_ended_read() { cat "$T/diss.json"; }
spl_reflection_share_line() { echo "share of 4 known live lanes: refactor 1 25%; phase night"; }
spl_spawn_q_init() { LANE_FLEET=main ASKS_BOX=box-a; }
spl_asks_hub() { echo "hub $*" >>"$STUB_LOG"; }
spl_asks_discussion_ok() { :; }
spl_asks_by() { echo c-001@box-a; }
spl_asks_holder() { echo c-001@box-a; }
spl_spawn_place_dispatch() { echo c-002@box-a; }
spl_spawn_q_resolve() { echo "$ASK_ID"; }
spl_spawn_q_op() { echo "qop $*" >>"$STUB_LOG"; echo "{\"position\": 1, \"queue_len\": 1, \"summary\": \"x\"}"; }
spl_spawn_q_reply() { :; }
do_spl_reflection_gather'

# run NOW [VAR=value]...: the action, output in $T/out, rc in $rc.
run() {
  local now="$1"; shift
  SNIPPET="$STUBS" in_orc T="$T" RHYTHM_NOW="$now" SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a \
    REFLECTION_STATE="$T/stamp" REFLECTION_DIR="$T/spool/dispatch/reflection" SPAWN_PLACE_BRIEF_DIR="$T/briefs" \
    REFLECTION_REPO="$R" REFLECTION_ZOMBIE_LOG="$T/zombie.log" REFLECTION_MIX_CMD="$T/bin/mix" \
    LI_SPEC_REPO="$R" LI_SPEC_FETCH_TIMEOUT=5 ENV= TENANT_ID= DESK_AGENT= "$@" >"$T/out" 2>&1
  rc=$?
}
reset() { rm -rf "$T/stamp" "$T/reads" "$T/briefs" "$T/spool/dispatch/reflection"; : >"$T/calls.log"; }
snap() { { git -C "$R" for-each-ref --format='%(refname) %(objectname)'; git -C "$R" status --porcelain; git -C "$APP_ROOT" status --porcelain; } 2>&1; }
GF="$T/spool/dispatch/reflection/$NIGHT.md"

# --- 1-3. at night: the gathered file, the enqueue through the gate, no git write ---
reset; BEFORE="$(snap)"
run "$NIGHT_NOW" DRY_RUN=0
[[ $rc == 0 ]] && pass "1. at night the action runs (rc 0)" || fail "1. rc=$rc: $(cat "$T/out")"
grep -q "^- $NEW_REV .*Revert \"feat(x): a thing\"" "$GF" 2>/dev/null && ! grep -q "$OLD_REV" "$GF" &&
  pass "1. the gathered file lists the revert in the window, not the one before it" || fail "1. reverts: $(cat "$GF" 2>/dev/null)"
grep -q '^- run 9001  2026-01-15T10:00:00Z  abc1234  wui-e2e  || FAIL: a shard$' "$GF" && grep -q '^- run 9000 .* iac-suite$' "$GF" && ! grep -q old-job "$GF" &&
  pass "1. it lists both CI reds in the window, not the older one" || fail "1. reds: $(cat "$GF" 2>/dev/null)"
grep -q "^- msg $M1, topic t-aaaa" "$GF" && grep -q "^- msg $M2, topic t-bbbb" "$GF" &&
  pass "1. it lists the window's owner msg ids" || fail "1. owner ids: $(cat "$GF" 2>/dev/null)"
grep -q '^- SPL-901 ended diss 2026-01-15T12:00:00Z: a lane dropped by its gate$' "$GF" && ! grep -q SPL-800 "$GF" &&
  grep -q 'phase night' "$GF" && grep -q 'OK zombie sweep, night of 2026-01-15' "$GF" &&
  pass "1. it lists the diss lane in the window, the share line and the zombie summary" || fail "1. rest: $(cat "$GF" 2>/dev/null)"
B="$T/briefs/$SLUG.md"
grep -qx 'Class: refactor' "$B" 2>/dev/null && grep -qx 'Kind: specs_and_docs' "$B" && grep -qx 'Epic: SPL-2129' "$B" &&
  grep -qx 'Spec: csi-spl-doc/specs/166-orchestrator-daily-rhythm' "$B" && grep -q "msg $M1" "$B" && ! grep -q '{GATHER}\|{NIGHT}' "$B" &&
  pass "2. the brief carries Class: refactor, Kind, Epic: and Spec: lines and the gathered file" || fail "2. brief: $(cat "$B" 2>/dev/null)"
grep -q "^qop queue .* c-001@box-a  claude:$SLUG refactor" "$T/calls.log" &&
  pass "2. it passes the enqueue gate: the queue op takes refactor, claude:$SLUG" || fail "2. qop: $(cat "$T/calls.log") $(cat "$T/out")"
[[ "$(grep -c '^hub put .*--topic '"$SLUG" "$T/calls.log")" == 1 ]] && grep -qx 'mix kind=specs_and_docs sensitive=1' "$T/mix.log" &&
  pass "2. one ask put on the hub, topic $SLUG; the vendor asked as specs_and_docs on private data" || fail "2. hub: $(cat "$T/calls.log")"
# --- 12. the brief's discussion is its Discussion: line ---------------------------
LIB="$PROJ_ROOT/src/bash/features/spawn-agents/lib/lane-issue.inc.sh"
got="$(bash -c 'do_log() { :; }; . "$1"; li_discussion_from_brief "$2"' _ "$LIB" "$B" 2>/dev/null)"
[[ "$got" == c0b0d572-c575-4849-8792-4c3ce4d170f2 ]] && grep -qx 'Discussion: c0b0d572-c575-4849-8792-4c3ce4d170f2' "$B" &&
  pass "12. the brief's discussion is the owner topic c0b0d572 (its Discussion: line)" || fail "12. discussion: '$got'"
[[ "$(cat "$T/stamp" 2>/dev/null)" == "$NIGHT" ]] && pass "2. the night is stamped $NIGHT" || fail "2. stamp: $(cat "$T/stamp" 2>/dev/null)"
[[ "$(snap)" == "$BEFORE" ]] && pass "3. nothing is written to git (fixture refs and status, this checkout's status)" ||
  fail "3. git changed: $(diff <(echo "$BEFORE") <(snap))"

# --- 4. red control: the brief without its Spec: line is refused by the gate -------
reset; grep -v '^Spec:' "$TPL" >"$T/nospec.tpl.md"
run "$NIGHT_NOW" DRY_RUN=0 REFLECTION_TPL="$T/nospec.tpl.md"
[[ $rc != 0 ]] && ! grep -q '^qop' "$T/calls.log" && grep -q 'FATAL ask not queued: no issue without an epic and a git spec .*no spec folder named' "$T/out" &&
  [[ ! -e "$T/stamp" ]] && pass "4. red control: the same brief without Spec: is refused by the existing gate, no queue op, no stamp" ||
  fail "4. red: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 5. by day nothing runs ---------------------------------------------------------
reset; run 2026-01-15T12:00Z DRY_RUN=0
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$GF" && ! -e "$T/stamp" ]] && grep -q 'phase day: the reflection runs at night only' "$T/out" &&
  pass "5. by day: no read, no gathered file, no stamp" || fail "5. day: rc=$rc $(cat "$T/out")"

# --- 6. a second tick the same night ------------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0; rm -f "$T/reads"; : >"$T/calls.log"
run 2026-01-16T05:30Z DRY_RUN=0
[[ $rc == 0 && ! -e "$T/reads" ]] && ! grep -q '^qop' "$T/calls.log" && grep -q "already ran in the night of $NIGHT" "$T/out" &&
  pass "6. 06:30 CET the next morning is the same night: nothing" || fail "6. second tick: $(cat "$T/out")"

# --- 7. DRY_RUN=1 -------------------------------------------------------------------
reset; run "$NIGHT_NOW"
[[ $rc == 0 && -s "$GF" ]] && ! grep -q '^hub\|^qop' "$T/calls.log" && grep -q "PLAN reflection: would queue $SLUG" "$T/out" &&
  grep -qx 'Spec: csi-spl-doc/specs/166-orchestrator-daily-rhythm' "$T/out" && [[ ! -e "$T/briefs/$SLUG.md" ]] &&
  pass "7. DRY_RUN=1: the gathered file and the brief, no ask, no queue op" || fail "7. dry: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 8. not the holder's box --------------------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0 SPOOL_BOX_TAG=box-b
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$T/stamp" ]] && grep -q 'is not on this box (box-b)' "$T/out" &&
  pass "8. not the dispatch holder's box: nothing" || fail "8. box: $(cat "$T/out")"

# --- 9. a reader that fails ---------------------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0 CI_FAIL=1
grep -q '^(not read: do_report_ci_gate failed: gh: no token)$' "$GF" 2>/dev/null && grep -q '^qop queue' "$T/calls.log" &&
  pass "9. a failed CI read is one (not read line; the lane is still queued" || fail "9. not read: $(cat "$GF" 2>/dev/null) $(cat "$T/out")"

# --- 10. no vendor fit for private data ---------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0 PICK=agy
[[ $rc != 0 && ! -e "$T/stamp" ]] && ! grep -q '^qop\|^hub' "$T/calls.log" && grep -q 'no vendor for private data' "$T/out" &&
  pass "10. the mix picks agy for private data: not queued, rc $rc, no stamp" || fail "10. vendor: rc=$rc $(cat "$T/out")"

# --- 11. the cron row ---------------------------------------------------------------
MF="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
CRON="$PROJ_ROOT/src/bash/scripts/reflection-cron.sh"
grep -qE '^reflection +\| \*/15 \* \* \* \* +\| src/bash/scripts/reflection-cron.sh +\| reflection/cron.log' "$MF" &&
  [[ "$(grep -nE '^(zombie-topics|reflection) ' "$MF" | cut -d: -f2 | cut -d' ' -f1 | tr '\n' ' ')" == "zombie-topics reflection " ]] &&
  pass "11. manifest row reflection runs reflection-cron.sh every 15 min, after zombie-topics" || fail "11. no manifest row"
[[ -x "$CRON" ]] && pass "11. the cron script is executable" || fail "11. $CRON not executable"
mkdir -p "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts"; cp "$CRON" "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/"
bash "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/reflection-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 2 ]] && grep -q 'agent worktree' "$T/cout" && pass "11. the cron script refuses an agent worktree (rc 2)" || fail "11. worktree: rc=$rc $(cat "$T/cout")"
O="$T/orc/csi-spl-orc"; mkdir -p "$O/src/bash/scripts"; cp "$CRON" "$O/src/bash/scripts/"
printf '#!/bin/bash\necho "reflection: DRY_RUN=$DRY_RUN $*"\n' >"$O/run"; chmod +x "$O/run"
echo REFLECTION_DRY_RUN=0 >>"$T/spool/dispatch/lease.conf"
SPOOL_ROOT="$T/spool" bash "$O/src/bash/scripts/reflection-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q 'reflection: DRY_RUN=0 -a do_spl_reflection_gather' "$T/cout" &&
  pass "11. REFLECTION_DRY_RUN=0 in lease.conf runs the action with DRY_RUN=0" || fail "11. lease knob: rc=$rc $(cat "$T/cout")"
SPOOL_ROOT="$T/no-spool" bash "$O/src/bash/scripts/reflection-cron.sh" >"$T/cout" 2>&1
grep -q 'reflection: DRY_RUN=1 ' "$T/cout" && pass "11. no lease knob: DRY_RUN=1" || fail "11. default dry: $(cat "$T/cout")"


# --- 13. the owner SQL on a REAL Postgres: an admin owner listed, a tester not ------
# (SPL-5460: prd t1's owner holds role admin, not owner; the old role = 'owner'
# join listed nobody.) The real rdb migrations, the runtime login (RLS binds).
FUNC="$PROJ_ROOT/src/bash/run/spl-reflection-gather.func.sh"
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP 13: no cached $PG_IMAGE image or no psql; the owner SQL is not run"
else
  export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
  # shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
  source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
  spl_export_go_path || fail "13. no go toolchain"
  BIN="$T/spool-bin"
  (cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || fail "13. spool build"
  PG_CTR="spl-reflection-pg-$$"
  trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
  docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
    -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
  # shellcheck source=pg-throwaway.inc.sh
  source "$TEST_DIR/pg-throwaway.inc.sh"
  PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
  for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
  OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
  RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
  q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
  "$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || fail "13. migrate"
  q -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
  q -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || fail "13. grants"
  q -c "INSERT INTO humans (human_id) VALUES ('HUM-10'), ('HUM-5'), ('HUM-51'), ('HUM-46')" >/dev/null
  q -c "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab', 32), 'hex')), ('t2', decode(repeat('ac', 32), 'hex'))" >/dev/null
  q -c "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
     ('t1', 'HUM-10', 'admin', 'operator'), ('t1', 'HUM-5', 'biz_owner', 'operator'),
     ('t1', 'HUM-51', 'tester', 'operator'), ('t1', 'HUM-46', 'developer', 'operator'),
     ('t2', 'HUM-10', 'admin', 'operator')" >/dev/null || fail "13. seed memberships"
  # pm <tenant> <msg n> <from> <hours ago>
  pm() { q -c "INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
    VALUES ('$1', '20000000-0000-4000-8000-00000000000$2', '00000000-0000-4000-8000-00000000000$2', now(), 'box-wui', '$3', 'box-wui', 'c-001', 'note', 'b',
            '{}'::jsonb, 'sig', '\x00', now() - interval '$4 hours', now() + interval '60 days')" >/dev/null || fail "13. seed msg $2"; }
  pm t1 1 HUM-10 2    # listed: the owner, role admin
  pm t1 2 HUM-5 3     # listed: a biz_owner (tenant_owner)
  pm t1 3 HUM-51 1    # control: a tester
  pm t1 4 HUM-46 1    # control: a developer
  pm t1 5 HUM-10 30   # control: the owner, before the window
  pm t2 6 HUM-10 1    # control: the owner in another workspace
  now="$(date -u +%s)"
  got="$(env FUNC="$FUNC" PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" bash -c '
    set -uo pipefail; do_log() { :; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"; source "$FUNC"
    spl_reflection_owner_sql t1 "$1" "$2"' _ "$((now - 86400))" "$((now + 60))" 2>"$T/pgerr" | cut -f1 | sed 's/20000000-0000-4000-8000-00000000000//' | tr '
' ' ')"
  [[ "$got" == "2 1 " ]] &&
    pass "13. on Postgres as the runtime login: the owner with role admin and a biz_owner are listed; a tester, a developer, an older post and another workspace are not" ||
    fail "13. owner sql: got='$got' $(cat "$T/pgerr")"
  # red control: the pre-fix predicate (role = 'owner') lists nobody on the same rows.
  old="$(sed -n '/^spl_reflection_owner_sql()/,/^}/p' "$FUNC" | sed -n '/^SELECT/,/^ ORDER/p' |
    sed -e '/AND EXISTS/,/tenant_owner OR/d' -e "s|^  FROM messages m|  FROM messages m JOIN tenant_memberships tm ON tm.tenant_id = m.tenant_id AND tm.human_id = m.from_id AND tm.role = 'owner'|")"
  red="$(PGPASSWORD=rt psql -X -q -At "$RT_DSN" -v t=t1 -v since="$((now - 86400))" -v until="$((now + 60))" <<SQL 2>&1
BEGIN; SET LOCAL app.rls_scope = 'operator';
$old;
ROLLBACK;
SQL
)"
  grep -q "tm.role = 'owner'" <<<"$old" && [[ -z "$red" ]] &&
    pass "13. red control: the old role = 'owner' join lists nobody on the same rows" || fail "13. red control: '$red' sql: $old"
fi

echo "---"
[[ $fails == 0 ]] && echo "spl-reflection-gather: all passed" || echo "spl-reflection-gather: $fails FAILED"
exit $((fails > 0))
