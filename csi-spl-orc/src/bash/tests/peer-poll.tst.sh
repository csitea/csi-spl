#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_peer_poll / do_spl_peer_ensure / do_spl_peer_fence (spec 068
#          sections 4.1, 4.2 and 7, lane L3). No live agent and no hub is
#          touched: 8 simulated ODs on 2 boxes (sat, pc: c-001 c-002 g-003
#          g-004 each, a fake /proc per box) poll a hub STUB that implements
#          the claim contract of 4.1 (claim = lock + gen + claim_n in one
#          step, renew, check, adopt) on a fake clock (LEASE_NOW). Each seat
#          ticks every 5 s at its own second, as the staggered loops do.
#   1. inert: no seats file = poll and ensure write nothing
#   2. pickup: 20 messages, each taken within 5 s, by exactly one seat, into
#      exactly one inbox, once; a seat holds at most PEER_MAX_HELD
#   3. a dead peer: its message moves within 125 s of the death (n=3)
#   4. an undetected stall (able, transcript frozen): it moves after 600 s
#      and within 12 min; control: a holder that keeps writing keeps it
#   5. hub down: local-origin messages are locked locally by exactly one seat
#      within 5 s, hub messages are not touched; back up, each local lock is
#      pushed insert-if-absent
#   6. split brain: the cut-off box's message moves to the other box within
#      125 s; the cut-off holder's fence says "unconfirmed" (2) while cut and
#      "lost" (1) after, the new holder's says 0
#   7. ensure starts one loop per seat, is idempotent, restarts a dead one
#   8. a grok seat (no claude process) is found by its harness's process
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'for s in "$T"/*/peer/*/poll.pid; do [ -f "$s" ] && kill -- "-$(cat "$s")" 2>/dev/null; done; rm -rf "$T"' EXIT
mkdir -p "$T/bin"
T0=1800000000

# ---- the hub stub: one JSON file under a flock, the clock = LEASE_NOW -------
cat > "$T/bin/hub.py" <<'EOF'
import fcntl, json, os, sys
st = os.environ["HUB_DIR"]; now = int(os.environ["LEASE_NOW"])
a = sys.argv[1:]
if a and a[0] == "claim": a = a[1:]
op = a[0].lstrip("-"); o = dict(zip(a[1::2], a[2::2])) if op != "ctl" else {}
seat = o.get("--seat", "")
if seat and os.path.exists(os.path.join(st, "down." + seat.split("@")[1])): sys.exit(75)
lk = open(os.path.join(st, "lock"), "w"); fcntl.flock(lk, fcntl.LOCK_EX)
p = os.path.join(st, "db.json")
db = json.load(open(p)) if os.path.exists(p) else []
def save(): json.dump(db, open(p, "w"))
def row(m): return {k: m[k] for k in ("msg_id", "responsible_gen", "task_id", "ts", "from", "to", "kind", "body", "files")}
rc = 0; out = None
if op == "post":
    db.append({"msg_id": a[1], "posted": now, "ts": str(now), "task_id": "t-" + a[1], "from": "HUM-1", "to": "peers",
               "kind": "msg", "body": "hello " + a[1], "files": [], "responsible": None, "locked_until": 0,
               "responsible_gen": 0, "claim_n": 0, "handled": False, "not_by": [], "claims": []})
elif op == "poll":
    n = int(o["--max"]); out = []
    for m in sorted(db, key=lambda m: m["posted"]):
        if len(out) >= n: break
        if m["handled"] or o["--harness"] in m["not_by"]: continue
        if m["responsible"] is None or m["locked_until"] < now:
            m.update(responsible=seat, locked_until=now + int(o["--ttl"]))
            m["responsible_gen"] += 1; m["claim_n"] += 1; m["claims"].append([now, seat]); out.append(row(m))
elif op == "renew":
    out = []
    for m in db:
        if m["responsible"] == seat and not m["handled"]:
            m["locked_until"] = now + int(o["--ttl"]); out.append({"msg_id": m["msg_id"], "responsible_gen": m["responsible_gen"]})
elif op == "check":
    m = next((m for m in db if m["msg_id"] == o["--msg"]), None)
    rc = 0 if m and m["responsible"] == seat and m["responsible_gen"] == int(o["--gen"]) and m["locked_until"] >= now else 1
elif op == "adopt":
    m = next((m for m in db if m["msg_id"] == o["--msg"]), None)
    if m is None:
        db.append({"msg_id": o["--msg"], "posted": now, "ts": str(now), "task_id": o["--msg"], "from": "local", "to": "peers",
                   "kind": "note", "body": "", "files": [], "responsible": seat, "locked_until": now + 120,
                   "responsible_gen": 1, "claim_n": 1, "handled": False, "not_by": [], "claims": [[now, seat]]})
    elif m["responsible"] is None:
        m.update(responsible=seat, locked_until=now + 120); m["responsible_gen"] += 1; m["claim_n"] += 1; m["claims"].append([now, seat])
elif op == "dump":
    out = db
else:
    rc = 2
save()
if out is not None: print(json.dumps(out))
sys.exit(rc)
EOF
printf '#!/usr/bin/env bash\nexec python3 "%s/bin/hub.py" "$@"\n' "$T" > "$T/bin/hub"
printf '#!/usr/bin/env bash\necho "$1" >> "%s/rings"\n' "$T" > "$T/bin/poke"
# the transcript clock: $T/act/<box>.<pid> holds a frozen epoch; none = it writes now
printf '#!/usr/bin/env bash\ncat "%s/act/$PEER_BOX.$1" 2>/dev/null || echo "$LEASE_NOW"\n' "$T" > "$T/bin/act"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/pane"
chmod +x "$T/bin/"*
mkdir -p "$T/act"

BOXES="sat pc"
SEATS="c-001 c-002 g-003 g-004"
declare -A OFF=([sat.c-001]=0 [sat.c-002]=1 [sat.g-003]=2 [sat.g-004]=3 [pc.c-001]=2 [pc.c-002]=3 [pc.g-003]=4 [pc.g-004]=1)

do_log() { :; }
# shellcheck source=../run/spl-peer-ensure.func.sh
source "$PROJ_ROOT/src/bash/run/spl-peer-ensure.func.sh"

# fresh: a new world - the hub, both boxes, 8 seats and their agents
fresh() {
  rm -rf "$T/hub" "$T/sat" "$T/pc" "$T/rings" "$T/act"; mkdir -p "$T/hub" "$T/act"
  local b s n=100 h
  for b in $BOXES; do
    mkdir -p "$T/$b/peer" "$T/$b/proc"
    for s in $SEATS; do
      h=claude; [[ "$s" == g-* ]] && h=grok
      echo "$s $h" >> "$T/$b/peer/seats"
      n=$((n + 1)); agent "$b" "$n" "$s" "$h"
    done
  done
}
agent() { mkdir -p "$T/$1/proc/$2"; echo "$4" > "$T/$1/proc/$2/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$3" > "$T/$1/proc/$2/environ"; }
pid_of() { grep -lzx "SPOOL_AGENT_ID=$2" "$T/$1"/proc/*/environ 2>/dev/null | sed -n 1p | xargs -r dirname | xargs -r basename; }
hubc() { HUB_DIR="$T/hub" LEASE_NOW="$((T0 + ${NOW:-0}))" python3 "$T/bin/hub.py" "$@"; }
peer_env() {
  SPOOL_ROOT="$T/$1" PEER_BOX="$1" LEASE_PROC_ROOT="$T/$1/proc" LEASE_PANE_CMD="$T/bin/pane" LEASE_ACTIVITY_CMD="$T/bin/act" \
    PEER_HUB_CMD="$T/bin/hub" PEER_POKE_CMD="$T/bin/poke" HUB_DIR="$T/hub" LEASE_NOW="$((T0 + NOW))" "${@:2}"
}
# tick <box> <seat>: one loop tick, in a subshell (each loop is its own process)
tick() {
  ( export SPOOL_ROOT="$T/$1" PEER_BOX="$1" LEASE_PROC_ROOT="$T/$1/proc" LEASE_PANE_CMD="$T/bin/pane" LEASE_ACTIVITY_CMD="$T/bin/act" \
      PEER_HUB_CMD="$T/bin/hub" PEER_POKE_CMD="$T/bin/poke" HUB_DIR="$T/hub" LEASE_NOW="$((T0 + NOW))"
    spl_peer_init && spl_peer_seated "$2" && spl_peer_tick "$2" )
}
# run <from> <to> [<box.seat>]: advance the clock second by second; every
# seat whose stagger falls on that second ticks (only <box.seat>, when given).
# A tick costs ~0.17 s (hub stub, jq), so the scenarios below tick only the
# holder, or nobody, while the lock is provably still valid: any other seat's
# poll in that window returns [] and changes nothing.
run() {
  local b s
  for ((NOW = $1; NOW <= $2; NOW++)); do
    for b in $BOXES; do for s in $SEATS; do
      [[ -n "${3:-}" && "$3" != "$b.$s" ]] && continue
      (( (NOW - OFF[$b.$s]) % 5 == 0 )) && tick "$b" "$s"
    done; done
  done
  NOW=$2
}
# field <msg> <jq expr on the row>
field() { NOW=${NOW:-0} hubc dump | jq -r --arg m "$1" ".[] | select(.msg_id == \$m) | $2"; }
inbox_count() { cat "$T"/sat/[acgq]-*/inbox/*.json "$T"/pc/[acgq]-*/inbox/*.json 2>/dev/null | jq -r 'select(.msg_id == "'"$1"'") | .to' | wc -l; }

# ---- 1. inert ----------------------------------------------------------------
mkdir -p "$T/empty"
SPOOL_ROOT="$T/empty" PEER_BOX=sat PEER_SEAT=c-001 PEER_TICKS=1 PEER_HUB_CMD="$T/bin/hub" do_spl_peer_poll; r1=$?
SPOOL_ROOT="$T/empty" PEER_BOX=sat do_spl_peer_ensure; r2=$?
if [[ $r1 == 0 && $r2 == 0 && -z "$(find "$T/empty" -mindepth 1)" ]]; then pass "1 inert: no seat = poll and ensure exit 0 and write nothing"
else fail "1 inert: rc $r1/$r2, wrote: $(find "$T/empty" -mindepth 1 | sed -n 1,3p)"; fi

# ---- 2. pickup within 5 s, exactly one responsible -----------------------------
fresh
NOW=0
worst=0 bad=""
for ((t = 0; t <= 70; t++)); do
  if (( t % 3 == 0 && t / 3 < 20 )); then NOW=$t hubc post "m$((t / 3))"; fi
  run "$t" "$t"
done
for i in $(seq 0 19); do
  d="$(field "m$i" '((.claims[0][0] // 0) - .posted)')"; n="$(field "m$i" '.claim_n')"
  (( d > worst )) && worst=$d
  [[ "$n" == 1 && "$(field "m$i" '.claims | length')" == 1 && "$(inbox_count "m$i")" == 1 && "$d" -ge 0 && "$d" -le 5 ]] || bad+=" m$i(d=$d n=$n inbox=$(inbox_count "m$i"))"
done
maxheld="$(hubc dump | jq -r '[.[] | .responsible] | group_by(.) | map(length) | max')"
if [[ -z "$bad" && "$maxheld" -le 3 ]]; then pass "2 pickup: n=20 messages, each locked once by one seat into one inbox, worst pickup ${worst}s <= 5s, max held $maxheld"
else fail "2 pickup:$bad maxheld=$maxheld"; fi
[[ -s "$T/rings" ]] && pass "2 pickup: the holder's pane is rung" || fail "2 pickup: no ring"

# ---- 3. a dead peer: <= 125 s ---------------------------------------------------
for k in 1 2 3; do
  fresh
  NOW=0 hubc post d1; run 0 6
  holder="$(field d1 .responsible)"; hb="${holder#*@}"; hs="${holder%@*}"
  kill_at=$((7 + k * 11))
  run 7 "$kill_at" "$hb.$hs"
  rm -rf "${T:?}/$hb/proc/$(pid_of "$hb" "$hs")"
  # the last renew was <= kill_at, so the lock holds until >= kill_at + 115
  until_="$(field d1 '.locked_until')"; (( until_ - T0 >= kill_at + 115 )) || fail "3 dead peer #$k: lock only until $((until_ - T0))"
  run "$((kill_at + 110))" "$((kill_at + 135))"
  moved="$(field d1 '.claims[1][0] // empty')"; who="$(field d1 '.claims[1][1] // empty')"
  if [[ -n "$moved" && "$who" != "$holder" ]] && (( moved - T0 - kill_at <= 125 && moved - T0 - kill_at > 0 )); then
    pass "3 dead peer #$k: $holder died at ${kill_at}s, $who took it $((moved - T0 - kill_at))s later (<= 125s)"
  else fail "3 dead peer #$k: holder $holder, moved '${moved:-never}' to '$who'"; fi
  grep -q "$hs idle: not able" "$T/$hb/peer/peer.log" && pass "3 dead peer #$k: logged once as not able" || fail "3 dead peer #$k: no log"
done

# ---- 4. an undetected stall: after 600 s, within 12 min ---------------------------
fresh
NOW=0 hubc post s1; run 0 6
holder="$(field s1 .responsible)"; hb="${holder#*@}"; hs="${holder%@*}"; c0="$(field s1 '.claims[0][0]')"
echo "$c0" > "$T/act/$hb.$(pid_of "$hb" "$hs")"
# the other seats find the message locked meanwhile; only the holder's ticks change anything
run 7 715 "$hb.$hs"
# the holder stopped renewing at 605 at the latest: locked until <= 725
run 716 760
moved="$(field s1 '.claims[1][0] // empty')"
if [[ -n "$moved" ]] && (( moved - c0 > 600 && moved - c0 <= 730 )); then
  pass "4 stall: transcript frozen at the claim, moved $((moved - c0))s later (600 < d <= 730, 12 min + 2 polls)"
else fail "4 stall: claim at $c0, moved '${moved:-never}'"; fi
grep -q "$hs idle: no progress" "$T/$hb/peer/peer.log" && pass "4 stall: logged as no progress" || fail "4 stall: no log"
fresh
NOW=0 hubc post s2; run 0 6
holder="$(field s2 .responsible)"; hb="${holder#*@}"; hs="${holder%@*}"
run 7 735 "$hb.$hs"; run 736 750
[[ "$(field s2 .claim_n)" == 1 && "$(field s2 .responsible)" == "$holder" ]] &&
  pass "4 control: a holder that keeps writing keeps its message past 12.5 min" || fail "4 control: moved to $(field s2 .responsible)"

# ---- 5. hub down: the local lock --------------------------------------------------
fresh
NOW=0 hubc post h1
touch "$T/hub/down.sat"
mkdir -p "$T/sat/peers/inbox"
for i in 1 2 3; do
  printf '{"v":1,"msg_id":"loc%s","task_id":"t","ts":"2027-01-15T08:00:0%sZ","from":"c-150","to":"peers","kind":"result","body":"report %s","files":[]}\n' "$i" "$i" "$i" > "$T/sat/peers/inbox/loc$i.json"
done
run 0 5 2>/dev/null
ok=1
for i in 1 2 3; do
  [[ -f "$T/sat/claims/loc$i" && "$(inbox_count "loc$i")" == 1 ]] || { ok=0; fail "5 hub down: loc$i lock '$(cat "$T/sat/claims/loc$i" 2>/dev/null)', delivered $(inbox_count "loc$i")"; }
done
(( ok )) && pass "5 hub down: n=3 local reports, each locked by exactly one sat seat within 5 s (O_EXCL), one inbox each"
[[ "$(field h1 '.responsible')" == *@pc ]] && pass "5 hub down: the hub message went to a pc seat; no sat seat touched it" ||
  fail "5 hub down: h1 is $(field h1 .responsible)"
[[ -z "$(cat "$T"/sat/*/inbox/*.json 2>/dev/null | jq -r 'select(.msg_id == "h1")')" ]] && pass "5 hub down: h1 is in no sat inbox" || fail "5 hub down: h1 delivered on sat"
# loc3 was meanwhile adopted by a pc seat on the hub: insert-if-absent keeps it
NOW=6 hubc adopt --seat c-002@pc --msg loc3
rm -f "$T/hub/down.sat"
run 6 11
ok=1
for i in 1 2; do
  [[ "$(field "loc$i" .responsible)" == "$(cut -d' ' -f1 "$T/sat/claims/loc$i.pushed" 2>/dev/null)" ]] || { ok=0; fail "5 back: loc$i is $(field "loc$i" .responsible)"; }
done
[[ "$(field loc3 .responsible)" == c-002@pc && -f "$T/sat/claims/loc3.pushed" ]] || { ok=0; fail "5 back: loc3 is $(field loc3 .responsible)"; }
(( ok )) && pass "5 hub back: each local lock pushed as responsible, insert-if-absent (loc3 stays c-002@pc)"
grep -q 'hub back: local locks pushed' "$T/sat/peer/peer.log" && pass "5 hub back: logged" || fail "5 hub back: no log"

# ---- 6. split brain: the fence ----------------------------------------------------
fresh
OFF[pc.c-001]=0  # sat c-001 polls first at 0 s
NOW=0 hubc post b1; run 0 0 sat.c-001
gen="$(field b1 .responsible_gen)"
[[ "$(field b1 .responsible)" == c-001@sat ]] || fail "6 setup: b1 is $(field b1 .responsible)"
fence() { peer_env "$1" env PEER_SEAT="$2" PEER_MSG=b1 PEER_GEN="$3" bash -c "do_log() { :; }; source '$PROJ_ROOT/src/bash/run/spl-peer-poll.func.sh'; do_spl_peer_fence"; }
NOW=1; fence sat c-001 "$gen"; r=$?
[[ $r == 0 ]] && pass "6 fence: the holder's fence passes before the cut" || fail "6 fence: rc $r before the cut"
cut=10; run 1 "$cut"; touch "$T/hub/down.sat"
# the last renew was <= cut: the lock holds until >= cut + 115
run "$((cut + 110))" "$((cut + 140))"
moved="$(field b1 '.claims[1][0] // empty')"; who="$(field b1 '.claims[1][1] // empty')"
if [[ "$who" == *@pc ]] && (( moved - T0 - cut <= 125 )); then pass "6 split brain: sat cut at ${cut}s, $who took b1 $((moved - T0 - cut))s later (<= 125s)"
else fail "6 split brain: moved '${moved:-never}' to '$who'"; fi
fence sat c-001 "$gen"; r=$?
[[ $r == 2 ]] && pass "6 fence: the cut-off holder cannot confirm (2) and stops" || fail "6 fence: cut-off rc $r"
rm -f "$T/hub/down.sat"
fence sat c-001 "$gen"; r=$?
[[ $r == 1 ]] && pass "6 fence: reconnected, the old holder's fence says lost (1)" || fail "6 fence: reconnected rc $r"
fence pc "${who%@*}" "$(field b1 .responsible_gen)"; r=$?
[[ $r == 0 ]] && pass "6 fence: the new holder's fence passes" || fail "6 fence: new holder rc $r"
grep -q 'FENCE unconfirmed b1' "$T/sat/peer/peer.log" && grep -q 'FENCE lost b1' "$T/sat/peer/peer.log" &&
  pass "6 fence: both refusals logged" || fail "6 fence: not logged"
OFF[pc.c-001]=2

# ---- 7. ensure: one loop per seat, idempotent, restarts a dead one ------------------
fresh
cat > "$T/bin/run" <<EOF
#!/usr/bin/env bash
export LEASE_PROC_ROOT="$T/sat/proc" LEASE_PANE_CMD="$T/bin/pane" LEASE_ACTIVITY_CMD="$T/bin/act" PEER_HUB_CMD="$T/bin/hub" \
  PEER_POKE_CMD="$T/bin/poke" HUB_DIR="$T/hub" LEASE_NOW="$T0" SPOOL_ROOT="$T/sat" PEER_POLL_SEC=1
do_log() { :; }
source "$PROJ_ROOT/src/bash/run/spl-peer-poll.func.sh"
do_spl_peer_poll
EOF
chmod +x "$T/bin/run"
ens() { SPOOL_ROOT="$T/sat" PEER_BOX=sat PEER_RUN="$T/bin/run" do_spl_peer_ensure; }
running() { local s n=0; for s in $SEATS; do PEER_DIR="$T/sat/peer" spl_peer_running "$s" && n=$((n + 1)); done; echo "$n"; }
wait_n() { local i; for i in $(seq 1 50); do [[ "$(running)" == "$1" ]] && return 0; sleep 0.1; done; return 1; }
ens; wait_n 4 && pass "7 ensure: 4 seats -> 4 poll loops" || fail "7 ensure: $(running) loops"
p1="$(cat "$T/sat/peer/c-001/poll.pid")"
ens; sleep 0.5
[[ "$(running)" == 4 && "$(cat "$T/sat/peer/c-001/poll.pid")" == "$p1" ]] && pass "7 ensure: idempotent (same pids)" || fail "7 ensure: not idempotent"
kill -- "-$(cat "$T/sat/peer/g-003/poll.pid")" 2>/dev/null; wait_n 3
ens; wait_n 4 && [[ "$(cat "$T/sat/peer/g-003/poll.pid")" != "" ]] && pass "7 ensure: a dead loop is restarted (the reboot path)" || fail "7 ensure: $(running) after restart"
grep -q 'g-003 poll start' "$T/sat/peer/peer.log" && pass "7 ensure: the loops log their start" || fail "7 ensure: no start log"
for s in $SEATS; do PEER_DIR="$T/sat/peer" spl_peer_stop "$s"; done
[[ "$(running)" == 0 ]] && pass "7 ensure: stop ends every loop" || fail "7 ensure: $(running) still run"

# ---- 8. a grok seat ------------------------------------------------------------------
fresh
NOW=0 hubc post g1
run 0 0 sat.g-004 2>/dev/null; run 1 3 sat.g-004
[[ "$(field g1 .responsible)" == g-004@sat ]] && pass "8 grok seat: found by its harness's process, it claims" || fail "8 grok seat: g1 is '$(field g1 .responsible)'"
rm -rf "${T:?}/sat/proc/$(pid_of sat g-003)"; agent sat 999 g-003 claude-other
( export SPOOL_ROOT="$T/sat" PEER_BOX=sat LEASE_PROC_ROOT="$T/sat/proc" LEASE_PANE_CMD="$T/bin/pane"; spl_peer_init; export PEER_HARNESS=grok; [[ -z "$(spl_peer_able g-003)" ]] ) &&
  pass "8 grok seat: an unrelated process carrying the id does not count" || fail "8 grok seat: counted a foreign process"

echo
if (( fails )); then echo "peer-poll: $fails FAILED"; exit 1; fi
echo "peer-poll: all passed"
