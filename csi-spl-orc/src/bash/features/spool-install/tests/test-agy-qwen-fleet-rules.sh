#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: step y9 gives agy and qwen every fleet-rule part that binds their
# seats (SPL-6533), not only 25-stay-in-your-lane. Hermetic: a throwaway HOME.
#   1. a fresh HOME: each Y9_PARTS part (25 AND 28 named) has its own agy
#      rules file, always_on frontmatter first, one fragment; QWEN.md carries
#      each part once, in part order; no Y9_SKIP part, no {{placeholder}}
#   2. each rendered fragment is its part file byte for byte
#   3. a QWEN.md as the old y9 left it (25 only + qwen's memory): one run adds
#      the rest, 25 stays once, the memory is kept, ONE backup (the old file);
#      a re-run writes nothing; no staging dir is left in ~/.qwen
#   4. a hand-edited 28 block in QWEN.md is left alone and named, rc 0
#   5. DRY=1 writes nothing
#   6. every part in claude-md/ is in exactly one of Y9_PARTS / Y9_SKIP, and
#      both lists name only parts that exist
# Control: on the tree before SPL-6533 (y9 renders 25 only), 1 and 3 FAIL.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC2015  # the bash -c body expands in the child; pass || fail
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
Y9="$FEAT/steps/y9-vendor-lane-rule.sh"
MD="$FEAT/assets/claude/claude-md"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset DRY FORCE_SKILLS SPOOL_INSTALL_VENDOR_RULES SPOOL_INSTALL_CLAUDE_ASSETS
y9() { local h="$1"; shift; env HOME="$h" "$@" bash -c 'source "$0" && spool_install_vendor_lane_rule' "$Y9"; }
WANT_PARTS="22-ui-forms-for-user-input 25-stay-in-your-lane 27-lane-issue-and-docs 28-wiki-designated-team-branch 30-cross-lane-findings"
SKIP_PARTS="00-title 05-agents-run-as-agent-user 07-permission-mode-bypass 10-push-and-deploy 20-spawn-an-agent"
frag() { awk -v p="<!-- fragment spool-install/$2 -->" '$0 == p {on = 1; next} on && $0 == "<!-- /fragment -->" {exit} on' "$1"; }

# ── 1. a fresh HOME ───────────────────────────────────────────────────────────
H="$T/h1"; mkdir -p "$H/.gemini" "$H/.qwen"
y9 "$H" 2>"$T/err1"; rc=$?
[ "$rc" = 0 ] && pass "1: y9 exits 0" || { fail "1: y9 rc=$rc"; cat "$T/err1"; }
R="$H/.gemini/config/rules" Q="$H/.qwen/QWEN.md"
for p in 25-stay-in-your-lane 28-wiki-designated-team-branch; do
  [ -f "$R/$p.md" ] && grep -qx "<!-- fragment spool-install/$p -->" "$R/$p.md" && pass "1: agy rules dir has $p" || fail "1: agy rules dir lacks $p"
  [ "$(grep -cx "<!-- fragment spool-install/$p -->" "$Q" 2>/dev/null)" = 1 ] && pass "1: QWEN.md has $p once" || fail "1: QWEN.md lacks $p"
done
ok=1
for p in $WANT_PARTS; do
  [ "$(head -n 3 "$R/$p.md" 2>/dev/null)" = $'---\ntrigger: always_on\n---' ] && [ "$(grep -c '^<!-- fragment ' "$R/$p.md")" = 1 ] || ok=0
done
[ "$ok" = 1 ] && pass "1: each of the 5 parts: its own agy file, frontmatter first, one fragment" || fail "1: an agy part file is missing or wrong"
got=$(grep '^<!-- fragment spool-install/' "$Q" 2>/dev/null | sed 's|^<!-- fragment spool-install/||; s| -->$||' | tr '\n' ' ')
[ "$got" = "$WANT_PARTS " ] && pass "1: QWEN.md carries the 5 parts in part order" || fail "1: QWEN.md parts: '$got'"
bad=0; for p in $SKIP_PARTS; do [ -e "$R/$p.md" ] || grep -q "fragment spool-install/$p " "$Q" 2>/dev/null && bad=1; done
[ "$bad" = 0 ] && pass "1: no Y9_SKIP part rendered" || fail "1: a skipped part was rendered"
! grep -qE '\{\{[A-Z_]+\}\}' "$Q" "$R"/*.md 2>/dev/null && pass "1: no {{placeholder}} left" || fail "1: a placeholder left"

# ── 2. byte for byte ──────────────────────────────────────────────────────────
ok=1
for p in $WANT_PARTS; do
  cmp -s <(frag "$Q" "$p") "$MD/$p.md" && cmp -s <(frag "$R/$p.md" "$p") "$MD/$p.md" || ok=0
done
[ "$ok" = 1 ] && pass "2: every rendered fragment is its part file byte for byte" || fail "2: a fragment differs from its part"

# ── 3. the upgrade of a QWEN.md the old y9 wrote ──────────────────────────────
H="$T/h3"; mkdir -p "$H/.qwen"; Q="$H/.qwen/QWEN.md"
Y8_ONLY=25-stay-in-your-lane Y8_TAG=lane-rule python3 "$FEAT/steps/y8-vibe-agents.py" "$MD" "$Q" 0 0 2>/dev/null
printf '\n## Qwen Added Memories\n- keep me\n' >>"$Q"
old=$(sha256sum <"$Q")
y9 "$H" 2>/dev/null; rc=$?
got=$(grep -c '^<!-- fragment spool-install/' "$Q")
[ "$rc" = 0 ] && [ "$got" = 5 ] && [ "$(grep -cx '<!-- fragment spool-install/25-stay-in-your-lane -->' "$Q")" = 1 ] &&
  pass "3: the old 25-only QWEN.md gets the other 4 parts, 25 stays once" || fail "3: rc=$rc, $got fragments"
grep -qx -- '- keep me' "$Q" && pass "3: qwen's memory text kept" || fail "3: qwen's memory text lost"
baks=$(find "$H/.qwen" -maxdepth 1 -name 'QWEN.md.bak-spool-install-*')
[ "$(printf '%s' "$baks" | grep -c .)" = 1 ] && [ "$(sha256sum <"$baks")" = "$old" ] &&
  pass "3: exactly one backup, and it is the old file" || fail "3: backups: $(printf '%s' "$baks" | grep -c .)"
before=$(sha256sum <"$Q"); y9 "$H" 2>/dev/null
[ "$(sha256sum <"$Q")" = "$before" ] && [ "$(find "$H/.qwen" -name '*.bak-spool-install-*' | wc -l)" = 1 ] &&
  pass "3: a re-run writes nothing" || fail "3: a re-run wrote"
[ -z "$(find "$H/.qwen" -mindepth 1 -maxdepth 1 -name '.y9-stage.*')" ] && pass "3: no staging dir left" || fail "3: a staging dir was left"

# ── 4. a hand-edited block ────────────────────────────────────────────────────
sed -i 's/^## Never add or move a wiki page.*/## my own words/' "$Q"
y9 "$H" 2>"$T/err4"; rc=$?
[ "$rc" = 0 ] && grep -qx '## my own words' "$Q" && grep -q "$Q: the spool-install block was edited by hand" "$T/err4" &&
  pass "4: a hand-edited 28 block is left alone and named" || { fail "4: rc=$rc"; cat "$T/err4"; }

# ── 5. DRY=1 ──────────────────────────────────────────────────────────────────
H="$T/h5"; mkdir -p "$H/.gemini" "$H/.qwen"
y9 "$H" DRY=1 >/dev/null 2>&1
[ -z "$(find "$H" -mindepth 2)" ] && pass "5: DRY=1 writes nothing" || fail "5: DRY=1 wrote: $(find "$H" -mindepth 2)"

# ── 6. every part is placed ───────────────────────────────────────────────────
lists=$(env -i bash -c 'source "$0" && echo "$Y9_PARTS|$Y9_SKIP"' "$Y9")
have=$(find "$MD" -maxdepth 1 -name '[0-9][0-9]-*.md' -printf '%f\n' | sed 's/\.md$//' | sort | tr '\n' ' ')
named=$(echo "${lists//|/ }" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')
dups=$(echo "${lists//|/ }" | tr ' ' '\n' | grep . | sort | uniq -d)
[ "$named" = "$have" ] && [ -z "$dups" ] && pass "6: every part is in exactly one of Y9_PARTS / Y9_SKIP" ||
  fail "6: put each new part in Y9_PARTS (agy + qwen get it) or Y9_SKIP (with its reason): have '$have', named '$named', dups '$dups'"

echo "== y9 agy + qwen fleet rules: $((n - fails))/$n passed"
[ "$fails" = 0 ]
