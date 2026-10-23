#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3062 (how-to-post.md section 7) - do_spl_desk_reply and
#          do_spl_desk_post refuse a body whose ```poll fence would not
#          render as a form, and send every other body as before. Owner
#          HUM-10, msg fb2b4cdf: a form whose options were written in a
#          wrong form showed as a code block, and the owner saw it first.
#          The verdict is the WUI's poll.mjs (pollProblems), run by node.
#   1. RED CONTROL: a question with a wrong option form (`A) x`) is refused,
#      one FATAL naming the question and the line, the valid syntax, nothing
#      reaches the spool
#   2. radios and checkboxes mixed -> refused
#   3. a key twice in one question -> refused
#   4. two ```poll fences -> refused (one form per message)
#   5. an unclosed ```poll fence -> refused
#   6. a valid radio form, a valid checkbox form, a Go button, task-list
#      options (`[ ] (A) x`, poll.mjs SPL-3062) -> sent, body unchanged
#   7. no poll at all, and a ```poll inside a longer fence -> sent
#   8. do_spl_desk_post: the same guard on a channel post
#   9. no poll.mjs on the box: one WARN, the post is sent unchecked
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=348d8011-0000-4000-8000-000000000001

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a prev=""; for a in "$@"; do [[ "$prev" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}'

# send <action> <body> [VAR=value]... -> rc; output in $T/o, the sent body in $T/sent
send() {
  local act="$1" body="$2"; shift 2
  rm -f "$T/sent"
  SNIPPET="$STUBS"$'\n'"$act" in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-10 DESK_TASK="$TOPIC" \
    DESK_CHANNEL=ops DESK_BODY="$body" DRY_RUN=0 SENT_BODY="$T/sent" "$@" >"$T/o" 2>&1
}
refused() { # <label> <must-name>...: rc != 0, nothing sent, the FATAL names each piece and the syntax
  local label="$1" n ok=1; shift
  (( rc != 0 )) && [[ ! -e "$T/sent" ]] && grep -q 'FATAL nothing was sent: the form would show as a code block' "$T/o" &&
    grep -q 'how-to-post.md section 7' "$T/o" && grep -qF '`(A) text` (pick one) or `[A] text` (pick any)' "$T/o" || ok=0
  for n in "$@"; do grep -qF -- "$n" "$T/o" || ok=0; done
  (( ok )) && pass "$label" || fail "$label (rc $rc): $(cat "$T/o")"
}
sent() { # <label> <body>: rc 0 and the body reached the spool byte for byte
  (( rc == 0 )) && [[ -f "$T/sent" && "$(cat "$T/sent")" == "$2" ]] && ! grep -q FATAL "$T/o" &&
    pass "$1" || fail "$1 (rc $rc, sent '$(cat "$T/sent" 2>/dev/null)'): $(cat "$T/o")"
}
F='```'

# --- 1. RED CONTROL: a wrong option form ------------------------------------------
B="Pick one:"$'\n\n'"${F}poll"$'\nWhat should we do?\nA) Open an issue\nB) Wait\n'"$F"
send do_spl_desk_reply "$B"; rc=$?
refused "1. a question whose options are no option lines is refused, nothing sent" \
  'FATAL poll form: the ```poll fence of line 3 is no form: question "What should we do? A) Open an issue B) Wait" has no option line; not an option line: "A) Open an issue"'
[[ "$(grep -c 'FATAL poll form:' "$T/o")" == 1 ]] && pass "1. one FATAL line for the one problem" || fail "1. FATAL count: $(cat "$T/o")"
B1="${B//A) /(A) }"; B1="${B1//B) /(B) }"
send do_spl_desk_reply "$B1"; rc=$?
sent "1. CONTROL: the same form with (A) / (B) options is sent" "$B1"

# --- 2. mixed -------------------------------------------------------------------------
send do_spl_desk_reply "${F}poll"$'\nQ\n(A) x\n[B] y\n'"$F"; rc=$?
refused "2. radios and checkboxes mixed are refused" 'radios `(A)` and checkboxes `[A]` are mixed ("[B] y")'

# --- 3. a key twice ---------------------------------------------------------------------
send do_spl_desk_reply "${F}poll"$'\nQ\n(A) x\n(a) y\n'"$F"; rc=$?
refused "3. a key twice in one question is refused" 'key A twice in question "Q"'

# --- 4. two fences ------------------------------------------------------------------------
GOOD="${F}poll"$'\nDeploy?\n(A) now\n(B) later\n'"$F"
send do_spl_desk_reply "$GOOD"$'\n\n'"$GOOD"; rc=$?
refused "4. a second poll fence is refused" 'a second ```poll fence (line 7): one form per message'

# --- 5. unclosed --------------------------------------------------------------------------
send do_spl_desk_reply "${F}poll"$'\nQ\n(A) x'; rc=$?
refused "5. an unclosed poll fence is refused" 'the ```poll fence of line 1 is never closed'

# --- 6. valid forms -----------------------------------------------------------------------
for B in "$GOOD" "${F}poll"$'\nWhich envs?\n- [a] dev\n- [b] prd\n'"$F" "${F}poll"$'\nGo?\n(GO) Go\n'"$F" \
  "${F}poll"$'\nWhat now?\n[ ] (A) Open an issue\n- [ ] (B) Wait\n'"$F"; do
  send do_spl_desk_reply "$B"; rc=$?
  sent "6. a valid form is sent: '$(sed -n 3p <<<"$B")'" "$B"
done

# --- 7. no poll / nested -------------------------------------------------------------------
send do_spl_desk_reply 'Plain text, a `poll` word, no fence.'; rc=$?
sent "7. a body with no poll fence is sent" 'Plain text, a `poll` word, no fence.'
B='````text'$'\n'"${F}poll"$'\nQ\nA) x\n'"$F"$'\n````'
send do_spl_desk_reply "$B"; rc=$?
sent "7. a poll fence inside a longer fence is its content and is sent" "$B"

# --- 8. do_spl_desk_post -------------------------------------------------------------------
send do_spl_desk_post "${F}poll"$'\nQ\n(A) x\n[B] y\n'"$F"; rc=$?
refused "8. do_spl_desk_post refuses a broken form" 'are mixed'
send do_spl_desk_post "$GOOD"; rc=$?
sent "8. do_spl_desk_post sends a valid form" "$GOOD"

# --- 9. no parser ----------------------------------------------------------------------------
send do_spl_desk_reply "${F}poll"$'\nQ\nA) x\n'"$F" POLL_CHECK_MJS="$T/none.mjs"; rc=$?
(( rc == 0 )) && [[ -f "$T/sent" ]] && grep -q 'WARN the poll form was not checked' "$T/o" &&
  pass "9. no poll.mjs: one WARN, the post is sent unchecked" || fail "9. no poll.mjs (rc $rc): $(cat "$T/o")"

echo "desk-poll-check: $fails failure(s)"
((fails == 0))
