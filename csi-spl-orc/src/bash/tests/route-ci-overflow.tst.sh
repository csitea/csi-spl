#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_route_ci_overflow points wf 10 (repo variable SPOOL_CI_RUNNER)
#   at the local runners only while the GitHub-hosted ones are overwhelmed,
#   and back with hysteresis (owner HUM-10, t1 f67e3656 msgs d4ba4b17,
#   70480eb3, 61cd35bc); do_setup_ci_overflow_cron installs its cron line.
#   1. bad settings are refused; a variable that does not read changes nothing
#   2. hosted: a hosted job queued >= enter_queue_min -> local (since kept);
#      under it, or only self-hosted jobs queued -> no change; DRY_RUN sets
#      nothing; a failing runs query changes nothing
#   3. local: held < hold_min -> stays; held >= hold_min and hosted wait <
#      exit_queue_min -> hosted (since removed); held but hosted still
#      waiting -> stays (the hysteresis)
#   4. switched off (env, hub fleet-load ci_overflow false, cnf): hosted at
#      once with no runs query; the hub's true beats cnf false
#   5. the cron script runs the action with DRY_RUN=0, refuses a worktree;
#      the installer writes ONE */5 tagged line, keeps the others, removes it
#   No real gh, crontab or hub: stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/route-ci-overflow.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$FUNC" || { echo "FAIL: bash -n"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx"
export T

# gh stub: fixtures under $T/fx, --jq applied with jq like gh does
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$T/gh.calls"
url="$2" q=""
[[ "${3:-}" == --jq ]] && q="$4"
case "$url" in
  */actions/variables/SPOOL_CI_RUNNER)
    [[ "${GH_VAR_FAIL:-0}" == 1 ]] && { echo "gh: boom (HTTP 500)"; exit 1; }
    [[ -s "$T/var" ]] || { echo "gh: Not Found (HTTP 404)"; exit 1; }
    f="$T/fx/var.json"; printf '{"value":%s}\n' "$(jq -Rs 'rtrimstr("\n")' "$T/var")" >"$f" ;;
  *runs\?status=*)
    [[ "${GH_RUNS_FAIL:-0}" == 1 ]] && exit 1
    st="${url#*status=}"; st="${st%%&*}"; f="$T/fx/runs-$st.json"; [[ -s "$f" ]] || echo '{"workflow_runs":[]}' >"$f" ;;
  */jobs\?*)
    id="${url%/jobs*}"; id="${id##*/}"; f="$T/fx/jobs-$id.json" ;;
  *) exit 1 ;;
esac
if [[ -n "$q" ]]; then jq -r "$q" "$f"; else cat "$f"; fi
EOF
printf '#!/usr/bin/env bash\n[[ "$*" == "fleet-load get" ]] || exit 1\ncat "$T/hub.json"\n' >"$T/bin/hubstub"
chmod +x "$T/bin/"*
printf 'env:\n  box:\n    ci_overflow:\n      enabled: true\n      cap_pct: 25\n      cpus: 0\n      enter_queue_min: 10\n      exit_queue_min: 3\n      hold_min: 30\n' >"$T/cnf.yaml"

ago() { date -u -d "@$(($(date +%s) - $1 * 60))" +%Y-%m-%dT%H:%M:%SZ; }
# runs <queued ids> / <in_progress ids>; job <run id> <label> <status> <min ago>...
runs() {
  local st=$1 i ids=""; shift
  for i in "$@"; do ids+="{\"id\":$i},"; done
  echo "{\"workflow_runs\":[${ids%,}]}" >"$T/fx/runs-$st.json"
}
jobs() {
  local id=$1 j=""; shift
  while (($#)); do j+="{\"status\":\"$2\",\"labels\":[\"$1\"],\"created_at\":\"$(ago "$3")\"},"; shift 3; done
  echo "{\"jobs\":[${j%,}]}" >"$T/fx/jobs-$id.json"
}
clear_fx() { rm -f "$T/fx/"*; }
route() {
  rm -f "$T/gh.calls" "$T/set.log"
  env PATH="$T/bin:$PATH" CI_OVERFLOW_GH="$T/bin/gh" CI_OVERFLOW_CNF="$T/cnf.yaml" CI_OVERFLOW_STATE_DIR="$T/state" \
    SPOOL_ROOT="$T/spool" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    spl_desk_box_default() { echo sat; }
    do_gh_set_ci_vars() { echo "set $SPOOL_CI_RUNNER dry=$DRY_RUN" >>"$T/set.log"; [[ "$DRY_RUN" == 0 ]] && printf "%s\n" "$SPOOL_CI_RUNNER" >"$T/var"; return 0; }
    source "'"$FUNC"'"
    do_route_ci_overflow'
}
HOSTED='"ubuntu-latest"' LOCAL='["self-hosted","spool-ci"]'
setlog() { cat "$T/set.log" 2>/dev/null; }

# 1. refusals -------------------------------------------------------------------
for bad in DRY_RUN=2 CI_OVERFLOW_MAX_RUNS=0 CI_OVERFLOW_ENABLED=maybe CI_OVERFLOW_HOLD_MIN=x CI_OVERFLOW_CAP_PCT=40; do
  out="$(route "$bad")"; rc=$?
  [[ $rc -ne 0 && "$out" == *FATAL* && -z "$(setlog)" ]] && pass "$bad is refused" || fail "$bad (rc=$rc): $out"
done
echo "$HOSTED" >"$T/var"
out="$(route DRY_RUN=0 GH_VAR_FAIL=1)"; rc=$?
[[ $rc -ne 0 && "$out" == *'SPOOL_CI_RUNNER does not read: nothing changed'* && -z "$(setlog)" ]] &&
  pass "the variable does not read: exit 1, nothing set" || fail "var fail (rc=$rc): $out"

# 2. hosted -> local ------------------------------------------------------------------
clear_fx; runs queued 11; runs in_progress 12
jobs 11 ubuntu-latest queued 12
jobs 12 ubuntu-latest completed 40 ubuntu-latest queued 4
out="$(route)"; rc=$?
[[ $rc -eq 0 && "$out" == *"ROUTE SPOOL_CI_RUNNER $HOSTED -> $LOCAL: a hosted job queued 12 min (>= 10): overflow"* && "$(setlog)" == "set $LOCAL dry=1" && "$(cat "$T/var")" == "$HOSTED" && ! -e "$T/state/since" ]] &&
  pass "dry run: a hosted job queued 12 min -> plans local, sets nothing" || fail "dry enter (rc=$rc): $out / $(setlog)"
[[ "$(grep -c 'actions/runs?status=' "$T/gh.calls")" == 2 && "$(grep -c '/jobs?' "$T/gh.calls")" == 2 ]] &&
  pass "the measure: 2 runs queries (queued, in_progress) + 1 jobs query per run" || fail "calls: $(cat "$T/gh.calls")"
out="$(route DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/var")" == "$LOCAL" && -s "$T/state/since" && "$out" == *"OK SPOOL_CI_RUNNER is $LOCAL"* ]] &&
  pass "apply: SPOOL_CI_RUNNER -> local runners, since kept" || fail "enter (rc=$rc): $out"
echo "$HOSTED" >"$T/var"; rm -rf "$T/state"
jobs 11 ubuntu-latest queued 9
out="$(route DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && -z "$(setlog)" && "$out" == *'hosted wait 9 min (< 10): stay hosted'* ]] &&
  pass "hosted wait 9 min: stays hosted" || fail "under enter (rc=$rc): $out"
jobs 11 self-hosted queued 50
out="$(route DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && -z "$(setlog)" && "$out" == *'hosted wait 4 min'* ]] &&
  pass "a self-hosted job queued 50 min does not count as hosted overwhelm" || fail "self-hosted (rc=$rc): $out"
jobs 11 ubuntu-latest queued 30
out="$(route DRY_RUN=0 GH_RUNS_FAIL=1)"; rc=$?
[[ $rc -ne 0 && -z "$(setlog)" && "$out" == *'query failed: nothing changed'* ]] &&
  pass "a failing runs query: exit 1, nothing changed" || fail "runs fail (rc=$rc): $out"
out="$(route DRY_RUN=0 CI_OVERFLOW_MAX_RUNS=1)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '/jobs?' "$T/gh.calls")" == 1 ]] &&
  pass "CI_OVERFLOW_MAX_RUNS=1 bounds the jobs queries" || fail "max runs (rc=$rc): $(cat "$T/gh.calls")"

# 3. local -> hosted (hysteresis) ---------------------------------------------------------
clear_fx; echo "$LOCAL" >"$T/var"; mkdir -p "$T/state"
echo $(($(date +%s) - 10 * 60)) >"$T/state/since"
out="$(route DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && -z "$(setlog)" && "$out" == *'local for 10 min of 30'* ]] &&
  pass "local for 10 of 30 min, nothing waiting: stays local" || fail "hold (rc=$rc): $out"
echo $(($(date +%s) - 31 * 60)) >"$T/state/since"
runs in_progress 21; jobs 21 ubuntu-latest queued 5
out="$(route DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && -z "$(setlog)" && "$out" == *'hosted wait 5 min (exit < 3): stay local'* ]] &&
  pass "held 31 min but a hosted job (another workflow) waits 5 min: stays local" || fail "hyst (rc=$rc): $out"
jobs 21 ubuntu-latest queued 1
out="$(route DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/var")" == "$HOSTED" && ! -e "$T/state/since" && "$out" == *'back to hosted'* ]] &&
  pass "held 31 min, hosted wait 1 min: back to hosted, since removed" || fail "exit (rc=$rc): $out"
clear_fx; : >"$T/var"; rm -rf "$T/state"
out="$(route DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'SPOOL_CI_RUNNER <unset> -> '"$LOCAL"': local for 0 min of 30'* && -s "$T/state/since" ]] &&
  pass "variable unset (wf 10 runs local): counted as local, the hold starts now" || fail "unset (rc=$rc): $out"

# 4. switched off --------------------------------------------------------------------------
echo "$LOCAL" >"$T/var"
out="$(route DRY_RUN=0 CI_OVERFLOW_ENABLED=false)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/var")" == "$HOSTED" && "$(grep -c 'actions/runs' "$T/gh.calls")" == 0 && "$out" == *'overflow switched off (enabled from env'* ]] &&
  pass "switched off: hosted at once, no runs query" || fail "off (rc=$rc): $out"
echo "$LOCAL" >"$T/var"; echo '{"ci_overflow":false}' >"$T/hub.json"
out="$(route DRY_RUN=0 LANE_FLEET=csi LANE_HUB_CMD="$T/bin/hubstub")"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/var")" == "$HOSTED" && "$out" == *'enabled from hub'* ]] &&
  pass "the workspace admin's ci_overflow false (hub) switches it off" || fail "hub off (rc=$rc): $out"
sed 's/enabled: true/enabled: false/' "$T/cnf.yaml" >"$T/cnf-off.yaml"
echo "$LOCAL" >"$T/var"
out="$(route DRY_RUN=0 CI_OVERFLOW_CNF="$T/cnf-off.yaml")"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/var")" == "$HOSTED" && "$out" == *'enabled from cnf'* ]] &&
  pass "cnf enabled: false switches it off" || fail "cnf off (rc=$rc): $out"
echo '{"ci_overflow":true}' >"$T/hub.json"; echo "$HOSTED" >"$T/var"
out="$(route DRY_RUN=0 CI_OVERFLOW_CNF="$T/cnf-off.yaml" LANE_FLEET=csi LANE_HUB_CMD="$T/bin/hubstub")"; rc=$?
[[ $rc -eq 0 && "$out" == *'stay hosted'* ]] && pass "the hub's ci_overflow true beats cnf false" || fail "hub on (rc=$rc): $out"

# 5. cron script + installer -----------------------------------------------------------
SH="$T/shared"
mkdir -p "$SH/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/ci-overflow-cron.sh" "$SH/csi-spl-orc/src/bash/scripts/"
printf '#!/usr/bin/env bash\nprintf "DRY_RUN=%%s args=%%s\\n" "${DRY_RUN:-}" "$*" >>"%s/calls"\nexit "${RUN_RC:-0}"\n' "$T" >"$SH/csi-spl-orc/run"
chmod +x "$SH/csi-spl-orc/run" "$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh"
out="$(bash "$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls")" == "DRY_RUN=0 args=-a do_route_ci_overflow" ]] &&
  pass "the cron script runs the action with DRY_RUN=0" || fail "cron run (rc=$rc): $out"
out="$(RUN_RC=1 bash "$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *'FAIL CI overflow route rc=1'* ]] && pass "a failed route: exit 1" || fail "cron fail (rc=$rc): $out"
printf '#!/usr/bin/env bash\necho "token=${GH_TOKEN:-unset}" >"%s/tok"\n' "$T" >"$SH/csi-spl-orc/run"
echo tok-from-file >"$T/token"
out="$(env -u GH_TOKEN GH_CONFIG_DIR="$T/nogh" CI_OVERFLOW_GH_TOKEN_FILE="$T/token" bash "$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/tok")" == token=tok-from-file ]] &&
  pass "gh not logged in: the cron script gives the action GH_TOKEN from the token file" || fail "token file (rc=$rc): $out / $(cat "$T/tok" 2>&1)"
out="$(GH_TOKEN=set-before GH_CONFIG_DIR="$T/nogh" CI_OVERFLOW_GH_TOKEN_FILE="$T/token" bash "$SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/tok")" == token=set-before ]] &&
  pass "a GH_TOKEN already set is kept" || fail "token kept (rc=$rc): $out / $(cat "$T/tok" 2>&1)"
WT="$T/csi-spl-wt/c-9"; mkdir -p "$WT"; cp -a "$SH/csi-spl-orc" "$WT/"
out="$(bash "$WT/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *'agent worktree'* ]] && pass "an agent worktree is refused" || fail "worktree (rc=$rc): $out"

printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
printf '%s\n' '# keep me' '*/5 * * * * /x/box-stats-cron.sh >> /l/cron.out 2>&1 # csi-spl:box-stats' >"$T/crontab"
cp "$T/crontab" "$T/crontab.orig"
setup() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
    DESK_CRON_SRC="$SH" CI_OVERFLOW_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/setup-ci-overflow-cron.func.sh"
    do_setup_ci_overflow_cron'
}
want="*/5 * * * * $SH/csi-spl-orc/src/bash/scripts/ci-overflow-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:ci-overflow"
out="$(setup)"; rc=$?
[[ $rc -eq 0 && "$out" == *'DRY_RUN nothing was touched'* && "$out" == *"+$want"* ]] && cmp -s "$T/crontab" "$T/crontab.orig" &&
  pass "dry run: prints the every-5-minutes line, writes nothing" || fail "install dry (rc=$rc): $out"
out="$(setup DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1 && "$(head -2 "$T/crontab")" == "$(cat "$T/crontab.orig")" ]] &&
  pass "install: ONE tagged line, every other line kept" || fail "install (rc=$rc): $out / $(cat "$T/crontab")"
out="$(setup DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c 'csi-spl:ci-overflow$' "$T/crontab")" -eq 1 ]] && pass "install twice = one line" || fail "reinstall: $(cat "$T/crontab")"
out="$(setup CI_OVERFLOW_CRON_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *'is installed'* ]] && pass "check: installed" || fail "check (rc=$rc): $out"
out="$(setup DRY_RUN=0 CI_OVERFLOW_CRON_ACTION=remove)"; rc=$?
cmp -s "$T/crontab" "$T/crontab.orig" && [[ $rc -eq 0 ]] && pass "remove takes only its own line" || fail "remove (rc=$rc): $(cat "$T/crontab")"

echo
if [ "$fails" -eq 0 ]; then echo "route-ci-overflow: all passed"; exit 0; fi
echo "route-ci-overflow: $fails FAILED"; exit 1
