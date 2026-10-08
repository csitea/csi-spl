#!/bin/bash
#------------------------------------------------------------------------------
# @description Live proof that a message made a topic of its own is read in
# @description the topic it lives in NOW (bug topic 226a8209, prd t1 645f9e3e:
# @description the dispatcher's copy and hub-tail kept the old topic, so the
# @description answer went there). On a deployed env it:
# @description   1. signs the test member in and posts a topic card c0 and a
# @description      reply m1 into PROBE_CHANNEL (topic A), over the browser
# @description      socket (scripts/move-notice-probe.py)
# @description   2. promotes m1 to a topic of its own, N
# @description   3. hub-tail --task N as the desk box DESK_BOX, which holds
# @description      both posts as a member of the channel: m1 must read
# @description      task_id N (waits up to PROBE_WAIT_SECS for the delivery)
# @description   4. CONTROL: hub-tail --task A reads c0 on A, and no m1
# @description   5. reports (never fails on) the move notice in the desk's
# @description      inboxes: it reaches only an agent whose box was online
# @description It WRITES two posts and a topic into PROBE_CHANNEL, so point it
# @description at a proof channel of a TEST workspace (dev t1 #live-proof),
# @description never at a human's conversation. Reads no database. The
# @description password is read from a file and never printed. Dry run unless
# @description DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (dev: t1)
# @param PROBE_CHANNEL (optional) - default live-proof: a channel the member may post in and DESK_BOX's agents are members of
# @param DESK_BOX (optional) - the desk box that reads hub-tail, default spl_desk_box_default
# @param PROBE_EMAIL (optional) - default the M3 e2e file <state>/m3-e2e/<tenant>/human-email, else m3-e2e-human@example.com
# @param PROBE_PW_FILE (optional) - default the M3 e2e file <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_WAIT_SECS (optional) - how long hub-tail waits for the posts to reach DESK_BOX, default 30
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_move_notice_probe
#------------------------------------------------------------------------------
do_spl_move_notice_probe() {
  do_require_bin yq python3 || return 1
  local tenant="${TENANT_ID:-}" channel="${PROBE_CHANNEL:-live-proof}" box="${DESK_BOX:-$(spl_desk_box_default)}"
  local wait="${PROBE_WAIT_SECS:-30}" dry=1
  _spl_move_probe_check "$tenant" "$channel" "$box" "$wait" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: post a card and a reply into #$channel of $tenant as the test member, make the reply a topic, then hub-tail both topics as $box"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to prove it."
    return 0
  fi
  do_spl_desk_cnf || return 1
  local d="$SPL_STATE_DIR/desk/$tenant/$box" pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -d "$d/spool" ]] || { do_log "FATAL no desk $box in $tenant on $ENV ($d): DESK_BOX names the desk that reads hub-tail"; return 1; }
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set PROBE_PW_FILE)"; return 1; }
  local api email email_file="$SPL_STATE_DIR/m3-e2e/$tenant/human-email" out rc=0 ids=()
  spl_cnf_api_fqdn api || return 1
  email="${PROBE_EMAIL:-}"
  [[ -n "$email" ]] || { [[ -r "$email_file" ]] && email="$(tr -d '[:space:]' <"$email_file")"; }
  out="$(PROBE_API="https://$api" PROBE_AUTH="https://${SPL_FQDN:-$api}" PROBE_TENANT="$tenant" \
    PROBE_EMAIL="${email:-m3-e2e-human@example.com}" PROBE_PW_FILE="$pw" PROBE_CHANNEL="$channel" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/move-notice-probe.py")" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL move-notice probe: post and promote on $ENV/$tenant failed (exit $rc)"; return 1; }
  read -r -a ids < <(tail -n 1 <<<"$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); print(o["c0"], o["m1"], o["task_a"], o["task_n"])' 2>/dev/null)
  (( ${#ids[@]} == 4 )) || { do_log "FATAL move-notice probe printed no ids"; return 1; }
  spl_host_spool || return 1
  _spl_move_probe_tails "$d" "$box" "$tenant" "$wait" "${ids[@]}"
}

# _spl_move_probe_check <tenant> <channel> <box> <wait>: 0 when the inputs are
# sane, else the FATAL naming the bad one. Runs before any cloud or spool call.
_spl_move_probe_check() {
  spl_require_tenant_slug "$1" || return 1
  [[ "$2" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ && ! "$2" =~ ^(lobby|general|issues|tasks)$ ]] ||
    { do_log "FATAL PROBE_CHANNEL must be a proof channel id (not lobby, general, issues or tasks), got: '$2'"; return 1; }
  [[ "$3" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$3" != box-wui ]] || { do_log "FATAL DESK_BOX '$3' is not a desk box id (box-wui is reserved)"; return 1; }
  [[ "$4" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL PROBE_WAIT_SECS must be a positive integer, got: '$4'"; return 1; }
}

# _spl_move_probe_tails <desk dir> <box> <tenant> <wait> <c0> <m1> <A> <N>:
# steps 3-5. 0 when hub-tail reads m1 on N and the control holds.
_spl_move_probe_tails() {
  local d="$1" box="$2" tenant="$3" wait="$4" c0="$5" m1="$6" a="$7" n="$8" got t0=$SECONDS
  while :; do
    got="$(spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- hub-tail --task "$n" --json 2>&1)"
    _spl_move_probe_has "$got" "$m1" "$n" && break
    (( SECONDS - t0 < wait )) || { do_log "FATAL hub-tail --task $n as $box does not read m1 $m1 on topic $n after ${wait}s: $(head -c 600 <<<"$got")"; return 1; }
    sleep 2
  done
  do_log "PASS hub-tail --task $n reads m1 $m1 with task_id $n (the topic it lives in now)"
  got="$(spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- hub-tail --task "$a" --json 2>&1)"
  if _spl_move_probe_has "$got" "$c0" "$a" && ! grep -q "\"msg_id\":\"$m1\"" <<<"$got"; then
    do_log "PASS CONTROL hub-tail --task $a reads the unmoved card c0 $c0 on $a, and m1 no longer"
  else
    do_log "FATAL CONTROL hub-tail --task $a: $(head -c 600 <<<"$got")"; return 1
  fi
  if _spl_move_probe_notice "$d/spool" "$m1" "$n"; then
    do_log "PASS the move notice for m1 reached an inbox on $box, on topic $n"
  else
    do_log "INFO no move notice on $box yet: it reaches only an agent whose box was online at the promote"
  fi
  do_log "OK move-notice probe on $ENV/$tenant: m1 $m1 promoted from $a to $n reads $n on hub-tail"
}

# _spl_move_probe_has <hub-tail --json output> <msg_id> <task_id>: 0 when one
# line is that message on that topic.
_spl_move_probe_has() {
  python3 -c '
import json, sys
for line in sys.argv[1].splitlines():
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and m.get("msg_id") == sys.argv[2] and m.get("task_id") == sys.argv[3]:
        sys.exit(0)
sys.exit(1)' "$1" "$2" "$3"
}

# _spl_move_probe_notice <spool root> <m1> <N>: 0 when an inbox holds the move
# notice: a message on topic N, not m1 itself, whose body names m1.
_spl_move_probe_notice() {
  python3 -c '
import glob, json, os, sys
for p in glob.glob(os.path.join(sys.argv[1], "*", "inbox", "*.json")):
    try:
        with open(p) as f:
            m = json.load(f)
    except (OSError, ValueError):
        continue
    if isinstance(m, dict) and m.get("task_id") == sys.argv[3] and m.get("msg_id") != sys.argv[2] \
            and sys.argv[2] in str(m.get("body", "")):
        sys.exit(0)
sys.exit(1)' "$1" "$2" "$3"
}
