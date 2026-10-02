#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_measure_wui_edge_warm (perf round 4, C7) samples documents and
#          /_nuxt files on fresh edge keys, one request at a time, and its
#          cold arm reads the first-reader MISS while its warm arm reads the
#          HIT the warmer left. Uses a local mock edge (MISS +150 ms on the
#          first GET of a path+query+accept-encoding), never the real host.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/measure-wui-edge-warm.func.sh"

fails=0

require_action "$FUNC"
command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "FAIL: curl+python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/warm-wui-edge.func.sh
source "$PROJ_ROOT/src/bash/run/warm-wui-edge.func.sh"
# shellcheck source=../run/measure-wui-edge-warm.func.sh
source "$FUNC"

T=$(mktemp -d); trap 'rm -rf "$T"; jobs -p | xargs -r kill 2>/dev/null' EXIT

cat >"$T/edge.py" <<'PY'
import os, sys, time, threading, http.server
DOC = ('<html><script type="module" src="/_nuxt/entry.js"></script>'
       '<script>r({locales:["en","fi"],defaultLocale:"en"})</script></html>')
FILES = {
    "/_nuxt/entry.js": ("text/javascript", 'import("./a.js");const m=["./a.css"]'),
    "/_nuxt/a.js": ("text/javascript", "export default 1"),
    "/_nuxt/a.css": ("text/css", "a{color:red}"),
    "/_nuxt/builds/latest.json": ("application/json", '{"id":"b1"}'),
}
seen, lock = set(), threading.Lock()
times = open(sys.argv[1] + ".times", "a", buffering=1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        times.write("%.3f\n" % time.time())
        ctype, body = FILES.get(self.path.split("?")[0], ("text/html", DOC))
        key = (self.path, self.headers.get("accept-encoding", ""))
        with lock:
            hit = key in seen; seen.add(key)
        if not hit:
            time.sleep(0.15)   # the origin fetch a MISS pays
        b = body.encode()
        self.send_response(200)
        self.send_header("content-type", ctype)
        self.send_header("x-cache", "HIT" if hit else "MISS")
        self.send_header("content-length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1] + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
srv.serve_forever()
PY
python3 "$T/edge.py" "$T/port" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 600); do [[ -s "$T/port" ]] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
[[ -s "$T/port" ]] || { echo "FAIL: mock edge never listened"; exit 1; }
BASE="http://127.0.0.1:$(cat "$T/port")"
export MEASURE_WUI_URL="$BASE" MEASURE_WUI_PAUSE=0.2 MEASURE_WUI_N=3 MEASURE_WUI_DOCS=2

# --- both arms, interleaved ---------------------------------------------------
: >"$T/port.times"
out=$(MEASURE_WUI_OUT="$T/both.tsv" do_measure_wui_edge_warm 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "measure exits 0" || fail "measure rc=$rc: $out"
row() { awk -F'\t' -v a="$1" -v c="$2" -v s="$3" '$2 == a && $4 == c && $3 == s' "$T/both.tsv"; }
[[ $(row cold nuxt reader | wc -l) -eq 3 && $(row warm nuxt reader | wc -l) -eq 3 ]] \
  && pass "n: 3 /_nuxt samples per arm" || fail "nuxt samples: $(cat "$T/both.tsv")"
[[ $(row cold document reader | wc -l) -eq 2 ]] && pass "n: 2 document samples per arm" || fail "document samples"
[[ $(row cold nuxt reader | awk -F'\t' '$9 == "MISS"' | wc -l) -eq 3 ]] \
  && pass "cold arm: the first reader MISSes (a fresh key per sample)" || fail "cold arm x-cache: $(row cold nuxt reader)"
[[ $(row warm nuxt reader | awk -F'\t' '$9 == "HIT"' | wc -l) -eq 3 ]] \
  && pass "warm arm: the reader HITs what the warmer fetched" || fail "warm arm x-cache: $(row warm nuxt reader)"
grep -qE '^\| cold \| nuxt \| 3 \| (1[5-9][0-9]|[2-9][0-9][0-9]) \|' <<<"$out" \
  && grep -qE '^\| warm \| nuxt \| 3 \| [0-9]{1,2} \|' <<<"$out" \
  && pass "summary: cold median pays the origin fetch, warm does not" || fail "summary: $out"
# interleaved: per sample cold then warm, never all of one arm first
seq_arms=$(awk -F'\t' 'NR > 1 && $3 == "reader" {print substr($2,1,1)}' "$T/both.tsv" | tr -d '\n')
[[ "$seq_arms" == cwcwcwcwcw ]] && pass "arms are interleaved per path" || fail "arm order: $seq_arms"
# gentle: the 15 sampling requests (5 paths x cold, warmer, reader) are never
# closer than the pause
gap=$(python3 -c 'import sys; t=[float(l) for l in open(sys.argv[1])]; t.sort(); print(min(b-a for a,b in zip(t[-15:],t[-14:])))' "$T/port.times")
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 0.19 else 1)' "$gap" \
  && pass "sampling requests are at least MEASURE_WUI_PAUSE apart (min gap ${gap}s)" || fail "two sampling requests ${gap}s apart"

# --- one arm only (the before / after command lines) -------------------------
MEASURE_WUI_ARMS=cold MEASURE_WUI_OUT="$T/cold.tsv" do_measure_wui_edge_warm >/dev/null 2>&1
[[ $(awk -F'\t' 'NR > 1 && $2 != "cold"' "$T/cold.tsv" | wc -l) -eq 0 && $(wc -l <"$T/cold.tsv") -eq 6 ]] \
  && pass "MEASURE_WUI_ARMS=cold samples the cold arm only" || fail "cold-only: $(cat "$T/cold.tsv")"

# --- refusals ----------------------------------------------------------------
for bad in "MEASURE_WUI_PAUSE=0.1" "MEASURE_WUI_PAUSE=x" "MEASURE_WUI_ARMS=hot" "MEASURE_WUI_N=0"; do
  ( export "${bad?}"; do_measure_wui_edge_warm >/dev/null 2>&1 ) \
    && fail "$bad accepted" || pass "$bad refuses"
done

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
