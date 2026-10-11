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
#   5. the first-red section (r7-02): a run with 1 red job and 8 jobs that
#      gate-fail-fast.sh stopped counts 1 job, not 9; the job names hold
#      commas, as the real ones do, and one stopped job names an earlier
#      stopped one, as a late poll does
#   6. one `last green: <run> <sha8> <time>` line per failed job
#   7. master only by default (r8-03): the header names the branch read, and
#      a failed run on a review branch is never counted; CI_GATE_BRANCH=
#      (set, empty) reads every branch, CI_GATE_BRANCH=<b> reads <b>
#   8. spec 131 C1: a job that hit timeout-minutes (GitHub: "cancelled" +
#      "exceeded the maximum execution time") is a red job, its run reads
#      `timeout`; a short superseded cancelled run is never re-read
#   9. spec 131 C1: a signature is never a PASS line that quotes FAIL
#   CONTROLS -- the report cannot be silently empty:
#     a. no runs at all               -> refused (non-zero), not "healthy"
#     b. gh itself fails              -> refused (non-zero)
#     c. a non-numeric CI_GATE_RUNS   -> refused before any call
#     d. CI_GATE_REPO reaches gh as GH_REPO -- `gh api` has no --repo flag, so
#        a wrong wiring here would silently report the WRONG repo in CI
#     e. RED CONTROL for 5: the same run with the annotations hidden counts
#        9 first reds, so the assertion of 5 fails without the parse
#     f. RED CONTROL for 7: the stub returns the branch run to a `gh run list`
#        without --branch, which is the call the report made before r8-03;
#        that call counts it, so check 7 fails without the --branch
#     g. RED CONTROL for 8: with the annotations hidden the window reads
#        "no failed run", the report before C1
#     h. RED CONTROL for 9: the pre-C1 signature grep picks the PASS line
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/report-ci-gate.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
[[ -f "$FUNC" ]] && pass "the action lives where the run framework discovers it: src/bash/run/$(basename "$FUNC")" \
  || { echo "FAIL: no $FUNC"; exit 1; }

mkdir -p "$T/stub" "$T/api"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
# canned API JSON + the CALLER's own --jq filter through real jq
[[ "${GH_STUB_BROKEN:-0}" == 1 ]] && { echo "gh: stub failure" >&2; exit 1; }
printf '%s\n' "${GH_REPO:-}" >>"$GH_STUB_DIR/gh_repo.seen"
args=("$@"); jqf=""; branch=""; has_branch=0
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == "--jq" ]] && jqf="${args[i+1]}"
  [[ "${args[i]}" == "--branch" ]] && { has_branch=1; branch="${args[i+1]}"; }
done
src=""
case "${args[0]}" in
  run)
    src="$GH_STUB_DIR/runs.json"
    # the real gh filters on headBranch server side; without --branch it
    # returns every branch, the review dispatches included
    if (( has_branch )); then
      jq --arg b "$branch" '[.[] | select(.headBranch == $b)]' "$src" >"$GH_STUB_DIR/runs-on-branch.json"
      src="$GH_STUB_DIR/runs-on-branch.json"
    fi ;;
  api)
    case "${args[1]}" in
      */runs/*/jobs) src="$GH_STUB_DIR/jobs-$(sed 's|.*/runs/\([0-9]*\)/jobs|\1|' <<<"${args[1]}").json" ;;
      */jobs/*/logs) cat "$GH_STUB_DIR/log-$(sed 's|.*/jobs/\([0-9]*\)/logs|\1|' <<<"${args[1]}").txt" 2>/dev/null; exit 0 ;;
      */check-runs/*/annotations)
        src="$GH_STUB_DIR/ann-$(sed 's|.*/check-runs/\([0-9]*\)/annotations|\1|' <<<"${args[1]}").json"
        [[ -f "$src" && "${GH_STUB_NO_ANNOTATIONS:-0}" != 1 ]] || src="$GH_STUB_DIR/ann-none.json" ;;
    esac ;;
esac
[[ -f "$src" ]] || { echo "gh: stub has no canned $src" >&2; exit 1; }
if [[ -n "$jqf" ]]; then jq -r "$jqf" "$src"; else cat "$src"; fi
STUB
chmod +x "$T/stub/gh"

# runs on master: 3 failures + 3 successes + 1 still running; plus 908, a
# failed branch dispatch of a review branch, which a master report never reads
cat >"$T/api/runs.json" <<'JSON'
[
 {"databaseId":901,"conclusion":"","createdAt":"2026-01-02T10:05:00Z","headSha":"aaaaaaaa1111","headBranch":"master"},
 {"databaseId":902,"conclusion":"failure","createdAt":"2026-01-02T10:00:00Z","headSha":"bbbbbbbb2222","headBranch":"master"},
 {"databaseId":908,"conclusion":"failure","createdAt":"2026-01-02T09:58:00Z","headSha":"88888888bbbb","headBranch":"review/r8-99"},
 {"databaseId":903,"conclusion":"failure","createdAt":"2026-01-02T09:55:00Z","headSha":"cccccccc3333","headBranch":"master"},
 {"databaseId":904,"conclusion":"success","createdAt":"2026-01-02T09:50:00Z","headSha":"dddddddd4444","headBranch":"master"},
 {"databaseId":905,"conclusion":"success","createdAt":"2026-01-02T09:45:00Z","headSha":"eeeeeeee5555","headBranch":"master"},
 {"databaseId":906,"conclusion":"success","createdAt":"2026-01-02T09:40:00Z","headSha":"ffffffff6666","headBranch":"master"},
 {"databaseId":907,"conclusion":"failure","createdAt":"2026-01-02T09:35:00Z","headSha":"99999999aaaa","headBranch":"master"}
]
JSON
# 908 (review branch): a job that never failed on master
cat >"$T/api/jobs-908.json" <<'JSON'
{"jobs":[{"id":7200,"name":"branch: red on a review branch only","conclusion":"failure"}]}
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
# 904 (success): the newest green of both jobs that failed in 902
cat >"$T/api/jobs-904.json" <<'JSON'
{"jobs":[{"id":7006,"name":"iac: step contracts","conclusion":"success"},
         {"id":7007,"name":"wui: unit tests","conclusion":"success"}]}
JSON
# 907: ONE job broke the run, gate-fail-fast.sh stopped the 8 others, and every
# stopped job concluded failure too. Names hold commas like the real ones; the
# last stopped job polled after s1 had ended, so it names s1 as well.
red='e2e: generate (mock, tenant)'
{
  printf '{"jobs":[{"id":7100,"name":"%s","conclusion":"failure"}' "$red"
  for i in 1 2 3 4 5 6 7 8; do printf ',\n {"id":71%02d,"name":"stop: s%s (a, b)","conclusion":"failure"}' "$i" "$i"; done
  printf ']}\n'
} >"$T/api/jobs-907.json"
echo '[]' >"$T/api/ann-none.json"
echo '[{"message":"Process completed with exit code 1."}]' >"$T/api/ann-7100.json"
for i in 1 2 3 4 5 6 7; do
  printf '[{"message":"Process completed with exit code 1."},{"message":"gate fail-fast: stopped, so the next gate run starts; red in this run: %s"}]\n' "$red" >"$T/api/ann-71$(printf %02d "$i").json"
done
printf '[{"message":"gate fail-fast: stopped, so the next gate run starts; red in this run: %s,stop: s1 (a, b)"}]\n' "$red" >"$T/api/ann-7108.json"
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

# --- 5. first red per job ----------------------------------------------------
# first_red_section <file> - the lines of the first-red section only
first_red_section() { sed -n '/^== first red per JOB/,/^== /{/^== /d;p}' "$1"; }
# first_red_is_one <file> - the 907 run counts its one red job and nothing else
first_red_is_one() {
  local sec; sec=$(first_red_section "$1")
  sed 's/^ *//' <<<"$sec" | grep -xF "1 $red" >/dev/null && ! grep -q 'stop: s' <<<"$sec"
}
report; rc=$?
if [[ $rc -eq 0 ]] && first_red_is_one "$T/out"; then
  pass "first red: the run with 1 red job and 8 stopped counts 1 job ($red), no stopped job"
else
  fail "first red: the stopped jobs were counted, or the red job was not (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi
sec=$(first_red_section "$T/out")
if grep -qE '^ +2 iac: step contracts$' <<<"$sec" && grep -qE '^ +1 wui: unit tests$' <<<"$sec"; then
  pass "first red: a failed job with no fail-fast annotation is a first red (iac 2, wui 1)"
else
  fail "first red: the runs with no stop lost their red jobs"; sed 's/^/    | /' <<<"$sec"
fi
grep -qE '^ +8 stop: s|^ +1 stop: s' "$T/out" \
  && pass "the old per-job section still counts the stopped jobs (other readers rely on it)" \
  || { fail "the old per-job section changed"; sed 's/^/    | /' "$T/out"; }

# --- CONTROL e. red control: without the annotation parse it counts 9 --------
report GH_STUB_NO_ANNOTATIONS=1
if ! first_red_is_one "$T/out" && [[ $(first_red_section "$T/out" | grep -cE '^ +1 (e2e: generate|stop: s[1-8] )') -eq 9 ]]; then
  pass "CONTROL e. with the annotations hidden the first-red section counts 9 jobs, so check 5 FAILS without the parse"
else
  fail "CONTROL e. check 5 passes without the annotation parse: it proves nothing"; sed 's/^/    | /' "$T/out"
fi

# --- 6. last green per failed job -----------------------------------------------
report
if grep -qx '   last green: 904 dddddddd 2026-01-02T09:50:00Z  iac: step contracts' "$T/out" \
   && grep -qx '   last green: 904 dddddddd 2026-01-02T09:50:00Z  wui: unit tests' "$T/out" \
   && grep -qx '   last green: none in the last 7 run(s)  stop: s1 (a, b)' "$T/out" \
   && [[ $(grep -c '^   last green: ' "$T/out") -eq 11 ]]; then
  pass "one last-green line per failed job: run, sha8, time; 'none' when it never passed in the window"
else
  fail "last-green lines wrong"; sed 's/^/    | /' "$T/out"
fi

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

# --- 7. master only by default ------------------------------------------------
# sees_branch_run <file> - the report read run 908 of the review branch
sees_branch_run() { grep -qE '908|88888888|red on a review branch only' "$1"; }
report; rc=$?
if [[ $rc -eq 0 ]] && grep -qE '^== 10_ci-quality\.yml on master -- last 7 run\(s\)' "$T/out" && ! sees_branch_run "$T/out"; then
  pass "default: the header says 'on master' over 7 runs and the review-branch run 908 is never counted"
else
  fail "default: not master only, or the header does not name the branch (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi
report CI_GATE_BRANCH=; rc=$?
if [[ $rc -eq 0 ]] && grep -qE '^== 10_ci-quality\.yml on every branch -- last 8 run\(s\)' "$T/out" \
   && grep -qE '^ +1 branch: red on a review branch only$' "$T/out"; then
  pass "CI_GATE_BRANCH= (empty) reads every branch, the header says so, and 908 is counted"
else
  fail "CI_GATE_BRANCH= did not read every branch (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi
report CI_GATE_BRANCH=review/r8-99; rc=$?
if [[ $rc -eq 0 ]] && grep -qE '^== 10_ci-quality\.yml on review/r8-99 -- last 1 run\(s\)' "$T/out" \
   && grep -q '908 .*88888888 .*branch: red on a review branch only' "$T/out" && ! grep -q 'iac: step contracts' "$T/out"; then
  pass "CI_GATE_BRANCH=review/r8-99 reads that branch only"
else
  fail "CI_GATE_BRANCH=review/r8-99 did not read that branch only (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi

# --- CONTROL f. red control for 7: the pre-r8-03 call had no --branch -------
# The stub returns 908 to any `gh run list` without --branch, the call the
# report made before r8-03 (`gh run list --workflow "$wf" --limit "$n"`).
PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" gh run list --workflow 10_ci-quality.yml --limit 40 \
  --json databaseId,conclusion,createdAt,headSha --jq '.[].databaseId' >"$T/out-f" 2>&1
if grep -qx 908 "$T/out-f"; then
  pass "CONTROL f. a run list without --branch returns the review-branch run 908, so check 7 FAILS on the old call"
else
  fail "CONTROL f. the stub hides 908 without --branch: check 7 proves nothing"; sed 's/^/    | /' "$T/out-f"
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

# --- 8. a timeout is a red job (spec 131 C1) ----------------------------------
# 920: started 30 min, one job timed out (cancelled + the timeout annotation)
# and one passed; 921: a superseded pending run (cancelled after 40 s) whose
# canned jobs would read as a timeout if the report fetched them; 922 green.
cp "$T/api/runs.json" "$T/api/runs-before-8.json"
cat >"$T/api/runs.json" <<'JSON'
[
 {"databaseId":921,"conclusion":"cancelled","createdAt":"2026-01-03T10:10:00Z","headSha":"21212121aaaa","headBranch":"master","startedAt":"2026-01-03T10:10:00Z","updatedAt":"2026-01-03T10:10:40Z"},
 {"databaseId":920,"conclusion":"cancelled","createdAt":"2026-01-03T10:00:00Z","headSha":"20202020aaaa","headBranch":"master","startedAt":"2026-01-03T10:00:00Z","updatedAt":"2026-01-03T10:30:00Z"},
 {"databaseId":922,"conclusion":"success","createdAt":"2026-01-03T09:00:00Z","headSha":"22222222aaaa","headBranch":"master","startedAt":"2026-01-03T09:00:00Z","updatedAt":"2026-01-03T09:40:00Z"}
]
JSON
echo '{"jobs":[{"id":7300,"name":"orc: hermetic 1/2","conclusion":"cancelled"},{"id":7301,"name":"cnf: validator","conclusion":"success"}]}' >"$T/api/jobs-920.json"
echo '{"jobs":[{"id":7310,"name":"orc: superseded","conclusion":"cancelled"}]}' >"$T/api/jobs-921.json"
echo '{"jobs":[{"id":7320,"name":"orc: hermetic 1/2","conclusion":"success"}]}' >"$T/api/jobs-922.json"
for j in 7300 7310; do
  echo '[{"message":"The job has exceeded the maximum execution time of 20m0s"},{"message":"The operation was canceled."}]' >"$T/api/ann-$j.json"
done
report; rc=$?
if [[ $rc -eq 0 ]] && grep -qE '^ +1 timeout$' "$T/out" && grep -qE '^ +1 cancelled$' "$T/out" \
   && grep -qE '^ +1 orc: hermetic 1/2$' "$T/out" \
   && grep -q '920 .*20202020 .*orc: hermetic 1/2  || timeout: The job has exceeded the maximum execution time of 20m0s' "$T/out" \
   && grep -qx '   last green: 922 22222222 2026-01-03T09:00:00Z  orc: hermetic 1/2' "$T/out" \
   && ! grep -q 'orc: superseded' "$T/out"; then
  pass "8. the timed-out job is a red job (run 920 reads timeout, last green 922); the 40 s superseded run 921 stays cancelled"
else
  fail "8. a timeout is not counted as red, or the superseded run was re-read (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi
# --- CONTROL g. without the annotation the report sees no red at all ----------
report GH_STUB_NO_ANNOTATIONS=1
if grep -q 'no failed run in the window' "$T/out" && grep -qE '^ +2 cancelled$' "$T/out"; then
  pass "CONTROL g. with the annotations hidden the timeout reads as 2 cancelled + no failed run, so check 8 FAILS without the parse"
else
  fail "CONTROL g. check 8 passes without the timeout annotation: it proves nothing"; sed 's/^/    | /' "$T/out"
fi
cp "$T/api/runs-before-8.json" "$T/api/runs.json"

# --- 9. a PASS line that quotes FAIL is never the signature (spec 131 C1) ------
# 6 PASS lines quote FAIL before the real failure, as on 822df3050 (c-830)
{
  for i in 1 2 3 4 5 6; do printf '2026-01-02T10:00:0%sZ PASS: %s. a handoff that cannot be written: RS-HANDOFF FAIL (never OK)\n' "$i" "$i"; done
  printf '2026-01-02T10:00:07Z FAIL: the tfvars differ from a fresh render\n'
} >"$T/api/log-7001.txt"
report CI_GATE_SIGNATURES=1; rc=$?
if [[ $rc -eq 0 ]] && grep -q '902 .*iac: step contracts  || FAIL: the tfvars differ from a fresh render' "$T/out" \
   && ! grep -q 'RS-HANDOFF' "$T/out"; then
  pass "9. after 6 PASS lines that quote FAIL, the signature is the real FAIL line"
else
  fail "9. a PASS line was taken as the signature (rc=$rc)"; sed 's/^/    | /' "$T/out"
fi
# --- CONTROL h. the pre-C1 grep takes the first PASS line ----------------------
old=$(grep -aE '(^|[[:space:]])(FAIL[:[:space:]]|FAILED:|--- FAIL|::error::)' "$T/api/log-7001.txt" |
      grep -avE '36;1m|echo "::error' | sed -E 's/^[^ ]*Z //' | sed -n 1p)
[[ "$old" == "PASS: 1."* ]] \
  && pass "CONTROL h. the pre-C1 signature grep returns '${old:0:40}...', so check 9 FAILS without the PASS filter" \
  || fail "CONTROL h. the old grep did not pick the PASS line ($old): check 9 proves nothing"

if [[ $fails -eq 0 ]]; then
  echo "PASS: all report-ci-gate.tst.sh assertions"
else
  echo "FAIL: $fails assertion(s) in report-ci-gate.tst.sh"
fi
[[ $fails -eq 0 ]]
