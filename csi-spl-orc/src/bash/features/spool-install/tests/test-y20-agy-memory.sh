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
#      file is refused; a line that also links an unlisted file is dropped; the
#      pin: a listed file edited, or only its index line edited, drops that
#      lesson and names it until it is pinned again; a row without both hashes
#      is refused; a symlink on the list is refused; a trailing "#" comment keeps
#      its row
#   6. a hand-written header and a hand-written AGENTS.md are kept and named, and
#      the step's other file goes (a whole-index symlink too); ..._FORCE=1 replaces
#      them; a link to another repo's claude MEMORY.md is replaced;
#      SPOOL_INSTALL_AGY_MEMORY=0 skips; no .gemini / no memory: skipped, and a
#      memory gone after an install removes the rules; a foreign index that stays
#      is named on every path, and the step then does not say "no index"
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
# The list rows of a fact file, computed here, not by the step under test.
sha() { sha256sum | cut -d' ' -f1; }
pin() {  # MEMDIR NAME
  local fh l
  fh="$(sha <"$1/$2")"
  grep -F "]($2)" "$1/MEMORY.md" | while IFS= read -r l; do
    printf '%s %s %s\n' "$fh" "$(printf '%s' "$l" | sha)" "$2"
  done
}
NOHASH=0000000000000000000000000000000000000000000000000000000000000000
mk_home() {  # HOME
  mkdir -p "$1/.gemini/config" "$1/.claude/projects/$slug/memory"
  printf -- '- [Probe fact](probe-fact.md) — the y20 probe word is y20-probe-alpha\n- [Unlisted fact](unlisted-fact.md) — another y20 probe word is y20-probe-unlisted\n' >"$1/.claude/projects/$slug/memory/MEMORY.md"
  printf 'the probe fact\n' >"$1/.claude/projects/$slug/memory/probe-fact.md"
  printf 'the unlisted fact\n' >"$1/.claude/projects/$slug/memory/unlisted-fact.md"
  { echo '# read whole by a claude seat'; pin "$1/.claude/projects/$slug/memory" probe-fact.md; } >"$1/.claude/projects/$slug/memory/agy-allow.list"
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
if grep -qF "data rule keeps secrets, credentials" "$hdr"; then pass "header states why: the data rule"; else fail "no data-rule reason: $(cat "$hdr")"; fi
if grep -qF "data rule" "$hdr"; then pass "header gives the data rule as the reason"; else fail "header reason: $(cat "$hdr")"; fi
printf -- '- [Late fact](late-fact.md) — y20-probe-beta\n' >>"$MEM/MEMORY.md"; printf 'late\n' >"$MEM/late-fact.md"
inst "$H" 0 "$R" >/dev/null
if ! grep -q y20-probe-beta "$idx"; then pass "a new MEMORY.md line stays out until its file is listed"; else fail "late fact reached agy unlisted"; fi
pin "$MEM" late-fact.md >>"$MEM/agy-allow.list"
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
pin "$AM" probe-fact.md >"$AM/agy-allow.list"
inst "$A" 0 "$R" >/dev/null
rm "$AM/agy-allow.list"
out="$(inst "$A" 0 "$R")"
if [ ! -e "$AR/AGENTS.md" ] && [ ! -e "$AR/fleet-memory-0-where.md" ] && [[ "$out" == *"agy gets no index"* ]]
then pass "list removed after an install: both rules go"; else fail "stale rules kept: $out"; fi
B="$T/homeB"; mk_home "$B"; BM="$B/.claude/projects/$slug/memory"; BR="$B/.gemini/config/rules"
{ pin "$BM" probe-fact.md; pin "$BM" unlisted-fact.md; } >"$BM/agy-allow.list"; rm "$BM/unlisted-fact.md"
out="$(inst "$B" 0 "$R")"
if grep -q y20-probe-alpha "$BR/AGENTS.md" && ! grep -q y20-probe-unlisted "$BR/AGENTS.md" && ! grep -qF unlisted-fact.md "$BR/fleet-memory-0-where.md" &&
  [[ "$out" == *"unlisted-fact.md is gone"* ]]
then pass "a listed file gone: its line dropped and named"; else fail "listed gone: $out"; fi
rm "$BM/probe-fact.md"
out="$(inst "$B" 0 "$R")"
if [ ! -e "$BR/AGENTS.md" ] && [[ "$out" == *"probe-fact.md is gone"* ]] && [[ "$out" == *"agy gets no index"* ]]
then pass "every listed file gone: no index"; else fail "all gone: $out"; fi
C="$T/homeC"; mk_home "$C"; CM="$C/.claude/projects/$slug/memory"; CR="$C/.gemini/config/rules"
printf '%s %s MEMORY.md\n%s %s ../probe-fact.md\n' "$NOHASH" "$NOHASH" "$NOHASH" "$NOHASH" >"$CM/agy-allow.list"
out="$(inst "$C" 0 "$R")"
if [ ! -e "$CR/AGENTS.md" ] && [[ "$out" == *"MEMORY.md is no fact file name"* ]] && [[ "$out" == *"../probe-fact.md is no fact file name"* ]]
then pass "MEMORY.md and a path on the list: refused and named"; else fail "bad names: $out"; fi
printf -- '- [Both](probe-fact.md) and [Other](unlisted-fact.md) — y20-probe-both\n- [Other](unlisted-fact.md) and [Both](probe-fact.md) — y20-probe-first\nfree text y20-probe-free\n' >>"$CM/MEMORY.md"
pin "$CM" probe-fact.md >"$CM/agy-allow.list"
out="$(inst "$C" 0 "$R")"
if grep -q y20-probe-alpha "$CR/AGENTS.md" && ! grep -qE 'y20-probe-(both|first|free)' "$CR/AGENTS.md" && [[ "$out" != *unlisted-fact.md* ]]
then pass "a line that also links an unlisted file, either order, and a line with no link: dropped"; else fail "index: $(cat "$CR/AGENTS.md") $out"; fi
pin "$CM" unlisted-fact.md >"$CM/agy-allow.list"
printf -- '' >"$CM/MEMORY.md"
out="$(inst "$C" 0 "$R")"
if [ ! -e "$CR/AGENTS.md" ] && [[ "$out" == *"unlisted-fact.md has no index line"* ]] && [[ "$out" == *"agy gets no index"* ]]
then pass "a listed file with no index line: named, no index"; else fail "no line: $out"; fi

# 5b. the pin: both hashes, any mismatch drops that lesson until it is read again
P="$T/homeP"; mk_home "$P"; PM="$P/.claude/projects/$slug/memory"; PR="$P/.gemini/config/rules"
pin "$PM" unlisted-fact.md >>"$PM/agy-allow.list"
out="$(inst "$P" 0 "$R")"
if grep -q y20-probe-alpha "$PR/AGENTS.md" && grep -q y20-probe-unlisted "$PR/AGENTS.md"
then pass "pin: both pinned lessons load"; else fail "pin: $out"; fi
want_rows="$(grep -v '^#' "$PM/agy-allow.list")"
got_rows="$(bash -c '. "$1"; spool_install_agy_memory_row "$2" probe-fact.md; spool_install_agy_memory_row "$2" unlisted-fact.md' _ "$STEP" "$PM" 2>&1)"
if [ "$got_rows" = "$want_rows" ]; then pass "spool_install_agy_memory_row prints the rows a seat appends"; else fail "rows: $got_rows"; fi
W="$T/homeW"; mk_home "$W"; WM="$W/.claude/projects/$slug/memory"
printf -- '- [Again](probe-fact.md) — y20-probe-again\n' >>"$WM/MEMORY.md"
before="$(ls -A "$WM" | cksum; cat "$WM"/* | cksum)"
got_rows="$(bash -c '. "$1"; spool_install_agy_memory_row "$2" probe-fact.md' _ "$STEP" "$WM" 2>&1)"
if [ "$(ls -A "$WM" | cksum; cat "$WM"/* | cksum)" = "$before" ]
then pass "the row helper writes nothing: a row goes on the list only by a seat's hand"; else fail "the row helper wrote: $(cat "$WM/agy-allow.list")"; fi
if [ "$got_rows" = "$(pin "$WM" probe-fact.md)" ] && [ "$(wc -l <<<"$got_rows")" = 2 ]
then pass "the row helper prints one row per index line of the file"; else fail "rows of two lines: $got_rows"; fi
cp "$PM/agy-allow.list" "$T/list.good"
printf 'a credential path\n' >>"$PM/unlisted-fact.md"
out="$(inst "$P" 0 "$R")"
if grep -q y20-probe-alpha "$PR/AGENTS.md" && ! grep -q y20-probe-unlisted "$PR/AGENTS.md" && ! grep -qF unlisted-fact.md "$PR/fleet-memory-0-where.md" &&
  [[ "$out" == *"unlisted-fact.md changed since"* ]]
then pass "a listed file edited: that lesson dropped and named, the other kept"; else fail "file edit: $out"; fi
printf 'the unlisted fact\n' >"$PM/unlisted-fact.md"
inst "$P" 0 "$R" >/dev/null
if grep -q y20-probe-unlisted "$PR/AGENTS.md"; then pass "the same file back: the lesson returns"; else fail "file restored"; fi
sed -i 's|another y20 probe word is y20-probe-unlisted|y20-probe-unlisted lives at a credential path|' "$PM/MEMORY.md"
out="$(inst "$P" 0 "$R")"
if grep -q y20-probe-alpha "$PR/AGENTS.md" && ! grep -q y20-probe-unlisted "$PR/AGENTS.md" && ! grep -qF unlisted-fact.md "$PR/fleet-memory-0-where.md" &&
  [[ "$out" == *"unlisted-fact.md: its index line changed since"* ]]
then pass "only the index line edited: that lesson dropped and named, the other kept"; else fail "line edit: $out"; fi
printf -- '- [Two](probe-fact.md) and [Files](unlisted-fact.md) — y20-probe-two\n' >>"$PM/MEMORY.md"
printf '%s %s probe-fact.md\n' "$(sha <"$PM/probe-fact.md")" "$(tail -1 "$PM/MEMORY.md" | tr -d '\n' | sha)" >>"$PM/agy-allow.list"
out="$(inst "$P" 0 "$R")"
if ! grep -q y20-probe-two "$PR/AGENTS.md" && [[ "$out" == *"unlisted-fact.md: its index line changed since"* ]]
then pass "a line of two listed files, pinned for one: dropped and the other named"; else fail "two links: $out"; fi
printf -- '- [Second line](probe-fact.md) — y20-probe-secondline\n' >>"$PM/MEMORY.md"
out="$(inst "$P" 0 "$R")"
if grep -q y20-probe-alpha "$PR/AGENTS.md" && ! grep -q y20-probe-secondline "$PR/AGENTS.md" && [[ "$out" == *"probe-fact.md: its index line changed since"* ]]
then pass "a second, unpinned line of a listed file: dropped and named, the pinned line kept"; else fail "second line: $out"; fi
printf 'probe-fact.md\n%s probe-fact.md\n%s %s probe-fact.md extra\nnothex %s probe-fact.md\n%s nothex probe-fact.md\n' "$NOHASH" "$NOHASH" "$NOHASH" "$NOHASH" "$NOHASH" >"$PM/agy-allow.list"
out="$(inst "$P" 0 "$R")"
if [ ! -e "$PR/AGENTS.md" ] && [ "$(grep -c 'is no row' <<<"$out")" = 5 ] && [[ "$out" == *"agy gets no index"* ]]
then pass "a row without both hashes is refused and named: no index"; else fail "bad rows: $out"; fi

# 5c. the filter: any link decides, the header follows the lines, comments, symlinks
Q="$T/homeQ"; mk_home "$Q"; QM="$Q/.claude/projects/$slug/memory"; QR="$Q/.gemini/config/rules"
printf -- '- [Other](unlisted-fact.md) and [Both](probe-fact.md) — y20-probe-first\n' >>"$QM/MEMORY.md"
printf 'no line\n' >"$QM/noline-fact.md"
{ pin "$QM" probe-fact.md | sed 's/$/  # read by a seat/'; echo "# $NOHASH $NOHASH unlisted-fact.md"
  printf '%s %s noline-fact.md\n' "$(sha <"$QM/noline-fact.md")" "$NOHASH"; } >"$QM/agy-allow.list"
out="$(inst "$Q" 0 "$R")"
if grep -q y20-probe-alpha "$QR/AGENTS.md" && ! grep -q y20-probe-first "$QR/AGENTS.md"
then pass "a pinned line with an unlisted link first and a listed link last: dropped"; else fail "first link: $out"; fi
if grep -qF probe-fact.md "$QR/fleet-memory-0-where.md" && ! grep -qF noline-fact.md "$QR/fleet-memory-0-where.md" && [[ "$out" == *"noline-fact.md has no index line"* ]]
then pass "the header names only files with a line, the other is named"; else fail "header follows lines: $out"; fi
if [[ "$out" != *"is no row"* ]] && ! grep -q y20-probe-unlisted "$QR/AGENTS.md"
then pass "a comment after a row and a commented-out row are comments"; else fail "comments: $out"; fi
L="$T/homeL"; mk_home "$L"; LM="$L/.claude/projects/$slug/memory"; LR="$L/.gemini/config/rules"
ln -s "$LM/MEMORY.md" "$LM/alias.md"
printf -- '- [Alias](alias.md) — y20-probe-alias\n' >>"$LM/MEMORY.md"
pin "$LM" alias.md >>"$LM/agy-allow.list"
out="$(inst "$L" 0 "$R")"
if grep -q y20-probe-alpha "$LR/AGENTS.md" && ! grep -q y20-probe-alias "$LR/AGENTS.md" && ! grep -qF alias.md "$LR/fleet-memory-0-where.md" && [[ "$out" == *"alias.md is a symlink"* ]]
then pass "a listed name that is a symlink: refused and named"; else fail "symlink name: $out"; fi
out="$(bash -c '. "$1"; spool_install_agy_memory_row "$2" alias.md' _ "$STEP" "$LM" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && ! grep -qE '^[0-9a-f]{64} ' <<<"$out" && [[ "$out" == *"is a symlink"* ]]; then pass "the row helper refuses a symlink"; else fail "row of a symlink rc=$rc: $out"; fi

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
# A foreign file blocks the install: the step's other file goes, nothing of the
# whole index or of an older listing stays behind it.
F="$T/homeF"; mk_home "$F"; FM="$F/.claude/projects/$slug/memory"; FR="$F/.gemini/config/rules"; mkdir -p "$FR"
echo "# mine" >"$FR/fleet-memory-0-where.md"
ln -s "$FM/MEMORY.md" "$FR/AGENTS.md"
out="$(inst "$F" 1 "$R")"
if [ -L "$FR/AGENTS.md" ] && [[ "$out" == *"would: remove $FR/AGENTS.md"* ]]
then pass "foreign header + whole-index symlink, dry run: plans the removal, removes nothing"; else fail "foreign header dry: $out"; fi
out="$(inst "$F" 0 "$R")"
if [ ! -e "$FR/AGENTS.md" ] && [ ! -L "$FR/AGENTS.md" ] && [ "$(cat "$FR/fleet-memory-0-where.md")" = "# mine" ] && [[ "$out" == *"was not written by this step: kept"* ]]
then pass "foreign header + whole-index symlink: the symlink goes, the header stays"; else fail "foreign header: $out"; fi
ln -s "$FR/whole-link" "$FR/AGENTS.md"; ln -s "$FM/MEMORY.md" "$FR/whole-link"
inst "$F" 0 "$R" >/dev/null
if [ ! -e "$FR/AGENTS.md" ] && [ ! -L "$FR/AGENTS.md" ]; then pass "a chain of links to the whole MEMORY.md goes too"; else fail "chain kept: $(readlink "$FR/AGENTS.md")"; fi
rm -f "$FR/whole-link" "$FR/fleet-memory-0-where.md"
inst "$F" 0 "$R" >/dev/null
grep -q y20-probe-alpha "$FR/AGENTS.md" || fail "foreign header: no index once the header is gone"
echo "# mine" >"$FR/fleet-memory-0-where.md"
inst "$F" 0 "$R" >/dev/null
if [ ! -e "$FR/AGENTS.md" ]; then pass "foreign header over an earlier generated index: the index goes"; else fail "stale index stays: $(cat "$FR/AGENTS.md")"; fi
rm -f "$FR/fleet-memory-0-where.md"
inst "$F" 0 "$R" >/dev/null
echo "# my agents" >"$FR/AGENTS.md"
: >"$FM/probe-fact.md"
pin "$FM" probe-fact.md >"$FM/agy-allow.list"
inst "$F" 0 "$R" >/dev/null
if [ ! -e "$FR/fleet-memory-0-where.md" ] && [ "$(cat "$FR/AGENTS.md")" = "# my agents" ]
then pass "hand-written AGENTS.md: the step's header goes, it names no file for an index it cannot write"; else fail "header stays: $(ls "$FR")"; fi
# A foreign index stays on every path: it is named, and agy does load it, so the
# step never says "no index" over it.
N="$T/homeN"; mk_home "$N"; NM="$N/.claude/projects/$slug/memory"; NR="$N/.gemini/config/rules"; mkdir -p "$NR"
cp "$NM/MEMORY.md" "$NR/AGENTS.md"; cp "$NM/agy-allow.list" "$T/list.N"; rm "$NM/agy-allow.list"
for d in 1 0; do
  out="$(inst "$N" "$d" "$R")"
  if grep -q y20-probe-unlisted "$NR/AGENTS.md" && [[ "$out" == *"$NR/AGENTS.md is not this step's file: kept"* ]] && [[ "$out" != *"agy gets no index"* ]]
  then pass "no list, a foreign AGENTS.md, dry=$d: kept, named, no claim of no index"; else fail "deny over a foreign index dry=$d: $out"; fi
done
echo "# mine" >"$NR/fleet-memory-0-where.md"
out="$(inst "$N" 0 "$R")"
if [ "$(cat "$NR/fleet-memory-0-where.md")" = "# mine" ] && [[ "$out" == *"fleet-memory-0-where.md was not written by this step: kept"* ]]
then pass "no list, a foreign header: kept and named"; else fail "deny over a foreign header: $out"; fi
cp "$T/list.N" "$NM/agy-allow.list"
out="$(inst "$N" 0 "$R")"
if [[ "$out" == *"fleet-memory-0-where.md was not written by this step: kept"* ]] && [[ "$out" == *"$NR/AGENTS.md is not this step's file: kept"* ]]
then pass "a filled list, both files foreign: both named"; else fail "both foreign: $out"; fi
rm "$NR/fleet-memory-0-where.md" "$NM/MEMORY.md"
out="$(inst "$N" 0 "$R")"
if grep -q y20-probe-unlisted "$NR/AGENTS.md" && [[ "$out" == *"no claude memory index"* ]] && [[ "$out" == *"$NR/AGENTS.md is not this step's file: kept"* ]] && [[ "$out" != *"agy gets no index"* ]]
then pass "no MEMORY.md, a foreign AGENTS.md: kept, named, no claim of no index"; else fail "no memory over a foreign index: $out"; fi
G="$T/homeG"; mk_home "$G"; GM="$G/.claude/projects/$slug/memory"; GR="$G/.gemini/config/rules"
inst "$G" 0 "$R" >/dev/null
rm "$GM/MEMORY.md"
out="$(inst "$G" 1 "$R")"
if [ -f "$GR/AGENTS.md" ] && [[ "$out" == *"would: remove $GR/AGENTS.md"* ]]
then pass "MEMORY.md gone, dry run: plans the removal, removes nothing"; else fail "memory gone dry: $out"; fi
out="$(inst "$G" 0 "$R")"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$GR/AGENTS.md" ] && [ ! -e "$GR/fleet-memory-0-where.md" ] && [[ "$out" == *"no claude memory index"* ]]
then pass "MEMORY.md gone after an install: both rules go, and the step says so"; else fail "memory gone rc=$rc: $out"; fi
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
