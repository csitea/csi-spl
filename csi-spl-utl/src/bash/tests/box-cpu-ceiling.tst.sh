#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for do_box_cpu_ceiling (SPL-5698 step 2, spec 175 task 5.9): a
# fake systemctl that keeps each unit's CPUQuota in a fixture dir, a fixture
# cgroup tree and a fixture cnf; the live box and its units are never read or
# changed.
#   1. check, no ceiling yet: both units named with their throttled time,
#      exit 1, nothing set
#   2. apply dry run: the plan for each unit, nothing set
#   3. apply: CPUQuota = cores * cap_pct on each unit, persistent (no
#      --runtime), and nothing is stopped, restarted or killed
#   4. apply again changes nothing; check is OK
#   5. BOX_CPU_CAP_PCT over the cnf; a unit at another quota is set again
#   6. remove takes the ceiling off (CPUQuota=), check then fails
#   7. guards: a cap outside 50..100, a bad BOX_CPU_CMD, no agent user
#   8. the units by default: cron.service and user-<uid>.slice of the agent user
#   9. through the csi-spl-utl ./run harness (dry run)
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/box-cpu-ceiling.func.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# the fake systemctl: show -p CPUQuotaPerSecUSec / ControlGroup, set-property;
# every call is logged
mkdir -p "$T/units" "$T/cg/system.slice/cron.service" "$T/cg/user.slice/user-1001.slice"
printf 'usage_usec 9\nnr_throttled 7\nthrottled_usec 3000000\n' >"$T/cg/system.slice/cron.service/cpu.stat"
printf 'usage_usec 9\nnr_throttled 0\nthrottled_usec 0\n' >"$T/cg/user.slice/user-1001.slice/cpu.stat"
cat >"$T/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/calls"
case "$1" in
  show)
    u="$2"; p="$4"
    if [[ "$p" == ControlGroup ]]; then
      case "$u" in cron.service) echo /system.slice/cron.service ;; user-*.slice) echo "/user.slice/$u" ;; esac
    elif [[ -s "$FAKE_DIR/units/$u" ]]; then cat "$FAKE_DIR/units/$u"; else echo infinity; fi ;;
  set-property)
    v="${3#CPUQuota=}"
    if [[ -z "$v" ]]; then rm -f "$FAKE_DIR/units/$2"
    else awk -v p="${v%\%}" 'BEGIN { printf "%.6fs\n", p / 100 }' >"$FAKE_DIR/units/$2"; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/systemctl"
mkdir -p "$T/fake/csi-spl-utl" "$T/fake/csi-spl-cnf/csi-spl"
printf 'env:\n  box:\n    agent_load:\n      cap_pct: 85\n' >"$T/fake/csi-spl-cnf/csi-spl/all.env.yaml"

run_bc() {
  env PROJ_PATH="$T/fake/csi-spl-utl" FAKE_DIR="$T" BOX_CPU_SYSTEMCTL="$T/systemctl" \
    BOX_CPU_CGROUP_ROOT="$T/cg" BOX_CPU_NPROC=16 BOX_CPU_UNITS="cron.service user-1001.slice" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    source "'"$FUNC_SH"'"
    do_box_cpu_ceiling' 2>&1
}
sets() { grep -c '^set-property' "$T/calls" 2>/dev/null; }

# 1. check, no ceiling ---------------------------------------------------------
out="$(run_bc)"; rc=$?
[[ $rc == 1 && "$out" == *"CPUQuota=1360% per unit"* && "$out" == *"UNIT cron.service CPUQuota=none (7 throttles, 3 s throttled)"* &&
  "$out" == *"UNIT user-1001.slice CPUQuota=none (0 throttles, 0 s throttled)"* && "$out" == *"FAIL 2 unit(s)"* && "$(sets)" == 0 ]] &&
  pass "1. check without a ceiling: exit 1, both units named, nothing set" || fail "1. check (rc $rc): $out"

# 2. apply dry run -------------------------------------------------------------
out="$(run_bc BOX_CPU_CMD=apply)"; rc=$?
[[ $rc == 0 && "$out" == *"PLAN cron.service CPUQuota=1360%"* && "$out" == *"PLAN user-1001.slice CPUQuota=1360%"* &&
  "$out" == *"DRY_RUN nothing was touched"* && "$(sets)" == 0 ]] &&
  pass "2. apply DRY_RUN=1: the plan, nothing set" || fail "2. dry run (rc $rc): $out"

# 3. apply ---------------------------------------------------------------------
out="$(run_bc BOX_CPU_CMD=apply DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$(cat "$T/units/cron.service")" == 13.600000s && "$(cat "$T/units/user-1001.slice")" == 13.600000s &&
  "$out" == *"SET cron.service CPUQuota=1360%"* && "$out" == *"OK 2 unit(s) changed (apply)"* ]] &&
  pass "3. apply: CPUQuota=1360% (16 cores * 85 %) on both units" || fail "3. apply (rc $rc): $out"
grep -E 'runtime|stop|start|restart|kill|reload' "$T/calls" >/dev/null &&
  fail "3. apply ran: $(grep -E 'runtime|stop|start|restart|kill|reload' "$T/calls")" ||
  pass "3. apply is persistent (no --runtime) and stops, restarts or kills nothing"

# 4. idempotent ----------------------------------------------------------------
n="$(sets)"
out="$(run_bc BOX_CPU_CMD=apply DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"OK nothing to change"* && "$(sets)" == "$n" ]] &&
  pass "4. a second apply changes nothing" || fail "4. second apply (rc $rc): $out"
out="$(run_bc)"; rc=$?
[[ $rc == 0 && "$out" == *"OK every unit has the ceiling of 1360%"* ]] &&
  pass "4. check OK once applied" || fail "4. check (rc $rc): $out"

# 5. env over cnf --------------------------------------------------------------
out="$(run_bc BOX_CPU_CMD=apply DRY_RUN=0 BOX_CPU_CAP_PCT=50)"; rc=$?
[[ $rc == 0 && "$(cat "$T/units/cron.service")" == 8.000000s && "$out" == *"UNIT cron.service CPUQuota=1360% ("* ]] &&
  pass "5. BOX_CPU_CAP_PCT=50 beats the cnf, a unit at 1360% is set to 800%" || fail "5. env cap (rc $rc): $out"

# 6. remove --------------------------------------------------------------------
out="$(run_bc BOX_CPU_CMD=remove DRY_RUN=0)"; rc=$?
[[ $rc == 0 && ! -e "$T/units/cron.service" && ! -e "$T/units/user-1001.slice" && "$(grep -c "^set-property .* CPUQuota=$" "$T/calls")" == 2 ]] &&
  pass "6. remove: CPUQuota= on both units" || fail "6. remove (rc $rc): $out"
out="$(run_bc)"; rc=$?
[[ $rc == 1 ]] && pass "6. check fails after the remove" || fail "6. check after remove (rc $rc): $out"

# 7. guards --------------------------------------------------------------------
n="$(sets)"
out="$(run_bc BOX_CPU_CMD=apply DRY_RUN=0 BOX_CPU_CAP_PCT=40)"; rc=$?
[[ $rc == 1 && "$out" == *"must be 50..100"* && "$(sets)" == "$n" ]] &&
  pass "7. a cap of 40 is refused, nothing set" || fail "7. cap 40 (rc $rc): $out"
out="$(run_bc BOX_CPU_CMD=nuke)"; rc=$?
[[ $rc == 1 && "$out" == *"BOX_CPU_CMD must be"* ]] && pass "7. a bad BOX_CPU_CMD is refused" || fail "7. bad cmd (rc $rc): $out"
out="$(run_bc BOX_CPU_UNITS= SPOOL_AGENT_USER= BOX_CPU_AGENT_USER= SPOOL_ROOT="$T/none")"; rc=$?
[[ $rc == 1 && "$out" == *"no agent user"* ]] && pass "7. no agent user: refused" || fail "7. no agent user (rc $rc): $out"

# 8. default units ---------------------------------------------------------------
me="$(id -un)" uid="$(id -u)"
out="$(run_bc BOX_CPU_UNITS= BOX_CPU_AGENT_USER="$me")"
[[ "$out" == *"UNIT cron.service "* && "$out" == *"UNIT user-$uid.slice "* ]] &&
  pass "8. default units: cron.service and user-$uid.slice" || fail "8. default units: $out"
mkdir -p "$T/sr" && echo "SPOOL_AGENT_USER=$me" >"$T/sr/box.env"
out="$(run_bc BOX_CPU_UNITS= SPOOL_AGENT_USER= BOX_CPU_AGENT_USER= SPOOL_ROOT="$T/sr")"
[[ "$out" == *"UNIT user-$uid.slice "* ]] && pass "8. the agent user from \$SPOOL_ROOT/box.env" || fail "8. box.env user: $out"

# 9. ./run harness ---------------------------------------------------------------
n="$(sets)"
out="$(cd "$UTL_ROOT" && env FAKE_DIR="$T" BOX_CPU_SYSTEMCTL="$T/systemctl" BOX_CPU_CGROUP_ROOT="$T/cg" \
  BOX_CPU_UNITS="cron.service user-1001.slice" BOX_CPU_CAP_PCT=85 BOX_CPU_CMD=apply SPOOL_TEST=1 ./run -a do_box_cpu_ceiling 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == *"PLAN cron.service"* && "$(sets)" == "$n" ]] &&
  pass "9. ./run -a do_box_cpu_ceiling: dry run, exit 0, nothing set" || fail "9. harness (rc $rc): $out"

echo
((fails == 0)) && { echo "ALL PASS"; exit 0; }
echo "$fails FAIL"; exit 1
