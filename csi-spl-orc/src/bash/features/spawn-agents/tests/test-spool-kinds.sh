#!/usr/bin/env bash
# test-spool-kinds.sh — the message kinds in orc (spec 033 section K.3, T024,
# SPL-5884): SPOOL_KINDS (spool-env.inc.sh) equals the Go msg.KindList, a
# SPOOL_NOTE_KINDS kind routes as a note, and a bug sent to the orchestrator
# raises no ask. Hermetic: own SPOOL_ROOT, no hub.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-asks.inc.sh"
nope() { ! "$@"; }
GO="$T_REPO/csi-spl-api/src/go/spool-hub-api/internal/msg/msg.go"

# ---- 1. one list: SPOOL_KINDS == msg.KindList --------------------------------
gv="$(sed -nE 's/^const KindList = "([^"]*)"$/\1/p' "$GO")"
if [ -n "$gv" ]; then
  eq "1. bash SPOOL_KINDS == Go msg.KindList" "$gv" "$SPOOL_KINDS"
else
  nok "1. Go msg.KindList not found at $GO"
fi
eq "1. SPOOL_KINDS holds 13 kinds" 13 "$(tr '|' '\n' <<<"$SPOOL_KINDS" | sort -u | wc -l)"
eq "1. SPOOL_NOTE_KINDS is note and the seven" "note|feature|bug|alert|question|idea|decision|docs" "$SPOOL_NOTE_KINDS"
for k in ${SPOOL_NOTE_KINDS//|/ }; do
  check "1. note kind $k is a SPOOL_KINDS kind" spool_kind_in "$SPOOL_KINDS" "$k"
done
check "1. spool_kind_in refuses doc" nope spool_kind_in "$SPOOL_KINDS" doc
check "1. spool_kind_in refuses ''" nope spool_kind_in "$SPOOL_KINDS" ""
check "1. spool_kind_in refuses task in SPOOL_NOTE_KINDS" nope spool_kind_in "$SPOOL_NOTE_KINDS" task
check "1. exported, so a child script reads it" test "$(bash -c 'echo "$SPOOL_NOTE_KINDS"')" = "$SPOOL_NOTE_KINDS"

# ---- 2. a new kind raises no ask ----------------------------------------------
export SPOOL_ORCHESTRATOR_ID=c-001
eq "2. a blocker to the orchestrator is an ask" blocker "$(spool_ask_wanted c-001 blocker '' 0)"
for k in ${SPOOL_NOTE_KINDS//|/ }; do
  eq "2. a $k to the orchestrator raises no ask" "" "$(spool_ask_wanted c-001 "$k" '' 0)"
done

t_done
