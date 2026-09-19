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
# wui-live-ws.md §1; same value as cnf env.hub.env.SPOOL_HUB_LOBBY_TASK_ID.
LOBBY="00000000-0000-4000-8000-000000000001"
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
  SPOOL_HUB_LOG_FORMAT=json SPOOL_HUB_ENV=lde \
  SPOOL_HUB_VIEW_DOOR=off SPOOL_HUB_LOBBY_TASK_ID="$LOBBY" \
  "$BIN" serve >>"$WORK/hub.log" 2>&1 &
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

# Door-off viewer reads (003 T036 door-off; Host = tenant, no Authorization).
view_get() {
  curl -fsS "http://$TENANT.localhost:$PORT$1" || fail "GET $1"
}

# Browser live socket: hello then subscribe LOBBY (wui-live-ws.md §3). Stdlib only.
wui_hello_subscribe() {
  python3 - "$TENANT.localhost" "$PORT" "$LOBBY" <<'PY' || fail "/v1/wui/ws hello+subscribe LOBBY"
import base64, hashlib, json, os, socket, struct, sys, time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
host, port, lobby = sys.argv[1], int(sys.argv[2]), sys.argv[3]


def die(msg):
    print("FAIL -", msg, file=sys.stderr)
    sys.exit(1)


def mask_frame(payload, opcode=1):
    mask = os.urandom(4)
    data = bytearray(payload)
    for i, b in enumerate(data):
        data[i] = b ^ mask[i % 4]
    n = len(payload)
    if n < 126:
        hdr = bytes([0x80 | opcode, 0x80 | n])
    elif n < 65536:
        hdr = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack("!H", n)
    else:
        hdr = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack("!Q", n)
    return hdr + mask + bytes(data)


class WS:
    def __init__(self, sock, leftover=b""):
        self.s = sock
        self.buf = leftover
        self.s.settimeout(8)

    def _recv(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(4096)
            if not chunk:
                die("websocket eof")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read(self):
        while True:
            b0 = self._recv(1)[0]
            b1 = self._recv(1)[0]
            opcode, ln = b0 & 0x0F, b1 & 0x7F
            if ln == 126:
                ln = struct.unpack("!H", self._recv(2))[0]
            elif ln == 127:
                ln = struct.unpack("!Q", self._recv(8))[0]
            if b1 & 0x80:
                mask = self._recv(4)
                payload = bytearray(self._recv(ln))
                for i in range(ln):
                    payload[i] ^= mask[i % 4]
                payload = bytes(payload)
            else:
                payload = self._recv(ln)
            if opcode == 8:
                die("close %r" % payload)
            if opcode == 9:
                self.s.sendall(mask_frame(payload, 10))
                continue
            if opcode == 1:
                return json.loads(payload.decode())

    def send(self, obj):
        self.s.sendall(mask_frame(json.dumps(obj).encode()))

    def wait(self, typ):
        deadline = time.time() + 8
        while time.time() < deadline:
            f = self.read()
            if f.get("type") == typ:
                return f
            if f.get("type") == "error":
                die("waiting for %s: %s" % (typ, f))
        die("timeout waiting for %s" % typ)


key = base64.b64encode(os.urandom(16)).decode()
req = (
    "GET /v1/wui/ws HTTP/1.1\r\n"
    "Host: %s:%s\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Key: %s\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    "\r\n" % (host, port, key)
)
s = socket.create_connection((host, port), timeout=8)
s.sendall(req.encode())
buf = b""
while b"\r\n\r\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        die("no websocket upgrade response")
    buf += chunk
head, rest = buf.split(b"\r\n\r\n", 1)
status = head.split(b"\r\n", 1)[0].decode()
if b" 101 " not in head.split(b"\r\n", 1)[0] and not head.startswith(b"HTTP/1.1 101"):
    die("upgrade %s" % status)
want = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
if not any(l.lower().startswith(b"sec-websocket-accept:") and want.encode() in l for l in head.split(b"\r\n")):
    die("bad Sec-WebSocket-Accept")
ws = WS(s, rest)
ws.send({"type": "hello", "as": "HUM-1"})
w = ws.wait("welcome")
if w.get("as") != "HUM-1" or w.get("lobby_task_id") != lobby or not w.get("upload_token"):
    die("welcome %s" % w)
ws.send({"type": "subscribe", "task_id": "LOBBY"})
sub = ws.wait("subscribed")
if sub.get("task_id") != lobby:
    die("subscribed %s" % sub)
print("ok %s %s" % (w["as"], sub["task_id"]))
PY
}

# 1. owner: tenant root key + tenant row
ROOT_PUB="$("$BIN" root-keygen --out "$WORK/root.key")"
SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-tenant --tenant "$TENANT" --root-pubkey "$ROOT_PUB" >/dev/null
ok "owner created tenant $TENANT"
start_hub
ok "spool serve up; /healthz 200"

# 2. two boxes, root-pinned at the hub via spool-pin --root-key (004 T005)
for b in box-a box-b; do
  pub="$(on "$b" keygen)"
  on "$b" pin --box "$b" --pubkey "$pub" --root-key "$WORK/root.key" >/dev/null
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

# 9. door-off view API + /v1/wui/ws (003 T036 door-off variant; token door waits on T033/B1)
command -v python3 >/dev/null || fail "python3 required for /v1/wui/ws e2e"
threads="$(view_get /v1/view/threads)"
echo "$threads" | grep -q "$task" || fail "view threads missing $task: $threads"
one="$(view_get "/v1/view/threads/$task")"
echo "$one" | grep -q '"task_id"' || fail "view one thread: $one"
echo "$one" | grep -q "build it" || fail "view one thread missing body: $one"
children="$(view_get "/v1/view/threads/$task/children")"
echo "$children" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d.get("threads"), list), d' \
  || fail "view children: $children"
roster="$(view_get /v1/view/roster)"
echo "$roster" | python3 -c 'import json,sys; ids={b["box_id"] for b in json.load(sys.stdin)["boxes"]}; assert ids>={"box-a","box-b"}, ids' \
  || fail "view roster: $roster"
channels="$(view_get /v1/view/channels)"
echo "$channels" | python3 -c 'import json,sys; s={c["channel"] for c in json.load(sys.stdin)["channels"]}; assert s>={"lobby","tasks","alerts"}, s' \
  || fail "view channels: $channels"
ok "door-off GET /v1/view/{threads,threads/{id},children,roster,channels}"
wsout="$(wui_hello_subscribe)"
echo "$wsout" | grep -q "ok HUM-1 $LOBBY" || fail "wui ws: $wsout"
ok "door-off /v1/wui/ws hello + subscribe LOBBY"

echo "ALL HUB E2E CHECKS PASSED"
