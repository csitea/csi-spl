#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_warm_wui_edge (perf round 4, C7) finds every deployed document and
#          /_nuxt file, skips a stale ref the SPA fallback answers, and fetches
#          each live path exactly once per browser Accept-Encoding key, so a
#          second run finds nothing cold. Uses a local mock edge (MISS on the
#          first GET of a path+accept-encoding, HIT after), never the real host;
#          workflow 31 runs the action against dev and prd after each deploy.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/warm-wui-edge.func.sh"
WF="$APP_ROOT/.github/workflows/31_wui-edge-warm.yml"

fails=0

require_action "$FUNC"
command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "FAIL: curl+python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/warm-wui-edge.func.sh
source "$FUNC"

T=$(mktemp -d); trap 'rm -rf "$T"; jobs -p | xargs -r kill 2>/dev/null' EXIT

# The mock edge: two locales (en default, fi), an entry chunk naming a CSS file
# and a chunk, that chunk naming another one and a STALE chunk which, like
# Hosting, falls back to the HTML shell with a 200.
cat >"$T/edge.py" <<'PY'
import os, sys, http.server
DOC = ('<html><script type="module" src="/_nuxt/entry.js"></script>'
       '<script>r({locales:["en","fi"],defaultLocale:"en"})</script>'
       '<script>window.__NUXT__={config:{app:{buildId:"b1"}}};buildId:"b1"</script></html>')
FILES = {
    "/": ("text/html", DOC), "/login": ("text/html", DOC),
    "/fi": ("text/html", DOC), "/fi/login": ("text/html", DOC),
    "/_nuxt/entry.js": ("text/javascript", 'import("./a.js");const m=["./a.css"]'),
    "/_nuxt/a.js": ("text/javascript", 'import("./b.js");import("./stale.js")'),
    "/_nuxt/b.js": ("text/javascript", "export default 1"),
    "/_nuxt/a.css": ("text/css", "a{color:red}"),
    "/_nuxt/builds/latest.json": ("application/json", '{"id":"b1"}'),
    "/_nuxt/builds/meta/b1.json": ("application/json", '{"id":"b1"}'),
}
seen = set()
log = open(sys.argv[1] + ".log", "a", buffering=1)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        path = self.path.split("?")[0]
        ctype, body = FILES.get(path, ("text/html", DOC))
        key = (path, self.headers.get("accept-encoding", ""))
        hit = key in seen; seen.add(key)
        log.write("%s\t%s\n" % key)
        b = body.encode()
        self.send_response(200)
        self.send_header("content-type", ctype + "; charset=utf-8")
        # shield first, edge last, as Fastly lists them
        self.send_header("x-cache", "MISS, HIT" if hit else "MISS, MISS")
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

# --- documents come from the deployed "/" (default locale unprefixed) --------
printf '%s' '<script>r({locales:["en","fi","sv"],defaultLocale:"en"})</script>' >"$T/doc.html"
got=$(_warm_wui_edge_documents "$T/doc.html" | paste -sd' ')
[[ "$got" == "/ /login /fi /fi/login /sv /sv/login" ]] \
  && pass "documents: / and /login plus each non-default locale's copy" \
  || fail "documents: got '$got'"

# --- the crawl: every live path, the stale chunk left out --------------------
mkdir "$T/c"
got=$(_warm_wui_edge_crawl "$BASE" "$T/c" 2>"$T/crawl.err" | paste -sd' ')
want="/ /_nuxt/a.css /_nuxt/a.js /_nuxt/b.js /_nuxt/builds/latest.json /_nuxt/builds/meta/b1.json /_nuxt/entry.js /fi /fi/login /login"
[[ "$got" == "$want" ]] && pass "crawl finds the 10 live paths" || fail "crawl: got '$got'"
grep -q 'stale.js' "$T/crawl.err" \
  && pass "a /_nuxt ref answered by the HTML fallback is named as skipped" \
  || fail "the stale ref was not reported: $(cat "$T/crawl.err")"

# --- the crawl sorts in byte order whatever the caller's locale -------------
# (no locale needs installing: a sort shim records the LC_ALL it was given;
# CI sets only LANG, and en_US orders /fi before /_nuxt)
mkdir -p "$T/bin" "$T/c2"
real_sort=$(command -v sort)
printf '#!/usr/bin/env bash\necho "${LC_ALL:-unset}" >>"%s/sort.lc"\nexec %s "$@"\n' "$T" "$real_sort" >"$T/bin/sort"
chmod +x "$T/bin/sort"
( unset LC_ALL; export LANG=en_US.UTF-8 PATH="$T/bin:$PATH"; _warm_wui_edge_crawl "$BASE" "$T/c2" >/dev/null 2>&1 )
[[ -s "$T/sort.lc" && -z "$(grep -vx C "$T/sort.lc")" ]] \
  && pass "every sort in the crawl runs with LC_ALL=C when the caller set only LANG" \
  || fail "the crawl's sort saw LC_ALL: $(sort -u "$T/sort.lc" 2>/dev/null | paste -sd' ')"

# --- the warm: each live path once per browser key, then nothing is cold -----
: >"$T/port.log"
export WARM_WUI_RATE=50/s
out=$(WARM_WUI_URLS="$BASE" do_warm_wui_edge 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "warm exits 0 on a healthy host" || fail "warm rc=$rc: $out"
grep -q '10 paths x 2 encodings = 20 fetches; 20 were cold' <<<"$out" \
  && pass "first warm: 10 paths x 2 browser keys, all 20 cold" || fail "first warm summary: $out"
for enc in 'gzip, deflate, br, zstd' 'gzip, deflate, br'; do
  n=$(awk -F'\t' -v e="$enc" '$2 == e' "$T/port.log" | sort -u | wc -l)
  [[ "$n" -eq 10 ]] && pass "every live path fetched with accept-encoding '$enc'" \
    || fail "accept-encoding '$enc': $n distinct paths, want 10"
done
awk -F'\t' '$1 ~ /stale/ && ($2 == "gzip, deflate, br, zstd" || $2 == "gzip, deflate, br")' "$T/port.log" | grep . >/dev/null \
  && fail "the stale ref was warmed" || pass "the stale ref is never fetched with a browser key"
out=$(WARM_WUI_URLS="$BASE" do_warm_wui_edge 2>&1)
grep -q '20 fetches; 0 were cold' <<<"$out" && grep -q 'x-cache seen: MISS, HIT=20' <<<"$out" \
  && pass "second warm finds nothing cold: the edge (last) x-cache entry is HIT on all 20" || fail "second warm: $out"

# --- failure modes -----------------------------------------------------------
WARM_WUI_URLS="http://127.0.0.1:9" do_warm_wui_edge >/dev/null 2>&1 \
  && fail "an unreachable host warms green" || pass "an unreachable host is a red warm"
( unset ENV WARM_WUI_URLS; do_warm_wui_edge >/dev/null 2>&1 ) \
  && fail "no ENV and no WARM_WUI_URLS warms green" || pass "no ENV and no WARM_WUI_URLS refuses"
for bad in 0 3 8; do
  WARM_WUI_PARALLEL=$bad WARM_WUI_URLS="$BASE" do_warm_wui_edge >/dev/null 2>&1 \
    && fail "WARM_WUI_PARALLEL=$bad accepted" || pass "WARM_WUI_PARALLEL=$bad refuses (at most 2 workers)"
done
WARM_WUI_RATE=fast WARM_WUI_URLS="$BASE" do_warm_wui_edge >/dev/null 2>&1 \
  && fail "WARM_WUI_RATE=fast accepted" || pass "a malformed WARM_WUI_RATE refuses"

# --- the host comes from cnf env.dns.fqdn ------------------------------------
mkdir "$T/cnf"
printf '{"env":{"dns":{"fqdn":"dev.example.com"}}}' >"$T/cnf/dev.env.json"
got=$(WARM_WUI_CNF_DIR="$T/cnf" _warm_wui_edge_base_urls dev)
[[ "$got" == "https://dev.example.com" ]] && pass "base URL is https://<cnf env.dns.fqdn>" || fail "base URL: '$got'"
WARM_WUI_CNF_DIR="$T/cnf" _warm_wui_edge_base_urls qa >/dev/null 2>&1 \
  && fail "an env without cnf resolved" || pass "an env without cnf refuses"
for e in dev prd; do
  [[ -n "$(WARM_WUI_CNF_DIR="$APP_ROOT/csi-spl-cnf/csi-spl" _warm_wui_edge_base_urls "$e")" ]] \
    && pass "the real cnf names a $e host" || fail "the real cnf has no $e env.dns.fqdn"
done

# --- workflow 31: after 30, per env, through the action ----------------------
if [[ -f "$WF" ]]; then
  grep -q 'workflow_run:' "$WF" && grep -q '"30 ci-cd: spool WUI build + deploy"' "$WF" \
    && pass "31 runs on workflow_run of 30" || fail "31 is not triggered by 30's completion"
  grep -q 'do_warm_wui_edge' "$WF" && pass "31 warms through the named action" || fail "31 does not call do_warm_wui_edge"
  grep -q 'Deploy WUI to' "$WF" && grep -q 'firebase deploy --only hosting' "$WF" \
    && pass "31 warms the envs whose 30 leg ran the hosting deploy step" || fail "31 does not read 30's deploy jobs"
  # 31 matches 30 by name: a rename in 30 would silently warm nothing
  WF30="$APP_ROOT/.github/workflows/30_wui-build-deploy.yml"
  grep -q 'name: Deploy WUI to \${{ matrix.environment }}' "$WF30" && grep -q 'name: firebase deploy --only hosting' "$WF30" \
    && pass "30 still names its legs and hosting step the way 31 reads them" || fail "30 renamed a job or step 31 matches"
else
  fail "no $WF"
fi

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
