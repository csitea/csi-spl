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
echo "ssh \$@" >> "$T/calls.log"
exit 0
EOS
chmod +x "$T/bin/ssh"

cat >"$T/bin/scp" <<EOS
#!/usr/bin/env bash
if [ "\${SCP_FAIL:-0}" = 1 ]; then exit 1; fi
echo "scp \$@" >> "$T/calls.log"
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

spl_handover_probe() { return 0; }
export -f spl_handover_probe
do_log() { echo "$@"; }
export -f do_log
spl_handover_main_checkout() { echo "/opt/csi/csi-spl"; }
export -f spl_handover_main_checkout
spl_handover_on() { return 0; }
export -f spl_handover_on

# 1. Success (agent id != conversation id)
: > "$T/calls.log"
mkdir -p "$T/home/.gemini/antigravity-cli/brain/c-1234-uuid"
mkdir -p "$T/home/.gemini/antigravity-cli/conversations"
touch "$T/home/.gemini/antigravity-cli/conversations/c-1234-uuid.db"

# Mock spl_handover_on for prep and brief
cat >"$T/bin/spl_handover_on" <<EOS
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$T/bin/spl_handover_on"

out=$(ID=a-001 CONVERSATION_ID=c-1234-uuid BOX=target-box DRY_RUN=0 do_spl_lane_handover_agy 2>&1)
if [[ "$out" == *"OK HANDOVER-AGY a-001 to target-box"* ]] && 
   grep -q "scp -q -r .*/brain/c-1234-uuid satellite:.*/brain/" "$T/calls.log" &&
   grep -q "scp -q .*/conversations/c-1234-uuid.db* satellite:.*/conversations/" "$T/calls.log"; then
  pass "1: success (agent id != conversation id -> the right dir)"
else
  cat "$T/calls.log"
  fail "1: success: $out"
fi

# 2. Resume command check
if grep -q "ssh -q satellite bash .*/spawn-window.sh agy a-001 .*-handover --conversation c-1234-uuid" "$T/calls.log" || 
   grep -q "spawn-window.sh agy a-001 .* --conversation c-1234-uuid" "$T/calls.log"; then
  pass "2: the resume command carries --conversation c-1234-uuid"
else
  fail "2: missing resume command with conversation id"
fi

# 3. Missing vars
out=$(ID="" BOX=target-box DRY_RUN=0 do_spl_lane_handover_agy 2>&1 || echo "FAIL")
if [[ "$out" == *"ID and BOX are required"* ]]; then pass "3: missing vars"; else fail "3: missing vars"; fi

# 4. WIP fail
out=$(ID=a-001 CONVERSATION_ID=c-1234-uuid BOX=target-box DRY_RUN=0 WIP_FAIL=1 do_spl_lane_handover_agy 2>&1 || echo "FAIL_EXEC")
if [[ "$out" == *"wip fail"* ]] && [[ "$out" == *"FAIL_EXEC"* ]]; then pass "4: wip fail"; else fail "4: wip fail: $out"; fi

# 5. scp fail (fallback)
: > "$T/calls.log"
out=$(ID=a-001 CONVERSATION_ID=c-1234-uuid BOX=target-box DRY_RUN=0 SCP_FAIL=1 do_spl_lane_handover_agy 2>&1 || echo "FAIL_EXEC")
if [[ "$out" == *"Handover fallback"* ]] && [[ "$out" != *"FAIL_EXEC"* ]]; then pass "5: scp fail"; else fail "5: scp fail: $out"; fi

# 6. DRY_RUN
: > "$T/calls.log"
out=$(ID=a-001 BOX=target-box DRY_RUN=1 do_spl_lane_handover_agy 2>&1)
if [[ "$out" == *"PLAN handover"* ]]; then pass "6: dry run"; else fail "6: dry run"; fi

# 7. Red control on bc102a5e9 for (1): missing conversation id resolution
out=$(ID=a-001 BOX=target-box DRY_RUN=0 do_spl_lane_handover_agy 2>&1 || echo "FAIL_EXEC")
if [[ "$out" == *"could not resolve conversation id"* ]] && [[ "$out" == *"FAIL_EXEC"* ]]; then
  pass "7: red control: fail clearly when it cannot resolve conversation id"
else
  fail "7: red control failed: $out"
fi

exit $fails
