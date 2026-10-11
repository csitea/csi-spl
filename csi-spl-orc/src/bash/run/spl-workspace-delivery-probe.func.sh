#!/bin/bash
#------------------------------------------------------------------------------
# @description Per-workspace END-TO-END delivery probe (gap M4 of the sienna
# @description miss, RCA m/9f554415): in EVERY non-test workspace with a live
# @description desk on this machine, a probe human DMs the dispatcher in a
# @description hidden probe topic (one fixed topic per env, workspace and box;
# @description a DM is seen by the probe member and the dispatcher only), then
# @description checks the dispatcher's desk seat on THIS machine within
# @description PROBE_WAIT seconds:
# @description   ok        - the message is in the seat's spool (inbox or
# @description               archive), its notices log holds it and the seat
# @description               is not muted: the dispatcher was TOLD
# @description   muted     - it arrived, and the seat has .no-poke or its
# @description               sidecar runs SPOOL_POKE=0 (the sienna case: a
# @description               desk that receives and never tells)
# @description   unnoticed - it arrived, and no notice was written
# @description   missed    - it never arrived in time
# @description   noseat    - the workspace's desk has no seat of the dispatcher
# @description   unprobed  - no probe login for the workspace (below)
# @description   post-failed - the probe login or the send was refused
# @description The workspace set is the live desk dirs (<state>/desk/<ws>),
# @description never a list; a test workspace (spl_test_workspace, the sweep's
# @description rule) is left out. The probe login of a workspace is
# @description <state>/m3-e2e/<ws>/{human-email,pw-human} (PROBE_LOGIN_DIR);
# @description the alert workspace (t1) also takes the PROBE_EMAIL /
# @description PROBE_PW_FILE pair the desk cron already uses, then the e2e
# @description member's files.
# @description Any verdict other than ok raises ONE ask to the orchestrator
# @description (a spool blocker, journaled as an ask by spool-send.sh) AND one
# @description blocker post in the alert workspace's #alerts (the owner's t1),
# @description posted by its probe login. An alert repeats only when a
# @description workspace's verdict changes or after PROBE_REALERT seconds
# @description (memory: <spool root>/dispatch/delivery-probe.state). Each
# @description posted probe topic is acked for the unanswered sweep
# @description (do_spl_unanswered_ack), so the probe never reads as a missed
# @description human post. Dry run unless DRY_RUN=0: the plan per workspace,
# @description nothing posted, sent or written. The cron line is
# @description do_spl_workspace_delivery_probe_install_cron.
# @param ENV - required: dev or prd
# @param PROBE_TO (optional) - the dispatcher DMed and checked, default LEASE_MASTER (lease.conf), else c-002
# @param PROBE_ASK_TO (optional) - who gets the ask, default LEASE_ORCH, else c-001
# @param PROBE_FROM (optional) - the ask's sender, default PROBE_TO
# @param PROBE_WAIT (optional) - seconds a probe may take, default 180
# @param PROBE_POLL (optional) - seconds between seat reads, default 10
# @param PROBE_REALERT (optional) - seconds before an unchanged alert repeats, default 3600
# @param PROBE_ALERT_TENANT (optional) - default LEASE_TENANT, else t1
# @param PROBE_ALERT_CHANNEL (optional) - default alerts
# @param PROBE_BOX (optional) - this machine's tag in the topic and the alert, default the short host name
# @param PROBE_DESK_DIR / PROBE_LOGIN_DIR (optional) - default <state>/desk and <state>/m3-e2e
# @param PROBE_POST_CMD / PROBE_SEND (optional) - the poster and the spool sender (the tests' seams)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_spl_workspace_delivery_probe
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_workspace_delivery_probe
#------------------------------------------------------------------------------
do_spl_workspace_delivery_probe() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local v
  for v in PROBE_WAIT PROBE_POLL PROBE_REALERT; do
    [[ -z "${!v:-}" || "${!v}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $v must be a positive integer, got: '${!v}'"; return 1; }
  done
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  do_spl_cloud_cnf || return 1
  spl_lease_init ro || return 1
  spl_lease_conf
  WDP_TO="${PROBE_TO:-${LEASE_MASTER:-c-002}}"
  WDP_ASK_TO="${PROBE_ASK_TO:-${LEASE_ORCH:-c-001}}"
  WDP_FROM="${PROBE_FROM:-$WDP_TO}"
  WDP_ALERT_T="${PROBE_ALERT_TENANT:-${LEASE_TENANT:-t1}}"
  WDP_DESK="${PROBE_DESK_DIR:-$SPL_STATE_DIR/desk}"
  WDP_LOGIN="${PROBE_LOGIN_DIR:-$SPL_STATE_DIR/m3-e2e}"
  WDP_BOX="${PROBE_BOX:-$(hostname -s)}"
  for v in "$WDP_TO" "$WDP_ASK_TO" "$WDP_FROM"; do
    [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL '$v' is not an agent id"; return 1; }
  done
  [[ "$WDP_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL PROBE_BOX is not a box tag: '$WDP_BOX'"; return 1; }
  local ws=()
  mapfile -t ws < <(spl_wdp_workspaces "$WDP_DESK")
  (( ${#ws[@]} )) || { do_log "FAIL no non-test workspace has a desk under $WDP_DESK: nothing to probe"; return 1; }
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_wdp_plan "${ws[@]}"
    do_log "OK DRY_RUN nothing was posted, sent or written. Re-run with DRY_RUN=0."
    return 0
  fi
  mkdir -p "$LEASE_DIR" || { do_log "FATAL cannot create $LEASE_DIR"; return 1; }
  local tmp rc=0
  tmp="$(mktemp -d)" || return 1
  # one probe at a time: a 10-minute cron and a 3-minute wait never overlap,
  # but a hand run might
  ( flock -n 9 || { do_log "INFO another delivery probe holds $LEASE_DIR/delivery-probe.lock - skipped"; exit 0; }
    spl_wdp_run "$tmp" "${ws[@]}" ) 9> "$LEASE_DIR/delivery-probe.lock" || rc=1
  rm -rf "$tmp"
  return $rc
}

# spl_wdp_workspaces <desk root>: the workspaces with a desk dir, test ones out.
spl_wdp_workspaces() {
  local d w
  for d in "$1"/*/; do
    [[ -d "$d" ]] || continue
    w="$(basename "$d")"
    [[ "$w" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
    spl_test_workspace "$w" && continue
    echo "$w"
  done
}

# spl_wdp_plan <ws>...: one PLAN line per workspace, read-only.
spl_wdp_plan() {
  local w seats
  for w in "$@"; do
    seats="$(spl_wdp_seat_dirs "$w" | wc -l)"
    if spl_wdp_login "$w" >/dev/null; then
      echo "PLAN $w: DM $WDP_TO in topic $(spl_wdp_topic "$w"), check $seats seat dir(s) for ${PROBE_WAIT:-180}s"
    else
      echo "PLAN $w: unprobed - no probe login under $WDP_LOGIN/$w"
    fi
  done
}

# spl_wdp_seat_dirs <ws>: the dispatcher's seat dirs in that workspace's desks.
spl_wdp_seat_dirs() {
  local s
  for s in "$WDP_DESK/$1"/*/spool/"$WDP_TO"; do [[ -d "$s" ]] && echo "$s"; done
}

# spl_wdp_topic <ws>: the hidden probe topic, fixed per env, workspace and box.
spl_wdp_topic() {
  python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool-delivery-probe/" + "/".join(sys.argv[1:])))' \
    "$ENV" "$1" "$WDP_BOX"
}

# spl_wdp_login <ws>: "<email>\t<pw file>" of the workspace's probe member.
spl_wdp_login() {
  local w="$1" dir e
  if [[ "$w" == "$WDP_ALERT_T" && -n "${PROBE_EMAIL:-}" && -r "${PROBE_PW_FILE:-}" ]]; then
    printf '%s\t%s\n' "$PROBE_EMAIL" "$PROBE_PW_FILE"; return 0
  fi
  for dir in "$WDP_LOGIN/$w" $([[ "$w" == "$WDP_ALERT_T" ]] && echo "$WDP_LOGIN/e2e"); do
    [[ -r "$dir/human-email" && -r "$dir/pw-human" ]] || continue
    e="$(tr -d '[:space:]' <"$dir/human-email")"
    [[ -n "$e" ]] && { printf '%s\t%s\n' "$e" "$dir/pw-human"; return 0; }
  done
  return 1
}

# spl_wdp_post <ws> <to|#channel> <task> <body>: one human send; prints the
# poster's JSON line.
spl_wdp_post() {
  local w="$1" dest="$2" login api to="" ch="" cmd
  login="$(spl_wdp_login "$w")" || return 2
  if [[ "$dest" == "#"* ]]; then ch="${dest#\#}"; else to="$dest"; fi
  if [[ -z "${PROBE_API:-}" ]]; then spl_cnf_api_fqdn api || return 1; fi
  cmd="${PROBE_POST_CMD:-python3 $PROJ_PATH/src/bash/scripts/workspace-delivery-probe-post.py}"
  PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$w" PROBE_EMAIL="${login%%$'\t'*}" \
    PROBE_PW_FILE="${login#*$'\t'}" PROBE_TO="$to" PROBE_CHANNEL="$ch" PROBE_TASK="$3" PROBE_BODY="$4" \
    $cmd
}

# spl_wdp_seat_state <seat dir> <msg id>: told | muted | unnoticed | none.
spl_wdp_seat_state() {
  local s="$1" m="$2" f got=0 pid poke
  for f in "$s"/inbox/*"-${m:0:8}.json" "$s"/archive/*"-${m:0:8}.json"; do
    [[ -f "$f" ]] && grep -qF "$m" "$f" && { got=1; break; }
  done
  (( got )) || { echo none; return 0; }
  grep -qF "msg $m" "$s/.pokes/notices.log" 2>/dev/null || { echo unnoticed; return 0; }
  [[ -e "$s/.no-poke" ]] && { echo muted; return 0; }
  pid="$(cat "$s/../.hub/hub-run.pid" 2>/dev/null)"
  if declare -F spl_desk_sidecar_poke >/dev/null; then poke="$(spl_desk_sidecar_poke "$pid")"; fi
  [[ "${poke:-}" == 0 ]] && { echo muted; return 0; }
  echo told
}

# spl_wdp_verdict <ws> <msg id>: the best state over the workspace's seats,
# as a verdict (ok | muted | unnoticed | missed | noseat).
spl_wdp_verdict() {
  local s st best=none n=0
  while IFS= read -r s; do
    n=$((n + 1))
    st="$(spl_wdp_seat_state "$s" "$2")"
    case "$st:$best" in
      told:*) best=told ;; muted:none|muted:unnoticed) best=muted ;; unnoticed:none) best=unnoticed ;;
    esac
  done < <(spl_wdp_seat_dirs "$1")
  (( n )) || { echo noseat; return 0; }
  case "$best" in told) echo ok ;; none) echo missed ;; *) echo "$best" ;; esac
}

# spl_wdp_run <tmp> <ws>...: post every probe, wait, judge, report, alert, ack.
spl_wdp_run() {
  local tmp="$1" w out rc task now deadline left
  shift
  : >"$tmp/rows"
  for w in "$@"; do
    task="$(spl_wdp_topic "$w")"
    if ! spl_wdp_login "$w" >/dev/null; then printf '%s\t-\t%s\tunprobed\n' "$w" "$task" >>"$tmp/rows"; continue; fi
    [[ -n "$(spl_wdp_seat_dirs "$w")" ]] || { printf '%s\t-\t%s\tnoseat\n' "$w" "$task" >>"$tmp/rows"; continue; }
    rc=0; out="$(spl_wdp_post "$w" "$WDP_TO" "$task" \
      "delivery probe $WDP_BOX $(date -u +%FT%TZ): no reply needed (do_spl_workspace_delivery_probe)")" || rc=$?
    local mid; mid="$(jq -r '.msg_id // empty' <<<"$out" 2>/dev/null)"
    if (( rc )) || [[ ! "$mid" =~ ^[0-9a-f-]{36}$ ]]; then
      printf '%s\t-\t%s\tpost-failed\n' "$w" "$task" >>"$tmp/rows"
      do_log "WARN the probe post in $w failed (rc $rc): $(head -c 300 <<<"$out")"
      continue
    fi
    printf '%s\t%s\t%s\tpending\n' "$w" "$mid" "$task" >>"$tmp/rows"
  done
  deadline=$(( $(date +%s) + ${PROBE_WAIT:-180} ))
  while :; do
    spl_wdp_judge "$tmp/rows" 0
    grep -q $'\tpending$' "$tmp/rows" || break
    now="$(date +%s)"; left=$(( deadline - now ))
    (( left > 0 )) || break
    sleep "$(( left < ${PROBE_POLL:-10} ? left : ${PROBE_POLL:-10} ))"
  done
  spl_wdp_judge "$tmp/rows" 1
  spl_wdp_report "$tmp/rows"
  spl_wdp_ack "$tmp/rows"
  spl_wdp_alert "$tmp/rows" "$tmp" || return 1
  ! grep -qv $'\tok$' "$tmp/rows"
}

# spl_wdp_judge <rows> <final>: re-read every pending row; a pending row that
# is not ok yet stays pending until <final> is 1.
spl_wdp_judge() {
  local w m t st v
  : >"$1.new"
  while IFS=$'\t' read -r w m t st; do
    if [[ "$st" == pending ]]; then
      v="$(spl_wdp_verdict "$w" "$m")"
      [[ "$v" == ok || "$2" == 1 ]] && st="$v"
    fi
    printf '%s\t%s\t%s\t%s\n' "$w" "$m" "$t" "$st" >>"$1.new"
  done <"$1"
  mv -f "$1.new" "$1"
}

# spl_wdp_report <rows>: the markdown table.
spl_wdp_report() {
  echo "## Delivery probe $ENV on $WDP_BOX: DM to $WDP_TO, ${PROBE_WAIT:-180}s"
  echo
  echo "| workspace | verdict | msg | topic |"
  echo "|---|---|---|---|"
  awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $4, substr($2, 1, 8), substr($3, 1, 8) }' "$1"
}

# spl_wdp_ack <rows>: every posted probe topic is handled for the sweep.
spl_wdp_ack() {
  declare -F do_spl_unanswered_ack >/dev/null || return 0
  local w m t st
  while IFS=$'\t' read -r w m t st; do
    [[ "$m" == - ]] && continue
    TOPIC="$t" REASON="delivery probe ($w, $st)" ACK_BY="$WDP_FROM" do_spl_unanswered_ack >/dev/null 2>&1 ||
      do_log "WARN could not ack the probe topic $t of $w for the sweep"
  done <"$1"
  return 0
}

# spl_wdp_alert <rows> <tmp>: the rows not ok whose verdict changed or whose
# last alert is older than PROBE_REALERT go to the orchestrator (blocker = an
# ask) and to the alert workspace's #alerts. The memory moves only when the
# ask landed.
spl_wdp_alert() {
  local rows="$1" tmp="$2" state="$LEASE_DIR/delivery-probe.state" now
  now="$(date +%s)"
  awk -F'\t' -v now="$now" -v re="${PROBE_REALERT:-3600}" -v stf="$state" -v out="$tmp/alert" -v nst="$tmp/state.new" '
    BEGIN { while ((getline l < stf) > 0) { split(l, a, "\t"); pv[a[1]] = a[2]; pa[a[1]] = a[3] } }
    { w = $1; v = $4; at = (w in pa) ? pa[w] : 0
      if (v != "ok" && (pv[w] != v || now - at >= re)) { print w "\t" v > out; at = now }
      if (v == "ok") at = 0
      print w "\t" v "\t" at > nst }' "$rows"
  if [[ ! -s "$tmp/alert" ]]; then mv -f "$tmp/state.new" "$state"; return 0; fi
  {
    echo "**Delivery probe RED on $ENV ($WDP_BOX):** a probe human's DM did not TELL dispatcher $WDP_TO within ${PROBE_WAIT:-180}s."
    echo
    echo "| workspace | verdict |"
    echo "|---|---|"
    awk -F'\t' '{ printf "| %s | %s |\n", $1, $2 }' "$tmp/alert"
    echo
    echo "Verdicts: \`do_spl_workspace_delivery_probe\` header. Seat health: \`TENANT_ID=<ws> DESK_AGENT=$WDP_TO ./run -a do_spl_desk_check\`."
  } >"$tmp/alert.md"
  cat "$tmp/alert.md"
  local ok=1
  spl_wdp_send "$WDP_ASK_TO" "$tmp/alert.md" || ok=0
  spl_wdp_post "$WDP_ALERT_T" "#${PROBE_ALERT_CHANNEL:-alerts}" "" "$(cat "$tmp/alert.md")" >/dev/null ||
    do_log "WARN the #${PROBE_ALERT_CHANNEL:-alerts} blocker post in $WDP_ALERT_T failed (no probe login there?)"
  (( ok )) || { do_log "FATAL the ask to $WDP_ASK_TO was not delivered; the alert repeats on the next probe"; return 1; }
  mv -f "$tmp/state.new" "$state"
}

# spl_wdp_send <to> <body file>: one spool blocker on task delivery-probe.
spl_wdp_send() {
  local send="${PROBE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$WDP_FROM" --to "$1" \
    --kind blocker --task delivery-probe --body-file "$2" >/dev/null 2>&1 8>&- 9>&- ||
    { do_log "WARN could not send the delivery-probe ask to $1"; return 1; }
  echo "SENT $1: $(head -1 "$2")"
}
