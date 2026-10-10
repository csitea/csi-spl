#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the watchdog self-update pre-flight tells a proof tick that TIMED
#          OUT (rc 124/137: a loaded box) from one that FAILED (2026-10-09,
#          load ~10: three good commits quarantined at rc 124), and fits its
#          limit to the box load. Deterministic: no loops, no sleeps past 3 s;
#          spl_wd_upd_preflight runs against a stub snapshot whose ./run exits
#          with RC; the load is injected (WD_UPD_LOAD1 / WD_UPD_NPROC, 0 by
#          default so the box running the test does not move the limit).
#   1. ./run exits 124 -> RETRY line with the tick time, no code/<sha>.bad,
#      no alert, code/<sha>.slow counts 1; control: exits 1 -> FAILED,
#      quarantined, ONE alert, the tick time in the FAILED line
#   2. 124 again and again -> retried up to WD_UPD_TIMEOUT_TRIES, then
#      quarantined with its own reason "timed out N times in a row"
#   3. a timeout counter resets: a green pre-flight clears code/<sha>.slow;
#      a new sha drops the old sha's counter; rc 137 is a timeout too
#   4. a real timeout (./run sleeps past WD_UPD_CHECK_MAX=1) -> rc 124, RETRY
#   5. a timeout whose output shows a script error is a failure, quarantined
#      (2026-10-09 a283fa4c2: rc 124 after 'line 431: b: unbound variable')
#   6. the limit fits the load (a desk box 2026-10-10, load 77-100 on 16 cpus: 10 of
#      10 pre-flights hit the fixed 20 s): base x load1/nproc, capped, never
#      under the base; a 2 s tick passes at load 3 per cpu where it times out
#      idle (red control); a tick that hangs still times out at the scaled
#      limit and is quarantined after WD_UPD_TIMEOUT_TRIES
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in jq flock timeout; do command -v "$b" >/dev/null || { echo "FAIL: $b is required"; exit 1; }; done
S="$T/spool"; W="$S/dispatch/wd"; LOG="$S/dispatch/wd.log"
mkdir -p "$T/bin" "$W/code" "$S/peer"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$S/box.env"
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/tmux"
chmod +x "$T/bin/"*
: > "$T/sent"

# snap SHA BODY: code/<SHA>/csi-spl-orc/run whose body is BODY
snap() {
  mkdir -p "$W/code/$1/csi-spl-orc"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$W/code/$1/csi-spl-orc/run"
  chmod +x "$W/code/$1/csi-spl-orc/run"
  echo "$1" > "$W/code/$1/.sha"
}
# pf SHA [VAR=val...]: one pre-flight of SHA; prints rc=<its return>
pf() {
  env SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" WD_SEND="$T/bin/send" ROTATE_TMUX="$T/bin/tmux" ROTATE_BOX=box1 \
    PROJ_PATH="$PROJ_ROOT" WD_PEERS=0 WD_INST=1 DRY_RUN=0 WD_UPD_CHECK_MAX=5 WD_UPD_LOAD1=0 SHA="$1" "${@:2}" bash -c '
    set -E -u -o pipefail; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    spl_wd_init >/dev/null || exit 1
    rc=0; spl_wd_upd_preflight "$SHA" "$(date +%s)" || rc=$?; echo "rc=$rc"' 2>&1
}
cnt() { local n; n="$(grep -cE -- "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb C=cccccccccccccccccccccccccccccccccccccccc
D=dddddddddddddddddddddddddddddddddddddddd E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

# ---- 1. timed out -> retried; control: failed -> quarantined ---------------
snap "$A" 'exit 124'
out="$(pf "$A")"
[[ "$out" == *rc=1* && ! -f "$W/code/$A.bad" && "$(cat "$W/code/$A.slow" 2>/dev/null)" == 1 && ! -s "$T/sent" ]] &&
  grep -qE "RETRY ${A:0:9}: pre-flight: .*timed out \(rc 124, took [0-9]+s, limit 5s: base 5s x load 0/[0-9]+ cpus, cap 60s\), 1 of 5; not quarantined" "$LOG" &&
  pass "1 a proof tick that exits 124 is retried: RETRY with its time, not quarantined, no alert" || fail "1 timeout: $out / $(tail -n 2 "$LOG" 2>/dev/null)"
snap "$B" 'exit 1'
out="$(pf "$B")"
[[ "$out" == *rc=1* && -f "$W/code/$B.bad" && ! -f "$W/code/$B.slow" && "$(cnt "commit ${B:0:9} failed" "$T/sent")" == 1 ]] &&
  grep -qE "FAILED ${B:0:9}: pre-flight: the proof tick from the snapshot failed \(rc 1, took [0-9]+s\)" "$LOG" &&
  pass "1 control: a proof tick that exits 1 is quarantined as before, ONE alert, its time logged" || fail "1 control: $out / $(tail -n 2 "$LOG" 2>/dev/null)"

# ---- 2. bounded: quarantined after WD_UPD_TIMEOUT_TRIES in a row -----------
: > "$T/sent"
snap "$C" 'exit 124'
for _ in 1 2; do pf "$C" WD_UPD_TIMEOUT_TRIES=3 >/dev/null; done
[[ ! -f "$W/code/$C.bad" && "$(cat "$W/code/$C.slow" 2>/dev/null)" == 2 && "$(cnt "RETRY ${C:0:9}" "$LOG")" == 2 ]] &&
  pass "2 two timeouts of 3: still retried, counter 2" || fail "2 retries: $(grep "${C:0:9}" "$LOG")"
pf "$C" WD_UPD_TIMEOUT_TRIES=3 >/dev/null
[[ -f "$W/code/$C.bad" && ! -f "$W/code/$C.slow" && "$(cnt "commit ${C:0:9} failed" "$T/sent")" == 1 ]] &&
  grep -q "timed out 3 times in a row (rc 124" "$W/code/$C.bad" &&
  pass "2 the 3rd timeout of 3 quarantines it, with its own reason, ONE alert" || fail "2 bound: $(cat "$W/code/$C.bad" 2>/dev/null) / $(grep "${C:0:9}" "$LOG")"

# ---- 3. counters reset ------------------------------------------------------
snap "$D" 'exit 137'
pf "$D" >/dev/null
[[ "$(cat "$W/code/$D.slow" 2>/dev/null)" == 1 && ! -f "$W/code/$D.bad" && ! -f "$W/code/$A.slow" ]] &&
  pass "3 rc 137 (killed after the timeout) is a timeout; a new sha drops the old sha's counter" || fail "3 137: $(ls "$W/code")"
snap "$D" 'exit 0'
out="$(pf "$D")"
[[ "$out" == *rc=0* && ! -f "$W/code/$D.slow" && ! -f "$W/code/$D.bad" ]] &&
  pass "3 a green pre-flight clears the timeout counter" || fail "3 green: $out / $(ls "$W/code")"

# ---- 4. a real timeout ------------------------------------------------------
snap "$E" 'sleep 10'
out="$(pf "$E" WD_UPD_CHECK_MAX=1)"
[[ "$out" == *rc=1* && ! -f "$W/code/$E.bad" && "$(cat "$W/code/$E.slow" 2>/dev/null)" == 1 ]] &&
  grep -qE "RETRY ${E:0:9}: .*\(rc 124, took [12]s, limit 1s: " "$LOG" &&
  pass "4 a proof tick past WD_UPD_CHECK_MAX (timeout rc 124) is retried" || fail "4 real: $out / $(grep "${E:0:9}" "$LOG")"

# ---- 5. a timeout with a script error is a failure -------------------------
snap "$E" 'echo "s1.sh: line 3: nosuchcmd: command not found"; exit 124'
pf "$E" >/dev/null
[[ -f "$W/code/$E.bad" && ! -f "$W/code/$E.slow" ]] && grep -q "FAILED ${E:0:9}: pre-flight: the proof tick from the snapshot failed (rc 124" "$LOG" &&
  pass "5 a timed-out tick that shows a script error is quarantined" || fail "5 err: $(grep "${E:0:9}" "$LOG")"
U=1212121212121212121212121212121212121212
snap "$U" 'echo "/x/code/$0/csi-spl-orc/src/bash/run/spl-watchdog.func.sh: line 431: b: unbound variable" >&2; exit 124'
pf "$U" >/dev/null
[[ -f "$W/code/$U.bad" && ! -f "$W/code/$U.slow" && "$(cnt "RETRY ${U:0:9}" "$LOG")" == 0 ]] &&
  pass "5 rc 124 after an 'unbound variable' line (a283fa4c2) is quarantined, never retried" || fail "5 unbound: $(grep "${U:0:9}" "$LOG")"

# ---- 6. the limit fits the load -------------------------------------------
# lim [VAR=val...]: the limit spl_wd_upd_check_limit sets
lim() {
  env SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" PROJ_PATH="$PROJ_ROOT" WD_PEERS=0 "$@" bash -c '
    set -u; do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    spl_wd_init >/dev/null || exit 1
    spl_wd_upd_check_limit; echo "$WD_UPD_LIM|$WD_UPD_LIM_WHY"' 2>&1
}
l1="$(lim WD_UPD_LOAD1=4.00 WD_UPD_NPROC=16)" l2="$(lim WD_UPD_LOAD1=24.5 WD_UPD_NPROC=16)"
l3="$(lim WD_UPD_LOAD1=96.31 WD_UPD_NPROC=16)" l4="$(lim WD_UPD_LOAD1=96.31 WD_UPD_NPROC=16 WD_UPD_CHECK_CAP=10)"
[[ "$l1" == "20|base 20s x load 4.00/16 cpus, cap 60s" && "$l2" == 31\|* && "$l3" == 60\|* && "$l4" == 20\|* ]] &&
  pass "6 limit = 20 s x load1/nproc (idle 20, 24.5/16 -> 31, 96/16 -> cap 60, a cap under the base -> 20)" ||
  fail "6 limit: '$l1' '$l2' '$l3' '$l4'"
: > "$T/sent"
F=f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0
snap "$F" 'sleep 2; exit 0'
out="$(pf "$F" WD_UPD_CHECK_MAX=1 WD_UPD_LOAD1=48 WD_UPD_NPROC=16)"
[[ "$out" == *rc=0* && ! -f "$W/code/$F.slow" && ! -f "$W/code/$F.bad" ]] &&
  pass "6 a 2 s proof tick at load 48 on 16 cpus passes (base 1 s -> limit 3 s)" || fail "6 loaded: $out / $(grep "${F:0:9}" "$LOG")"
out="$(pf "$F" WD_UPD_CHECK_MAX=1 WD_UPD_NPROC=16)"
[[ "$out" == *rc=1* && "$(cat "$W/code/$F.slow" 2>/dev/null)" == 1 ]] &&
  grep -qE "RETRY ${F:0:9}: .*limit 1s: base 1s x load 0/16 cpus" "$LOG" &&
  pass "6 control: the same tick on an idle box times out at the 1 s base" || fail "6 idle: $out / $(grep "${F:0:9}" "$LOG")"
H=4848484848484848484848484848484848484848
snap "$H" 'sleep 30'
pf "$H" WD_UPD_CHECK_MAX=1 WD_UPD_LOAD1=48 WD_UPD_NPROC=16 WD_UPD_TIMEOUT_TRIES=2 >/dev/null
[[ ! -f "$W/code/$H.bad" && "$(cat "$W/code/$H.slow" 2>/dev/null)" == 1 ]] &&
  grep -qE "RETRY ${H:0:9}: .*\(rc 124, took [34]s, limit 3s: base 1s x load 48/16 cpus, cap 60s\), 1 of 2" "$LOG" &&
  pass "6 a hang at load 48/16 times out at the scaled 3 s, logged with the load, retried" || fail "6 hang 1: $(grep "${H:0:9}" "$LOG")"
pf "$H" WD_UPD_CHECK_MAX=1 WD_UPD_LOAD1=48 WD_UPD_NPROC=16 WD_UPD_TIMEOUT_TRIES=2 >/dev/null
[[ -f "$W/code/$H.bad" && ! -f "$W/code/$H.slow" && "$(cnt "commit ${H:0:9} failed" "$T/sent")" == 1 ]] &&
  grep -q "timed out 2 times in a row (rc 124, last took [34]s, limit 3s: base 1s x load 48/16 cpus" "$W/code/$H.bad" &&
  pass "6 a hang under load is still quarantined after WD_UPD_TIMEOUT_TRIES, ONE alert" || fail "6 hang 2: $(cat "$W/code/$H.bad" 2>/dev/null) / $(grep "${H:0:9}" "$LOG")"

echo "wd-preflight-timeout: $fails failure(s)"
[[ $fails -eq 0 ]]
