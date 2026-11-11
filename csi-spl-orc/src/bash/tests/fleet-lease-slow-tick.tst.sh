#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5339, a slow fleet tick must not age the holder's row. sat
#          2026-11-11 (load5 121..136, 198 ticks in dial.log): LEASE_PERIOD 60
#          s, one tick 124 s p50 / 184 s p90 / 246 s max, the time in the seat
#          checks (pin-<role> -> read 19 s / 26 s p50, 94 s max); the hub row
#          and the local lease file went over LEASE_STALE (180 s) in 21 of 181
#          ticks while c-002@sat held dispatch: "lease: GAP stale" in
#          dispatch-check, and pc took the role from a live holder 4 times
#          ("silent 213s", 20:00:36Z). Scaled down 1:15 here: LEASE_PERIOD 2,
#          LEASE_STALE 10, a stub hub with a real clock answering in HUB_S
#          (0.5) s per call across W (4) tenant copies, a pane read of
#          PANE_S (2.5) s, 4 per tick (2 per role): a tick of ~14 s, 1.4 x
#          LEASE_STALE, sat's worst (246 s / 180 s); LEASE_KEEP_MAX 2 x.
#   1. the real loop, 3 ticks, keeper on: the local lease file and the hub
#      row stay under LEASE_STALE the whole run (sampled every 0.2 s); the
#      calls are counted per kind (t1 read / t1 write / tenant copy)
#   2. CONTROL, the same run with LEASE_KEEP=0 (the code before SPL-5339):
#      both go over LEASE_STALE - the test sees the defect
#   3. the keeper never names a holder the hub does not (one keeper pass,
#      stub clock): it renews only the holder the tick judged ours while the
#      hub still names it; a row another box took, no keep mark, a judgement
#      older than LEASE_KEEP_MAX and an own write younger than
#      LEASE_KEEP_AFTER cost zero hub calls; a handback wait keeps the
#      mirror's old name while the hub row is renewed; KEEP logged once
#   4. a tick that finds no able seat removes the keep mark
#  RED CONTROL on 269de997c's code: LEASE_SRC=<that file> fails 1 (the
#  keeper does not exist there). Fixtures only in a mktemp root.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
SRC="${LEASE_SRC:-$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh}"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v flock >/dev/null || { echo "FAIL: flock is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
mkdir -p "$T/bin"

printf '#!/bin/sh\nexit 0\n' >"$T/bin/send"
# The pane stub: a seat check costs PANE_S s (the /proc + pane + transcript
# reads under sat's load); no screen = able.
printf '#!/bin/sh\necho "$1" >>"%s/pane.calls"\nsleep "${PANE_S:-0}"\nexit 1\n' "$T" >"$T/bin/pane"
# The hub stub: "holder gen at" per [tenant.]fleet.role, compare-and-set under
# a lock (the real hub's row lock), age on HUB_NOW else the real clock, each
# call HUB_S s and one line in calls: "<tenant|t1> <role> read|write".
cat >"$T/bin/hub" <<'STUB'
#!/bin/sh
shift
fleet="" role="" holder="" ifgen=""
while [ $# -gt 0 ]; do case "$1" in --fleet) fleet="$2";; --role) role="$2";; --holder) holder="$2";; --if-gen) ifgen="$2";; esac; shift 2; done
sleep "${HUB_S:-0}"
echo "${LEASE_HUB_TENANT:-t1} $role $([ -n "$holder" ] && echo write || echo read)" >>"$HUB_DIR/calls"
f="$HUB_DIR/${LEASE_HUB_TENANT:+$LEASE_HUB_TENANT.}$fleet.$role"
exec 9>"$f.lock"; flock 9
now="${HUB_NOW:-$(date +%s)}" h="" g=0 at=0
[ -s "$f" ] && read -r h g at <"$f"
won=false
if [ -n "$holder" ] && [ "$ifgen" = "$g" ]; then g=$((g + 1)); h="$holder"; at="$now"; echo "$h $g $at" >"$f"; won=true; fi
age=-1; [ "$g" -gt 0 ] && age=$((now - at))
printf '{"fleet":"%s","role":"%s","holder":"%s","box":"b","gen":%s,"age_s":%s,"won":%s}\n' "$fleet" "$role" "$h" "$g" "$age" "$won"
STUB
chmod +x "$T/bin/"*

# agent <dir> <pid> <id>: a live claude process in the fake /proc
agent() { mkdir -p "$1/proc/$2"; echo claude >"$1/proc/$2/comm"; printf 'SPOOL_AGENT_ID=%s\0' "$3" >"$1/proc/$2/environ"; }

# lease_env <dir>: LE = the settings of one machine "sat" ranked first
lease_env() {
  LE=(PROJ_PATH="$PROJ_ROOT" SRC="$SRC" SPOOL_ROOT="$1/spool" LEASE_PROC_ROOT="$1/proc" LEASE_SEND="$T/bin/send" \
    LEASE_PANE_CMD="$T/bin/pane" LEASE_HUB_CMD="$T/bin/hub" HUB_DIR="$1/hub" LEASE_FLEET=main LEASE_MACHINE=sat \
    "LEASE_PRIORITY=sat,pc" LEASE_HOLDDOWN=0 LEASE_ASKS=0 LEASE_AGENT_RUN=0 LEASE_DESK_GATE=0 LEASE_UNREAD_MAX=0 \
    LEASE_HEALTH=0 LEASE_ALERT=0 LEASE_ROLE_SWITCH=0 LEASE_ORCH=c-001 LEASE_MASTER=c-002 LEASE_FAILOVER=c-003 \
    "LEASE_MIRROR_TENANTS=w1 w2 w3 w4")
}
setup() { mkdir -p "$1/hub" "$1/spool/dispatch"; agent "$1" 100 c-001; agent "$1" 101 c-002; }

# run_loop <dir> [env...]: the real fleet loop, LEASE_TICKS 3, sampled every
# 0.2 s; prints "<max file age> <max hub age> <samples>" of the dispatch role
run_loop() {
  local d="$1" pid now lt hat max_f=0 max_h=0 n=0; shift
  setup "$d"
  lease_env "$d"
  env "${LE[@]}" LEASE_PERIOD=2 LEASE_STALE=10 LEASE_TICKS=3 HUB_S=0.5 PANE_S=2.5 LEASE_KEEP=1 LEASE_KEEP_EVERY=1 "$@" bash -c '
    set -uo pipefail
    do_log() { :; }
    source "$SRC"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_loop fleet' >>"$T/out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if read -r _ lt 2>/dev/null < "$d/spool/dispatch/lease" && [[ "$lt" =~ ^[0-9]+$ ]]; then
      (( now - lt > max_f )) && max_f=$((now - lt)); n=$((n + 1))
    fi
    if read -r _ _ hat 2>/dev/null < "$d/hub/main.dispatch" && [[ "$hat" =~ ^[0-9]+$ ]]; then
      (( now - hat > max_h )) && max_h=$((now - hat))
    fi
    sleep 0.2
  done
  echo "$max_f $max_h $n"
}
calls() { grep -c -- "$2" "$1/hub/calls" 2>/dev/null || true; }

# --- 1. the real loop, keeper on --------------------------------------------------
t0=$SECONDS
read -r mf mh n <<<"$(run_loop "$T/k")"
took=$((SECONDS - t0))
[[ "$(cut -d' ' -f1 "$T/k/hub/main.dispatch")" == c-002@sat && "$n" -gt 20 && "$mf" -lt 10 && "$mh" -lt 10 ]] &&
  pass "1. a tick of ~$((took / 3))s against LEASE_STALE 10: the lease file at most ${mf}s old, the hub row ${mh}s ($n samples)" ||
  fail "1. keeper on: file ${mf}s hub ${mh}s n=$n took ${took}s hub=$(cat "$T/k/hub/main.dispatch" 2>&1): $(tail -5 "$T/out")"
echo "INFO 1. seat checks $(wc -l <"$T/pane.calls"), hub calls in ${took}s: t1 read $(calls "$T/k" '^t1 .* read$'), t1 write $(calls "$T/k" '^t1 .* write$'), tenant copies $(calls "$T/k" '^w[0-9] ') ($(calls "$T/k" '^w1 ') per tenant)"
[[ "$(grep -c '^.*KEEP dispatch: no tick renewed c-002@sat' "$T/k/spool/dispatch/lease.log" 2>/dev/null)" -ge 1 ]] &&
  pass "1. the keeper's renewal is in lease.log (one KEEP line per episode)" || fail "1. no KEEP line: $(cat "$T/k/spool/dispatch/lease.log" 2>&1)"

# --- 2. CONTROL: no keeper ---------------------------------------------------------
read -r cf ch cn <<<"$(run_loop "$T/c" LEASE_KEEP=0)"
[[ "$cf" -gt 10 && "$ch" -gt 10 ]] &&
  pass "2. control: LEASE_KEEP=0 (the code before SPL-5339) lets the file reach ${cf}s and the row ${ch}s ($cn samples)" ||
  fail "2. control did not go stale: file ${cf}s hub ${ch}s n=$cn"

# --- 3. one keeper pass: never a holder the hub does not name ---------------------
K="$T/p"; setup "$K"
# keep <hub-now> [env...]: one spl_fleet_keep_tick on sat at that clock
keep() {
  local now="$1"; shift
  lease_env "$K"
  env "${LE[@]}" LEASE_NOW="$now" HUB_NOW="$now" LEASE_PERIOD=60 LEASE_STALE=180 LEASE_MIRROR_WAIT=1 "$@" bash -c '
    set -uo pipefail
    do_log() { :; }
    source "$SRC"
    spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_fleet_keep_tick' >>"$T/out" 2>&1
}
D="$K/spool/dispatch"
row() { echo "$1 $2 $3" >"$K/hub/main.$4"; }
n_calls() { wc -l <"$K/hub/calls" 2>/dev/null | tr -d ' ' || echo 0; }
: >"$K/hub/calls"
row c-002@sat 7 1000 dispatch; echo "c-002@sat 1000" >"$D/lease"; echo 1000 >"$D/fleet.dispatch.ok"; echo "c-002@sat 1000" >"$D/fleet.dispatch.keep-holder"
keep 1100
[[ "$(cat "$K/hub/main.dispatch")" == "c-002@sat 8 1100" && "$(cat "$D/lease")" == "c-002@sat 1100" && "$(cat "$D/fleet.dispatch.ok")" == 1100 &&
   "$(cat "$D/fleet.dispatch.ok.gen")" == 8 && "$(calls "$K" '^w[0-9] dispatch write')" == 4 ]] &&
  pass "3. a held row the tick left 100 s ago: the keeper renews the same holder (gen 8), the file, ok and the 4 tenant copies" ||
  fail "3. renew: hub $(cat "$K/hub/main.dispatch") file $(cat "$D/lease") ok $(cat "$D/fleet.dispatch.ok")"
keep 1200
[[ "$(grep -c 'KEEP dispatch' "$D/lease.log")" == 1 ]] && pass "3. KEEP is logged once per episode" || fail "3. KEEP lines: $(cat "$D/lease.log")"
: >"$K/hub/calls"; keep 1230
[[ "$(n_calls)" == 0 ]] && pass "3. an own write 30 s old (< LEASE_KEEP_AFTER 90) costs no hub call" || fail "3. after: $(cat "$K/hub/calls")"
row c-002@pc 20 1290 dispatch; : >"$K/hub/calls"; keep 1300
[[ "$(cat "$K/hub/main.dispatch")" == "c-002@pc 20 1290" && "$(cat "$D/lease")" == "c-002@sat 1200" && "$(n_calls)" == 1 ]] &&
  pass "3. a row another box took: one read, no write, the local file keeps the tick's last word (no split brain)" ||
  fail "3. other box: hub $(cat "$K/hub/main.dispatch") file $(cat "$D/lease") calls $(n_calls)"
row c-002@sat 21 1000 dispatch; echo "c-002@sat 1000" >"$D/fleet.dispatch.ok"; echo "c-002@sat 1000" >"$D/fleet.dispatch.keep-holder"
: >"$K/hub/calls"; keep 1361
[[ "$(n_calls)" == 0 && "$(cut -d' ' -f2 "$K/hub/main.dispatch")" == 21 ]] &&
  pass "3. a tick judgement 361 s old (> LEASE_KEEP_MAX 360): no call, a hung loop lets the row go stale" || fail "3. max: $(cat "$K/hub/calls")"
rm -f "$D/fleet.dispatch.keep-holder"; : >"$K/hub/calls"; keep 1200
[[ "$(n_calls)" == 0 ]] && pass "3. no keep mark (the tick judged no seat of ours): no call" || fail "3. no mark: $(cat "$K/hub/calls")"
row c-001@sat 5 1000 orch; echo "c-001@pc 1000" >"$D/lease.orch"; echo 1000 >"$D/fleet.orch.ok"; echo "c-001@sat 1000" >"$D/fleet.orch.keep-holder"
keep 1100
[[ "$(cat "$K/hub/main.orch")" == "c-001@sat 6 1100" && "$(cat "$D/lease.orch")" == "c-001@pc 1000" ]] &&
  pass "3. a handback wait (the file still names c-001@pc): the hub row is renewed, the file keeps its old name" ||
  fail "3. handback: hub $(cat "$K/hub/main.orch") file $(cat "$D/lease.orch")"

# --- 4. the tick's mark ----------------------------------------------------------
M="$T/m"; setup "$M"
tick4() { lease_env "$M"; env "${LE[@]}" LEASE_NOW="$1" HUB_NOW="$1" bash -c '
  set -uo pipefail
  do_log() { :; }
  source "$SRC"
  spl_lease_init && spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init && spl_lease_fleet_tick' >>"$T/out" 2>&1; }
tick4 2000
[[ "$(cat "$M/spool/dispatch/fleet.dispatch.keep-holder" 2>&1)" == "c-002@sat 2000" ]] &&
  pass "4. a tick that holds with an able seat marks it for the keeper" || fail "4. mark: $(cat "$M/spool/dispatch/fleet.dispatch.keep-holder" 2>&1)"
rm -rf "$M/proc/101"
tick4 2060
[[ ! -e "$M/spool/dispatch/fleet.dispatch.keep-holder" && "$(cat "$M/spool/dispatch/fleet.orch.keep-holder" 2>&1)" == "c-001@sat 2060" ]] &&
  pass "4. a tick with no able dispatch seat removes the mark: the keeper stops, the row goes stale as before" ||
  fail "4. unmark: $(ls "$M/spool/dispatch")"

[[ "$fails" == 0 ]]
