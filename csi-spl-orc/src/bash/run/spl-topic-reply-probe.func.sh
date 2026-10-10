#!/bin/bash
#------------------------------------------------------------------------------
# @description Live proof on a cloud env's DEPLOYED hub that a person's reply
# @description to the whole topic (to ALL-0, no @mention) in a topic with NO
# @description channel reaches the topic's agent (prd t1 916c8696, 2026-10-06:
# @description the owner's reply got only a box-wui delivery row).
# @description   1. a throwaway probe box (its own key, SPOOL_ROOT and hub-run
# @description      sidecar; its notifier is a logger) announces PROBE_AGENT
# @description   2. PROBE_AGENT opens a channel-less topic: a note to ALL-0 on
# @description      box-wui, as a desk's note to a person is stored
# @description   3. the signed-in test member replies in that topic over the
# @description      browser socket: is_parent 0, no channel, no `to`
# @description   4. PASS = the reply's msg_id is in PROBE_AGENT's inbox within
# @description      PROBE_WAIT_SECS
# @description The sidecar is stopped at the end; the topic stays. Prints one
# @description JSON verdict. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant whose m3-e2e member and root key are in <state>/m3-e2e/<tenant>
# @param PROBE_BOX (optional) - the probe box id, default box-trp-<utc stamp> (one per run: a box id cannot be re-pinned to a new key)
# @param PROBE_AGENT (optional) - the probe agent, default q-998
# @param PROBE_WAIT_SECS (optional) - 1..600, default 30
# @param ROOT_KEY / MEMBER_PW_FILE / MEMBER_EMAIL (optional) - default the m3-e2e state of the tenant
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_topic_reply_probe
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_topic_reply_probe
#------------------------------------------------------------------------------
do_spl_topic_reply_probe() {
  local stamp
  stamp="$(date -u +%Y%m%d%H%M%S)"
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-trp-$stamp}" wait="${PROBE_WAIT_SECS:-30}" agent="${PROBE_AGENT:-q-998}"
  local dry
  spl_probe_preamble dry "$tenant" || return 1
  [[ "$wait" =~ ^[0-9]+$ ]] && (( wait >= 1 && wait <= 600 )) || { do_log "FATAL PROBE_WAIT_SECS must be 1..600, got: '$wait'"; return 1; }
  spl_probe_box_ok "$box" || return 1
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_agent_id "$agent" || { do_log "FATAL PROBE_AGENT '$agent' is not an agent id"; return 1; }
  local api
  spl_cnf_api_fqdn api || return 1
  if (( dry )); then
    spl_probe_dry_report \
      "pin $box under $tenant at https://$api announcing $agent, open a channel-less topic as $agent, reply to it as the test member (to ALL-0)"
    return 0
  fi
  local key pw
  spl_probe_secrets "$tenant" key pw setsid || return 1

  local d="$SPL_STATE_DIR/topic-reply-probe/$tenant/$stamp" hub="https://$api"
  mkdir -p "$d/spool/$agent/inbox" "$d/spool/.hub" "$d/keys" || return 1
  chmod -R go-rwx "$d" || return 1
  printf '#!/bin/sh\nprintf "%%s | %%s\\n" "$*" "$(cat)" >>"%s/pokes.log"\n' "$d" >"$d/notify.sh"
  chmod 0700 "$d/notify.sh"
  local pub out rc=0
  pub="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- keygen 2>&1)" || { do_log "FATAL keygen for $box: $pub"; return 1; }
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-pin --box "$box" --pubkey "$pub" --root-key "$key" 2>&1)" || rc=$?
  (( rc == 0 )) || { do_log "FATAL hub-pin $box under $tenant: $out"; return 1; }
  SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" SPOOL_HUB_URL="$hub" \
    SPOOL_TENANT="$tenant" SPOOL_NOTIFY_CMD="$d/notify.sh" \
    spl_desk_detach "$d/spool/.hub/hub-run.log" "$SPL_SPOOL" hub-run
  local pid=$!
  printf '%s\n' "$pid" >"$d/spool/.hub/hub-run.pid"
  spl_topic_reply_probe_run "$d" "$box" "$tenant" "$api" "$agent" "$wait" "$pw"
  rc=$?
  kill "$pid" 2>/dev/null
  return $rc
}

# spl_topic_reply_probe_run <dir> <box> <tenant> <api> <agent> <wait secs>
# <pw file>: steps 2..4 against a live probe sidecar.
spl_topic_reply_probe_run() {
  local d="$1" box="$2" tenant="$3" api="$4" agent="$5" wait="$6" pw="$7" out task post id t0 t1 got=0 lat="" i
  spl_desk_wait_roster "$d" "$box" "$agent" 30 || { do_log "FATAL the hub never announced $agent on $box"; return 1; }
  out="$(spl_desk_spool "$d" "$box" "$tenant" "https://$api" -- send --from "$agent" --to ALL-0 --to-box box-wui \
    --kind note --body "topic reply probe: a note outside any channel, reply to it" 2>&1)" ||
    { do_log "FATAL $agent's opening note: $out"; return 1; }
  task="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["task_id"])' "$out")" ||
    { do_log "FATAL no task_id in: $out"; return 1; }
  post="$(PROBE_API="https://$api" PROBE_TENANT="$tenant" PROBE_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$pw" PROBE_CHANNEL=- PROBE_TASK="$task" PROBE_PARENT=0 \
    PROBE_BODY="topic reply probe: the person's reply to the whole topic" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/fallback-probe-post.py")" ||
    { do_log "FATAL the member's reply in $task: $post"; return 1; }
  id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["msg_id"])' "$post")"
  t0="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sent_at"])' "$post")"
  for ((i = 0; i < wait * 10; i++)); do
    if grep -qs -- "$id" "$d/spool/$agent/inbox/"*.json; then
      got=1; t1="$(date +%s.%N)"; lat="$(python3 -c "print(round($t1 - $t0, 2))")"; break
    fi
    sleep 0.1
  done
  python3 -c 'import json,sys; a=sys.argv; print(json.dumps({"verdict": "PASS" if a[1]=="1" else "FAIL",
    "tenant": a[2], "box": a[3], "agent": a[4], "task_id": a[5], "reply_msg_id": a[6],
    "seconds": float(a[7]) if a[7] else None, "state_dir": a[8]}, sort_keys=True))' \
    "$got" "$tenant" "$box" "$agent" "$task" "$id" "$lat" "$d"
  (( got )) || { do_log "FAIL the channel-less reply $id never reached $agent's inbox"; return 1; }
  do_log "OK the channel-less reply $id reached $agent in ${lat}s"
}
