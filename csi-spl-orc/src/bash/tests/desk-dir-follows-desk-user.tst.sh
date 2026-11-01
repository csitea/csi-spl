#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every ./run desk reader and writer finds a moved desk (spec 069
# section 8.3.1, SPL-4536). The desk root follows the desk user through ONE
# resolver, spl_desk_dir, not the caller's SPL_STATE_DIR. Sandbox: caller A
# (this user, home $T/home-a), desk user B (t-desk-user, home $T/home-b),
# getent a stub over both; nothing outside $T is read or written, no hub.
#   1. spl_desk_dir: a half-moved box (no SPOOL_DESK_USER yet, B is the box's
#      SPOOL_AGENT_USER) finds B's desk; SPOOL_DESK_USER=B finds it; a desk
#      that has not moved is found under A first; a missing desk returns 1
#      and the caller's path; B's root unreadable returns 3, names B and
#      prints no path (W1/W3 of the R7). B only the agent or box user, not the
#      desk user, and unreadable: best-effort, a missing desk is still rc 1
#   2. spl_desk_glob: walks A's and B's roots, A hides the same desk in B
#   3. spl_desk_issue_once (do_spl_desk_issue, the closer's leg): RED on
#      master, the desk under B only was "no desk for"; now found. Not moved:
#      found. Missing: FATAL with the do_spl_desk_up hint. B's root drwx------
#      to A: a refusal that names B and the sudo fix, never a bare "no desk for"
#   4. spl_icl_ws_announced (do_spl_issue_close_landed): reads the roster
#      cache of the desk under B (RED on master: under A only, nothing read)
#   5. spl_desk_post (do_spl_desk_post): the same desk lookup, found under B
#   6. the creators refuse on 3 (R7 W3): do_spl_desk_up_all and do_spl_desk_pin
#      against B's root drwx------ make no twin desk under A
#   7. spl_lane_issue_actor (R7 W2): a lane seated on the desk under B acts
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
chmod +x "$T/stub/getent"
printf 'SPOOL_AGENT_USER=%s\n' "$DU" >"$T/box.env.half"
printf 'SPOOL_AGENT_USER=%s\nSPOOL_DESK_USER=%s\n' "$DU" "$DU" >"$T/box.env.moved"
: >"$T/box.env.none"

has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: ${3:0:500})"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: ${3:0:500})"; }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }

# fresh: empty homes, B's root readable again.
fresh() { chmod -R u+rwx "$HB" 2>/dev/null; rm -rf "$HA" "$HB"; mkdir -p "$RA" "$HB"; }
# desk ROOT: seat c-684 on desk t1/sat-rsp under ROOT.
desk() { mkdir -p "$1/desk/t1/sat-rsp/spool/c-684/inbox"; }
# in_orc BOXENV CODE: CODE with every orc func file sourced, as the caller A
# with SPL_STATE_DIR = A's root (what do_spl_cloud_cnf sets).
in_orc() {
  env -u SPOOL_DESK_USER -u SPOOL_AGENT_USER -u SPOOL_BOX_USER PATH="$T/stub:$PATH" HOME="$HA" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_ORG_APP="$OA" ENV=prd SPL_STATE_DIR="$RA" \
    SPOOL_BOX_ENV="$1" TENANT_ID=t1 DESK_BOX=sat-rsp DESK_AGENT=c-684 bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_require_bin() { return 0; }; do_spl_desk_cnf() { return 0; }; spl_host_spool() { return 0; }
    '"$2" 2>&1
}

# --- 1. spl_desk_dir -------------------------------------------------------------
fresh; desk "$RB"
eq "1a. half-moved (agent user B, no desk user): B's desk" "$RB/desk/t1/sat-rsp" "$(in_orc "$T/box.env.half" 'spl_desk_dir t1 sat-rsp')"
eq "1b. SPOOL_DESK_USER=B: B's desk" "$RB/desk/t1/sat-rsp" "$(in_orc "$T/box.env.moved" 'spl_desk_dir t1 sat-rsp')"
out="$(in_orc "$T/box.env.none" 'spl_desk_dir t1 sat-rsp; echo " rc=$?"')"
eq "1c. CONTROL no desk or agent user named: B is not looked at" "$RA/desk/t1/sat-rsp rc=1" "$out"
desk "$RA"
eq "1d. a desk that has not moved: A's, before B's" "$RA/desk/t1/sat-rsp" "$(in_orc "$T/box.env.moved" 'spl_desk_dir t1 sat-rsp')"
fresh
out="$(in_orc "$T/box.env.moved" 'spl_desk_dir t1 sat-rsp; echo " rc=$?"')"
eq "1e. missing: return 1, the caller's path (where do_spl_desk_up seats it)" "$RA/desk/t1/sat-rsp rc=1" "$out"
if [[ "$(id -u)" != 0 ]]; then
  fresh; desk "$RB"; chmod 700 "$RB"; chmod 000 "$RB"
  out="$(in_orc "$T/box.env.moved" 'spl_desk_dir t1 sat-rsp >/dev/null; echo "rc=$?"')"
  has "1f. B's root drwx------ to A: rc 3" "rc=3" "$out"
  has "1f. the refusal names B" "is not readable by $ME" "$out"
  has "1f. the refusal names the fix" "sudo -n -u $DU" "$out"
  out="$(in_orc "$T/box.env.moved" 'spl_desk_dir t1 sat-rsp 2>/dev/null; echo "rc=$?"')"
  eq "1f. rc 3 prints no path a caller could mkdir into a twin" "rc=3" "$out"
  fresh; chmod 000 "$HB"
  out="$(in_orc "$T/box.env.half" 'spl_desk_dir t1 sat-rsp; echo " rc=$?"')"
  eq "1g. agent user B (not the desk user) unreadable, desk nowhere: rc 1, the caller's path" "$RA/desk/t1/sat-rsp rc=1" "$out"
  out="$(in_orc "$T/box.env.none" 'SPOOL_BOX_USER='"$DU"' spl_desk_dir t1 sat-rsp; echo " rc=$?"')"
  eq "1h. box user B unreadable, desk nowhere: rc 1, the caller's path" "$RA/desk/t1/sat-rsp rc=1" "$out"
  chmod 700 "$HB"
fi

# --- 2. spl_desk_glob ------------------------------------------------------------
fresh; mkdir -p "$RA/desk/t1/box-a/spool" "$RB/desk/t1/box-b/spool" "$RB/desk/t1/box-a/spool" "$RB/desk/t2/box-a/spool"
out="$(in_orc "$T/box.env.moved" 'spl_desk_glob "*/*/spool"')"
eq "2. walks both roots, A's t1/box-a hides B's" "$(printf '%s\n' "$RA/desk/t1/box-a/spool" "$RB/desk/t1/box-b/spool" "$RB/desk/t2/box-a/spool")" "$(sort <<<"$out")"

# --- 3. the desk issue leg (do_spl_issue_close_landed -> do_spl_desk_issue) ----
fresh; desk "$RB"
out="$(in_orc "$T/box.env.half" 'spl_desk_issue_once && echo READY')"
hasnt "3a. half-moved, the desk under B: no 'no desk for' (RED on master)" "no desk for" "$out"
has "3a. ready" "READY" "$out"
out="$(in_orc "$T/box.env.moved" 'spl_desk_issue_once && echo READY')"
has "3b. moved (SPOOL_DESK_USER=B): ready" "READY" "$out"
fresh; desk "$RA"
out="$(in_orc "$T/box.env.moved" 'spl_desk_issue_once && echo READY')"
has "3c. a desk that has not moved: ready" "READY" "$out"
fresh
out="$(in_orc "$T/box.env.moved" 'spl_desk_issue_once && echo READY')"
has "3d. missing: FATAL no desk" "FATAL no desk for c-684 on sat-rsp in t1: run do_spl_desk_up first" "$out"
hasnt "3d. missing: not ready" "READY" "$out"
if [[ "$(id -u)" != 0 ]]; then
  fresh; desk "$RB"; chmod 000 "$RB"
  out="$(in_orc "$T/box.env.moved" 'spl_desk_issue_once && echo READY')"
  has "3e. B's root unreadable: the refusal names B and the fix" "run this ./run action as $DU (sudo -n -u $DU" "$out"
  hasnt "3e. not ready" "READY" "$out"
  hasnt "3e. no second, wrong 'run do_spl_desk_up' FATAL (R7 N1)" "no desk for" "$out"
  chmod 700 "$RB"
fi

# --- 4. the closer's roster read (spl_icl_ws_announced) -------------------------
fresh; desk "$RB"; mkdir -p "$RB/desk/t1/sat-rsp/spool/.hub" "$RB/desk/t1/sat-rsp/spool/c-777"
printf '{"sat-rsp": ["c-777"]}\n' >"$RB/desk/t1/sat-rsp/spool/.hub/roster.json"
out="$(in_orc "$T/box.env.half" 'spl_icl_ws_announced; echo "AGENT=$DESK_AGENT"')"
has "4. the roster cache under B is read: c-684 is not announced, acting as c-777 (RED on master)" "AGENT=c-777" "$out"

# --- 5. a desk writer: do_spl_desk_post's lookup ---------------------------------
fresh; desk "$RB"
out="$(in_orc "$T/box.env.half" 'd="$(spl_desk_dir "$TENANT_ID" "$DESK_BOX")"; [[ -d "$d/spool/$DESK_AGENT" ]] && echo FOUND')"
has "5. the same lookup every converted call site makes" "FOUND" "$out"

# --- 6. the creators refuse on 3: no twin desk under A (R7 W3) -----------------
# The stubs carry each creator past its preflight to its mkdir, so a creator
# that ignored rc 3 would create the desk under A (as on 3661dc5c1).
if [[ "$(id -u)" != 0 ]]; then
  fresh; desk "$RB"; chmod 000 "$RB"
  out="$(in_orc "$T/box.env.moved" 'do_spl_cloud_cnf() { return 0; }
    spl_desk_live_agents() { echo c-684; }; _spl_desk_up_all_pick() { seat=(c-684); }
    spl_desk_dead_agents() { :; }; do_spl_desk_up() { echo UP; }
    DRY_RUN=0 do_spl_desk_up_all; echo "rc=$?"')"
  has "6a. do_spl_desk_up_all: refuses, names B" "run this ./run action as $DU" "$out"
  [[ ! -e "$RA/desk/t1/sat-rsp" ]] && pass "6a. do_spl_desk_up_all: no twin under A" || fail "6a. twin desk under A: $(ls -R "$RA/desk" 2>&1 | sed -n 1,5p)"
  fresh; desk "$RB"; chmod 000 "$RB"
  out="$(in_orc "$T/box.env.moved" 'spl_box_ws_guard() { return 0; }; SPL_HUB_URL=https://hub.invalid
    spl_desk_pin_check() { mkdir -p "$1/keys"; echo PINCHECK; }
    DRY_RUN=0 do_spl_desk_pin; echo "rc=$?"')"
  has "6b. do_spl_desk_pin: refuses, names B" "run this ./run action as $DU" "$out"
  [[ ! -e "$RA/desk/t1/sat-rsp" ]] && pass "6b. do_spl_desk_pin: no twin under A" || fail "6b. twin desk under A: $(ls -R "$RA/desk" 2>&1 | sed -n 1,5p)"
  chmod 700 "$RB"
fi

# --- 7. the lane-issue actor: a lane seated on the moved desk acts (R7 W2) ----
fresh; desk "$RB"
out="$(in_orc "$T/box.env.half" 'spl_lane_issue_announced() { return 0; }; SLI_BOX=sat-rsp DESK_AGENT=c-001
  spl_lane_issue_actor /dev/null c-684; echo "AGENT=$DESK_AGENT"')"
has "7. the lane seated under B acts itself (RED on 3661dc5c1: the desk booked it)" "AGENT=c-684" "$out"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
