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

# SPL-1575 (specs/017 FR-SEC-030): a probe line is delivered, never typed.
out="$(bash "$SS" --from CLE-90 --to CLE-91 --kind note --body '[spool-probe] attach L1 lobby zz86')"; rc=$?
eq "SPL-1575: a probe send exits 0" 0 "$rc"
has "SPL-1575: …says the prompt was not touched" "poke: probe line" "$out"
check "SPL-1575: …and the probe is in the inbox" grep -lqF 'zz86' "$SPOOL_ROOT/CLE-91/inbox/"*.json
sleep 0.5
hasnt "SPL-1575: the probe never reached the pane" "zz86" "$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -t "$P91")"

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

# ---- spec 101 D14: one msg_id across both legs of a peers send -------------
# A hub that COMMITS the message and then loses its reply (a timeout after the
# commit, a sidecar crash): the relay exits non-zero and the local leg runs.
# The stub keeps the id it was handed (SPOOL_SEND_MSG_ID) the way the hub's
# primary key does; HUB_MINTS=1 makes it mint its own, the control.
D14="$T_TMP/d14"; mkdir -p "$D14"
cat >"$T_TMP/d14-hub" <<'SH'
#!/usr/bin/env bash
id="${SPOOL_SEND_MSG_ID:-}"
[ "${HUB_MINTS:-0}" = 1 ] || [ -z "$id" ] && id="$(cat /proc/sys/kernel/random/uuid)"
printf '%s\n' "$id" >>"$D14_ROWS"
echo "relay: timeout after commit" >&2; exit 1
SH
chmod +x "$T_TMP/d14-hub"
d14() {  # ROWS-FILE [env...]: one peers send through the lossy hub; prints the union of ids
  local rows="$1"; shift; rm -rf "$SPOOL_ROOT/peers"; : >"$rows"
  env "$@" D14_ROWS="$rows" SPOOL_TO_PEERS=1 SPOOL_FLEET_RELAY_CMD="$T_TMP/d14-hub" \
    bash "$SS" --from CLE-90 --to peers --kind result --body 'd14 report' >"$rows.out" 2>&1
  echo "rc=$?" >>"$rows.out"
  { cat "$rows"; jq -r .msg_id "$SPOOL_ROOT"/peers/inbox/*.json; } | sort -u
}
ids="$(d14 "$D14/rows")"
has "D14: the hub leg failed, the local leg wrote it (exit 0)" "rc=0" "$(cat "$D14/rows.out")"
eq "D14: the hub committed one row, the local peers inbox holds one file" "1 1" \
  "$(grep -c . "$D14/rows") $(find "$SPOOL_ROOT/peers/inbox" -name '*.json' | wc -l)"
eq "D14: ONE msg_id on both legs (adopt inserts if absent: one row)" 1 "$(grep -c . <<<"$ids")"
has "D14: ... the id the sender reports is that id" "\"msg_id\":\"${ids}\"" "$(cat "$D14/rows.out")"
ids="$(d14 "$D14/ctl" HUB_MINTS=1)"
eq "D14 CONTROL: a hub leg that mints its own id leaves two ids, two rows" 2 "$(grep -c . <<<"$ids")"

# ---- spec 130 section 4: --accept, the `ready` emitter (lane L3) -----------
# The line carries the v:1 key accepts. A same-machine acceptance goes through
# the hub to this machine's own desk box (relay --to-this-box), so the hub
# stores it and fires `ready`; with no hub leg it is delivered locally, WARN.
RES="0e1f2a3b-4c5d-4e6f-8a7b-9c0d1e2f3a4b"
for id in CLE-95 CLE-96; do mkdir -p "$SPOOL_ROOT/$id/inbox"; done
err="$(bash "$SS" --from CLE-96 --to CLE-95 --kind result --accept "$RES" --body 'ACCEPTED' --no-poke 2>&1 >/dev/null)"; rc=$?
eq "accept, no hub leg: delivered locally (exit 0)" 0 "$rc"
has "accept, no hub leg: WARNs that the Flow shows no ready" "accept: WARN no hub leg" "$err"
f="$(ls "$SPOOL_ROOT/CLE-95/inbox/"*.json 2>/dev/null | sed -n 1p)"
has "accept, no hub leg: the inbox copy carries accepts" "\"accepts\":\"${RES}\"" "$(tr -d ' \n' <"${f:-/dev/null}")"
has "accept, no hub leg: the outbox copy too" "\"accepts\":\"${RES}\"" "$(cat "$SPOOL_ROOT"/CLE-96/outbox/*.json | tr -d ' \n')"
bash "$SS" --from CLE-96 --to CLE-95 --kind result --body 'plain result' --no-poke >/dev/null 2>&1
hasnt "control: a result without --accept carries no accepts key" '"accepts"' \
  "$(grep -L "$RES" "$SPOOL_ROOT"/CLE-95/inbox/*.json | xargs cat)"

cat >"$T_TMP/accept-hub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ACCEPT_ROWS"
echo '{"delivery":"sent","msg_id":"9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d","task_id":"1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d","ts":"2026-10-12T00:00:00Z"}'
SH
chmod +x "$T_TMP/accept-hub"
rm -f "$SPOOL_ROOT"/CLE-95/inbox/*.json; : >"$T_TMP/accept.rows"
out="$(ACCEPT_ROWS="$T_TMP/accept.rows" SPOOL_FLEET_RELAY_CMD="$T_TMP/accept-hub" \
  bash "$SS" --from CLE-96 --to CLE-95 --kind result --accept "$RES" --body 'ACCEPTED' 2>&1)"; rc=$?
eq "same-box accept through the hub: exit 0" 0 "$rc"
has "same-box accept: the relay takes the accepts key" "--accept ${RES}" "$(cat "$T_TMP/accept.rows")"
has "same-box accept: ... to this machine's own desk box" "--to-this-box" "$(cat "$T_TMP/accept.rows")"
eq "same-box accept: ONE delivery, the hub's (no local copy)" 0 "$(find "$SPOOL_ROOT/CLE-95/inbox" -name '*.json' | wc -l)"
has "same-box accept: the sidecar rings the pane" "poke: hub" "$out"
: >"$T_TMP/accept.rows"
ACCEPT_ROWS="$T_TMP/accept.rows" SPOOL_FLEET_RELAY_CMD="$T_TMP/accept-hub" \
  bash "$SS" --from CLE-96 --to CLE-95 --kind result --body 'plain' --no-poke >/dev/null 2>&1
eq "control: a same-box result without --accept never touches the hub" 0 "$(grep -c . "$T_TMP/accept.rows")"
ACCEPT_ROWS="$T_TMP/accept.rows" SPOOL_FLEET_RELAY_CMD="$T_TMP/accept-hub" \
  bash "$SS" --from CLE-96 --to c-500@box-far --kind result --accept "$RES" --body 'ACCEPTED' >/dev/null 2>&1
has "accept to another machine: the relay carries accepts" "--to-box box-far --accept ${RES}" "$(cat "$T_TMP/accept.rows")"
hasnt "accept to another machine: no --to-this-box" "--to-this-box" "$(cat "$T_TMP/accept.rows")"

bash "$SS" --from CLE-96 --to CLE-95 --kind note --accept "$RES" --body x >/dev/null 2>&1; eq "--accept on a note: exit 2" 2 "$?"
bash "$SS" --from CLE-96 --to CLE-95 --kind result --accept NOPE --body x >/dev/null 2>&1; eq "--accept not a uuid: exit 2" 2 "$?"
bash "$SS" --from CLE-96 --to CLE-95 --kind result --accept >/dev/null 2>&1; eq "--accept without a value: exit 2" 2 "$?"

# ---- SPL-2280: no free-text go-ask to the owner ----------------------------
# Plan sdlc-round-1 row 12, red-control column: "Shall I proceed?" to the
# owner is refused; a ```poll form passes; a named owner gate passes.
printf 'HUM-10\thuman\t%%0\t/x\t20260101T000000Z\n' >> "$SPOOL_ROOT/registry.tsv"
n_hum() { find "$SPOOL_ROOT/HUM-10/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l; }
err="$(bash "$SS" --from CLE-90 --to HUM-10 --kind note --body 'Batch 1 is built. Shall I proceed?' --no-poke 2>&1 >/dev/null)"; rc=$?
eq "SPL-2280: 'Shall I proceed?' to the owner: refused, exit 3" 3 "$rc"
has "SPL-2280: …quotes the asking sentence" '"Shall I proceed?"' "$err"
has "SPL-2280: …names the poll form" '```poll form' "$err"
has "SPL-2280: …says nothing was sent" "Nothing was sent" "$err"
eq "SPL-2280: …the owner's inbox is empty" 0 "$(n_hum)"
bash "$SS" --from CLE-90 --to HUM-10 --kind note --body 'Done, landed. Waiting for your go.' --no-poke >/dev/null 2>&1
eq "SPL-2280: a plain 'waiting for your go': exit 3" 3 "$?"
bash "$SS" --from CLE-90 --to HUM-10 --kind note --no-poke \
  --body "$(printf 'Restart the hub now?\n\n```poll\n(GO) Go\n```')" >/dev/null 2>&1
eq "SPL-2280: a \`\`\`poll form (GO) passes, exit 0" 0 "$?"
bash "$SS" --from CLE-90 --to HUM-10 --kind note --no-poke \
  --body 'Plan is ready; needs owner go for terraform apply step 040. Your go?' >/dev/null 2>&1
eq "SPL-2280: a named gate (terraform apply) passes, exit 0" 0 "$?"
bash "$SS" --from CLE-90 --to HUM-10 --kind note --no-poke \
  --body 'Done: your GO is recorded, and the lane I should start is running.' >/dev/null 2>&1
eq "SPL-2280: a statement about a go (no ask) passes, exit 0" 0 "$?"
bash "$SS" --from CLE-90 --to HUM-10 --kind note --no-poke \
  --body "$(printf 'You wrote:\n> Shall I proceed?\nyes, and `go?` is in the log.')" >/dev/null 2>&1
eq "SPL-2280: a > quote and inline code are not the agent's ask, exit 0" 0 "$?"
eq "SPL-2280: …the four passing posts are in the owner's inbox" 4 "$(n_hum)"
bash "$SS" --from CLE-90 --to CLE-91 --kind note --body 'Shall I proceed?' --no-poke >/dev/null 2>&1
eq "SPL-2280: agent to agent is not checked, exit 0" 0 "$?"
err="$(SPOOL_GO_ASK_OK=1 bash "$SS" --from CLE-90 --to HUM-10 --kind note --body 'Shall I proceed?' --no-poke 2>&1 >/dev/null)"; rc=$?
eq "SPL-2280: SPOOL_GO_ASK_OK=1 sends it, exit 0" 0 "$rc"
has "SPL-2280: …with a WARN" "go-ask check is skipped" "$err"
mkdir -p "$T_TMP/old-ga/scripts"; ln -s "$T_FEAT/lib" "$T_TMP/old-ga/lib"
sed '/---- no free-text go-ask to the owner/,/^  fi$/d' "$SS" >"$T_TMP/old-ga/scripts/spool-send.sh"
hasnt "SPL-2280: the control has no guard" "spl_go_ask_check" "$(cat "$T_TMP/old-ga/scripts/spool-send.sh")"
before="$(n_hum)"
bash "$T_TMP/old-ga/scripts/spool-send.sh" --from CLE-90 --to HUM-10 --kind note --body 'Shall I proceed?' --no-poke >/dev/null 2>&1
eq "SPL-2280: RED control: no guard sends 'Shall I proceed?', exit 0" 0 "$?"
eq "SPL-2280: …into the owner's inbox" $((before + 1)) "$(n_hum)"

# ---- usage -----------------------------------------------------------------
bash "$SS" --from CLE-90 --to CLE-91 --kind chat --body x >/dev/null 2>&1; eq "bad kind: exit 2" 2 "$?"
bash "$SS" --from BOX-1 --to CLE-91 --kind note --body x >/dev/null 2>&1;  eq "BOX sender: exit 2" 2 "$?"
bash "$SS" --from CLE-90 --to CLE-91 --kind note >/dev/null 2>&1;          eq "no body: exit 2" 2 "$?"

t_done
