#!/usr/bin/env bash
# Hub end-to-end (spec 003, the M1 demo shape) with the real binary against a
# migrated Postgres: owner creates a tenant, two boxes are root-pinned, a task
# crosses boxes (queued, then sent to a live hub-run daemon), a result comes
# back, and a send made while the hub is down is pending and then flushed.
# Usage: bash hub-e2e.tst.sh <spool-binary> <postgres-dsn>   (hub-pg.tst.sh calls it)
set -euo pipefail

BIN="$1"
DSN="$2"
WORK="$(mktemp -d)"
PORT="$(( 20000 + RANDOM % 20000 ))"
TENANT="t-e2e"
HUB_PID=""
RUN_PID=""
cleanup() {
  [ -n "$RUN_PID" ] && kill "$RUN_PID" 2>/dev/null || true
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL - $*"; [ -f "$WORK/hub.log" ] && tail -20 "$WORK/hub.log"; exit 1; }
ok() { echo "ok   - $*"; }

start_hub() {
  SPOOL_HUB_DB_DSN="$DSN" SPOOL_HUB_FILES_DIR="$WORK/blobs" \
  SPOOL_HUB_TENANT_HOST_PATTERN="{tenant}.localhost" SPOOL_HUB_LISTEN_ADDR="127.0.0.1:$PORT" \
  SPOOL_HUB_LOG_FORMAT=json SPOOL_HUB_ENV=lde "$BIN" serve >>"$WORK/hub.log" 2>&1 &
  HUB_PID=$!
  for _ in $(seq 1 100); do
    curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "hub did not come up"
}
stop_hub() { kill "$HUB_PID"; wait "$HUB_PID" 2>/dev/null || true; HUB_PID=""; }

# box <name>: env for one box (own spool root and keys)
box() {
  echo "SPOOL_ROOT=$WORK/$1/spool SPOOL_KEYS_DIR=$WORK/$1/keys SPOOL_BOX_ID=$1 SPOOL_HUB_URL=http://$TENANT.localhost:$PORT"
}
on() { local b="$1"; shift; env $(box "$b") "$BIN" "$@"; }

# 1. owner: tenant root key + tenant row
ROOT_PUB="$("$BIN" root-keygen --out "$WORK/root.key")"
SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-tenant --tenant "$TENANT" --root-pubkey "$ROOT_PUB" >/dev/null
ok "owner created tenant $TENANT"
start_hub
ok "spool serve up; /healthz 200"

# 2. two boxes, root-pinned at the hub
for b in box-a box-b; do
  pub="$(on "$b" keygen)"
  on "$b" hub-pin --box "$b" --pubkey "$pub" --root-key "$WORK/root.key" >/dev/null
done
mkdir -p "$WORK/box-a/spool/GRK-03" "$WORK/box-b/spool/CLE-07"
on box-b hub-sync >/dev/null
on box-a hub-sync >/dev/null
ok "box-a and box-b pinned by the tenant root; hello accepted (hub-sync exit 0)"

# 3. an unpinned box is refused at hello (exit 78)
on box-x keygen >/dev/null
set +e; on box-x hub-sync >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 78 ] || fail "unpinned hello exit $rc, want 78"
ok "unpinned box refused at hello (exit 78)"

# 4. receiver offline -> queued; drained by hub-sync
out="$(on box-a send --from GRK-03 --to CLE-07 --kind task --body "build it")"
echo "$out" | grep -q '"delivery":"queued"' || fail "offline send: $out"
task="$(echo "$out" | sed 's/.*"task_id":"\([^"]*\)".*/\1/')"
on box-b hub-sync | grep -q '"delivered":1' || fail "box-b drain"
on box-b recv --as CLE-07 --ack | grep -q '"body":"build it"' || fail "box-b recv"
ok "offline receiver: delivery=queued, drained on hello, recv returns the task"

# 5. live daemon -> sent
env $(box box-b) "$BIN" hub-run >>"$WORK/run-b.log" 2>&1 &
RUN_PID=$!
sleep 1
out="$(on box-a send --from GRK-03 --to CLE-07 --task "$task" --kind note --body "live")"
echo "$out" | grep -q '"delivery":"sent"' || fail "live send: $out"
for _ in $(seq 1 50); do
  on box-b recv --as CLE-07 | grep -q '"body":"live"' && break
  sleep 0.1
done
on box-b recv --as CLE-07 | grep -q '"body":"live"' || fail "hub-run did not write the live frame"
ok "live receiver (hub-run): delivery=sent, written to the inbox"

# 6. result back to box-a
out="$(on box-b send --from CLE-07 --to GRK-03 --task "$task" --kind result --body "done")"
echo "$out" | grep -q '"delivery":"queued"' || fail "result send: $out"
on box-a hub-sync >/dev/null
on box-a recv --as GRK-03 | grep -q '"kind":"result"' || fail "result not received"
ok "kind=result crossed back (queued -> hub-sync)"

# 7. hub down -> pending (exit 0); hub back -> flush; the daemon reconnects and receives
stop_hub
out="$(on box-a send --from GRK-03 --to CLE-07 --task "$task" --kind note --body "while down")"
echo "$out" | grep -q '"delivery":"pending"' || fail "hub-down send: $out"
on box-a send --from GRK-03 --to GRK-03 --kind note --body "self" | grep -q '"delivery":"local"' || fail "same-box with hub down"
ok "hub down: cross-box delivery=pending (exit 0), same-box still local"
start_hub
on box-a hub-sync | grep -q '"flushed":1' || fail "flush"
for _ in $(seq 1 150); do
  on box-b recv --as CLE-07 | grep -q '"body":"while down"' && break
  sleep 0.2
done
on box-b recv --as CLE-07 | grep -q '"body":"while down"' || fail "daemon did not reconnect and receive the flushed message"
ok "hub back: flush sent the pending envelope; hub-run reconnected and received it"

# 8. the thread from the hub
n="$(on box-a hub-tail --task "$task" --json | wc -l)"
[ "$n" = 4 ] || fail "hub-tail has $n messages, want 4"
ok "hub-tail returns the 4-message thread (task, live, result, flushed)"

echo "ALL HUB E2E CHECKS PASSED"
