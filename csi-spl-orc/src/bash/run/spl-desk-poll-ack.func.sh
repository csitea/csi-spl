#!/bin/bash
#------------------------------------------------------------------------------
# @description The owner's poll answer gets an immediate acknowledgement (spec
# @description 157 Rule 5, row B3, SPL-4093; owner HUM-10, t1 99ffa592 msg
# @description a99676b7: "What could be automated to be done without any
# @description intelligence?"). A pick in a WUI poll posts a fixed two-line
# @description body (csi-spl-wui/src/utils/poll.mjs answerBody):
# @description   Poll: <poll msg uuid>
# @description   Answer[ <n>]: <keys>[ — <option text>]
# @description This action, on the machine that holds the dispatch lease, reads
# @description the holder's desk spools (every workspace, its inbox and
# @description archive), and for each such answer from a person (HUM-<n>) newer
# @description than POLL_ACK_MAX_AGE minutes:
# @description   1. skips it when $SPOOL_ROOT/dispatch/automation.log already
# @description      has a poll-ack line for its msg_id (a vote seen once is
# @description      acknowledged once), or another answer in the same topic
# @description      was acknowledged in this run
# @description   2. reads the topic from the hub (hub-tail --json) and skips it
# @description      when the topic cannot be read (a closed or unknown topic),
# @description      when the topic holds no poll message with that id from an
# @description      agent (not an active poll), or when an agent posted in the
# @description      topic after the answer (already answered)
# @description      hub-tail serves only what the holder's desk box holds
# @description      (measured 2026-10-28, csitea topic 26a21b5a: the box held
# @description      the owner's answers, not the poll another box posted). So
# @description      a poll posted from another box's desk fails the poll check
# @description      (no ack: closed, never a wrong post), and a reply another
# @description      box posted is not seen by the already-answered check.
# @description   3. posts `**In progress**: noted (answer <keys>, <HH:MM:SSZ>).`
# @description      into the topic through do_spl_desk_reply as the holder
# @description      (how-to-post.md rule 15: noted, never "acting on A"; the
# @description      time keeps two acks to one person distinct for the hub's
# @description      24 h duplicate guard)
# @description   4. wakes the holder with a spool note on task
# @description      dispatch-<topic8>, so the model acts on the answer
# @description   5. appends one line to $SPOOL_ROOT/dispatch/automation.log
# @description      (spec 157 5.1.3): time, msg id, action, actor, topic, poll,
# @description      keys and the reply / wake exit codes
# @description A non-person vote, a body that is not the poll answer format and
# @description an answer older than the window are ignored (no post, rc 0).
# @description Nothing happens (rc 0) when no live holder is on this machine:
# @description the lease (LEASE_CMD=show do_spl_dispatch_lease, read only) is
# @description none, stale (older than LEASE_STALE s) or held on another box.
# @description A reply the hub or a desk gate refuses (exit 6..9) is logged as
# @description refused and not tried again; any other failure is retried on
# @description the next run. Lease files (spl-dispatch-lease*) are never
# @description written. Dry run unless DRY_RUN=0: it prints the PLAN lines.
# @description The cron line: do_spl_desk_poll_ack_install_cron.
# @param ENV (optional) - dev or prd; default lease.conf LEASE_ENV, else prd
# @param POLL_ACK_MAX_AGE (optional) - minutes; older answers are ignored, default 30
# @param POLL_ACK_FROM (optional) - the wake note's sender, default lease.conf LEASE_ORCH, else role seat 1
# @param POLL_ACK_SEND (optional) - the sender script, default spawn-agents/scripts/spool-send.sh (tests)
# @param DESK_BOX (optional) - the desk box, default lease.conf LEASE_DESK_BOX, else this machine's desk box
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_desk_poll_ack
# @example DRY_RUN=0 ./run -a do_spl_desk_poll_ack
# @example POLL_ACK_MAX_AGE=120 ./run -a do_spl_desk_poll_ack
#------------------------------------------------------------------------------
do_spl_desk_poll_ack() {
  do_require_bin python3 || return 1
  local max="${POLL_ACK_MAX_AGE:-30}" dry="${DRY_RUN:-1}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL POLL_ACK_MAX_AGE must be minutes (a positive integer), got: '$max'"; return 1; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_lease_init ro || return 1
  spl_lease_conf
  ENV="${ENV:-${LEASE_ENV:-prd}}"
  [[ "$ENV" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd, got: '$ENV'"; return 1; }
  local agent box
  agent="$(_spl_poll_ack_holder)" || return 0
  box="${DESK_BOX:-${LEASE_DESK_BOX:-$(spl_desk_box_default)}}"
  do_spl_desk_cnf || return 1
  local log="$LEASE_DIR/automation.log"
  if [[ "$dry" == 0 ]]; then
    if ! { mkdir -p "$LEASE_DIR" && touch "$log"; }; then do_log "FATAL cannot write $log"; return 1; fi
    exec 7>"$LEASE_DIR/poll-ack.lock"
    flock -n 7 || { do_log "INFO another poll ack run holds $LEASE_DIR/poll-ack.lock - skipped"; return 0; }
  fi
  local spool tenant rows tenant_n=0 seen=" " n=0 msg task from ts poll keys
  for spool in "$SPL_STATE_DIR"/desk/*/"$box"/spool/"$agent"; do
    [[ -d "$spool" ]] || continue
    tenant="${spool#"$SPL_STATE_DIR"/desk/}"; tenant="${tenant%%/*}"
    spl_test_workspace "$tenant" && continue
    tenant_n=$((tenant_n + 1))
    rows="$(_spl_poll_ack_scan "$spool" "$max")" || { do_log "WARN could not read $spool"; continue; }
    while IFS=$'\t' read -r msg task from ts poll keys; do
      [[ -n "$msg" ]] || continue
      if grep -q " poll-ack $msg " "$log" 2>/dev/null; then continue; fi
      [[ "$seen" == *" $tenant/$task "* ]] && { do_log "INFO msg $msg: topic $task already acknowledged in this run"; continue; }
      _spl_poll_ack_one "$tenant" "$box" "$agent" "$msg" "$task" "$from" "$ts" "$poll" "$keys" "$log" "$dry" &&
        { seen+="$tenant/$task "; n=$((n + 1)); }
    done <<<"$rows"
  done
  do_log "OK poll ack: holder $agent on $box, $tenant_n workspace(s) read, $n answer(s) acknowledged$([[ "$dry" == 1 ]] && echo ' (DRY_RUN: planned, nothing sent)')"
}

# _spl_poll_ack_holder: the bare id of the dispatch lease holder when it is
# live and on this machine; 1 (with an INFO on stderr: stdout is the id)
# otherwise. Reads the lease only through `LEASE_CMD=show
# do_spl_dispatch_lease` ("<holder> <age-seconds>").
_spl_poll_ack_holder() {
  local show age
  show="$(LEASE_CMD=show do_spl_dispatch_lease 2>/dev/null)" || { do_log "INFO the dispatch lease cannot be read: nothing to do" >&2; return 1; }
  read -r LH age <<<"$show"
  if [[ -z "$LH" || "$LH" == none || ! "$age" =~ ^[0-9]+$ ]] || (( age > LEASE_STALE )); then
    do_log "INFO no live dispatch lease holder (${show:-empty}): nothing to do" >&2; return 1
  fi
  if spl_lease_remote; then
    do_log "INFO the dispatch lease is held by $LH, on another machine: its machine acknowledges" >&2; return 1
  fi
  spl_lease_holder_id
}

# _spl_poll_ack_scan <spool dir> <max age minutes>: one TSV row per poll answer
# from a person in <spool>/{inbox,archive} newer than the window, oldest first:
# msg_id task_id from ts poll_id keys. The file name opens with its delivery
# time, so older files are never opened. POLL_ACK_NOW pins the clock (tests).
_spl_poll_ack_scan() {
  python3 - "$1" "$2" "${POLL_ACK_NOW:-}" <<'EOF_PY'
import datetime as dt, json, os, re, sys
spool, mins, now = sys.argv[1], int(sys.argv[2]), sys.argv[3]
now = dt.datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ") if now else dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
cut = now - dt.timedelta(minutes=mins)
UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
POLL = re.compile(r"^Poll:\s*(" + UUID + r")\s*$")
ANSWER = re.compile(r"^Answer(?:\s+[0-9]+)?:\s+([A-Za-z0-9,]+)")
rows = []
for sub in ("inbox", "archive"):
    d = os.path.join(spool, sub)
    try:
        names = os.listdir(d)
    except OSError:
        continue
    for n in names:
        if not n.endswith(".json") or n[:16] < cut.strftime("%Y%m%dT%H%M%SZ"):
            continue
        try:
            with open(os.path.join(d, n)) as f:
                m = json.load(f)
            ts = dt.datetime.strptime(str(m.get("ts", ""))[:19], "%Y-%m-%dT%H:%M:%S")
        except (OSError, ValueError, TypeError, AttributeError):
            continue
        lines = str(m.get("body", "")).split("\n")
        p = POLL.match(lines[0])
        keys = [a.group(1) for a in map(ANSWER.match, lines[1:]) if a]
        frm, task, mid = str(m.get("from", "")), str(m.get("task_id", "")), str(m.get("msg_id", ""))
        if not (p and keys and re.fullmatch(r"HUM-[0-9]+", frm) and ts >= cut):
            continue
        if re.fullmatch(UUID, task) and re.fullmatch(UUID, mid):
            rows.append((str(m["ts"]), mid, task, frm, p.group(1), "/".join(keys)))
for r in sorted(set(rows)):
    print("\t".join((r[1], r[2], r[3], r[0], r[4], r[5])))
EOF_PY
}

# _spl_poll_ack_topic <poll id> <answer ts>, the topic's hub-tail NDJSON on
# stdin: "ok" when an agent posted that poll in the topic and no agent posted
# after the answer; "nopoll" or "answered" otherwise. A person is HUM-, RSP-
# or GST-; every other sender is an agent.
_spl_poll_ack_topic() {
  python3 -c '
import json, sys
poll, ts = sys.argv[1], sys.argv[2]
people = ("HUM-", "RSP-", "GST-")
found = answered = False
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if not isinstance(m, dict) or str(m.get("from", "")).startswith(people):
        continue
    if m.get("msg_id") == poll and "```poll" in str(m.get("body", "")):
        found = True
    if str(m.get("ts", "")) > ts:
        answered = True
print("answered" if answered else "ok" if found else "nopoll")' "$1" "$2"
}

# _spl_poll_ack_one <tenant> <box> <agent> <msg> <task> <from> <ts> <poll>
# <keys> <log> <dry>: the topic checks, the reply, the wake, the log line.
# 0 when the answer was acknowledged (or, dry, would be); 1 otherwise.
_spl_poll_ack_one() {
  local tenant="$1" box="$2" agent="$3" msg="$4" task="$5" from="$6" ts="$7" poll="$8" keys="$9" log="${10}" dry="${11}"
  local d="$SPL_STATE_DIR/desk/$tenant/$box" tail verdict body rc=0 wrc=0 outcome=sent
  # the desk's spool binary, found (or built) once, at the first answer
  [[ -n "${SPL_SPOOL:-}" ]] || spl_host_spool || return 1
  if ! tail="$(spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- hub-tail --task "$task" --json 2>/dev/null)" || [[ -z "$tail" ]]; then
    do_log "INFO msg $msg: topic $task cannot be read from $box (closed or unknown): not acknowledged"; return 1
  fi
  verdict="$(_spl_poll_ack_topic "$poll" "$ts" <<<"$tail")"
  case "$verdict" in
    ok) ;;
    answered) do_log "INFO msg $msg: an agent already posted in topic $task after the answer"; return 1 ;;
    *) do_log "INFO msg $msg: topic $task holds no poll $poll from an agent: not acknowledged"; return 1 ;;
  esac
  body="**In progress**: noted (answer ${keys//\//, }, {{NOW_UTC}})."
  if [[ "$dry" == 1 ]]; then
    echo "PLAN $tenant topic $task: $agent answers $from's vote $msg (poll $poll, answer $keys) with '$body', then wakes $agent"
    return 0
  fi
  ( ENV="$ENV" TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="$agent" DESK_TASK="$task" DESK_TO="$from" \
    DESK_KIND=note DESK_BODY="$body" DESK_BODY_FILE='' DESK_ACK=0 DRY_RUN=0 do_spl_desk_reply ) || rc=$?
  if (( rc >= 6 && rc <= 9 )); then outcome=refused
  elif (( rc != 0 )); then do_log "WARN msg $msg: the reply in topic $task failed (rc $rc); the next run tries again"; return 1; fi
  [[ "$outcome" == sent ]] && { _spl_poll_ack_wake "$agent" "$tenant" "$task" "$from" "$msg" "$poll" "$keys" || wrc=$?; }
  printf '%s poll-ack %s action=%s actor=%s@%s tenant=%s topic=%s poll=%s from=%s keys=%s reply_rc=%s wake_rc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" "$outcome" "$agent" "$box" "$tenant" "$task" "$poll" "$from" "$keys" "$rc" "$wrc" >>"$log"
  [[ "$outcome" == sent ]] || { do_log "WARN msg $msg: the desk refused the acknowledgement (rc $rc); logged, not tried again"; return 1; }
  do_log "OK msg $msg: $agent acknowledged $from's poll answer $keys in topic $task"
}

# _spl_poll_ack_wake <agent> <tenant> <task> <from> <msg> <poll> <keys>: a
# spool note to the holder on task dispatch-<topic8> (never the owner topic's
# own id: that would show in the owner's topic).
_spl_poll_ack_wake() {
  local send="${POLL_ACK_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  local who="${POLL_ACK_FROM:-${LEASE_ORCH:-$(spl_role_seat 1)}}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$who" --to "$1" --kind note --task "dispatch-${3:0:8}" \
    --body "$4 answered poll $6 with $7 (msg $5, $2 topic $3). The desk posted **In progress**: noted. Act on the answer now." \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || { do_log "WARN could not wake $1 about msg $5"; return 1; }
}
