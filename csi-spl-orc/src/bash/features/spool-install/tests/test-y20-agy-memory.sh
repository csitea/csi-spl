#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y20 - agy sessions load the fleet lessons claude
# keeps in its auto-memory (SPL-4911, spec 048 section 5); twin of Y18 (grok).
#   1. the step exists (RED on the tree before SPL-4911)
#   2. dry run: plans both files, writes nothing
#   3. install: the header opens with always_on frontmatter and names the
#      listed files only, rules/AGENTS.md is a generated file (no symlink) of
#      the listed lines only; a fact is in it only once listed and re-installed
#   4. re-run: already current, both files byte-identical
#   5. the allow-list (default deny, the data rule): no list or an empty list =
#      no index, also over an earlier install and over a symlink to MEMORY.md;
#      a listed file gone = its line dropped and named; a name that is no fact
#      file is refused; a line that also links an unlisted file is dropped
#   6. a hand-written header and a hand-written AGENTS.md are kept and named;
#      ..._FORCE=1 replaces them; a link to another repo's claude MEMORY.md is
#      replaced; SPOOL_INSTALL_AGY_MEMORY=0 skips; no .gemini / no memory:
#      skipped
#   7. install.sh calls the step once, only with --fleet
#   8. do_spl_agy_memory_install, DRY_RUN unset, this user, a sandbox home that
#      holds the memory (getent stubbed): rc 0, plans both files, writes nothing
#      there and nothing in the real ~/.gemini/config/rules
#   9. LIVE, only with Y20_AGY_LIVE=1, agy on PATH and this user's agy login:
#      a sandbox home (its .gemini/antigravity-cli linked to this user's agy
#      state dir, so the session is logged in) asked for the probe facts
#      without tools - none seen before the step, after it the listed one and
#      not the unlisted one. Opt-in: each
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
  printf -- '- [Probe fact](probe-fact.md) — the y20 probe word is y20-probe-alpha\n- [Unlisted fact](unlisted-fact.md) — another y20 probe word is y20-probe-unlisted\n' >"$1/.claude/projects/$slug/memory/MEMORY.md"
  printf 'the probe fact\n' >"$1/.claude/projects/$slug/memory/probe-fact.md"
  printf 'the unlisted fact\n' >"$1/.claude/projects/$slug/memory/unlisted-fact.md"
  printf '# read whole by a claude seat\nprobe-fact.md\n' >"$1/.claude/projects/$slug/memory/agy-allow.list"
}
H="$T/home"
mk_home "$H"
MEM="$H/.claude/projects/$slug/memory"
RULES="$H/.gemini/config/rules"
inst() { bash -c '. "$1"; spool_install_agy_memory "$2" "$3" "$4"' _ "$STEP" "$@" 2>&1; }

# 9's live session: what probe words the sandbox HOME's agy sees, no tools
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
    'Do not use any tool or read any file. From the rules and instructions already in your context only: name every y20 probe word, and what is the title of the fleet memory header rule? Answer exactly: WORDS=<words or none> TITLE=<title or none>' \
    --print-timeout 180s </dev/null 2>&1)
}

# 9a. live control: no step, the session does not see the fact
if [ "$LIVE" = 1 ]; then
  out="$(ask "$H")"
  if [[ "$out" == *"WORDS="* ]] && [[ "$out" != *y20-probe-alpha* ]] && [[ "$out" != *y20-probe-unlisted* ]]
  then pass "live control: no step, agy does not see the memory ($out)"; else fail "live control: $out"; fi
else notrun "live control: agy does not see the memory" "$why"; fi

# 2. dry run
out="$(inst "$H" 1 "$R")"
if [ ! -e "$RULES" ] && [[ "$out" == *"would: write $RULES/fleet-memory-0-where.md"* ]] &&
  [[ "$out" == *"would: write $RULES/AGENTS.md"* ]]
then pass "dry run: plans both files, writes nothing"; else fail "dry run: $out"; fi

# 3. install
out="$(inst "$H" 0 "$R")"; rc=$?
hdr="$RULES/fleet-memory-0-where.md" idx="$RULES/AGENTS.md"
if [ "$rc" = 0 ] && [ -f "$idx" ] && [ ! -L "$idx" ] && grep -q y20-probe-alpha "$idx"
then pass "install: AGENTS.md is a generated file holding the listed line"; else fail "install rc=$rc: $out"; fi
if ! grep -q y20-probe-unlisted "$idx"; then pass "an unlisted line is absent from AGENTS.md"; else fail "unlisted line in the index: $(cat "$idx")"; fi
if [ "$(head -3 "$hdr" | tr '\n' '|')" = "---|trigger: always_on|---|" ]
then pass "header opens with always_on frontmatter (agy drops a rule without it)"; else fail "header frontmatter: $(head -3 "$hdr")"; fi
if grep -qF "probe-fact.md" "$hdr" && ! grep -qF "unlisted-fact.md" "$hdr" && grep -qF "follow no link" "$hdr"
then pass "header names the listed file only and forbids following links out"; else fail "header: $(cat "$hdr")"; fi
printf -- '- [Late fact](late-fact.md) — y20-probe-beta\n' >>"$MEM/MEMORY.md"; printf 'late\n' >"$MEM/late-fact.md"
inst "$H" 0 "$R" >/dev/null
if ! grep -q y20-probe-beta "$idx"; then pass "a new MEMORY.md line stays out until its file is listed"; else fail "late fact reached agy unlisted"; fi
echo late-fact.md >>"$MEM/agy-allow.list"
inst "$H" 0 "$R" >/dev/null
if grep -q y20-probe-beta "$idx" && grep -qF late-fact.md "$hdr"; then pass "one source: the listed fact is in agy's rule after a re-install"; else fail "late fact not visible"; fi

# 9b. live: after the step the session sees the listed fact, not the unlisted
if [ "$LIVE" = 1 ]; then
  out="$(ask "$H")"
  if [[ "$out" == *y20-probe-alpha* ]] && [[ "$out" != *y20-probe-unlisted* ]] && [[ "$out" == *"Fleet memory"* ]]
  then pass "live: agy sees the listed fact and the header, not the unlisted fact ($out)"; else fail "live after install: $out"; fi
else notrun "live: agy sees the memory index and the header" "$why"; fi

# 4. re-run
cp "$hdr" "$T/before"; cp "$idx" "$T/before-idx"
out="$(inst "$H" 0 "$R")"
if [[ "$out" == *"already current"* ]] && cmp -s "$hdr" "$T/before" && cmp -s "$idx" "$T/before-idx"; then pass "re-run: already current"; else fail "re-run: $out"; fi

# 5. the allow-list: default deny
A="$T/homeA"; mk_home "$A"; AM="$A/.claude/projects/$slug/memory"; AR="$A/.gemini/config/rules"
rm "$AM/agy-allow.list"
out="$(inst "$A" 0 "$R")"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$AR/AGENTS.md" ] && [ ! -e "$AR/fleet-memory-0-where.md" ] && [[ "$out" == *"agy gets no index"* ]]
then pass "no list: no index, and the step says so"; else fail "no list rc=$rc: $out"; fi
printf '# nothing read yet\n\n' >"$AM/agy-allow.list"
out="$(inst "$A" 0 "$R")"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$AR/AGENTS.md" ] && [[ "$out" == *"agy gets no index"* ]]
then pass "empty list: no index, and the step says so"; else fail "empty list rc=$rc: $out"; fi
mkdir -p "$AR"; ln -s "$AM/MEMORY.md" "$AR/AGENTS.md"
out="$(inst "$A" 1 "$R")"
if [ -L "$AR/AGENTS.md" ] && [[ "$out" == *"would: remove $AR/AGENTS.md"* ]]
then pass "empty list, dry run: plans the removal, removes nothing"; else fail "deny dry run: $out"; fi
out="$(inst "$A" 0 "$R")"
if [ ! -e "$AR/AGENTS.md" ] && [ ! -L "$AR/AGENTS.md" ]; then pass "empty list: a symlink to the whole MEMORY.md is removed"; else fail "symlink kept: $out"; fi
printf 'probe-fact.md\n' >"$AM/agy-allow.list"
inst "$A" 0 "$R" >/dev/null
rm "$AM/agy-allow.list"
out="$(inst "$A" 0 "$R")"
if [ ! -e "$AR/AGENTS.md" ] && [ ! -e "$AR/fleet-memory-0-where.md" ] && [[ "$out" == *"agy gets no index"* ]]
then pass "list removed after an install: both rules go"; else fail "stale rules kept: $out"; fi
B="$T/homeB"; mk_home "$B"; BM="$B/.claude/projects/$slug/memory"; BR="$B/.gemini/config/rules"
printf 'probe-fact.md\nunlisted-fact.md\n' >"$BM/agy-allow.list"; rm "$BM/unlisted-fact.md"
out="$(inst "$B" 0 "$R")"
if grep -q y20-probe-alpha "$BR/AGENTS.md" && ! grep -q y20-probe-unlisted "$BR/AGENTS.md" && ! grep -qF unlisted-fact.md "$BR/fleet-memory-0-where.md" &&
  [[ "$out" == *"unlisted-fact.md is gone"* ]]
then pass "a listed file gone: its line dropped and named"; else fail "listed gone: $out"; fi
rm "$BM/probe-fact.md"
out="$(inst "$B" 0 "$R")"
if [ ! -e "$BR/AGENTS.md" ] && [[ "$out" == *"probe-fact.md is gone"* ]] && [[ "$out" == *"agy gets no index"* ]]
then pass "every listed file gone: no index"; else fail "all gone: $out"; fi
C="$T/homeC"; mk_home "$C"; CM="$C/.claude/projects/$slug/memory"; CR="$C/.gemini/config/rules"
printf 'MEMORY.md\n../probe-fact.md\n' >"$CM/agy-allow.list"
out="$(inst "$C" 0 "$R")"
if [ ! -e "$CR/AGENTS.md" ] && [[ "$out" == *"MEMORY.md is no fact file name"* ]] && [[ "$out" == *"../probe-fact.md is no fact file name"* ]]
then pass "MEMORY.md and a path on the list: refused and named"; else fail "bad names: $out"; fi
printf 'probe-fact.md\n' >"$CM/agy-allow.list"
printf -- '- [Both](probe-fact.md) and [Other](unlisted-fact.md) — y20-probe-both\nfree text y20-probe-free\n' >>"$CM/MEMORY.md"
inst "$C" 0 "$R" >/dev/null
if ! grep -qE 'y20-probe-(both|free)' "$CR/AGENTS.md"; then pass "a line that also links an unlisted file, and a line with no link: dropped"; else fail "index: $(cat "$CR/AGENTS.md")"; fi
printf 'unlisted-fact.md\n' >"$CM/agy-allow.list"
printf -- '' >"$CM/MEMORY.md"
out="$(inst "$C" 0 "$R")"
if [ ! -e "$CR/AGENTS.md" ] && [[ "$out" == *"unlisted-fact.md has no index line"* ]] && [[ "$out" == *"agy gets no index"* ]]
then pass "a listed file with no index line: named, no index"; else fail "no line: $out"; fi

# 6. hand-written files, force, another repo's link, skip, absent inputs
H2="$T/home2"; mk_home "$H2"; mkdir -p "$H2/.gemini/config/rules"
echo "# mine" >"$H2/.gemini/config/rules/fleet-memory-0-where.md"
out="$(inst "$H2" 0 "$R")"
if [ "$(cat "$H2/.gemini/config/rules/fleet-memory-0-where.md")" = "# mine" ] && [[ "$out" == *"was not written by this step: kept"* ]]
then pass "hand-written header: kept and named"; else fail "hand-written: $out"; fi
out="$(SPOOL_INSTALL_AGY_MEMORY_FORCE=1 inst "$H2" 0 "$R")"
if grep -qF "spool-install: y20 agy-memory header" "$H2/.gemini/config/rules/fleet-memory-0-where.md" && grep -q y20-probe-alpha "$H2/.gemini/config/rules/AGENTS.md"
then pass "FORCE=1 replaces it"; else fail "force: $out"; fi
H6="$T/home6"; mk_home "$H6"; mkdir -p "$H6/.gemini/config/rules"
echo "# my agents" >"$H6/.gemini/config/rules/AGENTS.md"
out="$(inst "$H6" 0 "$R")"
if [ "$(cat "$H6/.gemini/config/rules/AGENTS.md")" = "# my agents" ] && [[ "$out" == *"is not this step's file: kept"* ]]
then pass "hand-written AGENTS.md: kept and named"; else fail "hand-written AGENTS.md: $out"; fi
rm -f "$H6/.gemini/config/rules/AGENTS.md"
ln -s "$H6/.claude/projects/-other-repo/memory/MEMORY.md" "$H6/.gemini/config/rules/AGENTS.md"
out="$(inst "$H6" 0 "$R")"
if [ ! -L "$H6/.gemini/config/rules/AGENTS.md" ] && grep -q y20-probe-alpha "$H6/.gemini/config/rules/AGENTS.md"
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

# 7. install.sh wiring
c="$(grep -c 'spool_install_agy_memory "\$HOME" "\$DRY"' "$FEAT/install.sh")"
if [ "$c" = 1 ] && grep -q '^\[ "\$FLEET" = 1 \] && { \. "\$_here/steps/y20-agy-memory.sh"' "$FEAT/install.sh"
then pass "install.sh calls the step once, only with --fleet"; else fail "install.sh wiring: $c call(s)"; fi

# 8. the two-user action, this user only, its default: DRY_RUN unset, and a home
# that holds the memory, or the step skips before the dry run matters
H7="$T/home7"; mk_home "$H7"
R7="$H7/.gemini/config/rules"
real="$(find "$HOME/.gemini/config/rules" -maxdepth 1 -printf "%f %l %s\n" 2>/dev/null | sort | cksum)"
out="$(env -u DRY_RUN PROJ_PATH="$ORC" AGY_MEMORY_USERS="$(id -un)" AGY_MEMORY_REPO="$R" Y20_SANDBOX_HOME="$H7" bash -c '
  do_log() { echo "$*"; }
  getent() { printf "x:x:0:0::%s:/bin/sh\n" "$Y20_SANDBOX_HOME"; }
  . "$1/src/bash/run/spl-agy-memory-install.func.sh" && do_spl_agy_memory_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"OK agy memory: $(id -un) (DRY_RUN=1)"* ]] &&
  [[ "$out" == *"would: write $R7/fleet-memory-0-where.md"* ]] && [[ "$out" == *"would: write $R7/AGENTS.md"* ]]
then pass "action default is a dry run: rc 0, plans both files"; else fail "action: rc=$rc $out"; fi
if [ ! -e "$R7" ] && [ "$(find "$HOME/.gemini/config/rules" -maxdepth 1 -printf "%f %l %s\n" 2>/dev/null | sort | cksum)" = "$real" ]
then pass "action default writes nothing: the sandbox and the real rules dirs untouched"; else fail "action wrote: $(ls -la "$R7" 2>&1)"; fi

echo "--- y20 agy memory: $((n - fails))/$n passed, $notrun live agy checks not run"
[ "$fails" = 0 ]
