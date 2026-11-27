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

# spec 184 row L2: the brief's Kind: reaches the launcher as SPAWN_TASK_KIND,
# so its by_kind cell picks the model; the live pane gets it through the env list.
printf 'env:\n  box:\n    agent_model:\n      default: { claude: opus }\n      by_kind:\n        tests: { claude: sonnet }\n' > "$T_TMP/model.yaml"
printf '# brief\nKind: tests\n' > "$T_TMP/brief-k.md"
out="$(SPOOL_AGENT_MODEL_CNF="$T_TMP/model.yaml" SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$SW" claude CLE-4442 "$T_TMP/repo" "$T_TMP/brief-k.md" x 2>&1)"
has "L2: the brief's Kind: tests picks the by_kind model" "--model 'sonnet'" "$(grep '^PLAN launch' <<<"$out")"
out="$(SPOOL_AGENT_MODEL_CNF="$T_TMP/model.yaml" SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$SW" claude CLE-4443 "$T_TMP/repo" "$T_TMP/brief.md" x 2>&1)"
has "L2 control: a brief with no Kind: gets the vendor default" "--model 'opus'" "$(grep '^PLAN launch' <<<"$out")"
# R7 W1: a rotation (SPAWN_REUSE_ID=1) starts from a seed with no Kind:; the
# kind the first spawn recorded in lifetime/category.json picks the model,
# and the record is not rewritten.
mkdir -p "$SPOOL_ROOT/CLE-4444/lifetime"
printf '{"work_kind":"tests","category_path":""}\n' > "$SPOOL_ROOT/CLE-4444/lifetime/category.json"
rec="$(cat "$SPOOL_ROOT/CLE-4444/lifetime/category.json")"
out="$(SPAWN_REUSE_ID=1 SPOOL_AGENT_MODEL_CNF="$T_TMP/model.yaml" SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$SW" claude CLE-4444 "$T_TMP/repo" "$T_TMP/brief.md" rotate 2>&1)"
has "W1: a respawn's recorded work_kind tests picks the by_kind model" "--model 'sonnet'" "$(grep '^PLAN launch' <<<"$out")"
eq "W1: the respawn leaves lifetime/category.json as it was" "$rec" "$(cat "$SPOOL_ROOT/CLE-4444/lifetime/category.json")"
eq "W1: the respawn's launch carries --model once" 1 "$(grep '^PLAN launch' <<<"$out" | grep -o -- "--model" | wc -l)"
# R7 round 2 N1: a spaced record (jq's, L3's fixture) reads the same as the compact one.
mkdir -p "$SPOOL_ROOT/CLE-4446/lifetime"
printf '{"work_kind": "tests", "category_path": ""}\n' > "$SPOOL_ROOT/CLE-4446/lifetime/category.json"
out="$(SPAWN_REUSE_ID=1 SPOOL_AGENT_MODEL_CNF="$T_TMP/model.yaml" SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$SW" claude CLE-4446 "$T_TMP/repo" "$T_TMP/brief.md" rotate 2>&1)"
has "N1: a respawn's spaced record work_kind tests picks the by_kind model" "--model 'sonnet'" "$(grep '^PLAN launch' <<<"$out")"
mkdir -p "$SPOOL_ROOT/CLE-4445/lifetime"
out="$(SPAWN_REUSE_ID=1 SPOOL_AGENT_MODEL_CNF="$T_TMP/model.yaml" SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$SW" claude CLE-4445 "$T_TMP/repo" "$T_TMP/brief.md" rotate 2>&1)"
has "W1 control: a respawn with no recorded kind gets the vendor default" "--model 'opus'" "$(grep '^PLAN launch' <<<"$out")"
has "L2: the live pane's env carries SPAWN_TASK_KIND, SPAWN_MODEL and SPAWN_MODEL_MAP" "SPAWN_TASK_KIND SPAWN_MODEL SPAWN_MODEL_MAP" "$(cat "$SW")"

t_done
