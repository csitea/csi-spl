#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the lane map's --check never hangs under ./run (SPL-5519).
#   1. the real `./run -a do_spl_lane_map` (run.sh's two log tees in place,
#      under `timeout`): three live lanes with a worktree here are read one
#      at a time (LANE_WT_JOBS=1, the bounded wait), a path one of them
#      changed is exit 3, a free path is `free` exit 0, and the plain map
#      ends too. RED on the scan before it: its bare `wait` (and `wait -n`)
#      also waited on run.sh's tees, which live until the action exits, so
#      every --check under ./run hung until the timeout (exit 124). The
#      lane-map.tst.sh cases source the functions without ./run, which is
#      why they passed
#   2. lane-map.sh --check has an overall limit, LANE_CHECK_TIMEOUT
#      (default 60 s): a stub action that sleeps is `LOCAL-ONLY: ...` and
#      exit 5 (not free) within the limit; CONTROL a stub that answers keeps
#      its own verdict and exit code; a limit that is not whole seconds is
#      exit 64
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 1. the real ./run, its tees in place
mkdir -p "$T/home" "$T/spool"
git init -q "$T/csi-spl" && git -C "$T/csi-spl" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$T/csi-spl" update-ref refs/remotes/origin/master HEAD
for id in c-731 c-732 c-733; do git -C "$T/csi-spl" worktree add -q -b "$id-b" "$T/csi-spl-wt/$id" >/dev/null 2>&1; done
mkdir -p "$T/csi-spl-wt/c-732/a" && echo x >"$T/csi-spl-wt/c-732/a/x.txt"
printf '0 c-731@box-desk\n0 c-732@box-desk\n0 c-733@box-desk\n' >"$T/panes"
run() {
  (cd "$PROJ_ROOT" && env HOME="$T/home" PROJ_PATH="$T/csi-spl" SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" \
    SPOOL_DESK_BOX=box-desk LANE_FLEET= LEASE_FLEET= LANE_REPO_DIRS="$T/csi-spl" LANE_PANES_CMD="cat $T/panes" \
    LANE_CI_CMD="echo 0" SPOOL_VENDOR_CLIS_CMD=false LANE_WT_JOBS=1 "$@" timeout 30 ./run -a do_spl_lane_map --quiet 2>/dev/null)
}
s=$SECONDS
out="$(run LANE_CHECK=a/x.txt LANE_AGENT=c-777)"; rc=$?
[[ $rc -eq 3 && "$out" == *"a/x.txt owned by c-732@box-desk c-732-b (changed in its worktree; no files recorded)"* ]] &&
  pass "./run --check reads 3 worktrees one at a time and ends: a changed path is owned, exit 3 ($((SECONDS - s)) s)" ||
  fail "./run --check on a changed path (rc=$rc, 124 = hung on run.sh's tees): $out"
out="$(run LANE_CHECK=z/free.md LANE_AGENT=c-777)"; rc=$?
[[ $rc -eq 0 && "$out" == free ]] && pass "./run --check on a free path is free, exit 0" ||
  fail "./run --check on a free path (rc=$rc, 124 = hung on run.sh's tees): $out"
out="$(run)"; rc=$?
[[ $rc -eq 0 && "$out" == *c-732@box-desk* ]] && pass "./run map (the clean-lane scan in a subshell) ends, exit 0" ||
  fail "./run map (rc=$rc): $out"

# 2. lane-map.sh --check: the overall time limit
LM="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/lane-map.sh"
mkdir -p "$T/orc" "$T/lm"
printf '#!/usr/bin/env bash\n[ -n "${STUB_SLEEP:-}" ] && exec sleep "$STUB_SLEEP"\necho "a/b owned by c-101@sat b"\nexit 3\n' >"$T/orc/run"
chmod +x "$T/orc/run"
lm() { env -u LANE_BOX -u LANE_DESK_BOX SPOOL_ROOT="$T/lm" SPOOL_BOX_ENV="$T/lm/box.env" SPOOL_DESK_BOX=box-desk LANE_MAP_ORC="$T/orc" "$@"; }
s=$SECONDS
out="$(lm STUB_SLEEP=30 LANE_CHECK_TIMEOUT=2 bash "$LM" --check a/b --agent c-077 2>/dev/null)"; rc=$?
took=$((SECONDS - s))
[[ $rc -eq 5 && "$out" == "LOCAL-ONLY: lane-map --check did not finish in 2 s"*"not free, ask c-001" && $took -lt 10 ]] &&
  pass "a stalled action is LOCAL-ONLY, exit 5, after the 2 s limit (${took} s), never a hang" ||
  fail "stalled check (rc=$rc, ${took} s): $out"
out="$(lm LANE_CHECK_TIMEOUT=2 bash "$LM" --check a/b --agent c-077 2>/dev/null)"; rc=$?
[[ $rc -eq 3 && "$out" == "a/b owned by c-101@sat b" ]] && pass "control: an action that answers keeps its verdict and exit 3" ||
  fail "control check (rc=$rc): $out"
out="$(lm LANE_CHECK_TIMEOUT=1m bash "$LM" --check a/b --agent c-077 2>&1)"; rc=$?
[[ $rc -eq 64 && "$out" == *"LANE_CHECK_TIMEOUT must be whole seconds"* ]] && pass "LANE_CHECK_TIMEOUT=1m is refused, exit 64" ||
  fail "bad limit (rc=$rc): $out"

echo
if [ "$fails" -eq 0 ]; then echo "lane-map-run-tees: all passed"; exit 0; fi
echo "lane-map-run-tees: $fails FAILED"; exit 1
