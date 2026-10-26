#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: grade fix A (SPL-3517): a new human post to the dispatch lease
#          holder gets its take line from code, not from the holder's model.
#          do_spl_take_auto over a scratch spool root, a fake hub tail
#          (TAKE_AUTO_TAIL_CMD) and a fake do_spl_desk_reply (TAKE_REPLY_CMD);
#          the notifier's gate (spool_notify_take_auto) with a fake ./run.
#          No hub, no tmux, no spool binary is touched.
#   1. holder + a topic with no agent reply: ONE take line, to the human, in
#      the topic, "Taken by c-002@box-a: I read your post now. ..."
#   2. a second delivery in the same topic posts nothing more
#   3. an agent reply to the channel or a human owns the topic: no take;
#      an agent-to-agent relay and the responder (RSP-*) do not own it
#   4. skips: another seat holds the lease, a stale lease, the off switch,
#      a test workspace, a post naming another agent, a hub tail that fails
#   5. DRY_RUN (default) posts nothing
#   6. the notifier gate: starts ./run -a do_spl_take_auto for a human post
#      to the holder, with the desk root and the box root; nothing for an
#      agent sender, a non-holder, a probe, a short task id, the off switch
#   7. wiring: spool-notify.sh sources the lib and calls the gate
#   8. sole seat (SPL-3542): a human post in a channel whose box-map row
#      (channel-rules.tsv column 6) names a sole seat is not taken by any
#      other seat (one log line why); a normal channel, a DM and the sole seat
#      itself still take; a tail that does not name the post's channel, an
#      unreadable map or a malformed seat column posts nothing (fail closed)
#   control: with the owner check removed (a planted copy), an owned topic is
#      taken again -> assertion 3 would turn red; with the sole-seat check
#      removed, the sole-seat post is taken -> section 8 would turn red
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FEAT="$PROJ_ROOT/src/bash/features/spawn-agents"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }
has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (no '$2' in: $3)"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

S="$T/spool"; mkdir -p "$S/dispatch"
DESK="$T/state/prd/desk/t1/box-a/spool"; mkdir -p "$DESK"
TOPIC=00000000-0000-4000-8000-0000000000b1
cat >"$T/reply.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ENV" "$TENANT_ID" "$DESK_AGENT" "$DESK_TO" "$DESK_TASK" "$DESK_KIND" "$DESK_BODY" >>"$REPLY_LOG"
EOF
# the fake hub tail: prints $TAIL_FILE, fails while $TAIL_FILE.fail exists
cat >"$T/tail.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$TAIL_FILE.fail" ] && exit 7
cat "$TAIL_FILE"
EOF
chmod +x "$T/reply.sh" "$T/tail.sh"
export REPLY_LOG="$T/reply.log" TAIL_FILE="$T/tail.ndjson"
# row FROM TO BODY [CHANNEL [MSG_ID]]: one hub-tail --with-channel line
row() { printf '{"channel":"%s","v":1,"msg_id":"%s","from":"%s","to":"%s","kind":"note","task_id":"%s","body":"%s"}\n' "${4-ops}" "${5:-m-$RANDOM}" "$1" "$2" "$TOPIC" "$3"; }
lease() { printf '%s %s\n' "$1" "$2" >"$S/dispatch/lease"; }
n() { [[ -f "$1" ]] && wc -l <"$1" | tr -d ' ' || echo 0; }

# auto [VAR=VAL ...]: run do_spl_take_auto in a clean shell with the stubs
auto() {
  env -i PATH="$PATH" HOME="$HOME" PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_TEST=1 \
    REPLY_LOG="$REPLY_LOG" TAIL_FILE="$TAIL_FILE" TAKE_REPLY_CMD="$T/reply.sh" TAKE_AUTO_TAIL_CMD="$T/tail.sh" \
    TAKE_AUTO_TO=c-002 TAKE_AUTO_FROM=HUM-10 TAKE_AUTO_TASK="$TOPIC" TAKE_AUTO_DESK_ROOT="$DESK" \
    SPOOL_BOX_ID=box-a SPOOL_TENANT=t1 TAKE_AUTO_BODY='why is the build red' DRY_RUN=0 "$@" bash -c '
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/lib/bash/funcs/spl-desk-box.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-take.func.sh"
    source "${TAKE_AUTO_FUNC:-$PROJ_PATH/src/bash/run/spl-take-auto.func.sh}"
    do_spl_take_auto' 2>&1
}

# ---- 1. the holder takes a new topic at once ---------------------------------
lease c-002@box-a "$(date +%s)"
{ row HUM-10 ALL-0 'why is the build red'; row c-003 c-002 'relay: unanswered'; row RSP-1 HUM-10 'Seen'; } >"$TAIL_FILE"
out="$(auto)"
has "1. the action says it took the topic" "TAKEN $TOPIC by c-002@box-a" "$out"
eq "1. exactly one take line posted" 1 "$(n "$REPLY_LOG")"
r_env="" r_ten="" r_agent="" r_to="" r_task="" r_kind="" r_body=""
[[ -f "$REPLY_LOG" ]] && IFS=$'\t' read -r r_env r_ten r_agent r_to r_task r_kind r_body <"$REPLY_LOG"
eq "1. env from the desk root" prd "$r_env"
eq "1. the workspace" t1 "$r_ten"
eq "1. posted as the holder" c-002 "$r_agent"
eq "1. to the human who posted" HUM-10 "$r_to"
eq "1. in the topic" "$TOPIC" "$r_task"
eq "1. kind note" note "$r_kind"
eq "1. the take line" "Taken by c-002@box-a: I read your post now. I post the result here." "$r_body"
has "1. the decision is logged" "take" "$(cat "$S/dispatch/take-auto.log")"
has "1. the take ledger holds it" "c-002@box-a" "$(cat "$S/dispatch/take.log")"

# ---- 2. a second delivery posts nothing more -------------------------------
row c-002 HUM-10 'Taken by c-002@box-a: I read your post now. I post the result here.' >>"$TAIL_FILE"
out="$(auto)"
eq "2. a second post in the topic: still one take line" 1 "$(n "$REPLY_LOG")"
row HUM-10 ALL-0 'why is the build red' >"$TAIL_FILE"
out="$(auto)"
has "2. even when the hub has not shown the take yet: the ledger holds" "TAKEN-ALREADY" "$out"
eq "2. still one take line" 1 "$(n "$REPLY_LOG")"

# ---- 3. an agent reply owns the topic --------------------------------------
: >"$REPLY_LOG"; : >"$S/dispatch/take.log"
{ row HUM-10 ALL-0 'q'; row g-002 ALL-0 'an answer'; } >"$TAIL_FILE"
out="$(auto)"
has "3. an agent reply to the channel owns it" "owned: g-002" "$out"
{ row HUM-10 ALL-0 'q'; row c-003 HUM-10 'an answer'; } >"$TAIL_FILE"
out="$(auto)"
has "3. an agent reply to a human owns it" "owned: c-003" "$out"
eq "3. no take line in an owned topic" 0 "$(n "$REPLY_LOG")"

# ---- 4. skips ----------------------------------------------------------------
row HUM-10 ALL-0 'q' >"$TAIL_FILE"
out="$(auto SPOOL_BOX_ID=box-b)"; has "4. another box holds the lease" "not the dispatch lease holder (c-002@box-a)" "$out"
out="$(auto TAKE_AUTO_TO=c-001)"; has "4. another seat holds the lease" "not the dispatch lease holder" "$out"
lease c-002@box-a "$(( $(date +%s) - 3600 ))"
out="$(auto)"; has "4. a stale lease" "lease is stale" "$out"
lease c-002@box-a "$(date +%s)"
touch "$S/dispatch/take-auto.off"; out="$(auto)"; has "4. the off switch" "off (" "$out"; rm -f "$S/dispatch/take-auto.off"
out="$(auto SPOOL_TENANT=e2e)"; has "4. a test workspace" "test workspace e2e" "$out"
out="$(auto TAKE_AUTO_BODY='@c-001 can you look')"; has "4. a post naming another agent" "names c-001" "$out"
out="$(auto TAKE_AUTO_BODY='@c-002 can you look')"; has "4. a post naming the holder is taken" "TAKEN $TOPIC" "$out"
: >"$REPLY_LOG"; : >"$S/dispatch/take.log"
touch "$TAIL_FILE.fail"; out="$(auto)"; has "4. a failed hub tail: fail closed" "could not be read" "$out"; rm -f "$TAIL_FILE.fail"
eq "4. none of the skips posted" 0 "$(n "$REPLY_LOG")"
out="$(auto TAKE_AUTO_FROM=c-005)"; has "4. a sender that is not a human is refused" "FATAL TAKE_AUTO_FROM" "$out"

# ---- 5. DRY_RUN --------------------------------------------------------------
out="$(auto DRY_RUN=1)"
has "5. DRY_RUN says what it would post" "DRY_RUN would post to HUM-10" "$out"
eq "5. DRY_RUN posts nothing" 0 "$(n "$REPLY_LOG")"

# ---- 6. the notifier gate ----------------------------------------------------
cat >"$T/run" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$*" "$TAKE_AUTO_TO" "$TAKE_AUTO_FROM" "$TAKE_AUTO_TASK" "$TAKE_AUTO_DESK_ROOT" "$SPOOL_ROOT" "$DRY_RUN" "$TAKE_AUTO_BODY" >>"$RUN_LOG"
EOF
chmod +x "$T/run"
export RUN_LOG="$T/run.log"
gate() {  # TO FROM KIND TASK BODY [VAR=VAL ...]
  local to="$1" from="$2" kind="$3" task="$4" body="$5"; shift 5
  env -i PATH="$PATH" HOME="$HOME" RUN_LOG="$RUN_LOG" SPOOL_ROOT="$DESK" SPOOL_FLEET_ROOT="$S" SPOOL_BOX_ID=box-a \
    SPOOL_TAKE_AUTO_RUN="$T/run" FEAT="$FEAT" "$@" bash -c '
    . "$FEAT/lib/spool-notify.inc.sh"; . "$FEAT/lib/spool-notify-take.inc.sh"
    spool_notify_take_auto "$0" "$1" "$2" "$3" m-1 "$4"' "$to" "$from" "$kind" "$task" "$body"
}
waitrun() { local _; for _ in $(seq 1 50); do [[ "$(n "$RUN_LOG")" -ge "$1" ]] && return 0; sleep 0.1; done; return 1; }
gate c-002 HUM-10 note "$TOPIC" 'why is the build red'
waitrun 1
eq "6. a human post to the holder starts the action" 1 "$(n "$RUN_LOG")"
eq "6. with the action, the seat, the human, the topic, the desk root, the box root, DRY_RUN=0" \
  "-a do_spl_take_auto|c-002|HUM-10|$TOPIC|$DESK|$S|0|why is the build red" "$(head -1 "$RUN_LOG")"
gate c-002 c-003 note "$TOPIC" 'agent'
gate c-001 HUM-10 note "$TOPIC" 'not the holder'
gate c-002 HUM-10 note "$TOPIC" '[spool-probe] x'
gate c-002 HUM-10 note T-1 'short id'
gate c-002 HUM-10 result "$TOPIC" 'a result kind'
gate c-002 HUM-10 note "$TOPIC" 'other box' SPOOL_BOX_ID=box-b
gate c-002 HUM-10 note "$TOPIC" 'no fleet root' SPOOL_FLEET_ROOT=
touch "$S/dispatch/take-auto.off"; gate c-002 HUM-10 note "$TOPIC" 'off'; rm -f "$S/dispatch/take-auto.off"
sleep 1
eq "6. agent sender, non-holder, probe, short id, result, other box, no fleet root, off: nothing started" 1 "$(n "$RUN_LOG")"

# ---- 7. wiring -----------------------------------------------------------------
SN="$FEAT/scripts/spool-notify.sh"
eq "7. spool-notify.sh sources the take lib" 1 "$(grep -c '^\. "\$_here/../lib/spool-notify-take.inc.sh"' "$SN")"
eq "7. spool-notify.sh calls the gate with the delivery" 1 "$(grep -c '^spool_notify_take_auto "\$TO" "\$FROM" "\$KIND" "\$TASK" "\$MSGID" "\$BODY"$' "$SN")"
eq "7. the lib's default ./run is the orc run" "$PROJ_ROOT/run" "$(. "$FEAT/lib/spool-notify-take.inc.sh"; echo "$SPOOL_NOTIFY_TAKE_RUN_DEFAULT")"

# ---- 8. sole seat (SPL-3542) -------------------------------------------------
DOC=00000000-0000-4000-8000-0000000000d1
printf 't1\tsole\t%s\tprd\tc-423\tc-423@box-z\nt1\tops\t%s\tprd\tc-001\nt1\tdash\t%s\tprd\tc-001\t-\n' "$DOC" "$DOC" "$DOC" >"$S/channel-rules.tsv"
lease c-002@box-a "$(date +%s)"
fresh() { : >"$REPLY_LOG"; : >"$S/dispatch/take.log"; : >"$S/dispatch/take-auto.log"; }
fresh; row HUM-10 ALL-0 'q' sole >"$TAIL_FILE"
out="$(auto)"
has "8. a human post in a sole-seat channel: skipped, why" "sole-seat channel #sole: only c-423@box-z posts there" "$out"
eq "8. no take line in a sole-seat channel" 0 "$(n "$REPLY_LOG")"
has "8. one log line says why" "skip sole-seat channel #sole" "$(cat "$S/dispatch/take-auto.log")"
eq "8. exactly one log line" 1 "$(n "$S/dispatch/take-auto.log")"
fresh; row HUM-10 ALL-0 'q' '#Sole' >"$TAIL_FILE"
out="$(auto)"; has "8. the channel as '#Sole' is the same channel" "sole-seat channel #sole" "$out"
fresh; { row HUM-10 ALL-0 'q' ops ma-1; row c-009 c-002 'relay' sole; } >"$TAIL_FILE"
out="$(auto TAKE_AUTO_MSGID=ma-1)"; has "8. any channel the topic touches counts" "sole-seat channel #sole" "$out"
eq "8. none of those posted" 0 "$(n "$REPLY_LOG")"
fresh; row HUM-10 ALL-0 'q' ops >"$TAIL_FILE"
out="$(auto)"; has "8. a normal channel still takes" "TAKEN $TOPIC by c-002@box-a" "$out"
fresh; row HUM-10 ALL-0 'q' dash >"$TAIL_FILE"
out="$(auto)"; has "8. a '-' sole seat column is no sole seat" "TAKEN $TOPIC" "$out"
fresh; row HUM-10 c-002 'q' '' >"$TAIL_FILE"
out="$(auto)"; has "8. a DM (channel \"\") still takes" "TAKEN $TOPIC" "$out"
fresh; lease c-423@box-z "$(date +%s)"; row HUM-10 ALL-0 'q' sole >"$TAIL_FILE"
out="$(auto TAKE_AUTO_TO=c-423 SPOOL_BOX_ID=box-z)"; has "8. the sole seat itself still takes" "TAKEN $TOPIC by c-423@box-z" "$out"
eq "8. the sole seat posted its take line" 1 "$(n "$REPLY_LOG")"
lease c-002@box-a "$(date +%s)"
fresh; printf '{"v":1,"msg_id":"m-x","from":"HUM-10","to":"ALL-0","kind":"note","task_id":"%s","body":"q"}\n' "$TOPIC" >"$TAIL_FILE"
out="$(auto)"; has "8. a tail without the channel field: no post" "does not say which channel the post is in" "$out"
fresh; row HUM-10 ALL-0 'q' ops ma-2 >"$TAIL_FILE"
out="$(auto TAKE_AUTO_MSGID=ma-9)"; has "8. the post's own row is not in the tail: no post" "does not say which channel" "$out"
fresh; : >"$TAIL_FILE"; out="$(auto)"; has "8. an empty tail: no post" "does not say which channel" "$out"
fresh; printf 't1\tsole\t%s\tprd\tc-423\tc-423\n' "$DOC" >"$S/channel-rules.tsv"; row HUM-10 ALL-0 'q' sole >"$TAIL_FILE"
out="$(auto)"; has "8. a malformed sole seat column: no post" "cannot tell the sole seat of #sole" "$out"
chmod 000 "$S/channel-rules.tsv"
if [[ -r "$S/channel-rules.tsv" ]]; then pass "8. an unreadable map (skipped: this user reads mode 000)"
else fresh; out="$(auto)"; has "8. an unreadable map: no post" "cannot tell the sole seat" "$out"; fi
chmod 644 "$S/channel-rules.tsv"
eq "8. none of the fail-closed cases posted" 0 "$(n "$REPLY_LOG")"
rm -f "$S/channel-rules.tsv"; fresh; row HUM-10 ALL-0 'q' sole >"$TAIL_FILE"
out="$(auto)"; has "8. no box map: no channel has a sole seat" "TAKEN $TOPIC" "$out"

# ---- control: no sole-seat check -> the sole-seat post is taken ----------------
printf 't1\tsole\t%s\tprd\tc-423\tc-423@box-z\n' "$DOC" >"$S/channel-rules.tsv"
sed 's/^  why="\$(spl_take_auto_sole .*$/  :/' "$PROJ_ROOT/src/bash/run/spl-take-auto.func.sh" >"$T/planted-sole.func.sh"
fresh; row HUM-10 ALL-0 'q' sole >"$TAIL_FILE"
auto TAKE_AUTO_FUNC="$T/planted-sole.func.sh" >/dev/null
eq "control: the planted copy takes a sole-seat post (section 8 would be red)" 1 "$(n "$REPLY_LOG")"

# ---- control: no owner check -> an owned topic is taken ------------------------
sed 's/^  \[\[ -n "\$owner" \]\] && { echo "owned:.*$/  :/' "$PROJ_ROOT/src/bash/run/spl-take-auto.func.sh" >"$T/planted.func.sh"
{ row HUM-10 ALL-0 'q'; row g-002 ALL-0 'an answer'; } >"$TAIL_FILE"
: >"$REPLY_LOG"; : >"$S/dispatch/take.log"
auto TAKE_AUTO_FUNC="$T/planted.func.sh" >/dev/null
eq "control: the planted copy takes an owned topic (assertion 3 would be red)" 1 "$(n "$REPLY_LOG")"

echo "---"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
