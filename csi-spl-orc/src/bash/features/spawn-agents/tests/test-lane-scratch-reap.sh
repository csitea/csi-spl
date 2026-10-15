#!/usr/bin/env bash
# agent-id-retire.sh step 8 (lane-scratch-reap.sh): once a lane's window is
# closed and its id retired, its Claude Code scratch on the /tmp tmpfs
# (/tmp/claude-<uid>/<worktree slug>[-*]/) goes, ONLY when no process holds
# it, and the removal is logged. Defect (n=1): the closed c-232 left 20 GB in
# its scratch and /tmp reached 93% (sat, 2026-10-15).
# A sandbox tmp root, spool and registry; the real /tmp is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
RET="$T_SCRIPTS/agent-id-retire.sh"
R="$SPOOL_ROOT" TR="$T_TMP/tmp" LOGF="$T_TMP/reap.log"
export RETIRE_WORKTREE=0 RETIRE_DESKS=0 RETIRE_LANE=0 RETIRE_SCRATCH=1
export LANE_SCRATCH_TMP="$TR" LANE_SCRATCH_SUDO=0 LANE_SCRATCH_LOG="$LOGF"
S="$TR/claude-$(id -u)"
slug() { local p="$T_TMP/wt/$1"; printf '%s' "${p//[^A-Za-z0-9]/-}"; }
lane() {  # ID -> a registry row naming its worktree, a planted 1 MB scratch
  mkdir -p "$R/$1/inbox" "$S/$(slug "$1")/sess-1" "$S/$(slug "$1")-csi-orc/sess-2"
  head -c 1048576 /dev/zero >"$S/$(slug "$1")/sess-1/f"; echo x >"$S/$(slug "$1")-csi-orc/sess-2/f"
  printf '%s\tclaude\t%%1\t%s\t20261002T080000Z\n' "$1" "$T_TMP/wt/$1" >>"$R/registry.tsv"
}
mkdir -p "$S/$(slug c-2011)"; echo x >"$S/$(slug c-2011)/f"

# 1. the dry run plans both dirs and removes nothing.
lane c-201
out="$(bash "$RET" c-201 2>&1)"
has "1. the dry run plans the slug dir" "PLAN remove 10" "$out"
has "1. ...and the subdir session's" "$(slug c-201)-csi-orc" "$out"
check "1. ...and removes nothing" test -f "$S/$(slug c-201)/sess-1/f"
check "1. ...and logs nothing" test ! -e "$LOGF"

# 2. a process holds it: kept, retire still exits 0.
( cd "$S/$(slug c-201)/sess-1" && exec sleep 600 ) >/dev/null 2>&1 & hold=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold/cwd")" = "$S/$(slug c-201)/sess-1" ] && break; sleep 0.1; done
bash "$RET" --apply c-201 >"$T_TMP/o" 2>&1; eq "2. retire exits 0" 0 "$?"
has "2. a held scratch is KEEP in-use" "KEEP in-use $S/$(slug c-201) " "$(cat "$T_TMP/o")"
check "2. ...and stays" test -f "$S/$(slug c-201)/sess-1/f"
check "2. ...the free one goes, a DO line names it" grep -qE "DO remove [0-9]+KB owner=.* $S/$(slug c-201)-csi-orc\$" "$T_TMP/o"
check "2. ...it is gone" test ! -e "$S/$(slug c-201)-csi-orc"
kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null

# 3. nobody holds it: removed, logged, a neighbour lane's (c-2011) untouched.
lane c-202
bash "$RET" --apply c-202 >"$T_TMP/o" 2>&1; eq "3. retire exits 0" 0 "$?"
check "3. the unheld scratch is gone" test ! -e "$S/$(slug c-202)"
has "3. the DO line names its size" "DO remove 10" "$(cat "$T_TMP/o")"
check "3. ...and the log file has it" grep -qE -e "lane-scratch-reap: DO remove 10[0-9]{2}KB owner=.* $S/$(slug c-202)\$" "$LOGF"
check "3. a lane whose id only starts the same (c-2011) is untouched" test -f "$S/$(slug c-2011)/f"

# 4. RED CONTROL: without step 8 (RETIRE_SCRATCH=0, the old retire) it stays.
lane c-203
RETIRE_SCRATCH=0 bash "$RET" --apply c-203 >/dev/null 2>&1
check "4. CONTROL: RETIRE_SCRATCH=0 leaves the scratch (red)" test -f "$S/$(slug c-203)/sess-1/f"

t_done
