#!/usr/bin/env bash
# p14-02 (SPL-5819): the store and hub Postgres groups of hub-pg.tst.sh share
# ONE pool of HUB_PG_GROUP_JOBS slots (hub-pg-pool.inc.sh). No Postgres: the
# real store_group(s) / hub_group(s) functions are read out of hub-pg.tst.sh
# and launched as it launches them (two chains in the background), with
# group_db and pg_go_test stubbed. Each stub records its start and end, then
# waits until the pool is full (the cap running) or every group has started,
# so the peak number running at once is the pool's, not the stubs' timing.
# Asserts: peak == the cap (3 and 1; 8 for a cap above the group count),
# every group of both lists runs exactly once, one red group fails the gate
# by its name while the others still run, and a cap that is not a whole
# number >= 1 is refused. CONTROL (the commit body): run against the
# pre-pool hub-pg.tst.sh (HUB_PG_TST=<its path>) it reads peak 2 at cap 3.
# Usage: bash csi-spl-api/src/bash/tests/hub-pg-pool.tst.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_PG_TST="${HUB_PG_TST:-$HERE/hub-pg.tst.sh}"
STUB_WAIT="${STUB_WAIT:-10}" # s a stub waits for a full pool before it ends anyway (a broken pool)
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
fail() { echo "FAIL - $*"; fails=$((fails + 1)); }

# shellcheck source=store-pg-groups.inc.sh
source "$HERE/store-pg-groups.inc.sh"
# shellcheck source=hub-pg-groups.inc.sh
source "$HERE/hub-pg-groups.inc.sh"
# shellcheck source=hub-pg-pool.inc.sh
source "$HERE/hub-pg-pool.inc.sh"
TOTAL=$((${#STORE_PG_GROUPS[@]} + ${#HUB_PG_GROUPS[@]}))
# shellcheck disable=SC2034 # read by the functions eval-ed below
GO_TEST_TIMEOUT=20m
# The functions under test, verbatim from hub-pg.tst.sh (it refuses to be sourced).
fns="$(awk '/^(store|hub)_groups?\(\) \{/ { on = 1 } on { print } on && /^\}/ { on = 0 }' "$HUB_PG_TST")"
if ! grep -q '^store_groups() {' <<<"$fns" || ! grep -q '^hub_groups() {' <<<"$fns"; then
  echo "FAIL - no store_groups/hub_groups in $HUB_PG_TST"; exit 1
fi
eval "$fns"

group_db() { :; }
stub_log() { # <line>: append under the lock, so the log order is the event order
  ( flock 8; echo "$1" >>"$T/run/log" ) 8>"$T/run/lock"
}
stub_running() { awk '$1 == "S" { r++ } $1 == "E" { r-- } END { print r + 0 }' "$T/run/log"; }
stub_started() { grep -c '^S ' "$T/run/log"; }
pg_go_test() { # <db> <dir> <tag> ...: start, wait for a full pool, end; red for STUB_FAIL
  local tag="$3" i
  stub_log "S $tag"
  for ((i = 0; i < STUB_WAIT * 20; i++)); do
    [ "$(stub_running)" -ge "$CAP" ] || [ "$(stub_started)" -ge "$TOTAL" ] && break
    sleep 0.05 # a fixture: the stub plays a group that is still running
  done
  stub_log "E $tag"
  [ "$tag" != "${STUB_FAIL:-}" ]
}

launch() { # <cap>: the two chains as hub-pg.tst.sh launches them; prints their output, returns 1 if one is red
  local rc=0 ps hs
  CAP="$1"
  rm -rf "$T/run" && mkdir -p "$T/run" && : >"$T/run/log"
  pg_pool_open "$T/run" "$CAP" || return 2
  store_groups & ps=$!
  hub_groups & hs=$!
  wait "$ps" || rc=1
  wait "$hs" || rc=1
  return "$rc"
}
peak() { awk '$1 == "S" { r++; if (r > p) p = r } $1 == "E" { r-- } END { print p + 0 }' "$T/run/log"; }
each_once() { # every group of both lists started exactly once
  local g want=() got
  for g in "${STORE_PG_GROUPS[@]}"; do want+=("store-$g"); done
  for g in "${HUB_PG_GROUPS[@]}"; do want+=("hub-$g"); done
  got="$(grep '^S ' "$T/run/log" | cut -d' ' -f2 | sort)"
  [ "$got" = "$(printf '%s\n' "${want[@]}" | sort)" ] || { echo "ran: $(tr '\n' ' ' <<<"$got")"; return 1; }
}

for c in 3:3 1:1 "16:$TOTAL"; do
  cap="${c%%:*}" peak_want="${c#*:}"
  out="$(launch "$cap")"; rc=$?
  p="$(peak)"
  [ "$rc" -eq 0 ] || fail "cap $cap: the gate went red: $out"
  if [ "$p" -eq "$peak_want" ]; then echo "ok   - HUB_PG_GROUP_JOBS=$cap: peak $p groups at once"
  else fail "HUB_PG_GROUP_JOBS=$cap: peak $p groups at once, want $peak_want"; fi
  if e="$(each_once)"; then echo "ok   - HUB_PG_GROUP_JOBS=$cap: each of the $TOTAL store and hub groups ran exactly once"
  else fail "HUB_PG_GROUP_JOBS=$cap: not every group exactly once: $e"; fi
  [ "$(grep -c '^ok   - \(store\|hub\) group ' <<<"$out")" -eq "$TOTAL" ] || fail "cap $cap: not $TOTAL ok lines: $out"
done

out="$(STUB_FAIL=hub-b launch 3)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^FAIL - hub group b after [0-9]* s$' <<<"$out"; then
  echo "ok   - a red group (hub b) fails the gate and names its group"
else fail "red hub b: rc=$rc $out"; fi
if each_once >/dev/null && [ "$(grep -c '^ok   - ' <<<"$out")" -eq $((TOTAL - 1)) ]; then
  echo "ok   - a red group does not stop the others: the other $((TOTAL - 1)) ran green"
else fail "red hub b stopped others: $out"; fi

for bad in 0 x 03 ''; do
  rm -rf "$T/run" && mkdir -p "$T/run"
  if err="$(pg_pool_open "$T/run" "$bad" 2>&1)"; then fail "HUB_PG_GROUP_JOBS='$bad' accepted"
  elif grep -q "HUB_PG_GROUP_JOBS must be a whole number >= 1 (got '$bad')" <<<"$err"; then
    echo "ok   - HUB_PG_GROUP_JOBS='$bad' refused"
  else fail "HUB_PG_GROUP_JOBS='$bad': $err"; fi
done

[ "$fails" -eq 0 ] || { echo "FAIL - hub-pg-pool: $fails failure(s)"; exit 1; }
echo "ALL hub-pg-pool CHECKS PASSED"
