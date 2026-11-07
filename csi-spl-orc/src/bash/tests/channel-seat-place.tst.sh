#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_channel_seat_place carries out a channel seat ask (SPL-5000).
#          The hub, the launcher and the desk/add ./run are stubs that log.
#   1. DRY_RUN (default): prints the plan, touches nothing.
#   2. DRY_RUN=0: ack, launch that kind with a brief carrying Issue, Epic and
#      Spec, SPAWN_ISSUE_CREATE=0, desk
#      seat in the ask's tenant, channel add, close, in that order.
#   3. another ask is refused, nothing runs (control for the parse).
#   4. a launcher HOLD: exit 10, no seat, the ask stays acked (no close).
#   5. a failed add names the id and leaves the ask open; CHANNEL_SEAT_AGENT
#      re-runs without a second launch.
#   6. DRY_RUN=0 with no CHANNEL_SEAT_ISSUE is refused before the ack.
#   7. a REFUSED launch (exit 13) declines the ask with the launcher's reason,
#      and its stderr reaches the log.
#   8. the seat brief, read by the real do_spl_lane_issue (dry), places the
#      standing issue and files none (R7 W4).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SPOOL_TEST=1
mkdir -p "$T/bin" "$T/spool/dispatch" "$T/spool/c-001/inbox"
printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"
ASK=11111111-2222-4333-8444-555555555555
OTHER=99999999-2222-4333-8444-555555555555
SUMMARY="channel seat: kind=agy tenant=csitea channel=room-1 by=HUM-10; run: ASK_ID=11111111 DRY_RUN=0 ./run -a do_spl_channel_seat_place"

# the hub stub: the ask book in one JSON file, every write logged
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
book="$STUB_DIR/book.json"
[[ "$1" == ask ]] || { echo '{}'; exit 0; }
op="$2"; shift 2; id=""
reason=""
while (($#)); do [[ "$1" == --id ]] && id="$2"; [[ "$1" == --reason ]] && reason="$2"; shift; done
case "$op" in
  list) jq -c '{asks: .}' "$book" ;;
  *) echo "hub $op ${id:0:8}${reason:+ reason=$reason}" >>"$STUB_DIR/log"
     st=$([[ "$op" == ack ]] && echo acked || echo "$op")
     jq -c --arg i "$id" --arg s "$st" 'map(if .ask_id == $i then .state = $s else . end)' "$book" >"$book.n" && mv "$book.n" "$book"
     jq -c --arg i "$id" '{asks: map(select(.ask_id == $i))}' "$book" ;;
esac
STUB
cat >"$T/bin/launch" <<'STUB'
#!/usr/bin/env bash
echo "launch $1 box=$SPAWN_BOX brief=$(basename "$4") slug=$5 create=$SPAWN_ISSUE_CREATE" >>"$STUB_DIR/log"
cp "$4" "$STUB_DIR/brief.md"
[[ -n "${LAUNCH_ERR:-}" ]] && echo "$LAUNCH_ERR" >&2
[[ -n "${LAUNCH_RC:-}" ]] && exit "$LAUNCH_RC"
echo "a-777 %42"
STUB
cat >"$T/bin/run" <<'STUB'
#!/usr/bin/env bash
echo "run $2 ENV=$ENV tenant=$TENANT_ID${CHANNEL:+ channel=$CHANNEL}${AGENTS:+ agents=$AGENTS}${AGENT_BOX:+ box=$AGENT_BOX}${DESK_AGENT:+ desk=$DESK_AGENT}" >>"$STUB_DIR/log"
[[ "$2" == do_spl_channel_agent_add_op && -n "${ADD_RC:-}" ]] && exit "$ADD_RC"
exit 0
STUB
chmod +x "$T/bin/"*

book() { # <id> <topic> <summary>
  jq -cn --arg i "$1" --arg t "$2" --arg s "$3" '[{ask_id: $i, role: "orch", kind: "task", from: "HUM-10", topic: $t, summary: $s, state: "open", raised_n: 0, age_s: 1, quiet_s: 1}]' >"$T/book.json"
  : >"$T/log"
  rm -rf "$T/spool/asks"
}
act() {
  env SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_DESK_BOX=box-t SPOOL_ORCHESTRATOR_ID=c-001 SPOOL_AGENT_ID= \
    SPOOL_FLEET_RELAY=0 ASKS_HUB_CMD="$T/bin/hub" SPOOL_BIN="$T/bin/hub" STUB_DIR="$T" CHANNEL_SEAT_LAUNCH_CMD="$T/bin/launch" \
    CHANNEL_SEAT_RUN="$T/bin/run" CHANNEL_SEAT_BRIEF_DIR="$T/briefs" CHANNEL_SEAT_ISSUE=SPL-1 "$@" bash "$PROJ_ROOT/run" -a do_spl_channel_seat_place 2>&1
}

book "$ASK" channel-seat "$SUMMARY"
out="$(act ASK_ID=11111111)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"would start a agy agent"* && "$out" == *"#room-1"* && ! -s "$T/log" ]]; then pass "1 dry run plans and touches nothing"
else fail "1 dry run rc=$rc log=$(cat "$T/log") out=$out"; fi

book "$ASK" channel-seat "$SUMMARY"
out="$(act ASK_ID=11111111 DRY_RUN=0)"; rc=$?
want="hub ack 11111111
launch agy box=box-t brief=channel-seat-11111111.md slug=channel-seat-agy-room-1 create=0
run do_spl_desk_up ENV=dev tenant=csitea desk=a-777
run do_spl_channel_agent_add_op ENV=dev tenant=csitea channel=room-1 agents=a-777 box=box-t
hub done 11111111 reason=a-777@box-t added to #room-1 in csitea"
if (( rc == 0 )) && [[ "$(cat "$T/log")" == "$want" ]]; then pass "2 ack, launch, desk, add, close, in order"
else fail "2 rc=$rc log=[$(cat "$T/log")] out=$out"; fi
if grep -qx 'Issue: SPL-1' "$T/brief.md" && grep -qx 'Epic: SPL-2163' "$T/brief.md" && grep -qx 'Spec: csi-spl-doc/specs/005-spool-wui' "$T/brief.md"; then pass "2 the brief carries Issue, Epic and Spec"
else fail "2 brief: $(cat "$T/brief.md")"; fi
if ! grep -qE '\.gcp|key-csi|\.json' "$T/brief.md"; then pass "2 the brief names no credential path"
else fail "2 brief names a key"; fi

book "$OTHER" dispatch-abc "a blocker about something else"
out="$(act ASK_ID=99999999 DRY_RUN=0)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"not a channel seat"* && ! -s "$T/log" ]]; then pass "3 another ask is refused"
else fail "3 rc=$rc log=$(cat "$T/log") out=$out"; fi

book "$ASK" channel-seat "$SUMMARY"
out="$(act ASK_ID=11111111 DRY_RUN=0 LAUNCH_RC=10)"; rc=$?
if (( rc == 10 )) && ! grep -qE '^run |^hub done' "$T/log" && grep -q '^hub ack' "$T/log"; then pass "4 a HOLD seats nothing and closes nothing"
else fail "4 rc=$rc log=$(cat "$T/log") out=$out"; fi

book "$ASK" channel-seat "$SUMMARY"
out="$(act ASK_ID=11111111 DRY_RUN=0 ADD_RC=1)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"CHANNEL_SEAT_AGENT=a-777"* ]] && ! grep -q '^hub done' "$T/log"; then pass "5 a failed add names the id and does not close"
else fail "5 rc=$rc log=$(cat "$T/log") out=$out"; fi
: >"$T/log"
out="$(act ASK_ID=11111111 DRY_RUN=0 CHANNEL_SEAT_AGENT=a-777)"; rc=$?
if (( rc == 0 )) && ! grep -q '^launch' "$T/log" && grep -q '^run do_spl_channel_agent_add_op' "$T/log" && grep -q '^hub done' "$T/log"; then pass "5 the re-run launches nothing and closes"
else fail "5 re-run rc=$rc log=$(cat "$T/log") out=$out"; fi

book "$ASK" channel-seat "$SUMMARY"
out="$(act ASK_ID=11111111 DRY_RUN=0 CHANNEL_SEAT_ISSUE=)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"CHANNEL_SEAT_ISSUE=<KEY> is required"* && ! -s "$T/log" ]]; then pass "6 no standing issue: refused before the ack"
else fail "6 rc=$rc log=$(cat "$T/log") out=$out"; fi

book "$ASK" channel-seat "$SUMMARY"
why="a new agy lane (agy) on box-t: agy is on no box it may use (measured there: claude); nothing was spawned"
out="$(act ASK_ID=11111111 DRY_RUN=0 LAUNCH_RC=13 LAUNCH_ERR="spawn-window: REFUSED $why")"; rc=$?
if (( rc == 13 )) && grep -qxF "hub decline 11111111 reason=$why" "$T/log" && ! grep -qE '^run ' "$T/log"; then pass "7 a REFUSED launch declines the ask with the launcher's reason"
else fail "7 rc=$rc log=$(cat "$T/log") out=$out"; fi
if [[ "$out" == *"launcher: spawn-window: REFUSED"* ]]; then pass "7 the launcher's stderr reaches the log"
else fail "7 stderr not logged: $out"; fi

book "$ASK" channel-seat "$SUMMARY"
act ASK_ID=11111111 DRY_RUN=0 >/dev/null
mkdir -p "$T/spool/a-777/lifetime"
out="$(env SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_DESK_BOX=box-t SPOOL_ORCHESTRATOR_ID=c-001 SPOOL_AGENT_ID= \
  SPOOL_FLEET_RELAY=0 SPOOL_BIN="$T/bin/hub" AGENT_ID=a-777 BRIEF="$T/brief.md" bash "$PROJ_ROOT/run" -a do_spl_lane_issue 2>&1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"a-777 -> issue SPL-1 (wip)"* && "$out" != *"spool issue create"* ]]; then pass "8 the real do_spl_lane_issue places SPL-1 and files none"
else fail "8 rc=$rc out=$out"; fi

(( fails == 0 )) && echo "OK channel-seat-place" || { echo "FAILED $fails"; exit 1; }
