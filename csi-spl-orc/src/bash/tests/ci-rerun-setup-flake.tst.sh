#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_ci_rerun_setup_flake reruns a run's failed jobs ONCE, and only
#          when every failed job died at "Set up job" downloading an action
#          archive (GitHub's codeload 404 on a valid pinned SHA, 2026-10-15).
#          A stub gh serves fixture JSON through the action's own jq filters
#          (`-q`), its job logs, and records every `run rerun`:
#   1. CONTROL the CI line, verbatim (wf10 38685379352 job 116259956077),
#      on attempt 1                                    -> rerun, gh rerun called
#   2. the same job failing at a test step             -> real, nothing rerun
#   3. "Set up job" failing for another reason         -> real, nothing rerun
#   4. one flake + one real red in the same run        -> real, nothing rerun
#   5. the flake on attempt 2 (already a rerun)        -> attempt, nothing rerun
#   6. no failed job                                   -> nothing
#   7. DRY_RUN=1 on a flake                            -> says so, nothing rerun
#   8. a refused rerun, an unreadable run, a bad RUN_ID, no REPO -> rc 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

FLAKE_LOG="2026-10-15T05:14:32.2558866Z Download action repository 'actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e' (SHA:b7ad1dad31e06c5925ef5d2fc7ad053ef454303e)
2026-10-15T05:14:32.4636315Z ##[error]An action could not be found at the URI 'https://codeload.github.com/actions/setup-go/tar.gz/b7ad1dad31e06c5925ef5d2fc7ad053ef454303e' (ABC0:26BB79:8EBC3:FC857:6AD06138)
2026-10-15T05:14:32.4665590Z ##[error]Failed to download archive 'https://codeload.github.com/actions/setup-go/tar.gz/b7ad1dad31e06c5925ef5d2fc7ad053ef454303e' after 1 attempts."

# The stub gh: fixtures under $FX (run.json, jobs.json, log.<job id>);
# `-q <filter>` is applied with jq -r, as gh does; `run rerun` is logged.
mkdir -p "$T/stub"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == run && "$2" == rerun ]]; then echo "rerun $*" >>"$FX/calls"; exit "${RERUN_RC:-0}"; fi
q='.'; path=''
for (( i = 1; i <= $#; i++ )); do
  case "${!i}" in
    -q) j=$((i + 1)); q="${!j}" ;;
    repos/*) path="${!i}" ;;
  esac
done
case "$path" in
  */logs) f="$FX/log.$(basename "$(dirname "$path")")"; [[ -f "$f" ]] && cat "$f"; exit 0 ;;
  */jobs*) f="$FX/jobs.json" ;;
  */runs/*) f="$FX/run.json" ;;
esac
[[ -f "$f" ]] || exit 1
jq -r "$q" "$f"
STUB
chmod +x "$T/stub/gh"

# job <id> <name> <failed step or ''> -> one job object (conclusion failure when a step failed)
job() {
  if [[ -n "$3" ]]; then
    printf '{"id":%s,"name":"%s","conclusion":"failure","steps":[{"name":"%s","conclusion":"failure"}]}' "$1" "$2" "$3"
  else
    printf '{"id":%s,"name":"%s","conclusion":"success","steps":[{"name":"Run tests","conclusion":"success"}]}' "$1" "$2"
  fi
}
# fixture <attempt> <job json>,... : a fresh fixture dir in FX
fixture() {
  FX="$T/fx.$RANDOM$RANDOM"; mkdir -p "$FX"; : >"$FX/calls"
  printf '{"run_attempt":%s}' "$1" >"$FX/run.json"
  printf '{"jobs":[%s]}' "$2" >"$FX/jobs.json"
}
run_it() {  # [VAR=value]... -> the action's output; rc in $RC
  out="$(env PROJ_PATH="$PROJ_ROOT" FX="$FX" CI_RERUN_GH="$T/stub/gh" RUN_ID="${RUN:-38685379352}" REPO=example/repo "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/ci-rerun-setup-flake.func.sh"
    do_ci_rerun_setup_flake' 2>&1)"
  RC=$?
}
reruns() { grep -c '^rerun ' "$FX/calls"; }

# --- 1. CONTROL: the CI line on attempt 1 -> rerun ---------------------------
fixture 1 "$(job 116259956077 'orc: feature tests' 'Set up job'),$(job 2 'wui: e2e' '')"
printf '%s\n' "$FLAKE_LOG" >"$FX/log.116259956077"
run_it
[[ $RC -eq 0 && "$out" == "rerun run=38685379352: reran 1 failed job(s)"* && "$(reruns)" == 1 ]] &&
  grep -q -- 'run rerun 38685379352 --failed --repo example/repo' "$FX/calls" &&
  pass "1 CONTROL the CI's setup-go download line on attempt 1: the failed jobs are rerun" ||
  fail "1 the CI line was not rerun: rc=$RC out='$out' calls='$(cat "$FX/calls")'"

# --- 2. the same job failing at a test step -> real ---------------------------
fixture 1 "$(job 7 'orc: feature tests' 'Run feature tests')"
printf '%s\n' "$FLAKE_LOG" >"$FX/log.7"
run_it
[[ $RC -eq 0 && "$out" == "real run="*"failed at 'Run feature tests'"* && "$(reruns)" == 0 ]] &&
  pass "2 a job that failed at a test step is not rerun (even with the download line in its log)" ||
  fail "2 rc=$RC out='$out' reruns=$(reruns)"

# --- 3. "Set up job" failing for another reason -> real -----------------------
fixture 1 "$(job 8 'hub' 'Set up job')"
echo "##[error]Unable to resolve action \`actions/setup-go@nope\`, unable to find version \`nope\`" >"$FX/log.8"
run_it
[[ $RC -eq 0 && "$out" == "real run="* && "$(reruns)" == 0 ]] &&
  pass "3 a 'Set up job' failure that is not an archive download is not rerun" ||
  fail "3 rc=$RC out='$out' reruns=$(reruns)"

# --- 4. one flake + one real red -> real, nothing rerun ------------------------
fixture 1 "$(job 9 'orc 1/2' 'Set up job'),$(job 10 'orc 2/2' 'Run hermetic tests')"
printf '%s\n' "$FLAKE_LOG" >"$FX/log.9"
run_it
[[ $RC -eq 0 && "$out" == "real run="*"job 10"* && "$(reruns)" == 0 ]] &&
  pass "4 a flake beside a real red: nothing is rerun (a rerun never hides a red)" ||
  fail "4 rc=$RC out='$out' reruns=$(reruns)"

# --- 5. attempt 2 -> attempt ---------------------------------------------------
fixture 2 "$(job 11 'hub' 'Set up job')"
printf '%s\n' "$FLAKE_LOG" >"$FX/log.11"
run_it
[[ $RC -eq 0 && "$out" == "attempt run="*"attempt 2"* && "$(reruns)" == 0 ]] &&
  pass "5 the flake on attempt 2 (already a rerun) is not rerun again" ||
  fail "5 rc=$RC out='$out' reruns=$(reruns)"

# --- 6. no failed job -> nothing ----------------------------------------------
fixture 1 "$(job 12 'hub' '')"
run_it
[[ $RC -eq 0 && "$out" == "nothing run="* && "$(reruns)" == 0 ]] &&
  pass "6 a run with no failed job: nothing" || fail "6 rc=$RC out='$out'"

# --- 7. DRY_RUN -> says so, nothing rerun ---------------------------------------
fixture 1 "$(job 13 'hub' 'Set up job')"
printf '%s\n' "$FLAKE_LOG" >"$FX/log.13"
run_it DRY_RUN=1
[[ $RC -eq 0 && "$out" == "rerun run="*"would rerun 1"*"(DRY_RUN)" && "$(reruns)" == 0 ]] &&
  pass "7 DRY_RUN=1 names the rerun and makes none" || fail "7 rc=$RC out='$out' reruns=$(reruns)"

# --- 8. errors: rc 1 -----------------------------------------------------------
fixture 1 "$(job 14 'hub' 'Set up job')"
printf '%s\n' "$FLAKE_LOG" >"$FX/log.14"
run_it RERUN_RC=1
[[ $RC -eq 1 && "$out" == *"FATAL gh run rerun"* ]] && pass "8 a refused rerun is rc 1, named" || fail "8 refused: rc=$RC out='$out'"
fixture 1 "$(job 15 'hub' '')"; rm -f "$FX/run.json"
run_it
[[ $RC -eq 1 && "$out" == *"FATAL cannot read run"* ]] && pass "8 an unreadable run is rc 1" || fail "8 unreadable: rc=$RC out='$out'"
RUN=abc run_it
[[ $RC -eq 1 && "$out" == *"FATAL RUN_ID"* ]] && pass "8 a RUN_ID that is not a run id is rc 1" || fail "8 RUN_ID: rc=$RC out='$out'"
run_it REPO= GITHUB_REPOSITORY=
[[ $RC -eq 1 && "$out" == *"FATAL REPO"* ]] && pass "8 no REPO and no GITHUB_REPOSITORY is rc 1 (no default repo)" || fail "8 REPO: rc=$RC out='$out'"

echo "---- $(basename "$0"): $fails failed"
[[ "$fails" -eq 0 ]]
