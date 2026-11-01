#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the spl_desk_dir callers SPL-4536 left unchecked return on its rc 3
# (SPL-4555, R7 c-835 N1). rc 3 = the desk sits under the desk user's root
# this user cannot read; spl_desk_dir then prints NO path and one refusal line
# naming the desk user and the fix. An unchecked caller built every later path
# under / (/spool/...). Sandbox as in desk-dir-follows-desk-user.tst.sh:
# caller A (this user, home $T/home-a), desk user B (t-desk-user, home
# $T/home-b, root chmod 000), getent a stub; no hub, nothing outside $T.
#   1. fail closed, the refusal is the one line (no second "no desk for"):
#      do_spl_marketing_publish, spl_lane_issue_hub_body,
#      spl_issue_owner_go_from (no spool call with an empty desk)
#   2. soft, the caller's own soft path, the refusal shown, nothing under /:
#      spl_icl_ws_announced (return 0, no /spool/.hub read),
#      _spl_desk_welcome_ensure_plan (skip, never decide "no greeter" for
#      good), box_deploy_drop_retired (row kept), spl_lane_issue_actor (the
#      desk acts), spl_dispatch_desk (rc 3, no path) and spl_dispatch_seated
# Root reads every dir: the cases need a non-root user and are skipped as root.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
[[ "$(id -u)" != 0 ]] || { echo "SKIP as root: root reads every dir"; echo "ALL PASS"; exit 0; }
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
printf 'SPOOL_AGENT_USER=%s\nSPOOL_DESK_USER=%s\n' "$DU" "$DU" >"$T/box.env"
REFUSAL="run this ./run action as $DU (sudo -n -u $DU"

has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: ${3:0:500})"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: ${3:0:500})"; }
once() { local n; n="$(grep -cF -- "$2" <<<"$3")"; [[ "$n" == 1 ]] && pass "$1" || fail "$1 (want 1 '$2', got $n in: ${3:0:500})"; }

# the desk t1/sat-rsp with c-684 seated under B, B's root drwx------ to A.
unreadable() {
  chmod -R u+rwx "$HB" 2>/dev/null; rm -rf "$HA" "$HB" "$T/calls"; mkdir -p "$RA" "$HB"
  mkdir -p "$RB/desk/t1/sat-rsp/spool/c-684/inbox"; chmod 000 "$RB"
}
# in_orc CODE: CODE with every orc func file sourced, as A with SPL_STATE_DIR =
# A's root. spl_desk_spool records the desk it is handed in $CALLS.
in_orc() {
  env -u SPOOL_DESK_USER -u SPOOL_AGENT_USER -u SPOOL_BOX_USER PATH="$T/stub:$PATH" HOME="$HA" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_ORG_APP="$OA" ENV=prd SPL_STATE_DIR="$RA" \
    SPOOL_BOX_ENV="$T/box.env" TENANT_ID=t1 DESK_BOX=sat-rsp DESK_AGENT=c-684 CALLS="$T/calls" SPL_HUB_URL=https://hub.invalid bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_require_bin() { return 0; }; do_spl_desk_cnf() { return 0; }; spl_host_spool() { return 0; }
    spl_desk_issue_once() { return 0; }; spl_desk_spool() { echo "desk=[$1]" >>"$CALLS"; }
    '"$1" 2>&1
}

# --- 1. fail closed --------------------------------------------------------------
unreadable
out="$(in_orc 'spl_desk_validate() { return 0; }; curl() { echo "{}"; }
  _spl_marketing_publish_post() { printf "T\nhttps://example.com/p\nC\n"; }
  SPL_WUI_URL=https://example.com
  POST_ID=2026-10-14-a-post FOR_HUM=HUM-10 DRY_RUN=0 do_spl_marketing_publish; echo "rc=$?"')"
has "1a. do_spl_marketing_publish: fails closed" "rc=1" "$out"
once "1a. the refusal is the one line" "$REFUSAL" "$out"
hasnt "1a. no second 'no desk for' FATAL (RED on d5cd7dd30)" "no desk for" "$out"
unreadable
out="$(in_orc 'SLI_BOX=sat-rsp spl_lane_issue_hub_body t-1 m-1; echo "rc=$?"')"
has "1b. spl_lane_issue_hub_body: fails closed" "rc=1" "$out"
once "1b. the refusal is the one line" "$REFUSAL" "$out"
[[ ! -e "$T/calls" ]] && pass "1b. no spool call with an empty desk (RED on d5cd7dd30)" || fail "1b. spool called: $(cat "$T/calls")"
unreadable
out="$(in_orc 'ISSUE_DISCUSSIONS=t-1 spl_issue_owner_go_from m-1; echo "rc=$?"')"
has "1c. spl_issue_owner_go_from: fails closed" "rc=1" "$out"
once "1c. the refusal is the one line" "$REFUSAL" "$out"
[[ ! -e "$T/calls" ]] && pass "1c. no spool call with an empty desk (RED on d5cd7dd30)" || fail "1c. spool called: $(cat "$T/calls")"

# --- 2. soft: the caller's own soft path, nothing under / ------------------------
unreadable
out="$(in_orc 'python3() { echo "py $*" >>"$CALLS"; return 1; }; spl_icl_ws_announced; echo "rc=$? AGENT=$DESK_AGENT"')"
has "2a. spl_icl_ws_announced: checks nothing, rc 0" "rc=0 AGENT=c-684" "$out"
hasnt "2a. no read of /spool/.hub/roster.json (RED on d5cd7dd30)" " /spool/.hub" "$(cat "$T/calls" 2>/dev/null)"
once "2a. the refusal is shown" "$REFUSAL" "$out"
unreadable
out="$(in_orc 'D="$HOME/led/HUM-1"; _spl_desk_welcome_ensure_plan "$D" t1 sat-rsp HUM-1 c-684; echo "rc=$?"; ls "$D" 2>/dev/null')"
has "2b. _spl_desk_welcome_ensure_plan: skipped" "rc=1" "$out"
hasnt "2b. no 'no greeter' decided for good (RED on d5cd7dd30: done written)" "done" "$out"
once "2b. the refusal is shown" "$REFUSAL" "$out"
unreadable
out="$(in_orc 'echo desk:t1/sat-rsp | box_deploy_drop_retired')"
has "2c. box_deploy_drop_retired: the row is kept" "desk:t1/sat-rsp" "$out"
once "2c. the refusal is shown (RED on d5cd7dd30: swallowed)" "$REFUSAL" "$out"
unreadable
out="$(in_orc 'spl_lane_issue_announced() { return 0; }; SLI_BOX=sat-rsp DESK_AGENT=c-001
  spl_lane_issue_actor /dev/null c-684; echo "AGENT=$DESK_AGENT"')"
has "2d. spl_lane_issue_actor: the desk acts" "AGENT=c-001" "$out"
once "2d. the refusal is shown (RED on d5cd7dd30: swallowed)" "$REFUSAL" "$out"
unreadable
out="$(in_orc 'DISPATCH_STATE_DIR="$SPL_STATE_DIR" DISPATCH_DESK_BOX=sat-rsp
  echo "path=[$(spl_dispatch_desk t1)] rc=$?"')"
has "2e. spl_dispatch_desk: no path, rc 3 (RED on d5cd7dd30: rc=0)" "path=[] rc=3" "$out"
once "2e. the refusal is shown (RED on d5cd7dd30: swallowed)" "$REFUSAL" "$out"
out="$(in_orc 'DISPATCH_STATE_DIR="$SPL_STATE_DIR" DISPATCH_DESK_BOX=sat-rsp
  spl_dispatch_seated c-684 t1; echo "rc=$?"')"
hasnt "2f. spl_dispatch_seated: not seated here, quietly" "rc=0" "$out"
hasnt "2f. no refusal on the quiet probe" "$REFUSAL" "$out"

chmod -R u+rwx "$HB" 2>/dev/null
[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
