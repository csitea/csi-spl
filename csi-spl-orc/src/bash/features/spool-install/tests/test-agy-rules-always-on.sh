#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: agy loads a ~/.gemini/config/rules/*.md only when the file opens
# with "trigger: always_on" frontmatter (SPL-5106; without it the log says
# "Invalid rule trigger" and the text never reaches the model).
#   1. y9, y14 and y6 run in a sandbox HOME: every file they put in the agy
#      rules dir (four, the graft link followed) opens with the frontmatter
#   2. a live file from before the frontmatter gets it on the next run, once,
#      with the old file backed up; qwen's file gets none
#   3. the asset sources carry it, so an install from them does too
#   4. no step writes the rules dir but y6, y9, y14 and y20 (y20's header has
#      its own test; its rules/AGENTS.md loads without frontmatter)
# Control: on the tree before SPL-5106, 1, 2 and 3 FAIL (no frontmatter).
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC2015  # the bash -c bodies expand in the child; pass || fail
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
WANT=$'---\ntrigger: always_on\n---'
opens() { [ "$(head -n 3 "$1" 2>/dev/null)" = "$WANT" ]; }
y9() { env HOME="$1" bash -c 'source "$0" && spool_install_vendor_lane_rule' "$FEAT/steps/y9-vendor-lane-rule.sh"; }
y14() { env HOME="$1" bash -c 'source "$0" && spool_install_agy_exit_rule' "$FEAT/steps/y14-agy-exit-rule.sh"; }
y6() { env HOME="$1" bash -c 'source "$0" && y6_graft_install "$1" "$2" 0' "$FEAT/steps/y6-graft.sh" "$ORC" "$1/bin"; }

# ── 1. every file the steps write ─────────────────────────────────────────────
H="$T/h1"; mkdir -p "$H/.gemini" "$H/bin"
y9 "$H" 2>"$T/err" && y14 "$H" 2>>"$T/err" && y6 "$H" 2>>"$T/err" || fail "1: a step failed: $(cat "$T/err")"
R="$H/.gemini/config/rules"
got=$(find "$R" -mindepth 1 -maxdepth 1 | wc -l)
[ "$got" = 4 ] && pass "1: the steps put 4 files in the rules dir" || fail "1: expected 4 files, got $got"
for f in "$R"/*; do
  opens "$f" && pass "1: ${f##*/} opens with trigger: always_on" || fail "1: ${f##*/} has no frontmatter: $(head -n 1 "$f")"
done

# ── 2. the upgrade of a file from before the frontmatter ──────────────────────
H="$T/h2"; mkdir -p "$H/.gemini" "$H/.qwen"
y9 "$H" 2>/dev/null
L="$H/.gemini/config/rules/25-stay-in-your-lane.md"
if opens "$L"; then sed -i '1,3d' "$L"; fi
[[ "$(head -n 1 "$L")" == '<!-- spool-install: begin lane-rule'* ]] || fail "2: the setup did not leave a file from before the frontmatter"
y9 "$H" 2>/dev/null
opens "$L" && pass "2: an old lane rule file gets the frontmatter" || fail "2: the old file was not upgraded"
[ "$(grep -c '^trigger: always_on$' "$L")" = 1 ] && pass "2: exactly once" || fail "2: frontmatter count is not 1"
[ -n "$(find "$H/.gemini/config/rules" -name '*.bak-spool-install-*')" ] && pass "2: the old file is backed up" || fail "2: no backup"
before=$(sha256sum <"$L"); y9 "$H" 2>/dev/null
[ "$(sha256sum <"$L")" = "$before" ] && pass "2: a re-run changes nothing" || fail "2: a re-run wrote"
! grep -q 'trigger: always_on' "$H/.qwen/QWEN.md" && pass "2: QWEN.md carries no agy frontmatter" || fail "2: frontmatter leaked into QWEN.md"

# ── 3. the sources ────────────────────────────────────────────────────────────
for f in "$FEAT"/assets/agy/rules/*.md "$ORC/src/bash/features/graft/assets/agy-rules/graft.md"; do
  opens "$f" && pass "3: source ${f##*/} opens with it" || fail "3: source ${f##*/} has no frontmatter"
done

# ── 4. no other writer of the rules dir ───────────────────────────────────────
w=$(grep -lE '\.gemini/config/rules' "$FEAT"/steps/* | xargs -n1 basename | sort | tr '\n' ' ')
[ "$w" = "y14-agy-exit-rule.sh y20-agy-memory.sh y6-graft.sh y9-vendor-lane-rule.sh " ] && pass "4: the writers are y6, y9, y14, y20" ||
  fail "4: a new writer of the agy rules dir, give it the frontmatter and add it here: $w"

echo "== agy rules always_on: $((n - fails))/$n passed"
[ "$fails" = 0 ]
