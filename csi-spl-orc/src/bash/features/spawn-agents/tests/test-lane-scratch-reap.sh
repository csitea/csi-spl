#!/usr/bin/env bash
# agent-id-retire.sh step 8 (lane-scratch-reap.sh --list): once a lane's
# window is closed and its id retired, its Claude Code scratch on the /tmp
# tmpfs (/tmp/claude-<uid>/<worktree slug>[-*]/) is listed in the box's
# workdir table (SPL-2110: kept 24 h after the finish), and the disk sweep
# (csi-spl-utl workdir-sweep.sh) removes it then, ONLY when no process holds
# it. Defect (n=1): the closed c-232 left 20 GB in its scratch and /tmp
# reached 93% (sat, 2026-10-15).
# A sandbox tmp root, spool and registry; the real /tmp is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
RET="$T_SCRIPTS/agent-id-retire.sh"
SWEEP="$(cd "$T_FEAT/../../../../.." && pwd)/csi-spl-utl/src/bash/scripts/workdir-sweep.sh"
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

# sweep_at <hours>: the disk sweep, live, this user only, the clock moved on
sweep_at() {
  env SPOOL_NOW="$(date -u -d "@$(( $(date -u -d "$SPOOL_NOW" +%s) + $1 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    WORKDIR_SWEEP_SUDO=0 WORKDIR_SWEEP_FREE_PCT=50 WORKDIR_SWEEP_TMP="$TR" DRY_RUN=0 bash "$SWEEP" 2>&1
}
TB="$R/workdirs.tsv"

# 1. the dry run plans the listing of both dirs and writes nothing.
lane c-201
out="$(bash "$RET" c-201 2>&1)"
has "1. the dry run plans the slug dir" "PLAN scratch   list $S/$(slug c-201) " "$out"
has "1. ...and the subdir session's" "PLAN scratch   list $S/$(slug c-201)-csi-orc " "$out"
check "1. ...and removes nothing" test -f "$S/$(slug c-201)/sess-1/f"
check "1. ...and writes no table" test ! -e "$TB"

# 2. the retire lists both, removes none; 25 h later the sweep keeps the held
#    one and removes the free one.
( cd "$S/$(slug c-201)/sess-1" && exec sleep 600 ) >/dev/null 2>&1 & hold=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold/cwd")" = "$S/$(slug c-201)/sess-1" ] && break; sleep 0.1; done
bash "$RET" --apply c-201 >"$T_TMP/o" 2>&1; eq "2. retire exits 0" 0 "$?"
check "2. both dirs are listed as scratch" test "$(grep -cP "^\Q$S/$(slug c-201)\E(-csi-orc)?\tscratch\tc-201\t" "$TB")" = 2
check "2. ...and both stay after the retire" test -f "$S/$(slug c-201)-csi-orc/sess-2/f"
out="$(sweep_at 25)"
has "2. 25 h later a held scratch is KEEP in-use" "KEEP in-use (a process has its cwd or an open file under it) scratch $S/$(slug c-201) " "$out"
check "2. ...and stays" test -f "$S/$(slug c-201)/sess-1/f"
check "2. ...the free one goes, a REMOVE line names it" grep -qE "REMOVE [0-9]+KB scratch $S/$(slug c-201)-csi-orc " <<<"$out"
check "2. ...it is gone" test ! -e "$S/$(slug c-201)-csi-orc"
kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null

# 3. nobody holds it: the sweep removes it after 24 h, a neighbour lane's
#    (c-2011) is never listed nor touched.
lane c-202
bash "$RET" --apply c-202 >"$T_TMP/o" 2>&1; eq "3. retire exits 0" 0 "$?"
check "3. 1 h later it is still there" bash -c "$(declare -f sweep_at); SWEEP='$SWEEP' TR='$TR' SPOOL_NOW='$SPOOL_NOW' sweep_at 1 >/dev/null; test -d '$S/$(slug c-202)'"
out="$(sweep_at 25)"
check "3. 25 h later the unheld scratch is gone" test ! -e "$S/$(slug c-202)"
has "3. the REMOVE line names its size" "REMOVE 10" "$out"
check "3. a lane whose id only starts the same (c-2011) is untouched" test -f "$S/$(slug c-2011)/f"
check "3. ...and was never listed" bash -c "! grep -qF -e '$S/$(slug c-2011)' '$TB'"

# 4. RED CONTROL: without step 8 (RETIRE_SCRATCH=0) nothing is listed, so the
#    sweep never finds it.
lane c-203
RETIRE_SCRATCH=0 bash "$RET" --apply c-203 >/dev/null 2>&1
sweep_at 25 >/dev/null
check "4. CONTROL: RETIRE_SCRATCH=0 lists nothing and the scratch stays (red)" test -f "$S/$(slug c-203)/sess-1/f"

# 5. by hand, lane-scratch-reap.sh --apply still removes at once and logs it.
bash "$T_SCRIPTS/lane-scratch-reap.sh" --apply "$T_TMP/wt/c-203" >"$T_TMP/o" 2>&1; eq "5. --apply exits 0" 0 "$?"
check "5. --apply removes the unheld scratch" test ! -e "$S/$(slug c-203)"
check "5. ...and the log file has it" grep -qE -e "lane-scratch-reap: DO remove 10[0-9]{2}KB owner=.* $S/$(slug c-203)\$" "$LOGF"
out="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" --apply --list "$T_TMP/wt/c-203" 2>&1)"; eq "5. --apply with --list is refused" 2 "$?"

# 6. step 9: the /var/tmp leftovers whose name carries the id are listed
#    (var-tmp), the sweep removes them 25 h later; another id's, a dot entry
#    and a symlink are never listed.
VT="$T_TMP/vartmp"; mkdir -p "$VT/c-204-base/d" "$VT/c-2041-x" "$VT/elsewhere"
echo x >"$VT/c-204-base/d/f"; echo x >"$VT/c204-gocache"; echo x >"$VT/.c-204"; ln -s "$VT/elsewhere" "$VT/c-204-link"
lane c-204
RETIRE_SCRATCH=0 RETIRE_VARTMP=1 RETIRE_VARTMP_ROOT="$VT" bash "$RET" --apply c-204 >"$T_TMP/o" 2>&1; eq "6. retire exits 0" 0 "$?"
eq "6. exactly the two leftovers of c-204 are listed" "$VT/c-204-base $VT/c204-gocache" \
  "$(awk -F'\t' '$2 == "var-tmp" && $3 == "c-204" { print $1 }' "$TB" | sort | tr '\n' ' ' | sed 's/ $//')"
WORKDIR_SWEEP_VARTMP_ROOT="$VT" sweep_at 25 >/dev/null
check "6. 25 h later the sweep removed both" bash -c "test ! -e '$VT/c-204-base' && test ! -e '$VT/c204-gocache'"
check "6. ...another id's, the dot entry and the symlink's target stay" bash -c "test -d '$VT/c-2041-x' && test -e '$VT/.c-204' && test -d '$VT/elsewhere'"

t_done
