#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_ci_failed_log prints the log of every failed job of a run through
#          `gh api .../actions/jobs/<id>/logs`, because `gh run view <id>
#          --log-failed` (gh 2.46) prints 0 lines for a job whose name holds
#          `:` or `/` (SPL-2340). Hermetic: `gh` is a stub with canned API JSON.
#   1. a run with 2 failed jobs named with `:` and `/` prints both: header
#      (name, id, url), the first FAIL line and the log tail; the green job of
#      the run is not printed
#   2. CI_LOG_TAIL=1 prints only each log's last line
#   3. a run with no failed job says so, rc 0
#   4. no RUN_ID -> refused before any gh call; a non-numeric RUN_ID too
#   5. a run whose jobs cannot be read (gh fails) -> refused, never "no failed job"
#   CONTROL:
#     a. RED CONTROL for 1: the stub's `gh run view --log-failed` answers as
#        gh 2.46 does on these job names (0 lines), so the old runbook command
#        fails check 1's assertion
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/ci-failed-log.func.sh"
HELP="$PROJ_ROOT/src/bash/run/report-ci-gate.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
require_action "$FUNC"

mkdir -p "$T/stub" "$T/api"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_STUB_DIR/calls"
[[ "${GH_STUB_BROKEN:-0}" == 1 ]] && { echo "gh: stub failure" >&2; exit 1; }
args=("$@"); jqf=""
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == "--jq" ]] && jqf="${args[i+1]}"; done
[[ "${args[0]}" == run ]] && exit 0   # gh 2.46 --log-failed on these names: 0 lines
src=""
case "${args[1]}" in
  */runs/*/jobs) src="$GH_STUB_DIR/jobs-$(sed 's|.*/runs/\([0-9]*\)/jobs|\1|' <<<"${args[1]}").json" ;;
  */jobs/*/logs) cat "$GH_STUB_DIR/log-$(sed 's|.*/jobs/\([0-9]*\)/logs|\1|' <<<"${args[1]}").txt"; exit ;;
  */check-runs/*/annotations) src="$GH_STUB_DIR/ann-none.json" ;;
esac
[[ -f "$src" ]] || { echo "gh: stub has no canned $src" >&2; exit 1; }
if [[ -n "$jqf" ]]; then jq -r "$jqf" "$src"; else cat "$src"; fi
STUB
chmod +x "$T/stub/gh"

echo '[]' >"$T/api/ann-none.json"
cat >"$T/api/jobs-501.json" <<'JSON'
{"jobs":[{"id":8001,"name":"orc: feature tests (spawn-agents, graft, ...)","conclusion":"failure","html_url":"https://example.com/r/501/job/8001"},
         {"id":8002,"name":"orc: hermetic action tests 1/3","conclusion":"failure","html_url":"https://example.com/r/501/job/8002"},
         {"id":8003,"name":"hub: go test","conclusion":"success","html_url":"https://example.com/r/501/job/8003"}]}
JSON
cat >"$T/api/jobs-502.json" <<'JSON'
{"jobs":[{"id":8004,"name":"hub: go test","conclusion":"success","html_url":"https://example.com/r/502/job/8004"}]}
JSON
printf '2026-01-02T10:00:01Z ok   - a\n2026-01-02T10:00:02Z FAIL: feature log line\n2026-01-02T10:00:03Z feature-last-line\n' >"$T/api/log-8001.txt"
printf '2026-01-02T10:00:01Z ok   - b\n2026-01-02T10:00:02Z --- FAIL: hermetic 1/3 line\n2026-01-02T10:00:03Z hermetic-last-line\n' >"$T/api/log-8002.txt"
printf 'green log, never printed\n' >"$T/api/log-8003.txt"

# run_it <env assignments...> - the action under the stub; out in $T/out, rc in $rc
run_it() {
  rm -f "$T/api/calls"
  env -u RUN_ID PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" "$@" bash -c '
    do_log() { echo "$*"; }
    source "'"$HELP"'"; source "'"$FUNC"'"
    do_ci_failed_log' >"$T/out" 2>&1
  rc=$?
}

# 1. both failed jobs, names with ':' and '/'
run_it RUN_ID=501
if (( rc == 0 )) && grep -qF '=== orc: feature tests (spawn-agents, graft, ...)' "$T/out" \
   && grep -qF '=== orc: hermetic action tests 1/3' "$T/out" \
   && grep -qF 'job 8001  failure  https://example.com/r/501/job/8001' "$T/out" \
   && grep -qF 'first red: FAIL: feature log line' "$T/out" \
   && grep -qF 'first red: --- FAIL: hermetic 1/3 line' "$T/out" \
   && grep -q 'feature-last-line' "$T/out" && grep -q 'hermetic-last-line' "$T/out" \
   && ! grep -q 'green log' "$T/out"; then
  pass "1. 2 failed jobs named with ':' and '/': both headers, first red lines and logs; the green job is not printed"
else fail "1. rc=$rc, out: $(cat "$T/out")"; fi

# 2. CI_LOG_TAIL
run_it RUN_ID=501 CI_LOG_TAIL=1
if (( rc == 0 )) && grep -q 'feature-last-line' "$T/out" && ! grep -q 'ok   - a' "$T/out"; then
  pass "2. CI_LOG_TAIL=1 prints only each log's last line"
else fail "2. rc=$rc, out: $(cat "$T/out")"; fi

# 3. no failed job
run_it RUN_ID=502
if (( rc == 0 )) && grep -qF '== run 502: no failed job (1 job(s) read)' "$T/out"; then
  pass "3. a run with no failed job says so, rc 0"
else fail "3. rc=$rc, out: $(cat "$T/out")"; fi

# 4. RUN_ID missing / not numeric
run_it
if (( rc != 0 )) && grep -q 'RUN_ID must be set' "$T/out" && [[ ! -s "$T/api/calls" ]]; then
  pass "4. no RUN_ID -> refused (rc $rc) before any gh call"
else fail "4. rc=$rc, out: $(cat "$T/out")"; fi
run_it RUN_ID=abc
if (( rc != 0 )) && grep -q 'numeric run id' "$T/out"; then
  pass "4. a non-numeric RUN_ID -> refused (rc $rc)"
else fail "4b. rc=$rc, out: $(cat "$T/out")"; fi

# 5. gh fails
run_it RUN_ID=501 GH_STUB_BROKEN=1
if (( rc != 0 )) && grep -q 'no jobs read for run 501' "$T/out" && ! grep -q 'no failed job' "$T/out"; then
  pass "5. jobs not readable -> refused (rc $rc), never 'no failed job'"
else fail "5. rc=$rc, out: $(cat "$T/out")"; fi

# a. red control: the old runbook command finds neither job's log
PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" gh run view 501 --log-failed >"$T/out" 2>&1
if ! grep -q 'feature-last-line' "$T/out"; then
  pass "a. red control: 'gh run view --log-failed' (stubbed as gh 2.46) prints $(wc -l <"$T/out") line(s), check 1 would fail"
else fail "a. the red control printed the log: check 1 proves nothing"; fi

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
