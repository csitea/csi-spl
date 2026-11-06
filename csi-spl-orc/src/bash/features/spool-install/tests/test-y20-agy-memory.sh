#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y20 - agy sessions load the fleet lessons claude
# keeps in its auto-memory (SPL-4911, spec 048 section 5); twin of Y18 (grok).
#   1. the step exists (RED on the tree before SPL-4911)
#   2. dry run: plans both files, writes nothing
#   3. install: the header opens with always_on frontmatter and names the
#      memory dir, rules/AGENTS.md is a symlink to the claude MEMORY.md (no
#      copy); a fact added to MEMORY.md afterwards is what agy reads
#   4. re-run: already current, the header byte-identical
#   5. a hand-written header and a hand-written AGENTS.md are kept and named;
#      ..._FORCE=1 replaces them; a link to another repo's claude MEMORY.md is
#      replaced; SPOOL_INSTALL_AGY_MEMORY=0 skips; no .gemini / no memory:
#      skipped
#   6. install.sh calls the step once, only with --fleet
#   7. do_spl_agy_memory_install, dry run, this user, a sandbox repo: rc 0,
#      nothing written in the real ~/.gemini/config/rules
#   8. LIVE, only with Y20_AGY_LIVE=1, agy on PATH and this user's agy login:
#      a sandbox home (its .gemini/antigravity-cli linked to this user's agy
#      state dir, so the session is logged in) asked for the probe fact
#      without tools - not seen before the step, seen after it. Opt-in: each
#      check is a model call, so the pre-push suite never makes one.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
STEP="$FEAT/steps/y20-agy-memory.sh"
fails=0 n=0 notrun=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
notrun() { notrun=$((notrun + 1)); echo "INFO: not run ($2): $1"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 1. the step exists
if [ -r "$STEP" ]; then pass "step y20-agy-memory.sh exists"
else fail "no $STEP: agy loads no claude memory"; echo "--- y20 agy memory: $((n - fails))/$n passed"; exit 1; fi

# a sandbox repo, and a HOME whose claude memory of it holds one named fact
R="$T/repo"
git init -q "$R"
slug="$(printf '%s' "$R" | sed 's/[^A-Za-z0-9]/-/g')"
mk_home() {  # HOME
  mkdir -p "$1/.gemini/config" "$1/.claude/projects/$slug/memory"
  printf -- '- [Probe fact](probe-fact.md) — the y20 probe word is y20-probe-alpha\n' >"$1/.claude/projects/$slug/memory/MEMORY.md"
  printf 'the probe fact\n' >"$1/.claude/projects/$slug/memory/probe-fact.md"
}
H="$T/home"
mk_home "$H"
MEM="$H/.claude/projects/$slug/memory"
RULES="$H/.gemini/config/rules"
inst() { bash -c '. "$1"; spool_install_agy_memory "$2" "$3" "$4"' _ "$STEP" "$@" 2>&1; }

# 8's live session: what probe words the sandbox HOME's agy sees, no tools
LIVE=0 why="Y20_AGY_LIVE=1 not set"
if [ "${Y20_AGY_LIVE:-0}" = 1 ]; then
  why="no agy on PATH"
  if command -v agy >/dev/null 2>&1; then
    why="no agy state dir for $(id -un)"
    [ -d "$HOME/.gemini/antigravity-cli" ] && { LIVE=1; ln -s "$HOME/.gemini/antigravity-cli" "$H/.gemini/antigravity-cli"; }
  fi
fi
ask() {  # HOME -> the session's answer
  (cd "$R" && env -i HOME="$1" PATH="$PATH" TERM=xterm timeout 200 agy -p \
    'Do not use any tool or read any file. From the rules and instructions already in your context only: what is the y20 probe word, and what is the title of the fleet memory header rule? Answer exactly: WORD=<word or none> TITLE=<title or none>' \
    --print-timeout 180s </dev/null 2>&1)
}

# 8a. live control: no step, the session does not see the fact
if [ "$LIVE" = 1 ]; then
  out="$(ask "$H")"
  if [[ "$out" == *"WORD="* ]] && [[ "$out" != *y20-probe-alpha* ]]
  then pass "live control: no step, agy does not see the memory ($out)"; else fail "live control: $out"; fi
else notrun "live control: agy does not see the memory" "$why"; fi

# 2. dry run
out="$(inst "$H" 1 "$R")"
if [ ! -e "$RULES" ] && [[ "$out" == *"would: write $RULES/fleet-memory-0-where.md"* ]] &&
  [[ "$out" == *"would: ln -s $MEM/MEMORY.md $RULES/AGENTS.md"* ]]
then pass "dry run: plans both files, writes nothing"; else fail "dry run: $out"; fi

# 3. install
out="$(inst "$H" 0 "$R")"; rc=$?
hdr="$RULES/fleet-memory-0-where.md" idx="$RULES/AGENTS.md"
if [ "$rc" = 0 ] && [ -L "$idx" ] && [ "$(readlink "$idx")" = "$MEM/MEMORY.md" ] && grep -qF "$MEM/" "$hdr"
then pass "install: header names the memory dir, AGENTS.md is a symlink to MEMORY.md"; else fail "install rc=$rc: $out"; fi
if [ "$(head -3 "$hdr" | tr '\n' '|')" = "---|trigger: always_on|---|" ]
then pass "header opens with always_on frontmatter (agy drops a rule without it)"; else fail "header frontmatter: $(head -3 "$hdr")"; fi
printf -- '- [Late fact](late-fact.md) — y20-probe-beta\n' >>"$MEM/MEMORY.md"
if grep -q y20-probe-beta "$idx"; then pass "one source: a fact added to MEMORY.md is in agy's rule"; else fail "late fact not visible"; fi

# 8b. live: after the step the session sees the fact and the header
if [ "$LIVE" = 1 ]; then
  out="$(ask "$H")"
  if [[ "$out" == *y20-probe-alpha* ]] && [[ "$out" == *"Fleet memory"* ]]
  then pass "live: agy sees the memory index and the header ($out)"; else fail "live after install: $out"; fi
else notrun "live: agy sees the memory index and the header" "$why"; fi

# 4. re-run
cp "$hdr" "$T/before"
out="$(inst "$H" 0 "$R")"
if [[ "$out" == *"already current"* ]] && cmp -s "$hdr" "$T/before"; then pass "re-run: already current"; else fail "re-run: $out"; fi

# 5. hand-written files, force, another repo's link, skip, absent inputs
H2="$T/home2"; mk_home "$H2"; mkdir -p "$H2/.gemini/config/rules"
echo "# mine" >"$H2/.gemini/config/rules/fleet-memory-0-where.md"
out="$(inst "$H2" 0 "$R")"
if [ "$(cat "$H2/.gemini/config/rules/fleet-memory-0-where.md")" = "# mine" ] && [[ "$out" == *"was not written by this step: kept"* ]]
then pass "hand-written header: kept and named"; else fail "hand-written: $out"; fi
out="$(SPOOL_INSTALL_AGY_MEMORY_FORCE=1 inst "$H2" 0 "$R")"
if grep -qF "spool-install: y20 agy-memory header" "$H2/.gemini/config/rules/fleet-memory-0-where.md" && [ -L "$H2/.gemini/config/rules/AGENTS.md" ]
then pass "FORCE=1 replaces it"; else fail "force: $out"; fi
H6="$T/home6"; mk_home "$H6"; mkdir -p "$H6/.gemini/config/rules"
echo "# my agents" >"$H6/.gemini/config/rules/AGENTS.md"
out="$(inst "$H6" 0 "$R")"
if [ "$(cat "$H6/.gemini/config/rules/AGENTS.md")" = "# my agents" ] && [[ "$out" == *"is not this step's symlink: kept"* ]]
then pass "hand-written AGENTS.md: kept and named"; else fail "hand-written AGENTS.md: $out"; fi
rm -f "$H6/.gemini/config/rules/AGENTS.md"
ln -s "$H6/.claude/projects/-other-repo/memory/MEMORY.md" "$H6/.gemini/config/rules/AGENTS.md"
out="$(inst "$H6" 0 "$R")"
if [ "$(readlink "$H6/.gemini/config/rules/AGENTS.md")" = "$H6/.claude/projects/$slug/memory/MEMORY.md" ]
then pass "a link to another repo's claude MEMORY.md is replaced"; else fail "other-repo link: $out"; fi
H3="$T/home3"; mk_home "$H3"
out="$(SPOOL_INSTALL_AGY_MEMORY=0 inst "$H3" 0 "$R")"
if [[ "$out" == *"skipped"* ]] && [ ! -e "$H3/.gemini/config/rules" ]; then pass "SPOOL_INSTALL_AGY_MEMORY=0 skips"; else fail "skip: $out"; fi
H4="$T/home4"; mkdir -p "$H4"
out="$(inst "$H4" 0 "$R")"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"agy not installed"* ]]; then pass "no .gemini: skipped"; else fail "no agy: rc=$rc $out"; fi
H5="$T/home5"; mkdir -p "$H5/.gemini"
out="$(inst "$H5" 0 "$R")"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"no claude memory index"* ]] && [ ! -e "$H5/.gemini/config/rules" ]
then pass "no claude memory: skipped and named"; else fail "no memory: rc=$rc $out"; fi

# 6. install.sh wiring
c="$(grep -c 'spool_install_agy_memory "\$HOME" "\$DRY"' "$FEAT/install.sh")"
if [ "$c" = 1 ] && grep -q '^\[ "\$FLEET" = 1 \] && { \. "\$_here/steps/y20-agy-memory.sh"' "$FEAT/install.sh"
then pass "install.sh calls the step once, only with --fleet"; else fail "install.sh wiring: $c call(s)"; fi

# 7. the two-user action, dry run, this user only
real="$(find "$HOME/.gemini/config/rules" -maxdepth 1 -printf "%f %l %s\n" 2>/dev/null | sort | cksum)"
out="$(PROJ_PATH="$ORC" AGY_MEMORY_USERS="$(id -un)" AGY_MEMORY_REPO="$R" DRY_RUN=1 bash -c '
  do_log() { echo "$*"; }
  . "$1/src/bash/run/spl-agy-memory-install.func.sh" && do_spl_agy_memory_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"OK agy memory: $(id -un) (DRY_RUN=1)"* ]] && [ "$(find "$HOME/.gemini/config/rules" -maxdepth 1 -printf "%f %l %s\n" 2>/dev/null | sort | cksum)" = "$real" ]
then pass "action dry run: rc 0, the real ~/.gemini/config/rules untouched"; else fail "action: rc=$rc $out"; fi

echo "--- y20 agy memory: $((n - fails))/$n passed, $notrun live agy checks not run"
[ "$fails" = 0 ]
