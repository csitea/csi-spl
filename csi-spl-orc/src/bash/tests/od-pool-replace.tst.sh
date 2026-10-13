#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 134 section 4.2 (b) "a broken peer is detected quickly, killed
#          and replaced", step P3 / T3: do_spl_od_pool_supervise against the
#          stubs of od-pool-stub.inc.sh (spawn-window.sh, do_spl_wd_takeover,
#          kill and the hub are stubs; the able verdict is the real
#          spl_lease_agent_able on fake panes).
#   1. OD_POOL_SUPERVISE on, one box: four ticks fill the 2 + 2 target, one
#      spawn per tick, each slot lease held by its seat
#   2. a usage-limit banner on one Grok seat while its partner is able, n = 10:
#      tick 1 keeps the pid; tick 2 releases its jobs (gen + 1) and replaces it
#      through the takeover: the old pid gone, a new pid under the same id,
#      the target still 2 + 2, the old session's renew refused (ask_held)
#   3. controls: a seat inside a 10-minute tool call (live process, no banner,
#      progress 10 min old) keeps its pid and its loop renews; a banner whose
#      reset already passed is not a stall
#   4. a refused takeover (exit 3: a limit is S2, never taken over) leaves the
#      seat and sends ONE note to the dispatch holder in an hour
#   5. a box gone (its slot leases silent > OD_SLOT_TTL), two supervisors
#      racing for its seats, n = 20: exactly one spawn per missing seat
#   6. mutation control: a supervisor that takes a slot whatever its age
#      steals live slots, so case 5's count goes red
#   7. OD_POOL_SUPERVISE off: the seats this box spawned are retired (P3
#      rollback), and nothing is spawned
#   8. the cron installer: two tagged lines (every 30 s), installed OFF,
#      idempotent, removed; another job's line is kept
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
source "$TEST_DIR/od-pool-stub.inc.sh"
LIMIT="You've hit your limit · resets 3pm (Etc/GMT-3)"
PASSED="Usage limit reached · resets 9am (Etc/GMT-3)"

# --- 1. fill ------------------------------------------------------------------------
for _ in 1 2 3 4; do sup; done
sup
[[ "$(seats)" == "c-601 c-602 g-603 g-604 " && "$(wc -l < "$T/spawn.log")" == 4 ]] &&
  [[ "$(cut -d' ' -f1 "$H/lease/od-claude-1")" == c-601@b1 && "$(cut -d' ' -f1 "$H/lease/od-grok-2")" == g-604@b1 ]] &&
  pass "1. four ticks fill 2 + 2, one spawn per tick; each slot lease names its seat" ||
  fail "1. seats '$(seats)' spawns $(cat "$T/spawn.log" 2>&1) leases $(head "$H"/lease/* 2>&1)"

# --- 2. a usage-limit banner on g-603, n = 10 -------------------------------------------
hub ask pool --set --kinds route_post > /dev/null
ok=0
for i in $(seq 1 10); do
  echo '[]' > "$H/rows.json"; rm -f "$S"/od/*/job.json
  hub ask enqueue --id "h-$i" --kind route_post > /dev/null
  seat g-603
  gen="$(row "h-$i" .gen)" old="$(seatpid g-603)"
  pane "$old" "$LIMIT"
  sup
  t1=0; [[ -d "$P/$old" && "$(cat "$T/takeover.log" 2>/dev/null | wc -l)" == $((i - 1)) ]] && t1=1
  sup
  new="$(seatpid g-603)"
  if (( t1 )) && [[ ! -d "$P/$old" && -n "$new" && "$new" != "$old" && "$(seats)" == "c-601 c-602 g-603 g-604 " ]] &&
     [[ "$(row "h-$i" .state)" == open && "$(row "h-$i" .gen)" == $((gen + 1)) ]] &&
     ! hub ask renew --id "h-$i" --by g-603@b1 --gen "$gen" > /dev/null 2>&1; then ok=$((ok + 1)); fi
done
[[ "$ok" == 10 ]] && pass "2. banner on g-603: kept on tick 1, released + replaced on tick 2 (same id, new pid, 2 + 2, old gen refused) in 10 of 10" ||
  fail "2. $ok of 10; takeovers: $(cat "$T/takeover.log" 2>&1) log: $(tail -4 "$S/od/g-603/seat.log")"

# --- 3. controls: a long tool call; a passed reset ----------------------------------------
echo '[]' > "$H/rows.json"; rm -f "$S"/od/*/job.json; : > "$T/takeover.log"
hub ask enqueue --id l-1 --kind route_post > /dev/null
seat c-601
pane "$(seatpid c-601)" "⏺ Bash(make test)
  ⎿  Running… (10m 0s)"
mkdir -p "$S/c-601"; jq -nc --arg t "$(date -u -d "@$((NOW - 600))" +%FT%TZ)" '{progress_ts: $t}' > "$S/c-601/heartbeat.json"
p1="$(seatpid c-601)"; pane "$(seatpid c-602)" "$PASSED"; p2="$(seatpid c-602)"
sup; sup; NOW=$((NOW + 30)); seat c-601
[[ "$(seatpid c-601)" == "$p1" && "$(seatpid c-602)" == "$p2" && ! -s "$T/takeover.log" ]] &&
  grep -q 'HOLD l-1 gen 1' "$S/od/c-601/seat.log" && [[ "$(row l-1 .lock_until)" == $((NOW + 120)) ]] &&
  pass "3. controls: a 10-minute tool call keeps its pid and renews; a banner whose reset passed is no stall" ||
  fail "3. pids $p1/$(seatpid c-601) $p2/$(seatpid c-602) takeovers $(cat "$T/takeover.log") lock $(row l-1 .lock_until)"

# --- 4. a refused takeover --------------------------------------------------------------
echo "c-002@b1 $NOW" > "$S/dispatch/lease"; : > "$T/sent.log"
p4="$(seatpid g-604)"; pane "$p4" "$LIMIT"
for _ in 1 2 3 4; do sup TAKEOVER_RC=3; done
[[ "$(seatpid g-604)" == "$p4" && "$(grep -c '^g-604 ' "$T/takeover.log")" == 2 && "$(grep -c '^c-002@b1 :: OD POOL' "$T/sent.log")" == 1 ]] &&
  pass "4. a refused takeover keeps the seat, two tries in four ticks, ONE note to the dispatch holder" ||
  fail "4. pid $p4/$(seatpid g-604) takeovers $(cat "$T/takeover.log") sent $(cat "$T/sent.log")"
rm -f "$T/pane/$p4"

# --- 5. a box gone, two supervisors racing, n = 20 -------------------------------------------
gone() {
  rm -f "$H"/lease/* "$T/spawn.log"; rm -rf "$T/s1" "$T/s2"; mkdir -p "$T/s1/dispatch" "$T/s2/dispatch"
  echo "c-701@b3 1 $((NOW - 400))" > "$H/lease/od-claude-1"; echo "g-702@b3 1 $((NOW - 400))" > "$H/lease/od-grok-1"
  hub ask pool --set --claude-n 1 --grok-n 1 > /dev/null
}
race() { sup SPOOL_ROOT="$T/s1" OD_BOX=b1 OD_BOXES=b3,b1,b2 BOX_NAME=b1 & sup SPOOL_ROOT="$T/s2" OD_BOX=b2 OD_BOXES=b3,b1,b2 BOX_NAME=b2 & wait; }
spawned_once() { [[ "$(cat "$T/spawn.log" 2>/dev/null | wc -l)" == 2 && "$(grep -c ' od-claude-1 ' "$T/spawn.log")" == 1 && "$(grep -c ' od-grok-1 ' "$T/spawn.log")" == 1 ]]; }
ok=0
for _ in $(seq 1 20); do gone; race; race; spawned_once && ok=$((ok + 1)); done
[[ "$ok" == 20 ]] && pass "5. a box gone: two supervisors race for its 2 seats, exactly one spawn per seat in 20 of 20 rounds" ||
  fail "5. $ok of 20; last spawns: $(cat "$T/spawn.log" 2>&1)"

# --- 6. mutation control: take a slot whatever its age --------------------------------------
seq_ticks() { local i; for i in 1 2; do
  sup SPOOL_ROOT="$T/s1" OD_BOX=b1 OD_BOXES=b3,b1,b2 BOX_NAME=b1; sup SPOOL_ROOT="$T/s2" OD_BOX=b2 OD_BOXES=b3,b1,b2 BOX_NAME=b2; done; }
gone; seq_ticks; real=0; spawned_once && real=1
ODSRC="$(mutant any-age spl-od-pool-supervise.func.sh 'FA >= OD_SLOT_TTL' 'FA >= 0')" || fail "6. mutant not built"
export ODSRC; gone; seq_ticks; unset ODSRC
(( real )) && ! spawned_once && pass "6. control: taking live slots double-spawns on the mutant ($(wc -l < "$T/spawn.log") spawns); the real code spawns 2" ||
  fail "6. real=$real mutant spawns: $(cat "$T/spawn.log" 2>&1)"

# --- 7. off = rollback ---------------------------------------------------------------------
hub ask pool --set --claude-n 2 --grok-n 2 > /dev/null; : > "$T/spawn.log"
pids="$(for s in c-601 c-602 g-603 g-604; do seatpid "$s"; done | tr '\n' ' ')"
sup OD_POOL_SUPERVISE=0
gone7=1; for p in $pids; do [[ -d "$P/$p" ]] && gone7=0; done
[[ "$gone7" == 1 && -z "$(seats)" && ! -s "$T/spawn.log" && "$(grep -c 'RETIRED (OD_POOL_SUPERVISE is off)' "$S"/od/*/seat.log | awk -F: '{s += $2} END {print s}')" == 4 ]] &&
  pass "7. off: the 4 seats this box spawned are retired (by pid), none spawned" ||
  fail "7. pids $pids seats '$(seats)' spawns $(cat "$T/spawn.log")"

# --- 8. the cron lines ---------------------------------------------------------------------
printf '#!/usr/bin/env bash\nif [ "$1" = -l ]; then cat "%s/crontab" 2>/dev/null; else cat "$1" > "%s/crontab"; fi\n' "$T" "$T" > "$T/bin/crontab"
chmod +x "$T/bin/crontab"; echo "0 * * * * other-job # someone:else" > "$T/crontab"
cron() { od OD_CRONTAB="$T/bin/crontab" OD_CRON_ALLOW_WORKTREE=1 DRY_RUN=0 "$@" -- \
  'source "$PROJ_PATH/lib/bash/funcs/cron-tagged-line.func.sh"; source "$PROJ_PATH/src/bash/run/spl-od-pool-supervise-install-cron.func.sh"; do_spl_od_pool_supervise_install_cron' > /dev/null 2>&1; }
cron; cron
on="$(grep -c 'OD_POOL_SUPERVISE=0 .*do_spl_od_pool_supervise .*# csi-spl:od-pool-supervise$' "$T/crontab")"
on30="$(grep -c '^\* \* \* \* \* sleep 30; .*# csi-spl:od-pool-supervise-30$' "$T/crontab")"
cron OD_CRON_ACTION=remove
[[ "$on" == 1 && "$on30" == 1 && "$(grep -c od-pool-supervise "$T/crontab")" == 0 && "$(grep -c 'someone:else' "$T/crontab")" == 1 ]] &&
  pass "8. cron: two lines (every 30 s) installed off, twice = once, removed; the other job kept" ||
  fail "8. on=$on on30=$on30 crontab: $(cat "$T/crontab")"

[[ "$fails" == 0 ]] && echo "OK od-pool-replace: all passed" || { echo "FAILED od-pool-replace: $fails"; exit 1; }
