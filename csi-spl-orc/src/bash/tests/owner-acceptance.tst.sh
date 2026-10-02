#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: specs/031 — the owner acceptance run (do_spl_owner_acceptance) and
#          the pane assert it leans on (pane-seen.sh). Hermetic: no cloud call,
#          no browser, no tmux server, no spool binary.
#   1. spl_oa_validate takes a task UUID and nothing else. A wrong OA_TOPIC
#      would start a NEW conversation beside the one the owner is reading,
#      which is worse than an error, so the shape is checked before anything
#      is sent. CONTROL: a good uuid passes
#   2. the action inherits the desk id rules (tenant slug, box, agent)
#   3. the dry run makes no gcloud / curl / docker / spool / node / tmux call.
#      CONTROL: the stub log records one when a real call is made
#   4. the dry run NAMES the topic and the peer it would post into — the
#      owner has to be able to read, before DRY_RUN=0, exactly which
#      conversation is about to carry test traffic
#   5. DRY_RUN=0 refuses before it sends when the bot has no password on disk
#      (the member was never seated by do_spl_m3_e2e)
#   6. pane-seen.sh: its argument handling, and — the assert that matters —
#      that it compares with whitespace STRIPPED, because capture-pane hard
#      wraps mid-word and a raw substring would report a delivered message as
#      missing. Driven against a real tmux only when one can be started here;
#      otherwise the wrapping case is driven through the script's own flatten.
#   7. the bot is syntactically valid and needs every input it reads
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux node google-chrome

GOOD=0cd6b6d2-4336-46a2-a0b6-65bb962877ee

# --- 1. the topic rule --------------------------------------------------------
SNIPPET="spl_oa_validate $GOOD" in_orc >/dev/null 2>&1 &&
  pass "CONTROL a task UUID is accepted as OA_TOPIC" || fail "a good uuid was refused"
while read -r desc value; do
  out=$(SNIPPET="spl_oa_validate '${value//_/ }'" in_orc 2>&1)
  if [[ $? -eq 0 ]]; then
    fail "OA_TOPIC accepts $desc — it would start a topic beside the owner's"
  else
    grep -q FATAL <<<"$out" && pass "OA_TOPIC refuses $desc" ||
      fail "OA_TOPIC refuses $desc without saying why: $out"
  fi
done <<'EOF'
an_empty_topic 
a_channel_slug lobby
an_uppercase_uuid 0CD6B6D2-4336-46A2-A0B6-65BB962877EE
a_truncated_uuid 0cd6b6d2-4336-46a2-a0b6
a_uuid_with_a_trailing_path 0cd6b6d2-4336-46a2-a0b6-65bb962877ee/x
EOF

# --- 2. the desk id rules still apply -----------------------------------------
for bad in "'' box-desk CLE-00" "t1 box-wui CLE-00" "t1 box-desk box-desk"; do
  out=$(SNIPPET="spl_desk_validate $bad" in_orc 2>&1)
  [[ $? -ne 0 ]] && pass "the run inherits the desk id rule: refuses ($bad)" ||
    fail "the run accepted a bad desk triple: ($bad)"
done

# --- 3 + 4. the dry run is offline, and says which topic it would post into ---
: >"$T/calls.log"
out=$(SNIPPET='do_spl_owner_acceptance' in_orc TENANT_ID=t1 OA_TOPIC="$GOOD" 2>&1)
rc=$?
[[ $rc -eq 0 ]] && pass "the dry run succeeds without a cloud, a browser or a desk" ||
  fail "the dry run failed (rc=$rc): $out"
[[ ! -s "$T/calls.log" ]] && pass "no gcloud, curl, docker, spool, node or tmux call in the dry run" ||
  fail "the dry run called out: $(cat "$T/calls.log")"
grep -q "$GOOD" <<<"$out" && pass "the dry run NAMES the topic it would post into" ||
  fail "the dry run does not name the topic: $out"
grep -q 'CLE-00@box-desk' <<<"$out" && pass "the dry run names the peer it would talk to" ||
  fail "the dry run does not name the peer: $out"
grep -q 'DRY_RUN=0' <<<"$out" && pass "the dry run says how to really run it" ||
  fail "the dry run does not say how to run it for real: $out"

# CONTROL: the stub log is not empty for a reason other than the test's own care
( PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" gcloud version >/dev/null 2>&1 )
[[ -s "$T/calls.log" ]] && pass "CONTROL the stub log records a real call" ||
  fail "CONTROL the stub log stayed empty — the dry-run check proves nothing"

# --- 5. DRY_RUN=0 refuses before sending when the bot has no password ----------
out=$(SNIPPET='do_spl_owner_acceptance' in_orc TENANT_ID=t1 OA_TOPIC="$GOOD" DRY_RUN=0 2>&1)
if [[ $? -ne 0 ]] && grep -qi 'password\|pw-human\|do_spl_m3_e2e' <<<"$out"; then
  pass "DRY_RUN=0 refuses before it sends when the bot member has no password on disk"
else
  fail "DRY_RUN=0 did not refuse a bot with no password: $out"
fi

# --- 6. pane-seen.sh ----------------------------------------------------------
PS="$PROJ_ROOT/src/bash/scripts/pane-seen.sh"
[[ -x "$PS" ]] && pass "pane-seen.sh is executable" || fail "pane-seen.sh is not executable"
for bad in "--agent CLE-00" "--needle x" "--agent CLE-00 --needle x --timeout soon" "--agent CLE-00 --needle x --what"; do
  out=$(bash "$PS" $bad 2>&1); rc=$?
  [[ $rc -eq 2 ]] && pass "pane-seen.sh refuses '$bad' with a usage error" ||
    fail "pane-seen.sh took '$bad' (rc=$rc): $out"
done
out=$(bash "$PS" --agent CLE-00 --needle '   ' --timeout 1 2>&1); rc=$?
[[ $rc -eq 2 ]] && pass "pane-seen.sh refuses a needle that is only whitespace" ||
  fail "pane-seen.sh took an all-whitespace needle (rc=$rc)"

# A pane that does not exist is "not seen" (exit 1), never a crash and never a
# silent pass: a run whose tmux socket is wrong must FAIL its terminal case.
out=$(bash "$PS" --agent ZZZ-9999 --needle nothing --timeout 1 --sock "$T/no-such.sock" 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q '"seen":false' <<<"$out"; then
  pass "pane-seen.sh reports NOT SEEN (exit 1) when there is no such pane"
else
  fail "pane-seen.sh on a missing pane: rc=$rc out=$out"
fi

# The assert that matters: a hard wrap must not hide a match. Driven against a
# real tmux when one can be started here; otherwise skipped LOUDLY rather than
# passed quietly, since a skipped control proves nothing.
if command -v tmux >/dev/null 2>&1 && [[ "$(command -v tmux)" != "$T/stub/tmux" ]]; then
  sock="$T/tmux.sock"
  long='oa-wrap-needle-that-is-long-enough-to-be-hard-wrapped-by-capture-pane-0123456789'
  if tmux -S "$sock" -f /dev/null new-session -d -s oa -x 20 -y 10 -n "tag: CLE-00 desk" \
       "printf '%s\\n' '$long'; sleep 30" 2>/dev/null; then
    sleep 1
    out=$(bash "$PS" --agent CLE-00 --needle "$long" --timeout 5 --sock "$sock" 2>&1); rc=$?
    [[ $rc -eq 0 ]] && pass "pane-seen.sh finds a needle that capture-pane HARD WRAPPED across lines" ||
      fail "pane-seen.sh missed a hard-wrapped needle (rc=$rc): $out"
    # CONTROL: it is not simply saying yes to everything
    out=$(bash "$PS" --agent CLE-00 --needle 'oa-wrap-needle-that-was-never-printed' --timeout 1 --sock "$sock" 2>&1); rc=$?
    [[ $rc -eq 1 ]] && pass "CONTROL pane-seen.sh says NOT SEEN for text that is not in the pane" ||
      fail "CONTROL pane-seen.sh claimed to see text that was never printed (rc=$rc)"
    # the window name carries a box tag, so this also proves the tag is stripped
    tmux -S "$sock" kill-server 2>/dev/null
  else
    fail "could not start a private tmux server for the wrap control (it proves nothing unskipped)"
  fi
else
  fail "no real tmux on PATH: the hard-wrap control did not run and proves nothing"
fi

# --- 7. the bot script ---------------------------------------------------------
BOT="$APP_ROOT/csi-spl-wui/tests/e2e/owner-acceptance-bot.proof.mjs"
[[ -f "$BOT" ]] && pass "the acceptance bot is in the tree" || fail "no acceptance bot at $BOT"
if command -v node >/dev/null 2>&1 && [[ "$(command -v node)" != "$T/stub/node" ]]; then
  node --check "$BOT" >/dev/null 2>&1 && pass "the acceptance bot parses" || fail "the acceptance bot does not parse"
  for v in BASE OUT EMAIL PEER OWNER_TOPIC PW_FILE; do
    grep -q "need('$v')" "$BOT" && pass "the bot fails fast without $v" ||
      fail "the bot does not require $v — it would run against a default nobody chose"
  done
  grep -q "PW" "$BOT" && ! grep -qE "console\.log\(.*PW[^_]" "$BOT" &&
    pass "the bot never prints the password" || fail "the bot may print the password"
else
  fail "no real node on PATH: the bot was not parsed"
fi

echo "=== owner-acceptance.tst.sh: $fails failure(s)"
[[ "$fails" -eq 0 ]]
