#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the owner-order ledger, do_spl_owner_order (spec 168 B1, SPL-4343;
#          owner HUM-10 poll 10af03a3 answer A). Synthetic orders only: the
#          real ledger lives outside git.
#   1. add is a dry run by default (nothing written); DRY_RUN=0 appends one
#      line (mode 660); the same add again writes nothing (rc 0); the same id
#      with another text is refused (rc 3), the file unchanged
#   2. every bad input is refused before any write (rc 1)
#   3. ORDER_FROM_HUB: the whole body is taken from the hub, an excerpt of
#      it is kept, a paraphrase is refused (CONTROL: the same text without
#      the hub is accepted as source given); a non-owner sender and a missing
#      message are refused
#   4. match: a covered path exits 3 and prints the order, an uncovered one
#      exits 0 (CONTROL: the glob is anchored, a near-miss path is not
#      covered)
#   5. lift: needs the owner's lifting message; afterwards match no longer
#      covers it and list hides it (ORDER_ALL=1 shows it lifted); a second
#      lift is rc 3
#   6. expires: active before, expired after (list and match)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

D="$T/oo" F="$T/oo/repo-x.jsonl"
M1=11111111-aaaa-4bbb-8ccc-000000000001 M2=22222222-aaaa-4bbb-8ccc-000000000002
M3=33333333-aaaa-4bbb-8ccc-000000000003 L1=44444444-aaaa-4bbb-8ccc-000000000004
TOPIC=55555555-aaaa-4bbb-8ccc-000000000005
BODY=$'Poll: x\n> a question\n\ndo not change the contents of the docs, only the file structure'
B64=$(printf '%s' "$BODY" | base64 -w0)
# The hub stub: psql's aligned output of the action's one-column select,
# for M2 (an owner) and M3 (an agent); any other id is 0 rows.
STUB='do_spl_db_query() {
  echo "INFO proxy up"; echo "   r"; echo "-----"
  case "$SQL" in
    *'"$M2"'*) echo " OO|HUM-10|'"$TOPIC"'|2026-10-29T15:46:10Z|'"$B64"'"; echo "(1 row)" ;;
    *'"$M3"'*) echo " OO|c-001|'"$TOPIC"'|2026-10-29T15:47:00Z|'"$B64"'"; echo "(1 row)" ;;
    *) echo "(0 rows)" ;;
  esac
}
'
oo() {
  SNIPPET="${STUB}do_spl_owner_order" in_orc OWNER_ORDER_DIR="$D" AGENT_ID=c-900 "$@" >"$T/o" 2>&1
  RC=$?
}
add1() {
  oo ORDER_CMD=add ORDER_REPO=repo-x ORDER_MSG=$M1 ORDER_TEXT='keep docs/a.md as it is' ORDER_OWNER=HUM-10 \
    ORDER_TS=2026-10-29T10:00:00Z ORDER_PATHS='docs/*.md, cfg/**' "$@"
}
lines() { [[ -f "$F" ]] && wc -l <"$F" | tr -d ' ' || echo 0; }

# 1. add, dry run, idempotent, conflicting
add1
[[ $RC -eq 0 && ! -e "$F" ]] && grep -q 'DRY_RUN would append' "$T/o" &&
  pass "add is a dry run by default: nothing written" || fail "dry run (rc=$RC): $(cat "$T/o")"
add1 DRY_RUN=0
[[ $RC -eq 0 && "$(lines)" == 1 && "$(stat -c %a "$F")" == 660 ]] &&
  jq -e --arg m "$M1" '.op == "add" and .order == $m and .source == "given" and .gate == "go" and .paths == ["docs/*.md","cfg/**"] and .by == "c-900"' "$F" >/dev/null &&
  pass "DRY_RUN=0 appends one add line, mode 660, paths trimmed, source given, gate go" || fail "add (rc=$RC, lines $(lines)): $(cat "$T/o") / $(cat "$F" 2>/dev/null)"
add1 DRY_RUN=0
[[ $RC -eq 0 && "$(lines)" == 1 ]] && grep -q 'already in the repo-x ledger' "$T/o" &&
  pass "the same add again writes nothing (rc 0)" || fail "re-add (rc=$RC, lines $(lines)): $(cat "$T/o")"
add1 DRY_RUN=0 ORDER_TEXT='keep docs/a.md'
[[ $RC -eq 3 && "$(lines)" == 1 ]] && pass "the same id with another text is refused (rc 3), file unchanged" ||
  fail "conflict (rc=$RC, lines $(lines)): $(cat "$T/o")"

# 2. refusals, nothing written
for bad in "ORDER_REPO=../x" "ORDER_MSG=11111111" "ORDER_PATHS=/etc/x" "ORDER_PATHS=docs/../x" "ORDER_PATHS=" \
           "ORDER_PATHS=a,,b" "ORDER_TEXT=" "ORDER_TS=2026-10-29" "ORDER_GATE=maybe" "ORDER_OWNER=c-001" \
           "AGENT_ID=" "ORDER_EXPIRES=tomorrow" "ORDER_TOPIC=nope" "ORDER_FROM_HUB=stg"; do
  rm -f "$F"
  add1 DRY_RUN=0 ORDER_MSG=$M2 "$bad"
  [[ $RC -eq 1 && ! -e "$F" ]] && grep -q FATAL "$T/o" && pass "$bad: refused, nothing written" ||
    fail "$bad (rc=$RC): $(cat "$T/o")"
done
add1 DRY_RUN=0
[[ $RC -eq 0 && "$(lines)" == 1 ]] && pass "CONTROL: the same add with none of those faults is written" || fail "control add (rc=$RC): $(cat "$T/o")"

# 3. from the hub
hub() { oo ORDER_CMD=add ORDER_REPO=repo-x ORDER_FROM_HUB=prd ORDER_PATHS='docs/**' DRY_RUN=0 "$@"; }
hub ORDER_MSG=$M2
[[ $RC -eq 0 ]] && jq -e -s --arg m "$M2" --arg b "$BODY" --arg t "$TOPIC" \
  '.[-1] | .order == $m and .text == $b and .source == "hub" and .owner == "HUM-10" and .topic == $t and .ts == "2026-10-29T15:46:10Z"' "$F" >/dev/null &&
  pass "ORDER_FROM_HUB: the whole body, owner, topic and time come from the hub (newlines kept)" || fail "hub add (rc=$RC): $(cat "$T/o")"
rm -f "$F"
hub ORDER_MSG=$M2 ORDER_TEXT='do not change the contents of the docs, only the file structure'
[[ $RC -eq 0 ]] && jq -e -s '.[-1].text == "do not change the contents of the docs, only the file structure" and .[-1].source == "hub"' "$F" >/dev/null &&
  pass "ORDER_FROM_HUB with an excerpt: the word-for-word part is kept" || fail "hub excerpt (rc=$RC): $(cat "$T/o")"
rm -f "$F"
hub ORDER_MSG=$M2 ORDER_TEXT='do not change the docs, only their structure'
[[ $RC -eq 1 && ! -e "$F" ]] && grep -q 'never paraphrase' "$T/o" &&
  pass "ORDER_FROM_HUB with a paraphrase: refused, nothing written" || fail "paraphrase (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=add ORDER_REPO=repo-x ORDER_MSG=$M2 ORDER_PATHS='docs/**' ORDER_OWNER=HUM-10 ORDER_TS=2026-10-29T15:46:10Z \
  ORDER_TEXT='do not change the docs, only their structure' DRY_RUN=0
[[ $RC -eq 0 ]] && jq -e -s '.[-1].source == "given"' "$F" >/dev/null &&
  pass "CONTROL: the same paraphrase without the hub is taken, marked source given" || fail "given control (rc=$RC): $(cat "$T/o")"
rm -f "$F"
hub ORDER_MSG=$M3
[[ $RC -eq 1 && ! -e "$F" ]] && grep -q 'not an owner' "$T/o" && pass "a message from an agent is refused: only the owner gives an order" ||
  fail "non-owner (rc=$RC): $(cat "$T/o")"
hub ORDER_MSG=$L1
[[ $RC -eq 1 && ! -e "$F" ]] && grep -q 'is not on the prd hub' "$T/o" && pass "a message the hub does not have is refused" ||
  fail "missing msg (rc=$RC): $(cat "$T/o")"

# 4. match
add1 DRY_RUN=0
oo ORDER_CMD=match ORDER_REPO=repo-x ORDER_PATHS='src/x.sh,cfg/a/b.yaml'
[[ $RC -eq 3 ]] && jq -e -s --arg m "$M1" 'length == 1 and .[0].order == $m and .[0].state == "active"' "$T/o" >/dev/null &&
  pass "match: a path under cfg/** exits 3 and prints the order" || fail "match covered (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=match ORDER_REPO=repo-x ORDER_PATHS='docs/sub/a.md,src/docs/a.md,docs/a.mdx'
[[ $RC -eq 0 && ! -s "$T/o" ]] && pass "CONTROL: near misses of docs/*.md (deeper, prefixed, longer) are not covered (rc 0)" ||
  fail "match near miss (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=match ORDER_REPO=other ORDER_PATHS='docs/a.md'
[[ $RC -eq 0 ]] && pass "match on a repo with no ledger: rc 0" || fail "match no ledger (rc=$RC): $(cat "$T/o")"

# 5. lift
oo ORDER_CMD=lift ORDER_REPO=repo-x ORDER_ID=${M1:0:8} ORDER_REASON='owner lifted it' DRY_RUN=0
[[ $RC -eq 1 && "$(lines)" == 1 ]] && pass "lift without the owner's lifting message is refused" || fail "lift no msg (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=lift ORDER_REPO=repo-x ORDER_ID=${M1:0:8} ORDER_LIFT_MSG=$L1 ORDER_REASON='owner lifted it' DRY_RUN=0
[[ $RC -eq 0 && "$(lines)" == 2 ]] && pass "lift appends one lift line" || fail "lift (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=match ORDER_REPO=repo-x ORDER_PATHS='docs/a.md'
[[ $RC -eq 0 ]] && pass "a lifted order no longer covers its paths" || fail "match lifted (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=list
[[ $RC -eq 0 && ! -s "$T/o" ]] && pass "list hides a lifted order" || fail "list lifted (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=list ORDER_ALL=1
[[ $RC -eq 0 ]] && grep -q "^$M1 repo-x lifted gate=go" "$T/o" && grep -qx '  > keep docs/a.md as it is' "$T/o" &&
  pass "ORDER_ALL=1 lists it as lifted, its text quoted" || fail "list all (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=lift ORDER_REPO=repo-x ORDER_ID=${M1:0:8} ORDER_LIFT_MSG=$L1 ORDER_REASON='again' DRY_RUN=0
[[ $RC -eq 3 && "$(lines)" == 2 ]] && pass "a second lift is rc 3, nothing written" || fail "re-lift (rc=$RC): $(cat "$T/o")"

# 6. expires
rm -f "$F"
add1 DRY_RUN=0 ORDER_EXPIRES=2026-10-31T00:00:00Z
oo ORDER_CMD=match ORDER_REPO=repo-x ORDER_PATHS='docs/a.md' ORDER_NOW=2026-10-30T12:00:00Z
[[ $RC -eq 3 ]] && pass "CONTROL: before expires the order covers its paths" || fail "pre-expiry (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=match ORDER_REPO=repo-x ORDER_PATHS='docs/a.md' ORDER_NOW=2026-10-31T00:00:01Z
[[ $RC -eq 0 ]] && pass "after expires it covers nothing" || fail "post-expiry (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=list ORDER_JSON=1 ORDER_ALL=1 ORDER_NOW=2026-10-31T00:00:01Z
[[ $RC -eq 0 ]] && jq -e -s 'length == 1 and .[0].state == "expired"' "$T/o" >/dev/null &&
  pass "list ORDER_JSON=1 ORDER_ALL=1 shows it expired" || fail "list expired (rc=$RC): $(cat "$T/o")"
oo ORDER_CMD=nope
[[ $RC -eq 1 ]] && pass "an unknown ORDER_CMD is refused" || fail "bad cmd (rc=$RC)"

((fails == 0)) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
