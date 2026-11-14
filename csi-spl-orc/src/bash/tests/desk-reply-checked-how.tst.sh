#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5518 (how-to-post.md rule 22) - do_spl_desk_reply refuses a post
#          whose first line claims done work (a word of
#          csi-spl-orc/cnf/desk-reply/done-claim-words.txt) and carries no
#          `checked:` line; the spool is stubbed, DRY_RUN=0.
#   1. a done claim without the line -> rc != 0, one FATAL on stderr, no post
#   2. the same claim with a `checked:` line (or `Checked how:`) -> posted
#   3. a note that claims nothing -> posted
#   4. exempt: a blocker, a question, a negated or future word, a word
#      before ", not" (rule 16's **Landed, not live yet**) or before a "?" in
#      its clause -> posted
#   5. the first line of 29355715 (csitea 13a90dc3, taken back by 7a49e5cb)
#      -> refused
# Red control: on origin/master before SPL-5518, cases 1 and 5 were posted.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=b280b0e8-1111-4222-8333-444455556666
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
echo pub >"$T/state/dev/desk/t1/box-desk/pinned"

# post <body> [kind] -> rc in $rc, stdout in $T/o, stderr in $T/e, the sent
# body (if any) in $T/sent
post() {
  rm -f "$T/sent"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a; for a in "$@"; do [[ "${prev:-}" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}
do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-1 DESK_TASK="$TOPIC" \
    DESK_BODY="$1" DESK_KIND="${2:-note}" DRY_RUN=0 SENT_BODY="$T/sent" >"$T/o" 2>"$T/e"
  rc=$?
}
refused() { (( rc != 0 )) && [[ ! -e "$T/sent" ]] && [[ "$(grep -c 'FATAL.*rule 22' "$T/e")" == 1 ]] && ! grep -q 'rule 22' "$T/o"; }
posted() { (( rc == 0 )) && [[ -f "$T/sent" ]]; }
why() { echo "rc $rc, sent '$(cat "$T/sent" 2>/dev/null)', out: $(cat "$T/o") err: $(cat "$T/e")"; }

# --- 1. a done claim without the line -------------------------------------------
for b in "**Done.** The footer shows the version on dev and prd." \
  "Landed: 0226b4191aa3 on master." \
  "@HUM-1 The footer bug is fixed."; do
  post "$b"
  refused && pass "refused, rc $rc, one FATAL on stderr, nothing posted: '${b:0:30}'" || fail "not refused: '$b': $(why)"
done
post "**Done.** The footer shows the version."
grep -q "claims 'Done'" "$T/e" && pass "the FATAL names the claim word" || fail "the FATAL does not name the word: $(why)"

# --- 2. with the line: posted ----------------------------------------------------
post $'**Done.** The footer shows the version on dev and prd.\nchecked: opened /about on dev and prd, both show v1.4.2'
posted && pass "a done claim WITH a checked: line is posted" || fail "a checked claim was not posted: $(why)"
post $'Fixed the footer bug.\n- **Checked how:** reloaded the page twice'
posted && pass "a 'Checked how:' line counts too" || fail "Checked how: was not accepted: $(why)"
post $'Fixed the footer bug.\nnot checked: the phone view'
refused && pass "a 'not checked:' line alone is no 'checked:' line" || fail "'not checked:' alone passed: $(why)"

# --- 3. a note that claims nothing: posted -------------------------------------
post "Ask ec43caa4 is queued, position 2: claude weekly limit on the box."
posted && pass "a note that claims nothing is posted" || fail "a plain note was refused: $(why)"
post $'The plan has three steps.\nStep 2 is done once the tests pass.'
posted && pass "a claim word below the first line is no claim" || fail "a later-line word was refused: $(why)"

# --- 4. exempt: blocker, question, negated or future word ----------------------
post "**Done** with what I can do: the deploy needs your GO." blocker
posted && pass "a blocker is exempt" || fail "a blocker was refused: $(why)"
post "Is the footer fix live on prd for you?"
posted && pass "a question is exempt" || fail "a question was refused: $(why)"
post "The footer is not fixed yet; the cause is still open."
posted && pass "'not fixed' is no claim" || fail "a negated word was refused: $(why)"
post "The footer will be fixed after the rebase."
posted && pass "'will be fixed' is no claim" || fail "a future word was refused: $(why)"
post "**Landed, not live yet.** On master, prd still serves the commit before it."
posted && pass "rule 16's **Landed, not live yet** is no claim" || fail "'Landed, not live yet' was refused: $(why)"
post "The cards are Live now? no: plain text is not a state."
posted && pass "a claim word before a '?' in its clause is no claim" || fail "'Live now? no' was refused: $(why)"
post "The donor list and the deadline are attached."
posted && pass "a word that only starts with a claim word (donor, deadline) is no claim" || fail "a partial word was refused: $(why)"

# --- 5. the post 7a49e5cb took back --------------------------------------------
post "**The customer's desk stayed on the old user. Both move attempts rolled back by themselves, and the desk is running normally again.** The fix to the move's check is queued."
refused && pass "29355715's first line ('running normally') is refused" || fail "29355715 was posted: $(why)"

echo "desk-reply-checked-how: $fails failure(s)"
((fails == 0))
