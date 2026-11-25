#!/usr/bin/env bash
# The poke ledger (spec 053 section 8, SPL-6511): every poke leaves ONE row in
# <root>/<to>/lifetime/poke-ledger.tsv, on the send path (spool-send.sh) and
# on the sidecar path (spool-notify.sh, which every cross-box message takes),
# with monotonic millisecond stamps; a refused poke leaves rc 6; the agent
# hook adds the "surfaced" and "prompt" rows.
#   row: event ts_ms to msg_id written_ms start_ms rc via send_ms
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
# shellcheck source=../../../tests/wait-event.inc.sh
. "$T_REPO/csi-spl-orc/src/bash/tests/wait-event.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
SN="$T_SCRIPTS/spool-notify.sh"
HOOK="$T_SCRIPTS/spool-agent-hook.sh"
L91="$SPOOL_ROOT/CLE-91/lifetime/poke-ledger.tsv"
L92="$SPOOL_ROOT/CLE-92/lifetime/poke-ledger.tsv"

# field N of the only "poke" row of FILE whose msg_id is ID
pf() {  # FILE ID N
  awk -F'\t' -v id="$2" -v n="$3" '$1 == "poke" && $4 == id { print $n }' "$1" 2>/dev/null
}
npoke() {  # FILE ID
  awk -F'\t' -v id="$2" '$1 == "poke" && $4 == id' "$1" 2>/dev/null | wc -l
}
le() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != - ] && [ "$2" != - ] && [ "$1" -le "$2" ]; }

t_tmux
P91="$(t_window CLE-91 'sleep 600')"
printf 'CLE-91\tclaude\t%s\t/x\t20260101T000000Z\n' "$P91" >> "$SPOOL_ROOT/registry.tsv"

# ---- 1. same box: spool-send.sh -----------------------------------------
out="$(bash "$SS" --from CLE-90 --to CLE-91 --kind task --body 'ledger same box')"; rc=$?
eq "same box: delivered and poked" 0 "$rc"
M1="$(printf '%s' "$out" | sed -n 's/.*"msg_id" *: *"\([^"]*\)".*/\1/p')"
check "same box: a msg_id was minted" test -n "$M1"
eq "same box: ONE poke row for the message" 1 "$(npoke "$L91" "$M1")"
eq "same box: rc 0"            0    "$(pf "$L91" "$M1" 7)"
eq "same box: via send"        send "$(pf "$L91" "$M1" 8)"
eq "same box: to is the recipient" CLE-91 "$(pf "$L91" "$M1" 3)"
s0="$(pf "$L91" "$M1" 9)" w="$(pf "$L91" "$M1" 5)" st="$(pf "$L91" "$M1" 6)" ts="$(pf "$L91" "$M1" 2)"
check "same box: send start <= inbox written ($s0 <= $w)"  le "$s0" "$w"
check "same box: inbox written <= poke start ($w <= $st)" le "$w" "$st"
check "same box: poke start <= poke end ($st <= $ts)"      le "$st" "$ts"
check "same box: stamps are ms (13 digits)" test "${#ts}" -eq 13

# ---- 2. relayed: the hub sidecar wrote the inbox file, then rings ------
M2="5e1f0a2b-0000-4000-8000-000000000002"
mkdir -p "$SPOOL_ROOT/CLE-91/inbox"
printf '{"v":1,"msg_id":"%s","ts":"2026-11-25T00:00:00Z","from":"c-777","to":"CLE-91","kind":"note","task_id":"T-2","body":"relayed"}\n' "$M2" \
  >"$SPOOL_ROOT/CLE-91/inbox/20261125T000000Z--c-777@box-far--relayed-${M2:0:8}.json"
bash "$SN" --to CLE-91 --from c-777 --kind note --task T-2 --msg-id "$M2" --body relayed >/dev/null; rc=$?
eq "relayed: the sidecar path rang the pane" 0 "$rc"
eq "relayed: ONE poke row for the message" 1 "$(npoke "$L91" "$M2")"
eq "relayed: via sidecar" sidecar "$(pf "$L91" "$M2" 8)"
eq "relayed: rc 0"        0       "$(pf "$L91" "$M2" 7)"
w="$(pf "$L91" "$M2" 5)" st="$(pf "$L91" "$M2" 6)" ts="$(pf "$L91" "$M2" 2)"
check "relayed: inbox written <= poke start ($w <= $st)" le "$w" "$st"
check "relayed: poke start <= poke end ($st <= $ts)"     le "$st" "$ts"
eq "relayed: no send start on the sidecar path" - "$(pf "$L91" "$M2" 9)"

# ---- 3. a refused poke (unsent text in the composer) leaves rc 6 ---------
P92="$(t_window CLE-92 'exec cat')"
printf 'CLE-92\tclaude\t%s\t/x\t20260101T000000Z\n' "$P92" >> "$SPOOL_ROOT/registry.tsv"
mkdir -p "$SPOOL_ROOT/CLE-92/inbox"
tty92="$(tmux -S "$SPOOL_TMUX_SOCKET" display-message -p -t "$P92" '#{pane_tty}')"
printf 'welcome\r\n\xe2\x9d\xaf half typed text\r' >"$tty92"
wait_unsent() { tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P92" | grep 'half typed' >/dev/null; }
wait_event 5 wait_unsent || nok "refused: the pane never showed the unsent text"
out="$(bash "$SS" --from CLE-90 --to CLE-92 --kind note --body 'while you type')"; rc=$?
eq "refused: spool-send.sh exits 6" 6 "$rc"
M3="$(printf '%s' "$out" | sed -n 's/.*"msg_id" *: *"\([^"]*\)".*/\1/p')"
eq "refused: ONE poke row" 1 "$(npoke "$L92" "$M3")"
eq "refused: the row says rc 6" 6 "$(pf "$L92" "$M3" 7)"

# ---- 4. the hook: surfaced + prompt rows ---------------------------------
hookr() { env SPOOL_AGENT_ID=CLE-91 SPOOL_HARNESS=claude HANDOFF_COMPOSE_CMD=true bash "$HOOK" "$1" <<<'{}' >/dev/null 2>&1; }
hookr UserPromptSubmit
np="$(awk -F'\t' '$1 == "prompt"' "$L91" | wc -l)"
eq "hook: UserPromptSubmit leaves one prompt row" 1 "$np"
sv="$(awk -F'\t' -v id="$M2" '$1 == "surfaced" && $4 == id { print $8 }' "$L91")"
eq "hook: the relayed message surfaced on UserPromptSubmit" UserPromptSubmit "$sv"
sts="$(awk -F'\t' -v id="$M2" '$1 == "surfaced" && $4 == id { print $2 }' "$L91")"
check "hook: poke end <= surfaced ($ts <= $sts)" le "$ts" "$sts"
hookr PostToolUse
eq "hook: a message is surfaced once, not again on PostToolUse" 1 \
  "$(awk -F'\t' -v id="$M2" '$1 == "surfaced" && $4 == id' "$L91" | wc -l)"

# ---- 5. no agent dir, no row; the ledger rotates, never rewrites ---------
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
spool_ledger_row CLE-99 poke 1 m 1 1 0 send
check "no row is written for an agent with no dir" test ! -e "$SPOOL_ROOT/CLE-99"
before="$(wc -l <"$L91")"
SPOOL_LEDGER_MAX=1 spool_ledger_row CLE-91 poke 2 m 1 1 0 send
check "past SPOOL_LEDGER_MAX the file moves to .1" test "$(wc -l <"$L91.1")" -eq "$before"
eq "…and the new row starts a fresh file" 1 "$(wc -l <"$L91")"

t_done
