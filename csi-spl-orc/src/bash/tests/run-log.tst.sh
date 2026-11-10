#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a log directory nobody can write never aborts a ./run (SPL-2617,
# bug round 2 row 02). do_log resolves VAR_DIR/<org>/<app>/<proj>/dat/log/bash,
# then PROJ_PATH/dat/log/bash; when neither could be created, the append to
# the log file failed and the ERR trap turned the run FATAL (compact mode:
# "Command '[[ "${RUN_LOG_COMPACT:-0}" == "1" ]]' failed at line 430", full
# mode: "Command 'tee -a $log_file' failed at line 459"). Now do_log falls back
# to ${TMPDIR:-/tmp}/run-log-<uid>, else keeps no log file, warning on stderr.
#   1. both dirs blocked, compact and full: the action runs, exit 0, the line
#      lands in the TMPDIR fallback, a WARN on stderr
#   2. the fallback blocked too: still exit 0, no log file, WARN on stderr
#   3. an existing dat/log/bash, or today's log file in it, without write
#      permission (non-root only)
#   4. a slow stdout tee (SPL-2820): ./run returns only after its tee wrote
#      the last line, so `./run ... >f; grep f` never reads f too early
#   5. an action that ends in `exit` (a failure through error_handler, or its
#      own exit 0) does not idle in do_wait_tees (SPL-5192): with
#      RUN_TEE_WAIT_S=20 a counting `sleep` shim sees at most 100 polls (a
#      saved copy of the tee fd held it to the cap: ~1,000+ polls)
# Each case runs against the orc, iac and utl run.sh (kept in lockstep), in a
# throwaway tree with a probe action. A regular FILE in the way blocks a mkdir
# even for root, so cases 1-2 hold under any user.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)

# probe_tree <module> -- a throwaway <ns>-orc tree running <module>'s run.sh
probe_tree() {
  local d="$T/$1/csi-x/csi-x-orc"
  mkdir -p "$d/src/bash/run" "$d/lib/bash"
  cp "$APP_ROOT/$1/src/bash/run/run.sh" "$d/src/bash/run/run.sh"
  cp -r "$PROJ_ROOT/lib/bash/funcs" "$d/lib/bash/funcs"
  ln -s src/bash/run/run.sh "$d/run"
  cat >"$d/src/bash/run/log-probe.func.sh" <<'EOF'
do_log_probe() {
  do_log "INFO log probe line"
  echo "PROBE ran"
}
EOF
  echo "$d"
}

# run_probe <tree> <mode> <tmpdir> -- ./run the probe with both log dirs blocked
run_probe() {
  (cd "$1" && HOME="$T/home" VAR_DIR="$T/blocker/var" TMPDIR="$3" RUN_LOG="$2" \
    ./run -a do_log_probe </dev/null 2>"$T/err" >"$T/out")
}

mkdir -p "$T/home"
: >"$T/blocker"
for m in csi-spl-orc csi-spl-iac csi-spl-utl; do
  d="$(probe_tree "$m")"
  : >"$d/dat"
  for mode in compact full; do
    tmp="$T/tmp-$m-$mode"
    mkdir -p "$tmp"
    run_probe "$d" "$mode" "$tmp"
    rc=$?
    [[ $rc == 0 ]] && grep -q 'PROBE ran' "$T/out" && pass "$m $mode: blocked log dirs, the run exits 0" ||
      fail "$m $mode: blocked log dirs: rc=$rc $(grep -h FATAL "$T/out" "$T/err" | sed -n 1p)"
    grep -qs 'log probe line' "$tmp/run-log-$EUID/"*.log && pass "$m $mode: the line lands in the TMPDIR fallback" ||
      fail "$m $mode: no line in $tmp/run-log-$EUID: $(ls -R "$tmp" 2>&1 | sed -n 1,3p)"
    grep -q 'WARN.*not writable' "$T/err" && pass "$m $mode: a WARN on stderr names the fallback" ||
      fail "$m $mode: no WARN on stderr: $(head -2 "$T/err")"
  done

  run_probe "$d" compact "$T/blocker/tmp"
  rc=$?
  [[ $rc == 0 ]] && grep -q 'PROBE ran' "$T/out" && grep -q 'no log file' "$T/err" &&
    pass "$m: fallback blocked too, the run exits 0 with no log file" ||
    fail "$m: fallback blocked: rc=$rc $(grep -h 'FATAL\|WARN' "$T/out" "$T/err" | sed -n 1p)"
  rm -f "$d/dat"

  if [[ $EUID != 0 ]]; then
    mkdir -p "$d/dat/log/bash" && chmod 555 "$d/dat/log/bash"
    tmp="$T/tmp-$m-ro"
    mkdir -p "$tmp"
    run_probe "$d" full "$tmp"
    rc=$?
    chmod 755 "$d/dat/log/bash"
    [[ $rc == 0 ]] && grep -qs 'log probe line' "$tmp/run-log-$EUID/"*.log &&
      pass "$m: read-only dat/log/bash falls back to TMPDIR" ||
      fail "$m: read-only dat/log/bash: rc=$rc $(grep -h FATAL "$T/out" "$T/err" | sed -n 1p)"

    printf -v day '%(%Y%m%d)T' -1
    : >"$d/dat/log/bash/csi-x-orc.$day.log" && chmod 444 "$d/dat/log/bash/csi-x-orc.$day.log"
    tmp="$T/tmp-$m-rofile"
    mkdir -p "$tmp"
    run_probe "$d" compact "$tmp"
    rc=$?
    [[ $rc == 0 ]] && grep -qs 'log probe line' "$tmp/run-log-$EUID/"*.log &&
      pass "$m: read-only log file falls back to TMPDIR" ||
      fail "$m: read-only log file: rc=$rc $(grep -h FATAL "$T/out" "$T/err" | sed -n 1p)"
  fi
done

# 4. a PATH shim delays the start of run.sh's own tees (not do_log's tee -a)
real_tee=$(command -v tee)
mkdir -p "$T/shim"
printf '#!/usr/bin/env bash\n[[ " $* " == *" -a "* ]] || sleep 0.3\nexec %q "$@"\n' "$real_tee" >"$T/shim/tee"
chmod +x "$T/shim/tee"
for m in csi-spl-orc csi-spl-iac csi-spl-utl; do
  (cd "$T/$m/csi-x/csi-x-orc" && PATH="$T/shim:$PATH" HOME="$T/home" VAR_DIR="$T/var-slow" TMPDIR="$T/tmp-slow" \
    ./run -a do_log_probe </dev/null 2>"$T/slow-$m.err" >"$T/slow-$m.out")
  rc=$?
  [[ $rc == 0 ]] && grep -q 'PROBE ran' "$T/slow-$m.out" && pass "$m: a slow stdout tee wrote before ./run returned" ||
    fail "$m: slow stdout tee: rc=$rc, stdout lost its last line: $(head -c 200 "$T/slow-$m.out")"
done

# 5. exit inside main_exec: the tees end at once, not at RUN_TEE_WAIT_S
real_sleep=$(command -v sleep)
mkdir -p "$T/count"
printf '#!/usr/bin/env bash\necho x >>%q\nexec %q "$@"\n' "$T/sleeps" "$real_sleep" >"$T/count/sleep"
chmod +x "$T/count/sleep"
for m in csi-spl-orc csi-spl-iac csi-spl-utl; do
  d="$T/$m/csi-x/csi-x-orc"
  printf 'do_fail_probe() {\n  echo "FAIL PROBE last line"\n  return 3\n}\n' >"$d/src/bash/run/fail-probe.func.sh"
  printf 'do_exit_probe() {\n  echo "EXIT PROBE last line"\n  exit 0\n}\n' >"$d/src/bash/run/exit-probe.func.sh"
  for c in fail:3 exit:0; do
    a=${c%%:*} want=${c#*:}
    : >"$T/sleeps"
    (cd "$d" && PATH="$T/count:$PATH" HOME="$T/home" VAR_DIR="$T/var-exit" TMPDIR="$T/tmp-exit" RUN_TEE_WAIT_S=20 \
      ./run -a "do_${a}_probe" </dev/null 2>"$T/exit-$m.err" >"$T/exit-$m.out")
    rc=$?
    n=$(wc -l <"$T/sleeps")
    [[ $rc == "$want" ]] && grep -qi "$a PROBE last line" "$T/exit-$m.out" && ((n <= 100)) &&
      pass "$m: do_${a}_probe exits $rc with its last line, $n tee poll(s)" ||
      fail "$m: do_${a}_probe: rc=$rc (want $want), $n tee poll(s) (max 100), out: $(tail -c 200 "$T/exit-$m.out")"
  done
done

echo "run-log: $fails failure(s)"
(( fails == 0 ))
