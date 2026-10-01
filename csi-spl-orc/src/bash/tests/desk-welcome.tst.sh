#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_welcome (SPL-961). No cloud call, no tmux: the admit
# read, the #lobby post and the live-window list are stubbed; the ledger, the
# plan and the texts are the real ones. Each run is a FRESH process, so a
# second run is exactly what a cron tick after a restart is.
#   1. the first run writes the tenant baseline; an older admit is never greeted
#   2. CLE-77896: no greeter configured = nobody greets, decided once; a new
#      admit gets ONE post into #lobby, from the configured greeter only,
#      naming the person - never one per seated bot
#   3. a second run (a restart) posts nothing more - exactly once
#   4. a greeter that is seated but dead, or live but unseated, waits for a
#      tick; a malformed greeter file reads as none, never as "any bot"
#   5. a run killed between the hub's accept and the posted mark: the rerun
#      never posts again
#   6. a refused post releases its claim and is retried on the next run, once
#   7. a ledger planned before CLE-77896 (three bots) still finishes as planned
#   8. preferred_locale picks the language; an unknown one falls back to cnf
#   9. the dry run writes no ledger and posts nothing
#  10. every locale x variant fits 33 words with a three-word name
#  11. a test/proof account is skipped unless WELCOME_INCLUDE_TEST=1
#  12. the provenance footer rides the greeter's post
#  13. do_spl_desk_greeter: show, dry run, set, refuse a non-agent id, clear
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ST="$T/state/prd"
POSTS="$T/posts.tsv"
: >"$POSTS"

# run [VAR=val ...]: one welcome run in a fresh bash. ADMITS is the file the
# admit read returns, LIVE the live windows, FAIL_ON a bot whose post the hub
# refuses, CRASH_ON a bot whose post is accepted and then the run is killed.
run() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$ST" ENV=prd POSTS="$POSTS" \
    ADMITS="${ADMITS:-$T/none}" LIVE="${LIVE:-}" FAIL_ON="${FAIL_ON:-}" CRASH_ON="${CRASH_ON:-}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_desk_welcome_admits() { cat "$ADMITS" 2>/dev/null; }
    spl_desk_live_agents() { printf "%s\n" $LIVE; }
    spl_desk_welcome_post() {
      [[ "$3" == "$FAIL_ON" ]] && { echo "spool: hub refused: internal"; return 1; }
      printf "%s\t%s\t%s\n" "$1" "$3" "$4" >>"$POSTS"
      [[ "$3" == "$CRASH_ON" ]] && kill -9 $$
      echo "{\"send\": {\"msg_id\": \"00000000-0000-4000-8000-$(printf %012d "$(wc -l <"$POSTS")")\"}}"
    }
    do_spl_desk_welcome' >"$T/o" 2>&1
}
admit() {  # tenant human at name locale [test]
  printf '{"tenant":"%s","human":"%s","at":%s,"name":"%s","locale":"%s","test":%s}\n' "$1" "$2" "$3" "$4" "$5" "${6:-false}"
}
posts_for() { grep -c "$1" "$POSTS" || true; }

SEATS="$ST/desk/t1/box-desk"
mkdir -p "$SEATS"; echo pub >"$SEATS/pinned"
for a in CLE-1 CLE-2 CLE-3 CLE-4 CLE-5 GRK-9; do mkdir -p "$SEATS/spool/$a"; done
LIVE="CLE-1 CLE-2 CLE-3 CLE-4 CLE-5 CLE-77"   # GRK-9 seated but dead, CLE-77 live but not seated
export LIVE
greeter() { if [[ -n "$1" ]]; then printf '%s\n' "$1" >"$SEATS/greeter"; else rm -f "$SEATS/greeter"; fi; }

# 9. dry run first: no ledger
ADMITS="$T/a1"; admit t1 HUM-5 100 'Old Timer' '' >"$ADMITS"
run
[[ $? -eq 0 && ! -e "$ST/welcome" && ! -s "$POSTS" ]] && grep -q 'DRY_RUN' "$T/o" &&
  pass "9. the dry run writes no ledger and posts nothing" || fail "9. dry run: $(cat "$T/o")"

# 1. baseline
run DRY_RUN=0
base="$(cat "$ST/welcome/t1/baseline" 2>/dev/null)"
[[ $? -eq 0 && "$base" =~ ^[0-9]+$ && ! -s "$POSTS" && ! -e "$ST/welcome/t1/HUM-5" ]] &&
  pass "1. the first run writes the baseline and greets no older member" || fail "1. baseline: $(cat "$T/o")"
echo 1000 >"$ST/welcome/t1/baseline"   # pretend the feature was installed at t=1000

# 2. no greeter configured: nobody greets, five live seated bots or not
ADMITS="$T/a2a"; admit t1 HUM-19 1900 'Nobody Greets' '' >"$ADMITS"
run DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$POSTS" && -e "$ST/welcome/t1/HUM-19/done" ]] && grep -q 'no greeter configured' "$T/o" &&
  pass "2. no greeter configured: nobody greets, and the person is decided" || fail "2. no greeter ($rc): $(cat "$T/o") $(cat "$POSTS")"
greeter CLE-3
run DRY_RUN=0
[[ ! -s "$POSTS" ]] && pass "2. a greeter configured later never greets the people admitted before it" || fail "2. late greeter: $(cat "$POSTS")"

# 2. a new admit with a greeter: one post, from the greeter
ADMITS="$T/a2"; { admit t1 HUM-5 100 'Old Timer' ''; admit t1 HUM-20 2000 'Ada Lovelace' ''; } >"$ADMITS"
run DRY_RUN=0; rc=$?
bots="$(cut -f2 "$POSTS" | paste -sd ' ')"
[[ $rc -eq 0 && "$(wc -l <"$POSTS")" == 1 && "$bots" == "CLE-3" ]] &&
  pass "2. the configured greeter, and only it, welcomes the new person ($bots)" || fail "2. posts ($rc, $bots): $(cat "$T/o")"
grep -q 'Ada Lovelace' "$POSTS" && ! grep -q 'Old Timer' "$POSTS" &&
  pass "2. the text names the person; no pre-baseline member" || fail "2. texts: $(cat "$POSTS")"
[[ -e "$ST/welcome/t1/HUM-20/done" ]] && pass "2. the person is marked done" || fail "2. no done mark"

# 3. a restart: the same admits again
run DRY_RUN=0
[[ $? -eq 0 && "$(wc -l <"$POSTS")" == 1 ]] && pass "3. a second run (restart) posts nothing more" || fail "3. rerun: $(wc -l <"$POSTS") posts: $(cat "$T/o")"

# 4. a greeter that cannot post yet waits; a malformed one is none
ADMITS="$T/a4"; admit t1 HUM-21 2100 'Grace Hopper' '' >"$ADMITS"
for g in GRK-9 CLE-77; do
  greeter "$g"; run DRY_RUN=0
  [[ "$(grep -c 'Grace Hopper' "$POSTS")" == 0 && ! -e "$ST/welcome/t1/HUM-21/plan" && ! -e "$ST/welcome/t1/HUM-21/done" ]] &&
    grep -q "greeter $g is not seated and live" "$T/o" && pass "4. greeter $g (not seated + live): nobody posts, the person waits" ||
    fail "4. $g: $(cat "$T/o") $(cat "$POSTS")"
done
greeter CLE-2; run DRY_RUN=0
[[ "$(grep 'Grace Hopper' "$POSTS" | cut -f2)" == CLE-2 ]] && pass "4. once the greeter is seated and live, it greets" || fail "4. live greeter: $(cat "$POSTS")"
ADMITS="$T/a4b"; admit t1 HUM-27 2700 'Bad File' '' >"$ADMITS"
greeter 'HUM-1'; run DRY_RUN=0
[[ "$(grep -c 'Bad File' "$POSTS")" == 0 ]] && grep -q 'no greeter configured' "$T/o" &&
  pass "4. a malformed greeter file reads as none, never as any seated bot" || fail "4. malformed: $(cat "$T/o")"
greeter CLE-2

# 5. killed mid-post
ADMITS="$T/a5"; admit t1 HUM-22 2200 'Alan Turing' '' >"$ADMITS"
( CRASH_ON=CLE-2 run DRY_RUN=0 ) 2>/dev/null; rc=$?   # the shell reports the kill -9: keep it off the log
[[ $rc -ne 0 && -e "$ST/welcome/t1/HUM-22/CLE-2.claim" && ! -e "$ST/welcome/t1/HUM-22/done" ]] &&
  pass "5. CONTROL: the run died with CLE-2's claim open" || fail "5. crash rc=$rc: $(ls "$ST/welcome/t1/HUM-22")"
run DRY_RUN=0
[[ "$(grep -c 'Alan Turing' "$POSTS")" == 1 && -e "$ST/welcome/t1/HUM-22/done" ]] &&
  pass "5. the rerun never posts the greeter twice" || fail "5. after crash: $(cat "$T/o")"

# 6. refused, then retried once
ADMITS="$T/a6"; admit t1 HUM-23 2300 'Hedy Lamarr' '' >"$ADMITS"
FAIL_ON=CLE-2 run DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -e "$ST/welcome/t1/HUM-23/CLE-2.claim" && ! -e "$ST/welcome/t1/HUM-23/done" &&
   "$(cat "$ST/welcome/t1/HUM-23/CLE-2.tries")" == 1 ]] &&
  pass "6. a refused post releases its claim and counts a try" || fail "6. refused rc=$rc: $(cat "$T/o")"
run DRY_RUN=0
[[ "$(grep -c 'Hedy Lamarr' "$POSTS")" == 1 && -e "$ST/welcome/t1/HUM-23/done" ]] &&
  pass "6. the next run posts the refused greeter once" || fail "6. retry: $(cat "$T/o")"

# 7. a ledger planned before CLE-77896 finishes as planned (no new pile-on is
#    planned, but a half-posted old plan is not abandoned either)
ADMITS="$T/a7"; admit t1 HUM-24 2400 'Old Plan' '' >"$ADMITS"
mkdir -p "$ST/welcome/t1/HUM-24"; printf '%s\n' CLE-4 CLE-5 >"$ST/welcome/t1/HUM-24/plan"
run DRY_RUN=0
[[ "$(grep 'Old Plan' "$POSTS" | cut -f2 | paste -sd ' ')" == "CLE-4 CLE-5" ]] &&
  pass "7. an existing plan is honoured as written" || fail "7. old plan: $(cat "$POSTS")"

# 8. locale
ADMITS="$T/a8"; { admit t1 HUM-25 2500 'Kristina' bg; admit t1 HUM-26 2600 'Pat' zz; } >"$ADMITS"
run DRY_RUN=0
grep 'Kristina' "$POSTS" | grep -qE 'Добре|Здравейте|Ура' && pass "8. preferred_locale bg greets in Bulgarian" || fail "8. bg: $(grep Kristina "$POSTS")"
grep 'Pat' "$POSTS" | grep -qE 'Welcome|Hello|Hooray' && pass "8. an unknown locale falls back to the cnf default (en)" || fail "8. fallback: $(grep Pat "$POSTS")"

# 11. a test/proof account is skipped unless WELCOME_INCLUDE_TEST=1
ADMITS="$T/a11"; admit t1 HUM-30 3000 'm3-e2e human' '' true >"$ADMITS"
run DRY_RUN=0
[[ "$(grep -c 'm3-e2e human' "$POSTS")" == 0 && ! -e "$ST/welcome/t1/HUM-30/done" ]] && grep -q 'test/proof account' "$T/o" &&
  pass "11. a test/proof account is not greeted" || fail "11. test skipped: $(cat "$T/o")"
run DRY_RUN=0 WELCOME_INCLUDE_TEST=1
[[ "$(grep -c 'm3-e2e human' "$POSTS")" == 1 ]] && pass "11. CONTROL: WELCOME_INCLUDE_TEST=1 greets it (live proofs)" || fail "11. include test: $(cat "$T/o")"

# every post went to t1 only
[[ "$(cut -f1 "$POSTS" | sort -u)" == t1 ]] && pass "posts stay in the admit's tenant" || fail "tenants: $(cut -f1 "$POSTS" | sort -u)"

# 10. word cap
python3 "$PROJ_ROOT/src/bash/scripts/desk-welcome-text.py" --check >"$T/o" 2>&1 &&
  pass "10. $(cat "$T/o")" || fail "10. word cap: $(cat "$T/o")"
w="$(awk -F'\t' '{ n = split($3, x, /[ \t]+/); if (n > m) m = n } END { print m }' "$POSTS")"
(( w <= 33 )) && pass "10. the longest posted text is $w words" || fail "10. a post has $w words"

# 12. CLE-77778: the greeter's post carries the provenance footer, outside the
#     cheerful text. Run late: the footer's own newlines make that post span
#     lines in the TSV, so it is kept off the aggregate checks above.
ADMITS="$T/a12"; : >"$POSTS"
printf '{"tenant":"t1","human":"HUM-40","at":4000,"name":"Ada Prov","locale":"","test":false,"invited_on":"2026-09-25","ordered_by_name":"Grace Owner","ordered_via":"CLE-34967"}\n' >"$ADMITS"
run DRY_RUN=0
[[ "$(grep -c 'invited 2026-09-25 by Grace Owner (via CLE-34967)' "$POSTS")" == 1 && "$(grep -c 'Ada Prov' "$POSTS")" == 1 ]] &&
  pass "12. the greeter's one welcome carries the provenance footer" || fail "12. provenance footer: $(cat "$POSTS")"
ADMITS="$T/a12b"; : >"$POSTS"
admit t1 HUM-41 4100 'No Prov' '' >"$ADMITS"
run DRY_RUN=0
[[ "$(grep -c 'invited' "$POSTS")" == 0 && "$(grep -c 'No Prov' "$POSTS")" == 1 ]] &&
  pass "12. a member with no invite provenance gets no footer" || fail "12. no-prov: $(cat "$POSTS")"

# 13. do_spl_desk_greeter
gset() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$ST" ENV=prd TENANT_ID=t1 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_desk_greeter' >"$T/o" 2>&1
}
gset; [[ $? -eq 0 ]] && grep -q 'greeter: CLE-2' "$T/o" && pass "13. it shows the current greeter" || fail "13. show: $(cat "$T/o")"
gset DESK_GREETER=CLE-4; [[ $? -eq 0 && "$(cat "$SEATS/greeter")" == CLE-2 ]] && grep -q DRY_RUN "$T/o" &&
  pass "13. the dry run writes nothing" || fail "13. dry: $(cat "$T/o")"
gset DESK_GREETER=CLE-4 DRY_RUN=0; [[ $? -eq 0 && "$(cat "$SEATS/greeter")" == CLE-4 ]] &&
  pass "13. DRY_RUN=0 sets it" || fail "13. set: $(cat "$T/o")"
gset DESK_GREETER=HUM-3 DRY_RUN=0; [[ $? -ne 0 && "$(cat "$SEATS/greeter")" == CLE-4 ]] &&
  pass "13. a human id is refused" || fail "13. refuse: $(cat "$T/o")"
gset DESK_GREETER=none DRY_RUN=0; [[ $? -eq 0 && ! -e "$SEATS/greeter" ]] &&
  pass "13. none clears it: nobody greets" || fail "13. clear: $(cat "$T/o")"

(( fails == 0 )) && echo "=== all desk-welcome.tst.sh assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
