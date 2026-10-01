#!/bin/bash
#------------------------------------------------------------------------------
# @description The unanswered-post sweep (SPEC-spool-fleet-roles.md 3.2): the
# @description PULL half of dispatching. The dispatchers see only NEW
# @description deliveries, so a post that arrived before they existed, while a
# @description seat was down, whose poke was lost, or that an agent read and
# @description never answered is never looked at again (owner, 2026-10-01:
# @description "the pulling mechanism should work for all the tenants, not only
# @description the spool t1 tenant"). This reads EVERY workspace of the env's
# @description hub in one read-only query and lists the topics whose LAST
# @description message is a human's, older than SWEEP_MIN_AGE minutes.
# @description A topic is one task_id; its last message decides. Left out:
# @description   answered - the last message is an agent's
# @description   terminal - a line a human typed in an agent's terminal and
# @description              the agent mirrored (typed_by set, specs/036): the
# @description              agent read it where it was typed
# @description   handled  - a dispatcher acked it (do_spl_unanswered_ack)
# @description              after its last human post
# @description   human    - a post by SWEEP_SKIP_HUMANS (the probe human)
# @description   test     - a test workspace (SWEEP_SKIP_TENANTS, SWEEP_SKIP_RE)
# @description   closed   - the topic card is archived, or its channel is
# @description              archived or deleted
# @description   to-human - a post addressed to a human (DM or channel
# @description              post with to=HUM-n/GST-n): no agent is asked
# @description   channel  - a channel in SWEEP_SKIP_CHANNELS (#issues, #tasks)
# @description   fresh    - younger than SWEEP_MIN_AGE (the live path has it)
# @description   ack      - a pure acknowledgement ("ok", "thanks", emoji
# @description              only): LISTED in its own table, never delivered
# @description DELIVER=1 sends ONE spool note (task unanswered-sweep) to the
# @description lease holder (do_spl_dispatch_lease show) with the items NEW
# @description since the last sweep, plus each item still open SWEEP_RESEND s
# @description after it was sent (once); an item still open SWEEP_RESEND s
# @description after that re-send is escalated to the orchestrator, once.
# @description The memory is <spool root>/dispatch/unanswered.state (an item is
# @description a topic's last message: a new human post in it is a new item),
# @description and <spool root>/dispatch/unanswered.last holds the last
# @description delivered sweep's time and counts (do_spl_dispatch_check reads
# @description it). Without DELIVER=1 nothing is written or sent: the report
# @description and the PLAN lines only. The cron line is
# @description do_spl_unanswered_sweep_install_cron.
# @description Read-only on the hub: one statement set in a READ ONLY
# @description transaction, operator RLS scope, as the env SA.
# @param ENV - required: dev or prd
# @param DELIVER (optional) - 1 sends and records; default 0 (report only)
# @param SWEEP_MIN_AGE (optional) - minutes a human post waits before it counts, default 15
# @param SWEEP_DAYS (optional) - lookback in days, default 7
# @param SWEEP_RESEND (optional) - seconds before a re-send and again before the escalation, default 7200
# @param SWEEP_SKIP_TENANTS (optional) - space-separated test workspaces, default e2e; <spool root>/dispatch/test-workspaces adds to it (one id per line)
# @param SWEEP_SKIP_RE (optional) - a workspace id or name matching this ERE is a test one, default (^|[-_ ])(e2e|test|proof)([-_ ]|$)
# @param SWEEP_SKIP_CHANNELS (optional) - default "issues tasks"
# @param SWEEP_SKIP_HUMANS (optional) - posters left out; default HUM-1 on prd (the e2e probe owner), none on dev
# @param SWEEP_MAX_ITEMS (optional) - rows per delivered note, default 40
# @param SWEEP_ROWS_FILE (optional) - read the rows from this file instead of the hub (tests, an export)
# @param SWEEP_TO / SWEEP_ORCH / SWEEP_FROM (optional) - recipient, escalation target, sender; default the lease holder, LEASE_ORCH (lease.conf) or CLE-001, the orchestrator
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ENV=prd ./run -a do_spl_unanswered_sweep
# @example ENV=prd DELIVER=1 ./run -a do_spl_unanswered_sweep
# @example ENV=prd SWEEP_MIN_AGE=60 SWEEP_SKIP_TENANTS='e2e leiden' ./run -a do_spl_unanswered_sweep
#------------------------------------------------------------------------------
do_spl_unanswered_sweep() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local deliver="${DELIVER:-0}" v
  [[ "$deliver" == 0 || "$deliver" == 1 ]] || { do_log "FATAL DELIVER must be 0 or 1"; return 1; }
  for v in SWEEP_MIN_AGE SWEEP_DAYS SWEEP_RESEND SWEEP_MAX_ITEMS; do
    [[ -z "${!v:-}" || "${!v}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $v must be a positive integer, got: '${!v}'"; return 1; }
  done
  spl_lease_init ro || return 1
  spl_lease_conf
  SWEEP_ORCH="${SWEEP_ORCH:-${LEASE_ORCH:-CLE-001}}"
  SWEEP_FROM="${SWEEP_FROM:-$SWEEP_ORCH}"
  # fleet mode (CLE-77911): another machine holds the dispatch lease, so its
  # own sweep sends; sending from here too would deliver every item twice
  if (( ${DELIVER:-0} )) && [[ -z "${SWEEP_TO:-}" ]] && spl_lease_read && spl_lease_remote; then
    do_log "INFO the fleet's dispatch lease is held by $LH: this machine's sweep sends nothing"
    return 0
  fi
  local tmp rc=0
  tmp="$(mktemp -d)" || return 1
  if (( deliver )); then
    mkdir -p "$LEASE_DIR" || { do_log "FATAL cannot create $LEASE_DIR"; rm -rf "$tmp"; return 1; }
    # one sweep at a time: two would both send the same NEW items
    ( flock -n 9 || { do_log "INFO another unanswered sweep holds $LEASE_DIR/unanswered.lock - skipped"; exit 0; }
      spl_sweep_run "$tmp" 1 ) 9> "$LEASE_DIR/unanswered.lock" || rc=1
  else
    spl_sweep_run "$tmp" 0 || rc=1
  fi
  rm -rf "$tmp"
  return $rc
}

# spl_sweep_run <tmp> <deliver>: read, classify, report, then send + record.
spl_sweep_run() {
  local tmp="$1" deliver="$2" to f ok=1
  spl_sweep_rows "$tmp/rows" || return 1
  to="$(spl_sweep_holder)"
  SWEEP_NOW="${SWEEP_NOW:-$(date +%s)}" SWEEP_TO_ID="$to" SWEEP_ORCH_ID="$SWEEP_ORCH" ENVN="$ENV" \
    spl_sweep_classify "$tmp/rows" "$LEASE_DIR/unanswered.state" "$tmp" || return 1
  cat "$tmp/report.md"
  if (( ! deliver )); then
    for f in holder orch; do
      [[ -s "$tmp/$f.md" ]] || continue
      echo "PLAN send to $([[ $f == holder ]] && echo "$to" || echo "$SWEEP_ORCH"): $(head -1 "$tmp/$f.md")"
    done
    do_log "OK report only - DELIVER=1 sends the NEW items and records them"
    return 0
  fi
  [[ -s "$tmp/holder.md" ]] && { spl_sweep_send "$to" "$tmp/holder.md" || ok=0; }
  [[ -s "$tmp/orch.md" ]] && { spl_sweep_send "$SWEEP_ORCH" "$tmp/orch.md" || ok=0; }
  # the memory moves only when every send landed: a failed one is re-tried
  # as NEW on the next sweep rather than forgotten
  if (( ok )); then
    mv -f "$tmp/state.new" "$LEASE_DIR/unanswered.state" || return 1
  fi
  { cat "$tmp/last"; echo "to=$to"; echo "sent=$([[ $ok == 1 ]] && echo ok || echo FAILED)"; } > "$LEASE_DIR/unanswered.last.tmp" &&
    mv -f "$LEASE_DIR/unanswered.last.tmp" "$LEASE_DIR/unanswered.last"
  (( ok )) || { do_log "FATAL a sweep note was not delivered; the items stay NEW for the next sweep"; return 1; }
  return 0
}

# The dispatcher to send to: SWEEP_TO, else the lease holder, else the master
# in lease.conf, else the orchestrator.
spl_sweep_holder() {
  [[ -n "${SWEEP_TO:-}" ]] && { echo "$SWEEP_TO"; return 0; }
  spl_lease_read
  if [[ "$LH" != none ]]; then echo "$LH"
  elif [[ -n "${LEASE_MASTER:-}" ]]; then echo "$LEASE_MASTER"
  else echo "$SWEEP_ORCH"; fi
}

# spl_sweep_send <to> <body file>: one spool note on task unanswered-sweep.
# SWEEP_SEND replaces the sender script in the tests.
spl_sweep_send() {
  local send="${SWEEP_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}" bin="${SPOOL_BIN:-}"
  if [[ -z "$bin" ]]; then
    local org_app; org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
    bin="$HOME/.local/share/$org_app/cloud/$ENV/bin/spool"
    [[ -x "$bin" ]] || bin=spool
  fi
  SPOOL_BIN="$bin" SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$SWEEP_FROM" --to "$1" \
    --kind note --task unanswered-sweep --body-file "$2" >/dev/null 2>&1 8>&- 9>&- ||
    { do_log "WARN could not send the sweep note to $1"; return 1; }
  echo "SENT $1: $(head -1 "$2")"
}

# One do_spl_dispatch_check row (its `row`, LEASE_DIR set): the last delivered
# sweep, its age and open count; never run, a failed send or older than
# DISPATCH_SWEEP_STALE s is a GAP.
spl_sweep_check_row() {
  local f="$LEASE_DIR/unanswered.last" k v ts="" open="" per="" sent="" to="" age stale="${DISPATCH_SWEEP_STALE:-1800}"
  if [[ ! -f "$f" ]]; then
    row "unanswered sweep" "never ran" "GAP DRY_RUN=0 do_spl_unanswered_sweep_install_cron"; return 0
  fi
  while IFS='=' read -r k v; do
    case "$k" in ts) ts="$v" ;; open) open="$v" ;; per) per="$v" ;; sent) sent="$v" ;; to) to="$v" ;; esac
  done < "$f"
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  age=$(( $(spl_lease_now) - ts ))
  v="last ${age}s ago to ${to:-?}, ${open:-?} open${per:+ (${per//,/, })}"
  if [[ "$sent" != ok ]]; then row "unanswered sweep" "$v" "GAP the last note was not delivered"
  elif (( age > stale )); then row "unanswered sweep" "$v" "GAP stale (over ${stale}s): is the cron installed?"
  else row "unanswered sweep" "$v" ok; fi
}

# spl_sweep_rows <out>: the last message of every topic in the window, one TSV
# line each (spl_sweep_classify names the columns), from SWEEP_ROWS_FILE or
# the hub.
spl_sweep_rows() {
  if [[ -n "${SWEEP_ROWS_FILE:-}" ]]; then
    cp "$SWEEP_ROWS_FILE" "$1" || { do_log "FATAL cannot read SWEEP_ROWS_FILE $SWEEP_ROWS_FILE"; return 1; }
    return 0
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_sweep_rows_read "$1" || { do_log "FATAL could not read the topics of $ENV"; return 1; }
}

# Read-only, inside spl_via_proxy. Tabs and newlines in a body collapse to one
# space so a row is one line; an agent's body is not read at all.
_spl_sweep_rows_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v days="${SWEEP_DAYS:-7}" > "$1" <<'SQL'
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT l.tenant_id, coalesce(t.display_name, ''), coalesce(l.channel, ''), l.task_id, l.msg_id,
       extract(epoch FROM l.received_at)::bigint, coalesce(l.typed_by, l.from_id), l.to_id,
       CASE WHEN l.typed_by IS NOT NULL THEN 'terminal'
            WHEN l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%' THEN 'human' ELSE 'agent' END,
       CASE WHEN EXISTS (SELECT 1 FROM messages a WHERE a.tenant_id = l.tenant_id
                          AND a.task_id = l.task_id AND a.archived_at IS NOT NULL)
            THEN 'archived' ELSE 'open' END,
       CASE WHEN l.channel IS NULL THEN 'dm' WHEN c.deleted_at IS NOT NULL THEN 'deleted'
            WHEN c.archived_at IS NOT NULL THEN 'archived' ELSE 'live' END,
       CASE WHEN coalesce(l.has_files, false) THEN 'files' ELSE '-' END,
       CASE WHEN l.typed_by IS NULL AND (l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%')
            THEN regexp_replace(left(l.body, 400), '[[:space:]]+', ' ', 'g') ELSE '' END
  FROM (SELECT DISTINCT ON (m.tenant_id, m.task_id) m.*
          FROM messages m
         WHERE m.expires_at > now() AND m.received_at > now() - make_interval(days => :days)
         ORDER BY m.tenant_id, m.task_id, m.received_at DESC, m.msg_id DESC) l
  JOIN tenants t ON t.tenant_id = l.tenant_id
  LEFT JOIN channels c ON c.tenant_id = l.tenant_id AND c.channel_id = l.channel
 ORDER BY 1, 6;
COMMIT;
SQL
}

# spl_sweep_classify <rows> <state> <outdir>: writes report.md, holder.md,
# orch.md (empty = nothing to send), state.new and last into <outdir>.
spl_sweep_classify() {
  SKIP_T="$(spl_test_workspaces)" SKIP_RE="${SWEEP_SKIP_RE-(^|[-_ ])(e2e|test|proof)([-_ ]|$)}" \
  SKIP_CH="${SWEEP_SKIP_CHANNELS-issues tasks}" ACKS="$LEASE_DIR/unanswered.acks" \
  SKIP_HUM="${SWEEP_SKIP_HUMANS-$([[ "${ENV:-}" == prd ]] && echo HUM-1)}" MIN_AGE="${SWEEP_MIN_AGE:-15}" RESEND="${SWEEP_RESEND:-7200}" \
  MAX_ITEMS="${SWEEP_MAX_ITEMS:-40}" python3 - "$@" <<'PY'
import os, re, sys, time

rows_f, state_f, out = sys.argv[1:4]
e = os.environ
now = int(e["SWEEP_NOW"])
min_age = int(e["MIN_AGE"]) * 60
resend = int(e["RESEND"])
max_items = int(e["MAX_ITEMS"])
skip_t = set(e["SKIP_T"].split())
skip_re = re.compile(e["SKIP_RE"], re.I) if e["SKIP_RE"] else None
skip_ch = set(e["SKIP_CH"].split())
skip_hum = set(e["SKIP_HUM"].split())

# dispatcher acks (do_spl_unanswered_ack): <epoch> \t <topic or prefix> \t <by> \t <reason>
done_acks = []
try:
    for line in open(e["ACKS"], encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2 and f[0].isdigit() and re.fullmatch(r"[0-9a-f-]{8,36}", f[1]):
            done_acks.append((int(f[0]), f[1]))
except OSError:
    pass

def acked(task, ts):
    return any(task.startswith(p) and at >= ts for at, p in done_acks)
to, orch, envn = e["SWEEP_TO_ID"], e["SWEEP_ORCH_ID"], e["ENVN"]

# "ok", "thanks", "thank you", "got it", "👍" ... and nothing else. "yes" is
# NOT here: a yes to an agent's question asks it to act.
ACK = {"ok", "okay", "okey", "k", "kk", "thanks", "thank", "you", "thx", "ty", "tnx", "tx",
       "great", "cool", "nice", "perfect", "good", "fine", "got", "it", "noted", "roger",
       "a", "lot", "much", "so", "very", "super", "awesome", "excellent"}

def is_ack(body, files):
    if files == "files":
        return False
    words = re.findall(r"[^\W_]+", body.lower())
    if not words:
        return body.strip() != ""          # emoji / punctuation only
    return len(words) <= 4 and all(w in ACK for w in words)

def age(s):
    s = max(0, s)
    if s < 3600:
        return "%dm" % (s // 60)
    if s < 86400:
        return "%dh%02dm" % (s // 3600, s % 3600 // 60)
    return "%dd%02dh" % (s // 86400, s % 86400 // 3600)

def cell(s):
    return s.replace("\\", "\\\\").replace("|", "\\|")

def utc(t):
    return time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(t))

counts, items, acks = {}, [], []
for line in open(rows_f, encoding="utf-8", errors="replace"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 13:
        continue
    tenant, tname, chan, task, msg, ts, who, to_id, by, topic, cstate, files = f[:12]
    body = "\t".join(f[12:])
    ts = int(ts)
    c = counts.setdefault(tenant, {k: 0 for k in
        ("open", "ack", "fresh", "closed", "answered", "terminal", "handled", "test", "to-human", "channel", "human")})
    if tenant in skip_t or (skip_re and (skip_re.search(tenant) or (tname and skip_re.search(tname)))):
        c["test"] += 1; continue
    if by == "terminal":
        c["terminal"] += 1; continue
    if by != "human":
        c["answered"] += 1; continue
    if topic == "archived" or cstate in ("archived", "deleted"):
        c["closed"] += 1; continue
    if re.match(r"(HUM|GST)-", to_id) or (cstate == "dm" and to_id == "ALL-0"):
        c["to-human"] += 1; continue
    if chan in skip_ch:
        c["channel"] += 1; continue
    if who in skip_hum:
        c["human"] += 1; continue
    if now - ts < min_age:
        c["fresh"] += 1; continue
    if acked(task, ts):
        c["handled"] += 1; continue
    where = "#" + chan if chan else "dm " + to_id
    row = dict(tenant=tenant, where=where, task=task, msg=msg, ts=ts, who=who,
               text=body[:120] if body else ("(files)" if files == "files" else "(empty)"))
    if is_ack(body, files):
        c["ack"] += 1; acks.append(row)
    else:
        c["open"] += 1; items.append(row)
items.sort(key=lambda r: r["ts"])
acks.sort(key=lambda r: r["ts"])

# state: key \t stage \t first-sent \t last-sent ; stage 1 sent, 2 re-sent, 3 escalated
state = {}
try:
    for line in open(state_f, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) == 4 and f[1] in ("1", "2", "3"):
            state[f[0]] = [int(f[1]), int(f[2]), int(f[3])]
except OSError:          # no state yet (no file, or no dispatch dir on a report-only box)
    pass

new_state, send_new, send_again, escalate = {}, [], [], []
for r in items:
    k = "%s|%s|%s" % (r["tenant"], r["task"], r["msg"])
    st = state.get(k)
    if st is None:
        send_new.append(r); new_state[k] = [1, now, now]
    elif st[0] == 1 and now - st[2] >= resend:
        send_again.append(r); new_state[k] = [2, st[1], now]
    elif st[0] == 2 and now - st[2] >= resend:
        escalate.append(r); new_state[k] = [3, st[1], now]
    else:
        new_state[k] = st
    r["first"] = new_state[k][1]

HDR = "| | workspace | channel | topic | last human | age | who | first 120 chars |\n|---|---|---|---|---|---|---|---|\n"
def table(rows, tag, limit=None):
    s = ""
    for r in rows[:limit]:
        s += "| %s | %s | %s | %s | %s | %s | %s | %s |\n" % (r.get("tag", tag), cell(r["tenant"]), cell(r["where"]), r["task"],
             utc(r["ts"]), age(now - r["ts"]), cell(r["who"]), cell(r["text"]))
    if limit is not None and len(rows) > limit:
        s += "\n... and %d more (the full list: ENV=%s ./run -a do_spl_unanswered_sweep)\n" % (len(rows) - limit, envn)
    return s

stamp = utc(now)
rep = "## Unanswered sweep %s %s\n\n" % (envn, stamp)
rep += "Topics whose last message is a human's, older than %d min (sent to %s; escalation %s).\n\n" % (min_age // 60, to, orch)
rep += HDR + (table(items, "open") if items else "| - | (none) | | | | | | |\n")
rep += "\n### Acknowledgements only (listed, never sent)\n\n" + HDR + (table(acks, "ack") if acks else "| - | (none) | | | | | | |\n")
COLS = ("open", "ack", "handled", "fresh", "closed", "answered", "terminal", "to-human", "channel", "human", "test")
rep += "\n### Per workspace\n\n| workspace | " + " | ".join(COLS) + " |\n|" + "---|" * (len(COLS) + 1) + "\n"
for t in sorted(counts):
    rep += "| %s | " % cell(t) + " | ".join(str(counts[t][k]) for k in COLS) + " |\n"
n_open = sum(c["open"] for c in counts.values())
n_ack = sum(c["ack"] for c in counts.values())
rep += "\nSUM open=%d ack=%d new=%d resend=%d escalate=%d\n" % (n_open, n_ack, len(send_new), len(send_again), len(escalate))
open(os.path.join(out, "report.md"), "w").write(rep)

holder = ""
if send_new or send_again:
    holder = "**Unanswered sweep** (%s, %s): %d new, %d still unanswered after %s.\n\n" % (
        envn, stamp, len(send_new), len(send_again), age(resend))
    holder += ("A human posted last in each topic below and no agent answered. Answer or route each one "
               "(one discussion per lane). An item that needs no agent reply: "
               "`./run -a do_spl_unanswered_ack TOPIC=<uuid> REASON=<why>` and it is not sent again. "
               "An item still open %s after this note is sent once more, then escalated to %s.\n\n" % (age(resend), orch))
    holder += HDR + table([dict(r, tag="NEW") for r in send_new] +
                          [dict(r, tag="AGAIN") for r in send_again], "", max_items)
open(os.path.join(out, "holder.md"), "w").write(holder)

esc = ""
if escalate:
    esc = "**Unanswered sweep ESCALATION** (%s, %s): %d topic(s) still unanswered after two notes to %s.\n\n" % (
        envn, stamp, len(escalate), to)
    esc += HDR + table(escalate, "ESC", max_items)
open(os.path.join(out, "orch.md"), "w").write(esc)

with open(os.path.join(out, "state.new"), "w") as fh:
    for k in sorted(new_state):
        fh.write("%s\t%d\t%d\t%d\n" % (k, *new_state[k]))
per = ",".join("%s=%d" % (t, counts[t]["open"]) for t in sorted(counts) if counts[t]["open"])
with open(os.path.join(out, "last"), "w") as fh:
    fh.write("ts=%d\nopen=%d\nack=%d\nnew=%d\nresend=%d\nescalate=%d\nper=%s\n" % (
        now, n_open, n_ack, len(send_new), len(send_again), len(escalate), per))
PY
}
