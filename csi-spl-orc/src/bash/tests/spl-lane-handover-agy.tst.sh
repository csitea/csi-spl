#!/usr/bin/env bash
# shellcheck disable=SC2317,SC1091
#------------------------------------------------------------------------------
# Purpose: Test do_spl_lane_handover_agy
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T=$(mktemp -d)
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

export SPOOL_TEST=1
export SPOOL_ROOT="$T/spool"
mkdir -p "$T/bin" "$T/home/.gemini/antigravity-cli/brain" "$SPOOL_ROOT"
export HOME="$T/home"
export PATH="$T/bin:$PATH"
SPOOL_AGENT_USER="$(id -un)"; export SPOOL_AGENT_USER
SPOOL_BOX_USER="$(id -un)"; export SPOOL_BOX_USER
export SPOOL_PANE_TTY=/dev/null

cat >"$T/bin/sudo" <<EOS
#!/usr/bin/env bash
shift # -n
shift # -u
shift # user
"\$@"
EOS
chmod +x "$T/bin/sudo"

cat >"$T/bin/ssh" <<EOS
#!/usr/bin/env bash
if [ "\${SSH_FAIL:-0}" = 1 ]; then exit 1; fi
echo "ssh \$@" >: > "$T/calls.log"
exit 0
EOS
chmod +x "$T/bin/ssh"

cat >"$T/bin/scp" <<EOS
#!/usr/bin/env bash
if [ "\${SCP_FAIL:-0}" = 1 ]; then exit 1; fi
echo "scp \$@" >: > "$T/calls.log"
exit 0
EOS
chmod +x "$T/bin/scp"

cat >"$T/bin/run" <<EOS
#!/usr/bin/env bash
if [ "\$1" = "-a" ] && [ "\$2" = "do_spl_lane_handover_wip" ]; then
  if [ "\${WIP_FAIL:-0}" = 1 ]; then
    echo "wip fail" >&2
    exit 1
  fi
  echo "OK HANDOVER-WIP \$ID sha=123 ref=refs/heads/wip/handover/\$ID"
  exit 0
fi
EOS
chmod +x "$T/bin/run"

source "$PROJ_ROOT/run/spl-lane-handover-agy.func.sh"
export SPAWN_ORC_RUN="run"

getent() {
  if [ "$1" = "passwd" ]; then
    echo "$2:x:1000:1000::${T}/home:/bin/bash"
  else
    command getent "$@"
  fi
}
export -f getent

# 1. Success
: > "$T/calls.log"
mkdir -p "$T/home/.gemini/antigravity-cli/brain/a-001"
out=$(ID=a-001 BOX=target-box DRY_RUN=0 do_spl_lane_handover_agy 2>&1)
if [[ "$out" == *"OK HANDOVER-AGY a-001 to target-box"* ]] && grep -q "scp -q -r .*/brain/a-001 target-box:.*/brain/" "$T/calls.log"; then
  pass "success"
else
  fail "success: $out"
fi

# 2. Missing vars
out=$(ID="" BOX=target-box DRY_RUN=0 do_spl_lane_handover_agy 2>&1 || echo "FAIL")
if [[ "$out" == *"ID and BOX are required"* ]]; then pass "missing vars"; else fail "missing vars"; fi

# 3. WIP fail (red control)
out=$(ID=a-001 BOX=target-box DRY_RUN=0 WIP_FAIL=1 do_spl_lane_handover_agy 2>&1 || echo "FAIL_EXEC")
if [[ "$out" == *"wip fail"* ]] && [[ "$out" == *"FAIL_EXEC"* ]]; then pass "wip fail"; else fail "wip fail: $out"; fi

# 4. scp fail (fallback)
: > "$T/calls.log"
out=$(ID=a-001 BOX=target-box DRY_RUN=0 SCP_FAIL=1 do_spl_lane_handover_agy 2>&1 || echo "FAIL_EXEC")
if [[ "$out" == *"Handover fallback"* ]] && [[ "$out" != *"FAIL_EXEC"* ]]; then pass "scp fail"; else fail "scp fail: $out"; fi

# 5. DRY_RUN
: > "$T/calls.log"
out=$(ID=a-001 BOX=target-box DRY_RUN=1 do_spl_lane_handover_agy 2>&1)
if [[ "$out" == *"PLAN handover"* ]]; then pass "dry run"; else fail "dry run"; fi

exit $fails
