#!/usr/bin/env bash
# do_spl_dispatch_subscribe's hub read (_spl_dispatch_subs_read) - its hum|
# line, the inbound guard's input (CLE-77876) - against a REAL throwaway
# Postgres with the real rdb migrations, as the non-owner runtime role so
# rdb 0014 row-level security binds to the tenant scope the read sets.
# Written after the first version alerted on posts stored BEFORE the
# workspace's box-wui pin (CLE-001, 2026-10-01): those are the replay's.
#   1. the read runs on the migrated schema and prints one hum| line
#   2. unsigned counts a post with no pin, a post after the pin and a post
#      under a revoked pin; NOT a post from before the live pin
#   3. posts: a signed one counts, an agent's, a DM, #issues, #probe, a
#      typed_by line and one outside the window do not
#   4. the roster rows: the OD seats and the role seats 001..003 under any
#      vendor letter (SPL-1756), no other agent
#   6. SPL-2423: a humans-only channel (rdb 0206) is one hon| line; the desk
#      reconcile's add (system=1) skips it and writes nothing, an add by hand
#      seats the agent and clears the mark
#   7. SPL-6523: a loop prompt (loop_id set, HUM-* to one seat) is no human
#      post: a window of loop prompts only is hum|0|0 and no SILENT; two
#      channel posts (an @mention reply to one seat included) with 0 desk
#      files still are SILENT
#   8. b47-02: a note to self (rdb 0278) and a signed post in a humans-only
#      channel (SPL-2423) never fan out: each alone is hum|0|0 and no
#      UNSIGNED or SILENT; next to two ordinary channel posts (SILENT's
#      floor, DISPATCH_SILENCE_MIN) it is hum|2|2 and still SILENT
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the SQL part is not run"
  exit 0
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-inbound-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$HERE/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

psql_owner <<'PSQL' >/dev/null || fail "seed tenants/channels/pins"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('wp', decode(repeat('ab', 32), 'hex')),
  ('wn', decode(repeat('ac', 32), 'hex')), ('wr', decode(repeat('ad', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('wp', 'ops', 'ops', 'HUM-1'),
  ('wn', 'ops', 'ops', 'HUM-1'), ('wr', 'ops', 'ops', 'HUM-1');
INSERT INTO pins (tenant_id, box_id, pubkey, updated_at) VALUES
  ('wp', 'box-wui', decode(repeat('01', 32), 'hex'), now() - interval '30 minutes'),
  ('wr', 'box-wui', decode(repeat('02', 32), 'hex'), now() - interval '90 minutes');
UPDATE pins SET revoked_at = now() - interval '80 minutes' WHERE tenant_id = 'wr';
INSERT INTO boxes (tenant_id, box_id) VALUES ('wp', 'box-desk'), ('wp', 'box-sat'), ('wn', 'box-desk');
INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('wp', 'box-desk', 'c-001'), ('wp', 'box-desk', 'c-002'),
  ('wp', 'box-sat', 'c-003'), ('wp', 'box-desk', 'c-077'), ('wn', 'box-desk', 'c-002'),
  ('wp', 'box-sat', 'g-002'), ('wp', 'box-sat', 'm-004');
PSQL
n=0
# m <tenant> <channel|''> <from> <sig|''> <minutes ago>
m() {
  n=$((n + 1))
  local ch="NULL" box=box-desk id; [[ -n "$2" ]] && ch="'$2'"
  [[ "$3" == HUM-* ]] && box='box-wui'
  id="$(printf '10000000-0000-4000-8000-%012d' "$n")"
  psql_owner -c "INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
    VALUES ('$1', '$id', '$id', $ch, now(), '$box', '$3', 'box-wui', 'ALL-0', 'note', 'x',
            '{}'::jsonb, '$4', '\\x00', now() - interval '$5 minutes', now() + interval '30 days')" >/dev/null ||
    fail "seed $*"
  LAST_ID="$id"
}
m wp ops HUM-2 '' 60           # before the pin: the replay's, not counted unsigned
m wp ops HUM-2 '' 45           # also before the pin
m wp ops HUM-2 '' 20           # after the pin and still unsigned: a live gap
m wp ops HUM-2 sig 10          # signed
m wp ops CLE-5 '' 10           # an agent
m wp '' HUM-2 '' 10            # a DM
m wp issues HUM-2 '' 10        # #issues
m wp probe HUM-2 '' 10         # #probe: the live proof, not counted (SPL-1648)
m wp ops HUM-2 '' 300          # outside the window
m wp ops HUM-2 '' 2            # inside the grace
m wp ops HUM-2 '' 15; psql_owner -c "UPDATE messages SET typed_by = 'HUM-2' WHERE msg_id = '$LAST_ID'" >/dev/null
m wn ops HUM-3 '' 60           # no pin at all
m wn ops HUM-3 '' 20
m wr ops HUM-4 '' 100          # before a pin that is now revoked
m wr ops HUM-4 '' 50

read_hum() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/sr" SPL_PROXY_DSN="$RT_DSN" W="$1" DISPATCH_ORCH=c-001 DISPATCH_MASTER=c-002 DISPATCH_FAILOVER=c-003 bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-subscribe.func.sh"
    _spl_dispatch_subs_read "$W"' 2>&1
}
out="$(read_hum wp)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '^hum|' <<<"$out")" == 1 ]] && pass "1. the read runs on the migrated schema as the runtime role, one hum| line" ||
  fail "1. rc=$rc $out"
[[ "$(grep '^hum|' <<<"$out")" == 'hum|4|1' ]] &&
  pass "2+3. pinned workspace: 4 human posts in the window, only the post-pin unsigned one counts" || fail "2. wp: $(grep '^hum|' <<<"$out")"
[[ "$(read_hum wn | grep '^hum|')" == 'hum|2|2' ]] && pass "2. no pin: every unsigned post counts" || fail "2. wn: $(read_hum wn | grep '^hum|')"
[[ "$(read_hum wr | grep '^hum|')" == 'hum|2|2' ]] && pass "2. a revoked pin covers nothing" || fail "2. wr: $(read_hum wr | grep '^hum|')"

# c-322 (prd t1 2026-10-05): the dispatch holder changed 12 min ago, so the
# posts before it were the previous holder's: only the signed post at 10 min
# counts (2 min is in the grace). The old read counted all four (hum|4|1).
mkdir -p "$T/sr/dispatch"; echo c-002@box-sat >"$T/sr/dispatch/fleet.dispatch.holder"
touch -d "@$(( $(date +%s) - 720 ))" "$T/sr/dispatch/fleet.dispatch.holder"
[[ "$(read_hum wp | grep '^hum|')" == 'hum|1|0' ]] &&
  pass "5. holder changed 12 min ago: only the posts since count" || fail "5. takeover: $(read_hum wp | grep '^hum|')"
rm -f "$T/sr/dispatch/fleet.dispatch.holder"

# owner 2026-10-03 (every OD seat in every channel): the read names the
# roster rows of the OD seats, on every box, and no other agent's; a role
# seat 001..003 under another vendor letter is another box's OD seat (SPL-1756)
[[ "$(grep '^ros|' <<<"$out" | tr '\n' ' ')" == 'ros|box-desk|c-001 ros|box-desk|c-002 ros|box-sat|c-003 ros|box-sat|g-002 ' ]] &&
  pass "4. the OD and role seats' roster rows, every box, no other agent, no other workspace" || fail "4. ros: $(grep '^ros|' <<<"$out")"

# SPL-2423 (owner HUM-10 2026-10-17): "once the users have removed all of the
# agents from the properties of a channel, no new agents should be added by
# the system".
psql_owner <<'PSQL' >/dev/null || fail "seed humans-only"
INSERT INTO channels (tenant_id, channel_id, name, created_by, humans_only_at) VALUES ('wp', 'quiet', 'quiet', 'HUM-1', now());
INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id, origin) VALUES ('wp', 'quiet', 'c-002', 'box-desk', 'removed');
PSQL
out="$(read_hum wp)"
[[ "$(grep '^hon|' <<<"$out" | tr '\n' ' ')" == 'hon|quiet ' ]] &&
  pass "6. a humans-only channel is one hon| line, an ordinary one none" || fail "6. hon: $(grep -E '^(hon|chan)\|' <<<"$out")"
add_op() {
  env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" GCP_ACCOUNT=test bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-channel-agent-add-op.func.sh"
    _spl_channel_agent_add_op_run wp quiet box-desk c-002 1 "$1"' _ "$1" 2>&1
}
seat() { psql_owner -c "SELECT origin FROM channel_subscriptions WHERE tenant_id = 'wp' AND channel_id = 'quiet' AND agent_id = 'c-002'"; }
mark() { psql_owner -c "SELECT humans_only_at IS NOT NULL FROM channels WHERE tenant_id = 'wp' AND channel_id = 'quiet'"; }
o="$(add_op 1)"; rc=$?
[[ $rc -eq 0 && "$o" == *"humans-only"* && "$(seat)" == removed && "$(mark)" == t ]] &&
  pass "6. the desk reconcile's add skips a humans-only channel: the seat stays removed" || fail "6. system add: rc=$rc $o seat=$(seat) mark=$(mark)"
o="$(add_op 0)"; rc=$?
[[ $rc -eq 0 && "$(seat)" == invite && "$(mark)" == f ]] &&
  pass "6. an add by hand seats the agent and clears the mark" || fail "6. hand add: rc=$rc $o seat=$(seat) mark=$(mark)"

# SPL-6523 (prd csitea 2026-11-25 16:30Z): after the people's last post, the
# window held only "Loop prompt" rows, stored from HUM-10 to one seat; only
# that seat's box gets them, so the desk's empty spool was right, not SILENT.
psql_owner <<'PSQL' >/dev/null || fail "seed loop tenants"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('wl', decode(repeat('ae', 32), 'hex')), ('wc', decode(repeat('af', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('wl', 'ops', 'ops', 'HUM-1'), ('wc', 'ops', 'ops', 'HUM-1');
PSQL
# lp <tenant> <seat> <minutes ago>: a loop prompt to <seat> (loopStorePrompt)
lp() {
  m "$1" ops HUM-10 '' "$3"
  psql_owner -c "UPDATE messages SET to_box = 'box-desk', to_id = '$2', loop_id = gen_random_uuid() WHERE msg_id = '$LAST_ID'" >/dev/null ||
    fail "seed loop prompt $*"
}
lp wl c-146 25; lp wl c-041 20; lp wl c-146 10
lp wc c-146 25; lp wc c-041 20
m wc ops HUM-10 '' 30
m wc ops HUM-10 '' 15; psql_owner -c "UPDATE messages SET to_box = 'box-desk', to_id = 'c-146' WHERE msg_id = '$LAST_ID'" >/dev/null
inbound() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/sr" W="$1" HUM="$2" DISPATCH_STATE_DIR="$T/state" DISPATCH_DESK_BOX=box-desk \
    DISPATCH_MASTER=c-002 DISPATCH_FAILOVER=c-003 bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-subscribe.func.sh"
    spl_test_workspace() { return 1; }; spl_dispatch_seated() { return 0; }
    spl_dispatch_inbound "$W" "$HUM"' 2>&1
}
h="$(read_hum wl | grep '^hum|')"
[[ "$h" == 'hum|0|0' ]] && pass "7. loop prompts to one seat only: no human post counted" || fail "7. wl: $h"
o="$(inbound wl "$h")"
[[ "$o" != *SILENT* ]] && pass "7. loop prompts only, 0 desk files: no SILENT" || fail "7. wl inbound: $o"
h="$(read_hum wc | grep '^hum|')"
[[ "$h" == 'hum|2|2' ]] && pass "7. two channel posts (one an @mention reply) count, the loop prompts do not" || fail "7. wc: $h"
o="$(inbound wc "$h")"
[[ "$o" == *"SILENT wc 2 human posts in 120 min, 0 inbound files"* ]] && pass "7. two channel posts, 0 desk files: still SILENT" ||
  fail "7. wc inbound: $o"

# b47-02 (a-683 R7 N1 + N2 on SPL-6523): a note to self is stored unsigned
# and reaches no box; a humans-only channel's post is signed (wui fanOut) but
# no agent is seated there. Neither reaches the desk, so neither may alert.
psql_owner <<'PSQL' >/dev/null || fail "seed b47-02 tenants"
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('xn', decode(repeat('b1', 32), 'hex')),
  ('xh', decode(repeat('b2', 32), 'hex')), ('xm', decode(repeat('b3', 32), 'hex'));
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES ('xn', 'ops', 'ops', 'HUM-1'), ('xm', 'ops', 'ops', 'HUM-1');
INSERT INTO channels (tenant_id, channel_id, name, created_by, humans_only_at) VALUES
  ('xh', 'quiet', 'quiet', 'HUM-1', now()), ('xm', 'quiet', 'quiet', 'HUM-1', now());
PSQL
# nts <tenant> <minutes ago>: a note to self in #ops (unsigned, no fan-out)
nts() {
  m "$1" ops HUM-10 '' "$2"
  psql_owner -c "UPDATE messages SET note_to_self = true WHERE msg_id = '$LAST_ID'" >/dev/null || fail "seed note to self $*"
}
nts xn 25; nts xn 15
m xh quiet HUM-10 sig 25; m xh quiet HUM-10 sig 15
nts xm 25; m xm quiet HUM-10 sig 20; m xm ops HUM-10 '' 15; m xm ops HUM-10 '' 10
h="$(read_hum xn | grep '^hum|')"
[[ "$h" == 'hum|0|0' ]] && pass "8a. notes to self only: no human post counted" || fail "8a. xn: $h"
o="$(inbound xn "$h")"
[[ "$o" != *SILENT* && "$o" != *UNSIGNED* ]] && pass "8a. notes to self only, 0 desk files: no UNSIGNED, no SILENT" || fail "8a. xn inbound: $o"
h="$(read_hum xh | grep '^hum|')"
[[ "$h" == 'hum|0|0' ]] && pass "8b. signed posts in a humans-only channel only: no human post counted" || fail "8b. xh: $h"
o="$(inbound xh "$h")"
[[ "$o" != *SILENT* && "$o" != *UNSIGNED* ]] && pass "8b. humans-only posts only, 0 desk files: no SILENT" || fail "8b. xh inbound: $o"
h="$(read_hum xm | grep '^hum|')"
[[ "$h" == 'hum|2|2' ]] && pass "8c. two ordinary channel posts count, the note to self and the humans-only post do not" || fail "8c. xm: $h"
o="$(inbound xm "$h")"
[[ "$o" == *"SILENT xm 2 human posts in 120 min, 0 inbound files"* ]] && pass "8c. two ordinary channel posts, 0 desk files: still SILENT" ||
  fail "8c. xm inbound: $o"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
