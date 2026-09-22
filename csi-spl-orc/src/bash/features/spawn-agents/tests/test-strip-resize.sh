#!/usr/bin/env bash
# The notice pane is a RIGHT-HAND strip because of what a HEIGHT change does to
# a pane that is already painting (CLE-3447, owner 2026-09-22). That is a claim
# about tmux, not about this code, so it is measured rather than asserted -
# scripts/spool-strip-resize-proof.sh does the measuring on a PRIVATE tmux
# server and exits non-zero if tmux ever stops behaving the way the comments in
# lib/spool-poke-queue.inc.sh say it does.
#
# This wrapper is what puts that measurement in the suite. A proof script nobody
# runs is a paragraph; run by the suite it is a gate, and the day tmux changes
# its alternate-screen resize behaviour the reason for the -h split stops being
# true SILENTLY unless something checks.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"

PROOF="$T_SCRIPTS/spool-strip-resize-proof.sh"
check "the resize proof exists and is executable" test -x "$PROOF"

out="$(bash "$PROOF" 2>&1)"; rc=$?
eq "the measurement comes out the way the code assumes" 0 "$rc"

# The two facts the -h split rests on. Asserting the SENTENCES rather than
# re-deriving the numbers here keeps one place that knows how to measure this.
has "a bottom bar MOVES what is already drawn" \
  "as assumed: a bottom bar MOVES what is already drawn" "$out"
has "a right strip does NOT move it" \
  "as assumed: a right strip leaves every drawn row where it was" "$out"

# And the cost that makes it "better, not free": the second subject, shaped like
# a real agent CLI, loses its transcript line ENDS to a width change. A reader
# who takes "we moved it to the right" as "the distortion is gone" is the person
# this line is for.
has "the proof also measures what a WIDTH change costs" \
  "the transcript ABOVE it loses whatever sat past" "$out"
has "…and says where the complete fix is" "spawn-window.sh splits the strip BEFORE" "$out"

# The transcript row is the number that matters, in both directions.
has "the height case reports the top row MOVING" "top transcript row: TX-0" "$out"
has "the width case reports it unmoved" "top transcript row: TX-001" "$out"

t_done
