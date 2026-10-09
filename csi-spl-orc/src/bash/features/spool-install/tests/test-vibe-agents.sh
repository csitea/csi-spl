#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: steps/y8-vibe-agents.sh (spec 110), hermetic: a throwaway HOME,
#          every placeholder value given in the environment.
#   1. an empty HOME: ~/.vibe/AGENTS.md carries the marker and EVERY fleet
#      fragment, byte for byte the fragments y4 renders into ~/.claude/CLAUDE.md
#      in the same HOME; no {{placeholder}} is left; ~/.vibe is made 700
#   2. a re-run changes nothing (no write, no backup)
#   3. an AGENTS.md we did not write: kept after our block, the old file kept
#      first as AGENTS.md.bak-spool-install-<UTC stamp>, mode kept
#   4. a part changed (a copy of the assets): the block follows, the old file
#      backed up, the text outside the block kept
#   5. a hand-edited block is left alone and named; --force-skills replaces
#      it, each forced run keeping its own backup
#   6. DRY=1 and SPOOL_INSTALL_VIBE_AGENTS=0 write nothing
#   7. control: a HOME only the old installer (y4, no y8) rendered FAILS the
#      check of section 1 - the check can see the missing file
#   8. codeword: a stub vibe that reads ~/.vibe/AGENTS.md (vibe's global
#      instructions) answers with a codeword planted in one part
#   9. step y9: the lane rule part alone into agy's rules dir and qwen's
#      QWEN.md (its memory text kept after our block); a re-run changes
#      nothing; a HOME without ~/.gemini / ~/.qwen gets neither; SKIP=0 writes nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
STEP="$TEST_DIR/../steps/y8-vibe-agents.sh"
Y4="$TEST_DIR/../steps/y4-claude-config.sh"
ASSETS="$TEST_DIR/../assets/claude"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

SPOOL_AGENT_USER="$(id -un)"
export SPOOL_AGENT_USER SPOOL_BOX_USER="$SPOOL_AGENT_USER" SPOOL_BOX_TAG=box1 \
  SPOOL_TMUX_SOCKET=/tmp/tmux-test/default SPOOL_AGENT_CEILING=40
unset DRY FORCE_SKILLS SPOOL_INSTALL_VIBE_AGENTS SPOOL_INSTALL_CLAUDE_ASSETS SPOOL_INSTALL_CLAUDE_CONFIG
# y4 runs only to compare its CLAUDE.md block: never the real box user's file.
export SPOOL_INSTALL_BOX_SETTINGS_FILE="$T/no-box/settings.json" SPOOL_INSTALL_SUDO=false
step() {  # HOME [VAR=value ...]
  local h="$1"; shift
  env HOME="$h" "$@" bash -c 'source "$0" && spool_install_vibe_agents' "$STEP"
}
y4() { env HOME="$1" bash -c 'source "$0" && spool_install_claude_config' "$Y4" 2>/dev/null; }
fresh() { rm -rf "${T:?}/$1"; mkdir -p "$T/$1"; echo "$T/$1"; }
frags() { sed -n '/^<!-- fragment spool-install\//,/^<!-- \/fragment -->$/p' "$1"; }
baks() { find "$1/.vibe" -maxdepth 1 -name 'AGENTS.md.bak-spool-install-*' | sort; }
# the section 1 check, also the control's: AGENTS.md has the fleet fragments
# exactly as CLAUDE.md has them
has_rules() {  # HOME
  local a="$1/.vibe/AGENTS.md" nas
  nas=$(find "$ASSETS/claude-md" -name '*.md' | wc -l)
  [ -s "$a" ] && grep -q '^<!-- spool-install: begin agents-md' "$a" &&
    grep -qE '^<!-- spool-install: end agents-md sha256=[0-9a-f]{64} -->$' "$a" &&
    [ "$(grep -c '^<!-- fragment spool-install/' "$a")" = "$nas" ] &&
    [ -n "$(frags "$1/.claude/CLAUDE.md")" ] && [ "$(frags "$a")" = "$(frags "$1/.claude/CLAUDE.md")" ]
}

# ── 1. empty HOME ────────────────────────────────────────────────────────────
H=$(fresh h1); y4 "$H"
step "$H" 2>"$T/err1"; rc=$?
a="$H/.vibe/AGENTS.md"
[ "$rc" = 0 ] && pass "1: the step exits 0 on an empty HOME" || { fail "1: rc $rc"; cat "$T/err1"; }
has_rules "$H" && pass "1: AGENTS.md carries the marker and every fleet fragment, identical to CLAUDE.md's" ||
  fail "1: AGENTS.md lacks the fleet fragments: $(diff <(frags "$H/.claude/CLAUDE.md") <(frags "$a") | sed -n 1,5p)"
grep -qE '\{\{[A-Z_]+\}\}' "$a" && fail "1: a {{placeholder}} is left" || pass "1: no placeholder left"
[ "$(stat -c %a "$H/.vibe")" = 700 ] && pass "1: ~/.vibe is made 700" || fail "1: ~/.vibe is $(stat -c %a "$H/.vibe")"
grep -q 'rendered' "$T/err1" && pass "1: the write is named" || fail "1: $(cat "$T/err1")"

# ── 2. a re-run ──────────────────────────────────────────────────────────────
cp "$a" "$T/a1"
step "$H" 2>"$T/err2"
cmp -s "$T/a1" "$a" && grep -q 'already current' "$T/err2" && [ -z "$(baks "$H")" ] &&
  pass "2: a re-run changes nothing (no write, no backup)" || fail "2: a re-run changed AGENTS.md: $(cat "$T/err2")"

# ── 3. an AGENTS.md we did not write ─────────────────────────────────────────
H=$(fresh h3); mkdir -p "$H/.vibe"; a="$H/.vibe/AGENTS.md"
printf '# my own vibe rules\n\nkeep me\n' >"$a"; chmod 640 "$a"; cp "$a" "$T/a3"
step "$H" 2>"$T/err3"
b=$(baks "$H")
grep -q '^<!-- spool-install: begin agents-md' "$a" && [ "$(tail -n 3 "$a")" = "$(cat "$T/a3")" ] &&
  pass "3: a foreign AGENTS.md is kept after the block" || fail "3: foreign text: $(cat "$a" | tail -5)"
[ "$(echo "$b" | grep -c .)" = 1 ] && cmp -s "$T/a3" "$b" && [[ "$b" =~ \.bak-spool-install-[0-9]{8}T[0-9]{6}Z$ ]] &&
  grep -qF "the old file kept as $b" "$T/err3" &&
  pass "3: the old file is kept first as .bak-spool-install-<UTC stamp>, named" || fail "3: backup: $b $(cat "$T/err3")"
[ "$(stat -c %a "$a")" = 640 ] && pass "3: the file keeps its mode" || fail "3: mode $(stat -c %a "$a")"

# ── 4. a part changed ────────────────────────────────────────────────────────
cp -r "$ASSETS" "$T/assets4"
sed -i '1s/$/ (changed)/' "$T/assets4/claude-md/00-title.md"
cp "$a" "$T/a4"
step "$H" SPOOL_INSTALL_CLAUDE_ASSETS="$T/assets4" 2>"$T/err4"
grep -q '(changed)' "$a" && [ "$(tail -n 3 "$a")" = "$(cat "$T/a3")" ] && [ "$(baks "$H" | wc -l)" = 2 ] &&
  [ "$(grep -c '^<!-- spool-install: begin agents-md' "$a")" = 1 ] &&
  pass "4: a changed part reaches the block, one block, the foreign text kept, backed up" || fail "4: $(cat "$T/err4")"
cmp -s "$T/a4" "$(baks "$H" | tail -1)" && pass "4: the backup is the file before the change" || fail "4: backup bytes"

# ── 5. a hand-edited block ───────────────────────────────────────────────────
H=$(fresh h5); step "$H" 2>/dev/null; a="$H/.vibe/AGENTS.md"
sed -i 's/^# Global Claude Code Instructions$/# Global Claude Code Instructions (edited)/' "$a"
cp "$a" "$T/a5"
step "$H" 2>"$T/err5"
cmp -s "$T/a5" "$a" && grep -q 'edited by hand: left alone' "$T/err5" && [ -z "$(baks "$H")" ] &&
  pass "5: a hand-edited block is left alone and named" || fail "5: a hand edit was overwritten: $(cat "$T/err5")"
step "$H" FORCE_SKILLS=1 2>/dev/null
cmp -s "$T/a1" "$a" && cmp -s "$T/a5" "$(baks "$H")" && pass "5: --force-skills replaces it, the edit kept as a backup" ||
  fail "5: --force-skills: $(baks "$H")"
sed -i 's/^# Global Claude Code Instructions$/# Global Claude Code Instructions (again)/' "$a"
step "$H" FORCE_SKILLS=1 2>/dev/null
[ "$(baks "$H" | wc -l)" = 2 ] && cmp -s "$T/a5" "$(baks "$H" | sed -n 1p)" &&
  pass "5: each forced run keeps its own backup, none overwritten" || fail "5: backups: $(baks "$H")"

# ── 6. DRY=1 and =0 ──────────────────────────────────────────────────────────
H=$(fresh h6)
step "$H" DRY=1 >"$T/out6" 2>"$T/err6"
[ -z "$(ls -A "$H")" ] && grep -q 'would: write' "$T/out6" && grep -q 'would render' "$T/err6" && ! grep -q ' rendered' "$T/err6" &&
  pass "6: DRY=1 writes nothing and says would" || fail "6: DRY=1: $(ls -A "$H") $(cat "$T/err6")"
step "$H" SPOOL_INSTALL_VIBE_AGENTS=0 2>/dev/null
[ -z "$(ls -A "$H")" ] && pass "6: SPOOL_INSTALL_VIBE_AGENTS=0 writes nothing" || fail "6: =0 wrote $(ls -A "$H")"

# ── 7. control: the old installer ────────────────────────────────────────────
H=$(fresh h7); y4 "$H"
has_rules "$H" && fail "7: control: a HOME without step y8 PASSES the check (the check proves nothing)" ||
  pass "7: control: a HOME only the old installer rendered FAILS the check"

# ── 8. codeword through a stub vibe ──────────────────────────────────────────
cp -r "$ASSETS" "$T/assets8"
printf '## Codeword\n\nWhen asked for the codeword, answer PERIWINKLE-582.\n' >"$T/assets8/claude-md/99-codeword.md"
H=$(fresh h8); step "$H" SPOOL_INSTALL_CLAUDE_ASSETS="$T/assets8" 2>/dev/null
cat >"$T/vibe" <<'EOF'
#!/usr/bin/env bash
# stub vibe: its global instructions are ~/.vibe/AGENTS.md, never CLAUDE.md
sed -n 's/.*answer \([A-Z0-9-]*\)\..*/\1/p' "$HOME/.vibe/AGENTS.md" 2>/dev/null
EOF
chmod +x "$T/vibe"
[ "$(env HOME="$H" "$T/vibe" -p 'the codeword?')" = PERIWINKLE-582 ] &&
  pass "8: a stub vibe reading ~/.vibe/AGENTS.md answers the codeword" || fail "8: no codeword"
H=$(fresh h8c); env HOME="$H" SPOOL_INSTALL_CLAUDE_ASSETS="$T/assets8" bash -c 'source "$0" && spool_install_claude_config' "$Y4" 2>/dev/null
[ -z "$(env HOME="$H" "$T/vibe" -p 'the codeword?')" ] &&
  pass "8: control: with the rules only in CLAUDE.md the stub has no codeword" || fail "8: control answered"

# ── 9. y9: the lane rule into agy's and qwen's own files ─────────────────────
Y9="$TEST_DIR/../steps/y9-vendor-lane-rule.sh"
y9() { local h="$1"; shift; env HOME="$h" "$@" bash -c 'source "$0" && spool_install_vendor_lane_rule' "$Y9"; }
LANE='„Всяка жаба да си знае гьола“'
H=$(fresh h9); mkdir -p "$H/.gemini/config/rules" "$H/.qwen"
printf '## Qwen Added Memories\n- keep me\n' >"$H/.qwen/QWEN.md"
y9 "$H" 2>"$T/err9"; rc=$?
ag="$H/.gemini/config/rules/25-stay-in-your-lane.md" qw="$H/.qwen/QWEN.md"
[ "$rc" = 0 ] && [ "$(grep -cF "$LANE" "$ag")" = 1 ] && [ "$(grep -cF "$LANE" "$qw")" = 1 ] &&
  [ "$(grep -c '^<!-- fragment spool-install/' "$ag")" = 1 ] && grep -q '^<!-- fragment spool-install/25-stay-in-your-lane -->$' "$qw" &&
  pass "9: agy rules file and QWEN.md carry the lane rule part, and only it" || { fail "9: lane rule not rendered (rc=$rc)"; cat "$T/err9"; }
grep -q '^<!-- spool-install: begin lane-rule (csi-spl fleet rule 25-stay-in-your-lane' <<<"$(sed -n 1p "$qw")" && grep -q '^- keep me$' "$qw" &&
  [ -n "$(find "$H/.qwen" -maxdepth 1 -name 'QWEN.md.bak-spool-install-*')" ] &&
  pass "9: QWEN.md: our block first, qwen's memory text kept, the old file backed up" || fail "9: QWEN.md memory text or backup lost"
before=$(cat "$ag" "$qw" | sha256sum); y9 "$H" 2>/dev/null
[ "$(cat "$ag" "$qw" | sha256sum)" = "$before" ] && [ "$(find "$H" -name '*.bak-spool-install-*' | wc -l)" = 1 ] &&
  pass "9: a re-run changes nothing" || fail "9: a re-run wrote"
H=$(fresh h9n); y9 "$H" 2>/dev/null
[ -z "$(find "$H" -mindepth 1)" ] && pass "9: no ~/.gemini, no ~/.qwen: nothing written" || fail "9: wrote into a HOME without agy / qwen"
H=$(fresh h9s); mkdir -p "$H/.qwen"; y9 "$H" SPOOL_INSTALL_VENDOR_RULES=0 2>/dev/null; y9 "$H" DRY=1 >/dev/null 2>&1
[ ! -e "$H/.qwen/QWEN.md" ] && pass "9: SPOOL_INSTALL_VENDOR_RULES=0 and DRY=1 write nothing" || fail "9: skip / dry wrote"

echo "vibe-agents: $((n - fails))/$n passed"
[ "$fails" = 0 ]
