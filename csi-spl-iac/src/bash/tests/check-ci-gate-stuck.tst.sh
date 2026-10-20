#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_ci_gate_stuck sends ONE blocker per gate run with a job
#          queued over CI_GATE_STUCK_MIN, and do_cancel_ci_gate_run cancels one
#          run by id (c-001@sat note 4cbf224a: wf 10 push run 39281262959 sat
#          queued 9 h). Hermetic: `gh` is stubbed with canned API JSON (its
#          --jq runs through real jq), the sender is a stub that logs each send.
#   1. a run whose job is queued 61 min (limit 60) -> 1 blocker to the holder
#      on task dispatch-ci-red naming the run, its sha, the job, its runner
#      labels, the wait and the cancel action with the run id
#   2. three ticks of the same stuck run -> still 1 send
#   3. a job queued 59 min, a running job, a finished run -> nothing
#   4. a second stuck run -> 2 sends in all
#   5. the holder on another box -> nothing sent
#   6. the cancel action: a queued wf 10 run -> `gh run cancel <id>`
#   7. a run of another workflow -> refused (rc 2), no cancel
#   8. a finished run -> rc 0, no cancel
#   9. no run id / not digits -> rc 2, no gh call
#   CONTROL a. the state file wiped before every tick -> 3 sends for 3 ticks,
#              so check 2 FAILS without the run-id key
#   CONTROL b. CI_GATE_STUCK_MIN=58 -> the 59-min job alarms, so check 3 is
#              held by the limit, not by a job the reader never saw
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-ci-gate-stuck.func.sh"
CANCEL="$PROJ_ROOT/src/bash/run/cancel-ci-gate-run.func.sh"
NOTE="$PROJ_ROOT/src/bash/run/report-ci-red-note.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
require_action "$FUNC"
require_action "$CANCEL"

R="$T/repo"; mkdir -p "$R"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
git -C "$R" init -q

mkdir -p "$T/stub" "$T/api"
cat >"$T/stub/gh" <<'STUB'
#!/usr/bin/env bash
args=("$@"); jqf=""
echo "gh $*" >>"$GH_STUB_DIR/calls"
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == "--jq" ]] && jqf="${args[i+1]}"; done
src=""
case "${args[0]} ${args[1]:-}" in
  "run list") src="$GH_STUB_DIR/runs.json" ;;
  "run cancel") exit 0 ;;
  api\ */runs/*/jobs) src="$GH_STUB_DIR/jobs-$(sed 's|.*/runs/\([0-9]*\)/jobs|\1|' <<<"${args[1]}").json" ;;
  api\ */runs/*) src="$GH_STUB_DIR/run-${args[1]##*/}.json" ;;
esac
[[ -f "$src" ]] || { echo "gh: stub has no canned $src" >&2; exit 1; }
if [[ -n "$jqf" ]]; then jq -r "$jqf" "$src"; else cat "$src"; fi
STUB
cat >"$T/stub/send" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in --from) f=${args[i+1]} ;; --to) t=${args[i+1]} ;; --kind) k=${args[i+1]} ;; --task) s=${args[i+1]} ;; --body) b=${args[i+1]} ;; esac
done
{ echo "SEND from=$f to=$t kind=$k task=$s"; echo "$b"; } >>"$CGS_SENT"
STUB
chmod +x "$T/stub/gh" "$T/stub/send"

NOW=$(date -u -d 2026-10-20T02:00:00Z +%s)
ago() { date -u -d "@$((NOW - $1 * 60))" +%Y-%m-%dT%H:%M:%SZ; }
runs() { printf '[%s]\n' "$(IFS=,; echo "$*")" >"$T/api/runs.json"; }
row() { printf '{"databaseId":%s,"status":"%s","headSha":"%s","url":"https://example.com/runs/%s"}' "$1" "$2" "$3" "$1"; }
jobs() { local id=$1; shift; printf '{"jobs":[%s]}\n' "$(IFS=,; echo "$*")" >"$T/api/jobs-$id.json"; }
job() { printf '{"name":"%s","status":"%s","created_at":"%s","labels":["self-hosted","spool-ci"]}' "$1" "$2" "$(ago "$3")"; }

# 970 queued 61 min (stuck), 971 queued 59 min, 972 running, 973 finished
jobs 970 "$(job "orc: hermetic action tests 1/3" queued 61)" "$(job "classify" completed 70)"
jobs 971 "$(job "hub: go test" queued 59)"
jobs 972 "$(job "wui: e2e 1/8" in_progress 90)"
jobs 973 "$(job "iac: tests" queued 120)"
runs "$(row 970 queued aaa970)" "$(row 971 queued aaa971)" "$(row 972 in_progress aaa972)" "$(row 973 completed aaa973)"

export CGS_SENT="$T/sent"; : >"$CGS_SENT"
STATE="$T/state.tsv"
tick() {
  ( cd "$R" && env PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" CI_GATE_STUCK_STATE="$STATE" CI_GATE_STUCK_NOW="$NOW" \
      CI_GATE_STUCK_MIN="${MIN:-60}" CI_RED_NOTE_TO="${TO:-c-900@b1}" CI_RED_NOTE_BOX=b1 CI_RED_NOTE_SEND="$T/stub/send" \
      bash -c 'do_log() { echo "$*"; }; source "'"$NOTE"'"; source "'"$FUNC"'"; do_check_ci_gate_stuck' ) >"$T/out" 2>&1
}
sends() { grep -c '^SEND .*kind=blocker' "$CGS_SENT"; }

# --- 1 + 2. one stuck run over three ticks -> 1 send ------------------------
tick; tick; tick
if [[ "$(sends)" == 1 ]] && grep -qx 'SEND from=c-900 to=c-900@b1 kind=blocker task=dispatch-ci-red' "$CGS_SENT" \
   && grep -q '^## CI gate run stuck in the runner queue: 10_ci-quality.yml run 970$' "$CGS_SENT" \
   && grep -q 'Job `orc: hermetic action tests 1/3` has been queued for 61 min (over 60) on runners `self-hosted,spool-ci`' "$CGS_SENT" \
   && grep -q 'sha aaa970' "$CGS_SENT" && grep -qF 'CI_GATE_RUN_ID=970 ./run -a do_cancel_ci_gate_run' "$CGS_SENT"; then
  pass "1+2. three ticks of a run queued 61 min: 1 blocker to the holder with run, sha, job, labels, wait and the cancel action"
else
  fail "1+2. the stuck run was not sent exactly once ($(sends) sends)"; sed 's/^/    | /' "$CGS_SENT" "$T/out"
fi
# --- 3. under the limit, running, finished -> nothing ----------------------
if ! grep -qE 'run 97[123]$' "$CGS_SENT" && grep -q '1 run(s) with a job queued over 60 min' "$T/out"; then
  pass "3. a job queued 59 min, a running job and a finished run send nothing"
else
  fail "3. a run under the limit, running or finished was told"; sed 's/^/    | /' "$CGS_SENT" "$T/out"
fi
# --- CONTROL b. limit 58 -> the 59-min job alarms ---------------------------
: >"$CGS_SENT"; cp "$STATE" "$T/state.keep"
MIN=58 tick
if grep -q 'run 971$' "$CGS_SENT"; then
  pass "CONTROL b. limit 58: the 59-min job alarms, so check 3 is held by the limit"
else
  fail "CONTROL b. limit 58 did not alarm the 59-min job"; sed 's/^/    | /' "$CGS_SENT" "$T/out"
fi
cp "$T/state.keep" "$STATE"
# --- CONTROL a. state wiped every tick -> 3 sends ---------------------------
: >"$CGS_SENT"; cp "$STATE" "$T/state.keep"
for _ in 1 2 3; do : >"$STATE"; tick; done
if [[ "$(sends)" == 3 ]]; then
  pass "CONTROL a. the state wiped before every tick: 3 sends, so check 2 needs the run-id key"
else
  fail "CONTROL a. wiping the state did not resend ($(sends) sends): check 2 proves nothing"
fi
cp "$T/state.keep" "$STATE"
# --- 4. a second stuck run -> one more send ---------------------------------
: >"$CGS_SENT"
jobs 974 "$(job "wui: e2e 2/8" queued 75)"
runs "$(row 974 queued aaa974)" "$(row 970 queued aaa970)" "$(row 971 queued aaa971)"
tick; tick
if [[ "$(sends)" == 1 ]] && grep -q 'run 974$' "$CGS_SENT" && grep -q '2 run(s) with a job queued over 60 min, 0 told' "$T/out"; then
  pass "4. a second stuck run: one more send, the first run not told again (2 sends in all)"
else
  fail "4. the second stuck run: $(sends) new sends"; sed 's/^/    | /' "$CGS_SENT" "$T/out"
fi
# --- 5. the holder on another box -> nothing --------------------------------
: >"$CGS_SENT"; : >"$STATE"
TO=c-900@b2 tick
if [[ "$(sends)" == 0 ]] && grep -q 'not on this box' "$T/out"; then
  pass "5. the holder on another box: nothing sent from this box"
else
  fail "5. a box that is not the holder's sent $(sends)"; sed 's/^/    | /' "$T/out"
fi

# --- 6..9. the cancel action ------------------------------------------------
cancel() {
  : >"$T/api/calls"
  ( cd "$R" && env PATH="$T/stub:$PATH" GH_STUB_DIR="$T/api" CI_GATE_RUN_ID="$1" \
      bash -c 'do_log() { echo "$*"; }; source "'"$CANCEL"'"; do_cancel_ci_gate_run' ) >"$T/out" 2>&1
}
crun() { printf '{"path":".github/workflows/%s","status":"%s","head_sha":"aaa%s"}\n' "$2" "$3" "$1" >"$T/api/run-$1.json"; }
crun 980 10_ci-quality.yml queued
cancel 980; rc=$?
if [[ "$rc" == 0 ]] && grep -qx 'gh run cancel 980' "$T/api/calls"; then
  pass "6. a queued wf 10 run: gh run cancel 980, rc 0"
else
  fail "6. the queued run was not cancelled (rc $rc)"; sed 's/^/    | /' "$T/out" "$T/api/calls"
fi
crun 981 20_hub-deploy.yml queued
cancel 981; rc=$?
if [[ "$rc" == 2 ]] && ! grep -q 'run cancel' "$T/api/calls" && grep -q 'not 10_ci-quality.yml: refused' "$T/out"; then
  pass "7. a run of another workflow: refused, rc 2, no cancel"
else
  fail "7. another workflow's run was not refused (rc $rc)"; sed 's/^/    | /' "$T/out" "$T/api/calls"
fi
crun 982 10_ci-quality.yml completed
cancel 982; rc=$?
if [[ "$rc" == 0 ]] && ! grep -q 'run cancel' "$T/api/calls" && grep -q 'already finished' "$T/out"; then
  pass "8. a finished run: nothing to cancel, rc 0"
else
  fail "8. a finished run (rc $rc)"; sed 's/^/    | /' "$T/out" "$T/api/calls"
fi
cancel ""; rc1=$?; c1=$(wc -l <"$T/api/calls")
cancel "12;x"; rc2=$?; c2=$(wc -l <"$T/api/calls")
if [[ "$rc1" == 2 && "$rc2" == 2 && "$c1" == 0 && "$c2" == 0 ]]; then
  pass "9. no run id or a non-digit id: rc 2, no gh call"
else
  fail "9. a bad run id: rc $rc1/$rc2, gh calls $c1/$c2"
fi

[[ "$fails" -eq 0 ]] && echo "OK check-ci-gate-stuck: all checks passed" || { echo "FAILED: $fails"; exit 1; }
