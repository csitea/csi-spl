#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2280 (SDLC round 1 row 12) - do_spl_desk_post refuses a
#          free-text go-ask to the owner ("Shall I proceed?"): most steps need
#          no owner go (rounds rulebook 1.4), and one that does is asked with
#          a ```poll form (how-to-post.md rule 10). The plan measured 66 owner
#          go/yes/ok nudges in a week across 47 topics.
#   1. RED CONTROL: the same action without the guard sends "Shall I
#      proceed?"; with it the post is refused, FATAL quotes the sentence and
#      names the poll form, nothing reaches the spool (dry run and real run)
#   2. a plain request for a go with no '?' ("waiting for your go") is refused
#   3. a ```poll form, the single (GO) button included, is sent unchanged
#   4. a named owner gate passes: "needs owner go for terraform apply step
#      040", an IAM change, a prd restart, a gate named only in `code`
#   5. not an ask: a statement about a go, a > quote of the owner, inline
#      code, plain "should" / "approved" -> sent
#   6. SPOOL_GO_ASK_OK=1 skips the check
# No cloud call: the hub seams are stubbed, as in desk-live-proof.tst.sh.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a prev=""; for a in "$@"; do [[ "$prev" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}'

# post <body> [VAR=value]... -> rc; output in $T/o, the sent body in $T/sent
post() {
  local body="$1"; shift
  rm -f "$T/sent"
  SNIPPET="$STUBS"$'\n'"${PRE:-}"$'\n'do_spl_desk_post in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 \
    DESK_CHANNEL=ops DESK_BODY="$body" DRY_RUN=0 SENT_BODY="$T/sent" "$@" >"$T/o" 2>&1
}
refused() { # <label> <sentence>: rc != 0, nothing sent, FATAL quotes it and names the poll form
  if (( rc != 0 )) && [[ ! -e "$T/sent" ]] && grep -qF "FATAL a free-text go-ask to the owner: \"$2\"" "$T/o" &&
    grep -qF '```poll form' "$T/o" && grep -q 'Nothing was sent' "$T/o"; then pass "$1"; else fail "$1 (rc=$rc): $(cat "$T/o")"; fi
}
sent() { # <label> <body>: rc 0 and the body reached the spool unchanged
  if (( rc == 0 )) && [[ -e "$T/sent" && "$(cat "$T/sent")" == "$2" ]]; then pass "$1"; else fail "$1 (rc=$rc): $(cat "$T/o")"; fi
}

# --- 1. red control ---------------------------------------------------------------
ASK='Batch 1 is built and green. Shall I proceed?'
sed '/go-ask-guard.inc.sh/d; /spl_go_ask_check/d; /local ask$/d' "$PROJ_ROOT/src/bash/run/spl-desk-post.func.sh" >"$T/old-post.func.sh"
if grep -q spl_go_ask "$T/old-post.func.sh"; then fail "1. the control still carries the guard"; else pass "1. the control has no guard"; fi
PRE="source $T/old-post.func.sh" post "$ASK"; rc=$?
sent "1. RED CONTROL: without the guard 'Shall I proceed?' is sent" "$ASK"
post "$ASK"; rc=$?
refused "1. 'Shall I proceed?' is refused, nothing sent" "Shall I proceed?"
rm -f "$T/sent"
SNIPPET="$STUBS"$'\n'do_spl_desk_post in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 \
  DESK_CHANNEL=ops DESK_BODY="$ASK" SENT_BODY="$T/sent" >"$T/o" 2>&1; rc=$?
refused "1. a dry run refuses it too" "Shall I proceed?"

# --- 2. a request with no '?' -------------------------------------------------------
post 'Landed on master. Waiting for your go.'; rc=$?
refused "2. 'Waiting for your go.' is refused" "Waiting for your go."
post 'Do you want me to start the lane now?'; rc=$?
refused "2. 'Do you want me to ...?' is refused" "Do you want me to start the lane now?"

# --- 3. a poll form -------------------------------------------------------------------
for B in $'Restart the hub now?\n\n```poll\n(GO) Go\n```' \
  $'Shall I go this way?\n\n```poll\nWhich way?\n(A) local\n(B) cloud\n```'; do
  post "$B"; rc=$?; L="${B//$'\n'/ }"
  sent "3. a poll form is sent unchanged: '${L:0:22}'" "$B"
done

# --- 4. a named owner gate --------------------------------------------------------------
for B in 'Plan ready; needs owner go for terraform apply step 040.' \
  'The IAM binding is staged. Shall I proceed?' 'The hub on prd hangs. Your go to restart it?' \
  'Two files under `/etc/logrotate.d` need your go.'; do
  post "$B"; rc=$?; L="${B//$'\n'/ }"
  sent "4. a named gate passes: '${L:0:40}'" "$B"
done

# --- 5. not an ask ---------------------------------------------------------------------
for B in 'Done: your GO is recorded, 4 lanes run.' $'You wrote:\n> Shall I proceed?\nyes; it runs now.' \
  'The log says `go?` twice.' 'The lane I should start is running; rows 01-04 approved.' \
  'Which of the two layouts do you want?'; do
  post "$B"; rc=$?; L="${B//$'\n'/ }"
  sent "5. not a go-ask, sent: '${L:0:40}'" "$B"
done

# --- 6. the override ---------------------------------------------------------------------
post "$ASK" SPOOL_GO_ASK_OK=1; rc=$?
sent "6. SPOOL_GO_ASK_OK=1 sends it" "$ASK"

echo "spl-desk-post: $fails failure(s)"
((fails == 0))
