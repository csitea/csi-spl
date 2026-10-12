#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 031 OA-14 (spec 030, CLE-3435): the chat latency budget. The
#          owner's number is DELIVERED AND VISIBLE - send pressed -> the
#          message is on the agent's screen - with p50 and p95 under 0.3 s,
#          and the model's reply time reported SEPARATELY, never added to it.
#          The live figure comes from `ENV=dev ... DRY_RUN=0 ./run -a
#          do_spl_latency_probe` (latency-probe.py); this file pins, offline,
#          that the instrument computes the number the budget is judged on:
#   1. DELIVERED AND VISIBLE is t_send -> notify_visible, and its p50 / p95
#      over a fast run are inside 300 ms. CONTROL: a slow run is over it, so
#      the budget check below can fail
#   2. the reply / model leg is in NO hop: no hop ends on a reply stamp, and
#      a 14 s paste debounce (visible -> notifier returns) moves the
#      "visible -> notifier returns" row and never the budget row. CONTROL:
#      that row does see the 14 s, so the separation is measured
#   3. a run whose box stamps are missing reports n=0 for the budget row and
#      no number, so it can never read as inside the budget
#   4. with CHAT_LATENCY_RESULTS=<results.json of a live run> the budget is
#      judged on that run's singles (p50 and p95 < 300 ms, n >= 12)
# No hub, no network, no tmux: only the pure helpers of latency-probe.py run
# (importing the module would log in to a live hub through m3-e2e.py).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

PY="$PROJ_ROOT/src/bash/scripts/latency-probe.py"
[[ -r "$PY" ]] && pass "latency-probe.py ships with do_spl_latency_probe" || { fail "latency-probe.py is missing"; exit 1; }

# probe <case> [results.json]: one verdict line from the probe's own HOPS,
# pct() and table(), sliced out of the file and fed synthetic stamps.
probe() {
  python3 - "$PY" "$@" <<'EOP'
import json, sys
src = open(sys.argv[1]).read()
ns = {}
exec(compile(src[src.index("HOPS = ["):src.index("def read_trace(")], "hops", "exec"), ns)
exec(compile(src[src.index("def table("):src.index("def main(")], "table", "exec"), ns)
HOPS, table = ns["HOPS"], ns["table"]
BUDGET = "DELIVERED AND VISIBLE"
MS = 1_000_000
case = sys.argv[2]

def row(i, visible_ms, debounce_ms=40):
    t = 1_000_000_000_000 + i * 5_000 * MS
    return {"msg_id": "m%d" % i, "t_send": t, "t_ack": t + 60 * MS,
            "ws_recv": t + 80 * MS, "inbox_written": t + 82 * MS,
            "notify_start": t + 84 * MS, "notify_visible": t + visible_ms * MS,
            "notify_done": t + (visible_ms + debounce_ms) * MS}

def inside(s):
    b = s.get(BUDGET, {})
    return b.get("n", 0) > 0 and b["p50_ms"] < 300 and b["p95_ms"] < 300

if case == "hop":
    h = [x for x in HOPS if x[0] == BUDGET]
    print("ok" if len(h) == 1 and h[0][1:3] == ("t_send", "notify_visible") else "hop=%r" % h)
elif case == "fast":
    _, s = table([row(i, 90 + i * 5) for i in range(12)], "fast")
    b = s[BUDGET]
    print("ok n=%d p50=%.1f p95=%.1f" % (b["n"], b["p50_ms"], b["p95_ms"]) if inside(s) else "out %r" % b)
elif case == "slow":
    _, s = table([row(i, 280 + i * 10) for i in range(12)], "slow")
    print("rejected p95=%.1f" % s[BUDGET]["p95_ms"] if not inside(s) else "accepted %r" % s[BUDGET])
elif case == "noreply":
    stamps = {x[1] for x in HOPS} | {x[2] for x in HOPS}
    bad = sorted(st for st in stamps if "reply" in st or "model" in st)
    print("ok" if not bad else "reply stamps in a hop: %r" % bad)
elif case == "debounce":
    fast = [row(i, 100) for i in range(12)]
    slow = [row(i, 100, debounce_ms=14_000) for i in range(12)]
    _, a = table(fast, "a"); _, b = table(slow, "b")
    same = a[BUDGET] == b[BUDGET]
    seen = b["visible -> notifier returns"]["p50_ms"] >= 14_000
    print("ok" if same and seen else "budget_same=%s debounce_seen=%s" % (same, seen))
elif case == "empty":
    r = [row(i, 100) for i in range(3)]
    for x in r:
        x["notify_visible"] = 0
    _, s = table(r, "empty")
    b = s[BUDGET]
    print("ok" if b["n"] == 0 and b["p50_ms"] is None and not inside(s) else "empty=%r" % b)
elif case == "live":
    d = json.load(open(sys.argv[3]))
    b = d["results"]["singles_summary"][BUDGET]
    if b.get("n", 0) >= 12 and b["p50_ms"] < 300 and b["p95_ms"] < 300:
        print("ok n=%d p50=%.1f p95=%.1f" % (b["n"], b["p50_ms"], b["p95_ms"]))
    else:
        print("over %r" % b)
EOP
}

v="$(probe hop)"
[[ "$v" == ok ]] && pass "1. the budget row is t_send -> notify_visible: send pressed to on screen" ||
  fail "1. the budget row measures something else: $v"
v="$(probe fast)"
[[ "$v" == ok* ]] && pass "1. a fast run is inside 0.3 s on p50 AND p95 ($v)" || fail "1. a fast run: $v"
v="$(probe slow)"
[[ "$v" == rejected* ]] && pass "1. CONTROL a slow run is over the budget and rejected ($v)" ||
  fail "1. CONTROL the budget check accepted a slow run: $v"
v="$(probe noreply)"
[[ "$v" == ok ]] && pass "2. no hop starts or ends on a reply/model stamp: the reply is never in a delivery number" ||
  fail "2. $v"
v="$(probe debounce)"
[[ "$v" == ok ]] && pass "2. a 14 s wait after visible moves only its own row, never the budget row (CONTROL: that row sees it)" ||
  fail "2. $v"
v="$(probe empty)"
[[ "$v" == ok ]] && pass "3. a run with no visible stamps reports n=0 and no number, never a pass" ||
  fail "3. $v"

if [[ -n "${CHAT_LATENCY_RESULTS:-}" ]]; then
  v="$(probe live "$CHAT_LATENCY_RESULTS" 2>&1)"
  [[ "$v" == ok* ]] && pass "4. the live run $CHAT_LATENCY_RESULTS is inside 0.3 s ($v)" ||
    fail "4. the live run $CHAT_LATENCY_RESULTS: $v"
else
  echo "INFO: 4. no CHAT_LATENCY_RESULTS: the live budget (OA-14) was not judged by this run"
fi

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
