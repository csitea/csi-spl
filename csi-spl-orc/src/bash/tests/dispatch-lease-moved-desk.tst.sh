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
in_orc() {
  env -u SPOOL_DESK_USER -u SPOOL_AGENT_USER -u SPOOL_BOX_USER -u LEASE_DESK_DIR -u LEASE_HUB_CMD \
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

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
