#!/usr/bin/env bash
# test-agent-send.sh — the switch-over bridge (specs/048 switch-over §3):
# agent-send.sh reaches each agent through the mailbox it was spawned with,
# and agent-inbox.sh lists what an orchestrator has not seen yet, from both.
# A throwaway SPOOL_ROOT, a throwaway legacy root, a fake legacy sender and a
# private tmux server; nothing real is touched.
#
#   1. an id in the spool registry -> spool: a v:1 message in its inbox, the
#      pane poked; text and --file both work; cle-7 style ids are normalised
#   2. an id with a legacy inbox -> the legacy sender, with the same arguments,
#      its exit code passed through - even when the desk ALSO gave it a spool
#      dir (an old agent seated on the desk)
#   3. no mailbox anywhere -> exit 3, nothing written; a legacy target with no
#      SPOOL_LEGACY_SEND -> exit 3; --via forces a route
#   4. agent-inbox.sh: the first listing shows what is there, a second shows
#      nothing, a new spool message and a new legacy outbox file show once,
#      --peek does not move the mark
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
unset TMUX TMUX_PANE CLE_TMUX_PANE MCP_BOT_AGENT_ID SPOOL_AGENT_ID CLE_TMUX_SOCK
SEND="$T_SCRIPTS/agent-send.sh"; INBOX="$T_SCRIPTS/agent-inbox.sh"
export SPOOL_LEGACY_INBOX_ROOT="$T_TMP/legacy" SPOOL_LEGACY_SEND="$T_TMP/legacy-send.sh"
cat >"$SPOOL_LEGACY_SEND" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T_TMP/legacy.log"
exit "\${FAKE_LEGACY_RC:-0}"
EOF
mkdir -p "$SPOOL_LEGACY_INBOX_ROOT/CLE-08/inbox" "$SPOOL_LEGACY_INBOX_ROOT/CLE-08/outbox"
# CLE-001 (the orchestrator) and CLE-01 are DIFFERENT ids: both registered so a
# leading-zero id is not silently width-normalised onto the other's mailbox.
for id in CLE-01 CLE-07 CLE-001 CLE-77798; do mkdir -p "$SPOOL_ROOT/$id"/{inbox,outbox,archive}; done
printf 'CLE-07\tclaude\t%%9\t/x\t20260101T000000Z\n' >"$SPOOL_ROOT/registry.tsv"
printf 'CLE-001\tclaude\t%%1\t/x\t20260101T000000Z\n' >>"$SPOOL_ROOT/registry.tsv"
printf 'CLE-01\tclaude\t%%2\t/x\t20260101T000000Z\n' >>"$SPOOL_ROOT/registry.tsv"
printf 'CLE-77798\tclaude\t%%3\t/x\t20260101T000000Z\n' >>"$SPOOL_ROOT/registry.tsv"
mkdir -p "$SPOOL_ROOT/CLE-08"/{inbox,outbox,archive}      # the desk seated the old agent too
t_tmux
P7="$(t_window 'tbox: CLE-07 new harness' 'sleep 600')"

# --- 1. spool ------------------------------------------------------------------
out="$(bash "$SEND" --from CLE-01 cle-7 hello new agent 2>&1)"; rc=$?
eq "1. a registry id goes by spool (rc 0)" 0 "$rc"
has "1. it says which route and why" "via: spool (CLE-07 is in $SPOOL_ROOT/registry.tsv)" "$out"
f="$(ls "$SPOOL_ROOT/CLE-07/inbox/"*.json 2>/dev/null | sed -n 1p)"
eq "1. a v:1 message from CLE-01 lands in CLE-07's spool inbox" "1 CLE-01" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["v"], d["from"])' "$f" 2>/dev/null)"
has "1. ... carrying the text" "hello new agent" "$(cat "$f" 2>/dev/null)"
has "1. the pane is poked" "poke: $P7 (CLE-07)" "$out"
echo "from a file" >"$T_TMP/m.md"
bash "$SEND" --from CLE-01 CLE-07 --file "$T_TMP/m.md" --no-poke >/dev/null 2>&1; eq "1. --file works (rc 0)" 0 "$?"
eq "1. two messages in the inbox" 2 "$(ls "$SPOOL_ROOT/CLE-07/inbox/"*.json | wc -l)"

# --- 1b. a leading-zero id keeps every digit (CLE-001 != CLE-01) ----------------
# The old normalisation reparsed "001" as decimal 1 and printed "CLE-01", so the
# orchestrator CLE-001's mail was refused ("no mailbox for CLE-01") or delivered
# to a different agent. Send to CLE-001, CLE-01 and CLE-77798 as three controls.
bash "$SEND" --from CLE-77798 CLE-001 --no-poke to the orchestrator >/dev/null 2>&1
eq "1b. CLE-001 is not width-normalised to CLE-01 (rc 0)" 0 "$?"
eq "1b. the message lands in CLE-001's own inbox" 1 "$(ls "$SPOOL_ROOT/CLE-001/inbox/"*.json 2>/dev/null | wc -l)"
eq "1b. ... and NOT in the different id CLE-01's inbox" 0 "$(ls "$SPOOL_ROOT/CLE-01/inbox/"*.json 2>/dev/null | wc -l)"
bash "$SEND" --from CLE-001 CLE-01 --no-poke to the two-digit id >/dev/null 2>&1
eq "1b. CLE-01 stays CLE-01 (rc 0)" 0 "$?"
eq "1b. ... reaching CLE-01, still one in CLE-001" 1 "$(ls "$SPOOL_ROOT/CLE-01/inbox/"*.json 2>/dev/null | wc -l)"
eq "1b. ... CLE-001 unchanged at one" 1 "$(ls "$SPOOL_ROOT/CLE-001/inbox/"*.json 2>/dev/null | wc -l)"
bash "$SEND" --from CLE-001 CLE-77798 --no-poke a wide id is verbatim >/dev/null 2>&1
eq "1b. a wide id (CLE-77798) is delivered verbatim" 1 "$(ls "$SPOOL_ROOT/CLE-77798/inbox/"*.json 2>/dev/null | wc -l)"
# leave CLE-01's inbox clean: section 4 reads it as a fresh mailbox
rm -f "$SPOOL_ROOT/CLE-01/inbox/"*.json

# --- 2. legacy -----------------------------------------------------------------
out="$(bash "$SEND" --from CLE-01 CLE-08 --subject s1 --file "$T_TMP/m.md" 2>&1)"; rc=$?
eq "2. an old agent goes by the legacy sender (rc 0)" 0 "$rc"
has "2. ... even with a desk spool dir" "via: legacy (CLE-08 has a markdown inbox" "$out"
eq "2. the legacy sender gets the same arguments" "--from CLE-01 CLE-08 --subject s1 --file $T_TMP/m.md" "$(tail -1 "$T_TMP/legacy.log")"
eq "2. nothing went into its spool inbox" 0 "$(ls "$SPOOL_ROOT/CLE-08/inbox/" | wc -l)"
FAKE_LEGACY_RC=6 bash "$SEND" --from CLE-01 CLE-08 some text >/dev/null 2>&1; eq "2. the legacy exit code passes through" 6 "$?"
eq "2. text form passes as words" "--from CLE-01 CLE-08 some text" "$(tail -1 "$T_TMP/legacy.log")"

# --- 3. refusals and --via ---------------------------------------------------------
bash "$SEND" --from CLE-01 CLE-99 hi >"$T_TMP/o" 2>&1; eq "3. no mailbox -> exit 3" 3 "$?"
check "3. ... nothing written" test ! -e "$SPOOL_ROOT/CLE-99"
env -u SPOOL_LEGACY_SEND bash "$SEND" --from CLE-01 CLE-08 hi >"$T_TMP/o" 2>&1; eq "3. a legacy target without SPOOL_LEGACY_SEND -> exit 3" 3 "$?"
out="$(bash "$SEND" --from CLE-01 --via spool CLE-08 --no-poke forced 2>&1)"
has "3. --via spool forces the spool" "via: spool (--via spool)" "$out"
eq "3. ... and it lands there" 1 "$(ls "$SPOOL_ROOT/CLE-08/inbox/" | wc -l)"
bash "$SEND" CLE-07 no sender >/dev/null 2>&1; eq "3. the spool needs a sender id (2)" 2 "$?"

# --- 4. agent-inbox.sh ------------------------------------------------------------
bash "$SEND" --from CLE-07 CLE-01 --no-poke report one >/dev/null 2>&1
echo "old report" >"$SPOOL_LEGACY_INBOX_ROOT/CLE-08/outbox/20260101T000000Z--CLE-08--old-report.md"
out="$(bash "$INBOX" --as CLE-01 2>&1)"
has "4. the first listing shows the spool report" "report one" "$out"
has "4. ... and the legacy outbox report" "CLE-08" "$out"
has "4. ... and counts both" "new: 1 spool, 1 legacy" "$out"
has "4. a second listing shows nothing" "new: 0 spool, 0 legacy" "$(bash "$INBOX" --as CLE-01 2>&1)"
sleep 1.1
bash "$SEND" --from CLE-07 CLE-01 --no-poke report two >/dev/null 2>&1
echo "newer" >"$SPOOL_LEGACY_INBOX_ROOT/CLE-08/outbox/20260102T000000Z--CLE-08--second.md"
out="$(bash "$INBOX" --as CLE-01 --peek 2>&1)"
has "4. a new report shows" "report two" "$out"
hasnt "4. an old one does not" "report one" "$out"
has "4. --peek lists both kinds" "new: 1 spool, 1 legacy" "$out"
has "4. --peek did not move the mark" "new: 1 spool, 1 legacy" "$(bash "$INBOX" --as CLE-01 2>&1)"
has "4. ... the listing after it did" "new: 0 spool, 0 legacy" "$(bash "$INBOX" --as CLE-01 2>&1)"
bash "$INBOX" --as CLE-55 >/dev/null 2>&1; eq "4. no spool mailbox -> exit 3" 3 "$?"
t_done
