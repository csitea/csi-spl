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

echo "ALL SMOKE CHECKS PASSED"
