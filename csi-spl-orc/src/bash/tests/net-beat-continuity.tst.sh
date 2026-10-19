#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_net_beat_continuity (networking round row 08, SPL-2626): the NM
#   dispatcher beat poke and nbc_nap, the watchdog's sleep it wakes.
#   1. DRY_RUN default: prints the state, the file, the link and the probe;
#      writes nothing; a bad DRY_RUN, a relative NET_ROOT and a bad
#      NET_BEAT_CMD are refused
#   2. DRY_RUN=0: the script under NET_ROOT is the shipped one, mode 0755,
#      dispatcher.d/50-beat-poke.sh links to no-wait.d/50-beat-poke.sh, the
#      probe advances the poke file's mtime -> OK; a second run: SAME, SAME
#   3. the refusals: no etc/NetworkManager (dry run and DRY_RUN=0) and a
#      regular file where the link goes -> FATAL, nothing written or replaced
#   4. the dispatcher script: up, down, connectivity-change touch the poke
#      file; pre-up, dhcp4-change, hostname do not; it exits 0 when it
#      cannot write the poke file
#   5. nbc_nap in the watchdog (spl-watchdog.func.sh sourced, the hub a stub):
#      no poke -> no beat; a poke older than the loop -> no beat; a burst of
#      20 pokes (WD_POKE_GAP=5, the default) -> ONE beat, within 1 s, one
#      BEAT POKE line (on a loaded box the 20 forks outlast a 1 s gap); a
#      storm of pokes every 0.1 s for 3 s -> at most one beat per
#      WD_POKE_GAP (whole seconds); a poke inside the gap beats once when it
#      ends; WD_POKE=0 -> plain sleep, no beat; the hub silent, 3 pokes over
#      3 s, the ack 3 min old -> no fenced or held file, no wip push, kill or
#      note: a poke only beats
#   6. NET_BEAT_CMD=check: ack 10 s old, 0 FENCED -> OK; ack 100 s old -> rc 1;
#      a FENCED line after NET_BEAT_SINCE -> rc 1, one before it -> OK
#   7. red controls: a copy without the gap gives a storm of beats; a copy
#      without the NM refusal writes into a box with no NetworkManager; a
#      dispatcher script that pokes on every action pokes on dhcp4-change
#   No real /etc, NetworkManager, systemd or /var/run: NET_ROOT, stubs, no sudo.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
RUN_DIR="$PROJ_ROOT/src/bash/run"
FUNC="$RUN_DIR/net-beat-continuity.func.sh"
ASSET="$PROJ_ROOT/src/bash/features/net/assets/etc/NetworkManager/dispatcher.d/no-wait.d/50-beat-poke.sh"
bash -n "$FUNC" && sh -n "$ASSET" || { echo "FAIL: syntax"; exit 1; }
[[ -x "$ASSET" ]] || fail "0 the shipped dispatcher script is not executable"
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
mkdir -p "$T/bin"
export T
export SPL_WD_POKE_FILE="$T/run/spl/watchdog.poke"
printf '#!/usr/bin/env bash\necho "systemctl $*" >>"$T/calls"\n[[ "$*" == "is-enabled NetworkManager-dispatcher" ]] && echo enabled\n' >"$T/bin/systemctl"
chmod +x "$T/bin/systemctl"

# run <func file> <root> [VAR=val ...] - the action in a clean subshell
run() {
  local f="$1" root="$2"; shift 2
  env NET_ROOT="$root" NET_SYSTEMCTL="$T/bin/systemctl" NET_SUDO="" "$@" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$0"; do_net_beat_continuity' "$f"
}
# box <root> - a fresh root with etc/NetworkManager/dispatcher.d, no poke file
box() { rm -rf "$1" "$T/run" "$T/calls"; mkdir -p "$1/etc/NetworkManager/dispatcher.d"; }
D=etc/NetworkManager/dispatcher.d

# ---- 1. dry run --------------------------------------------------------------
box "$T/r1"; out="$(run "$FUNC" "$T/r1" 2>&1)"; rc=$?
if ((rc == 0)) && [[ -z "$(ls -A "$T/r1/$D")" && ! -e "$SPL_WD_POKE_FILE" ]] &&
  grep -q "NOW .*no-wait.d/50-beat-poke.sh: missing; .*50-beat-poke.sh: missing; NetworkManager-dispatcher is-enabled=enabled" <<<"$out" &&
  grep -q "PLAN install -D -m 0755 .*/50-beat-poke.sh .*/$D/no-wait.d/50-beat-poke.sh" <<<"$out" &&
  grep -q "PLAN ln -sfn no-wait.d/50-beat-poke.sh .*/$D/50-beat-poke.sh" <<<"$out" &&
  grep -q 'PLAN probe:' <<<"$out" && grep -q 'OK DRY_RUN' <<<"$out"; then
  pass "1 DRY_RUN default plans the file, the link and the probe, writes nothing"
else fail "1 dry run (rc=$rc): $out"; fi
for bad in "DRY_RUN=2" "NET_BEAT_CMD=apply"; do
  out="$(run "$FUNC" "$T/r1" "$bad" 2>&1)"
  [[ $? != 0 && "$out" == *FATAL* && -z "$(ls -A "$T/r1/$D")" ]] && pass "1 $bad refused" || fail "1 $bad: $out"
done
out="$(env NET_ROOT=rel/root NET_SUDO="" bash -c 'do_log() { echo "$*"; }; source "$0"; do_net_beat_continuity' "$FUNC" 2>&1)"
[[ $? != 0 && "$out" == *"NET_ROOT must be an absolute path"* ]] && pass "1 a relative NET_ROOT refused" || fail "1 relative root: $out"

# ---- 2. DRY_RUN=0 ------------------------------------------------------------
box "$T/r2"; out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
f="$T/r2/$D/no-wait.d/50-beat-poke.sh"
if ((rc == 0)) && cmp -s "$ASSET" "$f" && [[ "$(stat -c %a "$f")" == 755 ]] &&
  [[ "$(readlink "$T/r2/$D/50-beat-poke.sh")" == no-wait.d/50-beat-poke.sh && -e "$T/r2/$D/50-beat-poke.sh" ]] &&
  [[ -e "$SPL_WD_POKE_FILE" ]] && grep -q '^WROTE ' <<<"$out" && grep -q '^LINKED ' <<<"$out" &&
  grep -q '^PROBE ' <<<"$out" && grep -q '^OK NM dispatcher beat poke installed' <<<"$out"; then
  pass "2 DRY_RUN=0 installs the script 0755, links it from dispatcher.d, the probe touches the poke file"
else fail "2 install (rc=$rc): $out"; fi
out="$(run "$FUNC" "$T/r2" DRY_RUN=0 2>&1)"; rc=$?
((rc == 0)) && grep -q '^SAME .*no-wait.d/50-beat-poke.sh' <<<"$out" && grep -q '^SAME .*50-beat-poke.sh -> no-wait.d' <<<"$out" &&
  ! grep -qE '^(WROTE|LINKED)' <<<"$out" && pass "2 a second run: SAME file, SAME link" || fail "2 rerun (rc=$rc): $out"

# ---- 3. refusals -------------------------------------------------------------
for dry in 1 0; do
  rm -rf "$T/r3"; mkdir -p "$T/r3/etc"
  out="$(run "$FUNC" "$T/r3" DRY_RUN=$dry 2>&1)"; rc=$?
  [[ $rc != 0 && "$out" == *"no NetworkManager on this box, refusing"* && -z "$(ls -A "$T/r3/etc")" ]] &&
    pass "3 DRY_RUN=$dry: no etc/NetworkManager -> refused, nothing written" || fail "3 no NM DRY_RUN=$dry (rc=$rc): $out"
done
box "$T/r3"; echo mine >"$T/r3/$D/50-beat-poke.sh"
out="$(run "$FUNC" "$T/r3" DRY_RUN=0 2>&1)"; rc=$?
[[ $rc != 0 && "$out" == *"is a file, not the link"* && "$(cat "$T/r3/$D/50-beat-poke.sh")" == mine ]] &&
  pass "3 a regular file where the link goes -> refused, left as it was" || fail "3 file at the link (rc=$rc): $out"

# ---- 4. the dispatcher script ------------------------------------------------
for a in up down connectivity-change; do
  rm -rf "$T/run"; sh "$ASSET" wlan0 "$a"; rc=$?
  [[ $rc == 0 && -e "$SPL_WD_POKE_FILE" ]] && pass "4 $a pokes" || fail "4 $a did not poke (rc=$rc)"
done
for a in pre-up dhcp4-change hostname; do
  rm -rf "$T/run"; sh "$ASSET" wlan0 "$a"; rc=$?
  [[ $rc == 0 && ! -e "$T/run" ]] && pass "4 $a does not poke" || fail "4 $a poked (rc=$rc)"
done
rm -rf "$T/run"; mkdir -p "$T/ro"; chmod 0555 "$T/ro"
SPL_WD_POKE_FILE="$T/ro/x/watchdog.poke" sh "$ASSET" wlan0 up; rc=$?
[[ $rc == 0 && ! -e "$T/ro/x" ]] && pass "4 an unwritable poke path still exits 0" || fail "4 unwritable path rc=$rc"
chmod 0755 "$T/ro"

# ---- 5. nbc_nap in the watchdog ----------------------------------------------
# the hub: "$T/hub" ok -> an ack, else no answer; each call is one line in beats
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
echo "$(date +%s.%N) beat $*" >> "$T/beats"
if [ "$(cat "$T/hub")" = ok ]; then echo '{"ok":true,"box_down_min":2}'; else exit 1; fi
STUB
printf '#!/usr/bin/env bash\necho "wip $*" >> "$T/acts"\n' >"$T/bin/wip"
printf '#!/usr/bin/env bash\necho "kill $*" >> "$T/acts"\n' >"$T/bin/kill"
printf '#!/usr/bin/env bash\necho "send $*" >> "$T/acts"\n' >"$T/bin/send"
chmod +x "$T/bin/"*
# nap <func file> <seconds> - nbc_nap in a watchdog shell over $T/wd
nap() {
  ( set +u
    do_log() { echo "$*"; }
    # shellcheck source=../run/spl-watchdog.func.sh
    source "$RUN_DIR/spl-watchdog.func.sh"
    # shellcheck source=/dev/null
    source "$1"
    export SPOOL_ROOT="$T/spool" WD_DIR="$T/wd" WD_LOG="$T/wd.log" WD_SEND="$T/bin/send" WD_FROM=c-001 WD_BOX=box1
    export WD_BEAT_CMD="$T/bin/hub" WD_BEAT_TIMEOUT=1 WD_WIP_CMD="$T/bin/wip" WD_KILL_CMD="$T/bin/kill"
    export WD_TICK_SEQ=1 WD_POKE_SLICE="${WD_POKE_SLICE:-0.1}" WD_POKE_GAP="${WD_POKE_GAP:-1}"
    nbc_nap "$2" )
}
nreset() { rm -rf "$T/wd" "$T/spool" "$T/run" "$T/beats" "$T/acts" "$T/wd.log"; mkdir -p "$T/wd" "$T/spool" "$T/run/spl"; echo ok >"$T/hub"; }
nb() { if [[ -f "$T/beats" ]]; then wc -l <"$T/beats"; else echo 0; fi; }
poke() { touch "$SPL_WD_POKE_FILE"; }

nreset; nap "$FUNC" 2
[[ "$(nb)" == 0 ]] && pass "5 no poke -> no beat" || fail "5 no poke: $(nb) beats"
nreset; poke; sleep 0.05; nap "$FUNC" 2
[[ "$(nb)" == 0 ]] && pass "5 a poke older than the loop -> no beat" || fail "5 stale poke: $(nb) beats"
nreset; touch "$T/wd/beat.poke.seen"; sleep 0.05
( sleep 0.5; t0=$(date +%s.%N); for _ in $(seq 20); do poke; done; echo "$t0" >"$T/t0" ) &
WD_POKE_GAP=5 nap "$FUNC" 3; wait
lat="$(awk -v t0="$(cat "$T/t0")" 'NR == 1 {printf "%.2f", $1 - t0}' "$T/beats" 2>/dev/null)"
if [[ "$(nb)" == 1 && "$(grep -c 'BEAT POKE: network change; beat ack age 0s' "$T/wd.log")" == 1 ]] &&
  awk -v l="${lat:-9}" 'BEGIN {exit !(l < 1)}'; then
  pass "5 a burst of 20 pokes -> ONE beat, ${lat}s after it, one BEAT POKE line"
else fail "5 burst: $(nb) beats, latency ${lat:-none}s, log: $(cat "$T/wd.log" 2>/dev/null)"; fi
[[ "$(cat "$T/wd/beat.ack")" =~ ^[0-9]+$ ]] && pass "5 the poke beat writes the ack" || fail "5 no beat.ack"
nreset; touch "$T/wd/beat.poke.seen"; sleep 0.05
( for _ in $(seq 30); do poke; sleep 0.1; done ) &
WD_POKE_GAP=2 nap "$FUNC" 4; wait
b="$(nb)"
((b >= 1 && b <= 3)) && pass "5 a 3 s storm of pokes, WD_POKE_GAP=2 -> $b beat(s), at most one per gap" || fail "5 storm: $b beats"
nreset; touch "$T/wd/beat.poke.seen"; sleep 0.05
( sleep 0.3; poke; sleep 0.5; poke ) &
WD_POKE_GAP=2 nap "$FUNC" 4; wait
b2="$(awk 'NR == 2 {print $1}' "$T/beats" 2>/dev/null)" b1="$(awk 'NR == 1 {print $1}' "$T/beats" 2>/dev/null)"
[[ "$(nb)" == 2 ]] && awk -v a="$b1" -v b="$b2" 'BEGIN {exit !(b - a >= 1)}' &&
  pass "5 a poke inside the gap beats once when the gap ends" || fail "5 gap: $(cat "$T/beats" 2>/dev/null)"
nreset; touch "$T/wd/beat.poke.seen"; sleep 0.05; ( sleep 0.3; poke ) &
WD_POKE=0 nap "$FUNC" 1; wait
[[ "$(nb)" == 0 ]] && pass "5 WD_POKE=0 -> a plain sleep, no beat" || fail "5 WD_POKE=0: $(nb) beats"
nreset; echo silent >"$T/hub"; echo $(( $(date +%s) - 180 )) >"$T/wd/beat.ack"; touch "$T/wd/beat.poke.seen"; sleep 0.05
( for _ in 1 2 3; do poke; sleep 1.1; done ) &
nap "$FUNC" 4; wait
if [[ "$(nb)" -ge 2 && ! -e "$T/wd/fenced" && ! -e "$T/wd/held" && ! -s "$T/acts" ]] &&
  ! grep -qE 'FENCED|HELD' "$T/wd.log" && grep -q 'BEAT: no ack' "$T/wd.log"; then
  pass "5 hub silent, ack 3 min old: the pokes only beat ($(nb)x), no fence, hold, wip, kill or note"
else fail "5 silent hub: beats=$(nb) fenced=$([[ -e "$T/wd/fenced" ]] && echo yes) acts=$(cat "$T/acts" 2>/dev/null) log=$(cat "$T/wd.log")"; fi

# ---- 6. the measuring command -------------------------------------------------
ck() { env NET_BEAT_CMD=check NET_WD_DIR="$T/wd" NET_WD_LOG="$T/wd.log" "$@" bash -c 'do_log() { echo "$*"; }; source "$0"; do_net_beat_continuity' "$FUNC" 2>&1; }
nreset; echo $(( $(date +%s) - 10 )) >"$T/wd/beat.ack"; poke
echo "2027-01-15T08:00:00Z BEAT POKE: network change; beat ack age 0s" >"$T/wd.log"
out="$(ck)"; rc=$?
((rc == 0)) && grep -qE 'READ beat ack age 1[01]s \(max 90\); poke [01]s ago; since the start: FENCED 0, HELD 0, BEAT POKE 1' <<<"$out" &&
  grep -q '^OK beat ack' <<<"$out" && pass "6 check: ack 10 s old, 0 FENCED -> OK" || fail "6 check ok (rc=$rc): $out"
echo $(( $(date +%s) - 100 )) >"$T/wd/beat.ack"; out="$(ck)"; rc=$?
[[ $rc != 0 && "$out" == *"not under 90s"* ]] && pass "6 check: ack 100 s old -> rc 1" || fail "6 old ack (rc=$rc): $out"
echo $(( $(date +%s) - 10 )) >"$T/wd/beat.ack"
echo "2027-01-15T07:00:00Z FENCED: no beat ack for 130s" >>"$T/wd.log"
out="$(ck NET_BEAT_SINCE=2027-01-15T07:30:00Z)"; rc=$?
((rc == 0)) && pass "6 check: a FENCED line before NET_BEAT_SINCE -> OK" || fail "6 since (rc=$rc): $out"
out="$(ck NET_BEAT_SINCE=2027-01-15T06:30:00Z)"; rc=$?
[[ $rc != 0 && "$out" == *"1 FENCED line(s)"* ]] && pass "6 check: a FENCED line after NET_BEAT_SINCE -> rc 1" || fail "6 fenced (rc=$rc): $out"

# ---- 7. red controls ----------------------------------------------------------
sed 's/(( now - last < \${WD_POKE_GAP:-5} ))/false/' "$FUNC" >"$T/nogap.func.sh"
grep -q 'then return 0; fi' "$T/nogap.func.sh" && ! grep -q 'now - last <' "$T/nogap.func.sh" || fail "7 the no-gap copy did not change"
nreset; touch "$T/wd/beat.poke.seen"; sleep 0.05
( for _ in $(seq 30); do poke; sleep 0.1; done ) &
WD_POKE_GAP=2 nap "$T/nogap.func.sh" 4; wait
(( $(nb) > 3 )) && pass "7 red: without the gap the storm gives $(nb) beats (caught)" || fail "7 red no-gap gave only $(nb) beats"
awk '/no NetworkManager on this box, refusing/ {print "  true || true"; next} {print}' "$FUNC" |
  sed "s|^NBC_ASSET=.*|NBC_ASSET=$ASSET|" >"$T/norefuse.func.sh"
rm -rf "$T/r7"; mkdir -p "$T/r7/etc"
run "$T/norefuse.func.sh" "$T/r7" DRY_RUN=0 >/dev/null 2>&1
[[ -e "$T/r7/$D/no-wait.d/50-beat-poke.sh" ]] && pass "7 red: without the refusal a box with no NM gets the script (caught by 3)" ||
  fail "7 red no-refusal copy wrote nothing"
sed 's/^  up|down|connectivity-change) ;;$/  *) ;;/' "$ASSET" >"$T/all.sh"
rm -rf "$T/run"; sh "$T/all.sh" wlan0 dhcp4-change
[[ -e "$SPL_WD_POKE_FILE" ]] && pass "7 red: a script poking on every action pokes on dhcp4-change (caught by 4)" ||
  fail "7 red all-actions copy did not poke"

echo "net-beat-continuity: $fails failure(s)"
exit $((fails > 0))
