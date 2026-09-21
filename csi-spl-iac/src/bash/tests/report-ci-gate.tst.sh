#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_report_ci_gate counts a workflow's recent failures PER JOB, so a
#          job that is red across many runs is one line instead of many pages.
#          Hermetic: `gh` is stubbed. The stub is not a mock of the OUTPUT --
#          it holds canned API JSON and runs the action's OWN --jq filter over
#          it with real jq, so a broken filter fails here too.
#   1. the per-job counts are the number of RUNS that job failed in
#   2. every failed run is listed with its id, sha and job name
#   3. CI_GATE_SIGNATURES=1 adds the first FAIL/::error line of that job's log
#   4. a window with no failure says so and exits 0
#   CONTROLS -- the report cannot be silently empty:
#     a. no runs at all               -> refused (non-zero), not "healthy"
#     b. gh itself fails              -> refused (non-zero)
#     c. a non-numeric CI_GATE_RUNS   -> refused before any call
#     d. CI_GATE_REPO reaches gh as GH_REPO -- `gh api` has no --repo flag, so
#        a wrong wiring here would silently report the WRONG repo in CI
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/report-ci-gate.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it: src/bash/run/$(basename "$FUNC")" \
  || { echo "FAIL: no $FUNC"; exit 1; }

mkdir -p "$T/stub" "$T/api"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
# canned API JSON + the CALLER's own --jq filter through real jq
[[ "${GH_STUB_BROKEN:-0}" == 1 ]] && { echo "gh: stub failure" >&2; exit 1; }
printf '%s\n' "${GH_REPO:-}" >>"$GH_STUB_DIR/gh_repo.seen"
args=("$@"); jqf=""
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == "--jq" ]] && jqf="${args[i+1]}"; done
src=""
case "${args[0]}" in
  run) src="$GH_STUB_DIR/runs.json" ;;
  api)
    case "${args[1]}" in
      */runs/*/jobs) src="$GH_STUB_DIR/jobs-$(sed 's|.*/runs/\([0-9]*\)/jobs|\1|' <<<"${args[1]}").json" ;;
      */jobs/*/logs) cat "$GH_STUB_DIR/log-$(sed 's|.*/jobs/\([0-9]*\)/logs|\1|' <<<"${args[1]}").txt" 2>/dev/null; exit 0 ;;
    esac ;;
esac
[[ -f "$src" ]] || { echo "gh: stub has no canned $src" >&2; exit 1; }
if [[ -n "$jqf" ]]; then jq -r "$jqf" "$src"; else cat "$src"; fi
STUB
chmod +x "$T/stub/gh"

# runs: 2 failures + 3 successes + 1 still running
cat >"$T/api/runs.json" <<'JSON'
[
 {"databaseId":901,"conclusion":"","createdAt":"2026-01-02T10:05:00Z","headSha":"aaaaaaaa1111"},
 {"databaseId":902,"conclusion":"failure","createdAt":"2026-01-02T10:00:00Z","headSha":"bbbbbbbb2222"},
 {"databaseId":903,"conclusion":"failure","createdAt":"2026-01-02T09:55:00Z","headSha":"cccccccc3333"},
 {"databaseId":904,"conclusion":"success","createdAt":"2026-01-02T09:50:00Z","headSha":"dddddddd4444"},
 {"databaseId":905,"conclusion":"success","createdAt":"2026-01-02T09:45:00Z","headSha":"eeeeeeee5555"},
 {"databaseId":906,"conclusion":"success","createdAt":"2026-01-02T09:40:00Z","headSha":"ffffffff6666"}
]
JSON
# 902 fails two jobs, 903 fails one of the same two -> counts 2 and 1
cat >"$T/api/jobs-902.json" <<'JSON'
{"jobs":[{"id":7001,"name":"iac: step contracts","conclusion":"failure"},
         {"id":7002,"name":"wui: unit tests","conclusion":"failure"},
         {"id":7003,"name":"hub: go test","conclusion":"success"}]}
JSON
cat >"$T/api/jobs-903.json" <<'JSON'
{"jobs":[{"id":7004,"name":"iac: step contracts","conclusion":"failure"},
         {"id":7005,"name":"hub: go test","conclusion":"success"}]}
JSON
printf '2026-01-02T10:00:01Z ok   - something\n2026-01-02T10:00:02Z FAIL: the tfvars differ from a fresh render\n2026-01-02T10:00:03Z more\n' >"$T/api/log-7001.txt"
printf '2026-01-02T10:00:01Z FAIL key present auth.x: missing in en.json\n' >"$T/api/log-7002.txt"
printf '2026-01-02T09:55:02Z FAIL: the tfvars differ from a fresh render\n' >"$T/api/log-7004.txt"

# report [VAR=value ...] -> rc; combined output in $T/out
report() {
  env PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" "$@" bash -c '
    do_log() { echo "$*"; }
    source "'"$FUNC"'"
    do_report_ci_gate' >"$T/out" 2>&1
}

# --- 1. per-job counts --------------------------------------------------------
report; rc=$?
if [[ $rc -eq 0 ]] && grep -qE '^ +2 iac: step contracts$' "$T/out" && grep -qE '^ +1 wui: unit tests$' "$T/out"; then
  pass "per-job counts: iac 2 runs, wui 1 run (rc 0)"
else
  fail "per-job counts wrong (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi
grep -q 'hub: go test' "$T/out" && { fail "a job that SUCCEEDED was counted as a failure"; } \
  || pass "a job that succeeded in a failed run is not counted"
grep -qE '3 success' "$T/out" && grep -qE '1 running' "$T/out" \
  && pass "the run-level tally names success and the still-running run" \
  || { fail "run-level tally missing success/running"; sed 's/^/    | /' "$T/out"; }

# --- 2. the failed runs are named ---------------------------------------------
if grep -q '902 .*bbbbbbbb .*iac: step contracts' "$T/out" && grep -q '903 .*cccccccc' "$T/out"; then
  pass "each failed run is listed with id, sha and job"
else
  fail "the failed-run list is missing a run"; sed 's/^/    | /' "$T/out"
fi

# --- 3. signatures ------------------------------------------------------------
report CI_GATE_SIGNATURES=1; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'FAIL: the tfvars differ from a fresh render' "$T/out" \
   && grep -q 'FAIL key present auth.x: missing in en.json' "$T/out"; then
  pass "CI_GATE_SIGNATURES=1 names the first failure line of each failed job"
else
  fail "no per-job signature with CI_GATE_SIGNATURES=1 (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi

# --- 4. a clean window --------------------------------------------------------
jq '[.[] | select(.conclusion != "failure")]' "$T/api/runs.json" >"$T/api/runs-clean.json"
mv "$T/api/runs.json" "$T/api/runs-with-failures.json" && cp "$T/api/runs-clean.json" "$T/api/runs.json"
report; rc=$?
[[ $rc -eq 0 ]] && grep -q 'no failed run in the window' "$T/out" \
  && pass "a clean window reports no failure and exits 0" \
  || { fail "a clean window was not reported as clean (rc=$rc)"; sed 's/^/    | /' "$T/out"; }

# --- CONTROL d. CI_GATE_REPO reaches gh as GH_REPO ----------------------------
cp "$T/api/runs-with-failures.json" "$T/api/runs.json"   # runs + jobs + logs calls
: >"$T/api/gh_repo.seen"
report CI_GATE_REPO=an-org/a-repo CI_GATE_SIGNATURES=1 >/dev/null
if grep -qx 'an-org/a-repo' "$T/api/gh_repo.seen" && ! grep -qvx 'an-org/a-repo' "$T/api/gh_repo.seen"; then
  pass "CONTROL d. every gh call saw GH_REPO=an-org/a-repo ($(wc -l <"$T/api/gh_repo.seen") call(s))"
else
  fail "CONTROL d. CI_GATE_REPO did not reach gh as GH_REPO"; sed 's/^/    | /' "$T/api/gh_repo.seen"
fi
: >"$T/api/gh_repo.seen"
report CI_GATE_SIGNATURES=1 >/dev/null
grep -qvx '' "$T/api/gh_repo.seen" \
  && { fail "CONTROL d. GH_REPO was set although CI_GATE_REPO was not"; sed 's/^/    | /' "$T/api/gh_repo.seen"; } \
  || pass "CONTROL d. without CI_GATE_REPO, GH_REPO is left alone (gh infers the repo from the cwd)"

# --- CONTROL a. no runs at all ------------------------------------------------
echo '[]' >"$T/api/runs.json"
report; rc=$?
[[ $rc -ne 0 ]] && grep -q 'nothing measured' "$T/out" \
  && pass "CONTROL a. no runs at all is REFUSED (rc=$rc), never read as healthy" \
  || { fail "CONTROL a. an empty run list did not refuse (rc=$rc)"; sed 's/^/    | /' "$T/out"; }

# --- CONTROL b. gh itself fails -----------------------------------------------
cp "$T/api/runs-with-failures.json" "$T/api/runs.json"
report GH_STUB_BROKEN=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'gh run list failed' "$T/out" \
  && pass "CONTROL b. a failing gh is REFUSED (rc=$rc)" \
  || { fail "CONTROL b. a failing gh did not refuse (rc=$rc)"; sed 's/^/    | /' "$T/out"; }

# --- CONTROL c. a bad window size ---------------------------------------------
report CI_GATE_RUNS=all; rc=$?
[[ $rc -ne 0 ]] && grep -q 'CI_GATE_RUNS' "$T/out" \
  && pass "CONTROL c. a non-numeric CI_GATE_RUNS is REFUSED (rc=$rc)" \
  || { fail "CONTROL c. a non-numeric CI_GATE_RUNS was accepted (rc=$rc)"; sed 's/^/    | /' "$T/out"; }

if [[ $fails -eq 0 ]]; then
  echo "PASS: all report-ci-gate.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in report-ci-gate.tst.sh"
fi
[[ $fails -eq 0 ]]
