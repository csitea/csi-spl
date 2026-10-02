#!/bin/bash
#------------------------------------------------------------------------------
# @description Live seed for SPL-1008 on a cloud env's DEPLOYED hub: a channel
# @description whose OLDEST topic holds replies of every shape the middle
# @description card's "N >>" must count, pushed out of the WUI's first page
# @description window (30 lines) by newer topics - the prd t1
# @description #spool-hub-mobile shape of 2026-09-27 (6576fead: 6 replies
# @description stored, "2 >>" shown).
# @description   1. a throwaway probe box (its own key, SPOOL_ROOT and hub-run
# @description      sidecar) announces PROBE_MEMBER
# @description   2. the signed-in test member creates rc-probe-<utc>, seats
# @description      PROBE_MEMBER, and opens the OLD topic
# @description   3. PROBE_MEMBER replies in it: a note to the member's id, a
# @description      blocker, a result; the member replies once
# @description   4. the member opens PROBE_NEWER newer topics of 4 lines each
# @description   5. PROBE_MEMBER replies once more in the OLD topic: the reply
# @description      that arrives while no tab is open
# @description Prints one JSON line {channel, old_task_id, old_open_msg_id,
# @description replies, box}; the page proof reads it (reply-counts-live.proof.mjs).
# @description The sidecar is stopped at the end; the channel stays (a test
# @description tenant's probe channel). Dev t1 / prd t1 are refused.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: a TEST tenant slug (prd e2e); t1 is refused
# @param PROBE_BOX (optional) - default box-rcp-<utc stamp> (one per run: pin_conflict)
# @param PROBE_MEMBER (optional) - the channel's member agent, default PRB-9976
# @param PROBE_HUMAN (optional) - the HUM-* id the agent replies are addressed to, default HUM-1
# @param PROBE_NEWER (optional) - how many newer topics, 1..20, default 8
# @param ROOT_KEY (optional) - the tenant root private key file (0600), default
# @param   <state>/m3-e2e/<tenant>/root.key
# @param MEMBER_EMAIL (optional) - default m3-e2e-human@example.com
# @param MEMBER_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=e2e MEMBER_EMAIL="$(cat <state>/m3-e2e/e2e/human-email)" DRY_RUN=0 ./run -a do_spl_reply_count_probe
#------------------------------------------------------------------------------
do_spl_reply_count_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local stamp
  stamp="$(date -u +%Y%m%d%H%M%S)"
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-rcp-$stamp}" newer="${PROBE_NEWER:-8}"
  local member="${PROBE_MEMBER:-PRB-9976}" human="${PROBE_HUMAN:-HUM-1}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$tenant" != t1 ]] || { do_log "FATAL TENANT_ID=t1 is a real tenant: run the probe in a test tenant (e2e)"; return 1; }
  [[ "$newer" =~ ^[0-9]+$ ]] && (( newer >= 1 && newer <= 20 )) || { do_log "FATAL PROBE_NEWER must be 1..20, got: '$newer'"; return 1; }
  [[ "$box" =~ ^box-[a-z0-9][a-z0-9-]{0,26}$ && "$box" != box-wui && "$box" != box-desk ]] ||
    { do_log "FATAL PROBE_BOX must be a throwaway box-* id (not box-wui / box-desk), got: '$box'"; return 1; }
  [[ "$member" =~ ^[A-Z]{2,4}-[0-9]+$ && "${member%%-*}" != HUM ]] || { do_log "FATAL PROBE_MEMBER '$member' is not an agent id"; return 1; }
  [[ "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL PROBE_HUMAN must be a person id (HUM-<n>), got: '$human'"; return 1; }
  local api
  api="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  local ch="rc-probe-$stamp"
  if (( dry )); then
    do_log "INFO DRY_RUN would: pin $box under $tenant at https://$api announcing $member, create #$ch with $member seated"
    do_log "INFO DRY_RUN would: open the OLD topic, $member replies to $human (note, blocker, result), the member replies once"
    do_log "INFO DRY_RUN would: open $newer newer topics of 4 lines each, then $member replies once more in the OLD topic"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
    return 0
  fi
  local key="${ROOT_KEY:-$SPL_STATE_DIR/m3-e2e/$tenant/root.key}"
  local pw="${MEMBER_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -s "$key" && "$(stat -c %a "$key")" == 600 ]] || { do_log "FATAL ROOT_KEY $key must be a non-empty 0600 file"; return 1; }
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set MEMBER_PW_FILE)"; return 1; }
  do_require_bin curl setsid || return 1
  spl_host_spool || return 1

  local d="$SPL_STATE_DIR/reply-count-probe/$tenant/$stamp" hub="https://$api"
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
  spl_reply_count_probe_run "$d" "$box" "$tenant" "$api" "$ch" "$member" "$human" "$newer" "$pw"
  rc=$?
  kill "$pid" 2>/dev/null
  return $rc
}

# spl_reply_count_probe_agent <dir> <box> <tenant> <api> <member> <to> <task>
# <kind> <body>: one agent reply in <task> from the probe box.
spl_reply_count_probe_agent() {
  local out rc=0
  out="$(spl_desk_spool "$1" "$2" "$3" "https://$4" -- send --from "$5" --to "$6" --to-box box-wui --task "$7" --kind "$8" --body "$9" 2>&1)" || rc=$?
  (( rc == 0 )) || { do_log "FATAL send $5 -> $6 ($8) in $7: $out"; return 1; }
}

# spl_reply_count_probe_post <api> <tenant> <pw file> <channel> <plan json>:
# the member's posts, one sign-in (reply-count-probe-post.py).
spl_reply_count_probe_post() {
  PROBE_API="https://$1" PROBE_TENANT="$2" PROBE_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$3" PROBE_CHANNEL="$4" PROBE_PLAN="$5" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/reply-count-probe-post.py"
}

# spl_reply_count_probe_run <dir> <box> <tenant> <api> <channel> <member>
# <human> <newer> <pw file>: steps 2..5 against a live probe sidecar.
spl_reply_count_probe_run() {
  local d="$1" box="$2" tenant="$3" api="$4" ch="$5" member="$6" human="$7" newer="$8" pw="$9"
  local seat="$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/channel-agent-add.py" out i j
  spl_desk_wait_roster "$d" "$box" "$member" 30 || { do_log "FATAL the hub never announced $member on $box"; return 1; }
  out="$(SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ch" SEAT_AGENTS="$member" SEAT_BOX="$box" SEAT_CREATE=1 python3 "$seat")" ||
    { do_log "FATAL creating #$ch and seating $member: $out"; return 1; }
  local open task oid n=0 plan
  # The member signs in once per batch (native login: 10 per email per 15 min).
  open="$(spl_reply_count_probe_post "$api" "$tenant" "$pw" "$ch" \
    '[{"task":"new","body":"SPL-1008 reply-count probe: the OLD topic"},{"task":"$0","body":"SPL-1008: the member'"'"'s own reply"}]')" ||
    { do_log "FATAL the OLD topic in #$ch: $open"; return 1; }
  oid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["msg_id"])' "$open")"
  task="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["task_id"])' "$open")"
  n=1
  spl_reply_count_probe_agent "$d" "$box" "$tenant" "$api" "$member" "$human" "$task" note "SPL-1008: agent reply to $human" || return 1; n=$((n + 1))
  spl_reply_count_probe_agent "$d" "$box" "$tenant" "$api" "$member" "$human" "$task" blocker "SPL-1008: a blocker reply" || return 1; n=$((n + 1))
  spl_reply_count_probe_agent "$d" "$box" "$tenant" "$api" "$member" "$human" "$task" result "SPL-1008: a result reply" || return 1; n=$((n + 1))
  plan="$(python3 -c 'import json,sys; k=int(sys.argv[1]); print(json.dumps([s for i in range(k) for s in
    [{"task": "new", "body": "SPL-1008: newer topic %d" % (i + 1)}] + [{"task": "$%d" % (4 * i), "body": "SPL-1008: newer topic %d line %d" % (i + 1, j)} for j in (1, 2, 3)]]))' "$newer")"
  out="$(spl_reply_count_probe_post "$api" "$tenant" "$pw" "$ch" "$plan")" || { do_log "FATAL the newer topics: $out"; return 1; }
  spl_reply_count_probe_agent "$d" "$box" "$tenant" "$api" "$member" "$human" "$task" note "SPL-1008: the reply that came while no tab was open" || return 1
  n=$((n + 1))
  python3 -c 'import json,sys; a=sys.argv; print(json.dumps({"channel": a[1], "old_task_id": a[2], "old_open_msg_id": a[3],
    "replies": int(a[4]), "newer_topics": int(a[5]), "tenant": a[6], "box": a[7], "member": a[8]}, sort_keys=True))' \
    "$ch" "$task" "$oid" "$n" "$newer" "$tenant" "$box" "$member"
  do_log "OK #$ch: the OLD topic $task holds $n replies behind $newer newer topics of 4 lines"
}
