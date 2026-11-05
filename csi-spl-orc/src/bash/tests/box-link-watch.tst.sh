#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_link_watch (SPL-4816) on a fake relay hub: a box dir
# (inbound/, outbound/), a hub log, a results dir, a process list, a lane map
# and a sender stub that records each send. The clock is GW_NOW.
#   1. a bundle sent 8 min ago with no receipt -> exactly ONE blocker to the
#      topic's live seat, naming the box, what, since when and the evidence
#   2. the same state on the next run -> no second message
#   3. the receipt appears -> ONE note "cleared after N min"; then nothing
#   4. a bundle sent 6 min ago -> nothing
#   5. a command: no receipt and no result after 8 min -> alert; its
#      results/<id>/result.json alone clears it
#   6. the box log silent 8 min -> alert; the link down (no radiate) -> alert;
#      several stuck conditions on one box are ONE message
#   7. a refused apply 8 min ago -> alert; a later APPLIED clears it
#   8. no live seat row on the topic -> the fallback receiver
#   9. DRY_RUN (default) prints the plan, sends nothing, writes no state
#  10. a send that fails is not recorded: the next run sends it
#  11. a log of another queue (a relay test run) is ignored; a signed URL in
#      the evidence is redacted; no box dir -> nothing to watch, exit 0
#  12. the manifest row box-link-watch runs the cron script every minute
#  13. the relay paths come from the box-local env file (never sourced); no
#      ROOT anywhere -> nothing to watch, exit 0; ROOT without HOME -> refused
#  14. a box with no topic row -> ONE blocker to the fallback, rc 1
#  15. an open incident older than GW_WINDOW_H with no receipt -> not cleared
#  16. UTC stamps read under TZ=Europe/Sofia: 6 min -> still no alert
#   RED CONTROL: case 2 with the state file gone sends a second blocker, so
#   case 2's silence is the state's doing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
export TZ=UTC
NOW=1793800000
R="$T/root"; L="$T/logs"; RES="$T/results"
printf '#!/bin/sh\nprintf "%%s|" "$@" | tr "\\n" " " >>%q\necho >>%q\n' "$T/sent" "$T/sent" >"$T/send-ok"
printf '#!/bin/sh\nexit 1\n' >"$T/send-fail"
printf '{"lanes":[{"agent_id":"c-701","agent_box":"boxa","topic":"abcd1234-0000-4000-8000-000000000000","scope":"Seat brief: the box topic","state":"live","updated_at":"2026-11-04T10:00:00Z"},{"agent_id":"c-702","agent_box":"boxa","topic":"abcd1234-0000-4000-8000-000000000000","scope":"Lane brief: some lane","state":"live","updated_at":"2026-11-04T11:00:00Z"}]}\n' >"$T/lanes.json"
printf '{"lanes":[]}\n' >"$T/lanes-none.json"

stamp() { date -u -d "@$(( NOW - $1 * 60 ))" '+%Y-%m-%d %H:%M:%S'; }
logl() { printf ' INFO  %s UTC [rel][@box] [42] %s\n' "$(stamp "$1")" "$2" >>"$L/rel.sh.20261104_100000.out.log"; }
ps_up() { printf '/bin/bash %s/relay/run -a radiate\n' "$T" >"$T/ps"; }
# fresh: an empty hub with a radiating session and a box log received 1 min ago
fresh() {
  rm -rf "$R" "$L" "$RES" "$T/st.json" "$T/sent"; : >"$T/sent"
  mkdir -p "$R/box/inbound/archived" "$R/box/outbound/launch" "$L" "$RES"
  logl 60 "radiating session ses-1: every 60s until 2026-11-10 12:40:53; outbound $R/box/outbound, inbound $R/box/inbound"
  touch -d "@$(( NOW - 60 ))" "$R/box/inbound/archived/<x>-log.box.h1.20261104.log"
  ps_up
}
run() {
  SNIPPET='do_spl_box_link_watch' in_orc BOX_LINK_WATCH_ENV="$T/no-env" BOX_LINK_WATCH_ROOT="$R" BOX_LINK_WATCH_LOG_DIR="$L" BOX_LINK_WATCH_RESULTS="$RES" \
    BOX_LINK_WATCH_HOME="$T/relay" BOX_LINK_WATCH_STATE="$T/st.json" BOX_LINK_WATCH_TOPICS="box=abcd1234" \
    BOX_LINK_WATCH_FROM=c-001 BOX_LINK_WATCH_FALLBACK=c-002@sat BOX_LINK_WATCH_SEND="$T/send-ok" \
    BOX_LINK_WATCH_LANES_CMD="cat $T/lanes.json" BOX_LINK_WATCH_PS_CMD="cat $T/ps" GW_NOW="$NOW" DRY_RUN=0 "$@" 2>&1
}
n() { grep -c . "$T/sent" 2>/dev/null || true; }
last() { sed -n '$p' "$T/sent"; }
later() { NOW=$(( NOW + $1 * 60 )); touch -d "@$(( NOW - 60 ))" "$R/box/inbound/archived/<x>-log.box.h1.20261104.log"; }

# 1. 8 min, no receipt -> one blocker
fresh; logl 8 "sent b1.zip hub -> box (10 B, sha256 aa) as b-1 in 1 s, waiting for the box's receipt"
out="$(run)"
[ "$(n)" = 1 ] && grep -q '^--from|c-001|--to|c-701@boxa|--kind|blocker|--task|dispatch-abcd1234|--body|LINK STUCK > 7 min on box `box` since ' "$T/sent" \
  && grep -q 'bundle b1.zip sent, no receipt, since .* (8 min). Evidence: `.*sent b1.zip hub -> box' "$T/sent" \
  && pass "1. 8 min with no receipt -> ONE blocker to the topic seat c-701@boxa (not the lane c-702), naming what, since and the evidence" || fail "1. ($(n): $(cat "$T/sent"); $out)"
# 2. the same state again -> nothing
cp "$T/st.json" "$T/st.after1"
later 1; out="$(run)"
[ "$(n)" = 1 ] && grep -q 'incident open since' <<<"$out" && pass "2. the next run on the same state sends nothing" || fail "2. ($(n): $out)"
# RED CONTROL: without the state the same run sends again
cp "$T/sent" "$T/sent.keep"; out="$(run BOX_LINK_WATCH_STATE="$T/st-gone.json")"
[ "$(n)" = 2 ] && pass "RED CONTROL: with the state file gone the same run sends a second blocker" || fail "RED CONTROL ($(n): $out)"
cp "$T/sent.keep" "$T/sent"
# 3. the receipt -> one cleared note, then nothing
logl -1 "delivered b1.zip to box1: marked sent; relay blob deleted"
later 2; out="$(run)"
[ "$(n)" = 2 ] && grep -q '|--kind|note|--task|dispatch-abcd1234|--body|LINK CLEARED on box `box` after 11 min (stuck since .*: bundle b1.zip sent, no receipt)' <<<"$(last)" \
  && pass "3. the receipt -> ONE note 'cleared after 11 min'" || fail "3. ($(n): $(cat "$T/sent"); $out)"
later 1; run >/dev/null
[ "$(n)" = 2 ] && pass "3. ...and nothing after it" || fail "3. after ($(n))"

# 4. 6 min -> nothing
fresh; logl 6 "sent b2.zip hub -> box (10 B, sha256 aa) as b-2 in 1 s, waiting for the box's receipt"
out="$(run)"
[ "$(n)" = 0 ] && grep -q 'b2.zip sent, no receipt, 6 min' <<<"$out" && pass "4. 6 min -> no alert (tracked)" || fail "4. ($(n): $out)"

# 5. a command: no receipt, no result -> alert; result.json alone clears it
fresh; logl 9 "run-on-box: queued gr-cmd-0123456789ab.zip ('x', cwd /x, timeout 600s)"
logl 8 "sent gr-cmd-0123456789ab.zip hub -> box (10 B, sha256 aa) as b-3 in 1 s, waiting for the box's receipt"
run >/dev/null
grep -q 'command 0123456789ab sent, no receipt and no result, since .* (9 min)' "$T/sent" && pass "5. a command with no receipt and no result after 9 min -> alert" || fail "5. ($(cat "$T/sent"))"
mkdir -p "$RES/0123456789ab"; echo '{"exit":0}' >"$RES/0123456789ab/result.json"
later 1; run >/dev/null
[ "$(n)" = 2 ] && grep -q "LINK CLEARED" <<<"$(last)" && pass "5. ...results/<id>/result.json alone clears it" || fail "5. clear ($(cat "$T/sent"))"

# 6. box log silent -> alert; link down counts from the first run that saw it;
# both stuck -> ONE message naming both
fresh; touch -d "@$(( NOW - 480 ))" "$R/box/inbound/archived/<x>-log.box.h1.20261104.log"
run >/dev/null
[ "$(n)" = 1 ] && grep -q 'the box log is not advancing (last received .*), since .* (8 min). Evidence: `newest box log file inbound/archived/' "$T/sent" \
  && pass "6. the box log silent 8 min -> alert" || fail "6. ($(n): $(cat "$T/sent"))"
fresh; : >"$T/ps"; out="$(run)"
[ "$(n)" = 0 ] && grep -q 'd:link: the relay link/session is down, 0 min' <<<"$out" && pass "6. no radiate process: tracked from this run, no alert at once" || fail "6. down at once ($(n): $out)"
NOW=$(( NOW + 8 * 60 )); run >/dev/null
[ "$(n)" = 1 ] && grep -q 'link/session is down, since .* (8 min). Evidence: `no process matches' "$T/sent" && grep -q 'the box log is not advancing' "$T/sent" \
  && pass "6. ...8 min later ONE blocker names both the link down and the silent box log" || fail "6. down later ($(n): $(cat "$T/sent"))"
fresh; logl 9 "interrupted: closing the session"; run >/dev/null; later 8; run >/dev/null
grep -q 'link/session is down.*interrupted: closing the session' "$T/sent" && pass "6. a session the hub log closed counts as down" || fail "6. closed ($(cat "$T/sent"))"

# 7. a refused apply -> alert; a later APPLIED clears it
fresh; logl 8 "box: deploy: REFUSED alc.zip: the base commit is missing  (at 2026-11-04 10:00:00 EET on the box)"
run >/dev/null
grep -q 'box apply refused or timed out, since .* (8 min). Evidence: `.*REFUSED alc.zip' "$T/sent" && pass "7. a refused apply 8 min ago -> alert" || fail "7. ($(cat "$T/sent"))"
logl -1 "box: deploy: APPLIED alc branch b 1..2 (1 -> 2) at worktree /x from alc.zip"
later 2; run >/dev/null
[ "$(n)" = 2 ] && grep -q CLEARED <<<"$(last)" && pass "7. ...a later APPLIED clears it" || fail "7. clear ($(cat "$T/sent"))"

# 8. no live seat -> the fallback
fresh; logl 8 "sent b3.zip hub -> box (10 B, sha256 aa) as b-4 in 1 s, waiting for the box's receipt"
out="$(run BOX_LINK_WATCH_LANES_CMD="cat $T/lanes-none.json")"
grep -q '^--from|c-001|--to|c-002@sat|--kind|blocker' "$T/sent" && grep -q 'dispatch lease holder: no live seat row on topic abcd1234' <<<"$out" \
  && pass "8. no live seat row -> the fallback (the dispatch lease holder)" || fail "8. ($(cat "$T/sent"); $out)"

# 9. DRY_RUN default: plan only
fresh; logl 8 "sent b4.zip hub -> box (10 B, sha256 aa) as b-5 in 1 s, waiting for the box's receipt"
out="$(run DRY_RUN=1)"
[ "$(n)" = 0 ] && [ ! -e "$T/st.json" ] && grep -q '^PLAN blocker to c-701@boxa (seat of topic abcd1234) on dispatch-abcd1234: LINK STUCK' <<<"$out" \
  && pass "9. DRY_RUN=1 prints the plan, sends nothing, writes no state" || fail "9. ($(n): $out)"

# 10. a failed send is not recorded
out="$(run BOX_LINK_WATCH_SEND="$T/send-fail")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'did not send; retried next run' <<<"$out" && pass "10. a failed send -> rc != 0, logged" || fail "10. (rc $rc: $out)"
later 1; run >/dev/null
[ "$(n)" = 1 ] && pass "10. ...and the next run sends it" || fail "10. retry ($(n))"

# 11. another queue's log is ignored, a URL is redacted, no box -> nothing
fresh
printf ' INFO  %s UTC [rel][@box] [7] sent t.zip hub -> box (1 B) as b-9 in 0 s, waiting for the box'"'"'s receipt; outbound /tmp/tmp.x/hub/outbound\n' "$(stamp 9)" >"$L/rel.sh.20261104_110000.out.log"
logl 8 "sent b5.zip hub -> box (10 B) via https://storage.example.com/b?X-Goog-Signature=abc, waiting for the box's receipt"
run >/dev/null
! grep -q 't.zip' "$T/sent" && grep -q 'b5.zip' "$T/sent" && ! grep -q 'Signature=abc\|storage.example.com' "$T/sent" && grep -q '<redacted>' "$T/sent" \
  && pass "11. a test run's log (other queues) is ignored; the URL in the evidence is redacted" || fail "11. ($(cat "$T/sent"))"
out="$(run BOX_LINK_WATCH_ROOT="$T/no-such")"; rc=$?
[ "$rc" = 0 ] && grep -q 'OK no relay box under' <<<"$out" && pass "11. no box dir -> nothing to watch, exit 0" || fail "11. none (rc $rc: $out)"

# 12. the manifest row
grep -qE '^box-link-watch +\| \* \* \* \* \* +\| src/bash/scripts/box-link-watch-cron.sh +\| box-link-watch/cron.log \| \| desk$' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/box-link-watch-cron.sh" ] \
  && pass "12. the manifest row box-link-watch runs the cron script every minute" || fail "12. manifest row"

# 13. the box-local env file
fresh; logl 8 "sent b6.zip hub -> box (10 B, sha256 aa) as b-6 in 1 s, waiting for the box's receipt"
printf 'BOX_LINK_WATCH_ROOT=%s\nBOX_LINK_WATCH_LOG_DIR=%s\nBOX_LINK_WATCH_HOME=%s/relay\nBOX_LINK_WATCH_RESULTS=$(touch %s/pwned)\n' "$R" "$L" "$T" "$T" >"$T/box.env"
out="$(run BOX_LINK_WATCH_ENV="$T/box.env" BOX_LINK_WATCH_ROOT= BOX_LINK_WATCH_LOG_DIR= BOX_LINK_WATCH_HOME= BOX_LINK_WATCH_RESULTS=)"
[ "$(n)" = 1 ] && grep -q 'b6.zip' "$T/sent" && [ ! -e "$T/pwned" ] \
  && pass "13. the relay paths come from the box-local env file; a \$(...) line in it is not run" || fail "13. env file ($(n): $out)"
out="$(run BOX_LINK_WATCH_ROOT= BOX_LINK_WATCH_LOG_DIR= BOX_LINK_WATCH_HOME=)"; rc=$?
[ "$rc" = 0 ] && grep -q 'OK no relay configured on this box' <<<"$out" && pass "13. no ROOT and no env file -> nothing to watch, exit 0" || fail "13. none (rc $rc: $out)"
out="$(run BOX_LINK_WATCH_HOME=)"; rc=$?
[ "$rc" != 0 ] && grep -q 'FATAL BOX_LINK_WATCH_LOG_DIR and BOX_LINK_WATCH_HOME must be set' <<<"$out" && pass "13. ROOT without HOME -> refused" || fail "13. no home (rc $rc: $out)"

# 14. a box with no topic row -> the fallback
fresh; logl 8 "sent b7.zip hub -> box (10 B, sha256 aa) as b-7 in 1 s, waiting for the box's receipt"
out="$(run BOX_LINK_WATCH_TOPICS="other=abcd1234")"; rc=$?
[ "$(n)" = 1 ] && [ "$rc" = 1 ] && grep -q '^--from|c-001|--to|c-002@sat|--kind|blocker|--task|box-link-watch-box|--body|LINK STUCK' "$T/sent" \
  && grep -q 'WARN box box has no topic' <<<"$out" && pass "14. a box with no topic row -> ONE blocker to the fallback, rc 1" || fail "14. (rc $rc, $(n): $(cat "$T/sent"); $out)"

# 15. an open incident older than the window, still no receipt -> not cleared
fresh; logl 8 "sent b8.zip hub -> box (10 B, sha256 aa) as b-8 in 1 s, waiting for the box's receipt"
run >/dev/null
later 361; out="$(run)"
[ "$(n)" = 1 ] && grep -q 'b8.zip sent, no receipt, 369 min' <<<"$out" && ! grep -q CLEARED "$T/sent" \
  && pass "15. an incident older than the 6 h window with no receipt stays open (no CLEARED)" || fail "15. ($(n): $(cat "$T/sent"); $out)"

# 16. UTC stamps under another TZ
fresh; logl 6 "sent b9.zip hub -> box (10 B, sha256 aa) as b-9 in 1 s, waiting for the box's receipt"
out="$(TZ=Europe/Sofia run)"
[ "$(n)" = 0 ] && grep -q 'b9.zip sent, no receipt, 6 min' <<<"$out" && pass "16. UTC stamps read under TZ=Europe/Sofia: 6 min -> no alert" || fail "16. ($(n): $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
