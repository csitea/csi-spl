#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1265 / epic SPL-1238: the PERMANENT, NON-AI responder for
# @description unheard human posts. It is a dedicated desk agent (default
# @description RSP-01 on box-rsp) seated per fallback-on tenant; because it is
# @description in no channel, EVERY message the hub delivers to it is an
# @description escalation (an SPL-997/SPL-1225 fallback frame). For each one,
# @description one pass of this action:
# @description   (a) posts a visible "Seen: routed to the team" reply into the
# @description       topic (DESK_TO = the human, DESK_TASK = the topic), so the
# @description       owner sees the post was received;
# @description   (b) forwards the escalation as a FILE into RESP_FORWARD_TO's
# @description       inbox (default CLE-001) - a file cannot be refused the way
# @description       a busy pane refuses a poke (the SPL-1225 miss, 4b0ba40a);
# @description   (c) acks it so it is handled once.
# @description No model, no prompt: it cannot stall on a rate limit or unsent
# @description text. Run in a loop by the systemd service (do_spl_responder
# @description _install); the every-3-min watchdog is the safety net.
# @description The loud #spool-hub-ops tier (a post unanswered past
# @description RESP_ALERT_AFTER) is do_spl_report_unheard + do_spl_desk_post,
# @description driven by the watchdog, not this hot path.
# @description Sends real messages, so it is a DRY RUN unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant whose RSP desk to drain
# @param DESK_AGENT (optional) - the responder agent, default RSP-01
# @param DESK_BOX (optional) - the responder box, default box-rsp
# @param RESP_FORWARD_TO (optional) - who the escalation is filed to, default CLE-001
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_responder_run
#------------------------------------------------------------------------------
do_spl_responder_run() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-rsp}" agent="${DESK_AGENT:-RSP-01}"
  local fwd="${RESP_FORWARD_TO:-CLE-001}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$fwd" =~ ^[A-Z]{2,4}-[0-9]+$ ]] || { do_log "FATAL RESP_FORWARD_TO must be an agent id, got: '$fwd'"; return 1; }
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local d="$SPL_STATE_DIR/desk/$tenant/$box" api_fqdn hub
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  hub="https://$api_fqdn"
  [[ -d "$d/spool" ]] || { do_log "FATAL responder $agent on $box in $tenant is not seated ($d); seat it with do_spl_desk_up"; return 1; }
  spl_host_spool || return 1

  local recvf; recvf="$(mktemp "${TMPDIR:-/tmp}/spl-responder-recv.XXXXXX")" || return 1
  if ! spl_desk_spool "$d" "$box" "$tenant" "$hub" -- recv --as "$agent" >"$recvf" 2>&1; then
    do_log "FATAL recv --as $agent on $box: $(cat "$recvf")"; rm -f "$recvf"; return 1
  fi
  # Parse the inbox into TAB-separated (msg_id, from, task_id) lines. Every
  # message to a channel-less responder is an escalation to answer.
  local rows; rows="$(python3 - "$recvf" <<'PY'
import json, sys
try:
    msgs = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for m in msgs or []:
    frm, task, mid = m.get("from", ""), m.get("task_id", ""), m.get("msg_id", "")
    if frm.startswith("HUM-") and task and mid:
        print(f"{mid}\t{frm}\t{task}")
PY
)"
  rm -f "$recvf"
  if [[ -z "$rows" ]]; then
    do_log "OK $agent ($tenant): no escalation waiting"
    return 0
  fi

  local send="$APP_PATH/$SPL_ORG_APP-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
  local n=0 fails=0 line mid frm task
  while IFS=$'\t' read -r mid frm task; do
    [[ -n "$mid" ]] || continue
    if (( dry )); then
      do_log "INFO DRY_RUN would: reply 'Seen: routed to the team' to $frm in topic $task, file msg $mid to $fwd, and ack it"
      n=$((n + 1)); continue
    fi
    # (a) the visible "Seen" reply into the topic
    if ! ENV="$ENV" TENANT_ID="$tenant" DESK_AGENT="$agent" DESK_BOX="$box" \
         DESK_TO="$frm" DESK_TASK="$task" DESK_ACK=1 \
         DESK_BODY="Seen: routed to the team." DRY_RUN=0 do_spl_desk_reply >/dev/null 2>&1; then
      do_log "FAIL $agent could not reply to $frm in $task (msg $mid)"; fails=$((fails + 1)); continue
    fi
    # (b) forward the escalation as a FILE to the orchestrator (never refused)
    local body; body="$(printf 'Unheard human post escalated by the responder (%s, tenant %s).\nFrom %s, topic %s, msg %s.\nReply in the topic; the responder already posted "Seen".' "$agent" "$tenant" "$frm" "$task" "$mid")"
    if ! bash "$send" --from "$agent" --to "$fwd" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
      do_log "WARN $agent replied but could not file msg $mid to $fwd (it is answered in-topic)"
    fi
    n=$((n + 1))
  done <<<"$rows"

  do_log "OK $agent ($tenant): handled $n escalation(s), $fails failed"
  (( fails == 0 ))
}
