#!/usr/bin/env bash
# rotate-stalled.tst.sh - spl_rotate_stalled reads the CLI footer only (SPL-3483)
#
# FR-009 (spec 060) skips a rotation on a stalled pane. On 2026-10-25 the
# 21:05Z orch rotation was skipped as "stalled limit resets" while c-001 was
# working: its own reply text quoted the phrase, and the old check grepped
# the last 8 non-blank rows of the whole pane. Cases, with a stubbed
# spl_rotate_screen (no tmux, no live pane):
#   (a) reply text above the input rule quoting a banner: not stalled;
#       also a prompt line holding the phrase, between the two rules
#   (b) a usage-limit banner below the input box: stalled, its text printed
#   (c) a /login banner in the footer, a full-screen login picker and a
#       trust screen: stalled
#   (d) blank-line padding below and between the footer rows; an empty pane
#   (e) a screen with no rule at all reads as before (the rotate tests' form)
#
# Run: bash csi-spl-orc/src/bash/tests/rotate-stalled.tst.sh </dev/null
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export SPOOL_ROOT="$T/spool"
# shellcheck source=/dev/null
source "$HERE/../run/spl-rotate-lib.func.sh"
# the stub: the screen of pane P is the file $T/screen.P
spl_rotate_screen() { cat "$T/screen.$1" 2>/dev/null || true; }

RULE='────────────────────────────────────────────────────────────'
# expect NAME PANE WANT: spl_rotate_stalled PANE prints exactly WANT
expect() {
  local got
  got="$(spl_rotate_stalled "$2")"
  [[ "$got" == "$3" ]] && pass "$1 -> '${got}'" || fail "$1: want '$3', got '$got'"
}

# (a) c-001's reply quotes the banner; the footer is the normal status line
printf '%s\n' \
  '● Rotation 20261025T2105Z-orch was skipped: rotate.log says "stalled limit resets".' \
  '  The pane shows "Usage limit reached · limit resets 7:20am" only in this reply,' \
  '  and the limit resets on Monday at 09:00Z.' \
  '✻ Crunched for 4s' '' \
  "$RULE" '❯ ' "$RULE" \
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)' > "$T/screen.a"
expect "(a) reply text above the input rule quotes 'limit resets'" a ''
printf '%s\n' '● done' '' "$RULE" '❯ the owner wrote: usage limit reached, please run /login' "$RULE" \
  '  ⏵⏵ bypass permissions on (shift+tab to cycle)' > "$T/screen.a2"
expect "(a) the phrase in the prompt line, between the two rules" a2 ''
printf '%s\n' '● Quote: "Do you trust the files in this folder?" and "Select login method:"' '' \
  "$RULE" '❯ ' "$RULE" '  ⏵⏵ bypass permissions on' > "$T/screen.a3"
expect "(a) a modal title quoted in the transcript" a3 ''

# (b) the real banner under the input box (the CLE-77935 layout)
printf '%s\n' '● working' '' \
  '──────────────────────────────────────────────── box: CLE-002 ─' \
  '❯ [channel post from HUM-10, topic 5fe56859] a' "$RULE" \
  '  ⚠ Usage limit reached · limit resets 7:20am' \
  '  ⏵⏵ auto mode on · 3 monitors' > "$T/screen.b"
expect "(b) a usage-limit banner in the footer" b 'Usage limit reached'
printf '%s\n' '● ok' "$RULE" '❯ ' "$RULE" \
  "  You've hit your session limit · resets 8:20pm (Europe/Helsinki)" > "$T/screen.b2"
expect "(b) claude's 2026-10-10 wording in the footer" b2 "You've hit your session limit"

# (c) /login and modal screens
printf '%s\n' '● ok' "$RULE" '❯ ' "$RULE" '  Login expired · Please run /login' > "$T/screen.c"
expect "(c) a /login banner in the footer" c 'Please run /login'
printf '%s\n' ' Claude Code can be used with your Claude subscription or billed by API usage.' '' \
  ' Select login method:' '' ' ❯ 1. Claude account with subscription' '   2. Anthropic Console account' > "$T/screen.c2"
expect "(c) a full-screen login picker (no input box)" c2 'Select login method'
printf '%s\n' "$RULE" ' Do you trust the files in this folder?' '' ' /opt/csi/csi-spl-wt/c-900' '' \
  ' ❯ 1. Yes, proceed' '   2. No, exit' '' ' Enter to confirm · Esc to exit' > "$T/screen.c3"
expect "(c) a trust screen under its top rule" c3 'Do you trust the files'

# (d) padding: tmux pads the screen with blank rows
{ printf '%s\n' '● ok' '' '' "$RULE" '❯ ' '' "$RULE" '' '  ⚠ Usage limit reached · resets 7:20am' ''
  for _ in $(seq 1 30); do echo; done; } > "$T/screen.d"
expect "(d) blank rows between and below the footer rows" d 'Usage limit reached'
{ printf '%s\n' '● the limit resets at 9am, usage limit reached yesterday' '' "$RULE" '❯ ' "$RULE"
  for _ in $(seq 1 30); do echo; done; } > "$T/screen.d2"
expect "(d) blank rows under an empty footer, the phrase above the rule" d2 ''
: > "$T/screen.d3"
expect "(d) an empty pane" d3 ''

# (e) no rule at all: the rotate tests' form, read as before
printf 'idle\n❯ \nUsage limit reached · resets 7:20am\n' > "$T/screen.e"
expect "(e) no rule on the screen: the last rows, as before" e 'Usage limit reached'

echo
(( fails == 0 )) && { echo "rotate-stalled: all passed"; exit 0; }
echo "rotate-stalled: $fails failed"; exit 1
