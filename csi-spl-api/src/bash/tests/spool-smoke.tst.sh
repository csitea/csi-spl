#!/usr/bin/env bash
# End-to-end smoke for the on-box spool (spec 002), mirroring the ysg-box
# agent-msg flow: keygen -> pin -> send (with a blob + a path ref) -> recv --ack
# -> get-file. Self-contained: builds the binary and uses throwaway temp dirs.
#
# Usage: bash csi-spl-api/src/bash/tests/spool-smoke.tst.sh
set -euo pipefail

export PATH=/usr/local/go/bin:$PATH
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$HERE/../../go/spool-hub-api"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export SPOOL_ROOT="$WORK/msgs"
export SPOOL_KEYS_DIR="$WORK/keys"
export SPOOL_PINS_DIR="$SPOOL_ROOT/pins"
export SPOOL_LOG_LEVEL=error

B="$WORK/spool"
( cd "$MOD" && go build -o "$B" ./cmd/spool )

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; exit 1; }

# 1. keygen + pin two agents
PUBG="$("$B" keygen --as GRK-03)"; "$B" pin --id GRK-03 --pubkey "$PUBG"
PUBC="$("$B" keygen --as CLE-07)"; "$B" pin --id CLE-07 --pubkey "$PUBC"
[ -f "$SPOOL_KEYS_DIR/GRK-03.key" ] && pass "private key created" || fail "no private key"
[ "$(stat -c '%a' "$SPOOL_KEYS_DIR/GRK-03.key")" = "600" ] && pass "private key is 0600" || fail "private key not 0600"
[ -f "$SPOOL_PINS_DIR/GRK-03.pub" ] && pass "shared pin created" || fail "no pin"

# 2. blob a file, reference another by path, and send both
echo "patch-bytes" > "$WORK/patch.txt"
echo "on-box-report" > "$WORK/report.txt"
FID="$("$B" put-file "$WORK/patch.txt" | python3 -c 'import json,sys;print(json.load(sys.stdin)["file_id"])')"
"$B" send --from GRK-03 --to CLE-07 --kind task --body "review this" \
     --file-id "$FID" --file-ref "$WORK/report.txt" >/dev/null
pass "sent signed message with blob + path attachments"

# 3. recv --ack returns exactly one verified message, then inbox is empty
N="$("$B" recv --as CLE-07 --ack | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
[ "$N" = "1" ] && pass "recv --ack returned 1 verified message" || fail "recv returned $N"
N2="$("$B" recv --as CLE-07 | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
[ "$N2" = "0" ] && pass "second recv is empty (at-most-once ack)" || fail "double-recv returned $N2"
[ -f "$SPOOL_ROOT/CLE-07/archive/"*.json ] && pass "message archived on ack" || fail "not archived"

# 4. get-file back and verify bytes
"$B" get-file "$FID" "$WORK/out.txt" >/dev/null
[ "$(cat "$WORK/out.txt")" = "patch-bytes" ] && pass "get-file bytes verified" || fail "get-file mismatch"

# 5. unpinned sender is refused with exit 78
set +e
"$B" send --from AGY-09 --to CLE-07 --kind note --body hi >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "78" ] && pass "unpinned sender refused (exit 78)" || fail "unpinned exit was $rc"

# 6. tampered message fails verification (exit 78)
"$B" send --from GRK-03 --to CLE-07 --kind note --body "tamper-me" >/dev/null
F="$(ls "$SPOOL_ROOT/CLE-07/inbox/"*.json | head -1)"
python3 - "$F" <<'PY'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
m["body"]="tampered"
json.dump(m,open(p,"w"))
PY
set +e
"$B" recv --as CLE-07 >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "78" ] && pass "tampered message refused (exit 78)" || fail "tamper exit was $rc"
rm -f "$F"

# 7. legacy .md message bridge: drop a legacy .md file, recv absorbs and archives it
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

# 8. spool mcp speaks MCP over real stdio: initialize, the five canonical tools,
#    and an unpinned send surfaces as a tool error mirroring exit 78. stdin is
#    held open briefly so the replies are written before EOF ends the server.
{ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"spool_send","arguments":{"from":"AGY-09","to":"CLE-07","kind":"note","body":"hi"}}}'
  sleep 1; } | timeout 20 "$B" mcp > "$WORK/mcp.out"
MCP="$(python3 - "$WORK/mcp.out" <<'PY'
import json,sys
r={d.get("id"):d.get("result",{}) for d in map(json.loads,open(sys.argv[1]))}
tools=",".join(sorted(t["name"] for t in r[2]["tools"]))
print(r[1]["serverInfo"]["name"], tools, r[3]["isError"], r[3]["content"][0]["text"])
PY
)"
[ "$MCP" = "spool spool_get_file,spool_put_file,spool_recv,spool_send,spool_tail True spool: AGY-09: agent id is not pinned (exit 78)" ] \
  && pass "spool mcp over stdio: 5 canonical tools, unpinned send is a tool error (exit 78)" || fail "spool mcp stdio: $MCP"

echo "ALL SMOKE CHECKS PASSED"
