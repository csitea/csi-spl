#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a watchdog reload (spl_wd_upd_exec, spec 102 10.4.4) leaves no
#          process of the code it left behind (SPL-1732). ./run starts every
#          action with its stdout/stderr on two tee process substitutions;
#          ./run keeps their pipes' write ends open on fds of its own (62/63,
#          named fds since SPL-2820), which survive exec. Before the fix each reload kept the
#          old code's two tee subshells alive for good (a desk box, 2026-10-13:
#          926 processes over ~220 code/<sha> trees, ~4 per master push).
#          In a scratch SPOOL_ROOT, one instance loop is started from
#          code/A, then reloaded into code/B and into code/C; each snapshot
#          carries this tree's spl-wd-self-update.func.sh and a ./run with the
#          real ./run's tee line (checked against it, so the model cannot
#          drift). After every reload:
#   1. the instance's own descendants (no sleep) are the 2 tee subshells of
#      the code it runs now, never more (red before the fix: 4, then 6)
#   2. no tee of an earlier code tree is alive anywhere (by an open fd on its log)
#      (also a tee pipe on fd 9, where the keeper lock was: closed too)
#   3. control: same pid (exec, not restart) and the run lock (fd 7) still
#      held by it through both reloads
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in setsid flock tee pgrep; do command -v "$b" >/dev/null || { echo "FAIL: $b is required"; exit 1; }; done
W="$T/spool/dispatch/wd"
mkdir -p "$W/code"

# the model below repeats ./run's tee line; it must still be ./run's
# shellcheck disable=SC2016 # the literal line, not an expansion
if grep -qF 'exec {RUN_TEE_OUT_FD}> >(do_run_log_tee $main_log_dir/${RUN_UNIT:-run.sh}.$ts.out.log)' "$PROJ_ROOT/run" &&
   grep -qF 'exec {RUN_TEE_ERR_FD}> >(exec {RUN_TEE_OUT_FD}>&- && do_run_log_tee $main_log_dir/${RUN_UNIT:-run.sh}.$ts.err.log >&2)' "$PROJ_ROOT/run" &&
   grep -qF 'tee >(do_mask_private_keys >"$1")' "$PROJ_ROOT/run" &&
   grep -qF 'main_exec "$@" >&$RUN_TEE_OUT_FD 2>&$RUN_TEE_ERR_FD {RUN_TEE_OUT_FD}>&- {RUN_TEE_ERR_FD}>&-' "$PROJ_ROOT/run"; then
  pass "0 ./run still starts every action under the two tee process substitutions"
else
  fail "0 ./run's tee line changed: update the model in this test"
fi

# snap NAME: code/<NAME>/csi-spl-orc with this tree's self-update code and a
# ./run that tees like the real one, then execs into the sha $W/go names
snap() {
  local o="$W/code/$1/csi-spl-orc"
  mkdir -p "$o/src/bash/run"
  cp "$PROJ_ROOT/src/bash/run/spl-wd-self-update.func.sh" "$o/src/bash/run/"
  cat > "$o/run" <<'EOF'
#!/usr/bin/env bash
PROJ_PATH="$(cd "$(dirname "$0")" && pwd)"
CODE="$(basename "$(dirname "$PROJ_PATH")")"
spl_wd_peer_state() { echo ok; }
spl_wd_log() { echo "$*" >> "$WD_DIR/wd.log"; }
spl_lease_now() { date +%s; }
source "$PROJ_PATH/src/bash/run/spl-wd-self-update.func.sh"
main_exec() {
  local n
  # the run lock: taken on the first start, kept through every exec (fd 7)
  [[ -n "${WD_UPD_EXEC:-}" ]] || { exec 7>>"$WD_DIR/run.$WD_INST.lock"; flock -n 7 || exit 1; }
  # a tee pipe that landed on fd 9 after the keeper closed it (sat 2026-10-13)
  [[ -n "${WD_UPD_EXEC:-}" ]] || exec 9> >(tee "$WD_DIR/log/run.sh.K9.out.log")
  echo "$$ $CODE" >> "$WD_DIR/execs"
  while :; do
    n="$(cat "$WD_DIR/go" 2>/dev/null || true)"
    if [[ -n "$n" ]]; then
      rm -f "$WD_DIR/go"
      DRY_RUN=0 spl_wd_upd_exec "$n" forward "$(spl_lease_now)" test
    fi
    sleep 0.1
  done
}
# ./run's masked log tee (SPL-3614); the mask itself does not matter here
do_mask_private_keys() { cat; }
do_run_log_tee() {
  tee >(do_mask_private_keys >"$1")
  wait $! 2>/dev/null || true
}
main() {
  ts="$CODE"
  main_log_dir="$WD_DIR/log/"
  mkdir -p $main_log_dir
  exec {RUN_TEE_OUT_FD}> >(do_run_log_tee $main_log_dir/${RUN_UNIT:-run.sh}.$ts.out.log)
  exec {RUN_TEE_ERR_FD}> >(exec {RUN_TEE_OUT_FD}>&- && do_run_log_tee $main_log_dir/${RUN_UNIT:-run.sh}.$ts.err.log >&2)
  main_exec "$@" >&$RUN_TEE_OUT_FD 2>&$RUN_TEE_ERR_FD {RUN_TEE_OUT_FD}>&- {RUN_TEE_ERR_FD}>&-
  exit $?
}
main "$@"
EOF
  chmod +x "$o/run"
}
snap A; snap B; snap C

# under ROOT PID: PID's descendants, one per line (ROOT itself left out)
under() {
  ps -e -o pid=,ppid=,comm= | awk -v r="$1" '
    { p[$1] = $2; c[$1] = $3 }
    END { for (x in p) { y = x; while (y in p && y != r && y > 1) y = p[y]
                         if (y == r && x != r) print x, c[x] } }'
}
# kids PID: PID's own children, sleep left out (the loop's own 0.1 s nap): the
# tee process substitutions; each runs its tee and log writer below it
kids() { ps -e -o ppid=,comm= | awk -v r="$1" '$1 == r && $2 != "sleep"' | wc -l; }
# log_writers CODE: pids that hold a log of this code tree open (the masked
# log writer of ./run's tee, SPL-3614, or the fd 9 tee), one per line
log_writers() {
  find /proc/[0-9]*/fd -maxdepth 1 -lname "$(realpath -m "$W/log")/run.sh.$1.*" 2>/dev/null | cut -d/ -f3 | sort -u
}
# old_tees CODE...: live processes that write a log of these code trees
old_tees() {
  local c n=0
  for c in "$@"; do n=$(( n + $(log_writers "$c" | wc -l) )); done
  echo "$n"
}
# settle PID WANT: kids PID drops to WANT within 5 s; prints the last count
settle() {
  local i k
  for (( i = 0; i < 50; i++ )); do
    k="$(kids "$1")"
    (( k <= $2 )) && break
    sleep 0.1
  done
  echo "$k"
}
execs_n() { wc -l < "$W/execs" 2>/dev/null || echo 0; }
wait_execs() {
  local i
  for (( i = 0; i < 100; i++ )); do (( $(execs_n) >= $1 )) && return 0; sleep 0.1; done
  return 1
}
held() { [[ -f "$1" ]] && ! flock -n "$1" true; }

PID=""
cleanup() {
  # only the sandbox: the instance pid, its descendants, and tees of its logs, by pid
  local d c
  if [[ -n "$PID" ]]; then
    d="$(under "$PID" | awk '{print $1}')"
    # shellcheck disable=SC2086 # one pid per word
    kill -KILL "$PID" $d 2>/dev/null
    for c in A B C K9; do log_writers "$c" | xargs -r kill -KILL 2>/dev/null; done
  fi
  rm -rf "$T"
}
trap cleanup EXIT

: > "$W/execs"
(
  cd / || exit 1
  exec env WD_DIR="$W" WD_INST=1 PROJ_PATH="$W/code/A/csi-spl-orc" setsid "$W/code/A/csi-spl-orc/run" -a do_spl_watchdog \
    </dev/null >>"$W/run.1.out" 2>&1
) &
PID=$!
disown "$PID"
wait_execs 1 || fail "the loop did not start from code/A"
k0="$(settle "$PID" 3)"
[[ "$k0" == 3 ]] && pass "start on A: 3 descendants (the 2 tee subshells + the fd 9 tee)" || fail "start on A: $k0 descendants, want 3"

n=0
for code in B C; do
  n=$(( n + 1 ))
  echo "$code" > "$W/go"
  wait_execs $(( n + 1 )) || { fail "reload $n: no exec into code/$code"; continue; }
  k="$(settle "$PID" 2)"
  case "$code" in B) old="$(old_tees A K9)" ;; *) old="$(old_tees A B K9)" ;; esac
  [[ "$k" == 2 ]] && pass "1 reload $n into $code: $k descendants, the old code's are gone" ||
    fail "1 reload $n into $code: $k descendants of pid $PID, want 2 (the old code's tee subshells leaked)"
  [[ "$old" == 0 ]] && pass "2 reload $n into $code: no tee of an earlier code tree alive" ||
    fail "2 reload $n into $code: $old tee(s) of an earlier code tree still alive"
done

pids_seen="$(awk '{print $1}' "$W/execs" | sort -u | tr '\n' ' ')"
[[ "$pids_seen" == "$PID " && "$(awk '{print $2}' "$W/execs" | tr '\n' ' ')" == "A B C " ]] &&
  pass "3 control: one pid ran A, B, C (exec, not restart)" || fail "3 control: execs: $(tr '\n' ';' < "$W/execs"), pid $PID"
held "$W/run.1.lock" && pass "3 control: the run lock (fd 7) is still held after both reloads" ||
  fail "3 control: the run lock was lost across the reloads"

(( fails == 0 )) || { echo "wd-reload-leak: $fails failure(s)"; exit 1; }
echo "wd-reload-leak: all pass"
