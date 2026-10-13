#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_local_hub_agent_join / _leave (SPL-1625, local hub lane L7):
#          a box agent joins the LOCAL hub only with a join token the
#          workspace admin minted there, never a cloud hub, and leaves again;
#          none is seated by default.
#   1. no tenant, no agent, no token on a never-joined box: refused, and
#      do_spl_desk_up is never called (nobody is seated by default)
#   2. a cloud or any non-loopback hub URL, ENV=dev|prd, a ROOT_KEY_JSON, a
#      token in the environment (SPOOL_JOIN_TOKEN), a token file that is not
#      0600 or that belongs to another workspace: each refused, desk_up uncalled
#   3. a valid token file seats the agent on its OWN box lh-<agent> at
#      http://127.0.0.1:<hub port>, ENV=self, in the local-hub state dir; the
#      token never reaches the output; CONTROL a cloud SPL_STATE_DIR in the
#      caller's env is not used; the lead's cnf lib (spl_local_hub_cnf), when
#      loaded, is what sets the tenant and the port
#   4. a box that already joined re-seats with no token
#   4b. an agent is dedicated to ONE workspace: a join to a second is refused
#   5. leave: a dry run touches nothing; DRY_RUN=0 stops that box's sidecar
#      (DESK_ALL=1, the box is the agent's own), keeps the inbox under left/,
#      and forgets the box key, so a rejoin needs a fresh token
# do_spl_desk_up / do_spl_desk_down are stubs that record their env: no
# spool, no hub, no tmux.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

in_orc() {
  env -u SPOOL_JOIN_TOKEN -u ROOT_KEY_JSON -u SPOOL_HUB_URL -u ENV -u LOCAL_HUB_HUB_PORT -u LOCAL_HUB_TENANT \
      PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/cloud-state" \
      SPOOL_ROOT="$T/spool" CALLS="$T/calls" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    if [[ -n "${LIB_PORT:-}" ]]; then
      spl_local_hub_cnf() { LOCAL_HUB_HUB_PORT="$LIB_PORT"; }
      spl_local_hub_private_cnf() { LOCAL_HUB_TENANT="$LIB_TENANT"; }
    else
      unset -f spl_local_hub_cnf spl_local_hub_private_cnf
    fi
    do_spl_desk_up() {
      echo "up ENV=$ENV TENANT_ID=$TENANT_ID DESK_AGENT=$DESK_AGENT DESK_BOX=$DESK_BOX SPOOL_HUB_URL=$SPOOL_HUB_URL SPL_STATE_DIR=$SPL_STATE_DIR DRY_RUN=${DRY_RUN:-} TOKEN=${SPOOL_JOIN_TOKEN:-none}" >>"$CALLS"
      [[ "${DRY_RUN:-1}" == 0 ]] || return 0
      mkdir -p "$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX/keys" "$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX/spool/$DESK_AGENT/inbox"
      echo pub >"$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX/pinned"
    }
    do_spl_desk_down() { echo "down ENV=$ENV TENANT_ID=$TENANT_ID DESK_BOX=$DESK_BOX DESK_ALL=${DESK_ALL:-} SPL_STATE_DIR=$SPL_STATE_DIR DRY_RUN=${DRY_RUN:-}" >>"$CALLS"; }
    "$ACTION"'
}
join() { in_orc ACTION=do_spl_local_hub_agent_join "$@"; }
leave() { in_orc ACTION=do_spl_local_hub_agent_leave "$@"; }
calls() { cat "$T/calls" 2>/dev/null; }

LH="$T/home/.local/share/$(basename "$PROJ_ROOT" | sed 's/-orc$//')/local-hub"
TOK="$T/tok"; printf 'spj1.ws-test.s3cr3tvalue\n' >"$TOK"; chmod 600 "$TOK"
OK=(LOCAL_HUB_TENANT=ws-test DESK_AGENT=c-123)

# --- 1. nothing seated by default ---------------------------------------------------
out=$(join DESK_AGENT=c-123 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"LOCAL_HUB_TENANT"* ]] && pass "no LOCAL_HUB_TENANT is refused" || fail "no tenant (rc=$rc): $out"
out=$(join LOCAL_HUB_TENANT=ws-test 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"DESK_AGENT"* ]] && pass "no DESK_AGENT is refused" || fail "no agent (rc=$rc): $out"
out=$(join "${OK[@]}" DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"join token"* ]] && pass "a never-joined box with no token is refused: none seated by default" ||
  fail "no token (rc=$rc): $out"
[[ -z "$(calls)" ]] && pass "CONTROL do_spl_desk_up was never called" || fail "desk_up called: $(calls)"

# --- 2. refusals --------------------------------------------------------------------
refused() { # <label> <want substring> <env...>
  local label="$1" want="$2"; shift 2
  out=$(join "${OK[@]}" LOCAL_HUB_JOIN_TOKEN_FILE="$TOK" DRY_RUN=0 "$@" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"$want"* && "$out" != *s3cr3t* ]] && pass "$label is refused" || fail "$label (rc=$rc): $out"
}
refused "a cloud hub URL" "loopback" SPOOL_HUB_URL=https://api.example.com
refused "a LAN hub URL" "loopback" SPOOL_HUB_URL=http://10.0.0.5:58180
refused "ENV=prd" "ENV" ENV=prd
refused "a ROOT_KEY_JSON" "ROOT_KEY_JSON" ROOT_KEY_JSON=/nonexistent
refused "a token in the environment" "LOCAL_HUB_JOIN_TOKEN_FILE" SPOOL_JOIN_TOKEN=spj1.ws-test.x
refused "a bad hub port" "LOCAL_HUB_HUB_PORT" LOCAL_HUB_HUB_PORT=99999
chmod 644 "$TOK"; refused "a token file that is not 0600" "0600"; chmod 600 "$TOK"
OTHER="$T/other"; printf 'spj1.ws-other.zzz\n' >"$OTHER"; chmod 600 "$OTHER"
refused "a token of another workspace" "another workspace" LOCAL_HUB_JOIN_TOKEN_FILE="$OTHER"
[[ -z "$(calls)" ]] && pass "CONTROL no refusal called do_spl_desk_up" || fail "desk_up called: $(calls)"

# --- 3. join with a token -----------------------------------------------------------
out=$(join "${OK[@]}" DESK_AGENT=CLE-07 LIB_PORT=58199 LIB_TENANT=ws-test LOCAL_HUB_TENANT= LOCAL_HUB_JOIN_TOKEN_FILE="$TOK" 2>&1); rc=$?
[[ $rc -eq 0 && "$(calls)" == *"TENANT_ID=ws-test "*"DESK_BOX=lh-cle-07 SPOOL_HUB_URL=http://127.0.0.1:58199 "*"DRY_RUN=1 "* ]] &&
  pass "dry run by default; the cnf lib sets tenant and port; a legacy id is lower-cased into the box" || fail "lib/dry (rc=$rc): $out | $(calls)"
: >"$T/calls"
out=$(join "${OK[@]}" LOCAL_HUB_JOIN_TOKEN_FILE="$TOK" DRY_RUN=0 2>&1); rc=$?
want="up ENV=self TENANT_ID=ws-test DESK_AGENT=c-123 DESK_BOX=lh-c-123 SPOOL_HUB_URL=http://127.0.0.1:58180 SPL_STATE_DIR=$LH DRY_RUN=0 TOKEN=spj1.ws-test.s3cr3tvalue"
[[ $rc -eq 0 && "$(calls)" == "$want" ]] && pass "a token seats c-123 on its own box lh-c-123 at the loopback hub, ENV=self, local-hub state" ||
  fail "join (rc=$rc): $out | calls: $(calls)"
[[ "$out" != *s3cr3t* ]] && pass "the token never reaches the output" || fail "token leaked: $out"
[[ ! -e "$T/cloud-state" ]] && pass "CONTROL the caller's cloud SPL_STATE_DIR is not used" || fail "cloud state touched"

# --- 4. re-seat after a join --------------------------------------------------------
: >"$T/calls"
out=$(join "${OK[@]}" DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$(calls)" == *"DESK_BOX=lh-c-123 "*"TOKEN=none" ]] && pass "a box that joined re-seats with no token" ||
  fail "re-seat (rc=$rc): $out | $(calls)"

# --- 4b. dedicated: one agent serves one workspace -------------------------------
: >"$T/calls"
TOK2="$T/tok2"; printf 'spj1.ws-two.zzz\n' >"$TOK2"; chmod 600 "$TOK2"
out=$(join LOCAL_HUB_TENANT=ws-two DESK_AGENT=c-123 LOCAL_HUB_JOIN_TOKEN_FILE="$TOK2" DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"dedicated to another workspace"* && -z "$(calls)" ]] &&
  pass "an agent joined to one workspace is refused a second one" || fail "second workspace (rc=$rc): $out | $(calls)"
out=$(join LOCAL_HUB_TENANT=ws-two DESK_AGENT=c-456 LOCAL_HUB_JOIN_TOKEN_FILE="$TOK2" DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$(calls)" == *"TENANT_ID=ws-two DESK_AGENT=c-456 DESK_BOX=lh-c-456 "* ]] &&
  pass "CONTROL another agent joins the second workspace on its own box" || fail "c-456 (rc=$rc): $out | $(calls)"

# --- 5. leave -----------------------------------------------------------------------
B="$LH/desk/ws-test/lh-c-123"
: >"$T/calls"
out=$(leave "${OK[@]}" 2>&1); rc=$?
[[ $rc -eq 0 && -s "$B/pinned" && -d "$B/keys" && "$out" == *"DRY_RUN"* ]] && pass "a leave dry run touches nothing" ||
  fail "leave dry (rc=$rc): $out"
: >"$T/calls"
out=$(leave "${OK[@]}" DRY_RUN=0 2>&1); rc=$?
left=( "$LH"/left/ws-test/lh-c-123.* )
[[ $rc -eq 0 && "$(calls)" == *"down ENV=self TENANT_ID=ws-test DESK_BOX=lh-c-123 DESK_ALL=1 SPL_STATE_DIR=$LH DRY_RUN=0"* ]] &&
  pass "leave stops the sidecar of lh-c-123 only (DESK_ALL=1 on the agent's own box)" || fail "leave (rc=$rc): $out | $(calls)"
[[ ! -e "$B" && ${#left[@]} -eq 1 && -d "${left[0]}/spool/c-123/inbox" && ! -e "${left[0]}/keys" && ! -e "${left[0]}/pinned" ]] &&
  pass "leave keeps the inbox under left/ and forgets the box key and pin" || fail "leave state: $(find "$LH" | sort)"
[[ "$out" == *"Settings -> Agents"* ]] && pass "leave tells the owner where to revoke the seat" || fail "no revoke hint: $out"
: >"$T/calls"
out=$(join "${OK[@]}" DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && -z "$(calls)" ]] && pass "after a leave a rejoin needs a fresh token" || fail "rejoin without token (rc=$rc): $out"
out=$(leave "${OK[@]}" DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"not joined"* ]] && pass "leaving twice is OK (idempotent)" || fail "second leave (rc=$rc): $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all local-hub-agent-join.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
