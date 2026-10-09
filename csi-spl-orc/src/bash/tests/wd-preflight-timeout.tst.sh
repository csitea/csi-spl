#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the watchdog self-update pre-flight tells a proof tick that TIMED
#          OUT (rc 124/137: a loaded box) from one that FAILED (2026-10-09,
#          load ~10: three good commits quarantined at rc 124). Deterministic:
#          no loops, no sleeps past 2 s; spl_wd_upd_preflight runs against a
#          stub snapshot whose ./run exits with RC.
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
    PROJ_PATH="$PROJ_ROOT" WD_PEERS=0 WD_INST=1 DRY_RUN=0 WD_UPD_CHECK_MAX=5 SHA="$1" "${@:2}" bash -c '
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
  grep -qE "RETRY ${A:0:9}: pre-flight: .*timed out \(rc 124, took [0-9]+s, limit 5s\), 1 of 5; not quarantined" "$LOG" &&
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
  grep -qE "RETRY ${E:0:9}: .*\(rc 124, took [12]s, limit 1s\)" "$LOG" &&
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

echo "wd-preflight-timeout: $fails failure(s)"
[[ $fails -eq 0 ]]
