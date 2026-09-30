#!/usr/bin/env bash
# test-poke-ghost.sh (SPL-1253 harness fix) — the poke must tell Claude Code's
# grey GHOST AUTOSUGGEST (dim, cursor on its first char) from real typed text,
# so an idle agent is still woken. spool_notify_strip_ghost cuts the ghost;
# spool_notify_has_unsent then sees an idle composer as empty (pokeable) and a
# half-typed line as unsent (refused).
#   1. idle + dim ESC[0;2m suggestion (the live capture)  -> pokeable
#   2. real typed text + a suggestion                     -> refuse
#   3. bare ESC[2m suggestion (older render)              -> pokeable
#   4. empty composer, cursor only, no suggestion         -> pokeable
#   5. real typed text, no suggestion                     -> refuse
#   6. a SPOOL doorbell residue                           -> pokeable
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/spool-notify.inc.sh"
. "$LIB" 2>/dev/null

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
esc=$'\033'; nbsp=$' '

# pokeable when the cleaned line has NO real unsent text (has_unsent -> non-zero)
pokeable() { local c; c="$(spool_notify_strip_ghost "$1")"; spool_notify_has_unsent "$c" && return 1 || return 0; }

# 1. the exact shape captured from a live idle Claude pane 2026-09-30
idle="${esc}[39m❯${nbsp} ${esc}[7mt${esc}[0;2mear down the worktree${esc}[0m"
pokeable "$idle" && pass "1. idle + ESC[0;2m ghost -> pokeable" || fail "1. idle + ESC[0;2m ghost -> pokeable"

# 2. real typed text before the cursor+suggestion
typed="${esc}[39m❯${nbsp} fix the bug${esc}[7m ${esc}[0;2mnow${esc}[0m"
pokeable "$typed" && fail "2. typed text + suggestion -> refuse" || pass "2. typed text + suggestion -> refuse"

# 3. an older bare-ESC[2m suggestion still handled
old="${esc}[39m❯${nbsp} ${esc}[2mhello from a suggestion${esc}[0m"
pokeable "$old" && pass "3. bare ESC[2m ghost -> pokeable" || fail "3. bare ESC[2m ghost -> pokeable"

# 4. empty composer, just the cursor block, no suggestion
empty="${esc}[39m❯${nbsp} ${esc}[7m ${esc}[0m"
pokeable "$empty" && pass "4. empty composer -> pokeable" || fail "4. empty composer -> pokeable"

# 5. real typed text, no suggestion, cursor at end
onlytyped="${esc}[39m❯${nbsp} deploy now${esc}[7m ${esc}[0m"
pokeable "$onlytyped" && fail "5. real typed text -> refuse" || pass "5. real typed text -> refuse"

# 6. a leftover SPOOL doorbell is not human text
doorbell="${esc}[39m❯${nbsp} : 'SPOOL CLE-001: ...'${esc}[0m"
pokeable "$doorbell" && pass "6. a SPOOL doorbell residue -> pokeable" || fail "6. a SPOOL doorbell residue -> pokeable"

echo "-- test-poke-ghost.sh: $fails failed"
[ "$fails" -eq 0 ]
