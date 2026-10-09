#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_doc_tree_timing (spec 113 T002, the dedicated timing run) on
# a fake docker and a fake go:
#   1. it runs ONLY TestWorkspaceDocTiming in ./internal/store/, with
#      SPOOL_TEST_WSDOC_TIMING_GATE=1, without -race, on the DSN of the
#      throwaway container, and removes the container; the go exit 0 is its 0
#   2. a red test (go exit 1) is a non-zero exit, and the container is still
#      removed; WSDOC_TIMING_CEILINGS and WSDOC_TIMING_N reach the test
#   3. TIMING_PG_DSN set: no container at all, that DSN is used
#   4. CONTROL: a container that does not start fails the run before any go
#      test, so a missing database is never a green run
# The real run, and its lowered-ceiling control, are cited in tasks.md T002.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
# shellcheck source=../run/spl-doc-tree-timing.func.sh
source "$PROJ_ROOT/src/bash/run/spl-doc-tree-timing.func.sh"
# shellcheck disable=SC2317 # called by the sourced action
do_log() { echo "$*"; }
# shellcheck disable=SC2317 # called by the sourced action
do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
export APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" SPOOL_BOX_ID=box-t
mkdir -p "$T/stub"
cat >"$T/stub/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >>"$STUB_LOG"
case "$1" in
  run) [ -f "$STUB_LOG.norun" ] && exit 125; echo cid ;;
  port) echo "127.0.0.1:54999" ;;
esac
exit 0
EOF
cat >"$T/stub/go" <<'EOF'
#!/bin/bash
echo "go $* | pwd=$(pwd) gate=$SPOOL_TEST_WSDOC_TIMING_GATE ceil=$SPOOL_TEST_WSDOC_TIMING_CEILINGS n=$SPOOL_TEST_WSDOC_TIMING_N dsn=$SPOOL_TEST_PG_DSN" >>"$STUB_LOG"
exit "${GO_RC:-0}"
EOF
chmod +x "$T/stub/"*
# run [VAR=value]... - the action on the stubs, its output in $T/out
run() {
  : >"$STUB_LOG"
  (
    local kv
    export PATH="$T/stub:$PATH"
    for kv in "$@"; do export "${kv?}"; done
    do_spl_doc_tree_timing
  ) >"$T/out" 2>&1
}

run GO_RC=0; rc=$?
gl="$(grep '^go ' "$STUB_LOG")"
[ "$rc" = 0 ] && [ "$(grep -c '^go ' "$STUB_LOG")" = 1 ] \
  && grep -q -- "test -count=1 -run ^TestWorkspaceDocTiming\$ -v ./internal/store/ |" <<<"$gl" \
  && ! grep -q -- '-race' <<<"$gl" && grep -q 'gate=1 ' <<<"$gl" && grep -q 'pwd=.*/csi-spl-api/src/go/spool-hub-api ' <<<"$gl" \
  && grep -q 'dsn=postgres://spool_app:.*@127.0.0.1:54999/spool_hub_app' <<<"$gl" \
  && grep -q '^docker rm -fv spl-doc-timing-' "$STUB_LOG" && grep -q 'box=box-t load=.* cpus=' "$T/out" \
  && pass "1. one go test, the timing test alone, gated, no -race, on the container, removed" \
  || fail "1. green run (rc $rc): $(cat "$STUB_LOG" "$T/out")"

run GO_RC=1 WSDOC_TIMING_CEILINGS=11111-fanout10=1 WSDOC_TIMING_N=3; rc=$?
gl="$(grep '^go ' "$STUB_LOG")"
[ "$rc" = 1 ] && grep -q 'ceil=11111-fanout10=1 n=3 ' <<<"$gl" && grep -q '^docker rm -fv ' "$STUB_LOG" \
  && grep -q 'FATAL doc tree timing: .* exit 1' "$T/out" \
  && pass "2. a red test is exit 1, the ceilings and n reach it, the container is removed" \
  || fail "2. red run (rc $rc): $(cat "$STUB_LOG" "$T/out")"

run TIMING_PG_DSN=postgres://x@127.0.0.1:1/db; rc=$?
[ "$rc" = 0 ] && ! grep -q '^docker ' "$STUB_LOG" && grep -q 'dsn=postgres://x@127.0.0.1:1/db$' "$STUB_LOG" \
  && pass "3. TIMING_PG_DSN: no container, that database" || fail "3. dsn given (rc $rc): $(cat "$STUB_LOG")"

touch "$STUB_LOG.norun"
run; rc=$?
rm -f "$STUB_LOG.norun"
[ "$rc" != 0 ] && ! grep -q '^go ' "$STUB_LOG" && grep -q 'FATAL cannot start' "$T/out" \
  && pass "4. CONTROL: no database -> a failed run, no go test" || fail "4. no container (rc $rc): $(cat "$STUB_LOG" "$T/out")"

echo "spl-doc-tree-timing: $fails failure(s)"
exit $((fails > 0))
