#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: owner t1 48d09034 - do_spl_desk_reply prints the permalink of the
#          post it just sent, so the agent keeps it and cites it later.
#   1. DRY_RUN=0, spool stubbed: the JSON line carries
#      permalink = <wui>/m/<sent msg_id>, and an OK line repeats it
#   2. DESK_WUI_URL overrides the base (a trailing slash is dropped)
#   3. CONTROL: no WUI base known -> no permalink key, the reply still succeeds
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=b280b0e8-1111-4222-8333-444455556666
SENT_ID=4f0c2a10-aaaa-4bbb-8ccc-0123456789ab
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"

# send <wui base for the cnf stub> [VAR=val ...] -> output in $T/o, rc in $rc
send() {
  local base="$1"; shift
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; SPL_WUI_URL="'"$base"'"; }
spl_host_spool() { :; }
spl_desk_spool() { echo "{\"msg_id\":\"'"$SENT_ID"'\"}"; }
do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-1 DESK_TASK="$TOPIC" \
    DESK_KIND=blocker DESK_BODY="Which env first?" DRY_RUN=0 "$@" >"$T/o" 2>&1
  rc=$?
}
link_of() { grep '^{' "$T/o" | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline()).get("permalink","-"))'; }

# --- 1. the env's WUI ---------------------------------------------------------------
send https://wui.invalid
if (( rc == 0 )) && [[ "$(link_of)" == "https://wui.invalid/m/$SENT_ID" ]] &&
  grep -q "OK permalink https://wui.invalid/m/$SENT_ID" "$T/o"; then
  pass "the reply prints <wui>/m/<sent msg_id> in the JSON and on an OK line"
else
  fail "no permalink (rc $rc): $(cat "$T/o")"
fi

# --- 2. DESK_WUI_URL overrides ------------------------------------------------------
send https://wui.invalid DESK_WUI_URL=https://t1.wui.invalid/
[[ "$(link_of)" == "https://t1.wui.invalid/m/$SENT_ID" ]] &&
  pass "DESK_WUI_URL is the permalink base" || fail "DESK_WUI_URL ignored: $(cat "$T/o")"

# --- 3. CONTROL: no base ------------------------------------------------------------
send ""
if (( rc == 0 )) && [[ "$(link_of)" == "-" ]] && ! grep -q "OK permalink" "$T/o"; then
  pass "CONTROL: no WUI base, no permalink, the reply still succeeds"
else
  fail "control broke (rc $rc): $(cat "$T/o")"
fi

echo "desk-reply-permalink: $fails failure(s)"
((fails == 0))
