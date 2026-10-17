#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-08: GitHub Actions runner health & job hang detector
# (SPL-2451). Drives do_gh_runner_health_check against a STUB gh that serves
# fixture JSON from a temp dir; the real GitHub API is never called and no
# runner unit of the box is read (GH_RUNNER_HEALTH_UNITS is always set).
#   1. every runner online, no job -> OK, exit 0, one ONLINE line each
#   2. offline runner listed in CPU_BUDGET_STATE_DIR/parked -> PARKED, exit 0,
#      no alert (zero false alerts on parked runners)
#   3. offline runner with a unit here, not parked -> OFFLINE, exit 1, PLAN only
#   4. offline runner with no unit here -> OTHER_BOX, exit 0
#   5. self-hosted job at 50 min -> HUNG, exit 1; a hosted job at 300 min and
#      a self-hosted one at 30 min are no alert
#   6. runners endpoint fails (simulated API error) -> gh-api ERROR, exit 1
#   7. a run's jobs endpoint fails -> gh-api ERROR, exit 1
#   8. DRY_RUN=0 -> one note to orchestrator, --kind note --no-poke, stamp
#   9. same alert again, the job only aged -> throttled, nothing sent
#  10. alert set changes -> sent at once despite the throttle
#  11. throttle expired -> sent again
#  12. OK with DRY_RUN=1 keeps the stamp; DRY_RUN=0 clears it
#  13. a failed send writes no stamp
#  14. a parked unit naming no registered runner -> INFO line, exit 0
#  15. usage: bad GH_RUNNER_HEALTH_JOB_MAX_MIN / no repo -> exit 2, gh never called
#  16. ./run -a do_gh_runner_health_check (plan name) and do_gh_runner_health
#      (file name) both run it
#  17. the API calls run in parallel: 6 calls of 0.5 s each finish in < 3 s
#  18. GH_RUNNER_HEALTH_UNIT_CHECK=1 runs the unit check: its FAIL is an alert,
#      its OK is not
#  19. LIVE GUARD: no call reached a gh other than the stub, nor spool-send.sh
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="${GH_RUNNER_HEALTH_TST_FUNC_SH:-$UTL_ROOT/src/bash/run/gh-runner-health.func.sh}"

command -v jq >/dev/null 2>&1 || { fail "no jq on PATH: nothing ran"; echo "gh-runner-health: $fails failure(s)"; exit 1; }

T=$(mktemp -d /tmp/ghrh.XXXXXX)
trap 'rm -rf "$T"' EXIT
BIN="$T/bin" FIX="$T/fix" STATE="$T/state" CPU="$T/cpu"
CALLS="$T/gh-calls.log" SENT="$T/sent.log" LIVE_LOG="$T/live.log"
mkdir -p "$BIN" "$FIX" "$STATE" "$CPU"
: >"$CALLS"; : >"$SENT"; : >"$LIVE_LOG"
unset SPOOL_AGENT_ID GH_RUNNER_HEALTH_ALERT_FROM GH_RUNNER_HEALTH_UNIT_CHECK DRY_RUN

# the stub gh: `gh api --paginate <path>` -> a fixture file, missing = HTTP 404
cat >"$BIN/gh-stub" <<EOF
#!/bin/bash
p="\$3"
printf '%s\n' "\$p" >>"$CALLS"
[[ -n "\${GH_STUB_SLEEP:-}" ]] && sleep "\$GH_STUB_SLEEP"
case "\$p" in
  repos/*/actions/runners*) f=repo-runners ;;
  orgs/*/actions/runners*)  f=org-runners ;;
  repos/*/actions/runs\?status=in_progress*) f=runs ;;
  repos/*/actions/runs/*/jobs*) f="\${p#*/runs/}"; f="jobs-\${f%%/*}" ;;
  *) f=unknown ;;
esac
[[ -f "$FIX/\$f.json" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$FIX/\$f.json"
EOF
cat >"$BIN/send-stub" <<EOF
#!/bin/bash
printf 'SEND %s\n' "\$*" >>"$SENT"
EOF
cat >"$BIN/send-fail" <<'EOF'
#!/bin/bash
exit 1
EOF
# LIVE GUARD shims: the real gh and a spool-send.sh outside $T are refused
cat >"$BIN/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >>"$LIVE_LOG"; exit 97
EOF
cat >"$BIN/bash" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == */spool-send.sh && "\$a" != "$T"/* ]]; then
    printf 'bash %s\n' "\$*" >>"$LIVE_LOG"; exit 97
  fi
done
exec /bin/bash "\$@"
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

NOW=1760000000
iso() { TZ=UTC date -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
export GH_RUNNER_HEALTH_GH="$BIN/gh-stub" GH_RUNNER_HEALTH_REPO="acme/widgets"
export GH_RUNNER_HEALTH_NOW="$NOW" GH_RUNNER_HEALTH_STATE_DIR="$STATE"
export GH_RUNNER_HEALTH_SEND_CMD="$BIN/send-stub" CPU_BUDGET_STATE_DIR="$CPU"
export GH_RUNNER_HEALTH_UNITS="actions.runner.acme.box-01.service actions.runner.acme.box-02.service"
export PROJ_PATH="$UTL_ROOT"
STAMP="$STATE/last-alert.stamp"

# runner <id> <name> <status> [label...] - one runner JSON object
runner() {
  local id="$1" name="$2" st="$3" l labels=""; shift 3
  for l in self-hosted "$@"; do labels+="{\"name\":\"$l\"},"; done
  printf '{"id":%s,"name":"%s","status":"%s","busy":false,"labels":[%s]}' "$id" "$name" "$st" "${labels%,}"
}
# runners <file> <obj...>
runners() { local f="$1"; shift; local IFS=,; printf '{"total_count":%s,"runners":[%s]}\n' "$#" "$*" >"$FIX/$f.json"; }
# job <run> <id> <runner> <age_min> <self|hosted> - one in-progress job
job() {
  local lab='["ubuntu-latest"]'; [[ "$5" == self ]] && lab='["self-hosted","spool-ci"]'
  printf '{"run_id":%s,"id":%s,"name":"gate %s","status":"in_progress","runner_name":"%s","started_at":"%s","labels":%s,"html_url":"https://github.com/acme/widgets/actions/runs/%s/job/%s"}' \
    "$1" "$2" "$2" "$3" "$(iso $((NOW - $4 * 60)))" "$lab" "$1" "$2"
}
# runs <id...> - the in-progress runs list
runs() { local ids="" i; for i in "$@"; do ids+="{\"id\":$i},"; done; printf '{"workflow_runs":[%s]}\n' "${ids%,}" >"$FIX/runs.json"; }
jobs() { local f="$1"; shift; local IFS=,; printf '{"jobs":[%s]}\n' "$*" >"$FIX/jobs-$f.json"; }
reset_fix() { rm -f "$FIX"/*.json "$CPU/parked"; runners repo-runners; runners org-runners; runs; }

# check - one run in a fresh bash, under a hard timeout
check() {
  local f="$T/check.out" rc
  # shellcheck disable=SC2016 # $1 expands in the child bash
  timeout -k 2 20 /bin/bash -c 'source "$1" && do_gh_runner_health_check' _ "$FUNC_SH" >"$f" 2>&1
  rc=$?
  cat "$f"
  return "$rc"
}

# ---- 1. every runner online -----------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)" "$(runner 2 box-02 online)"
out="$(check)"; rc=$?
if ((rc == 0)) && [[ "$(grep -c '^gh-runner box-0[12] ONLINE busy=false labels=self-hosted' <<<"$out")" == 2 ]] &&
  grep -q 'CHECK gh-runner-health OK: repo=acme/widgets runners=2 online=2 parked=0 offline=0' <<<"$out"; then
  pass "1. all online -> OK, exit 0, 2 ONLINE lines"
else fail "1. all online (rc=$rc): $out"; fi

# ---- 2. offline + parked: no alert ----------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)" "$(runner 2 box-02 offline)"
echo "actions.runner.acme.box-02.service" >"$CPU/parked"
out="$(check)"; rc=$?
if ((rc == 0)) && grep -q "^gh-runner box-02 PARKED offline, actions.runner.acme.box-02.service is in $CPU/parked" <<<"$out" &&
  grep -q 'OK: .*parked=1 offline=0' <<<"$out" && ! grep -q PLAN <<<"$out"; then
  pass "2. offline + parked -> PARKED, exit 0, no alert"
else fail "2. parked (rc=$rc): $out"; fi

# ---- 3. offline, unit here, not parked: alert ------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)" "$(runner 2 box-02 offline)"
out="$(check)"; rc=$?
if ((rc == 1)) && grep -q '^gh-runner box-02 OFFLINE offline, actions.runner.acme.box-02.service is on this box and not parked' <<<"$out" &&
  grep -q 'ALERT: 1 alert(s)' <<<"$out" && grep -q 'PLAN note to orchestrator on task gh-runner-health: .*box-02 OFFLINE' <<<"$out" &&
  [[ ! -s "$SENT" && ! -f "$STAMP" ]]; then
  pass "3. offline unit here -> OFFLINE, exit 1, PLAN only (nothing sent, no stamp)"
else fail "3. offline (rc=$rc): $out"; fi

# ---- 4. offline, other box --------------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)" "$(runner 9 pc-07 offline)"
out="$(check)"; rc=$?
if ((rc == 0)) && grep -q '^gh-runner pc-07 OTHER_BOX offline, no unit here' <<<"$out" && grep -q 'other_box=1' <<<"$out"; then
  pass "4. offline, no unit here -> OTHER_BOX, exit 0"
else fail "4. other box (rc=$rc): $out"; fi

# ---- 5. hung jobs -----------------------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)"
runs 100 200
jobs 100 "$(job 100 11 box-01 50 self)" "$(job 100 12 box-01 30 self)"
jobs 200 "$(job 200 21 GitHub-Actions-3 300 hosted)"
out="$(check)"; rc=$?
if ((rc == 1)) && grep -q '^gh-job 100/11 HUNG 50 min on box-01 (> 45): gate 11 https://github.com/acme/widgets/actions/runs/100/job/11' <<<"$out" &&
  [[ "$(grep -c '^gh-job' <<<"$out")" == 1 ]] && grep -q 'jobs_in_progress=3 hung_jobs=1' <<<"$out"; then
  pass "5. self-hosted job 50 min -> HUNG, exit 1; hosted 300 min and self-hosted 30 min are no alert"
else fail "5. hung jobs (rc=$rc): $out"; fi
out="$(GH_RUNNER_HEALTH_JOB_MAX_MIN=60 check)"; rc=$?
((rc == 0)) && pass "5b. GH_RUNNER_HEALTH_JOB_MAX_MIN=60 -> the 50 min job is no alert" || fail "5b. max 60 (rc=$rc): $out"

# ---- 6. runners endpoint fails ---------------------------------------------
reset_fix
rm -f "$FIX/org-runners.json"
out="$(check)"; rc=$?
if ((rc == 1)) && grep -q '^gh-api ERROR orgs/acme/actions/runners?per_page=100 (gh: Not Found (HTTP 404))' <<<"$out" && ! grep -q 'CHECK.* OK' <<<"$out"; then
  pass "6. simulated API error on the runners -> gh-api ERROR, exit 1, never OK"
else fail "6. api error (rc=$rc): $out"; fi

# ---- 7. a jobs endpoint fails ----------------------------------------------
reset_fix
runs 300
out="$(check)"; rc=$?
if ((rc == 1)) && grep -q '^gh-api ERROR repos/acme/widgets/actions/runs/300/jobs' <<<"$out"; then
  pass "7. jobs endpoint fails -> gh-api ERROR, exit 1"
else fail "7. jobs error (rc=$rc): $out"; fi

# ---- 8..11. real send and throttle ------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)"
runs 100; jobs 100 "$(job 100 11 box-01 50 self)"
: >"$SENT"
out="$(DRY_RUN=0 check)"; rc=$?
if ((rc == 1)) && [[ "$(wc -l <"$SENT")" == 1 ]] && grep -q -- '--to orchestrator --kind note --task gh-runner-health --no-poke --body gh-runner-health on .* for acme/widgets, 1 alert(s): gh-job 100/11 HUNG 50 min' "$SENT" &&
  grep -q -- "--from gh-runner-health@" "$SENT" && [[ -f "$STAMP" ]]; then
  pass "8. DRY_RUN=0 -> one note to orchestrator (--no-poke), stamp written"
else fail "8. send (rc=$rc): $out | sent: $(cat "$SENT")"; fi
: >"$SENT"
jobs 100 "$(job 100 11 box-01 55 self)"
out="$(DRY_RUN=0 GH_RUNNER_HEALTH_NOW=$((NOW + 300)) check)"; rc=$?
jobs 100 "$(job 100 11 box-01 50 self)"
if ((rc == 1)) && [[ ! -s "$SENT" ]] && grep -q 'alert throttled' <<<"$out"; then
  pass "9. same alert, job only aged -> throttled, nothing sent"
else fail "9. throttle (rc=$rc): $out | sent: $(cat "$SENT")"; fi
runners org-runners "$(runner 1 box-01 online)" "$(runner 2 box-02 offline)"
out="$(DRY_RUN=0 check)"; rc=$?
if ((rc == 1)) && [[ "$(wc -l <"$SENT")" == 1 ]] && grep -q 'box-02 OFFLINE' "$SENT"; then
  pass "10. alert set changed -> sent at once"
else fail "10. change (rc=$rc): $out | sent: $(cat "$SENT")"; fi
: >"$SENT"
out="$(DRY_RUN=0 GH_RUNNER_HEALTH_NOW=$((NOW + 1801)) check)"; rc=$?
if [[ "$(wc -l <"$SENT")" == 1 ]]; then pass "11. throttle expired -> sent again"
else fail "11. expired (rc=$rc): $out | sent: $(cat "$SENT")"; fi

# ---- 12. OK clears the stamp only on a real run -----------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)"
check >/dev/null; rc1=$?
[[ -f "$STAMP" ]] && kept=1 || kept=0
DRY_RUN=0 check >/dev/null; rc2=$?
if ((rc1 == 0 && rc2 == 0 && kept == 1)) && [[ ! -f "$STAMP" ]]; then
  pass "12. OK: DRY_RUN=1 keeps the stamp, DRY_RUN=0 clears it"
else fail "12. clear (rc1=$rc1 rc2=$rc2 kept=$kept stamp=$([[ -f $STAMP ]] && echo yes))"; fi

# ---- 13. failed send -> no stamp ----------------------------------------------
reset_fix
runners org-runners "$(runner 2 box-02 offline)"
out="$(DRY_RUN=0 GH_RUNNER_HEALTH_SEND_CMD="$BIN/send-fail" check)"; rc=$?
if ((rc == 1)) && [[ ! -f "$STAMP" ]] && grep -q 'the note to orchestrator failed' <<<"$out"; then
  pass "13. failed send -> WARN, no stamp"
else fail "13. failed send (rc=$rc): $out"; fi

# ---- 14. stale parked entry ---------------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)"
echo "actions.runner.acme.box-gone.service" >"$CPU/parked"
out="$(check)"; rc=$?
if ((rc == 0)) && grep -q "^gh-runner-parked INFO actions.runner.acme.box-gone.service is in $CPU/parked but no runner box-gone is registered" <<<"$out"; then
  pass "14. parked unit with no registered runner -> INFO, exit 0"
else fail "14. stale parked (rc=$rc): $out"; fi

# ---- 15. usage errors -----------------------------------------------------------
: >"$CALLS"
out="$(GH_RUNNER_HEALTH_JOB_MAX_MIN=abc check)"; rc1=$?
out2="$(GH_RUNNER_HEALTH_REPO="not a repo" check)"; rc2=$?
if ((rc1 == 2 && rc2 == 2)) && [[ ! -s "$CALLS" ]] && grep -q FATAL <<<"$out" && grep -q 'FATAL no GitHub repo' <<<"$out2"; then
  pass "15. bad max / bad repo -> exit 2, gh never called"
else fail "15. usage (rc1=$rc1 rc2=$rc2 calls=$(wc -l <"$CALLS")): $out | $out2"; fi

# ---- 16. ./run names ---------------------------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)"
ok=1
for a in do_gh_runner_health_check do_gh_runner_health; do
  out="$(cd "$UTL_ROOT" && timeout -k 2 30 ./run -a "$a" 2>&1)"; rc=$?
  ((rc == 0)) && grep -q 'CHECK gh-runner-health OK' <<<"$out" || { ok=0; echo "  | $a rc=$rc: $(tail -3 <<<"$out")"; }
done
((ok)) && pass "16. ./run -a do_gh_runner_health_check and do_gh_runner_health both run it" || fail "16. ./run names"

# ---- 17. parallel calls -------------------------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)"
runs 100 200 300; jobs 100; jobs 200; jobs 300
: >"$CALLS"
t0=${EPOCHREALTIME/[.,]/}
out="$(GH_STUB_SLEEP=0.5 check)"; rc=$?
ms=$(( (${EPOCHREALTIME/[.,]/} - t0) / 1000 ))
if ((rc == 0 && ms < 3000)) && [[ "$(wc -l <"$CALLS")" == 6 ]]; then
  pass "17. 6 API calls of 0.5 s each -> done in ${ms} ms (< 3000, serial would be 3000)"
else fail "17. parallel (rc=$rc ms=$ms calls=$(wc -l <"$CALLS")): $out"; fi

# ---- 18. unit check ---------------------------------------------------------------
reset_fix
runners org-runners "$(runner 1 box-01 online)"
printf '%s\n' 'do_check_gh_runner() { echo "FAIL box-01: Restart=no (not always)"; echo "CHECK gh-runner FAIL: 1 of 1"; return 1; }' >"$T/uc-fail.sh"
printf '%s\n' 'do_check_gh_runner() { echo "OK box-01: service active"; echo "CHECK gh-runner OK: 1 runner(s)"; }' >"$T/uc-ok.sh"
out="$(GH_RUNNER_HEALTH_UNIT_CHECK=1 GH_RUNNER_HEALTH_UNIT_CHECK_SH="$T/uc-fail.sh" check)"; rc1=$?
out2="$(GH_RUNNER_HEALTH_UNIT_CHECK=1 GH_RUNNER_HEALTH_UNIT_CHECK_SH="$T/uc-ok.sh" check)"; rc2=$?
if ((rc1 == 1 && rc2 == 0)) && grep -q 'PLAN note.*gh-unit-check FAIL box-01: Restart=no' <<<"$out" && grep -q '^gh-unit-check OK box-01' <<<"$out2"; then
  pass "18. unit check: FAIL is an alert, OK is not"
else fail "18. unit check (rc1=$rc1 rc2=$rc2): $out | $out2"; fi
default_sh="$(sed -n 's/.*GH_RUNNER_HEALTH_UNIT_CHECK_SH:-\${PROJ_PATH:-\.}\/\(\.\.\/[^}]*\)}.*/\1/p' "$FUNC_SH" | head -1)"
if [[ -n "$default_sh" && -f "$UTL_ROOT/$default_sh" ]] && grep -q '^do_check_gh_runner()' "$UTL_ROOT/$default_sh"; then
  pass "18b. the default unit check path ($default_sh) is csi-spl-orc's do_check_gh_runner"
else fail "18b. default unit check path '$default_sh' does not hold do_check_gh_runner"; fi

# ---- 19. live guard -----------------------------------------------------------------
if [[ ! -s "$LIVE_LOG" ]]; then pass "19. LIVE GUARD: no real gh, no spool-send.sh outside the temp dir"
else fail "19. LIVE GUARD: $(cat "$LIVE_LOG")"; fi

echo "gh-runner-health: $fails failure(s)"
((fails == 0))
