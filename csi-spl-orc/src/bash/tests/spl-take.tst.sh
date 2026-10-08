#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_take (SPEC-spool-fleet-roles.md 3, t1 bc1a43e1 fix C) over a
#          scratch spool root, a fake do_spl_desk_reply (TAKE_REPLY_CMD) and a
#          fake spool-send (TAKE_SEND). No hub, no spool binary is touched.
#   1. DRY_RUN (default) posts nothing and records nothing
#   2. DRY_RUN=0: exactly ONE take line to the human, in the topic, kind note,
#      with the taker's id@box and the plan; ledger has one row; the agents in
#      TAKE_NOTIFY get one note each, on the topic's task
#   3. idempotent: a second take of the same (topic, taker) posts nothing and
#      sends nothing (count stays 1); another taker or another topic posts
#   4. a failed post is not recorded and sends no note; a re-run posts it
#   5. a failed note is a WARN: the take still succeeds
#   6. refusals: bad ENV, DESK_TO not a human, a topic prefix, empty plan,
#      SPOOL_TEST=1 without TAKE_REPLY_CMD
#   7. wiring: the dispatcher brief teaches the take command and it matches
#      a dispatcher allow rule
#   control: with the ledger check removed (a planted copy), the second take
#      posts again -> the idempotency assertion would turn red
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

S="$T/spool"; mkdir -p "$S/dispatch"
TOPIC=00000000-0000-4000-8000-0000000000a1
TOPIC2=00000000-0000-4000-8000-0000000000a2
# the fake desk reply: one line per post; fails while $REPLY_LOG.fail exists
cat >"$T/reply.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$REPLY_LOG.fail" ] && exit 9
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ENV" "$TENANT_ID" "$DESK_AGENT" "$DESK_TO" "$DESK_TASK" "$DESK_KIND" "$DESK_BODY" >>"$REPLY_LOG"
EOF
cat >"$T/send.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$SEND_LOG.fail" ] && exit 11
echo "$*" >>"$SEND_LOG"
EOF
chmod +x "$T/reply.sh" "$T/send.sh"
export REPLY_LOG="$T/reply.log" SEND_LOG="$T/send.log"

# take [VAR=VAL ...]: run do_spl_take in a clean shell with the stubs
take() {
  env -i PATH="$PATH" HOME="$HOME" PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_TEST=1 \
    REPLY_LOG="$REPLY_LOG" SEND_LOG="$SEND_LOG" TAKE_REPLY_CMD="$T/reply.sh" TAKE_SEND="$T/send.sh" \
    ENV=prd TENANT_ID=csitea DESK_AGENT=c-002 DESK_TO=HUM-10 DESK_TASK="$TOPIC" TAKE_BOX=box-a \
    TAKE_PLAN='I read the hub logs and post the cause' "$@" bash -c '
    do_log() { echo "$*" >&2; }
    source "$PROJ_PATH/lib/bash/funcs/spl-desk-box.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "${TAKE_FUNC:-$PROJ_PATH/src/bash/run/spl-take.func.sh}"
    do_spl_take'
}
n() { [[ -f "$1" ]] && wc -l <"$1" | tr -d ' ' || echo 0; }

# 1. dry run
take >"$T/o" 2>&1 || fail "1. dry run exited non-zero: $(cat "$T/o")"
[[ "$(n "$REPLY_LOG")" == 0 && ! -f "$S/dispatch/take.log" ]] && pass "1. dry run posts and records nothing" || fail "1. dry run wrote"

# 2. the take
take DRY_RUN=0 TAKE_NOTIFY='c-001 c-003' >"$T/o" 2>&1 || fail "2. take failed: $(cat "$T/o")"
[[ "$(n "$REPLY_LOG")" == 1 ]] && pass "2. exactly one take line posted" || fail "2. posts: $(n "$REPLY_LOG")"
IFS=$'\t' read -r e tn ag to tk kd bd <"$REPLY_LOG"
[[ "$e $tn $ag $to $tk $kd" == "prd csitea c-002 HUM-10 $TOPIC note" ]] && pass "2. to the human, in the topic, kind note" ||
  fail "2. wrong route: $e $tn $ag $to $tk $kd"
[[ "$bd" == "Taken by c-002@box-a: I read the hub logs and post the cause. I post the result here." ]] &&
  pass "2. the body names the taker and the plan" || fail "2. body: $bd"
[[ "$(n "$S/dispatch/take.log")" == 1 ]] && pass "2. one ledger row" || fail "2. ledger rows: $(n "$S/dispatch/take.log")"
[[ "$(n "$SEND_LOG")" == 2 ]] && grep -q -- "--to c-001 --kind note --task $TOPIC" "$SEND_LOG" &&
  grep -q -- "--to c-003 " "$SEND_LOG" && pass "2. one note per TAKE_NOTIFY id on the topic" || fail "2. notes: $(cat "$SEND_LOG" 2>/dev/null)"
grep -q "^TAKEN $TOPIC by c-002@box-a" "$T/o" && pass "2. prints TAKEN" || fail "2. output: $(cat "$T/o")"

# 3. idempotent
take DRY_RUN=0 TAKE_NOTIFY='c-001' >"$T/o" 2>&1 || fail "3. second take exited non-zero"
[[ "$(n "$REPLY_LOG")" == 1 && "$(n "$SEND_LOG")" == 2 ]] && grep -q TAKEN-ALREADY "$T/o" &&
  pass "3. a second take of the same topic+taker posts and sends nothing" || fail "3. posts $(n "$REPLY_LOG"), notes $(n "$SEND_LOG")"
take DRY_RUN=0 DESK_TASK="${TOPIC^^}" >"$T/o" 2>&1
[[ "$(n "$REPLY_LOG")" == 1 ]] && pass "3. the uppercase uuid is the same topic" || fail "3. uppercase posted again"
take DRY_RUN=0 DESK_AGENT=c-001 TAKE_BOX=box-b >"$T/o" 2>&1
take DRY_RUN=0 DESK_TASK="$TOPIC2" >>"$T/o" 2>&1
[[ "$(n "$REPLY_LOG")" == 3 && "$(n "$S/dispatch/take.log")" == 3 ]] && pass "3. another taker / another topic each post once" ||
  fail "3. posts $(n "$REPLY_LOG")"

# 4. a failed post
: >"$REPLY_LOG.fail"
take DRY_RUN=0 DESK_TASK=00000000-0000-4000-8000-0000000000a3 TAKE_NOTIFY=c-001 >"$T/o" 2>&1 && fail "4. a failed post exited 0" || pass "4. a failed post fails"
[[ "$(n "$S/dispatch/take.log")" == 3 && "$(n "$SEND_LOG")" == 2 ]] && pass "4. nothing recorded, no note" || fail "4. recorded or noted"
rm -f "$REPLY_LOG.fail"
take DRY_RUN=0 DESK_TASK=00000000-0000-4000-8000-0000000000a3 >"$T/o" 2>&1
[[ "$(n "$REPLY_LOG")" == 4 ]] && pass "4. the re-run posts it" || fail "4. re-run posts $(n "$REPLY_LOG")"

# 5. a failed note
: >"$SEND_LOG.fail"
take DRY_RUN=0 DESK_TASK=00000000-0000-4000-8000-0000000000a4 TAKE_NOTIFY=c-001 >"$T/o" 2>&1 &&
  grep -q "WARN could not tell c-001" "$T/o" && pass "5. a failed note is a WARN" || fail "5. $(cat "$T/o")"
rm -f "$SEND_LOG.fail"

# 6. refusals
before="$(n "$REPLY_LOG")"
take DRY_RUN=0 ENV=stage >/dev/null 2>&1 && fail "6. ENV=stage accepted" || pass "6. bad ENV refused"
take DRY_RUN=0 DESK_TO=c-001 DESK_TASK=00000000-0000-4000-8000-0000000000b1 >/dev/null 2>&1 && fail "6. agent as DESK_TO accepted" || pass "6. DESK_TO must be a human"
take DRY_RUN=0 DESK_TASK=00000000 >/dev/null 2>&1 && fail "6. topic prefix accepted" || pass "6. a topic prefix is refused"
take DRY_RUN=0 TAKE_PLAN='  ' DESK_TASK=00000000-0000-4000-8000-0000000000b2 >/dev/null 2>&1 && fail "6. empty plan accepted" || pass "6. an empty plan is refused"
take DRY_RUN=0 TAKE_REPLY_CMD= DESK_TASK=00000000-0000-4000-8000-0000000000b3 >/dev/null 2>&1; rc=$?
[[ $rc == 96 ]] && pass "6. SPOOL_TEST=1 without TAKE_REPLY_CMD exits 96" || fail "6. SPOOL_TEST guard rc=$rc"
[[ "$(n "$REPLY_LOG")" == "$before" ]] && pass "6. no refusal posted" || fail "6. a refusal posted"

# 7. wiring: the brief template renders the take command, and that command
#    (one command, no $(), no &&) matches one of the dispatcher's allow rules
grep -qF '{TAKE_CMD}' "$PROJ_ROOT/src/bash/features/dispatch/brief-dispatcher.tpl.md" &&
  pass "7. the dispatcher brief teaches the take command" || fail "7. brief does not carry {TAKE_CMD}"
env -i PATH="$PATH" PROJ_PATH="$PROJ_ROOT" DISPATCH_BOX_USER=box ENV=prd T="$T" bash -c '
  source "$PROJ_PATH/src/bash/run/spl-dispatch-setup.func.sh"
  source "$PROJ_PATH/src/bash/run/spl-dispatch-check.func.sh"
  spl_dispatch_settings_json c-002 >"$T/settings.json"
  cmd="$(spl_dispatch_take_cmd c-002)"
  [[ "$cmd" == *"./run -a do_spl_take" ]] && spl_dispatch_rule_allows "$T/settings.json" "$cmd"' 2>"$T/o" &&
  pass "7. the taught take command matches a dispatcher allow rule" || fail "7. take command not allowed: $(cat "$T/o")"

# control: the same second take without the ledger check posts twice
sed 's/if spl_take_seen "\$f" "\$task" "\$by"; then/if false; then/; s/spl_take_seen "\$f" "\$task" "\$by" \&\&/false \&\&/' \
  "$PROJ_ROOT/src/bash/run/spl-take.func.sh" >"$T/planted.func.sh"
C="$T/ctl.log"
REPLY_LOG="$C" take DRY_RUN=0 TAKE_FUNC="$T/planted.func.sh" DESK_TASK=00000000-0000-4000-8000-0000000000c1 >/dev/null 2>&1
REPLY_LOG="$C" take DRY_RUN=0 TAKE_FUNC="$T/planted.func.sh" DESK_TASK=00000000-0000-4000-8000-0000000000c1 >/dev/null 2>&1
[[ "$(n "$C")" == 2 ]] && pass "control: without the ledger check the take line is posted twice" ||
  fail "control: planted copy posted $(n "$C") (the idempotency test would not see a regression)"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
