#!/usr/bin/env bash
# End-to-end smoke for the on-box spool (spec 002), mirroring the ysg-box
# agent-msg flow in LOCAL mode (contracts/trust-modes.md): unsigned send (with a
# blob + a path ref) -> recv --ack -> get-file, with NO key and NO pin; then the
# optional per-box key ceremony, a hash-mismatch refusal (exit 78), the legacy
# .md bridge, and `spool mcp` over stdio. Self-contained: builds the binary and
# uses throwaway temp dirs.
#
# Usage: bash csi-spl-api/src/bash/tests/spool-smoke.tst.sh
set -euo pipefail

export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../use-go-toolchain.sh
source "$HERE/../use-go-toolchain.sh"
spl_export_go_path
MOD="$HERE/../../go/spool-hub-api"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export SPOOL_ROOT="$WORK/msgs"
export SPOOL_KEYS_DIR="$WORK/keys"
export SPOOL_PINS_DIR="$SPOOL_ROOT/pins"
export SPOOL_LOG_LEVEL=error
unset SPOOL_BOX_ID SPOOL_HUB_URL

B="$WORK/spool"
( cd "$MOD" && go build -o "$B" ./cmd/spool )

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; exit 1; }

# 0. a local send to an id this root does not know is refused, nothing written
#    (specs/058 N1: it lives on another machine, or nowhere)
rc=0; "$B" send --from GRK-03 --to CLE-07 --kind task --body "x" >/dev/null 2>&1 || rc=$?
[ "$rc" = 3 ] && [ ! -e "$SPOOL_ROOT/CLE-07" ] && pass "unknown local recipient: exit 3, no orphan inbox" ||
  fail "unknown local recipient: rc=$rc"
mkdir -p "$SPOOL_ROOT/CLE-07/inbox"

# 1. blob a file, reference another by path, and send both, with no key at all
echo "patch-bytes" > "$WORK/patch.txt"
echo "on-box-report" > "$WORK/report.txt"
FID="$("$B" put-file "$WORK/patch.txt" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file_id"])')"
DELIVERY="$("$B" send --from GRK-03 --to CLE-07 --kind task --body "review this" \
     --file-id "$FID" --file-ref "$WORK/report.txt" | python3 -c 'import json,sys;print(json.load(sys.stdin)["delivery"])')"
pass "sent unsigned message with blob + path attachments"
[ "$DELIVERY" = "local" ] && pass "send result carries delivery=local" || fail "delivery was $DELIVERY"
grep -q '"sig"' "$SPOOL_ROOT/CLE-07/inbox/"*.json && fail "local v:1 carries a sig" || pass "local v:1 omits sig"
[ ! -e "$SPOOL_KEYS_DIR" ] && [ ! -e "$SPOOL_PINS_DIR" ] && pass "no key and no pin were needed" || fail "keys/pins touched"

# 2. recv --ack returns exactly one message, then inbox is empty
N="$("$B" recv --as CLE-07 --ack | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
[ "$N" = "1" ] && pass "recv --ack returned 1 message" || fail "recv returned $N"
N2="$("$B" recv --as CLE-07 | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
[ "$N2" = "0" ] && pass "second recv is empty (at-most-once ack)" || fail "double-recv returned $N2"
[ -f "$SPOOL_ROOT/CLE-07/archive/"*.json ] && pass "message archived on ack" || fail "not archived"

# 3. get-file back and verify bytes
"$B" get-file "$FID" "$WORK/out.txt" >/dev/null
[ "$(cat "$WORK/out.txt")" = "patch-bytes" ] && pass "get-file bytes verified" || fail "get-file mismatch"

# 4. optional box key: keygen needs a box id, writes box-<id>.key 0600, pins box-<id>.pub
set +e
"$B" keygen >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] && pass "keygen without \$SPOOL_BOX_ID fails fast" || fail "keygen without box exit was $rc"
set +e
SPOOL_KEYS_DIR="$SPOOL_ROOT/keys" SPOOL_BOX_ID=box-a "$B" keygen >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] && [ ! -e "$SPOOL_ROOT/keys/box-box-a.key" ] && pass "keygen refuses a keys dir inside \$SPOOL_ROOT (FR-009)" || fail "keygen into \$SPOOL_ROOT exit was $rc"
PUB="$(SPOOL_BOX_ID=box-a "$B" keygen)"; "$B" pin --box box-a --pubkey "$PUB"
[ "$(stat -c '%a' "$SPOOL_KEYS_DIR/box-box-a.key")" = "600" ] && pass "box private key is box-<id>.key 0600" || fail "box key missing or not 0600"
[ -f "$SPOOL_PINS_DIR/box-box-a.pub" ] && pass "box pin created" || fail "no box pin"
SPOOL_BOX_ID=box-a "$B" send --from GRK-03 --to CLE-07 --kind note --body "still unsigned" >/dev/null
grep -q '"sig"' "$SPOOL_ROOT/CLE-07/inbox/"*.json && fail "box key signed local mail" || pass "a box key does not sign local mail"
"$B" recv --as CLE-07 --ack >/dev/null

# 5. a corrupted blob is refused on get-file with exit 78
echo "rotted" > "$SPOOL_ROOT/files/$FID"
set +e
"$B" get-file "$FID" "$WORK/bad.txt" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "78" ] && [ ! -e "$WORK/bad.txt" ] && pass "hash mismatch refused (exit 78), nothing written" || fail "hash mismatch exit was $rc"

# 6. legacy .md message bridge: drop a legacy .md file, recv absorbs and archives it
mkdir -p "$SPOOL_ROOT/CLE-07/inbox"
cat > "$SPOOL_ROOT/CLE-07/inbox/20260903T084612Z--CLE-387--done.md" <<'MD'
---
from: CLE-387
to: CLE-07
sent: 20260903T084612Z
subject: done
---
legacy-markdown-body
MD
LEG_FROM="$("$B" recv --as CLE-07 --ack | python3 -c 'import json,sys;msgs=json.load(sys.stdin);print(msgs[0]["from"] if msgs else "")')"
[ "$LEG_FROM" = "CLE-387" ] && pass "legacy .md transparently bridged and archived" || fail "legacy bridge failed"
[ -f "$SPOOL_ROOT/CLE-07/archive/20260903T084612Z--CLE-387--done.md" ] && pass "legacy .md moved to archive on ack" || fail "legacy .md not in archive"

# 7. spool mcp speaks MCP over real stdio: initialize, the five canonical tools,
#    an unsigned send, and the corrupted blob as a tool error mirroring exit 78.
#    stdin is held open until all four replies (ids 1..4, in any order) are
#    written, bounded: the stdio transport closes on EOF, and a fixed `sleep 1`
#    lost replies under box load (CLE-77859).
{ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spool_send","arguments":{"from":"AGY-09","to":"CLE-07","kind":"note","body":"hi"}}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"spool_get_file\",\"arguments\":{\"file_id\":\"$FID\",\"dest\":\"$WORK/mcp-bad.txt\"}}}"
  for _ in $(seq 1 500); do
    [ "$(grep -cE '"id":[1-4][,}]' "$WORK/mcp.out" 2>/dev/null)" = 4 ] && break; sleep 0.1
  done
} | timeout 60 "$B" mcp > "$WORK/mcp.out"
MCP="$(python3 - "$WORK/mcp.out" <<'PY'
import json,sys
r={d.get("id"):d.get("result",{}) for d in map(json.loads,open(sys.argv[1]))}
tools=",".join(sorted(t["name"] for t in r[2]["tools"]))
sent=json.loads(r[3]["content"][0]["text"])["delivery"]
err=r[4]["content"][0]["text"]
print(r[1]["serverInfo"]["name"], tools, r[3].get("isError", False), sent, r[4]["isError"], err.endswith("(exit 78)"))
PY
)"
[ "$MCP" = "spool spool_get_file,spool_issue,spool_put_file,spool_recv,spool_send,spool_tail False local True True" ] \
  && pass "spool mcp over stdio: 5 canonical tools + spool_issue, unsigned send, hash mismatch is a tool error (exit 78)" || fail "spool mcp stdio: $MCP"

echo "ALL SMOKE CHECKS PASSED"
