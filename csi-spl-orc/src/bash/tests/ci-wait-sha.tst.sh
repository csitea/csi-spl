#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_ci_wait_sha waits for one commit's CI at ONE GitHub call per tick
#   (SPL-6502: the fleet's agents share one account's 5000 REST calls/h).
#   1. bad settings are refused with no call (interval < 30, junk, unknown sha)
#   2. green: every call is actions/runs?head_sha=<full sha>, never jobs or
#      annotations; done only on the second tick that sees every run completed
#   3. a run that appears after the others completed (workflow_run) is waited for
#   4. a red conclusion exits 1 and prints the runs; skipped/neutral are green
#   4b. only push/workflow_run runs count (CI_WAIT_EVENTS); a scheduled red
#      run that shares the head_sha is not the lane's
#   5. no run at all exits 2 after CI_WAIT_NORUN_MIN
#   6. a failed call is a WARN and the next tick retries; the timeout exits 4
#   7. COUNTING: one hour of a run that never ends costs 60 calls at the default
#      interval, against the measured `gh run watch` cost (GH_DEBUG=api,
#      2026-11-25: 69 REST calls in 60 s at --interval 10 on a 28-job wf 10 run,
#      = 4140/h; gh's default --interval 3 costs more)
#   No real gh, no sleep: stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/ci-wait-sha.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx" "$T/repo"
export T

# gh stub: the n-th call prints fixture n (else the last one), or fails on n.fail
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$T/gh.calls"
n=$(wc -l <"$T/gh.calls")
[[ -e "$T/fx/$n.fail" ]] && { echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1; }
f="$T/fx/$n.tsv"; [[ -e "$f" ]] || f="$(ls "$T"/fx/*.tsv 2>/dev/null | sort -V | tail -1)"
[[ -n "$f" ]] && cat "$f"
exit 0
EOF
printf '#!/usr/bin/env bash\necho "$1" >>"$T/sleeps"\n' >"$T/bin/sleep"
chmod +x "$T/bin/"*
git -C "$T/repo" init -q && git -C "$T/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
FULL=$(git -C "$T/repo" rev-parse HEAD)

# fx <tick> <id|name|status|conclusion[|event, default push]>... ; an empty list = no run yet
fx() { local n=$1 r; shift; : >"$T/fx/$n.tsv"; for r in "$@"; do e=""; IFS='|' read -r a b c d e <<<"$r"; printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d" "${e:-push}" >>"$T/fx/$n.tsv"; done; }
reset_fx() { rm -f "$T/fx/"* "$T/gh.calls" "$T/sleeps"; }
wait_sha() {
  (cd "$T/repo" && env CI_WAIT_GH="$T/bin/gh" CI_WAIT_SLEEP="$T/bin/sleep" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    source "'"$FUNC"'"
    do_ci_wait_sha')
}
calls() { [[ -e "$T/gh.calls" ]] && wc -l <"$T/gh.calls" || echo 0; }

# 1. refusals --------------------------------------------------------------------
for bad in CI_WAIT_INTERVAL=3 CI_WAIT_INTERVAL=x CI_WAIT_TIMEOUT_MIN=-1 SHA=nosuchsha 'CI_WAIT_EVENTS=push;x'; do
  reset_fx; out="$(wait_sha "$bad")"; rc=$?
  [[ $rc -eq 1 && "$out" == *FATAL* && "$(calls)" -eq 0 ]] && pass "$bad is refused, no call" || fail "$bad (rc=$rc calls=$(calls)): $out"
done

# 2. green, one call per tick, the right endpoint only ----------------------------
reset_fx
fx 1 '11|ci: quality gate|in_progress|' '12|cd: build|queued|'
fx 2 '11|ci: quality gate|completed|success' '12|cd: build|completed|skipped'
out="$(wait_sha SHA="${FULL:0:9}")"; rc=$?
[[ $rc -eq 0 && "$(calls)" -eq 3 && "$out" == *"11 ci: quality gate success"* && "$out" == *"12 cd: build skipped"* ]] &&
  pass "green after the second completed tick: 3 calls" || fail "green (rc=$rc calls=$(calls)): $out"
bad_calls="$(grep -cv "^gh api repos/{owner}/{repo}/actions/runs?head_sha=$FULL&per_page=100 --jq " "$T/gh.calls")"
[[ "$bad_calls" -eq 0 ]] && pass "every call is runs?head_sha=<full sha>" || fail "other calls: $(cat "$T/gh.calls")"
grep -qE 'jobs|annotations|check-runs' "$T/gh.calls" && fail "a jobs/annotations call" || pass "no jobs or annotations call"
[[ "$(sort -u "$T/sleeps")" == 60 && $(wc -l <"$T/sleeps") -eq 2 ]] && pass "60 s between ticks" || fail "sleeps: $(paste -sd' ' "$T/sleeps")"
reset_fx; fx 1 '11|w|completed|success'
out="$(wait_sha CI_WAIT_REPO=o/r)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "repos/o/r/actions/runs?head_sha=$FULL" "$T/gh.calls" && pass "CI_WAIT_REPO names the repo" || fail "repo (rc=$rc): $(cat "$T/gh.calls")"

# 3. a run triggered after the others completed is waited for ---------------------
reset_fx
fx 1 '11|a|completed|success'
fx 2 '11|a|completed|success' '13|deploy|queued|'
fx 3 '11|a|completed|success' '13|deploy|completed|failure'
out="$(wait_sha)"; rc=$?
[[ $rc -eq 1 && "$(calls)" -eq 4 && "$out" == *"13 deploy failure"* && "$out" == *"ended red"* ]] &&
  pass "a later triggered run is waited for, and its red counts" || fail "triggered (rc=$rc calls=$(calls)): $out"

# 4. red and neutral ---------------------------------------------------------------
reset_fx; fx 1 '11|a|completed|neutral' '12|b|completed|cancelled'
out="$(wait_sha)"; rc=$?
[[ $rc -eq 1 && "$out" == *"12 b cancelled"* ]] && pass "cancelled is red" || fail "cancelled (rc=$rc): $out"
reset_fx; fx 1 '11|a|completed|neutral'
out="$(wait_sha)"; rc=$?
[[ $rc -eq 0 ]] && pass "neutral is green" || fail "neutral (rc=$rc): $out"

# 4b. events: a scheduled/dispatched run on the sha is not the lane's -----------------
reset_fx; fx 1 '11|a|completed|success' '14|40 cd: reconcile|completed|failure|schedule' '15|12 rerun|completed|skipped|workflow_run' '16|x|in_progress||workflow_dispatch'
out="$(wait_sha)"; rc=$?
[[ $rc -eq 0 && "$out" != *reconcile* && "$out" == *"15 12 rerun skipped"* ]] && pass "schedule/dispatch runs are ignored, workflow_run counts" || fail "events (rc=$rc): $out"
reset_fx; fx 1 '14|40 cd: reconcile|completed|failure|schedule'
out="$(wait_sha CI_WAIT_EVENTS=push,schedule)"; rc=$?
[[ $rc -eq 1 && "$out" == *"14 40 cd: reconcile failure"* ]] && pass "CI_WAIT_EVENTS widens the set" || fail "events widen (rc=$rc): $out"

# 5. no run ------------------------------------------------------------------------
reset_fx; fx 1
out="$(wait_sha CI_WAIT_NORUN_MIN=3)"; rc=$?
[[ $rc -eq 2 && "$(calls)" -eq 3 && "$out" == *"no CI run"* ]] && pass "no run: exit 2 after 3 min, 3 calls" || fail "no run (rc=$rc calls=$(calls)): $out"

# 6. a failed call retries; timeout ---------------------------------------------------
reset_fx; touch "$T/fx/1.fail"; fx 2 '11|a|completed|success'
out="$(wait_sha)"; rc=$?
[[ $rc -eq 0 && "$out" == *WARN* && "$(calls)" -eq 3 ]] && pass "a failed call is a WARN, the next tick retries" || fail "retry (rc=$rc calls=$(calls)): $out"
reset_fx; fx 1 '11|a|in_progress|'
out="$(wait_sha CI_WAIT_TIMEOUT_MIN=5)"; rc=$?
[[ $rc -eq 4 && "$(calls)" -eq 5 && $(wc -l <"$T/sleeps") -eq 4 ]] && pass "timeout: exit 4 after 5 ticks, no sleep after the last" || fail "timeout (rc=$rc calls=$(calls)): $out"

# 7. counting: calls per hour, before and after ---------------------------------------
BEFORE_PER_HOUR=4140   # measured gh run watch --interval 10, 28-job run: 69 calls / 60 s
for iv in 60 30; do
  reset_fx; fx 1 '11|a|in_progress|'
  wait_sha CI_WAIT_TIMEOUT_MIN=60 CI_WAIT_INTERVAL=$iv >/dev/null; n=$(calls)
  [[ "$n" -eq $((3600 / iv)) ]] && pass "interval ${iv}s: $n calls in one hour (gh run watch measured: $BEFORE_PER_HOUR)" ||
    fail "interval ${iv}s: $n calls in one hour, want $((3600 / iv))"
done
(( 3600 / 60 * 50 <= BEFORE_PER_HOUR )) && pass "default saves >= 98 % per watched sha" || fail "saving"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
