#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_latency_probe (CLE-3435) - the action that prices each hop of
#          a WUI chat message - validates its ids, stays offline in a dry run,
#          and refuses rather than reporting blanks when the live sidecar is
#          not carrying a trace. No cloud call, no tmux, no spool binary.
#   1. it validates the tenant / box / agent triple the same way the desk
#      actions do. CONTROL: the good triple passes
#   2. the dry run makes no gcloud, curl, docker or spool call, and says what
#      it would do. CONTROL: the stub log records one when a call IS made
#   3. spl_lat_sidecar_traces refuses a desk whose live sidecar carries no
#      SPOOL_TRACE, or the WRONG one, and names the restart that fixes it.
#      This is the defect the check exists for: a running process's environment
#      cannot be changed, so a probe that "just measured anyway" would print a
#      table of blank hops and read as a successful measurement
#   4. …and it truncates the trace file when the sidecar DOES carry it, so one
#      run's stamps are never joined with the previous run's
#   5. latency-probe.py's percentile is the one the report prints: it must not
#      report a p95 that is merely the maximum of a short sample
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl docker cloud-sql-proxy spool tmux; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. the id rules ---------------------------------------------------------------
SNIPPET='spl_desk_validate t1 box-desk CLE-00' in_orc >/dev/null 2>&1 &&
  pass "a good tenant/box/agent triple passes" || fail "the good triple was refused"
for row in "the-reserved-box:t1:box-wui:CLE-00" "the-BOX-agent-prefix:t1:box-desk:BOX-1" \
           "a-lower-case-agent:t1:box-desk:cle-00"; do
  IFS=: read -r desc tenant box agent <<<"$row"
  if SNIPPET="spl_desk_validate '$tenant' '$box' '$agent'" in_orc >"$T/o" 2>&1; then
    fail "the probe would accept $desc"
  else
    pass "the probe refuses $desc"
  fi
done

# --- 2. the dry run is offline -----------------------------------------------------
: >"$T/calls.log"
SNIPPET='do_spl_latency_probe' in_orc TENANT_ID=t1 LAT_AGENT=CLE-00 >"$T/o" 2>&1
grep -q 'DRY_RUN' "$T/o" && pass "the dry run says what it would do" ||
  fail "the dry run said nothing: $(cat "$T/o")"
if [ -s "$T/calls.log" ]; then
  fail "the dry run made a real call: $(cat "$T/calls.log")"
else
  pass "the dry run made no gcloud/curl/docker/spool call"
fi
# CONTROL: the stubs DO record, so the empty log above means something.
: >"$T/calls.log"
STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" curl -s https://example.invalid >/dev/null 2>&1
[ -s "$T/calls.log" ] && pass "CONTROL: a real call would have been recorded" ||
  fail "CONTROL: the stub log never records, so the offline check proves nothing"

# --- 3/4. the sidecar must actually be tracing -------------------------------------
d="$T/desk"; mkdir -p "$d/spool/.hub"
trace="$d/spool/.hub/latency-trace.ndjson"
# A pid that is alive but is not a `spool hub-run`: spl_desk_alive must reject
# it, which is what stops the probe measuring some unrelated process.
sleep 300 & other=$!
printf '%s\n' "$other" >"$d/spool/.hub/hub-run.pid"
SNIPPET="spl_lat_sidecar_traces '$d' '$trace'" in_orc >"$T/o" 2>&1 &&
  fail "it accepted a pid that is not a hub-run sidecar" ||
  pass "it refuses a pid that is not a hub-run sidecar"
kill "$other" 2>/dev/null

# A live sidecar with no SPOOL_TRACE at all.
SNIPPET="spl_desk_alive() { return 0; }
         spl_lat_proc_trace() { printf ''; }
         spl_lat_sidecar_traces '$d' '$trace'" in_orc >"$T/o" 2>&1 &&
  fail "it measured a sidecar with no SPOOL_TRACE" ||
  pass "it refuses a sidecar with no SPOOL_TRACE"
grep -q 'do_spl_desk_up' "$T/o" &&
  pass "…and names the restart that fixes it" ||
  fail "…but did not say how to fix it: $(cat "$T/o")"

# A live sidecar tracing SOMEWHERE ELSE is exactly as unmeasurable, and is the
# likelier mistake: a second probe run against a desk left up by the first.
SNIPPET="spl_desk_alive() { return 0; }
         spl_lat_proc_trace() { printf '/somewhere/else'; }
         spl_lat_sidecar_traces '$d' '$trace'" in_orc >"$T/o" 2>&1 &&
  fail "it measured a sidecar tracing to another file" ||
  pass "it refuses a sidecar tracing to another file"
grep -q '/somewhere/else' "$T/o" &&
  pass "…and says where that sidecar is actually tracing" ||
  fail "…but did not name the wrong target: $(cat "$T/o")"

# The trace file is truncated when the sidecar IS the right one, so this run's
# stamps can never be joined with the previous run's.
printf '{"stage":"ws_recv","msg_id":"stale"}\n' >"$trace"
SNIPPET="spl_desk_alive() { return 0; }
         spl_lat_proc_trace() { printf '%s' '$trace'; }
         spl_lat_sidecar_traces '$d' '$trace'" in_orc >"$T/o" 2>&1 &&
  pass "it accepts a sidecar that traces to the right file" ||
  fail "it refused the right sidecar: $(cat "$T/o")"
if [ -s "$trace" ]; then
  fail "a stale trace survived into the new run: $(cat "$trace")"
else
  pass "the trace is truncated before a run, so stale stamps cannot join it"
fi

# --- 5. the percentile is a percentile ---------------------------------------------
py="$PROJ_ROOT/src/bash/scripts/latency-probe.py"
[ -r "$py" ] && pass "latency-probe.py ships with the action" || fail "latency-probe.py is missing"
got="$(python3 - "$py" <<'EOP'
import sys
# Only the pure helper is under test: importing the module would run
# m3-e2e.py, which wants a live hub.
src = open(sys.argv[1]).read()
ns = {}
exec(compile(src[src.index("def pct("):src.index("def read_trace(")], "pct", "exec"), ns)
pct = ns["pct"]
xs = list(range(1, 101))
p50, p95 = pct(xs, 50), pct(xs, 95)
# A p95 must INTERPOLATE, not fall back to the maximum: a run of 12 samples
# would otherwise report its slowest send as "p95" and read far worse than it
# is. And it must be safe on the two shapes a short run really produces.
print("interp" if 94.0 < p95 < 96.0 and p95 != max(xs) else "p95=%r" % p95,
      "median" if p50 == 50.5 else "p50=%r" % p50,
      "empty" if pct([], 50) is None else "empty=%r" % pct([], 50),
      "single" if pct([7], 95) == 7 else "single=%r" % pct([7], 95))
EOP
)" || got="ERR"
case "$got" in
  "interp median empty single") pass "pct interpolates, and is safe on an empty and a single sample" ;;
  *) fail "pct is not a percentile: got '$got'" ;;
esac

echo "---- $(basename "$0"): $fails failed"
[ "$fails" -eq 0 ]
