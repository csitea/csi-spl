#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the boot pass queues its restarts (sat reboot drill 2, 2026-10-08,
#          n=1: "11 restart(s) started", 8 refused at once by the pass's own
#          restart slots and its own rotate.hold; only c-001 came back). A
#          sandbox box ran 11 agents before the boot: the seats c-001..c-003
#          and the lanes c-101..c-108. The restart is a stub with the real
#          gate's two refusals: a slot lock peer/restart.slot.<n> (seat 0,
#          lanes 1..4) held while it runs, and rotate.hold (written by a role
#          seat, any other id refused). It runs until the test lets it end
#          ($T/go.<id>); the test then shows the id back (a window and a process).
#   1. RESTART_SLOTS=4: the seats one per tick, nothing else in a role
#      seat's pass; then the lanes 4 at a time, the 5th waits while 4 run;
#      all 11 restarted once, 0 refused; the summaries count started /
#      queued / in flight / back; boot.seen once all are back
#   2. control: the queue's gates cut out (every id a lane, every slot
#      free, no hold) = the old pass: all 11 at once -> refusals by its own
#      slots and hold; the next tick counts them refused and starts them again
#   3. a refusal by something else (another rotation's hold): counted
#      refused, retried next tick; WD_BOOT_TRIES refusals -> given up, done;
#      not back in WD_BOOT_BACK_WAIT -> started again
#   4. sat drill 4 (2026-10-09, n=1): no tmux server after the boot, the pass
#      creates one, the spawn of m-617 FAILs: tried again next tick, up to
#      WD_BOOT_TRIES, then reported failed (boot.result). The tmux server, a
#      daemon, inherited the pass's fd 5 (boot.lock) and held it for good:
#      every later pass gave up on the lock in silence, boot.q/m-617 kept
#      try 1. Control: a tmux call that keeps fd 5 -> no retry, no log
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v setsid >/dev/null || { echo "FAIL: setsid is required"; exit 1; }
BT=1800000000   # 2027-01-15T08:00:00Z, the boot
S="$T/spool"; D="$S/dispatch"; W="$D/wd"
mkdir -p "$T/bin" "$T/sit" "$T/tmux"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=%s\nSPOOL_BOX_TAG=box1\nSPOOL_DESK_BOX=box1\n' "$(id -un)" "$(id -un)" > "$T/box.env"

# ---- stubs -------------------------------------------------------------------
printf '#!/usr/bin/env bash\ncat "%s/ps"\n' "$T" > "$T/bin/ps"
# tmux: no server until new-session (no tmux/up), which starts a daemon that
# keeps every fd it was given, as tmux's server does
cat > "$T/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
  list-panes) cat "$T/tmux/panes" ;;
  has-session) [[ -e "$T/tmux/up" ]] || exit 1 ;;
  new-session) touch "$T/tmux/up"; ( setsid sleep 600 < /dev/null > /dev/null 2>&1 & echo "\$!" >> "$T/tmux/daemons" ) ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\necho "send $*" >> "%s/sent"\n' "$T" > "$T/bin/send"
printf '#!/usr/bin/env bash\ncase "${1:-}" in --norm|--scrub) cat ;; esac\nexit 0\n' > "$T/sit/s3.sh"
# the restart: the real gate's slot and rotate.hold refusals, then it runs until go.<id>
cat > "$T/bin/takeover" <<STUB
#!/usr/bin/env bash
id="\$ID" T="$T" H="$D/rotate.hold" got=""
echo "\$id cause=\$CAUSE" >> "\$T/takeovers"
if [[ -e "\$T/fail.\$id" ]]; then echo "2027-01-15T08:05:00Z x-rs-\$id RS-SPAWN FAIL no mistral session carrying \$id started in %5 within 120s"; exit 1; fi
first=1 last=4; [[ "\$id" =~ -00[1-4]\$ ]] && first=0 last=0
mkdir -p "$S/peer"
for (( n = first; n <= last; n++ )); do
  exec 6>> "$S/peer/restart.slot.\$n"; if flock -n 6; then got=\$n; break; fi; exec 6>&-
done
refuse() { echo "REFUSED \$id: \$1"; echo "\$id \$1" >> "\$T/refused"; exit 4; }
[[ -n "\$got" ]] || refuse "no free restart slot (peer/restart.slot.\$first..\$last are held)"
if [[ -s "\$H" ]]; then read -r hid _ < "\$H"; [[ "\$hid" == "\$id" ]] || refuse "rotate.hold names \$hid: a rotation runs on this box"; fi
[[ "\$id" =~ -00[1-3]\$ ]] && echo "\$id $(( BT + 1 )) rid" > "\$H"
echo "\$id" >> "\$T/ran"
for _ in \$(seq 1 400); do [[ -e "\$T/go.\$id" ]] && break; sleep 0.05; done
[[ "\$id" =~ -00[1-3]\$ ]] && rm -f "\$H"
touch "\$T/end.\$id"
STUB
chmod +x "$T/bin/"* "$T/sit/"*
export T

IDS="c-001 c-002 c-003 c-101 c-102 c-103 c-104 c-105 c-106 c-107 c-108"
# box: the box after the boot BT; every id of IDS ran here just before it
box() {
  local id
  rm -rf "${S:?}" "${T:?}/proc" "${T:?}/wt" "$T"/takeovers "$T"/refused "$T"/ran "$T"/go.* "$T"/end.*
  mkdir -p "$W" "$T/proc" "$T/wt" "$S/peer"; : > "$T/ps"; : > "$T/tmux/panes"; : > "$S/registry.tsv"
  touch "$T/tmux/up"; rm -f "$T"/fail.*
  cp "$T/box.env" "$S/box.env"
  printf 'cpu  1 2 3\nbtime %s\nprocesses 1\n' "$BT" > "$T/proc/stat"
  echo "$(( BT - 120 ))" > "$W/last.tick"; touch "$T/fresh"
  for id in $IDS; do
    mkdir -p "$S/$id/lifetime" "$S/$id/inbox" "$T/wt/$id"
    printf '%s\tclaude\t%%9\t%s\t20270115T0600Z\n' "$id" "$T/wt/$id" >> "$S/registry.tsv"
    echo "OK" > "$D/wd.$id"; touch -d "@$(( BT - 30 ))" "$D/wd.$id"
  done
}
wd_env=(PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$S" SPOOL_BOX_ENV="$S/box.env" LEASE_PROC_ROOT="$T/proc"
  WD_PS_CMD="$T/bin/ps" ROTATE_TMUX="$T/bin/tmux" WD_SEND="$T/bin/send" WD_TAKEOVER_CMD="$T/bin/takeover"
  WD_SITUATIONS="$T/sit" LEASE_TRANSCRIPT_CMD=true RESTART_SLOTS=4 RESTART_MAX_PER_HOUR=9)
# wd <now>: one tick under ./run's set -E + ERR trap; WD_EXTRA: bash run after the source
wd() {
  if [[ -f "$T/fresh" ]]; then rm -f "${T:?}/fresh"; else echo "$(( $1 - 30 ))" > "$W/last.tick"; fi
  env "${wd_env[@]}" LEASE_NOW="$1" WD_TICKS=1 WD_TICK=30 DRY_RUN=0 WD_EXTRA="${WD_EXTRA:-}" \
    WD_BOOT_TRIES="${WD_BOOT_TRIES:-3}" WD_BOOT_BACK_WAIT="${WD_BOOT_BACK_WAIT:-1200}" bash -c '
    set -E; trap "echo ERR-TRAP: \$BASH_COMMAND; exit 9" ERR
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-watchdog.func.sh"
    eval "$WD_EXTRA"
    do_spl_watchdog' > "$T/out" 2>&1
  if grep -q ERR-TRAP "$T/out"; then fail "the ERR trap fired: $(grep -m3 ERR-TRAP "$T/out")"; fi
}
n_of() { grep -c . "$1" 2>/dev/null || echo 0; }
started() { n_of "$T/takeovers"; }
# settle <n>: n restarts have passed the stub's gate (ran or refused)
settle() {
  for _ in $(seq 1 100); do (( $(n_of "$T/ran") + $(n_of "$T/refused") >= $1 )) && break; sleep 0.05; done
  sleep 0.2
}
pid=7000
# release <id>...: each restart ends, the id runs again (a window and a process)
release() {
  local id
  for id in "$@"; do
    touch "$T/go.$id"
    for _ in $(seq 1 100); do [[ -e "$T/end.$id" ]] && break; sleep 0.05; done
    pid=$(( pid + 2 ))
    printf '%%%s\t%s\t$1\t%s@box1\tclaude\n' "$pid" "$pid" "$id" >> "$T/tmux/panes"
    printf '%s 1 60 sh\n%s %s 60 claude\n' "$pid" "$(( pid + 1 ))" "$pid" >> "$T/ps"
    mkdir -p "$T/proc/$(( pid + 1 ))"; printf 'SPOOL_AGENT_ID=%s\0' "$id" > "$T/proc/$(( pid + 1 ))/environ"
  done
}
# new_ids <before>: the ids started since line <before> of takeovers
new_ids() { tail -n +$(( $1 + 1 )) "$T/takeovers" 2>/dev/null | awk '{print $1}' | sort | paste -sd' ' -; }
last_sum() { grep 'BOOT .*started' "$D/wd.log" | tail -1 | sed 's/.*Z: //; s/.*Z done: //'; }
cleanup_stubs() { local id; for id in $IDS; do touch "$T/go.$id"; done; sleep 0.3; }

# ---- 1. the queue ----------------------------------------------------------------
echo "=== 1. 11 ids at boot, 4 lane slots: all restarted over the ticks, 0 refused"
box; wd $(( BT + 60 ))
t=$(( BT + 300 ))
# step <want started ids> <label>: one tick, the ids it started
step() {
  local b; b="$(started)"
  wd "$t"; t=$(( t + 30 )); settle "$(( b + $(wc -w <<<"$1") ))"
  [[ "$(new_ids "$b")" == "$1" ]] && pass "$2: started '$1'" || fail "$2: started '$(new_ids "$b")', want '$1'"
}
step "c-001" "tick 1 (a role seat holds rotate.hold: alone)"
grep -q '1 started, 0 refused, 10 queued (its restart of c-001 holds rotate.hold), 0 in flight' "$D/wd.log" && pass "summary: 1 started, 10 queued, its own hold named" || fail "summary: $(last_sum)"
release c-001
step "c-002" "tick 2 (c-001 back, the next seat)"
release c-002
step "c-003" "tick 3"
release c-003
step "c-101 c-102 c-103 c-104" "tick 4 (the lanes, 4 slots)"
step "" "tick 5 (4 slots held by its own restarts: nothing)"
grep -q '0 started, 0 refused, 4 queued, 4 in flight' "$D/wd.log" && pass "summary: 4 queued, 4 in flight" || fail "summary: $(last_sum)"
release c-101 c-102
step "c-105 c-106" "tick 6 (2 slots free)"
grep -q '2 started, 0 refused, 2 queued, 2 in flight, 2 back' "$D/wd.log" && pass "summary: 2 started, 2 queued, 2 in flight, 2 back" || fail "summary: $(last_sum)"
release c-103 c-104 c-105 c-106
step "c-107 c-108" "tick 7"
release c-107 c-108
step "" "tick 8 (all back)"
[[ "$(started)" == 11 && "$(awk '{print $1}' "$T/takeovers" | sort -u | wc -l)" == 11 ]] && pass "all 11 restarted, each once" || fail "takeovers: $(awk '{print $1}' "$T/takeovers" | paste -sd' ' -)"
[[ "$(n_of "$T/refused")" == 0 ]] && pass "0 refused by its own slots or hold" || fail "refused: $(cat "$T/refused")"
! grep -q 'refused (try' "$D/wd.log" && pass "wd.log: no refusal" || fail "wd.log refusals: $(grep 'refused (try' "$D/wd.log")"
[[ "$(cat "$W/boot.seen" 2>/dev/null)" == "$BT" ]] && grep -q 'done: 0 restart(s) started, 0 refused, 2 back' "$D/wd.log" && pass "boot.seen once all are back; the done line" || fail "boot.seen: $(cat "$W/boot.seen" 2>/dev/null); $(last_sum)"
step "" "tick 9 (handled)"

# ---- 2. control ------------------------------------------------------------------
echo "=== 2. control: the queue's gates cut out (the old pass) -> refused by its own slots and hold"
box; wd $(( BT + 60 ))
export WD_EXTRA='spl_wd_boot_seat() { return 1; }; spl_wd_boot_free_lanes() { echo 99; }; spl_wd_boot_hold() { return 0; }'
wd $(( BT + 300 )); settle 11
[[ "$(started)" == 11 ]] && pass "red: all 11 started at once" || fail "control started: $(started)"
r="$(n_of "$T/refused")"
(( r >= 6 )) && pass "red: $r of 11 refused by the pass's own slots / rotate.hold (drill: 8)" || fail "control refused: $r ($(cat "$T/refused" 2>/dev/null))"
cleanup_stubs
wd $(( BT + 330 )); settle 11
grep -q "BOOT .*: [0-9]* started, $r refused" "$D/wd.log" && pass "the next tick counts the $r refused (not started) and starts them again" || fail "control summary: $(last_sum)"
unset WD_EXTRA; cleanup_stubs

# ---- 3. refused by another rotation, not back -----------------------------------
echo "=== 3. refused by another rotation: counted, retried, given up after WD_BOOT_TRIES"
IDS="c-101 c-102"; box; wd $(( BT + 60 ))
t=$(( BT + 300 ))
echo "c-555 $(( BT + 1 )) other" > "$D/rotate.hold"
step "" "another rotation's rotate.hold: nothing"
grep -q '0 started, 0 refused, 2 queued (rotate.hold names c-555)' "$D/wd.log" && pass "summary names the other hold" || fail "summary: $(last_sum)"
echo "c-555 $(( BT - 60 )) old" > "$D/rotate.hold"
step "c-101 c-102" "a hold from before the boot: removed, both started"
[[ ! -e "$D/rotate.hold" ]] && grep -q 'rotate.hold names c-555 from before the boot' "$D/wd.log" && pass "the stale hold removed, logged" || fail "stale hold: $(cat "$D/rotate.hold" 2>/dev/null)"
cleanup_stubs
echo "c-555 $(( BT + 1 )) other" > "$D/rotate.hold"
rm -f "$T"/go.* "$T"/end.* "$D/rotate.hold"; b="$(started)"
WD_BOOT_BACK_WAIT=60 WD_BOOT_TRIES=2 wd $(( BT + 430 )); settle 4
[[ "$(new_ids "$b")" == "c-101 c-102" ]] && grep -q 'c-101 not back 100s after try 1' "$D/wd.log" && pass "not back in WD_BOOT_BACK_WAIT: started again (try 2)" || fail "retry: '$(new_ids "$b")'"
cleanup_stubs
echo "c-555 $(( BT + 1 )) other" > "$D/rotate.hold"
# a refusal of the running stub: written into its restart.<id>.out
echo "REFUSED c-101: rotate.hold names c-555: a rotation runs on this box" >> "$W/restart.c-101.out"
b="$(started)"; WD_BOOT_TRIES=2 wd $(( BT + 460 ))
grep -q 'c-101 refused (try 2): rotate.hold names c-555' "$D/wd.log" && pass "the refusal read from restart.<id>.out" || fail "refusal: $(grep c-101 "$D/wd.log" | tail -2)"
grep -q 'c-101 given up: not back after 2 tries' "$D/wd.log" && [[ "$(cat "$W/boot.d/c-101" 2>/dev/null)" == "$BT" ]] && pass "WD_BOOT_TRIES=2 used: given up, done (boot.d)" || fail "given up: $(ls "$W/boot.d" 2>/dev/null)"
grep -q 'BOOT .*: 0 started, 1 refused, 0 queued.*1 in flight' "$D/wd.log" && pass "summary: 1 refused (not started), c-102 in flight" || fail "summary: $(last_sum)"
rm -f "$D/rotate.hold"; cleanup_stubs

# ---- 4. a failed spawn, after the pass made the tmux server -----------------------
echo "=== 4. drill 4: tmux server made by the pass, the spawn FAILs -> tried again, then reported"
# kill_daemons: the stub tmux servers of a case
kill_daemons() { local p; while read -r p; do kill "$p" 2>/dev/null; done < "$T/tmux/daemons" 2>/dev/null; rm -f "$T/tmux/daemons"; }
# drill4 [WD_EXTRA [label]]: m-617 ran before the boot, no tmux server, every spawn fails
drill4() {
  IDS="m-617"; box; rm -f "$T/tmux/up"; touch "$T/fail.m-617"; wd $(( BT + 60 ))
  WD_BOOT_TRIES=2 WD_EXTRA="${1:-}" wd $(( BT + 300 )); sleep 0.3
  [[ -e "$T/tmux/up" ]] && grep -q "session 'main' created" "$D/wd.log" && pass "${2:-}tick 1: the pass made the tmux server" || fail "${2:-}tick 1: no tmux session ($(last_sum))"
  WD_BOOT_TRIES=2 WD_EXTRA="${1:-}" wd $(( BT + 330 )); sleep 0.3
  WD_BOOT_TRIES=2 WD_EXTRA="${1:-}" wd $(( BT + 360 ))
}
drill4
[[ "$(started)" == 2 ]] && pass "m-617 started twice (WD_BOOT_TRIES=2)" || fail "m-617 started $(started) time(s), want 2"
grep -q 'BOOT .* m-617 failed (try 1): .*RS-SPAWN FAIL no mistral session' "$D/wd.log" && grep -q 'm-617: restart started, try 2' "$D/wd.log" \
  && pass "tick 2: the FAIL read, tried again (try 2)" || fail "tick 2: $(grep m-617 "$D/wd.log" | tail -3)"
grep -q 'm-617 given up: not back after 2 tries' "$D/wd.log" && [[ "$(cat "$W/boot.result" 2>/dev/null)" == "$BT back=0 failed=1 m-617" ]] \
  && pass "tick 3: given up, reported (boot.result failed=1 m-617)" || fail "tick 3: boot.result '$(cat "$W/boot.result" 2>/dev/null)'"
[[ "$(cat "$W/boot.seen" 2>/dev/null)" == "$BT" && ! -e "$W/boot.q/m-617" ]] && pass "boot.seen written, boot.q/m-617 gone" || fail "boot.seen '$(cat "$W/boot.seen" 2>/dev/null)', boot.q: $(cat "$W/boot.q/m-617" 2>/dev/null)"
kill_daemons
# control: the tmux call keeps fd 5, as before the fix (fd 7: on sat the loop
# that ran on holds it already, a tick of this test would wait on it instead)
drill4 'spl_wd_tmux() { timeout -k 1 5 "$ROTATE_TMUX" "$@" 6>&- 7>&- 8>&- 9>&-; }' "control: "
[[ "$(started)" == 1 ]] && pass "red: started once, never again (drill 4)" || fail "control started $(started) time(s), want 1"
[[ "$(awk '{print $3}' "$W/boot.q/m-617" 2>/dev/null)" == 1 ]] && ! grep -q 'm-617 failed (try' "$D/wd.log" \
  && pass "red: boot.q/m-617 keeps try 1, the pass logs nothing (boot.lock held by the tmux server)" || fail "control: boot.q '$(cat "$W/boot.q/m-617" 2>/dev/null)'"
kill_daemons

echo
if (( fails == 0 )); then echo "wd-boot-queue: all passed"; else echo "wd-boot-queue: $fails failed"; fi
exit $(( fails > 0 ))
