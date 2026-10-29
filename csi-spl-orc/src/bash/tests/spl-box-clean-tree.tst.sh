#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_clean_tree (SPL-4202, spec 069; box shutdown drill 2026-10-29:
#          the clean-tree loop over every worktree folder read 358 rows,
#          dozens of retired lanes dirty, and hid the live lanes). A fake
#          /proc holds the live agents, registry.tsv names their run dirs, and
#          the worktrees are real git worktrees of a clone of a local bare
#          origin.
#   1. live lanes only in the table: c-101 pushed (registry run dir), c-102
#      dirty (registry run dir), c-103 unpushed (no row: <root>/<id>), a-104
#      no own worktree (n/a); NOT CLEAN: 2 live lanes, exit 3
#   2. the retired folders (a-461 dirty, c-005 unpushed, c-006 clean) are a
#      count line only: 4 scanned, 3 dirty or unpushed; no table row
#   3. CLEAN_TREE_LIST_RETIRED=1 lists the dirty retired ids, the clean one not
#   4. the live lanes pushed: CLEAN, exit 0, though 3 retired stay dirty
#   5. the latest registry row wins: c-101's older row names a dirty dir,
#      which is read as retired
#   6. CLEAN_TREE_LIST_RETIRED=x: FATAL, exit 1
#  Fixtures only in a mktemp root: the test refuses the live /var/spool-hub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
export SPOOL_TEST=1
S="$T/spool"; W="$T/wt"
mkdir -p "$S" "$W" "$T/proc"

G=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master)
"${G[@]}" init -q --bare "$T/origin.git"
"${G[@]}" clone -q "$T/origin.git" "$T/seed" 2>/dev/null
"${G[@]}" -C "$T/seed" commit -q --allow-empty -m seed && "${G[@]}" -C "$T/seed" push -q origin HEAD:master 2>/dev/null
# wt <name> [clean|dirty|unpushed]: a worktree under the root
wt() {
  "${G[@]}" -C "$T/seed" worktree add -q -b "$1" "$W/$1" origin/master 2>/dev/null
  case "${2:-clean}" in
    dirty) echo x >"$W/$1/wip.txt" ;;
    unpushed) "${G[@]}" -C "$W/$1" commit -q --allow-empty -m "local $1" ;;
  esac
}
# agent <pid> <id> [rundir]: a live process carrying SPOOL_AGENT_ID, and its registry row when a rundir is given
agent() {
  mkdir -p "$T/proc/$1"; echo claude >"$T/proc/$1/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$2" >"$T/proc/$1/environ"
  [[ -n "${3:-}" ]] && printf '%s\tclaude\t%%%s\t%s\t20261029T000000Z\n' "$2" "$1" "$3" >>"$S/registry.tsv"
  return 0
}
run() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_WT_ROOT="$W" LEASE_PROC_ROOT="$T/proc" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-box-clean-tree.func.sh"
    do_spl_box_clean_tree' >"$T/o" 2>&1
  echo $? >"$T/rc"
}
rc() { cat "$T/rc"; }
has() { grep -qF -- "$1" "$T/o"; }

wt c-101; wt c-102 dirty; wt c-103 unpushed; wt c-101-old dirty
wt a-461 dirty; wt c-005 unpushed; wt c-006
# c-101's older row names a dirty dir: the latest row must win (case 5)
printf 'c-101\tclaude\t%%90\t%s\t20261001T000000Z\n' "$W/c-101-old" >>"$S/registry.tsv"
agent 101 c-101 "$W/c-101"; agent 102 c-102 "$W/c-102"; agent 103 c-103; agent 104 a-104 "$T/seed"

run
if [[ "$(rc)" == 3 ]] && has "NOT CLEAN: 2 live lanes hold unpushed or dirty work" &&
   has "c-101 | yes | $W/c-101" && has "c-102 | no (0 unpushed, 1 dirty)" &&
   has "c-103 | no (1 unpushed, 0 dirty) | $W/c-103" && has "a-104 | n/a (no own worktree)"; then
  pass "1. live lanes only: c-101 yes, c-102 dirty, c-103 unpushed, a-104 n/a; NOT CLEAN exit 3"
else fail "1. live table / verdict (rc=$(rc)): $(cat "$T/o")"; fi

if has "retired worktrees (no live agent): 4 scanned, 3 dirty or unpushed" &&
   ! grep -qE '^   (a-461|c-005|c-006) \|' "$T/o" && ! has "a-461"; then
  pass "2. retired: one count line (4 scanned, 3 dirty or unpushed), no row, no id"
else fail "2. retired count: $(cat "$T/o")"; fi

run CLEAN_TREE_LIST_RETIRED=1
if has "   a-461 c-005 c-101-old" && ! grep -q 'c-006' "$T/o"; then
  pass "3. CLEAN_TREE_LIST_RETIRED=1 lists a-461 c-005 c-101-old, not the clean c-006"
else fail "3. retired list: $(cat "$T/o")"; fi

rm -f "$W/c-102/wip.txt"; "${G[@]}" -C "$W/c-103" push -q origin HEAD:refs/heads/c-103 2>/dev/null
run
if [[ "$(rc)" == 0 ]] && has "CLEAN: every live lane pushed" && has "4 scanned, 3 dirty or unpushed"; then
  pass "4. live lanes pushed: CLEAN exit 0, the 3 dirty retired do not count"
else fail "4. clean verdict (rc=$(rc)): $(cat "$T/o")"; fi

if has "c-101 | yes | $W/c-101" && ! grep -qE '^   c-101 \|.*c-101-old' "$T/o"; then
  pass "5. the latest registry row wins: c-101 reads its new dir, the older row's dirty dir is retired"
else fail "5. latest row: $(cat "$T/o")"; fi

run CLEAN_TREE_LIST_RETIRED=x
if [[ "$(rc)" == 1 ]] && has "FATAL CLEAN_TREE_LIST_RETIRED must be 0 or 1"; then
  pass "6. a bad CLEAN_TREE_LIST_RETIRED is FATAL, exit 1"
else fail "6. bad flag (rc=$(rc)): $(cat "$T/o")"; fi

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
