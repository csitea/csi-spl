#!/bin/bash
#------------------------------------------------------------------------------
# @description Live replay of SPL-1004 on a cloud env's DEPLOYED hub: a
# @description person's untagged reply to ALL-0, in a channel topic whose
# @description OPENING was addressed to another person, reaches the channel's
# @description online member agent - the csi-rel rows of 2026-09-27 (opening
# @description 11:37:10 to HUM-27, reply 11:52:45 to ALL-0, is_parent 0).
# @description   1. a throwaway probe box (its own key, SPOOL_ROOT and hub-run
# @description      sidecar; its notifier is a logger) announces PROBE_MEMBER
# @description   2. the signed-in test member creates rp-probe-<utc> and seats
# @description      PROBE_MEMBER in it
# @description   3. the member opens a topic there TO PROBE_OPEN_TO (a person),
# @description      then replies in it to ALL-0 with no channel tag, over the
# @description      browser socket exactly as the WUI reply pane sends it
# @description   4. PASS = PROBE_MEMBER's inbox holds BOTH msg_ids within
# @description      PROBE_WAIT_SECS; the JSON line carries each latency
# @description The sidecar is stopped at the end; the channel stays (a test
# @description tenant's probe channel). Dev t1 / prd t1 are refused.
# @description What it cannot show: the cross-revision relay itself - that
# @description needs a browser and a box on different Cloud Run revisions, which
# @description only a deploy makes; internal/hub/relay_test.go replays that.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: a TEST tenant slug (prd e2e); t1 is refused
# @param PROBE_BOX (optional) - default box-rpp-<utc stamp> (one per run: pin_conflict)
# @param PROBE_MEMBER (optional) - the channel's member agent, default PRB-9975
# @param PROBE_OPEN_TO (optional) - the opening's addressee, default HUM-27
# @param ROOT_KEY (optional) - the tenant root private key file (0600), default
# @param   <state>/m3-e2e/<tenant>/root.key
# @param MEMBER_EMAIL (optional) - default m3-e2e-human@example.com
# @param MEMBER_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_WAIT_SECS (optional) - how long to wait for each delivery, default 30
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=e2e MEMBER_EMAIL="$(cat <state>/m3-e2e/e2e/human-email)" DRY_RUN=0 ./run -a do_spl_reply_probe
#------------------------------------------------------------------------------
do_spl_reply_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local stamp
  stamp="$(date -u +%Y%m%d%H%M%S)"
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-rpp-$stamp}" wait="${PROBE_WAIT_SECS:-30}"
  local member="${PROBE_MEMBER:-PRB-9975}" to="${PROBE_OPEN_TO:-HUM-27}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$tenant" != t1 ]] || { do_log "FATAL TENANT_ID=t1 is a real tenant: run the probe in a test tenant (e2e)"; return 1; }
  [[ "$wait" =~ ^[0-9]+$ ]] && (( wait >= 1 && wait <= 600 )) || { do_log "FATAL PROBE_WAIT_SECS must be 1..600, got: '$wait'"; return 1; }
  [[ "$box" =~ ^box-[a-z0-9][a-z0-9-]{0,26}$ && "$box" != box-wui && "$box" != box-desk ]] ||
    { do_log "FATAL PROBE_BOX must be a throwaway box-* id (not box-wui / box-desk), got: '$box'"; return 1; }
  [[ "$member" =~ ^[A-Z]{2,4}-[0-9]+$ && "${member%%-*}" != HUM ]] || { do_log "FATAL PROBE_MEMBER '$member' is not an agent id"; return 1; }
  [[ "$to" =~ ^HUM-[0-9A-Za-z._@-]+$ ]] || { do_log "FATAL PROBE_OPEN_TO must be a person id (HUM-*), got: '$to'"; return 1; }
  local api
  spl_cnf_api_fqdn api || return 1
  local ch="rp-probe-$stamp"
  if (( dry )); then
    do_log "INFO DRY_RUN would: pin $box under $tenant at https://$api announcing $member, create #$ch with $member seated"
    do_log "INFO DRY_RUN would: open a topic in #$ch to $to, reply in it to ALL-0 (untagged), and wait for $member to get both"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
    return 0
  fi
  local key="${ROOT_KEY:-$SPL_STATE_DIR/m3-e2e/$tenant/root.key}"
  local pw="${MEMBER_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -s "$key" && "$(stat -c %a "$key")" == 600 ]] || { do_log "FATAL ROOT_KEY $key must be a non-empty 0600 file"; return 1; }
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set MEMBER_PW_FILE)"; return 1; }
  do_require_bin curl setsid || return 1
  spl_host_spool || return 1

  local d="$SPL_STATE_DIR/reply-probe/$tenant/$stamp" hub="https://$api"
  mkdir -p "$d/spool/$member/inbox" "$d/spool/.hub" "$d/keys" || return 1
  chmod -R go-rwx "$d" || return 1
  printf '#!/bin/sh\ncat >/dev/null\n' >"$d/notify.sh"
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
  spl_reply_probe_run "$d" "$box" "$tenant" "$api" "$ch" "$member" "$to" "$wait" "$pw"
  rc=$?
  kill "$pid" 2>/dev/null
  return $rc
}

# spl_reply_probe_wait <inbox dir> <msg id> <t0> <wait secs>: prints the
# seconds from t0 until the msg is in the inbox, or nothing on a timeout.
spl_reply_probe_wait() {
  local i t1
  for ((i = 0; i < $4 * 10; i++)); do
    if grep -qs -- "$2" "$1"/*.json; then
      t1="$(date +%s.%N)"; python3 -c "print(round($t1 - $3, 2))"; return 0
    fi
    sleep 0.1
  done
  return 1
}

# spl_reply_probe_run <dir> <box> <tenant> <api> <channel> <member> <to>
# <wait secs> <pw file>: steps 2..4 against a live probe sidecar.
spl_reply_probe_run() {
  local d="$1" box="$2" tenant="$3" api="$4" ch="$5" member="$6" to="$7" wait="$8" pw="$9"
  local seat="$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/channel-agent-add.py" out
  spl_desk_wait_roster "$d" "$box" "$member" 30 || { do_log "FATAL the hub never announced $member on $box"; return 1; }
  out="$(SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ch" SEAT_AGENTS="$member" SEAT_BOX="$box" SEAT_CREATE=1 python3 "$seat")" ||
    { do_log "FATAL creating #$ch and seating $member: $out"; return 1; }
  local open task oid ot0 olat="" reply rid rt0 rlat=""
  open="$(PROBE_TO="$to" spl_fallback_probe_post "$api" "$tenant" "$pw" "$ch" "SPL-1004 reply probe: an opening addressed to $to ($ch)")" ||
    { do_log "FATAL the opening into #$ch: $open"; return 1; }
  oid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["msg_id"])' "$open")"
  task="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["task_id"])' "$open")"
  ot0="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sent_at"])' "$open")"
  olat="$(spl_reply_probe_wait "$d/spool/$member/inbox" "$oid" "$ot0" "$wait")"
  reply="$(PROBE_TASK="$task" PROBE_PARENT=0 spl_fallback_probe_post "$api" "$tenant" "$pw" "$ch" "SPL-1004 reply probe: the reply to ALL-0 ($ch)")" ||
    { do_log "FATAL the reply in $task: $reply"; return 1; }
  rid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["msg_id"])' "$reply")"
  rt0="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sent_at"])' "$reply")"
  rlat="$(spl_reply_probe_wait "$d/spool/$member/inbox" "$rid" "$rt0" "$wait")"
  local ok=0
  [[ -n "$olat" && -n "$rlat" ]] && ok=1
  python3 -c 'import json,sys; a=sys.argv; f=lambda v: float(v) if v else None; print(json.dumps({"verdict": "PASS" if a[1]=="1" else "FAIL",
    "tenant": a[2], "box": a[3], "member": a[4], "channel": a[5], "task_id": a[6],
    "opening": {"msg_id": a[7], "to": a[8], "reached_member_s": f(a[9])},
    "reply": {"msg_id": a[10], "to": "ALL-0", "is_parent": 0, "reached_member_s": f(a[11])},
    "state_dir": a[12]}, sort_keys=True))' \
    "$ok" "$tenant" "$box" "$member" "$ch" "$task" "$oid" "$to" "$olat" "$rid" "$rlat" "$d"
  (( ok )) || { do_log "FAIL $member did not get both the opening and the reply (see the JSON line)"; return 1; }
  do_log "OK #$ch: $member got the opening to $to in ${olat}s and the untagged ALL-0 reply in ${rlat}s"
}
