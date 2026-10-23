#!/usr/bin/env bash
# hub-live-stack.sh (SPL-2167) refuses to pass when it has no hub to give:
# no command is usage (64), and no Postgres is exit 70, never a skip (0) and
# never the caller's command run without HUB_URL. The full stack (Postgres,
# migrate, serve, the command's exit status) is proven by the wf 10 job
# hub-live, which runs pnpm test:live through it.
# SPL-3107: hub-pg.tst.sh refuses being sourced (return 2, the caller's shell
# lives on), and the stack hands its command SPOOL_TEST_PG_DSN; that case
# needs a Postgres (server binaries or a cached image) and the full tier.
# Usage: bash csi-spl-api/src/bash/tests/hub-live-stack.tst.sh [<stack script>] [<hub-pg.tst.sh>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${1:-$HERE/../hub-live-stack.sh}"
HUB_PG="${2:-$HERE/hub-pg.tst.sh}"
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

# shellcheck disable=SC2016 # $1 expands in the child shell
out="$(timeout 60 env PG_BIN=/nonexistent SPOOL_TEST_PG_IMAGE=none:0 \
  bash -c '. "$1"; echo "AFTER rc=$?"' _ "$HUB_PG" 2>&1)" || true
grep -qx 'AFTER rc=2' <<<"$out" && ! grep -qE '^skip|temp Postgres' <<<"$out" \
  || { echo "FAIL - b07-02a sourcing hub-pg.tst.sh: want 'AFTER rc=2' and no suite run, got: $out"; exit 1; }
echo "ok   - b07-02a hub-pg.tst.sh refuses being sourced (return 2) and the caller's shell lives on"

PG_BIN_HERE="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)}"
if [ "${SPL_API_TEST_TIER:-full}" = fast ]; then
  echo "skip - b07-02b SPOOL_TEST_PG_DSN: fast tier (a full stack build + migrate); the full tier runs it"
elif ! command -v psql >/dev/null; then
  echo "skip - b07-02b SPOOL_TEST_PG_DSN: no psql client"
elif [ -x "$PG_BIN_HERE/initdb" ] \
  || { command -v docker >/dev/null && docker image inspect "${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}" >/dev/null 2>&1; }; then
  rc=0
  # shellcheck disable=SC2016 # expands in the stack's command, not here
  bash "$STACK" bash -c '[ -n "${SPOOL_TEST_PG_DSN:-}" ] && psql "$SPOOL_TEST_PG_DSN" -Atc "select current_user, count(*) from information_schema.tables where table_name='\''messages'\''"' \
    >"$WORK/dsn.out" 2>"$WORK/dsn.err" || rc=$?
  [ "$rc" -eq 0 ] && grep -qx 'spool_app|1' "$WORK/dsn.out" \
    || { echo "FAIL - b07-02b SPOOL_TEST_PG_DSN: rc $rc, want 0 and 'spool_app|1': $(cat "$WORK/dsn.out"; grep -v '^{' "$WORK/dsn.err" | tail -5)"; exit 1; }
  echo "ok   - b07-02b the stack's command gets SPOOL_TEST_PG_DSN (spool_app, migrated schema)"
else
  echo "skip - b07-02b SPOOL_TEST_PG_DSN: no Postgres server binaries and no cached image"
fi
