#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: _dns_wait_tf_runner tries `docker exec <con> true` once a second,
#          returns 0 on the first success, and gives up with an ERROR after
#          exactly 30 tries. docker and sleep are stubs: nothing real runs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# stub docker: counts every call; succeeds from call DOCKER_OK_AT on (0 = never)
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$DOCKER_CALLS" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$DOCKER_CALLS"
(( DOCKER_OK_AT > 0 && n >= DOCKER_OK_AT ))
STUB
chmod +x "$work/bin/docker"

# $1 = DOCKER_OK_AT; prints "<rc> <calls>", the log goes to $work/log
run_wait() {
  rm -f "$work/calls" "$work/log"
  (
    set -u
    PATH="$work/bin:$PATH"
    DOCKER_CALLS="$work/calls" DOCKER_OK_AT="$1"
    export DOCKER_CALLS DOCKER_OK_AT
    sleep() { :; }
    do_log() { echo "$*" >>"$work/log"; }
    # shellcheck disable=SC1091
    source "$PROJ_ROOT/src/bash/run/check-container-dns.func.sh"
    _dns_wait_tf_runner con-test-tf-runner
    echo "$? $(cat "$work/calls")"
  )
}

read -r rc calls < <(run_wait 3)
[[ "$rc" == 0 && "$calls" == 3 ]] && pass "ready on try 3: rc 0 after 3 docker calls" \
  || fail "ready on try 3: want rc 0 / 3 calls, got rc $rc / $calls calls"
[[ ! -s "$work/log" ]] && pass "ready: no ERROR logged" || fail "ready: logged $(cat "$work/log")"

read -r rc calls < <(run_wait 0)
[[ "$rc" != 0 && "$calls" == 30 ]] && pass "never ready: non-zero after exactly 30 docker calls" \
  || fail "never ready: want rc!=0 / 30 calls, got rc $rc / $calls calls"
grep -q '^ERROR con-test-tf-runner did not become ready after resolver restart$' "$work/log" 2>/dev/null \
  && pass "never ready: ERROR line names the container" || fail "never ready: ERROR line missing"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
