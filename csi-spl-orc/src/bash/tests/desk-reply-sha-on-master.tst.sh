#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5994 (how-to-post.md rule 22) - do_spl_desk_reply refuses a post
#          that names a commit sha "on master" / "landed" when that sha is not
#          an ancestor of origin/master after a fetch (t1 7e9986f3 msg
#          42189c54: "done, b33f2a306 on master", the pre-rebase sha). A
#          fixture repo (DESK_SHA_REPO) and its bare origin; the spool is
#          stubbed, DRY_RUN=0.
#   1. the rebased (pre-rebase) sha "on master" or "landed" -> refused, one
#      FATAL on stderr, nothing posted
#   2. the landed sha -> posted; a topic uuid on the line is no sha
#   3. "not on master" / "not landed yet" with the rebased sha -> posted;
#      a sha on a line with no claim -> posted
#   4. an unknown sha "on master" -> refused; a failed fetch -> refused
#   5. SPL-6751: an 8-hex ask / msg / topic / poll / request / post id (or a
#      /t/ /m/ link, or a list after the id word) on a claim line is no sha
#      -> posted; CONTROL: the rebased sha with an id word after it, or
#      before it with no id word -> still refused
#   (a **Live** post is left to rule 16: desk-live-proof.tst.sh)
# Red control: on origin/master before SPL-5994, case 1 was posted; before
# SPL-6751 (2de10856d), every case 5 post was refused.
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

# The fixture: base and landed on origin/master; pre is the same change
# before the rebase, committed on a side branch that never lands.
g() { git -C "$T/repo" -c user.name=t -c user.email=t@example.com "$@"; }
git init -q --bare "$T/origin.git"
git init -q -b master "$T/repo"
g remote add origin "$T/origin.git"
g commit -q --allow-empty -m base
g push -q origin master
# commit <msg> -> its 9-hex short sha, with a digit and a letter: an
# all-digit word is no sha to the check, so the message is re-made until
# the sha has both.
commit() {
  local i=0 s
  g commit -q --allow-empty -m "$1"
  while s=$(g rev-parse --short=9 HEAD); ! [[ "$s" =~ [0-9] && "$s" =~ [a-f] ]]; do
    i=$((i + 1)); g commit -q --amend --allow-empty -m "$1 $i"
  done
  echo "$s"
}
g checkout -q -b side
PRE=$(commit pre)
g checkout -q master
LANDED=$(commit landed)
g push -q origin master
g update-ref -d refs/remotes/origin/master

# post <body> [repo] -> rc in $rc, stdout in $T/o, stderr in $T/e, the sent
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
    DESK_BODY="$1" DESK_KIND=note DESK_SHA_REPO="${2:-$T/repo}" DRY_RUN=0 SENT_BODY="$T/sent" >"$T/o" 2>"$T/e"
  rc=$?
}
refused() { (( rc != 0 )) && [[ ! -e "$T/sent" ]] && [[ "$(grep -c 'FATAL.*SPL-5994' "$T/e")" == 1 ]] && ! grep -q 'SPL-5994' "$T/o"; }
posted() { (( rc == 0 )) && [[ -f "$T/sent" ]]; }
why() { echo "rc $rc, sent '$(cat "$T/sent" 2>/dev/null)', out: $(cat "$T/o") err: $(cat "$T/e")"; }
CHK=$'\nchecked: git merge-base --is-ancestor'

# --- 1. the rebased sha -----------------------------------------------------------
for b in "SPL-5879 is done, \`$PRE\` on master.$CHK" "Landed: $PRE (the footer fix).$CHK" \
  "The fix is on origin/master as $PRE."; do
  post "$b"
  refused && pass "the rebased sha is refused: '${b:0:28}'" || fail "the rebased sha was not refused: '$b': $(why)"
done
post "SPL-5879 is done, \`$PRE\` on master.$CHK"
grep -q "$PRE" "$T/e" && pass "the FATAL names the sha" || fail "the FATAL does not name the sha: $(why)"

# --- 2. the landed sha ------------------------------------------------------------
post "SPL-5879 is done, \`$LANDED\` on master (topic $TOPIC).$CHK"
posted && pass "the landed sha is posted" || fail "the landed sha was refused: $(why)"
post "Landed $(git -C "$T/repo" rev-parse HEAD~0 2>/dev/null) after the rebase.$CHK"
posted && pass "the full 40-hex landed sha is posted" || fail "the full landed sha was refused: $(why)"

# --- 3. no claim ------------------------------------------------------------------
post "$PRE is not on master, it is the pre-rebase sha; the landed one is $LANDED.$CHK"
posted && pass "'not on master' is no claim" || fail "'not on master' was refused: $(why)"
post "The lane's $PRE is not landed yet; the push is queued."
posted && pass "'not landed yet' is no claim" || fail "'not landed yet' was refused: $(why)"
post $'The lane pushed '"$PRE"$' to its review branch.\nNothing is on master yet.'
posted && pass "a sha on a line without a claim is no claim" || fail "a sha without a claim was refused: $(why)"

# --- 4. unknown sha, failed fetch -------------------------------------------------
post "Landed as deadbeef123 on master.$CHK"
refused && pass "an unknown sha is refused" || fail "an unknown sha was not refused: $(why)"
post "Landed as $LANDED on master.$CHK" "$T/no-such-repo"
refused && grep -q 'fetch' "$T/e" && pass "a failed fetch is refused and says so" || fail "a failed fetch was not refused: $(why)"

# --- 5. ids after an id word are no sha (SPL-6751) --------------------------------
for b in "SPL-6647 is on master as $LANDED (reviewer ask 5ddf4d3a).$CHK" \
  "Landed $LANDED, asks 5ddf4d3a, 6a27166d and 7b1c2d3e answered.$CHK" \
  "On master: $LANDED (owner msg 65a45673 and 591ca574, topic 6a27166d).$CHK" \
  "Landed $LANDED for poll 4e432858, request ab12cd34, post 9f8e7d6c.$CHK" \
  "Landed $LANDED as /t/6a27166d/m/5ddf4d3a asked.$CHK" "Landed $LANDED: message id 1a7c70da.$CHK"; do
  post "$b"
  posted && pass "an id after an id word is no sha: '${b:0:40}'" || fail "an id after an id word was checked as a sha: '$b': $(why)"
done
for b in "SPL-6647 is on master as $PRE (reviewer ask 5ddf4d3a).$CHK" "Ask 5ddf4d3a: landed $PRE.$CHK" \
  "Landed $LANDED and $PRE.$CHK"; do
  post "$b"
  refused && grep -q "$PRE" "$T/e" && pass "CONTROL the rebased sha is still refused: '${b:0:40}'" ||
    fail "CONTROL the rebased sha was not refused: '$b': $(why)"
done

echo "desk-reply-sha-on-master: $fails failure(s)"
((fails == 0))
