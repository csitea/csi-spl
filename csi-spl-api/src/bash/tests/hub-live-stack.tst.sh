#!/usr/bin/env bash
# hub-live-stack.sh (SPL-2167) refuses to pass when it has no hub to give:
# no command is usage (64), and no Postgres is exit 70, never a skip (0) and
# never the caller's command run without HUB_URL. The full stack (Postgres,
# migrate, serve, the command's exit status) is proven by the wf 10 job
# hub-live, which runs pnpm test:live through it.
# Usage: bash csi-spl-api/src/bash/tests/hub-live-stack.tst.sh [<stack script>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${1:-$HERE/../hub-live-stack.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rc=0; bash "$STACK" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 64 ] || { echo "FAIL - no command: exit $rc, want 64"; exit 1; }
echo "ok   - hub-live-stack: no command is usage (exit 64)"

rc=0
PG_BIN=/nonexistent SPOOL_TEST_PG_IMAGE=spool-no-such-image:0 \
  bash "$STACK" touch "$WORK/ran" >"$WORK/out" 2>&1 || rc=$?
[ "$rc" -eq 70 ] && grep -q 'FAIL hub-live-stack: no Postgres' "$WORK/out" \
  || { echo "FAIL - no Postgres: exit $rc, want 70: $(cat "$WORK/out")"; exit 1; }
[ ! -e "$WORK/ran" ] || { echo "FAIL - no Postgres, yet the command ran"; exit 1; }
echo "ok   - hub-live-stack: no Postgres is exit 70 and the command never runs"
