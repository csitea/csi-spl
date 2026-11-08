#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a box-user lease holds dispatch through a desk the desk user owns
# (spec 069 section 8.3.1, SPL-4942). The desk stays 0700: the gate and the
# lease's spool calls hop to its owner, nothing is loosened. Sandbox: caller A
# (this user), desk user B (t-desk-user), B's cloud root chmod 000 except inside
# the hop (a stub of the sudo that spl_desk_moved_to already uses); a stub
# spool that signs like the real one: no readable key = "no private key for
# <box>" (sign.go LoadPrivate). Nothing outside $T is read, no hub.
#   1. t1's desk under B's 0700 root, a live sidecar: able, on a half-moved box
#      (no SPOOL_DESK_USER) and a moved one. Dead sidecar, or the session down:
#      not able. RED on fe0455e48: "desk: no hub-run sidecar" / "cannot read"
#   2. no hop possible (no sudo rule): not able, on both boxes
#   3. the hub calls sign with B's key through B's spool: the lease read, a
#      stub left under A (keys or none) changes nothing. RED on fe0455e48:
#      "no private key for sat"
#   4. spl_fleet_hub_init finds the pin, spl_fleet_beats and `fleet-show` work
#   5. the post, the notice and the asks tick run as B with B's HOME
#   6. a desk that has not moved: no hop at all, A's binary (a counting guard)
#   7. the hops per call on a moved desk stay counted: the lease ticks every 60 s
#   8. a hop that hangs, at any step, is cut at LEASE_HOP_TIMEOUT and reads not
#      able: the loop is one thread and holds both roles (R7 W1, c799). RED on
#      256f79290: "outer limit" on 8a..8g
#   9. a hop that fails reads not able and says it was the hop: a failed stat
#      must not pass a sidecar with no session since its restart (R7 N1, N2)
#  10. the lane map and the ask book on a moved desk (SPL-4985): spl_lane_init
#      finds it, spl_lane_spool and spl_asks_hub sign with B's key through B's
#      spool; a stub under A changes nothing; a desk that has not moved runs no
#      hop; no sudo rule: "not pinned", as before. RED on 48dc6c573: "not pinned"
#  11. ensure run by a user who does not own the fleet loop runs as its owner,
#      once, with that run's rc; its owner, or no loop yet: no hop. RED on
#      48dc6c573: no hop, the old loop is never replaced
#  12. a log read cut after partial output is not able, by its rc and not its
#      text; a cut locate names the hop and uses no stub under A; -k on the
#      locate and the signed call, the limit on hub init's pin read (SPL-5119)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
ME="$(id -un)" DU=t-desk-user
HA="$T/home-a" HB="$T/home-b"
RA="$HA/.local/share/$OA/cloud/prd" RB="$HB/.local/share/$OA/cloud/prd"
if [[ "$(id -u)" == 0 ]]; then echo "SKIP: root enters a chmod 000 root"; exit 0; fi
mkdir -p "$T/stub"
cat >"$T/stub/getent" <<STUB
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $ME) echo "$ME:x:5001:5001::$HA:/bin/sh" ;;
  $DU) echo "$DU:x:5002:5002::$HB:/bin/sh" ;;
  *) exit 2 ;;
esac
STUB
# as <user> -- <cmd...>: the hop. B's root opens only for B.
cat >"$T/stub/as" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$T/hops"
[[ "\$1" == "$DU" && "\$2" == -- ]] || exit 1
shift 2
chmod 700 "$RB"; "\$@"; rc=\$?; chmod 000 "$RB"; exit \$rc
STUB
printf '#!/bin/sh\necho "$*" >>"%s/hops"\nexit 1\n' "$T" >"$T/stub/as-refused"
# the spool: signs with SPOOL_KEYS_DIR's key or says what sign.go says
cat >"$T/stub/spool" <<'STUB'
#!/usr/bin/env bash
[[ -r "$SPOOL_KEYS_DIR/box-$SPOOL_BOX_ID.key" ]] ||
  { echo "spool: no private key for $SPOOL_BOX_ID: unpinned"; exit 1; }
echo "{\"holder\":\"c-002@sat\",\"gen\":7,\"age_s\":3,\"won\":false,\"bin\":\"$0\",\"keys\":\"$SPOOL_KEYS_DIR\",\"verb\":\"$1\"}"
STUB
# the ./run stub of the post, the notice and the asks tick
cat >"$T/stub/run" <<STUB
#!/usr/bin/env bash
echo "RUN HOME=\$HOME \$*" >>"$T/runs"
STUB
# the hop with one step broken; the pattern matches the command: HOP_HANG hangs,
# HOP_DEAF also ignores TERM with stdout closed (a sudo stuck before it runs the
# command), HOP_FAIL exits 1. HOP_CUT=fail|hang: the log read prints the log's
# first line, then fails or hangs. Anything else goes through the plain hop.
cat >"$T/stub/as-sel" <<STUB
#!/usr/bin/env bash
c="\$*"
[[ -n "\${HOP_HANG:-}" && "\$c" == *"\$HOP_HANG"* ]] && exec sleep 20
[[ -n "\${HOP_DEAF:-}" && "\$c" == *"\$HOP_DEAF"* ]] && { exec >/dev/null 2>&1; trap '' TERM; sleep 18; exit 0; }
[[ -n "\${HOP_FAIL:-}" && "\$c" == *"\$HOP_FAIL"* ]] && exit 1
if [[ -n "\${HOP_CUT:-}" && "\$c" == *"tail "* ]]; then
  chmod 700 "$RB"; head -1 "\${!#}"; chmod 000 "$RB"
  [[ "\$HOP_CUT" == hang ]] && exec sleep 20
  exit 1
fi
exec "$T/stub/as" "\$@"
STUB
chmod +x "$T/stub/"*
printf 'SPOOL_AGENT_USER=%s\n' "$DU" >"$T/box.env.half"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_DESK_USER=%s\n' "$DU" "$DU" >"$T/box.env.moved"

has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: ${3:0:500})"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: ${3:0:500})"; }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }

# fresh: empty homes, the spool binaries in both roots, no hop logged.
fresh() {
  chmod 700 "$RB" 2>/dev/null; rm -rf "$HA" "$HB"; mkdir -p "$RA/bin" "$RB/bin" "$T/spool/dispatch"
  cp "$T/stub/spool" "$RA/bin/spool"; cp "$T/stub/spool" "$RB/bin/spool"; : >"$T/hops"; : >"$T/runs"
}
# desk ROOT [up|down]: a pinned t1/sat with a key under ROOT, its sidecar's pid
# file and a session line. The fake /proc holds a live hub-run for pid 4242.
desk() {
  local d="$1/desk/t1/sat" h="$1/desk/t1/sat/spool/.hub"
  mkdir -p "$h" "$d/keys"; echo pin >"$d/pinned"; echo key >"$d/keys/box-sat.key"
  echo 4242 >"$h/hub-run.pid"; touch -d "@$(( $(date +%s) - 60 ))" "$h/hub-run.pid"
  printf '%s hub session %s\n' "$(date -u +%FT%TZ)" "${2:-up}" >"$h/hub-run.log"
}
sidecar() { mkdir -p "$T/proc/4242"; printf 'spool\0hub-run\0' >"$T/proc/4242/cmdline"; }
dead() { rm -rf "$T/proc/4242"; }
lock() { chmod 000 "$RB"; }

# in_orc BOXENV ASCMD CODE: CODE with every orc func file sourced, as caller A.
# PRE: what the call runs under (the outer limit of cases 8).
PRE=()
in_orc() {
  "${PRE[@]}" env -u SPOOL_DESK_USER -u SPOOL_AGENT_USER -u SPOOL_BOX_USER -u LEASE_DESK_DIR -u LEASE_HUB_CMD \
    PATH="$T/stub:$PATH" HOME="$HA" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_ORG_APP="$OA" ENV=prd \
    SPL_STATE_DIR="$RA" SPL_SPOOL="$RA/bin/spool" SPL_HUB_URL=http://hub.invalid SPL_DESK_AS_CMD="$2" SPOOL_BOX_ENV="$1" \
    LEASE_ENV=prd LEASE_TENANT=t1 LEASE_DESK_BOX=sat LEASE_PROC_ROOT="$T/proc" SPOOL_ROOT="$T/spool" LEASE_DIR="$T/spool/dispatch" LEASE_LOG="$T/spool/dispatch/lease.log" \
    LEASE_ASKS_RUN="$T/stub/run" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_require_bin() { return 0; }; do_spl_desk_cnf() { return 0; }; spl_host_spool() { return 0; }
    '"$3" 2>&1
}
hops() { wc -l <"$T/hops" | tr -d ' '; }

# --- 1. the bar: able through the hop, not able when the sidecar is not ------
for box in half moved; do
  fresh; desk "$RB"; sidecar; lock
  out="$(in_orc "$T/box.env.$box" as 'spl_fleet_desk_able; echo "able_rc=$?"')"
  eq "1a. $box: t1 under B's 0700 root, sidecar live: able" "able_rc=0" "$out"
  fresh; desk "$RB"; dead; lock
  out="$(in_orc "$T/box.env.$box" as 'spl_fleet_desk_able; echo "able_rc=$?"')"
  has "1b. $box: the sidecar dead: not able" "able_rc=1" "$out"
  has "1b. $box: the gate says why" "desk: no hub-run sidecar" "$out"
  fresh; desk "$RB" down; sidecar; lock
  out="$(in_orc "$T/box.env.$box" as 'spl_fleet_desk_able; echo "able_rc=$?"')"
  has "1c. $box: the session down: not able" "able_rc=1" "$out"
  has "1c. $box: the gate says why" "desk: session not up" "$out"
done
chmod 700 "$RB"
grep -q 'chmod' "$PROJ_ROOT/src/bash/run/spl-dispatch-lease.func.sh" &&
  fail "1d. the lease file chmods something" || pass "1d. the lease file has no chmod: nothing is loosened"

# --- 2. no way to reach it: still not able (desk-dir test case 8 holds too) ----
for box in half moved; do
  fresh; desk "$RB"; sidecar; lock
  out="$(in_orc "$T/box.env.$box" as-refused 'spl_fleet_desk_able; echo "able_rc=$?"')"
  has "2. $box: no sudo rule: not able" "able_rc=1" "$out"
done
chmod 700 "$RB"

# --- 3. the "no private key for sat" path (sign.go:56) ------------------------
for box in half moved; do
  fresh; desk "$RB"; sidecar; lock
  out="$(in_orc "$T/box.env.$box" as 'spl_fleet_hub_once --fleet main --role dispatch; echo "rc=$?"')"
  hasnt "3a. $box: no 'no private key' through the hop" "no private key" "$out"
  has "3b. $box: signed with B's key" "\"keys\":\"$RB/desk/t1/sat/keys\"" "$out"
  has "3c. $box: B's spool binary" "\"bin\":\"$RB/bin/spool\"" "$out"
  has "3d. $box: rc 0" "rc=0" "$out"
done
fresh; desk "$RB"; sidecar; mkdir -p "$RA/desk/t1/sat/spool/c-002" "$RA/desk/t1/sat/keys"; echo minted >"$RA/desk/t1/sat/keys/box-sat.key"; lock
out="$(in_orc "$T/box.env.half" as 'spl_fleet_hub_once --fleet main --role dispatch; echo "rc=$?"')"
has "3e. A's stub holding a minted key: B's key signs, never the stub's (bad_sig, SPL-4699)" "\"keys\":\"$RB/desk/t1/sat/keys\"" "$out"
fresh; desk "$RB"; sidecar; mkdir -p "$RA/desk/t1/sat/spool/c-002"; lock
out="$(in_orc "$T/box.env.half" as 'spl_fleet_desk_able; echo "able_rc=$?"')"
eq "3f. A's stub without a pin: the gate reads B's desk" "able_rc=0" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(in_orc "$T/box.env.half" as-refused 'spl_fleet_hub_once --fleet main --role dispatch; echo "rc=$?"')"
has "3g. CONTROL no hop: the call still fails the way the bar names" "no private key for sat" "$out"
chmod 700 "$RB"

# --- 4. the loop's start and its other hub reads -------------------------------
fresh; desk "$RB"; sidecar; lock
out="$(in_orc "$T/box.env.half" as 'spl_fleet_hub_init; echo "init_rc=$?"')"
eq "4a. hub init: B's pin is found" "init_rc=0" "$out"
fresh; lock
out="$(in_orc "$T/box.env.half" as 'spl_fleet_hub_init; echo "init_rc=$?"')"
has "4b. CONTROL no desk anywhere: hub init refuses" "init_rc=1" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(in_orc "$T/box.env.moved" as 'spl_fleet_beats --since 1; echo "rc=$?"')"
has "4c. beats read through the hop" "\"verb\":\"box-beat\"" "$out"
has "4c. beats rc 0" "rc=0" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(in_orc "$T/box.env.half" as 'LEASE_FLEET=main spl_fleet_show')"
has "4d. fleet-show reads both roles through the hop" "dispatch c-002@sat 3 7" "$out"
hasnt "4d. fleet-show no ERROR" "ERROR" "$out"
chmod 700 "$RB"

# --- 5. the actions that post through the desk ---------------------------------
fresh; desk "$RB"; sidecar; lock
in_orc "$T/box.env.half" as 'LEASE_ORCH=c-001 spl_fleet_alert_post "bench line" >/dev/null; wait' >/dev/null
has "5a. the #alerts post runs as B, B's HOME" "RUN HOME=$HB -a do_spl_desk_post" "$(cat "$T/runs")"
: >"$T/runs"
in_orc "$T/box.env.half" as 'LEASE_ASKS=1 spl_lease_asks_tick' >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/runs" ]] && break; sleep 0.2; done
has "5b. the asks tick runs as B, B's HOME" "RUN HOME=$HB -a do_spl_asks_tick" "$(cat "$T/runs")"
: >"$T/runs"
in_orc "$T/box.env.half" as 'spl_fleet_owner_dm c-001@sat "notice text"' >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$T/runs" ]] && break; sleep 0.2; done
has "5c. the ops notice runs as B, B's HOME" "RUN HOME=$HB -a do_spl_fleet_notice" "$(cat "$T/runs")"
chmod 700 "$RB"

# --- 6. not moved: nothing changes, no hop (the box user's desk today) ---------
fresh; desk "$RA"; sidecar
out="$(in_orc "$T/box.env.half" as 'spl_fleet_desk_able; echo "able_rc=$?"; spl_fleet_hub_once --fleet main --role dispatch; spl_fleet_hub_init; echo "init_rc=$?"')"
has "6a. A's desk: able" "able_rc=0" "$out"
has "6b. A's desk: A's key" "\"keys\":\"$RA/desk/t1/sat/keys\"" "$out"
has "6c. A's desk: A's binary" "\"bin\":\"$RA/bin/spool\"" "$out"
has "6d. A's desk: init" "init_rc=0" "$out"
eq "6e. a desk that has not moved costs no hop" "0" "$(hops)"
out="$(in_orc "$T/box.env.half" as 'spl_desk_roots() { echo ROOTS-WALKED; }; spl_fleet_desk_at t1; echo "rc=$? $LD"')"
eq "6g. pinned here: located with no walk of the roots (per dial, ~130 ms at load 50)" "rc=0 $RA/desk/t1/sat" "$out"
desk "$RB"; lock
out="$(in_orc "$T/box.env.half" as 'spl_fleet_desk_able; echo "able_rc=$?"')"
eq "6f. pinned under A and B (a move half done): A's stands, no hop" "0 able_rc=0" "$(hops) $out"
chmod 700 "$RB"

# --- 7. the cost guard: hops per call on a moved desk --------------------------
fresh; desk "$RB"; sidecar; lock
in_orc "$T/box.env.half" as 'spl_fleet_desk_able' >/dev/null; gate="$(hops)"
: >"$T/hops"
in_orc "$T/box.env.half" as 'spl_fleet_hub_once --fleet main --role dispatch' >/dev/null; hub="$(hops)"
(( gate <= 4 )) && pass "7a. the gate costs at most 4 hops (locate + pid + log + mtime), got $gate" || fail "7a. gate hops $gate"
(( hub <= 2 )) && pass "7b. a hub call costs at most 2 hops (locate + call), got $hub" || fail "7b. hub hops $hub"
chmod 700 "$RB"

# --- 8. a hung hop is cut, at every step: the outer limit is never what ends it --
# limited RC-NAME OUT: "outer limit" when the 15 s limit ended the call (no rc line).
export LEASE_HOP_TIMEOUT=2
limited() { [[ "$2" == *"$1="* ]] && printf '%s\n' "$2" || echo "outer limit: $2"; }
PRE=(timeout 15)
for step in "8a. every hop hangs, from the locate|HOP_HANG|--" "8b. the pid read hangs|HOP_HANG|cat " "8c. the log read hangs|HOP_HANG|tail " \
  "8d. the mtime read hangs|HOP_HANG|stat " "8e. a hop deaf to TERM|HOP_DEAF|cat "; do
  IFS='|' read -r name var pat <<<"$step"
  fresh; desk "$RB"; sidecar; lock
  out="$(limited able_rc "$(export "$var=$pat"; in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')")"
  unset "$var"
  has "$name: not able, within the limit" "able_rc=1" "$out"
done
fresh; desk "$RB"; sidecar; lock
out="$(limited hub_rc "$(HOP_HANG=-- LEASE_HUB_TIMEOUT=2 in_orc "$T/box.env.half" as-sel 'spl_fleet_hub_once --fleet main --role dispatch; echo "hub_rc=$?"')")"
has "8f. a hub call whose locate hangs: returns" "hub_rc=" "$out"
hasnt "8f. ...and is no success" "hub_rc=0" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(limited asks_rc "$(HOP_HANG=-- LEASE_ASKS=1 in_orc "$T/box.env.half" as-sel 'spl_lease_asks_tick; echo "asks_rc=$?"')")"
eq "8g. the asks starter whose locate hangs: returns" "asks_rc=0" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(limited able_rc "$(in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')")"
eq "8h. control: the same hop, not broken: able" "able_rc=0" "$out"
fresh; desk "$RA"; sidecar
out="$(limited able_rc "$(HOP_HANG=-- in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')")"
eq "8i. a desk that has not moved: no hop, so nothing to cut" "able_rc=0 0" "$out $(hops)"
PRE=()
chmod 700 "$RB"

# --- 9. a hop that fails says so, and never passes the gate ---------------------
stale_up() { # the sidecar restarted after its only "up" line
  touch "$RB/desk/t1/sat/spool/.hub/hub-run.pid"
  printf '%s hub session up\n' "$(date -u -d '-1 hour' +%FT%TZ)" >"$RB/desk/t1/sat/spool/.hub/hub-run.log"
}
fresh; desk "$RB"; stale_up; sidecar; lock
out="$(in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')"
has "9a. control: a stale up line, working hop: not able" "able_rc=1" "$out"
fresh; desk "$RB"; stale_up; sidecar; lock
out="$(HOP_FAIL="stat " in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')"
has "9b. the same, only the mtime hop fails: not able" "able_rc=1" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(HOP_FAIL="cat " in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')"
has "9c. a healthy desk, the pid hop fails: not able" "able_rc=1" "$out"
has "9d. ...and the text names the hop, not only a dead sidecar" "the hop to its owner failed" "$out"
chmod 700 "$RB"

# --- 10. the lane map and the ask book --------------------------------------
LANE10='LANE_FLEET=main LANE_ENV=prd LANE_TENANT=t1 LANE_DESK_BOX=sat LANE_BOX=sat; spl_lane_init; echo "init_rc=$?"'
for box in half moved; do
  fresh; desk "$RB"; sidecar; lock
  out="$(in_orc "$T/box.env.$box" as "$LANE10"'; spl_lane_spool lane list; echo "lane_rc=$?"; spl_asks_hub list; echo "ask_rc=$?"')"
  has "10a. $box: spl_lane_init finds the moved desk" "init_rc=0" "$out"
  has "10a. $box: the lane call signs with B's key" "\"keys\":\"$RB/desk/t1/sat/keys\",\"verb\":\"lane\"" "$out"
  has "10a. $box: the ask call signs with B's key" "\"keys\":\"$RB/desk/t1/sat/keys\",\"verb\":\"ask\"" "$out"
  has "10a. $box: B's spool" "\"bin\":\"$RB/bin/spool\"" "$out"
  has "10a. $box: the lane call's rc" "lane_rc=0" "$out"
  has "10a. $box: the ask call's rc" "ask_rc=0" "$out"
  hasnt "10a. $box: no 'not pinned'" "not pinned" "$out"
  fresh; desk "$RB"; sidecar; mkdir -p "$RA/desk/t1/sat/spool/c-002/.mirror" "$RA/desk/t1/sat/keys"; lock
  out="$(in_orc "$T/box.env.$box" as "$LANE10"'; spl_lane_spool lane list')"
  has "10b. $box: a stub under A changes nothing" "\"keys\":\"$RB/desk/t1/sat/keys\"" "$out"
  fresh; desk "$RB"; sidecar; lock
  out="$(in_orc "$T/box.env.$box" as-refused "$LANE10")"
  hasnt "10c. $box: no sudo rule: not found" "init_rc=0" "$out"
done
chmod 700 "$RB"
fresh; desk "$RA"; sidecar
out="$(in_orc "$T/box.env.half" as "$LANE10"'; spl_lane_spool lane list')"
has "10d. a desk that has not moved: A's key" "\"keys\":\"$RA/desk/t1/sat/keys\"" "$out"
eq "10d. a desk that has not moved: no hop" "0" "$(hops)"

# --- 11. ensure and the loop's owner ------------------------------------------
cat >"$T/stub/stat" <<STUB
#!/usr/bin/env bash
[[ -n "\${LOOP_OWNER:-}" && "\$*" == *fleet.run ]] && { echo "\$LOOP_OWNER"; exit 0; }
PATH="\${PATH#*:}" exec stat "\$@"
STUB
cat >"$T/stub/as-ens" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$T/hops"
exit "\${ENS_RC:-0}"
STUB
chmod +x "$T/stub/stat" "$T/stub/as-ens"
ENS11='LEASE_CONF="$T11/conf"; spl_lease_ids() { return 0; }; spl_lease_trunk_check() { echo REACHED-HERE; return 1; }; spl_lease_ensure; echo "ens_rc=$?"'
fresh; echo LEASE_FLEET=main >"$T/conf"
out="$(T11="$T" LOOP_OWNER="$DU" in_orc "$T/box.env.half" as-ens "$ENS11")"; log="$(cat "$T/hops")"
eq "11a. the loop is another user's: one hop" "1" "$(hops)"
has "11a. to that user, with its HOME" "$DU -- env HOME=$HB " "$log"
has "11a. the same action" "LEASE_CMD=ensure" "$log"
has "11a. one hop only" "SPL_LEASE_OWNER_HOPPED=$ME" "$log"
hasnt "11a. nothing runs here" "REACHED-HERE" "$out"
has "11a. rc 0" "ens_rc=0" "$out"
fresh; echo LEASE_FLEET=main >"$T/conf"
out="$(T11="$T" LOOP_OWNER="$DU" ENS_RC=7 in_orc "$T/box.env.half" as-ens "$ENS11")"
has "11b. the hopped run's rc" "ens_rc=7" "$out"
fresh; echo LEASE_FLEET=main >"$T/conf"
out="$(T11="$T" LOOP_OWNER="$ME" in_orc "$T/box.env.half" as-ens "$ENS11")"
eq "11c. the loop is this user's: no hop" "0" "$(hops)"
has "11c. it runs here" "REACHED-HERE" "$out"
fresh; echo LEASE_FLEET=main >"$T/conf"
out="$(T11="$T" in_orc "$T/box.env.half" as-ens "$ENS11")"
eq "11d. no loop yet: no hop" "0" "$(hops)"
fresh; echo LEASE_FLEET=main >"$T/conf"
out="$(T11="$T" LOOP_OWNER="$DU" SPL_LEASE_OWNER_HOPPED=x in_orc "$T/box.env.half" as-ens "$ENS11")"
eq "11e. already hopped: no second hop" "0" "$(hops)"

# --- 12. a read cut part way, and the limits nothing else pins (SPL-5119) -------
# up_then_down ROOT: the session's last word is down, an earlier up is this session's.
up_then_down() {
  printf '%s hub session up\n%s hub session down\n' "$(date -u +%FT%TZ)" "$(date -u +%FT%TZ)" >"$1/desk/t1/sat/spool/.hub/hub-run.log"
}
PRE=(timeout 15)
fresh; desk "$RB"; up_then_down "$RB"; sidecar; lock
out="$(limited able_rc "$(in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')")"
has "12a. control: the session's last word is down, working hop: not able" "able_rc=1" "$out"
for how in fail hang; do
  fresh; desk "$RB"; up_then_down "$RB"; sidecar; lock
  out="$(limited able_rc "$(HOP_CUT=$how in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')")"
  has "12b. the log hop prints an old up, then $how: not able" "able_rc=1" "$out"
  has "12b. $how: the text names the hop" "the hop to its owner failed reading the session log" "$out"
done
fresh; desk "$RA"; up_then_down "$RA"; sidecar
out="$(in_orc "$T/box.env.half" as-sel 'tail() { [[ "$1" == -n ]] || { command tail "$@"; return; }; command head -1 "$3"; return 1; }; spl_fleet_desk_able; echo "able_rc=$?"')"
has "12c. the direct read prints an old up, then fails: not able" "able_rc=1" "$out"
hasnt "12c. no hop to name" "the hop to its owner" "$out"
# A cut locate: a stub under A, with a minted key, must not stand in for B's desk.
stub_a() { mkdir -p "$RA/desk/t1/sat/spool/c-002" "$RA/desk/t1/sat/keys"; echo minted >"$RA/desk/t1/sat/keys/box-sat.key"; }
fresh; desk "$RB"; sidecar; stub_a; lock
out="$(limited able_rc "$(HOP_HANG="test -s" in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')")"
has "12d. the locate cut: not able" "able_rc=1" "$out"
has "12d. the text says the hop was cut" "the hop to its owner was cut" "$out"
hasnt "12d. no false 'no sudo rule'" "no sudo -n rule" "$out"
hasnt "12d. the reader is not sent to the stub" "$RA/desk" "$out"
fresh; desk "$RB"; sidecar; stub_a; lock
out="$(limited hub_rc "$(HOP_HANG="test -s" in_orc "$T/box.env.half" as-sel 'spl_fleet_hub_once --fleet main --role dispatch; echo "hub_rc=$?"')")"
hasnt "12e. a call whose locate is cut never signs with the stub's key" "\"keys\":" "$out"
has "12e. ...it is no success, and names the hop" "the hop to its owner was cut" "$out"
hasnt "12e. ...rc" "hub_rc=0" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(limited init_rc "$(HOP_HANG="test -s" in_orc "$T/box.env.half" as-sel 'spl_fleet_hub_init; echo "init_rc=$?"')")"
has "12f. hub init whose locate is cut: refuses" "init_rc=1" "$out"
has "12f. ...and names the hop, not the pin" "the hop to its owner was cut" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(in_orc "$T/box.env.half" as-refused 'spl_fleet_desk_able; echo "able_rc=$?"')"
hasnt "12g. control: a real refusal is not called a cut" "was cut" "$out"
has "12g. ...and keeps its own warning" "no sudo -n rule" "$out"
# The three limits: each stub outlives the 15 s outer limit if its limit is gone.
fresh; desk "$RB"; sidecar; lock
out="$(limited able_rc "$(HOP_DEAF="test -s" in_orc "$T/box.env.half" as-sel 'spl_fleet_desk_able; echo "able_rc=$?"')")"
has "12h. a locate deaf to TERM is killed (-k): not able, within the limit" "able_rc=1" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(limited hub_rc "$(HOP_DEAF="SPOOL_KEYS_DIR=" LEASE_HUB_TIMEOUT=2 in_orc "$T/box.env.half" as-sel 'spl_fleet_hub_once --fleet main --role dispatch; echo "hub_rc=$?"')")"
has "12i. a signed call deaf to TERM is killed (-k): returns" "hub_rc=" "$out"
hasnt "12i. ...and is no success" "hub_rc=0" "$out"
fresh; desk "$RB"; sidecar; lock
out="$(limited init_rc "$(HOP_HANG="env HOME=" in_orc "$T/box.env.half" as-sel 'spl_fleet_hub_init; echo "init_rc=$?"')")"
has "12j. hub init's pin read hangs: cut at the limit" "init_rc=1" "$out"
PRE=()
chmod 700 "$RB"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
