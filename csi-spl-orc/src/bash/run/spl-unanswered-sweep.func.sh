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
# @description   to-human - a post addressed to a human (to=HUM-n/GST-n),
# @description              or a null-channel post to ALL-0 in a topic no
# @description              agent has posted in. A null-channel post to
# @description              ALL-0 after an agent post is open (cstate thread)
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
  SWEEP_ORCH="${SWEEP_ORCH:-${LEASE_ORCH:-c-001}}"
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
  if [[ "$LH" != none ]]; then spl_lease_holder_id
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
# DISPATCH_SWEEP_STALE s is a GAP. While another machine holds the lease this
# one's sweep sends nothing and never rewrites the file, so it is not judged.
spl_sweep_check_row() {
  local f="$LEASE_DIR/unanswered.last" k v ts="" open="" per="" sent="" to="" age stale="${DISPATCH_SWEEP_STALE:-1800}"
  spl_lease_read; spl_lease_conf
  if spl_lease_remote && [[ "$LH" != *@unreachable ]]; then
    row "unanswered sweep" "not sent from here" "ok (remote holder $LH: that machine sends)"; return 0
  fi
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
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v days="${SWEEP_DAYS:-7}" > "$1" <<SQL
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
$(_spl_sweep_rows_sql);
COMMIT;
SQL
}

# The sweep's one statement (psql variable :days). The last message of each
# topic is picked on its key alone (k: tenant_id, msg_id; MATERIALIZED, so it
# runs once whatever the join order), then only those rows are read whole.
# A null channel is a DM (cstate dm) only when no agent has posted in the
# topic. Once one has (from_id not HUM-/GST-, and not a terminal mirror),
# cstate is thread: the classifier then keeps a later human post to ALL-0
# open. A human-to-human DM, and a null-channel ALL-0 with no agent, stay dm.
# Perf edition 20261004 E17: DISTINCT ON over m.* sorted every 7-day row at
# full width (bodies, envelopes) and spilled 8 MB to disk each run; prd
# EXPLAIN ANALYZE 110..448 ms -> 71..78 ms, dev 55..59 -> 11..13 ms (n=3 each,
# interleaved), identical rows. Pinned by unanswered-sweep-narrow-pg.tst.sh.
_spl_sweep_rows_sql() {
  cat <<'SQL'
WITH k AS MATERIALIZED (
  SELECT DISTINCT ON (m.tenant_id, m.task_id) m.tenant_id, m.msg_id
    FROM messages m
   WHERE m.expires_at > now() AND m.received_at > now() - make_interval(days => :days)
   ORDER BY m.tenant_id DESC, m.task_id DESC, m.received_at DESC, m.msg_id DESC)
SELECT l.tenant_id, coalesce(t.display_name, ''), coalesce(l.channel, ''), l.task_id, l.msg_id,
       extract(epoch FROM l.received_at)::bigint, coalesce(l.typed_by, l.from_id), l.to_id,
       CASE WHEN l.typed_by IS NOT NULL THEN 'terminal'
            WHEN l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%' THEN 'human' ELSE 'agent' END,
       CASE WHEN EXISTS (SELECT 1 FROM messages a WHERE a.tenant_id = l.tenant_id
                          AND a.task_id = l.task_id AND a.archived_at IS NOT NULL)
            THEN 'archived' ELSE 'open' END,
       CASE WHEN l.channel IS NOT NULL AND c.deleted_at IS NOT NULL THEN 'deleted'
            WHEN l.channel IS NOT NULL AND c.archived_at IS NOT NULL THEN 'archived'
            WHEN l.channel IS NOT NULL THEN 'live'
            WHEN EXISTS (SELECT 1 FROM messages g
                          WHERE g.tenant_id = l.tenant_id AND g.task_id = l.task_id
                            AND g.typed_by IS NULL
                            AND g.from_id NOT LIKE 'HUM-%' AND g.from_id NOT LIKE 'GST-%')
            THEN 'thread' ELSE 'dm' END,
       CASE WHEN coalesce(l.has_files, false) THEN 'files' ELSE '-' END,
       CASE WHEN l.typed_by IS NULL AND (l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%')
            THEN regexp_replace(left(l.body, 400), '[[:space:]]+', ' ', 'g') ELSE '' END
  FROM k
  JOIN messages l ON l.tenant_id = k.tenant_id AND l.msg_id = k.msg_id
  JOIN tenants t ON t.tenant_id = l.tenant_id
  LEFT JOIN channels c ON c.tenant_id = l.tenant_id AND c.channel_id = l.channel
 ORDER BY 1, 6
SQL
}

# spl_sweep_classify <rows> <state> <outdir>: writes report.md, holder.md,
# orch.md (empty = nothing to send), state.new and last into <outdir>.
spl_sweep_classify() {
  SKIP_T="$(spl_test_workspaces)" SKIP_RE="${SWEEP_SKIP_RE-(^|[-_ ])(e2e|test|proof)([-_ ]|$)}" \
  SKIP_CH="${SWEEP_SKIP_CHANNELS-issues tasks}" ACKS="$LEASE_DIR/unanswered.acks" \
  SKIP_HUM="${SWEEP_SKIP_HUMANS-$([[ "${ENV:-}" == prd ]] && echo HUM-1)}" MIN_AGE="${SWEEP_MIN_AGE:-15}" RESEND="${SWEEP_RESEND:-7200}" \
  MAX_ITEMS="${SWEEP_MAX_ITEMS:-40}" python3 "$(dirname "${BASH_SOURCE[0]}")/../scripts/unanswered-sweep-classify.py" "$@"
}
