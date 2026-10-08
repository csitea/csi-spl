#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_peer_poll / do_spl_peer_ensure / do_spl_peer_fence on spec
#          093's two-phase claim (sections 4 and 5.3, task T010; spec 101
#          T014), plus 068's hub-down local lock and the fence. No live agent
#          and no hub is touched: 8 simulated ODs on 2 boxes (sat, pc: c-001
#          c-002 g-003 g-004 each, a fake /proc per box) poll a hub STUB that
#          implements the round contract of 4.2 (T1 open, T1j join, T2 accept,
#          T3 lapse, T4 anchor renew, T5 expiry, T6 park, T7b reoffer, T10
#          dead) with OFFER_K 2, BUSY_DELAY 8 s, OFFER_WINDOW 20 s on a fake
#          clock (LEASE_NOW). Each seat ticks every 5 s at its own second, as
#          the staggered loops do; each simulated agent writes its
#          heartbeat.json (spec 5.2) and accepts the stubs in its inbox.
#   1. inert: no seats file = poll and ensure write nothing
#   2. rounds: n=20 jobs, each in a first round within 5 s, accepted once;
#      a stub reaches at most OFFER_K seats and only the round's seats; the
#      loser's stub is archived "taken"; control: a hub answer that does not
#      name the seat writes no stub
#   3. FR-001: a holder whose progress stops loses its job at anchor + 120 s
#      and the job is in a new round within 125 s of the last progress
#      (n=20, 2 runs of 10); the lock is exactly anchor + 120 (FR-002);
#      control: a holder that keeps progressing keeps its job
#   4. FR-005: an idle seat opens a round before a busy one (n=5); control:
#      busy seats only -> the round opens >= BUSY_DELAY after the post
#   5. FR-006: parked jobs of a holder that is not able are in a new round
#      within 125 s, parked_until still ahead (n=5); control: an able idle
#      holder keeps its parked jobs for the whole park (n=5); T7b: the wait
#      token answering re-offers the job to its holder alone; control: an
#      unrelated message does not
#   6. FR-008: a lapsed stub, a taken stub and a dead job's stub are each
#      archived within one tick; an idle seat is rung only for a new stub
#   7. hub down: local-origin messages are locked locally by exactly one
#      seat within 5 s, hub messages are not touched; back up, each local
#      lock is pushed insert-if-absent
#   8. split brain: the cut-off box's job moves to the other box within
#      125 s; the cut-off holder's fence says "unconfirmed" (2) while cut and
#      "lost" (1) after, the new holder's says 0
#   9. ensure starts one loop per seat, is idempotent, restarts a dead one
#  10. a grok seat (no claude process) is found by its harness's process
#  11. spec 110 grammar: an m-004 (mistral) seat line is read and its fence
#      is asked; control: an x-004 line is skipped and its fence refused
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
import fcntl, json, os, sys, time
st = os.environ["HUB_DIR"]; now = int(os.environ["LEASE_NOW"])
a = sys.argv[1:]
if a and a[0] == "claim": a = a[1:]
VAL = ("--accept", "--park", "--reoffer", "--unpark", "--touch")
op, o, i = None, {}, 0
while i < len(a):
    k = a[i]
    if k in ("--poll", "--renew", "--check", "--adopt"): op = k[2:]; i += 1
    elif k in VAL: op = k[2:]; o["--msg"] = a[i + 1]; i += 2
    elif k.startswith("--"): o[k] = a[i + 1]; i += 2
    else: op = op or k; o.setdefault("args", []).append(k); i += 1
seat = o.get("--seat", "")
if seat and os.path.exists(os.path.join(st, "down." + seat.split("@")[1])): sys.exit(75)
lk = open(os.path.join(st, "lock"), "w"); fcntl.flock(lk, fcntl.LOCK_EX)
p = os.path.join(st, "db.json")
db = json.load(open(p)) if os.path.exists(p) else []
def save(): json.dump(db, open(p, "w"))
def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else ""
def kind(s): return s[0]
OFFER_WINDOW, OFFER_K, OFFER_MAX, BUSY, HARNESS, FRESH, IDLE_MAX, CLAIM_MAX = 20, 2, 6, 8, 5, 120, 900, 4
def row(m, body=False):
    r = {"msg_id": m["msg_id"], "responsible_gen": m["gen"], "claim_state": m["state"], "task_id": m["task_id"],
         "ts": iso(m["posted"]), "from": m["from"], "to": m["to"], "kind": m["kind"], "claim_n": m["claim_n"],
         "round": m["offer_n"], "offer_set": m["offer_set"], "offer_until": iso(m["offer_until"]),
         "touched_at": iso(m["touched_at"]), "wait_token": m["wait_token"], "parked_until": iso(m["parked_until"])}
    if m["responsible"]: r["responsible"] = m["responsible"]
    if body: r["body"] = m["body"]
    return r
def settle(m):
    if m["state"] in ("owned", "parked") and m["locked_until"] < now:
        # T5: claim_n stays, wait_token goes to the next owner; free since the lock ran out
        m.update(state="free", responsible=None, freed=m["locked_until"], parked_was=m["parked_until"], parked_until=0)
    if m["state"] == "offered" and m["offer_until"] < now:
        m["lapsed"] = m["lapsed"] + [s for s in m["offer_set"] if s not in m["lapsed"]]
        m.update(state="free", offer_set=[], freed=m["offer_until"])
    if m["state"] == "free" and (m["offer_n"] >= OFFER_MAX or m["claim_n"] >= CLAIM_MAX):
        m.update(state="done", handled="dead")
        return True
    return False
def hold(m, s, g, *states):
    return m["state"] in states and m["responsible"] == s and m["gen"] == g
def find(mid): return next((m for m in db if m["msg_id"] == mid), None)
rc = 0; out = None
if op == "post":
    mid = o["args"][1]
    db.append({"msg_id": mid, "posted": now, "task_id": "t-" + mid, "from": "HUM-1", "to": "peers", "kind": "msg",
               "body": "hello " + mid, "state": "free", "offer_set": [], "offer_n": 0, "offer_until": 0, "lapsed": [],
               "responsible": None, "locked_until": 0, "gen": 0, "claim_n": 0, "touched_at": 0, "parked_until": 0,
               "wait_token": "", "handled": None, "freed": now, "rounds": [], "claims": [], "dead_told": False})
elif op == "poll":
    busy = o["--state"] == "busy"; mx = int(o["--max"]); box = seat.split("@")[1]
    ready = [seat] + [r if "@" in r else r + "@" + box for r in o.get("--ready", "").split(",") if r]
    out = []
    for m in sorted(db, key=lambda m: m["posted"]):
        if m["handled"] and m["dead_told"]: continue
        if m["handled"] is None and settle(m) or m["handled"] == "dead" and not m["dead_told"]:
            m["dead_told"] = True; r = row(m, True); r["dead"] = True; out.append(r); continue
        if m["handled"] or len([x for x in out if not x.get("dead")]) >= mx: continue
        if os.environ.get("HUB_LIE") and m["state"] == "offered":
            out.append(row(m)); continue
        if m["state"] == "offered" and seat in m["offer_set"]:
            out.append(row(m)); continue
        if m["state"] == "free":
            if busy and now < m["freed"] + BUSY: continue
            if seat in m["lapsed"]:
                if any(r not in m["lapsed"] for r in ready): continue
                m["lapsed"] = []
            m.update(state="offered", offer_set=[seat], offer_until=now + OFFER_WINDOW)
            m["offer_n"] += 1; m["rounds"].append([now, m["offer_n"], [seat]]); out.append(row(m))
        elif m["state"] == "offered":
            if len(m["offer_set"]) >= OFFER_K or seat in m["offer_set"] or seat in m["lapsed"]: continue
            wait = BUSY if busy else 0
            if any(kind(s) == kind(seat) for s in m["offer_set"]): wait = max(wait, HARNESS)
            if now < m["offer_until"] - OFFER_WINDOW + wait: continue
            m["offer_set"] = m["offer_set"] + [seat]; m["rounds"][-1][2].append(seat); out.append(row(m))
elif op == "accept":
    m = find(o["--msg"])
    if m and m["handled"] is None: settle(m)
    if m and m["state"] == "offered" and seat in m["offer_set"] and m["offer_n"] == int(o["--round"]) and m["offer_until"] >= now:
        m.update(state="owned", responsible=seat, locked_until=now + FRESH, offer_set=[], lapsed=[], touched_at=now)
        m["gen"] += 1; m["claim_n"] += 1; m["claims"].append([now, seat]); out = [row(m, True)]
    else: rc = 1
elif op == "renew":
    hb = o.get("--hb", ""); age = int(o.get("--anchor-age", "0"))
    out = []
    for m in db:
        if m["responsible"] != seat or m["handled"]: continue
        settle(m)
        if m["responsible"] != seat: continue
        if m["state"] == "owned" and hb == "fresh" and m["touched_at"] >= now - IDLE_MAX:
            m["locked_until"] = now - age + FRESH
        elif m["state"] == "parked" and hb in ("fresh", "able") and now < m["parked_until"]:
            m["locked_until"] = now + FRESH
        out.append(row(m))
elif op == "park":
    m = find(o["--msg"])
    if m and hold(m, seat, int(o["--gen"]), "owned", "parked"):
        m.update(state="parked", parked_until=now + int(o["--until"]), wait_token=o["--wait"], touched_at=now)
    else: rc = 1
elif op == "reoffer":
    m = find(o["--msg"])
    if m and hold(m, seat, int(o["--gen"]), "parked"):
        m.update(state="offered", offer_set=[seat], offer_until=now + OFFER_WINDOW, responsible=None, locked_until=0,
                 parked_until=0, wait_token="", touched_at=now)
        m["offer_n"] += 1; m["rounds"].append([now, m["offer_n"], [seat]])
    else: rc = 1
elif op == "check":
    m = find(o["--msg"])
    rc = 0 if m and m["handled"] is None and m["state"] in ("owned", "parked") and m["responsible"] == seat \
        and m["gen"] == int(o["--gen"]) and m["locked_until"] >= now else 1
elif op == "adopt":
    m = find(o["--msg"])
    if m is None:
        db.append({"msg_id": o["--msg"], "posted": now, "task_id": o["--msg"], "from": "local", "to": "peers", "kind": "note",
                   "body": "", "state": "owned", "offer_set": [], "offer_n": 0, "offer_until": 0, "lapsed": [],
                   "responsible": seat, "locked_until": now + FRESH, "gen": 1, "claim_n": 1, "touched_at": now,
                   "parked_until": 0, "wait_token": "", "handled": None, "freed": now, "rounds": [], "claims": [[now, seat]],
                   "dead_told": False})
    elif m["state"] == "free":
        m.update(state="owned", responsible=seat, locked_until=now + FRESH, touched_at=now)
        m["gen"] += 1; m["claim_n"] += 1; m["claims"].append([now, seat])
elif op == "set":
    m = find(o["args"][1]); m.update(json.loads(o["args"][2]))
elif op == "dump":
    out = db
else:
    rc = 2
save()
if out is not None: print(json.dumps(out))
sys.exit(rc)
EOF
printf '#!/usr/bin/env bash\nexec python3 "%s/bin/hub.py" "$@"\n' "$T" > "$T/bin/hub"
printf '#!/usr/bin/env bash\necho "$1 $LEASE_NOW" >> "%s/rings"\n' "$T" > "$T/bin/poke"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/pane"
chmod +x "$T/bin/"*

BOXES="sat pc"
SEATS="c-001 c-002 g-003 g-004"
declare -A OFF=([sat.c-001]=0 [sat.c-002]=1 [sat.g-003]=2 [sat.g-004]=3 [pc.c-001]=2 [pc.c-002]=3 [pc.g-003]=4 [pc.g-004]=1)
declare -A OFF0
for k in "${!OFF[@]}"; do OFF0[$k]=${OFF[$k]}; done

do_log() { :; }
# shellcheck source=../run/spl-peer-ensure.func.sh
source "$PROJ_ROOT/src/bash/run/spl-peer-ensure.func.sh"

# fresh: a new world - the hub, both boxes, 8 seats and their agents (idle,
# accepting), every seat ticking (TICKERS: "<box>.<seat> ..." limits that)
fresh() {
  rm -rf "$T/hub" "$T/sat" "$T/pc" "$T/rings"; mkdir -p "$T/hub"
  local b s n=100 h k
  for k in "${!OFF0[@]}"; do OFF[$k]=${OFF0[$k]}; done
  TICKERS=""
  for b in $BOXES; do
    mkdir -p "$T/$b/peer" "$T/$b/proc"
    for s in $SEATS; do
      h=claude; [[ "$s" == g-* ]] && h=grok
      echo "$s $h" >> "$T/$b/peer/seats"
      n=$((n + 1)); agent "$b" "$n" "$s" "$h"
      mode "$b" "$s" "idle:$T0"; accepts "$b" "$s" yes
      TICKERS+=" $b.$s"
    done
  done
}
agent() { mkdir -p "$T/$1/proc/$2"; echo "$4" > "$T/$1/proc/$2/comm"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$3" > "$T/$1/proc/$2/environ"; }
pid_of() { grep -lzx "SPOOL_AGENT_ID=$2" "$T/$1"/proc/*/environ 2>/dev/null | sed -n 1p | xargs -r dirname | xargs -r basename; }
kill_agent() { rm -rf "${T:?}/$1/proc/$(pid_of "$1" "$2")"; }
# the simulated agent: mode = idle:<since> | working | frozen:<last progress> | error; accepts = yes | no
mode() { mkdir -p "$T/$1/agent/$2"; echo "$3" > "$T/$1/agent/$2/mode"; }
accepts() { mkdir -p "$T/$1/agent/$2"; echo "$3" > "$T/$1/agent/$2/accepts"; }
iso() { date -u -d "@$1" +%FT%TZ; }
# beat <box> <seat>: the heartbeat.json its hooks would have written by now
beat() {
  local m st=working p=$((T0 + NOW)) err=null
  m="$(cat "$T/$1/agent/$2/mode")"
  case "$m" in
    idle:*) st=idle p="${m#idle:}" ;;
    frozen:*) p="${m#frozen:}" ;;
    error) st=idle err='"Login expired · Please run /login"' ;;
  esac
  mkdir -p "$T/$1/$2"
  printf '{"v":1,"id":"%s","state":"%s","progress_ts":"%s","tool":null,"tool_since":null,"api_error":%s}\n' "$2" "$st" "$(iso "$p")" "$err" > "$T/$1/$2/heartbeat.json"
}
hubc() { HUB_DIR="$T/hub" LEASE_NOW="$((T0 + ${NOW:-0}))" python3 "$T/bin/hub.py" "$@"; }
# act <box> <seat>: the agent accepts every stub in its inbox it has not tried
act() {
  local b="$1" s="$2" f mid n a
  compgen -G "$T/$b/$s/inbox/*-r[0-9]*.json" >/dev/null || return 0
  read -r a < "$T/$b/agent/$s/accepts"
  [[ "$a" == yes && -n "$(pid_of "$b" "$s")" ]] || return 0
  for f in "$T/$b/$s"/inbox/*-r[0-9]*.json; do
    [[ -f "$f" ]] || continue
    read -r mid n < <(jq -r '"\(.msg_id) \(.round)"' "$f")
    mkdir -p "$T/$b/agent/$s/tried"
    ( set -o noclobber; : > "$T/$b/agent/$s/tried/$mid.$n" ) 2>/dev/null || continue
    # it accepts, answers at once and is back at its prompt
    hubc --accept "$mid" --round "$n" --seat "$s@$b" >/dev/null && mode "$b" "$s" "idle:$((T0 + NOW))"
  done
}
# tick <box> <seat>: its heartbeat, then one loop tick in a subshell (each loop is its own process)
tick() {
  beat "$1" "$2"
  ( export SPOOL_ROOT="$T/$1" PEER_BOX="$1" LEASE_PROC_ROOT="$T/$1/proc" LEASE_PANE_CMD="$T/bin/pane" \
      PEER_HUB_CMD="$T/bin/hub" PEER_POKE_CMD="$T/bin/poke" HUB_DIR="$T/hub" LEASE_NOW="$((T0 + NOW))"
    spl_peer_init && spl_peer_seated "$2" && spl_peer_tick "$2" )
}
# run <from> <to>: advance the clock second by second; each seat of TICKERS
# whose stagger falls on that second ticks, then every agent acts on its stubs.
# A tick costs ~0.2 s (hub stub, jq): a scenario ticks only the seats it
# needs, and skips the stretches where every lock is provably still valid.
run() {
  local bs
  for ((NOW = $1; NOW <= $2; NOW++)); do
    for bs in $TICKERS; do (( (NOW - OFF[$bs]) % 5 == 0 )) && tick "${bs%.*}" "${bs#*.}"; done
    for bs in $TICKERS; do act "${bs%.*}" "${bs#*.}"; done
  done
  NOW=$2
}
# field <msg> <jq expr on the hub row>
field() { NOW=${NOW:-0} hubc dump | jq -r --arg m "$1" ".[] | select(.msg_id == \$m) | $2"; }
# every stub of <msg> written anywhere (inbox or archive): "<seat>@<box> <round> <lost>"
stubs_of() {
  local b
  for b in $BOXES; do
    cat "$T/$b"/[acgmq]-*/inbox/*-r[0-9]*.json "$T/$b"/[acgmq]-*/archive/*-r[0-9]*.json 2>/dev/null |
      jq -r --arg m "$1" --arg b "$b" 'select(.msg_id == $m) | "\(.to)@\($b) \(.round) \(.lost // (if .accepted then "accepted" else "open" end))"'
  done
}

# ---- 1. inert ----------------------------------------------------------------
mkdir -p "$T/empty"
SPOOL_ROOT="$T/empty" PEER_BOX=sat PEER_SEAT=c-001 PEER_TICKS=1 PEER_HUB_CMD="$T/bin/hub" do_spl_peer_poll; r1=$?
SPOOL_ROOT="$T/empty" PEER_BOX=sat do_spl_peer_ensure; r2=$?
if [[ $r1 == 0 && $r2 == 0 && -z "$(find "$T/empty" -mindepth 1)" ]]; then pass "1 inert: no seat = poll and ensure exit 0 and write nothing"
else fail "1 inert: rc $r1/$r2, wrote: $(find "$T/empty" -mindepth 1 | sed -n 1,3p)"; fi

# ---- 2. rounds: pickup, OFFER_K, the round's seats only -----------------------
fresh
for ((t = 0; t <= 72; t++)); do
  (( t % 3 == 0 && t / 3 < 20 )) && NOW=$t hubc post "m$((t / 3))"
  run "$t" "$t"
done
bad="" worst=0 maxk=0 losers=0 lost_ok=0
for i in $(seq 0 19); do
  d="$(field "m$i" '((.rounds[0][0] // 0) - .posted)')"; n="$(field "m$i" '.claim_n')"
  (( d > worst )) && worst=$d
  [[ "$n" == 1 && "$d" -ge 0 && "$d" -le 5 ]] || bad+=" m$i(open=${d}s accepts=$n)"
  # each stub's seat was in that round's offer_set on the hub; at most OFFER_K per round
  while read -r who r why; do
    grep -qx "$who" <<<"$(field "m$i" ".rounds[] | select(.[1] == $r) | .[2][]")" || bad+=" m$i:stub-to-$who-not-in-round-$r"
    [[ "$why" == taken ]] && lost_ok=$((lost_ok + 1))
    [[ "$who" != "$(field "m$i" .responsible)" ]] && losers=$((losers + 1))
  done < <(stubs_of "m$i")
  k="$(stubs_of "m$i" | awk '{print $2}' | sort | uniq -c | awk '{print $1}' | sort -n | tail -1)"
  (( k > maxk )) && maxk=$k
done
maxheld="$(hubc dump | jq -r '[.[] | select(.state == "owned") | .responsible] | group_by(.) | map(length) | max')"
if [[ -z "$bad" && "$maxk" -le 2 && "$maxheld" -le 3 ]]; then
  pass "2 rounds: n=20 jobs, each in a round within ${worst}s (<= 5s) and accepted once; at most $maxk stubs per round (OFFER_K 2), each to a seat of that round; max owned $maxheld"
else fail "2 rounds:$bad maxk=$maxk maxheld=$maxheld"; fi
[[ "$losers" -gt 0 && "$lost_ok" == "$losers" ]] && pass "2 rounds: every losing seat's stub (n=$losers) archived as taken" ||
  fail "2 rounds: $losers losing stubs, $lost_ok archived taken"
[[ -s "$T/rings" ]] && pass "2 rounds: an idle seat's pane is rung for its stub" || fail "2 rounds: no ring"
# control: a hub whose answer names rounds this seat is not in
fresh; TICKERS="sat.c-001 sat.g-003"; accepts sat c-001 no; accepts sat g-003 no
NOW=0 hubc post x1; run 0 2
[[ "$(field x1 '.offer_set | join(",")')" == c-001@sat,g-003@sat ]] || fail "2 control setup: x1 offer_set $(field x1 '.offer_set')"
NOW=2 HUB_LIE=1 tick pc c-001
[[ -z "$(stubs_of x1 | grep '@pc')" ]] && grep -q 'NOT-OFFERED x1' "$T/pc/peer/peer.log" &&
  pass "2 control: a round that does not name the seat writes no stub (logged NOT-OFFERED)" || fail "2 control: $(stubs_of x1)"

# ---- 3. FR-001: progress stops -> new round within 125 s (n=20) ----------------
fr001() {  # <run> <holder box> <taker box>: 12 jobs on the holder box's 4 seats, then every holder's progress stops
  local run_n="$1" hb="$2" tb="$3" s i k=0 n=500 P=45 lo hi prog moved first
  fresh
  for s in $SEATS; do kill_agent "$tb" "$s"; done
  TICKERS="$hb.c-001 $hb.c-002 $hb.g-003 $hb.g-004"
  for i in $(seq 0 11); do NOW=$((i * 2)) hubc post "f$run_n-$i"; run $((i * 2)) $((i * 2 + 1)); done
  run 24 "$P"
  declare -gA PROG=()
  for s in $SEATS; do PROG[$s]=$((T0 + P - 2 * k)); k=$((k + 1)); mode "$hb" "$s" "frozen:${PROG[$s]}"; done
  for s in $SEATS; do n=$((n + 1)); agent "$tb" "$n" "$s" "$([[ $s == g-* ]] && echo grok || echo claude)"; mode "$tb" "$s" "idle:$((T0 + P))"; done
  lo=$((P - 6)); hi=$((P + 125))
  # one tick each sets every lock to its anchor + 120 (a later fresh renew writes the same); nothing moves
  # before the earliest anchor + 120, so the clock jumps there
  run $((P + 1)) $((P + 5))
  TICKERS+=" $tb.c-001 $tb.c-002 $tb.g-003 $tb.g-004"
  run $((lo + 111)) "$hi"
  for i in $(seq 0 11); do
    m="f$run_n-$i"; first="$(field "$m" '.claims[0][1] // empty')"; s="${first%@*}"
    prog="${PROG[$s]:-0}"; moved="$(field "$m" '.rounds[1][0] // empty')"
    if [[ -n "$first" && -n "$moved" ]] && (( moved - prog > 120 && moved - prog <= 125 )) && [[ "$(field "$m" '.claims[1][1]')" == *@"$tb" ]]; then
      N001=$((N001 + 1)); (( moved - prog > W001 )) && W001=$((moved - prog))
    else fail "3 FR-001: $m holder '$first' progress $((prog - T0)), new round '${moved:-never}', then $(field "$m" '.claims[1][1] // "nobody"')"; fi
  done
  return 0
}
N001=0 W001=0
# FR-002 and the control: c-001 holds a1 and stops at 7 s; c-002 holds a2 and keeps working
fresh; TICKERS="sat.c-001"
NOW=0 hubc post a1; run 0 1; accepts sat c-001 no; mode sat c-001 working
TICKERS="sat.c-001 sat.c-002"; NOW=2 hubc post a2; run 2 7
mode sat c-001 "frozen:$((T0 + 7))"; mode sat c-002 working
TICKERS+=" pc.c-001"; run 8 30
[[ "$(field a1 .locked_until)" == $((T0 + 7 + 120)) ]] && pass "3 FR-002: the renew writes anchor + 120 s (progress at 7 s -> locked until 127 s), never now + 120" ||
  fail "3 FR-002: locked until $(( $(field a1 .locked_until) - T0 ))"
run 31 140
moved="$(field a1 '.rounds[1][0] // 0')"
(( moved - T0 - 7 > 120 && moved - T0 - 7 <= 125 )) || fail "3 FR-001: a1 new round at $((moved - T0))"
[[ "$(field a2 '.claim_n')" == 1 && "$(field a2 .responsible)" == c-002@sat && "$(field a2 .state)" == owned ]] &&
  pass "3 FR-001 control: a holder that keeps working keeps its job past 140 s (a1 beside it moved at $((moved - T0 - 7))s)" ||
  fail "3 FR-001 control: a2 $(field a2 '.state + " " + (.responsible // "-")')"
fr001 1 sat pc
fr001 2 pc sat
(( N001 >= 20 )) && pass "3 FR-001: n=$N001 jobs whose holder's progress stopped were in a new round on the other box within ${W001}s (120 < d <= 125s) of the last progress" ||
  fail "3 FR-001: only $N001 of 24 moved in time"

# ---- 4. FR-005: idle first ------------------------------------------------------
fresh
n5=0
for k in 1 2 3 4 5; do
  # sat c-001 is busy and polls first (second 0); sat c-002 is idle and polls at second 1
  rm -f "$T/hub/db.json"; TICKERS="sat.c-001 sat.c-002"; accepts sat c-001 no; accepts sat c-002 no
  mode sat c-001 working; mode sat c-002 "idle:$T0"
  base=$((k * 100)); NOW=$base hubc post "i$k"
  run "$base" $((base + 6))
  [[ "$(field "i$k" '.rounds[0][2][0]')" == c-002@sat ]] && n5=$((n5 + 1)) || fail "4 FR-005 #$k: first offered to $(field "i$k" '.rounds[0][2]')"
done
(( n5 == 5 )) && pass "4 FR-005: n=5 jobs, the idle seat opened each round although the busy one polled first"
rm -f "$T/hub/db.json"; mode sat c-002 working
NOW=1000 hubc post i9; run 1000 1015
d="$(field i9 '(.rounds[0][0] // 0) - .posted')"
(( d >= 8 && d <= 13 )) && pass "4 FR-005 control: busy seats only -> the round opened ${d}s after the post (>= BUSY_DELAY 8s)" || fail "4 control: opened ${d}s after"

# ---- 5. FR-006: parks -------------------------------------------------------------
park_setup() {  # 5 jobs owned by sat c-001 (3) and sat c-002 (2), each parked for <1> s on <2>
  fresh; TICKERS="sat.c-001"
  local i
  for i in 1 2 3; do NOW=$i hubc post "p$i"; done; run 1 6
  TICKERS="sat.c-002"
  for i in 4 5; do NOW=$((6 + i)) hubc post "p$i"; done; run 7 16
  TICKERS="sat.c-001 sat.c-002"
  for i in 1 2 3 4 5; do
    NOW=17 hubc --park "p$i" --seat "$(field "p$i" .responsible)" --gen "$(field "p$i" .gen)" --until "$1" --wait "$2" ||
      fail "5 setup: p$i is $(field "p$i" '.state + " " + (.responsible // "-")')"
  done
}
park_setup 1800 c-150
# both holders lose their session (a dead login, a bare shell): not able, no renew
kill_agent sat c-001; kill_agent sat c-002; D=20
TICKERS="sat.c-001 sat.c-002 sat.g-003 pc.c-001"
run 18 "$D"; run $((D + 110)) $((D + 130))
ok=0
for i in 1 2 3 4 5; do
  moved="$(field "p$i" '.rounds[-1][0] // empty')"; pu="$(field "p$i" '.parked_was // 0')"
  [[ "$(field "p$i" '.rounds | length')" -ge 2 ]] && (( moved - T0 - D <= 125 && pu > moved )) && ok=$((ok + 1)) || fail "5 FR-006: p$i rounds $(field "p$i" '.rounds')"
done
(( ok == 5 )) && pass "5 FR-006: n=5 parked jobs of holders that are not able were in a new round within 125 s, the park (1800 s) still ahead"
park_setup 300 c-150
mode sat c-001 "idle:$((T0 + 17))"; mode sat c-002 "idle:$((T0 + 17))"
# the holders' own renew settles their rows first: a lock that ran out would show here as free
run 18 310
ok=0
for i in 1 2 3 4 5; do [[ "$(field "p$i" '.state + .responsible')" == parked"$(field "p$i" '.claims[0][1]')" && "$(field "p$i" .claim_n)" == 1 ]] && ok=$((ok + 1)); done
(( ok == 5 )) && pass "5 FR-006 control: n=5 parked jobs of able idle holders (no progress for 290 s) stayed parked for the whole 300 s park" ||
  fail "5 FR-006 control: $ok of 5 still parked"
# T7b: the lane the job waits on reports; control: another lane does not wake it
park_setup 1800 c-150
mkdir -p "$T/sat/c-001/inbox"
printf '{"v":1,"msg_id":"r-151","task_id":"t-x","ts":"2027-01-15T08:00:00Z","from":"c-151@sat","to":"c-001","kind":"result","body":"other","files":[]}\n' > "$T/sat/c-001/inbox/r151.json"
accepts sat c-001 yes; mode sat c-001 working
run 18 23
[[ "$(field p1 .state)" == parked && "$(field p1 '.rounds | length')" == 1 ]] && pass "5 T7b control: a report from another lane leaves the job parked" || fail "5 T7b control: p1 $(field p1 .state)"
printf '{"v":1,"msg_id":"r-150","task_id":"t-y","ts":"2027-01-15T08:00:01Z","from":"c-150@sat","to":"c-001","kind":"result","body":"done","files":[]}\n' > "$T/sat/c-001/inbox/r150.json"
run 24 30
if [[ "$(field p1 '.rounds[-1][2] | join(",")')" == c-001@sat && "$(field p1 '.state + .responsible')" == ownedc-001@sat && "$(field p1 .gen)" == 2 ]] &&
   grep -q 'REOFFER p1' "$T/sat/peer/peer.log"; then
  pass "5 T7b: the waited-on lane reported -> a round for the holder alone, accepted again at gen 2"
else fail "5 T7b: p1 $(field p1 '{state, responsible, gen, rounds}' | tr -d '\n ')"; fi

# ---- 6. FR-008: stubs archived within one tick, rung only for new ones --------------
fresh; TICKERS="sat.c-001 sat.g-003"; accepts sat c-001 no; accepts sat g-003 no
NOW=0 hubc post l1; run 0 2
[[ "$(field l1 '.offer_set | join(",")')" == c-001@sat,g-003@sat ]] || fail "6 setup: l1 offered to $(field l1 .offer_set)"
# taken: g-003 accepts; c-001's next tick archives its stub
NOW=3 hubc --accept l1 --round 1 --seat g-003@sat >/dev/null; run 3 5
[[ "$(stubs_of l1 | grep c-001@sat | awk '{print $3}')" == taken ]] && pass "6 FR-008: a stub won by another seat archived as taken on the next tick" ||
  fail "6 FR-008 taken: $(stubs_of l1)"
# lapsed: nobody accepts l2 in its 20 s window; archived on the first tick after it
TICKERS="sat.c-001"
NOW=10 hubc post l2; run 10 10
r0="$(grep -c '^c-001 ' "$T/rings" 2>/dev/null)"
until_="$(field l2 '.offer_until')"; run 11 $((until_ - T0 + 5))
lapsed="$(stubs_of l2 | awk '$1 == "c-001@sat" && $2 == 1 {print $3}')"
[[ "$lapsed" == lapsed ]] && pass "6 FR-008: a stub whose round lapsed archived as lapsed by the first tick after its window" || fail "6 FR-008 lapsed: $(stubs_of l2)"
r1="$(grep -c '^c-001 ' "$T/rings")"; nstub="$(stubs_of l2 | awk '$1 == "c-001@sat"' | wc -l)"
(( r1 - r0 >= 1 && r1 - r0 == nstub - 1 )) && pass "6 FR-008: the idle seat was rung only for its new stubs ($((r1 - r0)) rings, $((nstub - 1)) new round(s)), never for the stale one" ||
  fail "6 FR-008 rings: $((r1 - r0)) rings for $nstub stubs"
# done: the job goes dead (OFFER_MAX rounds) while c-001 holds its stub
NOW=50 hubc post l3; TICKERS="sat.c-001"; run 50 55
NOW=56 hubc set l3 '{"offer_n": 6}'
NOW=56 hubc set l3 "{\"offer_until\": $((T0 + 56))}"; run 57 62
[[ "$(stubs_of l3 | awk '$1 == "c-001@sat" {print $3}')" == "done" ]] && [[ -n "$(cat "$T"/sat/c-001/inbox/*.json | jq -r 'select(.msg_id == "l3" and .round == null) | .body' | grep '^DEAD')" ]] &&
  pass "6 FR-008: a dead job's stub archived as done; the DEAD note delivered once" || fail "6 FR-008 done: $(stubs_of l3)"

# ---- 7. hub down: the local lock --------------------------------------------------
fresh
NOW=0 hubc post h1
touch "$T/hub/down.sat"
mkdir -p "$T/sat/peers/inbox"
for i in 1 2 3; do
  printf '{"v":1,"msg_id":"loc%s","task_id":"t","ts":"2027-01-15T08:00:0%sZ","from":"c-150","to":"peers","kind":"result","body":"report %s","files":[]}\n' "$i" "$i" "$i" > "$T/sat/peers/inbox/loc$i.json"
done
run 0 5 2>/dev/null
ok=1
inbox_count() { cat "$T"/sat/[acgmq]-*/inbox/*.json "$T"/pc/[acgmq]-*/inbox/*.json 2>/dev/null | jq -r 'select(.msg_id == "'"$1"'" and .round == null) | .to' | wc -l; }
for i in 1 2 3; do
  [[ -f "$T/sat/claims/loc$i" && "$(inbox_count "loc$i")" == 1 ]] || { ok=0; fail "7 hub down: loc$i lock '$(cat "$T/sat/claims/loc$i" 2>/dev/null)', delivered $(inbox_count "loc$i")"; }
done
(( ok )) && pass "7 hub down: n=3 local reports, each locked by exactly one sat seat within 5 s (O_EXCL), one inbox each"
[[ -z "$(field h1 '.rounds[][2][]' | grep '@sat')" && "$(field h1 .responsible)" == *@pc ]] && pass "7 hub down: the hub job went only to pc seats' rounds and a pc seat accepted it" ||
  fail "7 hub down: h1 rounds $(field h1 .rounds), responsible $(field h1 .responsible)"
NOW=6 hubc --adopt --seat c-002@pc --msg loc3
rm -f "$T/hub/down.sat"
run 6 11
ok=1
for i in 1 2; do
  [[ "$(field "loc$i" .responsible)" == "$(cut -d' ' -f1 "$T/sat/claims/loc$i.pushed" 2>/dev/null)" ]] || { ok=0; fail "7 back: loc$i is $(field "loc$i" .responsible)"; }
done
[[ "$(field loc3 .responsible)" == c-002@pc && -f "$T/sat/claims/loc3.pushed" ]] || { ok=0; fail "7 back: loc3 is $(field loc3 .responsible)"; }
(( ok )) && pass "7 hub back: each local lock pushed as responsible, insert-if-absent (loc3 stays c-002@pc)"
grep -q 'hub back: local locks pushed' "$T/sat/peer/peer.log" && pass "7 hub back: logged" || fail "7 hub back: no log"

# ---- 8. split brain: the fence ----------------------------------------------------
fresh; TICKERS="sat.c-001"
NOW=0 hubc post b1; run 0 1
gen="$(field b1 .gen)"
[[ "$(field b1 .responsible)" == c-001@sat ]] || fail "8 setup: b1 is $(field b1 .responsible)"
fence() {
  ( export SPOOL_ROOT="$T/$1" PEER_BOX="$1" PEER_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" LEASE_NOW="$((T0 + NOW))" PEER_SEAT="$2" PEER_MSG=b1 PEER_GEN="$3"
    do_spl_peer_fence )
}
NOW=1; fence sat c-001 "$gen"; r=$?
[[ $r == 0 ]] && pass "8 fence: the holder's fence passes before the cut" || fail "8 fence: rc $r before the cut"
cut=10; run 2 "$cut"; touch "$T/hub/down.sat"
TICKERS="sat.c-001 pc.c-001 pc.c-002 pc.g-003 pc.g-004"
run $((cut + 110)) $((cut + 140))
moved="$(field b1 '.rounds[1][0] // empty')"; who="$(field b1 '.claims[1][1] // empty')"
if [[ "$who" == *@pc ]] && (( moved - T0 - cut <= 125 )); then pass "8 split brain: sat cut at ${cut}s, b1 in a pc round $((moved - T0 - cut))s later (<= 125s), $who accepted"
else fail "8 split brain: new round '${moved:-never}', accepted by '$who'"; fi
fence sat c-001 "$gen"; r=$?
[[ $r == 2 ]] && pass "8 fence: the cut-off holder cannot confirm (2) and stops" || fail "8 fence: cut-off rc $r"
rm -f "$T/hub/down.sat"
fence sat c-001 "$gen"; r=$?
[[ $r == 1 ]] && pass "8 fence: reconnected, the old holder's fence says lost (1)" || fail "8 fence: reconnected rc $r"
fence pc "${who%@*}" "$(field b1 .gen)"; r=$?
[[ $r == 0 ]] && pass "8 fence: the new holder's fence passes" || fail "8 fence: new holder rc $r"
grep -q 'FENCE unconfirmed b1' "$T/sat/peer/peer.log" && grep -q 'FENCE lost b1' "$T/sat/peer/peer.log" &&
  pass "8 fence: both refusals logged" || fail "8 fence: not logged"

# ---- 9. ensure: one loop per seat, idempotent, restarts a dead one ------------------
fresh
cat > "$T/bin/run" <<EOF
#!/usr/bin/env bash
export LEASE_PROC_ROOT="$T/sat/proc" LEASE_PANE_CMD="$T/bin/pane" PEER_HUB_CMD="$T/bin/hub" \
  PEER_POKE_CMD="$T/bin/poke" HUB_DIR="$T/hub" LEASE_NOW="$T0" SPOOL_ROOT="$T/sat" PEER_POLL_SEC=1
do_log() { :; }
source "$PROJ_ROOT/src/bash/run/spl-peer-poll.func.sh"
do_spl_peer_poll
EOF
chmod +x "$T/bin/run"
ens() { SPOOL_ROOT="$T/sat" PEER_BOX=sat PEER_RUN="$T/bin/run" do_spl_peer_ensure; }
running() { local s n=0; for s in $SEATS; do PEER_DIR="$T/sat/peer" spl_peer_running "$s" && n=$((n + 1)); done; echo "$n"; }
wait_n() { local i; for i in $(seq 1 50); do [[ "$(running)" == "$1" ]] && return 0; sleep 0.1; done; return 1; }
ens; wait_n 4 && pass "9 ensure: 4 seats -> 4 poll loops" || fail "9 ensure: $(running) loops"
p1="$(cat "$T/sat/peer/c-001/poll.pid")"
ens; sleep 0.5
[[ "$(running)" == 4 && "$(cat "$T/sat/peer/c-001/poll.pid")" == "$p1" ]] && pass "9 ensure: idempotent (same pids)" || fail "9 ensure: not idempotent"
kill -- "-$(cat "$T/sat/peer/g-003/poll.pid")" 2>/dev/null; wait_n 3
ens; wait_n 4 && [[ "$(cat "$T/sat/peer/g-003/poll.pid")" != "" ]] && pass "9 ensure: a dead loop is restarted (the reboot path)" || fail "9 ensure: $(running) after restart"
grep -q 'g-003 poll start' "$T/sat/peer/peer.log" && pass "9 ensure: the loops log their start" || fail "9 ensure: no start log"
for s in $SEATS; do PEER_DIR="$T/sat/peer" spl_peer_stop "$s"; done
[[ "$(running)" == 0 ]] && pass "9 ensure: stop ends every loop" || fail "9 ensure: $(running) still run"

# ---- 10. a grok seat ------------------------------------------------------------------
fresh; TICKERS="sat.g-004"
NOW=0 hubc post g1
run 0 3 2>/dev/null
[[ "$(field g1 .responsible)" == g-004@sat ]] && pass "10 grok seat: found by its harness's process, offered the round, it accepts" || fail "10 grok seat: g1 is '$(field g1 .responsible)'"
kill_agent sat g-003; agent sat 999 g-003 claude-other
( export SPOOL_ROOT="$T/sat" PEER_BOX=sat LEASE_PROC_ROOT="$T/sat/proc" LEASE_PANE_CMD="$T/bin/pane"; spl_peer_init; export PEER_HARNESS=grok; [[ -z "$(spl_peer_able g-003)" ]] ) &&
  pass "10 grok seat: an unrelated process carrying the id does not count" || fail "10 grok seat: counted a foreign process"

# ---- 11. spec 110: the mistral letter ----------------------------------------------
mkdir -p "$T/m/peer"; printf 'm-004 vibe\nx-004 vibe\n' > "$T/m/peer/seats"
got="$(SPOOL_ROOT="$T/m" PEER_BOX=sat; spl_peer_init ro; spl_peer_seats)"
[[ "$got" == "m-004 vibe" ]] && pass "11 an m-004 seat line is read; control: x-004 is skipped" || fail "11 seats read: '$got'"
mfence() { ( export SPOOL_ROOT="$T/m" PEER_BOX=sat PEER_HUB_CMD="$T/bin/hub" PEER_SEAT="$1" PEER_MSG=f1 PEER_GEN=1; do_log() { echo "$*"; }; do_spl_peer_fence ) 2>&1; }
o4="$(mfence m-004)"; ox="$(mfence x-004)"; rx=$?
[[ "$o4" != *"PEER_SEAT, PEER_MSG and PEER_GEN are required"* && $rx == 2 && "$ox" == *"PEER_SEAT, PEER_MSG and PEER_GEN are required"* ]] &&
  pass "11 the fence takes PEER_SEAT=m-004; control: x-004 is refused (2)" || fail "11 fence: m='$o4' x(rc $rx)='$ox'"

echo
if (( fails )); then echo "peer-poll: $fails FAILED"; exit 1; fi
echo "peer-poll: all passed"
