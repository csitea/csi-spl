#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2584 - do_spl_desk_reply turns the hub's human post guard
#          (hub/human_post_guard.go, how-to-post.md rule 18; owner HUM-10, t1
#          4b49e47d) into a FATAL that names the rule and where the post
#          belongs, nothing sent. The desk spool is stubbed: `send` fails with
#          SEND_ERR on stderr (the hub's refusal as the spool CLI prints it),
#          else succeeds; every call is logged.
#   1. dm_not_blocker -> exit 6, the FATAL names rule 18, DESK_KIND=blocker,
#      the channel topic and the cnf ops channel (do_spl_fleet_notice)
#   2. duplicate_to_human -> exit 7, the FATAL names rule 18 and the 24 h
#   3. a duplicate in the topic of a DM about a topic (spec 067) is final: no
#      DM fallback (edge 2)
#   4. CONTROL: another send error stays exit 1 with the old FATAL; a
#      successful send (a blocker DM, an answer in a person-started DM) is
#      sent once, exit 0
#   5. do_spl_fleet_notice posts into cnf env.fleet_notices.channel, and an
#      unset key is a FATAL with nothing sent (never a DM)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
DM=44444444-4444-4444-8444-444444444444
TOPIC=55555555-5555-4555-8555-555555555555
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/c-002"
printf 'env:\n  fleet_notices:\n    channel: spool-hub-ops\n' >"$T/cnf.yaml"
# a person's DM to the desk about a channel topic (spec 067 ref_task_id)
python3 - "$T/inbox.json" "$DM" "$TOPIC" <<'EOF_PY'
import json, sys
json.dump([{"v": 1, "msg_id": "m-1", "task_id": sys.argv[2], "ts": "2026-10-19T08:52:00Z",
            "from": "HUM-10", "to": "c-002", "kind": "note", "ref_task_id": sys.argv[3],
            "body": "is this deployed?", "files": []}], open(sys.argv[1], "w"))
EOF_PY

# reply [VAR=value]... - DRY_RUN=0 against the stubbed spool; calls in
# $T/calls (args joined by "|"), the output in $T/o, the exit code in $T/rc.
reply() {
  : >"$T/calls"
  rm -f "$T/state/dev/desk/t1/box-desk/answered"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; SPL_CNF="$CNF"; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local IFS="|"; echo "$*" >>"$CALLS"
  case "$1" in
    recv) cat "$INBOX" ;;
    topics) return 1 ;;
    hub-tail) echo "{\"msg_id\":\"r-1\"}" ;;
    send) [[ -n "${SEND_ERR:-}" ]] && { echo "spool: $SEND_ERR" >&2; return 1; }
      echo "{\"msg_id\":\"s-1\",\"delivery\":\"sent\"}" ;;
  esac
}
do_spl_desk_reply' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=c-002 DESK_BODY="Dev and prd serve 1.4.2." DRY_RUN=0 \
    CALLS="$T/calls" INBOX="$T/inbox.json" CNF="$T/cnf.yaml" "$@" >"$T/o" 2>&1
  echo $? >"$T/rc"
}
sends() { grep -c '^send|' "$T/calls"; }

# --- 1. dm_not_blocker -----------------------------------------------------------------
reply DESK_TO=HUM-10 DESK_TASK="$DM" SEND_ERR="hub refused: dm_not_blocker (a DM to HUM-10 must be a blocker)"
[[ "$(cat "$T/rc")" == 6 ]] && grep -q 'FATAL nothing was sent: a DM to HUM-10 must be a blocker (DESK_KIND=blocker)' "$T/o" &&
  grep -q 'how-to-post.md rule 18' "$T/o" && grep -q 'DESK_TASK=<that topic>' "$T/o" && grep -q 'do_spl_fleet_notice (#spool-hub-ops)' "$T/o" &&
  pass "1. a refused non-blocker DM: exit 6, the FATAL names rule 18, the channel topic and #spool-hub-ops" ||
  fail "1. rc=$(cat "$T/rc") out=$(cat "$T/o")"

# --- 2. duplicate_to_human -------------------------------------------------------------
reply DESK_TO=HUM-10 DESK_TASK="$TOPIC" SEND_ERR="hub refused: duplicate_to_human (HUM-10 already got this text)"
[[ "$(cat "$T/rc")" == 7 ]] && grep -q 'FATAL nothing was sent: HUM-10 already got this text from an agent in the last 24 h' "$T/o" &&
  grep -q 'how-to-post.md rule 18' "$T/o" &&
  pass "2. a refused duplicate: exit 7, the FATAL names rule 18 and the 24 h" || fail "2. rc=$(cat "$T/rc") out=$(cat "$T/o")"

# --- 3. a duplicate in the topic is final: no DM fallback ------------------------------
reply SEND_ERR="hub refused: duplicate_to_human (HUM-10 already got this text)"
[[ "$(cat "$T/rc")" == 7 && "$(sends)" == 1 ]] && grep -q -- "--task|$TOPIC|" "$T/calls" && ! grep -q 'spec 067 edge 2' "$T/o" &&
  pass "3. a duplicate refused in the topic is not re-sent as a DM (one send, exit 7)" ||
  fail "3. rc=$(cat "$T/rc") calls=$(cat "$T/calls") out=$(cat "$T/o")"

# --- 4. controls -----------------------------------------------------------------------
reply DESK_TO=HUM-10 DESK_TASK="$DM" SEND_ERR="hub refused: unpinned_box"
[[ "$(cat "$T/rc")" == 1 ]] && grep -q "FATAL send c-002 -> HUM-10 in task $DM" "$T/o" && ! grep -q 'nothing was sent' "$T/o" &&
  pass "4. CONTROL: another send error stays exit 1, no rule-18 FATAL" || fail "4. other error rc=$(cat "$T/rc") out=$(cat "$T/o")"
reply DESK_TO=HUM-10 DESK_TASK="$DM" DESK_KIND=blocker
[[ "$(cat "$T/rc")" == 0 && "$(sends)" == 1 ]] && grep -q -- '--kind|blocker' "$T/calls" &&
  pass "4. CONTROL: a blocker DM the hub accepts is sent once, exit 0" || fail "4. blocker rc=$(cat "$T/rc") out=$(cat "$T/o")"

# --- 5. do_spl_fleet_notice ------------------------------------------------------------
notice() {
  SNIPPET='do_spl_desk_cnf() { SPL_CNF="$CNF"; }
do_spl_fleet_notice' in_orc TENANT_ID=t1 DESK_AGENT=g-001 DESK_BODY="Orchestrator failover: g-001@sat took over" DRY_RUN=0 \
    FLEET_NOTICE_CMD="$T/bin/notice" "$@" >"$T/o" 2>&1
  echo $? >"$T/rc"
}
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$1 $2 $(cat)" >>"%s/notice.log"\n' "$T" >"$T/bin/notice"; chmod +x "$T/bin/notice"
notice CNF="$T/cnf.yaml"
[[ "$(cat "$T/rc")" == 0 && "$(cat "$T/notice.log")" == "spool-hub-ops note Orchestrator failover: g-001@sat took over" ]] &&
  pass "5. do_spl_fleet_notice posts into the cnf ops channel (#spool-hub-ops)" || fail "5. rc=$(cat "$T/rc") log=$(cat "$T/notice.log" 2>&1) out=$(cat "$T/o")"
printf 'env: {}\n' >"$T/empty.yaml"; rm -f "$T/notice.log"
notice CNF="$T/empty.yaml"
[[ "$(cat "$T/rc")" != 0 && ! -e "$T/notice.log" ]] && grep -q 'FATAL env.fleet_notices.channel is not set' "$T/o" &&
  pass "5. no env.fleet_notices.channel: FATAL, nothing posted (never a DM)" || fail "5. unset rc=$(cat "$T/rc") out=$(cat "$T/o")"

echo
if (( fails > 0 )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASSED"
