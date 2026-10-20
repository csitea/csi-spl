#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y18 - grok sessions load the fleet lessons claude
# keeps in its auto-memory (SPL-2738, spec 048 section 5).
#   1. the step exists (RED on the tree before SPL-2738)
#   2. CONTROL: a sandbox HOME with a claude memory index and a .grok, no
#      step: `grok inspect` lists no memory rule - grok misses the lessons
#   3. dry run: plans both files, writes nothing
#   4. install: the header names the memory dir, the index is a symlink to
#      the claude MEMORY.md (no copy); `grok inspect` lists both rules and a
#      fact added to MEMORY.md afterwards is what grok reads (one source)
#   5. re-run: already current, the header byte-identical
#   6. a hand-written header is kept and named; ..._FORCE=1 replaces it;
#      SPOOL_INSTALL_GROK_MEMORY=0 skips; no .grok / no memory: skipped
#   7. install.sh calls the step once, only with --fleet
#   8. do_spl_grok_memory_install, dry run, this user, a sandbox repo: rc 0,
#      nothing written in the real ~/.grok/rules
# The `grok inspect` checks run only with grok on PATH (a dev box); without
# it they print one INFO line and count nothing (CI's runners have no grok,
# and its orc job refuses a SKIP line).
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
STEP="$FEAT/steps/y18-grok-memory.sh"
fails=0 n=0 notrun=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
notrun() { notrun=$((notrun + 1)); echo "INFO: not run (no grok on PATH): $1"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 1. the step exists
if [ -r "$STEP" ]; then pass "step y18-grok-memory.sh exists"
else fail "no $STEP: grok loads no claude memory"; echo "--- y18 grok memory: $((n - fails))/$n passed"; exit 1; fi

# a sandbox repo, and a HOME whose claude memory of it holds one named fact
R="$T/repo"
git init -q "$R"
slug="$(printf '%s' "$R" | sed 's/[^A-Za-z0-9]/-/g')"
mk_home() {  # HOME
  mkdir -p "$1/.grok" "$1/.claude/projects/$slug/memory"
  printf -- '- [Probe fact](probe-fact.md) — y18-probe-alpha\n' >"$1/.claude/projects/$slug/memory/MEMORY.md"
  printf 'the probe fact\n' >"$1/.claude/projects/$slug/memory/probe-fact.md"
}
H="$T/home"
mk_home "$H"
MEM="$H/.claude/projects/$slug/memory"
inst() { bash -c '. "$1"; spool_install_grok_memory "$2" "$3" "$4"' _ "$STEP" "$@" 2>&1; }
HAVE_GROK=0
command -v grok >/dev/null 2>&1 && HAVE_GROK=1
inspect() { (cd "$R" && env -i HOME="$1" PATH="$PATH" TERM=xterm timeout 60 grok inspect 2>&1); }

# 2. control
if [ "$HAVE_GROK" = 1 ]; then
  out="$(inspect "$H")"
  if [[ "$out" == *"Project Instructions"* ]] && [[ "$out" != *fleet-memory* ]]
  then pass "control: no step, grok inspect lists no memory rule"; else fail "control: $out"; fi
else notrun "control: grok inspect lists no memory rule"; fi

# 3. dry run
out="$(inst "$H" 1 "$R")"
if [ ! -e "$H/.grok/rules" ] && [[ "$out" == *"would: write $H/.grok/rules/fleet-memory-0-where.md"* ]] &&
  [[ "$out" == *"would: ln -s $MEM/MEMORY.md $H/.grok/rules/fleet-memory-1-index.md"* ]]
then pass "dry run: plans both files, writes nothing"; else fail "dry run: $out"; fi

# 4. install
out="$(inst "$H" 0 "$R")"; rc=$?
hdr="$H/.grok/rules/fleet-memory-0-where.md" idx="$H/.grok/rules/fleet-memory-1-index.md"
if [ "$rc" = 0 ] && [ -L "$idx" ] && [ "$(readlink "$idx")" = "$MEM/MEMORY.md" ] && grep -qF "$MEM/" "$hdr"
then pass "install: header names the memory dir, index is a symlink to MEMORY.md"; else fail "install rc=$rc: $out"; fi
printf -- '- [Late fact](late-fact.md) — y18-probe-beta\n' >>"$MEM/MEMORY.md"
if grep -q y18-probe-beta "$idx"; then pass "one source: a fact added to MEMORY.md is in grok's rule"; else fail "late fact not visible"; fi
if [ "$HAVE_GROK" = 1 ]; then
  out="$(inspect "$H")"
  if [[ "$out" == *"$hdr"* ]] && [[ "$out" == *"$idx"* ]]
  then pass "grok inspect lists both memory rules"; else fail "grok inspect after install: $out"; fi
else notrun "grok inspect lists both memory rules"; fi

# 5. re-run
cp "$hdr" "$T/before"
out="$(inst "$H" 0 "$R")"
if [[ "$out" == *"already current"* ]] && cmp -s "$hdr" "$T/before"; then pass "re-run: already current"; else fail "re-run: $out"; fi

# 6. hand-written header, force, skip, absent inputs
H2="$T/home2"; mk_home "$H2"; mkdir -p "$H2/.grok/rules"
echo "# mine" >"$H2/.grok/rules/fleet-memory-0-where.md"
out="$(inst "$H2" 0 "$R")"
if [ "$(cat "$H2/.grok/rules/fleet-memory-0-where.md")" = "# mine" ] && [[ "$out" == *"was not written by this step: kept"* ]]
then pass "hand-written header: kept and named"; else fail "hand-written: $out"; fi
out="$(SPOOL_INSTALL_GROK_MEMORY_FORCE=1 inst "$H2" 0 "$R")"
if grep -qF "spool-install: y18 grok-memory header" "$H2/.grok/rules/fleet-memory-0-where.md" && [ -L "$H2/.grok/rules/fleet-memory-1-index.md" ]
then pass "FORCE=1 replaces it"; else fail "force: $out"; fi
H3="$T/home3"; mk_home "$H3"
out="$(SPOOL_INSTALL_GROK_MEMORY=0 inst "$H3" 0 "$R")"
if [[ "$out" == *"skipped"* ]] && [ ! -e "$H3/.grok/rules" ]; then pass "SPOOL_INSTALL_GROK_MEMORY=0 skips"; else fail "skip: $out"; fi
H4="$T/home4"; mkdir -p "$H4"
out="$(inst "$H4" 0 "$R")"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"grok not installed"* ]]; then pass "no .grok: skipped"; else fail "no grok: rc=$rc $out"; fi
H5="$T/home5"; mkdir -p "$H5/.grok"
out="$(inst "$H5" 0 "$R")"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"no claude memory index"* ]] && [ ! -e "$H5/.grok/rules" ]
then pass "no claude memory: skipped and named"; else fail "no memory: rc=$rc $out"; fi

# 7. install.sh wiring
c="$(grep -c 'spool_install_grok_memory "\$HOME" "\$DRY"' "$FEAT/install.sh")"
if [ "$c" = 1 ] && grep -q '^\[ "\$FLEET" = 1 \] && { \. "\$_here/steps/y18-grok-memory.sh"' "$FEAT/install.sh"
then pass "install.sh calls the step once, only with --fleet"; else fail "install.sh wiring: $c call(s)"; fi

# 8. the two-user action, dry run, this user only
real="$(find "$HOME/.grok/rules" -maxdepth 1 -printf "%f %l %s\n" 2>/dev/null | sort | cksum)"
out="$(PROJ_PATH="$ORC" GROK_MEMORY_USERS="$(id -un)" GROK_MEMORY_REPO="$R" DRY_RUN=1 bash -c '
  do_log() { echo "$*"; }
  . "$1/src/bash/run/spl-grok-memory-install.func.sh" && do_spl_grok_memory_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"OK grok memory: $(id -un) (DRY_RUN=1)"* ]] && [ "$(find "$HOME/.grok/rules" -maxdepth 1 -printf "%f %l %s\n" 2>/dev/null | sort | cksum)" = "$real" ]
then pass "action dry run: rc 0, the real ~/.grok/rules untouched"; else fail "action: rc=$rc $out"; fi

echo "--- y18 grok memory: $((n - fails))/$n passed, $notrun grok checks not run"
[ "$fails" = 0 ]
