#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_welcome (SPL-961). No cloud call, no tmux: the admit
# read, the #lobby post and the live-window list are stubbed; the ledger, the
# plan and the texts are the real ones. Each run is a FRESH process, so a
# second run is exactly what a cron tick after a restart is.
#   1. the first run writes the tenant baseline; an older admit is never greeted
#   2. a new admit gets WELCOME_CAP posts from distinct live seated bots, into
#      #lobby, naming the person, all different texts; a seated bot with no
#      live window and a live bot with no seat are never picked
#   3. a second run (a restart) posts nothing more - exactly once
#   4. round-robin: the next person meets the next bots
#   5. a run killed between the hub's accept and the posted mark: the rerun
#      never posts that bot again and finishes the others
#   6. a refused post releases its claim and is retried on the next run, once
#   7. no live seated bot: nothing is planned, the person waits for a tick
#   8. preferred_locale picks the language; an unknown one falls back to cnf
#   9. the dry run writes no ledger and posts nothing
#  10. every locale x variant fits 33 words with a three-word name
#  11. a test/proof account is skipped unless WELCOME_INCLUDE_TEST=1
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

# 2. a new admit
ADMITS="$T/a2"; { admit t1 HUM-5 100 'Old Timer' ''; admit t1 HUM-20 2000 'Ada Lovelace' ''; } >"$ADMITS"
run DRY_RUN=0; rc=$?
n="$(posts_for HUM-20)"; n=$(wc -l <"$POSTS")
bots="$(cut -f2 "$POSTS" | sort | paste -sd ' ')"
[[ $rc -eq 0 && "$n" == 3 && "$bots" == "CLE-1 CLE-2 CLE-3" ]] &&
  pass "2. three live seated bots greet the new person ($bots)" || fail "2. posts ($rc, $n, $bots): $(cat "$T/o")"
[[ "$(cut -f3 "$POSTS" | grep -c 'Ada Lovelace')" == 3 && "$(cut -f3 "$POSTS" | sort -u | wc -l)" == 3 ]] &&
  pass "2. every text names the person and no two are the same" || fail "2. texts: $(cut -f3 "$POSTS")"
! grep -qE 'GRK-9|CLE-77' "$POSTS" && ! grep -q 'Old Timer' "$POSTS" &&
  pass "2. no dead seat, no unseated window, no pre-baseline member" || fail "2. picked wrong: $(cat "$POSTS")"
[[ -e "$ST/welcome/t1/HUM-20/done" ]] && pass "2. the person is marked done" || fail "2. no done mark"

# 3. a restart: the same admits again
run DRY_RUN=0
[[ $? -eq 0 && "$(wc -l <"$POSTS")" == 3 ]] && pass "3. a second run (restart) posts nothing more" || fail "3. rerun: $(wc -l <"$POSTS") posts: $(cat "$T/o")"

# 4. round robin
ADMITS="$T/a4"; admit t1 HUM-21 2100 'Grace Hopper' '' >"$ADMITS"
run DRY_RUN=0
bots="$(grep 'Grace Hopper' "$POSTS" | cut -f2 | paste -sd ' ')"
[[ "$bots" == "CLE-4 CLE-5 CLE-1" ]] && pass "4. the next person meets the next bots ($bots)" || fail "4. round robin: '$bots'"

# 5. killed mid-post
ADMITS="$T/a5"; admit t1 HUM-22 2200 'Alan Turing' '' >"$ADMITS"
( CRASH_ON=CLE-3 run DRY_RUN=0 ) 2>/dev/null; rc=$?   # the shell reports the kill -9: keep it off the log
[[ $rc -ne 0 && -e "$ST/welcome/t1/HUM-22/CLE-3.claim" && ! -e "$ST/welcome/t1/HUM-22/done" ]] &&
  pass "5. CONTROL: the run died with CLE-3's claim open" || fail "5. crash rc=$rc: $(ls "$ST/welcome/t1/HUM-22")"
run DRY_RUN=0
bots="$(grep 'Alan Turing' "$POSTS" | cut -f2 | paste -sd ' ')"
[[ "$bots" == "CLE-2 CLE-3 CLE-4" && -e "$ST/welcome/t1/HUM-22/done" ]] &&
  pass "5. the rerun finishes the plan and never posts CLE-3 twice ($bots)" || fail "5. after crash: '$bots' $(cat "$T/o")"

# 6. refused, then retried once
ADMITS="$T/a6"; admit t1 HUM-23 2300 'Hedy Lamarr' '' >"$ADMITS"
FAIL_ON=CLE-1 run DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -e "$ST/welcome/t1/HUM-23/CLE-1.claim" && ! -e "$ST/welcome/t1/HUM-23/done" &&
   "$(cat "$ST/welcome/t1/HUM-23/CLE-1.tries")" == 1 ]] &&
  pass "6. a refused post releases its claim and counts a try" || fail "6. refused rc=$rc: $(cat "$T/o")"
run DRY_RUN=0
bots="$(grep 'Hedy Lamarr' "$POSTS" | cut -f2 | sort | paste -sd ' ')"
[[ "$(grep 'Hedy Lamarr' "$POSTS" | cut -f2 | sort | uniq -d)" == "" && "$(grep -c 'Hedy Lamarr' "$POSTS")" == 3 &&
   -e "$ST/welcome/t1/HUM-23/done" ]] &&
  pass "6. the next run posts the refused bot once and nobody twice ($bots)" || fail "6. retry: '$bots'"

# 7. nobody live
ADMITS="$T/a7"; admit t1 HUM-24 2400 'Nobody Home' '' >"$ADMITS"
LIVE="CLE-77" run DRY_RUN=0
[[ "$(grep -c 'Nobody Home' "$POSTS")" == 0 && ! -e "$ST/welcome/t1/HUM-24/plan" && ! -e "$ST/welcome/t1/HUM-24/done" ]] &&
  grep -q 'no live seated bot' "$T/o" && pass "7. with no live seated bot nothing is planned yet" || fail "7. nobody live: $(cat "$T/o")"

# 8. locale
ADMITS="$T/a8"; { admit t1 HUM-25 2500 'Kristina' bg; admit t1 HUM-26 2600 'Pat' zz; } >"$ADMITS"
run DRY_RUN=0 WELCOME_CAP=1
grep 'Kristina' "$POSTS" | grep -qE 'Добре|Здравейте|Ура' && pass "8. preferred_locale bg greets in Bulgarian" || fail "8. bg: $(grep Kristina "$POSTS")"
grep 'Pat' "$POSTS" | grep -qE 'Welcome|Hello|Hooray' && pass "8. an unknown locale falls back to the cnf default (en)" || fail "8. fallback: $(grep Pat "$POSTS")"
[[ "$(grep -c 'Kristina' "$POSTS")" == 1 ]] && pass "8. WELCOME_CAP=1 posts one greeting" || fail "8. cap 1: $(grep -c Kristina "$POSTS")"

# 11. a test/proof account is skipped unless WELCOME_INCLUDE_TEST=1
ADMITS="$T/a11"; admit t1 HUM-30 3000 'm3-e2e human' '' true >"$ADMITS"
run DRY_RUN=0
[[ "$(grep -c 'm3-e2e human' "$POSTS")" == 0 && ! -e "$ST/welcome/t1/HUM-30/done" ]] && grep -q 'test/proof account' "$T/o" &&
  pass "11. a test/proof account is not greeted" || fail "11. test skipped: $(cat "$T/o")"
run DRY_RUN=0 WELCOME_INCLUDE_TEST=1 WELCOME_CAP=1
[[ "$(grep -c 'm3-e2e human' "$POSTS")" == 1 ]] && pass "11. CONTROL: WELCOME_INCLUDE_TEST=1 greets it (live proofs)" || fail "11. include test: $(cat "$T/o")"

# every post went to t1 only
[[ "$(cut -f1 "$POSTS" | sort -u)" == t1 ]] && pass "posts stay in the admit's tenant" || fail "tenants: $(cut -f1 "$POSTS" | sort -u)"

# 10. word cap
python3 "$PROJ_ROOT/src/bash/scripts/desk-welcome-text.py" --check >"$T/o" 2>&1 &&
  pass "10. $(cat "$T/o")" || fail "10. word cap: $(cat "$T/o")"
w="$(awk -F'\t' '{ n = split($3, x, /[ \t]+/); if (n > m) m = n } END { print m }' "$POSTS")"
(( w <= 33 )) && pass "10. the longest posted text is $w words" || fail "10. a post has $w words"

(( fails == 0 )) && echo "=== all desk-welcome.tst.sh assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
