#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 134 section 4.1 (a) "no single failure point", step P3 / T2:
#          do_spl_od_seat against the hub stub of od-pool-stub.inc.sh (the
#          store's own races: TestFleetAskLockNextRaces). Four seats, two per
#          vendor, on two boxes.
#   1. kinds empty (P3 as shipped): every seat ticks, nothing is locked
#   2. 4 seats race for 1 open row, n = 20 rounds: exactly one holds it
#   3. 40 rows, the seats lock, work and close them: each locked once, 40 done
#   4. control: 2 rows, 2 seats -> both locked, one each
#   5. SIGKILL the holder: its loop stops renewing; once the lease ran out a
#      seat of the OTHER vendor on the box that does NOT hold the orch lease
#      locks it and closes it: exactly one done; the old gen's renew is refused
#   6. a seat whose agent closed its job drops it on its next tick (ask_closed)
#   7. mutation control: a seat loop that renews without the able check keeps
#      the dead holder's lock alive, so case 5 goes red on it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
source "$TEST_DIR/od-pool-stub.inc.sh"

agent 101 c-501; agent 102 c-502; agent 103 g-503 grok; agent 104 g-504 grok
echo "c-001@b1 $NOW" > "$S/dispatch/lease.orch"
box() { case "$1" in c-501|g-503) echo b1 ;; *) echo b2 ;; esac; }
tick_all() { local s; for s in c-501 c-502 g-503 g-504; do seat "$s" OD_BOX="$(box "$s")" & done; wait; }
holders() { ls "$S"/od/*/job.json 2>/dev/null | wc -l; }

# --- 1. kinds empty ---------------------------------------------------------------
hub ask enqueue --id r-1 --kind route_post > /dev/null
tick_all
[[ "$(row r-1 .state)" == open && "$(holders)" == 0 && -s "$S/od/c-501/beat" ]] &&
  pass "1. kinds empty: four seats tick (beat written), nothing is locked" ||
  fail "1. state $(row r-1 .state), holders $(holders): $(cat "$S"/od/*/seat.log 2>&1)"

# --- 2. the race, n = 20 -------------------------------------------------------------
hub ask pool --set --kinds route_post > /dev/null
ok=0
for i in $(seq 1 20); do
  rm -f "$S"/od/*/job.json; echo '[]' > "$H/rows.json"
  hub ask enqueue --id "x-$i" --kind route_post > /dev/null
  tick_all
  by="$(row "x-$i" .acked_by)"
  [[ "$(holders)" == 1 && -s "$S/od/${by%@*}/job.json" && "$(grep -c "^lock x-$i " "$H/events.log")" == 1 ]] && ok=$((ok + 1))
done
[[ "$ok" == 20 ]] && pass "2. 4 seats, 1 row: exactly one holder in 20 of 20 rounds" || fail "2. one holder in $ok of 20 rounds"

# --- 3. 40 rows, each locked once -----------------------------------------------------
rm -f "$S"/od/*/job.json; echo '[]' > "$H/rows.json"; : > "$H/events.log"
for i in $(seq 1 40); do hub ask enqueue --id "y-$i" --kind route_post > /dev/null; done
for _ in $(seq 1 12); do
  tick_all
  for s in c-501 c-502 g-503 g-504; do
    j="$S/od/$s/job.json"; [[ -s "$j" ]] || continue
    hub ask "done" --id "$(jq -r .ask_id "$j")" --by "$s@$(box "$s")" --gen "$(jq -r .gen "$j")" > /dev/null
  done
  tick_all
done
once="$(grep '^lock y-' "$H/events.log" | awk '{print $2}' | sort | uniq -c | awk '$1 == 1' | wc -l)"
[[ "$once" == 40 && "$(grep -c '^done y-' "$H/events.log")" == 40 && "$(holders)" == 0 ]] &&
  pass "3. 40 rows: each locked exactly once, 40 done, no seat still holds one" ||
  fail "3. locked once: $once, done: $(grep -c '^done y-' "$H/events.log"), holders $(holders)"

# --- 4. control: 2 rows, 2 seats ------------------------------------------------------
echo '[]' > "$H/rows.json"
hub ask enqueue --id z-1 --kind route_post > /dev/null; hub ask enqueue --id z-2 --kind route_post > /dev/null
seat c-501 OD_BOX=b1 & seat g-503 OD_BOX=b1 & wait
[[ "$(row z-1 .state)" == acked && "$(row z-2 .state)" == acked && "$(row z-1 .acked_by)" != "$(row z-2 .acked_by)" ]] &&
  pass "4. control: 2 rows, 2 seats -> both locked, one each" || fail "4. $(cat "$H/rows.json")"

# --- 5. SIGKILL the holder -------------------------------------------------------------
case5() {
  rm -f "$S"/od/*/job.json "$S"/od/*/last.*; echo '[]' > "$H/rows.json"; : > "$H/events.log"
  agent 101 c-501
  hub ask enqueue --id k-1 --kind route_post > /dev/null
  NOW=1791885600; seat c-501 OD_BOX=b1
  local gen; gen="$(row k-1 .gen)"
  rm -rf "${P:?}/101"
  NOW=$((NOW + 60)); seat c-501 OD_BOX=b1
  NOW=$((NOW + 61)); seat c-501 OD_BOX=b1; seat g-504 OD_BOX=b2
  local by; by="$(row k-1 .acked_by)"
  [[ -s "$S/od/g-504/job.json" ]] && hub ask "done" --id k-1 --by g-504@b2 --gen "$(row k-1 .gen)" > /dev/null
  [[ "$by" == g-504@b2 && "$(grep -c '^done k-1 ' "$H/events.log")" == 1 && "$(row k-1 .raised_n)" == 1 ]] || return 1
  hub ask renew --id k-1 --by c-501@b1 --gen "$gen" > /dev/null 2>&1 && return 1
  grep -q 'NO-RENEW k-1: not able: no live process' "$S/od/c-501/seat.log"
}
case5 && pass "5. SIGKILL the holder: it stops renewing, g-504 on b2 (not the orch box) locks it after 121 s, one done, the old gen is refused" ||
  fail "5. rows $(cat "$H/rows.json") events $(cat "$H/events.log") log $(tail -3 "$S/od/c-501/seat.log")"

# --- 6. a closed job is dropped -------------------------------------------------------
echo '[]' > "$H/rows.json"; rm -f "$S"/od/*/job.json
hub ask enqueue --id d-1 --kind route_post > /dev/null
seat g-503 OD_BOX=b1
hub ask "done" --id d-1 --by g-503@b1 --gen 1 > /dev/null
seat g-503 OD_BOX=b1
[[ ! -e "$S/od/g-503/job.json" ]] && grep -q 'END d-1 gen 1: ask_closed' "$S/od/g-503/seat.log" &&
  pass "6. the agent closed its job: the loop drops it on the next tick (ask_closed)" || fail "6. $(tail -3 "$S/od/g-503/seat.log")"

# --- 7. mutation control -----------------------------------------------------------------
ODSRC="$(mutant renew-dead spl-od-seat.func.sh 'if [[ -z "$pid" ]]; then why="not able' 'if false; then why="not able')" || fail "7. mutant not built"
export ODSRC
case5 && fail "7. control: a loop renewing for a dead agent still passed case 5" ||
  pass "7. control: a loop that renews without the able check keeps the dead lock: case 5 is red on it"
unset ODSRC

[[ "$fails" == 0 ]] && echo "OK od-pool-spof: all passed" || { echo "FAILED od-pool-spof: $fails"; exit 1; }
