#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_report_ci_axes prints spec 133's eight CI axes (X1..X8) for one
#          window from one command (fix F0). Hermetic: `gh` is stubbed with
#          canned API JSON, and the stub runs the action's OWN --jq filter
#          over it with real jq, so a broken filter fails here too. Every
#          expected number below is worked out by hand from the fixture.
#   1. X1 push to verdict: a schedule run is not a push; a push answered by a
#      verdict created AFTER the window end still counts (r8 -> r6, 390 min)
#   2. X2 red minutes per day and X3 verdicts green, from verdict order
#   3. X4 / X6 seat A's critical path: classify + nuxt generate (when the last
#      job is an e2e shard) + the last job + gate health; X5 job-minutes
#   4. X7 a job whose p90 wall is 93 % of its timeout-minutes is AT RISK, one
#      at 53 % is not; a matrix name takes its job's timeout
#   5. X8 seat B's first reds: a job annotated `gate fail-fast: stopped` is
#      left out, a timeout annotation is a red row, and the guard counts the
#      run whose only red is a lost runner
#   6. API cost: jobs are read only for verdict runs inside the window (not
#      the superseded r2, not r6 after the window), annotations only for the
#      failed / cancelled jobs of failure runs; a second run reads the cache
#      and makes 0 job and 0 annotation calls
#   CONTROLS -- the report cannot be silently wrong or empty:
#     a. no run in the window            -> refused (non-zero)
#     b. gh itself fails                 -> refused (non-zero)
#     c. a malformed CI_AXES_SINCE       -> refused before any call
#     d. RED CONTROL for 5: with the annotations hidden the stopped jobs count
#        and the lost runner reads as a code red, so X8 and the guard change
#     e. RED CONTROL for 6: the first run against an empty cache DOES call
#        the API, so check 6's zero is the cache, not a dead fetch
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/report-ci-axes.func.sh"
GATE_FUNC="$PROJ_ROOT/src/bash/run/report-ci-gate.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }
[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it: src/bash/run/$(basename "$FUNC")" \
  || { echo "FAIL: no $FUNC"; exit 1; }

mkdir -p "$T/stub" "$T/api"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
# canned API JSON + the CALLER's own --jq filter through real jq (gh prints
# one compact JSON value per line, as jq -c does)
[[ "${GH_STUB_BROKEN:-0}" == 1 ]] && { echo "gh: stub failure" >&2; exit 1; }
args=("$@"); jqf=""; path=""
for ((i = 1; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqf="${args[i+1]}"; i=$((i + 1)) ;;
    -*) ;;
    *) [[ -z "$path" ]] && path="${args[i]}" ;;
  esac
done
echo "$path" >>"$GH_STUB_DIR/calls.log"
case "$path" in
  */workflows/*/runs*) src="$GH_STUB_DIR/runs.json" ;;
  */runs/*/jobs*) src="$GH_STUB_DIR/jobs-$(sed 's|.*/runs/\([0-9]*\)/jobs.*|\1|' <<<"$path").json" ;;
  */check-runs/*/annotations)
    src="$GH_STUB_DIR/ann-$(sed 's|.*/check-runs/\([0-9]*\)/annotations|\1|' <<<"$path").json"
    [[ -f "$src" && "${GH_STUB_NO_ANNOTATIONS:-0}" != 1 ]] || src="$GH_STUB_DIR/ann-none.json" ;;
  *) src="" ;;
esac
[[ -f "$src" ]] || { echo "gh: stub has no canned $src for $path" >&2; exit 1; }
if [[ -n "$jqf" ]]; then jq -c "$jqf" "$src"; else cat "$src"; fi
STUB
chmod +x "$T/stub/gh"

# Window 2026-01-02T00:00:00Z .. 12:00:00Z. r2 is a superseded pending push,
# r4 and r7 are hourly schedule runs, r5 and r8 still run, r6 lands after the
# window and answers r8's push.
cat >"$T/api/runs.json" <<'JSON'
{"workflow_runs":[
 {"id":8,"event":"push","status":"in_progress","conclusion":null,"created_at":"2026-01-02T07:00:00Z","updated_at":"2026-01-02T07:00:00Z","run_started_at":"2026-01-02T07:00:00Z","head_sha":"8888888888aa"},
 {"id":6,"event":"push","status":"completed","conclusion":"success","created_at":"2026-01-02T13:00:00Z","updated_at":"2026-01-02T13:30:00Z","run_started_at":"2026-01-02T13:00:00Z","head_sha":"6666666666aa"},
 {"id":7,"event":"schedule","status":"completed","conclusion":"failure","created_at":"2026-01-02T06:00:00Z","updated_at":"2026-01-02T06:30:00Z","run_started_at":"2026-01-02T06:00:00Z","head_sha":"7777777777aa"},
 {"id":5,"event":"push","status":"in_progress","conclusion":null,"created_at":"2026-01-02T05:00:00Z","updated_at":"2026-01-02T05:00:00Z","run_started_at":"2026-01-02T05:00:00Z","head_sha":"5555555555aa"},
 {"id":4,"event":"schedule","status":"completed","conclusion":"failure","created_at":"2026-01-02T03:00:00Z","updated_at":"2026-01-02T04:00:00Z","run_started_at":"2026-01-02T03:00:00Z","head_sha":"4444444444aa"},
 {"id":3,"event":"push","status":"completed","conclusion":"success","created_at":"2026-01-02T02:10:00Z","updated_at":"2026-01-02T03:10:00Z","run_started_at":"2026-01-02T02:10:00Z","head_sha":"3333333333aa"},
 {"id":2,"event":"push","status":"completed","conclusion":"cancelled","created_at":"2026-01-02T01:30:00Z","updated_at":"2026-01-02T02:05:00Z","run_started_at":"2026-01-02T01:30:00Z","head_sha":"2222222222aa"},
 {"id":1,"event":"push","status":"completed","conclusion":"failure","created_at":"2026-01-02T01:00:00Z","updated_at":"2026-01-02T02:00:00Z","run_started_at":"2026-01-02T01:00:00Z","head_sha":"1111111111aa"}
]}
JSON
# job <id> <name> <conclusion> <created HH:MM> <started> <completed> (on 2026-01-02)
job() { printf '{"id":%s,"name":"%s","conclusion":"%s","created_at":"2026-01-02T%s:00Z","started_at":"2026-01-02T%s:00Z","completed_at":"2026-01-02T%s:00Z","runner_name":"r"}' "$@"; }
# r1: hub broke it; e2e 1/2 and orc hermetic 1/2 were stopped by fail-fast.
# Critical path: classify 1 + generate 6 + e2e 20 + gate health 1 = 28 min run,
# queue 0 + 0 + 8 + 1 = 9. Job-minutes 1 + 16 + 20 + 20 + 6 + 1 = 64.
{ printf '{"jobs":['
  job 11 "classify: doc-only push?" success 01:01 01:01 01:02; printf ','
  job 12 "hub: go test" failure 01:02 01:04 01:20; printf ','
  job 13 "wui: browser e2e (mock) 1/2" failure 01:02 01:10 01:30; printf ','
  job 14 "orc: hermetic 1/2" failure 01:02 01:05 01:25; printf ','
  job 15 "wui: nuxt generate (mock)" success 01:02 01:02 01:08; printf ','
  job 16 "gate health" success 01:30 01:31 01:32
  printf ']}\n'; } >"$T/api/jobs-1.json"
# r3: green. Critical: classify 1 + orc feature tests 28 + gate health 1 = 30.
{ printf '{"jobs":['
  job 31 "classify: doc-only push?" success 02:11 02:11 02:12; printf ','
  job 32 "orc: feature tests" success 02:12 02:12 02:40; printf ','
  job 33 "gate health" success 02:40 02:40 02:41
  printf ']}\n'; } >"$T/api/jobs-3.json"
# r4: e2e 2/2 timed out (GitHub: cancelled + annotation), generate failed.
# Critical: classify 1 + generate 5 + e2e 45 = 51; job-minutes 51.
{ printf '{"jobs":['
  job 41 "classify: doc-only push?" success 03:01 03:01 03:02; printf ','
  job 42 "wui: browser e2e (mock) 2/2" cancelled 03:02 03:02 03:47; printf ','
  job 43 "wui: nuxt generate (mock)" failure 03:02 03:02 03:07
  printf ']}\n'; } >"$T/api/jobs-4.json"
# r7: its only red is a lost runner. Critical: iac 19 run, 1 queue.
{ printf '{"jobs":['
  job 71 "iac: suite" failure 06:00 06:01 06:20
  printf ']}\n'; } >"$T/api/jobs-7.json"
echo '[]' >"$T/api/ann-none.json"
echo '[{"message":"Process completed with exit code 1."}]' >"$T/api/ann-12.json"
echo '[{"message":"gate fail-fast: stopped, so the next gate run starts; red in this run: hub: go test"}]' >"$T/api/ann-13.json"
echo '[{"message":"gate fail-fast: stopped, so the next gate run starts; red in this run: hub: go test"}]' >"$T/api/ann-14.json"
echo '[{"message":"The job has exceeded the maximum execution time of 1h0m0s"}]' >"$T/api/ann-42.json"
echo '[{"message":"The self-hosted runner: r lost communication with the server."}]' >"$T/api/ann-71.json"

cat >"$T/wf.yml" <<'YML'
jobs:
  hub-suite:
    name: "hub: go test"
    timeout-minutes: 30
  wui-e2e:
    name: "wui: browser e2e (mock) ${{ matrix.shard }}/2"
    timeout-minutes: 60
  orc-features:
    name: "orc: feature tests"
    timeout-minutes: 30
YML

# run_axes <cache dir> [ENV=val ...] -> stdout+stderr in $out, rc in $rc
run_axes() {
  local cache="$1"; shift
  out=$(cd "$T" && env PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" \
        CI_AXES_SINCE=2026-01-02T00:00:00Z CI_AXES_UNTIL=2026-01-02T12:00:00Z \
        CI_AXES_CACHE="$cache" CI_AXES_WORKFLOW_FILE="$T/wf.yml" "$@" bash -c '
    do_log() { echo "$*"; }
    source "'"$GATE_FUNC"'"
    source "'"$FUNC"'"
    do_report_ci_axes' 2>&1)
  rc=$?
}
has() { grep -qF -- "$1" <<<"$out" && pass "$2" || { fail "$2 -- want '$1' in:"; sed 's/^/      /' <<<"$out"; }; }

: >"$T/api/calls.log"
run_axes "$T/cache1"
[[ $rc -eq 0 ]] && pass "the report exits 0" || fail "exit $rc"

# --- 1. X1 ---------------------------------------------------------------------
# pushes r1 60, r2 100, r3 60, r5 -> r7 90, r8 -> r6 390 (after the window):
# sorted 60 60 90 100 390, p50 90.0, p90 100 + 0.6 * 290 = 274.0
has "X1 push to verdict      p50 90.0 / p90 274.0 min (n=5 pushes, 0 with no verdict yet)" \
    "1. X1: schedule runs are not pushes; a verdict after the window still answers a push"
# --- 2. X2, X3 -----------------------------------------------------------------
# verdicts r1 F 02:00, r3 S 03:10, r4 F 04:00, r7 F 06:30; red 70 + 150 + 330 =
# 550 of 600 min from the first verdict to the end -> 1320 min/day, 92 %
has "X2 red minutes per day  1320 min/day = 92% of 10.0 h (n=4 verdicts)" "2. X2 red minutes per day"
has "X3 verdicts green       25% (1 of 4)" "2. X3 verdicts green"
# --- 3. X4, X5, X6 -------------------------------------------------------------
has "X4 critical-path run    p50 29.0 min (n=4 completed runs with jobs)" "3. X4 seat A's critical path (19 28 30 51)"
has "X5 job-minutes per run  median 40.5 (n=4)" "3. X5 job-minutes (19 30 51 64)"
has "X6 queue on the path    p90 6.6 min (n=4)" "3. X6 queue on the path (0 0 1 9)"
# --- 4. X7 ---------------------------------------------------------------------
has "X7 jobs at timeout risk 1 of 3 (orc: feature tests 93%)" "4. X7: 93 % is AT RISK, 53 % and the matrix e2e name are not"
# --- 5. X8 + guard -------------------------------------------------------------
# first-red rows: hub (r1), e2e timeout + generate (r4), iac lost (r7) = 4;
# no local gate: e2e + generate = 2
has "X8 reds with no local gate 50% (2 of 4 first-red rows, 3 of 3 failure runs read)" \
    "5. X8: fail-fast stops left out, a timeout is a red row"
has "guard: red verdicts whose first reds are all timeout / runner-lost: 1 of 3" "5. guard: the lost-runner run"
# --- 6. API cost ---------------------------------------------------------------
jobs_calls=$(grep -c '/jobs' "$T/api/calls.log"); ann_calls=$(grep -c '/annotations' "$T/api/calls.log")
[[ $jobs_calls -eq 4 && $ann_calls -eq 6 ]] \
  && pass "6. first run: 4 job calls (r1 r3 r4 r7 only) and 6 annotation calls (red jobs of failure runs) -- CONTROL e" \
  || fail "6. first run made $jobs_calls job / $ann_calls annotation call(s), want 4 / 6: $(tr '\n' ' ' <"$T/api/calls.log")"
grep -qE 'runs/(2|6|5|8)/jobs' "$T/api/calls.log" && fail "6. jobs read for a superseded, running or out-of-window run" \
  || pass "6. no jobs read for r2 (superseded), r5 / r8 (running) or r6 (after the window)"
first="$out"
: >"$T/api/calls.log"
run_axes "$T/cache1"
jobs_calls=$(grep -c '/jobs' "$T/api/calls.log"); ann_calls=$(grep -c '/annotations' "$T/api/calls.log")
[[ $jobs_calls -eq 0 && $ann_calls -eq 0 ]] && pass "6. second run reads the cache: 0 job and 0 annotation calls" \
  || fail "6. second run made $jobs_calls job / $ann_calls annotation call(s)"
[[ "$(grep -v '^== api' <<<"$out")" == "$(grep -v '^== api' <<<"$first")" ]] \
  && pass "6. the cached run prints the same axes" || fail "6. the cached run printed different axes"

# --- CONTROL a. no run in the window --------------------------------------------
run_axes "$T/cache-a" CI_AXES_SINCE=2027-01-01T00:00:00Z CI_AXES_UNTIL=2027-01-02T00:00:00Z
[[ $rc -ne 0 ]] && grep -q "no run of" <<<"$out" && pass "CONTROL a: an empty window is refused, not reported healthy" \
  || fail "CONTROL a: rc=$rc out=$out"
# --- CONTROL b. gh fails ---------------------------------------------------------
run_axes "$T/cache-b" GH_STUB_BROKEN=1
[[ $rc -ne 0 ]] && grep -q "FATAL gh api runs failed" <<<"$out" && pass "CONTROL b: a failing gh is refused" \
  || fail "CONTROL b: rc=$rc out=$out"
# --- CONTROL c. malformed SINCE ----------------------------------------------------
: >"$T/api/calls.log"
run_axes "$T/cache-c" CI_AXES_SINCE=yesterday
[[ $rc -ne 0 && ! -s "$T/api/calls.log" ]] && pass "CONTROL c: a malformed CI_AXES_SINCE is refused before any call" \
  || fail "CONTROL c: rc=$rc calls=$(wc -l <"$T/api/calls.log")"
# --- CONTROL d. annotations hidden -> check 5 would fail ----------------------------
run_axes "$T/cache-d" GH_STUB_NO_ANNOTATIONS=1
# rows: hub, e2e 1/2, orc 1/2 (r1, no stop seen), generate (r4; the e2e
# timeout is a plain cancel now), iac (r7) = 5; no local gate: e2e + generate
grep -qF "X8 reds with no local gate 40% (2 of 5 first-red rows" <<<"$out" &&
  grep -qF "runner-lost: 0 of 3" <<<"$out" &&
  pass "CONTROL d: without the annotation parse X8 reads 40 % and the guard 0 -- check 5 depends on it" \
  || fail "CONTROL d: the hidden annotations did not change X8 / the guard: $out"

if [[ $fails -eq 0 ]]; then
  echo "PASS: report-ci-axes.tst.sh"
else
  echo "FAIL: $fails assertion(s) in report-ci-axes.tst.sh"
fi
[[ $fails -eq 0 ]]
