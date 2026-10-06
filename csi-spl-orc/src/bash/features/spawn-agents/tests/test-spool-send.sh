#!/usr/bin/env bash
# spool-send.sh: v:1 delivery through `spool send`, unsigned, one topic per
# task_id; the tmux poke is a doorbell with checked outcomes.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
sp() { SPOOL_ROOT="$SPOOL_ROOT" "$SPOOL_BIN" "$@"; }

t_tmux
P91="$(t_window CLE-91 'sleep 600')"
printf 'CLE-91\tclaude\t%s\t/x\t20260101T000000Z\n' "$P91" >> "$SPOOL_ROOT/registry.tsv"

# ---- task CLE-90 -> CLE-91, poked ----------------------------------------
out="$(bash "$SS" --from CLE-90 --to CLE-91 --kind task --body 'ping from 90')"; rc=$?
eq "task delivered and poked (exit 0)" 0 "$rc"
has "spool reports local delivery" '"delivery": "local"' "$(printf '%s' "$out" | sed 's/":"/": "/g')"
has "poke went to the registered pane" "poke: ${P91} (CLE-91)" "$out"
TASK="$(printf '%s' "$out" | sed -n 's/.*"task_id" *: *"\([^"]*\)".*/\1/p')"
check "a task_id was minted" test -n "$TASK"

f="$(ls "$SPOOL_ROOT/CLE-91/inbox/"*.json 2>/dev/null | sed -n 1p)"
check "a .json landed in the recipient inbox" test -n "$f"
check "a copy landed in the sender outbox" test -n "$(ls "$SPOOL_ROOT/CLE-90/outbox/"*.json 2>/dev/null)"
obj="$(cat "$f")"
has "object is v:1" '"v":1' "$(printf '%s' "$obj" | tr -d ' \n')"
hasnt "local mode is unsigned (no sig)" '"sig"' "$obj"

sleep 0.5
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P91")"
has "the pane shows the shell-inert poke line" ": 'SPOOL CLE-91: task from CLE-90 task ${TASK}" "$screen"
# specs/028 FR-002: the line carries the message, it is not a bare doorbell.
has "the pane shows the BODY itself" "ping from 90" "$screen"
has "the pane names how to read it in full" "run: spool recv --as CLE-91" "$screen"

# ---- recv, reply on the same topic, tail --------------------------------
got="$(sp recv --as CLE-91 --ack)"
has "recv returns the task" '"kind":"task"' "$(printf '%s' "$got" | tr -d ' \n')"
check "--ack moved it to archive" test -z "$(ls "$SPOOL_ROOT/CLE-91/inbox/" 2>/dev/null)"
bash "$SS" --from CLE-91 --to CLE-90 --kind result --task "$TASK" --body 'pong from 91' >/dev/null; rc=$?
eq "reply to an agent with no window: delivered, exit 5" 5 "$rc"
check "the reply is in CLE-90's inbox" test -n "$(ls "$SPOOL_ROOT/CLE-90/inbox/"*.json 2>/dev/null)"
tail_out="$(sp tail --task "$TASK")"
eq "tail shows the 2-message topic" 2 "$(printf '%s\n' "$tail_out" | grep -c .)"
has "tail is oldest-first (task first)" "task" "$(printf '%s\n' "$tail_out" | sed -n 1p)"

# ---- doorbell outcomes -----------------------------------------------------
# agents of THIS machine: a send to an id the root does not know is relayed or
# refused (specs/058 N1, test-fleet-send.sh), never an orphan inbox
for id in CLE-92 CLE-93 CLE-94 CLE-97; do mkdir -p "$SPOOL_ROOT/$id/inbox"; done
t_window CLE-92 'bash --norc' >/dev/null
bash "$SS" --from CLE-90 --to CLE-92 --kind note --body x >/dev/null; eq "pane with only a shell: exit 7" 7 "$?"
t_window CLE-93 "sh -c 'printf \"❯ half typed\\n\"; sleep 600'" >/dev/null
sleep 0.3
bash "$SS" --from CLE-90 --to CLE-93 --kind note --body x >/dev/null; eq "unsent typed text: refused, exit 6" 6 "$?"
check "…but the refused message was still delivered" test -n "$(ls "$SPOOL_ROOT/CLE-93/inbox/"*.json 2>/dev/null)"
bash "$SS" --from CLE-90 --to CLE-91 --kind note --body x --no-poke >/dev/null; eq "--no-poke: exit 0" 0 "$?"
# A live agent behind the run-as hop: its pane tty shows only "bash sudo"
# (sudo runs the CLI on its own pty). That is alive, not exited.
ln -s "$(command -v sleep)" "$T_TMP/sudo"
t_window CLE-94 "bash -c '$T_TMP/sudo 600; :'" >/dev/null
sleep 0.3
bash "$SS" --from CLE-90 --to CLE-94 --kind note --body x >/dev/null; eq "pane showing bash+sudo is alive: poked, exit 0" 0 "$?"
# The TUI's dim ghost suggestion after the prompt glyph is not typed text.
t_window CLE-97 "sh -c 'printf \"❯ \\033[2mfix the thing\\033[0m\\n\"; sleep 600'" >/dev/null
sleep 0.3
bash "$SS" --from CLE-90 --to CLE-97 --kind note --body x >/dev/null; eq "dim ghost suggestion is not typed text: exit 0" 0 "$?"

# ---- spec 101 R2: a dispatcher asking the orch for a new lane --------------
# The dispatcher that takes real lane work spawns it (fleet-roles 3): a task
# "new lane please" from c-002 to the orchestrator WARNs and is still sent.
for id in c-001 c-002 c-003; do mkdir -p "$SPOOL_ROOT/$id/inbox"; done
ask() {  # stderr only, with the send's exit code
  SPOOL_ORCHESTRATOR_ID=c-001 bash "$SS" --no-poke --no-ask "$@" >/dev/null 2>"$T_TMP/ask.err"
  local rc=$?; cat "$T_TMP/ask.err"; return "$rc"
}
inbox_n() { find "$SPOOL_ROOT/c-001/inbox" -maxdepth 1 -name '*.json' | wc -l; }
n0="$(inbox_n)"
err="$(ask --from c-002 --to orchestrator --kind task --body 'please spawn a new lane for the hub fix')"; rc=$?
eq "R2: the ask from c-002 is still sent (exit 0)" 0 "$rc"
has "R2: a task asking for a new lane from c-002 WARNs" "lane: WARN c-002 asks the orchestrator for a new lane" "$err"
eq "R2: ... and is delivered to the orchestrator" $((n0 + 1)) "$(inbox_n)"
eq "R2: one WARN line" 1 "$(grep -c 'lane: WARN' <<<"$err")"
err="$(ask --from c-003 --to c-001 --kind task --body 'New lane please: the wui typo')"
has "R2: from c-003 to the orch's id WARNs too" "lane: WARN c-003" "$err"
err="$(ask --from CLE-90 --to orchestrator --kind task --body 'please spawn a new lane for the hub fix')"; rc=$?
eq "R2 control: the same ask from a lane is sent" 0 "$rc"
hasnt "R2 control: ... with no WARN" "lane: WARN" "$err"
err="$(ask --from c-002 --to orchestrator --kind note --body 'please spawn a new lane for the hub fix')"
hasnt "R2 control: a note from c-002 does not WARN" "lane: WARN" "$err"
err="$(ask --from c-002 --to orchestrator --kind task --body 'prd deploy of v1.4.2 needs your go')"
hasnt "R2 control: a task from c-002 that asks no lane does not WARN" "lane: WARN" "$err"

# ---- usage -----------------------------------------------------------------
bash "$SS" --from CLE-90 --to CLE-91 --kind chat --body x >/dev/null 2>&1; eq "bad kind: exit 2" 2 "$?"
bash "$SS" --from BOX-1 --to CLE-91 --kind note --body x >/dev/null 2>&1;  eq "BOX sender: exit 2" 2 "$?"
bash "$SS" --from CLE-90 --to CLE-91 --kind note >/dev/null 2>&1;          eq "no body: exit 2" 2 "$?"

t_done
