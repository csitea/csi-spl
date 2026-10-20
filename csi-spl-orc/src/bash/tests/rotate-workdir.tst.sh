#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_rotate_workdir (spl-rotate-lib.func.sh), the dir a rotation,
#          restart or takeover starts the new session in, never a home dir
#          (SPL-2715). An orch rotation 2026-10-20 0905Z: no registry row, the
#          old pid's cwd unreadable to the caller, so the successor started in
#          the box user's home, loaded its .claude/settings.json as PROJECT
#          settings, a failing hook denied every Bash call: no ack.
#   1. the repro: no registry row, an unreadable /proc cwd, a lane id ->
#      nothing, exit 1 (was $HOME), under ./run's set -E + ERR trap
#   2. the old cwd read as root (ROTATE_PRIV) when the plain read fails
#   3. a home dir is never used: ROTATE_WORKDIR, a registry row or the old
#      cwd naming $HOME, the agent home or a passwd home is skipped
#   4. a role id (lease.conf, a seat id) falls back to the role checkout:
#      ROTATE_ROLE_WORKDIR, else the tree above PROJ_PATH; a lane id does not
#   5. the seat switch (c-001 -> g-001): the new id has no row, the old one does
#   6. spl_rotate_spawn refuses with the reason and never calls the spawn
#------------------------------------------------------------------------------
set -uo pipefail
while read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(SPOOL_|ROTATE_|LEASE_)')
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export T
mkdir -p "$T/spool" "$T/proc/4242" "$T/bin" "$T/home/agent" "$T/wt/c-777" "$T/old" "$T/role" "$T/proj/app-orc" "$T/wt/c-001"
# the privileged reader: what root would read for the old pid's cwd
printf '#!/usr/bin/env bash\n[ -n "${PRIV_CWD:-}" ] || exit 1\necho "$PRIV_CWD"\n' >"$T/bin/priv"
printf '#!/usr/bin/env bash\necho called >"$T/spawned"\n' >"$T/bin/spawn"
chmod +x "$T/bin/priv" "$T/bin/spawn"

# wd <id> [VAR=value ...]: spl_rotate_workdir under ./run's set -E + ERR trap;
# prints "<dir>|rc=<n>", or ERRTRAP when the trap fired
wd() {
  local id="$1"; shift
  env -i PATH="$PATH" HOME="$T/home/box" T="$T" SPOOL_ROOT="$T/spool" LEASE_PROC_ROOT="$T/proc" \
    ROTATE_OLD_PID=4242 ROTATE_PRIV="$T/bin/priv" ROTATE_AGENT_HOME="$T/home/agent" "$@" \
    bash -c 'set -E; trap "echo ERRTRAP; exit 9" ERR; do_log() { :; }
      source "$1/src/bash/run/spl-rotate-lib.func.sh"
      d="$(spl_rotate_workdir "$2")" || { echo "|rc=1|$(spl_rotate_workdir_why "$2")"; exit 0; }
      echo "$d|rc=0"' _ "$PROJ_ROOT" "$id"
}
mkdir -p "$T/home/box"

# 1. the repro
out="$(wd c-777)"
[[ "$out" == "|rc=1|"* && "$out" == *"never starts in a home dir (SPL-2715)"* ]] &&
  pass "1. no registry row + unreadable /proc cwd: refused, not \$HOME" || fail "1. repro: $out"
out="$(wd c-777 ROTATE_PRIV=false)"
[[ "$out" == "|rc=1|"* ]] && pass "1. no privileged read either: refused" || fail "1. no priv: $out"
out="$(env -i PATH="$PATH" HOME="$T/home/box" SPOOL_ROOT="$T/spool" bash -c 'set -E; trap "echo ERRTRAP; exit 9" ERR; do_log() { :; }
  source "$1/src/bash/run/spl-rotate-lib.func.sh"; echo "PLAN $(spl_rotate_workdir c-777 || echo REFUSED)"' _ "$PROJ_ROOT")"
[[ "$out" == "PLAN REFUSED" ]] && pass "1. a PLAN line's refusal trips no ERR trap" || fail "1. plan form: $out"

# 2. the privileged read
out="$(wd c-777 PRIV_CWD="$T/old")"
[[ "$out" == "$T/old|rc=0" ]] && pass "2. unreadable cwd read as root: the old pid's cwd" || fail "2. priv read: $out"
ln -s "$T/wt/c-777" "$T/proc/4242/cwd"
out="$(wd c-777 PRIV_CWD="$T/old")"
[[ "$out" == "$T/wt/c-777|rc=0" ]] && pass "2. a readable cwd needs no root" || fail "2. plain read: $out"
rm "$T/proc/4242/cwd"

# 3. never a home dir
out="$(wd c-777 PRIV_CWD="$T/home/box")"
[[ "$out" == "|rc=1|"* ]] && pass "3. old cwd = \$HOME: refused" || fail "3. old cwd home: $out"
out="$(wd c-777 PRIV_CWD="$T/home/agent")"
[[ "$out" == "|rc=1|"* ]] && pass "3. old cwd = the agent user's home: refused" || fail "3. agent home: $out"
out="$(wd c-777 ROTATE_WORKDIR="$T/home/box")"
[[ "$out" == "|rc=1|"* ]] && pass "3. ROTATE_WORKDIR = \$HOME: skipped" || fail "3. ROTATE_WORKDIR home: $out"
h="$(getent passwd "$(id -un)" | cut -d: -f6)"
out="$(wd c-777 PRIV_CWD="$h")"
[[ "$out" == "|rc=1|"* ]] && pass "3. old cwd = a passwd home: refused" || fail "3. passwd home: $out"
printf 'c-777\tclaude\t%%9\t%s\t20261020T0900Z\n' "$T/home/box" >"$T/spool/registry.tsv"
out="$(wd c-777 PRIV_CWD="$T/old")"
[[ "$out" == "$T/old|rc=0" ]] && pass "3. a registry row naming \$HOME is skipped, the next source wins" || fail "3. registry home: $out"
printf 'c-777\tclaude\t%%9\t%s\t20261020T0900Z\n' "$T/wt/c-777" >>"$T/spool/registry.tsv"
out="$(wd c-777 PRIV_CWD="$T/old")"
[[ "$out" == "$T/wt/c-777|rc=0" ]] && pass "3. control: the newest registry row wins" || fail "3. registry: $out"
: >"$T/spool/registry.tsv"

# 4. a role id falls back to the role checkout
out="$(wd c-900 LEASE_ORCH=c-900 ROTATE_ROLE_WORKDIR="$T/role")"
[[ "$out" == "$T/role|rc=0" ]] && pass "4. the orch id: ROTATE_ROLE_WORKDIR" || fail "4. role knob: $out"
out="$(wd c-900 LEASE_ORCH=c-900 PROJ_PATH="$T/proj/app-orc")"
[[ "$out" == "$T/proj|rc=0" ]] && pass "4. the orch id: the tree above PROJ_PATH" || fail "4. role default: $out"
out="$(wd g-002 PROJ_PATH="$T/proj/app-orc")"
[[ "$out" == "$T/proj|rc=0" ]] && pass "4. a role seat id (g-002): the checkout" || fail "4. seat id: $out"
out="$(wd c-777 LEASE_ORCH=c-900 PROJ_PATH="$T/proj/app-orc")"
[[ "$out" == "|rc=1|"* ]] && pass "4. control: a lane id gets no checkout fallback" || fail "4. lane: $out"
out="$(wd c-900 LEASE_ORCH=c-900 ROTATE_ROLE_WORKDIR="$T/home/box")"
[[ "$out" == "|rc=1|"*"no role checkout"* ]] && pass "4. a role checkout that is a home dir: refused, named" || fail "4. role home: $out"

# 5. the seat switch: g-001 has no row, c-001 has
printf 'c-001\tclaude\t%%9\t%s\t20261020T0900Z\n' "$T/wt/c-001" >"$T/spool/registry.tsv"
out="$(wd g-001 ROTATE_SWITCH_FROM=c-001 ROTATE_SWITCH_TO=g-001)"
[[ "$out" == "$T/wt/c-001|rc=0" ]] && pass "5. seat switch c-001 -> g-001: the old id's rundir" || fail "5. switch: $out"
out="$(wd c-001 ROTATE_SWITCH_FROM=g-001 ROTATE_SWITCH_TO=c-001)"
[[ "$out" == "$T/wt/c-001|rc=0" ]] && pass "5. switch back g-001 -> c-001: its own row" || fail "5. switch back: $out"
: >"$T/spool/registry.tsv"

# 6. spl_rotate_spawn refuses before any spawn
out="$(env -i PATH="$PATH" HOME="$T/home/box" T="$T" SPOOL_ROOT="$T/spool" LEASE_PROC_ROOT="$T/proc" ROTATE_OLD_PID=4242 \
  ROTATE_PRIV=false ROTATE_SPAWN="$T/bin/spawn" ROTATE_AGENT_HOME="$T/home/agent" ROTATE_RID=20261020T0905Z-orch \
  bash -c 'set -E; trap "echo ERRTRAP; exit 9" ERR; do_log() { :; }
    source "$1/src/bash/run/spl-rotate-lib.func.sh"
    spl_rotate_spawn c-777 /dev/null || echo "rc=1 $ROTATE_ERR"' _ "$PROJ_ROOT")"
[[ "$out" == "rc=1 no working dir for c-777"* && ! -e "$T/spawned" ]] &&
  pass "6. spl_rotate_spawn: refused with the reason, no spawn" || fail "6. spawn: $out $(ls "$T")"

echo "rotate-workdir: $fails failure(s)"
(( fails == 0 ))
