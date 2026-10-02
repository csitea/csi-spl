#!/bin/bash
#------------------------------------------------------------------------------
# @description Live proof of SPL-997 (specs/038 FR-030..FR-035) on a cloud env's
# @description DEPLOYED hub: a human post in a channel that no online agent is a
# @description member of reaches the tenant's fallback responder, with ONE
# @description "unanswered post" poke - and a post in a channel whose member
# @description agent IS online does not (the control).
# @description   1. a throwaway probe box (its own key, SPOOL_ROOT and hub-run
# @description      sidecar; its notifier is a logger) announces two agents:
# @description      the RESPONDER and a MEMBER
# @description   2. the tenant's responder list is set to the RESPONDER
# @description      (do_spl_tenant_responders; this is why a test tenant only)
# @description   3. the signed-in test member creates fb-probe-<utc> with no
# @description      agent and posts one new topic over the browser socket
# @description   4. PASS half 1 = the RESPONDER's inbox holds that msg_id within
# @description      PROBE_WAIT_SECS and the logger holds one poke reading
# @description      "unanswered post in #fb-probe-<utc> (no member agent online)"
# @description   5. the member creates fb-ctrl-<utc>, seats the MEMBER (online on
# @description      the same box) and posts; PASS half 2 = the MEMBER gets it and
# @description      the RESPONDER gets neither the post nor a poke
# @description The sidecar is stopped at the end; the channels stay (a test
# @description tenant's probe channels) and so does the responder list. Prints
# @description one JSON verdict. Dev t1 is refused (its list is the
# @description orchestrator's): use the prd e2e tenant or another test tenant.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: a TEST tenant slug (prd e2e); t1 is refused
# @param PROBE_BOX (optional) - the probe box id, default box-fbp-<utc stamp>:
# @param   one per run, since each run mints a new key and the hub refuses to
# @param   re-pin a box id to another key (pin_conflict)
# @param PROBE_RESPONDER (optional) - default PRB-9973
# @param PROBE_MEMBER (optional) - the control's member agent, default PRB-9974
# @param ROOT_KEY (optional) - the tenant root private key file (0600), default
# @param   <state>/m3-e2e/<tenant>/root.key (the M3 e2e harness writes it)
# @param MEMBER_EMAIL (optional) - default m3-e2e-human@example.com
# @param MEMBER_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_WAIT_SECS (optional) - how long to wait for a delivery, default 30
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=e2e DRY_RUN=0 ./run -a do_spl_fallback_probe
#------------------------------------------------------------------------------
do_spl_fallback_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local stamp
  stamp="$(date -u +%Y%m%d%H%M%S)"
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-fbp-$stamp}" wait="${PROBE_WAIT_SECS:-30}"
  local resp="${PROBE_RESPONDER:-PRB-9973}" member="${PROBE_MEMBER:-PRB-9974}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$tenant" != t1 ]] || { do_log "FATAL TENANT_ID=t1 is a real tenant: its responder list is not the probe's to change (use e2e)"; return 1; }
  [[ "$wait" =~ ^[0-9]+$ ]] && (( wait >= 1 && wait <= 600 )) || { do_log "FATAL PROBE_WAIT_SECS must be 1..600, got: '$wait'"; return 1; }
  [[ "$box" =~ ^box-[a-z0-9][a-z0-9-]{0,26}$ && "$box" != box-wui && "$box" != box-desk ]] ||
    { do_log "FATAL PROBE_BOX must be a throwaway box-* id (not box-wui / box-desk), got: '$box'"; return 1; }
  local a
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for a in "$resp" "$member"; do
    spl_is_agent_id "$a" || { do_log "FATAL '$a' is not an agent id"; return 1; }
  done
  [[ "$resp" != "$member" ]] || { do_log "FATAL PROBE_RESPONDER and PROBE_MEMBER must differ"; return 1; }
  local api
  spl_cnf_api_fqdn api || return 1
  if (( dry )); then
    do_log "INFO DRY_RUN would: pin $box under $tenant at https://$api announcing $resp and $member, with a logger notifier"
    do_log "INFO DRY_RUN would: set $tenant's responders to $resp, post into #fb-probe-$stamp (no agent), then #fb-ctrl-$stamp ($member seated)"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
    return 0
  fi
  local key="${ROOT_KEY:-$SPL_STATE_DIR/m3-e2e/$tenant/root.key}"
  local pw="${MEMBER_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -s "$key" && "$(stat -c %a "$key")" == 600 ]] || { do_log "FATAL ROOT_KEY $key must be a non-empty 0600 file"; return 1; }
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set MEMBER_PW_FILE)"; return 1; }
  do_require_bin curl setsid || return 1
  spl_host_spool || return 1

  local d="$SPL_STATE_DIR/fallback-probe/$tenant/$stamp" hub="https://$api"
  mkdir -p "$d/spool/$resp/inbox" "$d/spool/$member/inbox" "$d/spool/.hub" "$d/keys" || return 1
  chmod -R go-rwx "$d" || return 1
  cat >"$d/notify.sh" <<NOTIFY
#!/bin/sh
printf '%s | %s\n' "\$*" "\$(cat)" >>"$d/pokes.log"
NOTIFY
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
  spl_fallback_probe_run "$d" "$box" "$tenant" "$api" "$stamp" "$resp" "$member" "$wait" "$pw"
  rc=$?
  kill "$pid" 2>/dev/null
  return $rc
}

# spl_fallback_probe_post <api> <tenant> <pw file> <channel> <body>: one human
# post over the browser socket; prints the script's JSON line.
spl_fallback_probe_post() {
  PROBE_API="https://$1" PROBE_TENANT="$2" PROBE_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$3" PROBE_CHANNEL="$4" PROBE_BODY="$5" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/fallback-probe-post.py"
}

# spl_fallback_probe_run <dir> <box> <tenant> <api> <stamp> <responder>
# <member> <wait secs> <pw file>: steps 2..5 against a live probe sidecar.
spl_fallback_probe_run() {
  local d="$1" box="$2" tenant="$3" api="$4" stamp="$5" resp="$6" member="$7" wait="$8" pw="$9"
  local seat="$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/channel-agent-add.py" out i
  local ch="fb-probe-$stamp" ctl="fb-ctrl-$stamp"
  spl_desk_wait_roster "$d" "$box" "$resp" 30 || { do_log "FATAL the hub never announced $resp on $box"; return 1; }
  TENANT_ID="$tenant" AGENTS="$resp" DRY_RUN=0 do_spl_tenant_responders || { do_log "FATAL setting $tenant's responders to $resp"; return 1; }
  out="$(SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ch" SEAT_AGENTS="" SEAT_BOX="$box" SEAT_CREATE=1 python3 "$seat")" ||
    { do_log "FATAL creating #$ch: $out"; return 1; }

  # Half 1: no member agent -> the responder gets it, with one fallback poke.
  local post id t0 t1 got=0 lat=""
  post="$(spl_fallback_probe_post "$api" "$tenant" "$pw" "$ch" "SPL-997 fallback probe: is anyone there? ($ch)")" ||
    { do_log "FATAL the human post into #$ch: $post"; return 1; }
  id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["msg_id"])' "$post")"
  t0="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sent_at"])' "$post")"
  for ((i = 0; i < wait * 10; i++)); do
    if grep -qs -- "$id" "$d/spool/$resp/inbox/"*.json; then
      got=1; t1="$(date +%s.%N)"; lat="$(python3 -c "print(round($t1 - $t0, 2))")"; break
    fi
    sleep 0.1
  done
  local pline want1="unanswered post in #$ch (no member agent online): SPL-997 fallback probe"
  for ((i = 0; i < 50; i++)); do
    pline="$(grep -- "--to $resp " "$d/pokes.log" 2>/dev/null | grep -- "$id" | head -1)"
    [[ -n "$pline" ]] && break
    sleep 0.1
  done

  # Half 2, the control: an online member agent -> no fallback.
  out="$(SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ctl" SEAT_AGENTS="$member" SEAT_BOX="$box" SEAT_CREATE=1 python3 "$seat")" ||
    { do_log "FATAL creating #$ctl and seating $member: $out"; return 1; }
  local cpost cid cgot=0 cleak=0
  cpost="$(spl_fallback_probe_post "$api" "$tenant" "$pw" "$ctl" "SPL-997 fallback probe control: $member is here ($ctl)")" ||
    { do_log "FATAL the control post into #$ctl: $cpost"; return 1; }
  cid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["msg_id"])' "$cpost")"
  for ((i = 0; i < wait * 10; i++)); do
    grep -qs -- "$cid" "$d/spool/$member/inbox/"*.json && { cgot=1; break; }
    sleep 0.1
  done
  sleep 5
  grep -qs -- "$cid" "$d/spool/$resp/inbox/"*.json && cleak=1
  grep -s -- "$cid" "$d/pokes.log" | grep -q -- "--to $resp " && cleak=1

  local ok=1
  (( got == 1 )) || ok=0
  [[ "$pline" == *"$want1"* ]] || ok=0
  (( cgot == 1 && cleak == 0 )) || ok=0
  python3 -c 'import json,sys; a=sys.argv; print(json.dumps({"verdict": "PASS" if a[1]=="1" else "FAIL",
    "tenant": a[2], "box": a[3], "responder": a[4], "member": a[5],
    "post": {"channel": a[6], "msg_id": a[7], "reached_responder": a[8]=="1", "seconds": float(a[9]) if a[9] else None,
             "poke_line": a[10].split(" | ",1)[-1]},
    "control": {"channel": a[11], "msg_id": a[12], "reached_member": a[13]=="1", "fallback_sent": a[14]=="1"},
    "state_dir": a[15]}, sort_keys=True))' \
    "$ok" "$tenant" "$box" "$resp" "$member" "$ch" "$id" "$got" "$lat" "$pline" "$ctl" "$cid" "$cgot" "$cleak" "$d"
  (( ok )) || { do_log "FAIL the fallback proof did not match (see the JSON line)"; return 1; }
  do_log "OK #$ch reached the fallback $resp in ${lat}s with one poke; the control #$ctl reached $member and no fallback"
}
