#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_file_streams_measure (spec 160 row B7, case C24) stays
#          offline in its dry run, refuses bad input, and builds frames the
#          hub takes, with no cloud call.
#   1. dry run of the fill: no spool / gcloud / curl call; names the lines,
#      the streams, the box and the tenant
#   2. refusals: ENV=prd, MEASURE_LINES / STREAMS / RATE / N out of range,
#      an unknown step, box-wui, a bad tenant
#   3. DRY_RUN=0 without a pinned probe box stops before any spool call and
#      names do_spl_box_msg_probe
#   4. the frames: the announce first with every key; then pushes of at most
#      1000 lines and 448 KiB, seq strictly increasing per key across frames,
#      at most MEASURE_RATE lines per key and minute, every line one line of
#      at most 2048 bytes, b7needle in one line of 1000
#   5. time: the execution ms of each EXPLAIN run (a stubbed
#      do_spl_db_query) give n, min, median and max; a run with no
#      Execution Time FAILS the step
#   6. CONTROL: the stub log records a call when one is made
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker spool

# --- 1. dry run ------------------------------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_file_streams_measure in_orc TENANT_ID=spool MEASURE_STEPS=fill 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "DRY_RUN nothing was touched" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "dry run: no call" \
  || fail "dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"
grep -q "push 500000 lines in 8 streams b7-measure-<n> from box-orc-probe to https://[^ ]* as tenant spool, 1000 lines" <<<"$out" \
  && pass "dry run names 500000 lines, 8 streams, the box and tenant spool" || fail "dry run text: $out"

# --- 2. refusals -------------------------------------------------------------------------
for bad in "ENV=prd" "MEASURE_LINES=999" "MEASURE_LINES=500001" "MEASURE_STREAMS=9" "MEASURE_RATE=1201" \
  "MEASURE_N=4" "MEASURE_STEPS=fill,drop" "PROBE_BOX=box-wui" "TENANT_ID=Sp"; do
  if SNIPPET=do_spl_file_streams_measure in_orc TENANT_ID=spool MEASURE_STEPS=fill "$bad" >"$T/o" 2>&1; then
    fail "accepts $bad"
  else
    pass "refuses $bad"
  fi
done

# --- 3. unpinned box: stops before spool ---------------------------------------------------
: >"$T/calls.log"
out=$(SNIPPET=do_spl_file_streams_measure in_orc TENANT_ID=spool MEASURE_STEPS=fill DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "do_spl_box_msg_probe first" <<<"$out" && [[ ! -s "$T/calls.log" ]] && pass "unpinned: refused, no spool call" \
  || fail "unpinned: rc=$rc calls=$(cat "$T/calls.log") out=$out"

# --- 4. the frames -------------------------------------------------------------------------
SNIPPET='spl_fsm_frames 20000 3 700' in_orc >"$T/frames" 2>&1
out=$(python3 - "$T/frames" <<'EOF_PY'
import json, sys
from collections import Counter
fr = [json.loads(l) for l in open(sys.argv[1])]
bad = []
a = fr[0]
if a.get("lane_op") != "file_streams_announce" or [s["stream_key"] for s in a["streams"]] != ["b7-measure-1", "b7-measure-2", "b7-measure-3"]:
    bad.append("announce")
last, per, n = {}, Counter(), 0
for f in fr[1:]:
    if f.get("lane_op") != "file_streams_push" or not 0 < len(f["lines"]) <= 1000 or len(json.dumps(f)) > 448 << 10:
        bad.append("push shape")
    for l in f["lines"]:
        k = f["stream_key"]
        if l["seq"] <= last.get(k, 0) or len(l["text"].encode()) > 2048 or "\n" in l["text"] or not l["at"].endswith("Z"):
            bad.append("line %s %d" % (k, l["seq"]))
        last[k] = l["seq"]
        per[(k, l["at"][:16])] += 1
        n += 1
needle = sum("b7needle" in l["text"] for f in fr[1:] for l in f["lines"])
print("lines=%d max_per_minute=%d needle=%d bad=%s" % (n, max(per.values()), needle, ",".join(bad[:3]) or "none"))
EOF_PY
)
[[ "$out" == "lines=19998 max_per_minute=700 needle=21 bad=none" ]] && pass "frames: announce, 3 x 6666 lines, <= 700 a minute, seq order, needle 1 in 1000" \
  || fail "frames: $out"

# --- 5. time: the parse and its failure ------------------------------------------------------
fake='do_spl_db_query() { case "$SQL" in *b7needle*) echo "\"Execution Time\": 40.5";; *tick*) echo "\"Execution Time\": 3.2";; *) echo "\"Execution Time\": 150.0";; esac; }'
out=$(SNIPPET="$fake; spl_fsm_time spool - - - - 5" in_orc 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "time b7absentword  n=5 ms=150,150,150,150,150 min=150 median=150 max=150" <<<"$out" \
  && grep -q "time b7needle .*n=5 .*median=40 " <<<"$out" && grep -q "time tick .*n=5 .*median=3 " <<<"$out" \
  && pass "time: n=5 per word, min / median / max" || fail "time: rc=$rc $out"
out=$(SNIPPET='do_spl_db_query() { echo "ERROR: canceled"; return 1; }; spl_fsm_time spool - - - - 5' in_orc 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "FAIL time: no Execution Time for 'b7absentword' run 1" <<<"$out" && pass "time: no Execution Time FAILS" \
  || fail "time without Execution Time: rc=$rc $out"

# --- 6. CONTROL --------------------------------------------------------------------------
SNIPPET='spool version' in_orc >/dev/null 2>&1
grep -q '^spool version' "$T/calls.log" && pass "CONTROL: stub records calls" || fail "CONTROL: stub recorded nothing"

(( fails == 0 )) && echo "OK file-streams-measure: all checks passed" || { echo "file-streams-measure: $fails failure(s)"; exit 1; }
