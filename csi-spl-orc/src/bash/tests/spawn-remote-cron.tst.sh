#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_spawn_remote_install_cron (HOWTO-satellite-work gap 6) in a
#          sandbox: a fake crontab, a fake shared checkout. The receiver itself
#          is tested in features/spawn-agents/tests/test-spawn-remote.sh.
#   1. dry run: the diff, nothing written
#   2. check fails while not installed
#   3. DRY_RUN=0: one exact every-minute line, other lines kept; idempotent
#   4. check passes once installed
#   5. CRON_REMOVE=1 takes only its line
#   6. an agent worktree source is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi
cp "$1" "$FAKE_CRONTAB"
EOF
chmod +x "$T/bin/crontab"
SRC="$T/shared"; S="$SRC/csi-spl-orc/src/bash/features/spawn-agents/scripts"
mkdir -p "$S"
cp "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-remote.sh" "$S/"
printf '*/3 * * * * other job # csi-spl:desk-reconcile\n' >"$T/crontab"
cron() {
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$SRC" \
    SPAWN_REMOTE_CRON_LOG_DIR="$T/log" "$@" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    source "$PROJ_PATH/src/bash/run/spl-desk-install-service.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-spawn-remote-install-cron.func.sh"
    do_spl_spawn_remote_install_cron'
}
before="$(md5sum <"$T/crontab")"
cron >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(md5sum <"$T/crontab")" == "$before" ]] && grep -q '^    +\* \* \* \* \* .*spawn-remote.sh --serve >> .*/cron.out 2>&1 # csi-spl:spawn-remote$' "$T/o" &&
  pass "1. dry run: the diff, nothing written" || fail "1. dry: rc=$rc $(cat "$T/o")"
cron SPAWN_REMOTE_CRON_ACTION=check >"$T/o" 2>&1 && fail "2. check passed with no line" || pass "2. check fails while not installed"
cron DRY_RUN=0 >"$T/o" 2>&1; rc=$?
want="* * * * * $S/spawn-remote.sh --serve >> $T/log/cron.out 2>&1 # csi-spl:spawn-remote"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$T/crontab" && grep -q 'desk-reconcile' "$T/crontab" &&
  pass "3. DRY_RUN=0: one exact line, the other line kept" || fail "3. install rc=$rc: $(cat "$T/crontab") $(cat "$T/o")"
cron DRY_RUN=0 >/dev/null 2>&1
[[ "$(grep -c '# csi-spl:spawn-remote$' "$T/crontab")" == 1 ]] && pass "3. idempotent" || fail "3. lines: $(cat "$T/crontab")"
cron SPAWN_REMOTE_CRON_ACTION=check >"$T/o" 2>&1 && pass "4. check passes once installed" || fail "4. check: $(cat "$T/o")"
cron CRON_REMOVE=1 DRY_RUN=0 >/dev/null 2>&1
! grep -q 'spawn-remote' "$T/crontab" && grep -q 'desk-reconcile' "$T/crontab" && pass "5. CRON_REMOVE=1 takes only its line" || fail "5. remove: $(cat "$T/crontab")"
mkdir -p "$T/repo-wt/X"
cron DESK_CRON_SRC="$T/repo-wt/X" >"$T/o" 2>&1 && fail "6. a worktree source accepted" || pass "6. an agent worktree is refused"
echo "-- spawn-remote-cron.tst.sh: fails=$fails"
[[ $fails -eq 0 ]]
