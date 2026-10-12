#!/usr/bin/env bash
# pg_throwaway_port (pg-throwaway.inc.sh): an orc test whose throwaway Postgres
# did not start stops at the port read with one clear FAIL line, before any
# DSN connect (CI topic f67e3656; run 38214878587 read an empty port and
# failed later on "password authentication failed" -> "FAIL: migrate").
#
#   1. every test that maps 127.0.0.1::5432 reads the port through the helper
#   2. the helper under a stubbed docker: run failed, no port, dead container
#      -> FAIL line + rc 1; CONTROL: a running container with a port -> port
#   3. a real pg test (topic-head-pg.tst.sh) under a docker whose run fails:
#      the FAIL line, rc != 0, and no connect: 0 psql calls, no migrate
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# --- 1. no raw `docker port` read left in a pg test ---------------------------
n=0; bad=()
for f in "$TEST_DIR"/*.tst.sh; do
  [[ "$f" -ef "$0" ]] && continue
  grep -q -- '-p 127.0.0.1::5432' "$f" || continue
  n=$((n + 1))
  { grep -q 'pg_throwaway_port "\$PG_CTR")" || exit 1' "$f" && ! grep -q 'docker port' "$f"; } || bad+=("$(basename "$f")")
done
[[ $n -gt 0 && ${#bad[@]} -eq 0 ]] && pass "1. all $n pg tests read the port through pg_throwaway_port" \
  || fail "1. raw docker port read in ${#bad[@]} of $n: ${bad[*]}"

# --- 2. the helper against a stubbed docker -----------------------------------
mkdir -p "$T/stub"
cat >"$T/stub/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
case "$DOCKER_MODE:$1" in
  *:image) exit 0 ;;
  run-fails:run) echo "docker: failed to bind host port: address already in use" >&2; exit 125 ;;
  run-fails:port|run-fails:inspect) echo "Error: No such container" >&2; exit 1 ;;
  no-port:inspect|ok:inspect) echo true ;;
  dead:inspect) echo false ;;
  no-port:port) exit 0 ;;
  dead:port|ok:port) echo "127.0.0.1:55432" ;;
  *) exit 0 ;;
esac
STUB
printf '#!/bin/sh\necho "psql $*" >>"$STUB_LOG"\nexit 2\n' >"$T/stub/psql"
chmod +x "$T/stub/"*
helper() { # <mode> -> stdout in $T/out, stderr in $T/err, rc
  env PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" DOCKER_MODE="$1" TEST_DIR="$TEST_DIR" bash -c '
    source "$TEST_DIR/pg-throwaway.inc.sh"; pg_throwaway_port ctr-x' >"$T/out" 2>"$T/err"
}
for mode in run-fails no-port dead; do
  helper "$mode"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/out" ]] && grep -q '^FAIL: throwaway postgres did not start: ctr-x ' "$T/err" \
    && pass "2. $mode: one FAIL line, rc 1, no port ($(cat "$T/err"))" || fail "2. $mode: rc=$rc out=$(cat "$T/out") err=$(cat "$T/err")"
done
helper ok; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == 55432 && ! -s "$T/err" ]] && pass "2. CONTROL: a running container gives its port" \
  || fail "2. CONTROL ok: rc=$rc out=$(cat "$T/out") err=$(cat "$T/err")"

# --- 3. a real pg test whose container did not start --------------------------
: >"$T/calls.log"
env PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" DOCKER_MODE=run-fails \
  bash "$TEST_DIR/topic-head-pg.tst.sh" >"$T/real" 2>&1; rc=$?
psql_n=$(grep -c '^psql ' "$T/calls.log")
if grep -q '^SKIP: no cached' "$T/real" || grep -q 'FAIL: no go toolchain' "$T/real"; then
  echo "SKIP: 3. topic-head-pg.tst.sh did not reach the port read: $(tail -1 "$T/real")"
else
  [[ $rc -ne 0 && $psql_n -eq 0 ]] && grep -q '^FAIL: throwaway postgres did not start: spl-topic-head-pg-' "$T/real" \
    && ! grep -q 'migrate' "$T/real" \
    && pass "3. topic-head-pg.tst.sh stops at the port read: rc=$rc, psql calls 0, no migrate" \
    || fail "3. topic-head-pg.tst.sh: rc=$rc psql calls $psql_n: $(tail -3 "$T/real")"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
