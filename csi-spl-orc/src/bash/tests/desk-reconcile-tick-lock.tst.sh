#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: desk-reconcile-cron.sh runs ONE tick per env at a time (SPL-3287).
#          2026-10-25 on a satellite box (load 103..125 on 16 CPUs) a tick ran
#          over 10 min and the */3 crontab stacked 5 ticks of the same env, each
#          slowing the others. ./run is a stub: do_spl_desk_up_all records the
#          env, starts a detached "sidecar" (sleep) and works for a few seconds;
#          the trunk check and every other step are off.
#   1. two dev ticks started together: exactly one does the work, the other
#      exits 0 with "INFO tick skipped: the dev tick from <pid> still runs"
#      naming the working tick's pid
#   2. a dev and a prd tick together: both do the work
#   3. the next dev tick after the first ended runs, although the detached
#      sidecar the first one started still lives: the lock is not left on an
#      fd a child inherited
# DESK_TICK_SCRIPT runs the cases on another copy of the script (the red
# control: origin/master's script fails 1, both ticks work).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
sidecars=()
cleanup() {
  local p
  for p in "${sidecars[@]}"; do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

O="$T/checkout/$(basename "$PROJ_ROOT")"
mkdir -p "$O/src/bash/scripts"
cp "${DESK_TICK_SCRIPT:-$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh}" "$O/src/bash/scripts/desk-reconcile-cron.sh" || { echo "FAIL: cannot copy the script under test"; exit 1; }
: >"$T/sidecars"
cat >"$O/run" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *do_spl_desk_up_all*)
    echo "\$ENV \$PPID" >>"$T/work"
    setsid sleep 60 </dev/null >/dev/null 2>&1 &
    echo \$! >>"$T/sidecars"
    sleep "\${STUB_WORK_SECS:-3}" ;;
esac
exit 0
STUB
chmod +x "$O/run" "$O/src/bash/scripts/desk-reconcile-cron.sh"

tick() {
  env -u TENANT_ID SPOOL_ROOT="$T/spool" HOME="$T" DESK_CRON_STATE_DIR="$T/state" DESK_CRON_TOOLS="flock tail" \
    DESK_TRUNK_CHECK=0 DESK_LEASE=0 DESK_SETTINGS_CHECK=0 DESK_ALL_TENANTS=0 DESK_OTHER_BOXES=0 \
    DESK_DISPATCH=0 DESK_WELCOME=0 DESK_RESPONDER=0 \
    bash "$O/src/bash/scripts/desk-reconcile-cron.sh" --env "$1" >"$T/out.$2" 2>&1 &
  echo $! >"$T/pid.$2"
}
reap() { local n rc; for n in "$@"; do rc=0; wait "$(cat "$T/pid.$n")" || rc=$?; echo "$rc" >"$T/rc.$n"; done; }
works() { grep -c "^$1 " "$T/work" 2>/dev/null || true; }

# --- 1. two dev ticks at once ----------------------------------------------------------
tick dev a; tick dev b; reap a b
echo "1. a: rc=$(cat "$T/rc.a") $(grep -E 'skipped|exit' "$T/out.a" | tr '\n' ' ')"
echo "1. b: rc=$(cat "$T/rc.b") $(grep -E 'skipped|exit' "$T/out.b" | tr '\n' ' ')"
skip="$(grep -l 'INFO tick skipped: the dev tick from' "$T/out.a" "$T/out.b" 2>/dev/null)"
[[ "$(works dev)" == 1 && "$(cat "$T/rc.a")" == 0 && "$(cat "$T/rc.b")" == 0 && "$(wc -l <<<"$skip")" == 1 && -n "$skip" ]] &&
  pass "1. two dev ticks together: one does the work, the other exits 0 with the skip line" ||
  fail "1. dev works=$(works dev) skip files='$skip'"
if [[ -n "$skip" && "$(wc -l <<<"$skip")" == 1 ]]; then
  other="a"; [[ "$skip" == "$T/out.a" ]] && other="b"
  grep -q "INFO tick skipped: the dev tick from $(cat "$T/pid.$other") still runs" "$skip" &&
    pass "1. ...naming the pid of the tick that works" || fail "1. skip line: $(cat "$skip") working pid $(cat "$T/pid.$other")"
fi
mapfile -t -O "${#sidecars[@]}" sidecars <"$T/sidecars"

# --- 2. dev and prd at once ------------------------------------------------------------
: >"$T/work"
tick dev c; tick prd d; reap c d
[[ "$(works dev)" == 1 && "$(works prd)" == 1 && "$(cat "$T/rc.c")" == 0 && "$(cat "$T/rc.d")" == 0 ]] &&
  ! grep -q 'skipped' "$T/out.c" "$T/out.d" &&
  pass "2. a dev and a prd tick together: both do the work" ||
  fail "2. dev=$(works dev) prd=$(works prd) c=$(cat "$T/out.c") d=$(cat "$T/out.d")"
mapfile -t sidecars <"$T/sidecars"

# --- 3. the lock ends with the tick, not with its children -----------------------------
: >"$T/work"
live=0; for p in "${sidecars[@]}"; do kill -0 "$p" 2>/dev/null && live=$((live + 1)); done
tick dev e; reap e
[[ "$live" -ge 1 && "$(works dev)" == 1 && "$(cat "$T/rc.e")" == 0 ]] && ! grep -q skipped "$T/out.e" &&
  pass "3. the next dev tick works while $live sidecar(s) of the earlier ticks still live" ||
  fail "3. live sidecars=$live dev works=$(works dev) out=$(cat "$T/out.e")"
mapfile -t sidecars <"$T/sidecars"

echo "----"
[[ $fails -eq 0 ]] && { echo "desk-reconcile-tick-lock: all passed"; exit 0; }
echo "desk-reconcile-tick-lock: $fails failed"; exit 1
