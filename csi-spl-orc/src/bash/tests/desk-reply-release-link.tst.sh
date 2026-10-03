#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 065 L9 (7.3) - do_spl_desk_reply, the dispatcher's relay to the
#          owner, WARNS on a post that says released / deployed with a commit
#          sha but no /releases/ link for it, and never drops or rewrites it.
#   1. released + a sha, no link -> one WARN naming the sha and the
#      do_release_note_link command; the dry run still completes
#   2. the same post WITH the sha's /releases/ link -> silent
#   3. released, no sha -> silent; CONTROL: a sha but no released/deployed -> silent
#   4. two shas, one linked -> the WARN names only the unlinked one; a topic
#      UUID and a plain number are not read as shas
#   5. DRY_RUN=0 with the spool stubbed: the post that drew the WARN is SENT,
#      its body byte for byte as given, rc 0
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
SHA1=0226b4191aa3
SHA2=8d20601bcf00
TOPIC=b280b0e8-1111-4222-8333-444455556666

# reply <body> -> the dry-run output of do_spl_desk_reply in $T/o, rc kept
reply() {
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }; do_spl_desk_reply' \
    in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_BODY="$1" >"$T/o" 2>&1
}
warns() { grep -c 'WARN release-note link missing' "$T/o"; }

# --- 1. released + sha, no link ---------------------------------------------------
reply "Released to prd: $SHA1 fixes the footer."
[[ "$(warns)" == 1 ]] && grep -q "sha $SHA1 .*do_release_note_link SHA=$SHA1" "$T/o" &&
  pass "a released sha without a link draws one WARN naming the sha + do_release_note_link" ||
  fail "no WARN for a released sha without a link: $(cat "$T/o")"
grep -q 'OK DRY_RUN nothing was sent' "$T/o" && pass "the warned post still runs to the end" ||
  fail "the WARN stopped the reply: $(cat "$T/o")"
reply "deployed $SHA1 to dev"
[[ "$(warns)" == 1 ]] && pass "deployed counts like released" || fail "deployed + sha drew no WARN: $(cat "$T/o")"

# --- 2. with the link: silent ------------------------------------------------------
reply "Released to prd: $SHA1 v1.3.4 https://wui.example.com/releases/${SHA1}deadbeefdeadbeefdeadbeef0000"
[[ "$(warns)" == 0 ]] && pass "a released sha WITH its /releases/ link is silent" ||
  fail "WARN despite the link: $(cat "$T/o")"

# --- 3. no sha / no released word: silent -----------------------------------------
reply "Released the fix to prd, all green."
[[ "$(warns)" == 0 ]] && pass "released with no sha is silent" || fail "WARN with no sha: $(cat "$T/o")"
reply "Pushed $SHA1 to master, CI running."
[[ "$(warns)" == 0 ]] && pass "CONTROL: a sha without released/deployed is silent" ||
  fail "WARN without released/deployed: $(cat "$T/o")"

# --- 4. one of two linked; UUID + number ignored -----------------------------------
reply "Released in topic $TOPIC: $SHA1 (/releases/$SHA1) and $SHA2, 2026093 rows."
if [[ "$(warns)" == 1 ]] && grep -q "sha $SHA2 " "$T/o" && ! grep -q "sha $SHA1 \|sha b280b0e8\|sha 2026093" "$T/o"; then
  pass "only the unlinked sha is named; the topic UUID and a number are not shas"
else
  fail "wrong shas warned: $(cat "$T/o")"
fi

# --- 5. never dropped: DRY_RUN=0, the post is sent unchanged -----------------------
BODY="Released to prd: $SHA1 - footer fix."
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a; for a in "$@"; do [[ "${prev:-}" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}
do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-1 DESK_TASK="$TOPIC" \
  DESK_BODY="$BODY" DRY_RUN=0 SENT_BODY="$T/sent" >"$T/o" 2>&1
rc=$?
if (( rc == 0 )) && [[ "$(warns)" == 1 && -f "$T/sent" && "$(cat "$T/sent")" == "$BODY" ]]; then
  pass "DRY_RUN=0: the warned post is sent, body unchanged, rc 0"
else
  fail "the warned post was not sent unchanged (rc $rc, sent '$(cat "$T/sent" 2>/dev/null)'): $(cat "$T/o")"
fi

echo "desk-reply-release-link: $fails failure(s)"
((fails == 0))
