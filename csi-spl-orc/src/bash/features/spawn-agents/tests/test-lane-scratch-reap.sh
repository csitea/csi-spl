#!/usr/bin/env bash
# agent-id-retire.sh step 8 (lane-scratch-reap.sh --apply, then --list): once
# a lane's window is closed and its id retired, its Claude Code scratch on the
# /tmp tmpfs (/tmp/claude-<uid>/<worktree slug>[-*]/) is removed at once when
# no process holds it; a held dir is listed in the box's workdir table
# (SPL-2110: kept 24 h after the finish), and the disk sweep (csi-spl-utl
# workdir-sweep.sh) removes it then, ONLY when no process holds it. Defects:
# the closed c-232 left 20 GB in its scratch and /tmp reached 93% (sat,
# 2026-10-15); retired lanes' scratch held 12.85 GB of a full /tmp, and the
# reaper run as another user than the scratch owner printed "OK no scratch"
# for every dir of a 0700 root it could not read (2026-10-31, SPL-4680).
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

# 1. the dry run plans the removal of both free dirs and writes nothing.
lane c-201
out="$(bash "$RET" c-201 2>&1)"
check "1. the dry run plans the slug dir's removal" grep -qE "^PLAN scratch +remove [0-9]+KB owner=.* $S/$(slug c-201)\$" <<<"$out"
check "1. ...and the subdir session's" grep -qE "^PLAN scratch +remove [0-9]+KB owner=.* $S/$(slug c-201)-csi-orc\$" <<<"$out"
hasnt "1. ...and lists neither (a free dir is not kept)" "PLAN scratch   list" "$out"
check "1. ...and removes nothing" test -f "$S/$(slug c-201)/sess-1/f"
check "1. ...and writes no table" test ! -e "$TB"

# 2. CONTROL (cwd): the retire removes the free dir at once and keeps the one
#    a process has its cwd in; that one is listed, and 25 h later the sweep
#    keeps it while it is still held.
( cd "$S/$(slug c-201)/sess-1" && exec sleep 600 ) >/dev/null 2>&1 & hold=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold/cwd")" = "$S/$(slug c-201)/sess-1" ] && break; sleep 0.1; done
bash "$RET" --apply c-201 >"$T_TMP/o" 2>&1; eq "2. retire exits 0" 0 "$?"
check "2. the free subdir session's dir is gone at once" test ! -e "$S/$(slug c-201)-csi-orc"
check "2. ...a DO scratch remove line names it" grep -qE "^DO scratch +remove [0-9]+KB owner=.* $S/$(slug c-201)-csi-orc\$" "$T_TMP/o"
check "2. the held dir stays" test -f "$S/$(slug c-201)/sess-1/f"
check "2. ...a KEEP in-use line names it" grep -qF "KEEP in-use $S/$(slug c-201) " "$T_TMP/o"
eq "2. ...and only it is listed as scratch" "$S/$(slug c-201)" "$(awk -F'\t' '$2 == "scratch" && $3 == "c-201" { print $1 }' "$TB")"
out="$(sweep_at 25)"
has "2. 25 h later a held scratch is KEEP in-use" "KEEP in-use (a process has its cwd or an open file under it) scratch $S/$(slug c-201) " "$out"
check "2. ...and stays" test -f "$S/$(slug c-201)/sess-1/f"
kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null

# 3. nobody holds it: the retire removes it at once and lists nothing; a
#    neighbour lane's (c-2011) is never listed nor touched.
lane c-202
bash "$RET" --apply c-202 >"$T_TMP/o" 2>&1; eq "3. retire exits 0" 0 "$?"
check "3. the idle scratch is gone right after the retire" test ! -e "$S/$(slug c-202)"
check "3. ...its subdir session's too" test ! -e "$S/$(slug c-202)-csi-orc"
check "3. ...the DO line names its size" grep -qE "^DO scratch +remove 10[0-9]{2}KB owner=.* $S/$(slug c-202)\$" "$T_TMP/o"
eq "3. ...and no scratch row is written for it" 0 "$(awk -F'\t' '$2 == "scratch" && $3 == "c-202"' "$TB" | wc -l)"
check "3. a lane whose id only starts the same (c-2011) is untouched" test -f "$S/$(slug c-2011)/f"
check "3. ...and was never listed" bash -c "! grep -qF -e '$S/$(slug c-2011)' '$TB'"

# 3b. CONTROL (open fd): a dir a process has a file open under is kept and
#     listed, and the sweep keeps it while held.
lane c-205
( exec 3<"$S/$(slug c-205)/sess-1/f"; exec sleep 600 ) >/dev/null 2>&1 & hold=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold/fd/3" 2>/dev/null)" = "$S/$(slug c-205)/sess-1/f" ] && break; sleep 0.1; done
bash "$RET" --apply c-205 >"$T_TMP/o" 2>&1; eq "3b. retire exits 0" 0 "$?"
check "3b. the dir with an open file stays" test -f "$S/$(slug c-205)/sess-1/f"
eq "3b. ...and is listed as scratch" "$S/$(slug c-205)" "$(awk -F'\t' '$2 == "scratch" && $3 == "c-205" { print $1 }' "$TB")"
check "3b. ...the free subdir session's dir is gone" test ! -e "$S/$(slug c-205)-csi-orc"
has "3b. 25 h later the sweep keeps it" "KEEP in-use (a process has its cwd or an open file under it) scratch $S/$(slug c-205) " "$(sweep_at 25)"
kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null

# 4. RED CONTROL: without step 8 (RETIRE_SCRATCH=0) nothing is removed nor
#    listed, so the sweep never finds it.
lane c-203
RETIRE_SCRATCH=0 bash "$RET" --apply c-203 >/dev/null 2>&1
check "4. CONTROL: RETIRE_SCRATCH=0 leaves the scratch (red)" test -f "$S/$(slug c-203)/sess-1/f"
sweep_at 25 >/dev/null
check "4. ...and lists nothing, so the sweep leaves it too" test -f "$S/$(slug c-203)/sess-1/f"

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

# 7. a /tmp/claude-* root this user cannot read (0700, another user's; here a
#    0000 one of ours, LANE_SCRATCH_SUDO=0: no sudo to its owner) is never
#    an all-clear: a WARN names it and the exit is 3, in every mode.
if [ "$(id -u)" = 0 ]; then echo "skip - 7: root reads every dir"; else
  B="$TR/claude-other"; mkdir -p "$B/$(slug c-206)"; chmod 000 "$B"
  WT6="$T_TMP/wt/c-206"
  out="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" "$WT6" 2>&1)"; eq "7. an unreadable root: exit 3" 3 "$?"
  hasnt "7. ...no OK no scratch line" "OK no scratch" "$out"
  has "7. ...a WARN names the unreadable root" "WARN unreadable $B (owner $(id -un), mode 0)" "$out"
  out="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" --apply "$WT6" 2>&1)"; eq "7. --apply: exit 3" 3 "$?"
  hasnt "7. ...no OK no scratch line" "OK no scratch" "$out"
  lst="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" --list "$WT6" 2>"$T_TMP/e")"; eq "7. --list: exit 3" 3 "$?"
  eq "7. ...stdout holds no path" "" "$lst"
  check "7. ...the WARN goes to stderr" grep -qF "WARN unreadable $B" "$T_TMP/e"
  printf '%s\tclaude\t%%1\t%s\t20261002T080000Z\n' c-206 "$WT6" >>"$R/registry.tsv"; mkdir -p "$R/c-206/inbox"
  bash "$RET" --apply c-206 >"$T_TMP/o" 2>&1; eq "7. a retire still exits 0" 0 "$?"
  check "7. ...and warns that the scratch was not all read" grep -qF "agent-id-retire: WARN the /tmp scratch of $WT6 was not all read" "$T_TMP/o"
  check "7. ...printing the reaper's WARN as a scratch step" grep -qE "^DO scratch +WARN unreadable $B " "$T_TMP/o"
  chmod 755 "$B"
  out="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" "$WT6" 2>&1)"; eq "7. CONTROL: once readable, exit 0" 0 "$?"
  has "7. ...and its scratch is found" "PLAN remove 0KB owner=$(id -un) $B/$(slug c-206)" "$out"
  rm -rf "$B"
  out="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" "$WT6" 2>&1)"
  has "7. CONTROL: no root holds it, readable: OK no scratch" "OK no scratch of $WT6" "$out"
fi

# 8. a registry row whose worktree is not named for the id (/opt, a parent of
#    every lane's worktree) never reaches another lane's scratch: its slug is
#    a prefix of theirs (R7 W1, SPL-4680). The reaper refuses such a path.
mkdir -p "$S/$(slug c-207)/sess-1"; echo x >"$S/$(slug c-207)/sess-1/f"
for wt in "$T_TMP/wt" "$T_TMP" /opt /tmp; do
  out="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" --apply "$wt" 2>&1)"; eq "8. the reaper refuses $wt: exit 2" 2 "$?"
  has "8. ...saying why" "does not end in a lane id" "$out"
done
check "8. ...and another lane's scratch is still there" test -f "$S/$(slug c-207)/sess-1/f"
printf '%s\tclaude\t%%1\t%s\t20261002T080000Z\n' c-208 "$T_TMP/wt" >>"$R/registry.tsv"; mkdir -p "$R/c-208/inbox"
bash "$RET" --apply c-208 >"$T_TMP/o" 2>&1; eq "8. a retire of an id whose worktree is a parent dir exits 0" 0 "$?"
check "8. ...another lane's scratch survives" test -f "$S/$(slug c-207)/sess-1/f"
check "8. ...the retire says it did not reap" grep -qF "scratch of $T_TMP/wt not reaped: its dir is not named c-208" "$T_TMP/o"
hasnt "8. ...and no scratch step ran" "scratch " "$(grep -E '^(DO|PLAN) scratch' "$T_TMP/o")"
out="$(bash "$T_SCRIPTS/lane-scratch-reap.sh" "$T_TMP/wt/c-207" 2>&1)"; eq "8. CONTROL: the lane's own worktree is read, exit 0" 0 "$?"
has "8. ...and its scratch is planned" "PLAN remove" "$out"

t_done
