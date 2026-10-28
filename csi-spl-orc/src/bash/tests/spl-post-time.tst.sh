#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 157 Rule 6, row B1 (SPL-4023) - machine-stamped UTC times in
#          desk posts (spl-post-time.func.sh). On 2026-10-25 an agent typed
#          its local hour with a `Z`: well formed, an hour wrong. A post now
#          writes {{NOW_UTC}} / {{TODAY_UTC}} / {{NOW_ISO}} and the machine
#          fills it in; a colloquial time is refused, never converted.
#   1. RED CONTROL: `at 3pm today` is refused by do_spl_desk_reply, the FATAL
#      names the time and the grammar, nothing reaches the spool
#   2. RED CONTROLS: a clock time with no zone, a named zone (EEST), an ISO
#      date-time with no zone, an unknown token -> refused, nothing sent
#   3. `Taken at {{NOW_UTC}}` -> sent with the machine's UTC time (pinned
#      SPL_POST_TIME_EPOCH, and the real clock), all three tokens from one
#      reading
#   4. the section 4 forms (10:4xZ, ISO +03:00, ranges, 07:05:30Z) -> sent
#      byte for byte
#   5. a time in `code` or a fenced block, a port, a sha -> sent unchanged
#   6. do_spl_desk_post: the same refusal and expansion on a channel post
#   7. do_spl_post_time: the stamps, a draft filled in, a refused draft rc 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=157b1000-0000-4000-8000-000000000001
EPOCH=1761412530 # 2025-10-25T17:15:30Z

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_lease_gate() { :; }
spl_desk_human_gate() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a prev=""; for a in "$@"; do [[ "$prev" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}'

# send <action> <body> [VAR=value]... -> rc; output in $T/o, the sent body in $T/sent
send() {
  local act="$1" body="$2"; shift 2
  rm -f "$T/sent"
  SNIPPET="$STUBS"$'\n'"$act" in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-10 DESK_TASK="$TOPIC" \
    DESK_CHANNEL=ops DESK_BODY="$body" DRY_RUN=0 SENT_BODY="$T/sent" "$@" >"$T/o" 2>&1
}
refused() { # <label> <must-name>...: rc != 0, nothing sent, the FATAL names each piece and the grammar
  local label="$1" n ok=1; shift
  (( rc != 0 )) && [[ ! -e "$T/sent" ]] && grep -q 'FATAL nothing was sent: write a time the reader' "$T/o" &&
    grep -q 'how-to-post.md section 4, spec 157 Rule 6' "$T/o" || ok=0
  for n in "$@"; do grep -qF -- "$n" "$T/o" || ok=0; done
  (( ok )) && pass "$label" || fail "$label (rc $rc): $(cat "$T/o")"
}
sent() { # <label> <body>: rc 0 and that body reached the spool byte for byte
  (( rc == 0 )) && [[ -f "$T/sent" && "$(cat "$T/sent")" == "$2" ]] && ! grep -q FATAL "$T/o" &&
    pass "$1" || fail "$1 (rc $rc, sent '$(cat "$T/sent" 2>/dev/null)'): $(cat "$T/o")"
}

# --- 1. RED CONTROL: a colloquial time ----------------------------------------------
send do_spl_desk_reply 'The deploy runs at 3pm today.'; rc=$?
refused "1. 'at 3pm today' is refused, nothing sent" 'FATAL post time: colloquial time "3pm"'
send do_spl_desk_reply 'The deploy runs at {{NOW_UTC}} today.' SPL_POST_TIME_EPOCH=$EPOCH; rc=$?
sent "1. CONTROL: the same post with {{NOW_UTC}} is sent, filled in" 'The deploy runs at 17:15:30Z today.'

# --- 2. RED CONTROLS: no zone, a named zone, ISO with no zone, an unknown token -------
send do_spl_desk_reply 'Started at 10:45, done.'; rc=$?
refused "2. a clock time with no zone is refused" 'colloquial time "10:45"'
send do_spl_desk_reply 'Started 13:45 EEST.'; rc=$?
refused "2. a named zone is refused (never converted)" 'colloquial time "13:45 EEST"'
send do_spl_desk_reply 'At 2026-10-25T10:15:30 it broke.'; rc=$?
refused "2. an ISO date-time with no zone is refused" 'colloquial time "10:15:30"'
send do_spl_desk_reply 'At {{NOW_LOCAL}} it broke.'; rc=$?
refused "2. an unknown token is refused" 'unknown time token {{NOW_LOCAL}}'
send do_spl_desk_reply 'At 9 a.m. and 11:30 PM.'; rc=$?
refused "2. both colloquial times are named" 'colloquial time "9 a.m."' 'colloquial time "11:30 PM"'

# --- 3. tokens -------------------------------------------------------------------------
send do_spl_desk_reply 'Taken at {{NOW_UTC}} on {{TODAY_UTC}} ({{NOW_ISO}}).' SPL_POST_TIME_EPOCH=$EPOCH; rc=$?
sent "3. all three tokens filled from one clock reading" 'Taken at 17:15:30Z on 2025-10-25 (2025-10-25T17:15:30Z).'
before="$(date -u +%s)"
send do_spl_desk_reply 'Taken at {{NOW_ISO}}'; rc=$?
after="$(date -u +%s)"
got="$(cat "$T/sent" 2>/dev/null)"; ok=0
for ((s = before; s <= after; s++)); do [[ "$got" == "Taken at $(date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ)" ]] && ok=1; done
(( rc == 0 && ok )) && pass "3. unpinned: the machine's own UTC clock ($got)" || fail "3. unpinned (rc $rc): '$got' $(cat "$T/o")"

# --- 4. section 4 forms pass unaltered ------------------------------------------------------
B='About 10:4xZ; at 2026-10-25T10:15:30+03:00; 10:15-10:17Z, 09:53Z..10:23Z, 07:05:30Z and 2026-10-25T07:05Z.'
send do_spl_desk_reply "$B"; rc=$?
sent "4. the section 4 forms are sent byte for byte" "$B"

# --- 5. code, ports, shas -------------------------------------------------------------------
B='Log `12:03:44 boot` and 127.0.0.1:8080, sha 1f5e074b, 3 amendments.'$'\n''```'$'\n''10:45 a log line'$'\n''```'
send do_spl_desk_reply "$B"; rc=$?
sent "5. times in code, a port, a sha are sent unchanged" "$B"

# --- 6. do_spl_desk_post ----------------------------------------------------------------------
send do_spl_desk_post 'Window opens at 3pm.'; rc=$?
refused "6. do_spl_desk_post refuses a colloquial time" 'colloquial time "3pm"'
send do_spl_desk_post 'Window opened {{NOW_UTC}}.' SPL_POST_TIME_EPOCH=$EPOCH; rc=$?
sent "6. do_spl_desk_post fills {{NOW_UTC}}" 'Window opened 17:15:30Z.'

# --- 7. the action ------------------------------------------------------------------------------
SNIPPET=do_spl_post_time in_orc SPL_POST_TIME_EPOCH=$EPOCH >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$T/o")" == $'17:15:30Z\n2025-10-25\n2025-10-25T17:15:30Z' ]] &&
  pass "7. do_spl_post_time prints the three stamps" || fail "7. stamps (rc $rc): $(cat "$T/o")"
SNIPPET=do_spl_post_time in_orc SPL_POST_TIME_EPOCH=$EPOCH POST_TIME_BODY='at {{NOW_UTC}}' >"$T/o" 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$T/o")" == 'at 17:15:30Z' ]] && pass "7. a draft is printed filled in" || fail "7. draft (rc $rc): $(cat "$T/o")"
SNIPPET=do_spl_post_time in_orc POST_TIME_BODY='at 3pm' >"$T/o" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q 'colloquial time "3pm"' "$T/o" && ! grep -qx 'at 3pm' "$T/o" &&
  pass "7. a refused draft: rc $rc, the FATAL, no body" || fail "7. refused draft (rc $rc): $(cat "$T/o")"

echo "spl-post-time: $fails failure(s)"
((fails == 0))
