#!/usr/bin/env bash
# test-spool-kinds.sh — the message kinds in orc (spec 033 section K.3, T024,
# SPL-5884): SPOOL_KINDS (spool-env.inc.sh) equals the Go msg.KindList, a
# SPOOL_NOTE_KINDS kind routes as a note, spool-send.sh takes every kind in
# SPOOL_KINDS (--kind bug passes the check, --kind bogus exits 2), and a bug
# sent to the orchestrator raises no ask. Hermetic: own SPOOL_ROOT, no hub.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-asks.inc.sh"
nope() { ! "$@"; }
SS="$T_SCRIPTS/spool-send.sh"
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

# ---- 2. spool-send.sh --kind --------------------------------------------------
# An empty body is refused AFTER the kind check: its line proves the kind passed.
err="$(bash "$SS" --from c-781 --to c-782 --kind bug --body "" --no-poke --no-ask 2>&1 >/dev/null)"; rc=$?
hasnt "2. --kind bug passes the kind check" "--kind must be" "$err"
has "2. ...and stops at the next one (the empty body)" "the body is empty" "$err"
eq "2. ...exit 2" 2 "$rc"
err="$(bash "$SS" --from c-781 --to c-782 --kind bogus --body "x" --no-poke --no-ask 2>&1 >/dev/null)"; rc=$?
eq "2. --kind bogus: exit 2" 2 "$rc"
has "2. ...naming the 13 kinds" "--kind must be $SPOOL_KINDS, got: 'bogus'" "$err"
for k in ${SPOOL_KINDS//|/ }; do
  err="$(bash "$SS" --from c-781 --to c-782 --kind "$k" --body "" --no-poke --no-ask 2>&1 >/dev/null)"
  hasnt "2. --kind $k passes the kind check" "--kind must be" "$err"
done
has "2. the usage line names SPOOL_KINDS" "--kind $SPOOL_KINDS" "$(bash "$SS" --help 2>&1)"

# ---- 3. a new kind raises no ask ----------------------------------------------
export SPOOL_ORCHESTRATOR_ID=c-001
eq "3. a blocker to the orchestrator is an ask" blocker "$(spool_ask_wanted c-001 blocker '' 0)"
for k in ${SPOOL_NOTE_KINDS//|/ }; do
  eq "3. a $k to the orchestrator raises no ask" "" "$(spool_ask_wanted c-001 "$k" '' 0)"
done

# ---- 4. spl-desk-reply.sh names the reply action's kinds ----------------------
# want = the set do_spl_desk_reply checks (spl-desk-reply.func.sh, spool_kind_in).
want="$(tr '|' '\n' <<<"result|reject|blocker|msg|$SPOOL_NOTE_KINDS" | sort -u | paste -sd' ')"
u="$(bash "$T_REPO/csi-spl-orc/src/bash/scripts/spl-desk-reply.sh" --help 2>&1)"
got="$(sed -nE 's/.*--kind ([a-z|]+).*/\1/p' <<<"$u" | tr '|' '\n' | sort -u | paste -sd' ')"
eq "4. spl-desk-reply.sh usage --kind lists the reply kinds" "$want" "$got"
got="$(sed -nE 's/^ *DESK_KIND +([a-z |]+)\(default.*/\1/p' <<<"$u" | tr -d ' ' | tr '|' '\n' | sed '/^$/d' | sort -u | paste -sd' ')"
eq "4. spl-desk-reply.sh DESK_KIND line lists the reply kinds" "$want" "$got"

t_done
