#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box user's desk reconcile skips a desk do_spl_desk_move gave to
# the agent user (spec 069 8.4, SPL-4699). sat prd 2026-11-03: a stub
# <caller root>/desk/<ws>/sat/spool/<agent> left by the move was seated by
# do_spl_desk_up_tenants, which minted a new box key and printed a
# do_spl_desk_pin offer that would take the desk from the agent user's live
# sidecar. Sandbox: caller A (this user, home $T/home-a), agent user B
# (t-agent-user, home $T/home-b), getent a stub; no hub, no sudo, no tmux.
#   1. spl_desk_moved_to: B's root holds the desk -> "B<TAB>entered"; B's root
#      0700 -> read through SPL_DESK_AS_CMD ("sudo"), refused -> rc 1. CONTROLS:
#      a desk under A only, and a desk under both whose A copy has a live
#      sidecar, are A's (rc 1)
#   2. do_spl_desk_up_tenants: the moved desk is skipped with ONE INFO line and
#      do_spl_desk_up_all is not run for it. CONTROL: an unmoved tenant desk
#      still reconciles
#   3. do_spl_desk_up_all on a moved desk: returns 0, reads no live agents,
#      creates no lock or key under A
#   4. spl_desk_pin_check on a moved desk: no key minted, no do_spl_desk_pin
#      line, rc 1. CONTROL: an unmoved unpinned desk still gets the admin line
#   5. _spl_desk_up_all_rsp: a moved responder box gets no pin check
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
ME="$(id -un)" AU=t-agent-user
HA="$T/home-a" HB="$T/home-b"
RA="$HA/.local/share/$OA/cloud/prd" RB="$HB/.local/share/$OA/cloud/prd"
export STUB_LOG="$T/stub.log"
mkdir -p "$T/stub"
cat >"$T/stub/getent" <<STUB
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $ME) echo "$ME:x:5001:5001::$HA:/bin/sh" ;;
  $AU) echo "$AU:x:5002:5002::$HB:/bin/sh" ;;
  *) exit 2 ;;
esac
STUB
# as-user stub: logs, answers STUB_AS_RC (0 = the desk is there)
printf '#!/bin/sh\necho "as $*" >>"$STUB_LOG"\nexit "${STUB_AS_RC:-1}"\n' >"$T/stub/as-user"
chmod +x "$T/stub/"*
printf 'SPOOL_AGENT_USER=%s\n' "$AU" >"$T/box.env"

has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: ${3:0:600})"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: ${3:0:600})"; }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }

fresh() { chmod -R u+rwx "$HB" 2>/dev/null; rm -rf "$HA" "$HB" "$STUB_LOG"; mkdir -p "$RA" "$HB"; : >"$STUB_LOG"; }
# desk ROOT WS BOX AGENT: an agent dir on desk WS/BOX under ROOT (a move stub
# under A looks exactly like this: spool/<agent>, no keys, no pin)
desk() { mkdir -p "$1/desk/$2/$3/spool/$4/inbox"; }
in_orc() {
  env -u SPOOL_DESK_USER -u SPOOL_AGENT_USER -u SPOOL_BOX_USER PATH="$T/stub:$PATH" HOME="$HA" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_ORG_APP="$OA" ENV=prd SPL_STATE_DIR="$RA" \
    SPOOL_BOX_ENV="$T/box.env" SPL_DESK_AS_CMD="as-user" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_require_bin() { return 0; }; do_spl_desk_cnf() { return 0; }; spl_host_spool() { return 0; }
    do_spl_cloud_cnf() { return 0; }; spl_box_ws_claim() { return 0; }
    spl_desk_live_agents() { echo "live-read" >>"$STUB_LOG"; echo g-002; }
    '"$1" 2>&1
}

# --- 1. spl_desk_moved_to ------------------------------------------------------
fresh; desk "$RA" az sat g-002; desk "$RB" az sat g-002
out="$(in_orc 'spl_desk_moved_to az sat; echo "rc=$?"')"
eq "1a. B's root holds the desk: moved to B (read by entering)" "$AU"$'\t'"entered"$'\n'"rc=0" "$out"
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$HB"
  out="$(STUB_AS_RC=0 in_orc 'spl_desk_moved_to az sat; echo "rc=$?"')"
  eq "1b. B's root 0700: read as B, the desk is there" "$AU"$'\t'"sudo"$'\n'"rc=0" "$out"
  has "1b. asked as B with test -d" "as $AU -- test -d $RB/desk/az/sat" "$(cat "$STUB_LOG")"
  out="$(STUB_AS_RC=1 in_orc 'spl_desk_moved_to az sat; echo "rc=$?"')"
  eq "1c. B's root 0700 and the read refused: not known as moved (rc 1, as before)" "rc=1" "$out"
  chmod 700 "$HB"
fi
fresh; desk "$RA" az sat g-002
out="$(in_orc 'spl_desk_moved_to az sat; echo "rc=$?"')"
eq "1d. CONTROL a desk under A only: A's" "rc=1" "$out"
fresh; desk "$RA" az sat g-002; desk "$RB" az sat g-002; mkdir -p "$RA/desk/az/sat/spool/.hub"; echo 1 >"$RA/desk/az/sat/spool/.hub/hub-run.pid"
out="$(in_orc 'spl_desk_alive() { [[ "$1" == '"$RA"'/* ]]; }; spl_desk_moved_to az sat; echo "rc=$?"')"
eq "1e. CONTROL both hold it, A's sidecar is live: A's" "rc=1" "$out"

# --- 2. do_spl_desk_up_tenants ----------------------------------------------------
fresh; desk "$RA" az sat g-002; desk "$RB" az sat g-002; desk "$RA" demo sat c-003
out="$(in_orc 'do_spl_desk_up_all() { echo "UPALL $TENANT_ID" >>"$STUB_LOG"; }; DESK_BOX=sat DESK_SKIP_TENANTS=t1 DRY_RUN=0 do_spl_desk_up_tenants; echo "rc=$?"')"
log="$(cat "$STUB_LOG")"
hasnt "2a. the moved desk is not reconciled as A (RED on base: UPALL az)" "UPALL az" "$log"
eq "2a. one INFO line for it" "1" "$(grep -c "desk sat of az (prd) lives under $AU's state root" <<<"$out")"
hasnt "2a. no FAIL line" "FAIL" "$out"
has "2b. CONTROL the unmoved tenant desk still reconciles" "UPALL demo" "$log"
has "2b. rc 0" "rc=0" "$out"

# --- 3. do_spl_desk_up_all on a moved desk -----------------------------------------
fresh; desk "$RA" az sat g-002; desk "$RB" az sat g-002
out="$(in_orc 'TENANT_ID=az DESK_BOX=sat DESK_SEATED_ONLY=1 DESK_RETIRE=0 DESK_HUB_CHECK=0 DRY_RUN=0 do_spl_desk_up_all; echo "rc=$?"')"
has "3a. skipped, rc 0" "rc=0" "$out"
hasnt "3a. no live agent read, no seat (RED on base)" "live-read" "$(cat "$STUB_LOG")"
[[ ! -e "$RA/desk/az/sat/keys" && ! -e "$RA/desk/az/sat/up-all.lock" ]] && pass "3b. no key and no lock under A" || fail "3b. a key or lock was made under A: $(ls "$RA/desk/az/sat")"
hasnt "3c. no do_spl_desk_pin offer" "do_spl_desk_pin" "$out"

# --- 4. spl_desk_pin_check -----------------------------------------------------------
fresh; desk "$RA" az sat g-002; desk "$RB" az sat g-002
out="$(in_orc 'spl_desk_box_pub() { echo "minted" >>"$STUB_LOG"; echo PUBKEY; }; spl_desk_spool() { return 1; }; spl_desk_pin_check '"$RA"'/desk/az/sat sat az https://hub.invalid; echo "rc=$?"')"
hasnt "4a. moved: no do_spl_desk_pin offer (RED on base)" "./run -a do_spl_desk_pin" "$out"
hasnt "4a. moved: no key minted" "minted" "$(cat "$STUB_LOG")"
has "4a. moved: rc 1, names B" "lives under $AU's state root" "$out"
has "4a. rc 1" "rc=1" "$out"
fresh; desk "$RA" az sat g-002
out="$(in_orc 'spl_desk_box_pub() { echo PUBKEY; }; spl_desk_spool() { echo "hub said no"; return 1; }; spl_desk_pin_check '"$RA"'/desk/az/sat sat az https://hub.invalid; echo "rc=$?"')"
has "4b. CONTROL unmoved and unpinned: the admin line" "BOX_PUBKEY=PUBKEY ROOT_KEY_JSON=<the tenant create JSON> DRY_RUN=0 ./run -a do_spl_desk_pin" "$out"
has "4b. rc 3" "rc=3" "$out"

# --- 5. the responder box -------------------------------------------------------------
fresh; desk "$RA" t1 sat-rsp c-684; desk "$RB" t1 sat-rsp c-684
out="$(in_orc 'spl_rsp_box_default() { echo sat-rsp; }; spl_desk_pin_check() { echo "PINCHECK" >>"$STUB_LOG"; return 3; }; _spl_desk_up_all_rsp t1 sat; echo "rc=$?"')"
hasnt "5. moved responder box: no pin check (RED on base: a key and an offer for t1/sat-rsp)" "PINCHECK" "$(cat "$STUB_LOG")"
has "5. one INFO line" "desk sat-rsp of t1 (prd) lives under $AU's state root" "$out"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
