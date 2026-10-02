#!/usr/bin/env bash
# spawn-window.sh with SPAWN_DRY_RUN=1 in the CALLER's environment changes
# nothing and prints the plan (CLE-77968). On 2026-10-02 a dry run printed
# "CLE-77966 %373" and really spawned it: id claimed, registry row, worktree,
# a live claude; the real call that followed spawned a duplicate CLE-77967.
#
# Against a throwaway SPOOL_ROOT, a private tmux server, a stub orc ./run for
# the lane map and a throwaway git repo with an origin: the registry, the
# spool dirs, the lane-map calls, the worktree list and the window list are
# the same after the dry run as before it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
# The server env carries NO SPAWN_DRY_RUN: a pane that ran the launcher would
# do so live (and be refused by the sandbox guard) - the point is that no
# pane is made at all.
t_tmux
SW="$T_SCRIPTS/spawn-window.sh"
TM=(tmux -S "$SPOOL_TMUX_SOCKET")
echo brief > "$T_TMP/brief.md"

# The lane map: a stub orc whose ./run logs every call.
ORC="$T_TMP/orc"; mkdir -p "$ORC"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/lane.calls"\n' "$T_TMP" > "$ORC/run"; chmod +x "$ORC/run"
export LANE_MAP_ORC="$ORC"

# A git checkout with an origin, so the plan includes a worktree.
git init -q --bare "$T_TMP/origin.git"
git init -q -b master "$T_TMP/repo"
git -C "$T_TMP/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

printf 'c-004\tclaude\t%%1\t/x\t20260101T000000Z\n' > "$SPOOL_ROOT/registry.tsv"
state() {
  echo "-- registry"; cat "$SPOOL_ROOT/registry.tsv" 2>/dev/null
  echo "-- spool";    (cd "$SPOOL_ROOT" && find . | sort)
  echo "-- lane";     cat "$T_TMP/lane.calls" 2>/dev/null
  echo "-- worktree"; git -C "$T_TMP/repo" worktree list --porcelain
  echo "-- branches"; git -C "$T_TMP/repo" branch --format='%(refname)'
  echo "-- windows";  "${TM[@]}" list-windows -a -F '#{window_name}'
}
before="$(state)"

for title in auto CLE-4441; do
  out="$(SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool timeout 60 bash "$SW" claude "$title" "$T_TMP/repo" "$T_TMP/brief.md" dry-proof 2>&1)"; rc=$?
  eq "$title: dry run exits 0" 0 "$rc"
  eq "$title: registry, spool dirs, lane map, worktrees and windows unchanged" "$before" "$(state)"
  has "$title: plans the id claim" "PLAN claim" "$out"
  has "$title: plans the window" "PLAN window" "$out"
  has "$title: prints the launcher's plan (worktree)" "PLAN worktree   add $T_TMP/repo-wt/" "$out"
  has "$title: prints the launcher's plan (registry)" "PLAN registry" "$out"
  check "$title: no worktree dir on disk" test ! -e "$T_TMP/repo-wt"
done
has "auto: names the id it would take, without claiming it" "PLAN claim      c-005" \
  "$(SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$SW" claude auto "$T_TMP/repo" "$T_TMP/brief.md" x 2>&1)"

t_done
