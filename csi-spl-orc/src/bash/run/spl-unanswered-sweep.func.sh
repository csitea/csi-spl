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
# @description message is a human's, aged from the OLDEST human post after
# @description the topic's last agent reply: listed once that post is older
# @description than SWEEP_MIN_AGE minutes, however many came after it.
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
# @description   to-human - a post addressed to a human (to=HUM-n/GST-n)
# @description   nobody   - a null-channel post to ALL-0 in a topic no agent
# @description              has posted in: read by its writer alone (spec
# @description              117 1.3). LISTED in its own table ("Reached
# @description              nobody", ids and seat only), never sent;
# @description              do_spl_msg_unreadable alerts on these. A
# @description              null-channel post to ALL-0 after an agent post
# @description              is open (cstate thread)
# @description   channel  - a channel in SWEEP_SKIP_CHANNELS (#issues, #tasks,
# @description              #probe: the live proof's hidden test channel), or
# @description              a channel whose AI agents switch is off (SPL-1684,
# @description              rdb 0189: cstate ai_off) when the post names no
# @description              agent (to ALL-0); an @agent dispatch stays open
# @description   fresh    - younger than SWEEP_MIN_AGE (the live path has it)
# @description   ack      - a pure acknowledgement ("ok", "thanks", emoji
# @description              only): LISTED in its own table, never delivered
# @description DELIVER=1 sends ONE spool note (task unanswered-sweep) to the
# @description lease holder (do_spl_dispatch_lease show) with the items NEW
# @description since the last sweep, plus each item still open SWEEP_RESEND s
# @description after it was sent (once); an item still open SWEEP_RESEND s
# @description after that re-send is escalated to the orchestrator, once.
# @description With SWEEP_ESCALATE_AGE an item is escalated, once, as soon as
# @description its oldest unanswered post is that many minutes old (the cron
# @description line: SWEEP_MIN_AGE=3, SWEEP_ESCALATE_AGE=5, every minute).
# @description The memory is <spool root>/dispatch/unanswered.state (an item is
# @description a topic's oldest unanswered human post: more human posts keep
# @description it one item; one after an agent reply is a new item),
# @description and <spool root>/dispatch/unanswered.last holds the last
# @description delivered sweep's time and counts (do_spl_dispatch_check reads
# @description it).
# @description Seats (spec 101 D7): while <spool root>/peer/seats holds a seat
# @description line (the same switch as spool-send.sh's peers leg), every box
# @description sends - the fleet-lease skip is off - and each NEW, AGAIN or
# @description ESC item is its OWN note to `peers`, so one seat claims it.
# @description The sweep reads the last message of each topic, never the
# @description claim, so a job owned by a dead holder is still listed. No
# @description seats file: today's single note to the lease holder.
# @description Without DELIVER=1 nothing is written or sent: the report
# @description and the PLAN lines only. The cron line is
# @description do_spl_unanswered_sweep_install_cron.
# @description Read-only on the hub: one statement set in a READ ONLY
# @description transaction, operator RLS scope, as the env SA.
# @description Row cache (perf round 5 P5-01): DELIVER=1 keeps the row set in
# @description <spool root>/dispatch/unanswered.rows and reads only the topics
# @description that moved since (topic heads, archived channels, edits); every
# @description SWEEP_FULL_EVERY s a full read replaces it and counts the drift.
# @description A workspace whose tenants.settings spool_enc is true (spec 136
# @description L6a) contributes an empty body: the excerpt is not copied out
# @description of the hub (FR9 W5). The cache meta records v=2; a cache without
# @description it is replaced by a full read, so an excerpt saved earlier does
# @description not stay.
# @param ENV - required: dev or prd
# @param DELIVER (optional) - 1 sends and records; default 0 (report only)
# @param SWEEP_MIN_AGE (optional) - minutes a human post waits before it counts, default 15
# @param SWEEP_DAYS (optional) - lookback in days, default 7
# @param SWEEP_RESEND (optional) - seconds before a re-send and again before the escalation, default 7200
# @param SWEEP_ESCALATE_AGE (optional) - minutes from the oldest unanswered post to the escalation; unset = the two-SWEEP_RESEND path
# @param SWEEP_SKIP_TENANTS (optional) - space-separated test workspaces, default e2e; <spool root>/dispatch/test-workspaces adds to it (one id per line)
# @param SWEEP_SKIP_RE (optional) - a workspace id or name matching this ERE is a test one, default (^|[-_ ])(e2e|test|proof)([-_ ]|$)
# @param SWEEP_SKIP_CHANNELS (optional) - default "issues tasks probe" (probe: wf 30's live proof posts, SPL-1632)
# @param SWEEP_SKIP_HUMANS (optional) - posters left out; default HUM-1 on prd (the e2e probe owner), none on dev
# @param SWEEP_MAX_ITEMS (optional) - rows per delivered note, default 40
# @param SWEEP_FULL_EVERY (optional) - seconds between full reads of a delivering sweep, default 3600
# @param SWEEP_OVERLAP (optional) - seconds a delta read reaches back before the last read, default 300
# @param SWEEP_ROWS_FILE (optional) - read the rows from this file instead of the hub (tests, an export)
# @param SWEEP_TO / SWEEP_ORCH / SWEEP_FROM (optional) - recipient, escalation target, sender; default the lease holder, LEASE_ORCH (lease.conf) or CLE-001, the orchestrator; with seats both recipients are peers
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ENV=prd ./run -a do_spl_unanswered_sweep
# @example ENV=prd DELIVER=1 ./run -a do_spl_unanswered_sweep
# @example ENV=prd SWEEP_MIN_AGE=60 SWEEP_SKIP_TENANTS='e2e leiden' ./run -a do_spl_unanswered_sweep
#------------------------------------------------------------------------------
do_spl_unanswered_sweep() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local deliver="${DELIVER:-0}" v
  [[ "$deliver" == 0 || "$deliver" == 1 ]] || { do_log "FATAL DELIVER must be 0 or 1"; return 1; }
  for v in SWEEP_MIN_AGE SWEEP_DAYS SWEEP_RESEND SWEEP_MAX_ITEMS SWEEP_ESCALATE_AGE SWEEP_FULL_EVERY SWEEP_OVERLAP; do
    [[ -z "${!v:-}" || "${!v}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $v must be a positive integer, got: '${!v}'"; return 1; }
  done
  spl_lease_init ro || return 1
  spl_lease_conf
  SWEEP_ORCH="${SWEEP_ORCH:-${LEASE_ORCH:-c-001}}"
  SWEEP_FROM="${SWEEP_FROM:-$SWEEP_ORCH}"
  # fleet mode (CLE-77911): another machine holds the dispatch lease, so its
  # own sweep sends; sending from here too would deliver every item twice
  # with seats (spec 101 D7) every box sends: its notes go to peers, not to
  # the lease holder, and one seat claims each
  if (( ${DELIVER:-0} )) && [[ -z "${SWEEP_TO:-}" ]] && ! spl_sweep_seated && spl_lease_read && spl_lease_remote; then
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
  local tmp="$1" deliver="$2" to f ok=1 orch="$SWEEP_ORCH" seats=0
  spl_sweep_rows "$tmp/rows" "$deliver" || return 1
  to="$(spl_sweep_holder)"
  if [[ -z "${SWEEP_TO:-}" ]] && spl_sweep_seated; then seats=1 to=peers orch=peers; fi
  SWEEP_NOW="${SWEEP_NOW:-$(date +%s)}" SWEEP_TO_ID="$to" SWEEP_ORCH_ID="$orch" ENVN="$ENV" \
    spl_sweep_classify "$tmp/rows" "$LEASE_DIR/unanswered.state" "$tmp" || return 1
  cat "$tmp/report.md"
  if (( ! deliver )); then
    for f in holder orch; do
      [[ -s "$tmp/$f.md" ]] || continue
      if (( seats )); then echo "PLAN send to peers: $(spl_sweep_items "$tmp/$f.md" | wc -l) note(s), one per item: $(head -1 "$tmp/$f.md")"
      else echo "PLAN send to $([[ $f == holder ]] && echo "$to" || echo "$orch"): $(head -1 "$tmp/$f.md")"; fi
    done
    do_log "OK report only - DELIVER=1 sends the NEW items and records them"
    return 0
  fi
  if (( seats )); then
    for f in holder orch; do
      [[ -s "$tmp/$f.md" ]] && { spl_sweep_send_items "$tmp/$f.md" "$tmp" || ok=0; }
    done
  else
    [[ -s "$tmp/holder.md" ]] && { spl_sweep_send "$to" "$tmp/holder.md" || ok=0; }
    [[ -s "$tmp/orch.md" ]] && { spl_sweep_send "$orch" "$tmp/orch.md" || ok=0; }
  fi
  # the memory moves only when every send landed: a failed one is re-tried
  # as NEW on the next sweep rather than forgotten
  if (( ok )); then
    mv -f "$tmp/state.new" "$LEASE_DIR/unanswered.state" || return 1
  fi
  { cat "$tmp/last"; echo "to=$to"; echo "sent=$([[ $ok == 1 ]] && echo ok || echo FAILED)"
    if [[ -z "${SWEEP_ROWS_FILE:-}" && -r "$LEASE_DIR/unanswered.rows.info" ]]; then cat "$LEASE_DIR/unanswered.rows.info"; fi
  } > "$LEASE_DIR/unanswered.last.tmp" &&
    mv -f "$LEASE_DIR/unanswered.last.tmp" "$LEASE_DIR/unanswered.last"
  (( ok )) || { do_log "FATAL a sweep note was not delivered; the items stay NEW for the next sweep"; return 1; }
  return 0
}

# 0 when this machine has a seat (spec 068 L3 / 101 D7): a seat line in
# <spool root>/peer/seats, parsed as spool-send.sh's send_to_peers_on does.
spl_sweep_seated() {
  local f="${SPOOL_ROOT:-/var/spool-hub}/peer/seats"
  [[ -r "$f" ]] && sed 's/#.*//' "$f" | awk '$1 ~ /^[acgmq]-[0-9][0-9][0-9]$/ && $2 ~ /^[a-z]+$/ { f = 1 } END { exit !f }'
}

# spl_sweep_items <note>: the item rows of a holder.md / orch.md table.
spl_sweep_items() { grep -E '^\| (NEW|AGAIN|ESC) \|' "$1"; }

# spl_sweep_send_items <note> <tmp>: one peers note per item row, each the
# note's text above its table, the table header and that one row; a seat
# claims each. Every item is tried; 1 when any send failed.
spl_sweep_send_items() {
  local note="$1" head="$2/item.head" one="$2/item.md" line rc=0
  sed '/^| |/,$d' "$note" >"$head"
  while IFS= read -r line; do
    { cat "$head"; grep -m2 -E '^\| \||^\|---' "$note"; echo "$line"; } >"$one"
    spl_sweep_send peers "$one" || rc=1
  done < <(spl_sweep_items "$note")
  return $rc
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

# spl_sweep_send <to> <body file> [task]: one spool note on task unanswered-sweep
# (or [task]: do_spl_msg_unreadable sends on msg-unreadable).
# SWEEP_SEND replaces the sender script in the tests.
spl_sweep_send() {
  local send="${SWEEP_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}" bin="${SPOOL_BIN:-}"
  if [[ -z "$bin" ]]; then
    local org_app; org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
    bin="$HOME/.local/share/$org_app/cloud/$ENV/bin/spool"
    [[ -x "$bin" ]] || bin=spool
  fi
  SPOOL_BIN="$bin" SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$SWEEP_FROM" --to "$1" \
    --kind note --task "${3:-unanswered-sweep}" --body-file "$2" >/dev/null 2>&1 8>&- 9>&- ||
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
  if ! spl_sweep_seated && spl_lease_remote && [[ "$LH" != *@unreachable ]]; then
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

# spl_sweep_rows <out> [<deliver>]: the last message of every topic in the
# window, one TSV line each (spl_sweep_classify names the columns), from
# SWEEP_ROWS_FILE or the hub. A delivering sweep reads through the row cache
# (spl_sweep_rows_cached); a report reads the whole set and keeps nothing.
spl_sweep_rows() {
  if [[ -n "${SWEEP_ROWS_FILE:-}" ]]; then
    cp "$SWEEP_ROWS_FILE" "$1" || { do_log "FATAL cannot read SWEEP_ROWS_FILE $SWEEP_ROWS_FILE"; return 1; }
    return 0
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if [[ "${2:-0}" == 1 ]]; then
    spl_sweep_rows_cached "$1" || { do_log "FATAL could not read the topics of $ENV"; return 1; }
    return 0
  fi
  spl_via_proxy _spl_sweep_rows_read "$1" || { do_log "FATAL could not read the topics of $ENV"; return 1; }
}

# spl_sweep_rows_cached <out> (perf round 5 P5-01): a delivering sweep keeps
# its row set in $LEASE_DIR/unanswered.rows, with the DB time it was read at
# (unanswered.rows.meta, v=2). v=2 means a spool_enc workspace's body is empty
# in every row; a cache with another v is stale and is replaced by a full read.
# Otherwise the next run reads only the topics that moved since
# then less SWEEP_OVERLAP s (a write that committed late), and merges them in
# (spl_sweep_merge). With no cache, a cache of another ENV or SWEEP_DAYS, or
# the last full read SWEEP_FULL_EVERY s ago or more, it reads the whole set;
# when a cache exists it reads the delta in the same snapshot too and counts
# the lines the merge would have got wrong (drift, a WARN when not 0).
# unanswered.rows.info says which read it was (do_spl_unanswered_sweep
# appends it to unanswered.last).
spl_sweep_rows_cached() {
  local out="$1" cache="$LEASE_DIR/unanswered.rows" meta="$LEASE_DIR/unanswered.rows.meta"
  local info="$LEASE_DIR/unanswered.rows.info" days="${SWEEP_DAYS:-7}"
  local every="${SWEEP_FULL_EVERY:-3600}" overlap="${SWEEP_OVERLAP:-300}"
  local k v m_env="" m_days="" m_now="" m_full="" m_v="" since="" now full drift="" tns tks
  if [[ -r "$cache" && -r "$meta" ]]; then
    while IFS='=' read -r k v; do
      case "$k" in env) m_env="$v" ;; days) m_days="$v" ;; now) m_now="$v" ;; full) m_full="$v" ;; v) m_v="$v" ;; esac
    done <"$meta"
  fi
  [[ "$m_env" == "$ENV" && "$m_days" == "$days" && "$m_v" == 2 && "$m_now" =~ ^[0-9]+$ && "$m_full" =~ ^[0-9]+$ ]] &&
    since=$((m_now - overlap))
  [[ -n "$since" ]] && read -r tns tks < <(spl_sweep_keep "$cache")
  if [[ -n "$since" ]] && (( $(date +%s) - m_full < every )); then
    spl_via_proxy _spl_sweep_rows_read "" "$out.now" "$since" "$out.delta" "$tns" "$tks" || return 1
    now="$(cat "$out.now")" full="$m_full"
    [[ "$now" =~ ^[0-9]+$ ]] || { do_log "FATAL the read returned no DB time"; return 1; }
    spl_sweep_merge "$cache" "$out.delta" "$now" "$days" >"$out" || return 1
    printf 'rows=delta\nmoved=%s\n' "$(wc -l <"$out.delta")" >"$info.tmp"
  else
    if [[ -n "$since" ]]; then
      spl_via_proxy _spl_sweep_rows_read "$out" "$out.now" "$since" "$out.delta" "$tns" "$tks" || return 1
    else
      spl_via_proxy _spl_sweep_rows_read "$out" "$out.now" || return 1
    fi
    now="$(cat "$out.now")" full="$now"
    [[ "$now" =~ ^[0-9]+$ ]] || { do_log "FATAL the read returned no DB time"; return 1; }
    if [[ -n "$since" ]]; then
      spl_sweep_merge "$cache" "$out.delta" "$now" "$days" >"$out.merged" || return 1
      drift="$(diff <(LC_ALL=C sort "$out.merged") <(LC_ALL=C sort "$out") | grep -c '^[<>]')"
      (( drift == 0 )) ||
        do_log "WARN the row cache drifted from the hub in $drift line(s) since the last full read; the full read replaces it"
    fi
    { echo "rows=full"; [[ -n "$drift" ]] && echo "drift=$drift"; } >"$info.tmp"
  fi
  # the cache before its meta: a meta left behind only re-reads more
  cp "$out" "$cache.tmp" && mv -f "$cache.tmp" "$cache" &&
    printf 'env=%s\ndays=%s\nnow=%s\nfull=%s\nv=2\n' "$ENV" "$days" "$now" "$full" >"$meta.tmp" &&
    mv -f "$meta.tmp" "$meta" && mv -f "$info.tmp" "$info" || { do_log "FATAL cannot write the row cache in $LEASE_DIR"; return 1; }
  rm -f "$out.now" "$out.delta" "$out.merged"
}

# spl_sweep_keep <cache> -> two words, the Postgres arrays of the workspaces
# and topics of its human-last rows (the only rows the sweep can list): the
# delta looks up their heads every run, so a deleted topic, whose head is
# deleted with it, leaves the list at once and not at the next full read.
spl_sweep_keep() {
  awk -F'\t' '$9 == "human" && $1 ~ /^[A-Za-z0-9._-]+$/ && $4 ~ /^[0-9a-f-]+$/ { tn = tn s $1; tk = tk s $4; s = "," }
    END { print "{" tn "}", "{" tk "}" }' "$1"
}

# spl_sweep_merge <cache> <delta> <db now> <days>: the cached rows still in
# the window, with every topic of <delta> replaced by its delta row; a delta
# line with no msg_id (column 5) is a topic that left the set. Sorted by
# workspace and time, as the full read is.
spl_sweep_merge() {
  awk -F'\t' -v cut="$(($3 - $4 * 86400))" -v delta="$2" '
    FILENAME == delta { moved[$1 FS $4] = 1; if ($5 != "") print; next }
    !(($1 FS $4) in moved) && $6 + 0 > cut' "$2" "$1" | LC_ALL=C sort -t $'\t' -k1,1 -k6,6n -k4,4
}

# _spl_sweep_rows_read <out> [<now out> [<since> <delta out> [<tns> <tks>]]]:
# read-only, inside spl_via_proxy, in ONE repeatable-read snapshot: the DB
# time (floored: never past the read) into <now out>, the delta since the epoch <since> (plus the topics
# tns[i]/tks[i], spl_sweep_keep) into <delta out>, and the full set into
# <out> (skipped when <out> is ""). Tabs and newlines in a body collapse to
# one space so a row is one line; an agent's body is not read. A workspace
# whose tenants.settings spool_enc is true (spec 136 L6a) contributes an
# empty body too: that excerpt must not leave the hub (FR9 W5).
_spl_sweep_rows_read() {
  local none='{}'
  local out="$1" nowf="${2:-}" since="${3:-}" delta_out="${4:-}" tns="${5:-$none}" tks="${6:-$none}"
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v days="${SWEEP_DAYS:-7}" -v since="${since:-0}" \
    -v tns="$tns" -v tks="$tks" >/dev/null <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL app.rls_scope = 'operator';
$([[ -n "$nowf" ]] && printf '\\o %s\nSELECT floor(extract(epoch FROM now()))::bigint;\n' "$nowf")
$([[ -n "$delta_out" ]] && printf '\\o %s\n%s;\n' "$delta_out" "$(_spl_sweep_delta_sql)")
$([[ -n "$out" ]] && printf '\\o %s\n%s;\n' "$out" "$(_spl_sweep_rows_sql)")
\o
COMMIT;
SQL
}

# The sweep's one statement (psql variable :days). The last message of each
# topic is picked on its key alone (k: tenant_id, msg_id; MATERIALIZED, so it
# runs once whatever the join order), then only those rows are read whole.
# A null channel is a DM (cstate dm) only when no agent has posted in the
# topic. Once one has (from_id not HUM-/GST-, and not a terminal mirror),
# cstate is thread: the classifier then keeps a later human post to ALL-0
# open. A human-to-human DM, and a null-channel ALL-0 with no agent (the
# classifier's 'nobody'), stay dm.
# Perf edition 20261004 E17: DISTINCT ON over m.* sorted every 7-day row at
# full width (bodies, envelopes) and spilled 8 MB to disk each run; prd
# EXPLAIN ANALYZE 110..448 ms -> 71..78 ms, dev 55..59 -> 11..13 ms (n=3 each,
# interleaved), identical rows. Pinned by unanswered-sweep-narrow-pg.tst.sh.
# API perf round d-02 (2026-10-07): the per-row probes were most of what was
# left (prd EXPLAIN, 1 166 rows: 11 476 buffers, of them 2 358 in one archived
# probe per row and 3 368 in 795 agent-post probes). The archived topics are
# now read once (an uncorrelated IN: one hashed SubPlan over the small partial
# index messages_archived, never a per-row loop), and a last
# message that is itself an agent post answers the agent-post question for
# its topic without a probe. Same rows (narrow-pg check 1 compares them).
# M3 (2026-10-11): two trailing columns, read only when the last message is
# a human's (a one-time filter in the LATERAL f): the time and id of the
# OLDEST human post after the topic's last agent reply (a terminal mirror
# counts as one). The sweep ages and keys an item from it, so a burst of
# human posts is not held as fresh by its newest one.
_spl_sweep_rows_sql() {
  cat <<'SQL'
WITH k AS MATERIALIZED (
  SELECT DISTINCT ON (m.tenant_id, m.task_id) m.tenant_id, m.msg_id
    FROM messages m
   WHERE m.expires_at > now() AND m.received_at > now() - make_interval(days => :days)
   ORDER BY m.tenant_id DESC, m.task_id DESC, m.received_at DESC, m.msg_id DESC)
SQL
  _spl_sweep_rows_tail "(l.tenant_id, l.task_id) IN (SELECT a.tenant_id, a.task_id FROM messages a
                                               WHERE a.archived_at IS NOT NULL)"
  echo " ORDER BY 1, 6"
}

# Perf round 5 P5-01: the same rows for the topics that moved after the epoch
# :since (psql variables :days, :since), for spl_sweep_merge. A topic moved
# when its head was written (topic_heads.changed_at: an insert, a delete, an
# archive or an expiry change, spec 099), its head is due (a key line expired:
# valid_until), its channel was archived or deleted, or one of its lines was
# edited (message_revisions); and a topic the caller names (:tns, :tks: the
# cached human-last rows, spl_sweep_keep) whose head is gone (the topic was
# deleted, and its head with it). Each moved topic's last line is one backward
# probe of messages_task_received; a moved topic with no line left in the
# window is one row with its two keys only (it leaves the set). The archived
# card is a probe per moved row, not the full read's hashed set of every
# archived line. Not seen until the next full read (SWEEP_FULL_EVERY): a
# channel un-archived, a workspace renamed, a workspace's AI agents default
# changed (a channel's own switch is read: ai_agents_at).
_spl_sweep_delta_sql() {
  cat <<'SQL'
WITH mv AS MATERIALIZED (
  SELECT h.tenant_id, h.task_id FROM topic_heads h
   WHERE h.changed_at > to_timestamp(:since)
      OR (h.valid_until <= now() AND h.last_at > now() - make_interval(days => :days))
  UNION
  SELECT p.tenant_id, p.task_id FROM channels c
    JOIN topic_head_parts p ON p.tenant_id = c.tenant_id AND p.channel = c.channel_id
   WHERE c.archived_at > to_timestamp(:since) OR c.deleted_at > to_timestamp(:since)
      OR c.ai_agents_at > to_timestamp(:since)
  UNION
  SELECT e.tenant_id, e.task_id FROM message_revisions r
    JOIN messages e ON e.tenant_id = r.tenant_id AND e.msg_id = r.msg_id
   WHERE r.edited_at > to_timestamp(:since)
  UNION
  SELECT u.tn, u.tk FROM unnest(:'tns'::text[], :'tks'::uuid[]) u (tn, tk)
   WHERE NOT EXISTS (SELECT 1 FROM topic_heads o WHERE o.tenant_id = u.tn AND o.task_id = u.tk)),
k AS MATERIALIZED (
  SELECT mv.tenant_id, mv.task_id, x.msg_id FROM mv
  LEFT JOIN LATERAL (
    SELECT m.msg_id FROM messages m
     WHERE m.tenant_id = mv.tenant_id AND m.task_id = mv.task_id
       AND m.expires_at > now() AND m.received_at > now() - make_interval(days => :days)
     ORDER BY m.received_at DESC, m.msg_id DESC LIMIT 1) x ON true)
SQL
  _spl_sweep_rows_tail "EXISTS (SELECT 1 FROM messages a WHERE a.tenant_id = l.tenant_id
                                          AND a.task_id = l.task_id AND a.archived_at IS NOT NULL)"
  cat <<'SQL'
UNION ALL
SELECT k.tenant_id, NULL, NULL, k.task_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
  FROM k WHERE k.msg_id IS NULL
 ORDER BY 1, 6
SQL
}

# _spl_sweep_rows_tail <archived predicate>: the select list and joins of
# both reads, over a CTE k holding (tenant_id, msg_id) of each last line.
_spl_sweep_rows_tail() {
  cat <<SQL
SELECT l.tenant_id, coalesce(t.display_name, ''), coalesce(l.channel, ''), l.task_id, l.msg_id,
       extract(epoch FROM l.received_at)::bigint, coalesce(l.typed_by, l.from_id), l.to_id,
       CASE WHEN l.typed_by IS NOT NULL THEN 'terminal'
            WHEN l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%' THEN 'human' ELSE 'agent' END,
       CASE WHEN $1
            THEN 'archived' ELSE 'open' END,
SQL
  cat <<'SQL'
       CASE WHEN l.channel IS NOT NULL AND c.deleted_at IS NOT NULL THEN 'deleted'
            WHEN l.channel IS NOT NULL AND c.archived_at IS NOT NULL THEN 'archived'
            WHEN l.channel IS NOT NULL AND coalesce(l.to_id, 'ALL-0') = 'ALL-0'
                 AND NOT coalesce(c.ai_agents, (t.settings->>'channel_ai_agents')::boolean, true) THEN 'ai_off'
            WHEN l.channel IS NOT NULL THEN 'live'
            WHEN l.typed_by IS NULL AND l.from_id NOT LIKE 'HUM-%' AND l.from_id NOT LIKE 'GST-%' THEN 'thread'
            WHEN EXISTS (SELECT 1 FROM messages g
                          WHERE g.tenant_id = l.tenant_id AND g.task_id = l.task_id
                            AND g.typed_by IS NULL
                            AND g.from_id NOT LIKE 'HUM-%' AND g.from_id NOT LIKE 'GST-%')
            THEN 'thread' ELSE 'dm' END,
       CASE WHEN coalesce(l.has_files, false) THEN 'files' ELSE '-' END,
       CASE WHEN l.typed_by IS NULL AND (l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%')
                 AND NOT coalesce(t.settings->'spool_enc' = 'true'::jsonb, false)
            THEN regexp_replace(left(l.body, 400), '[[:space:]]+', ' ', 'g') ELSE '' END,
       coalesce(extract(epoch FROM f.received_at)::bigint::text, ''), coalesce(f.msg_id::text, '')
  FROM k
  JOIN messages l ON l.tenant_id = k.tenant_id AND l.msg_id = k.msg_id
  JOIN tenants t ON t.tenant_id = l.tenant_id
  LEFT JOIN channels c ON c.tenant_id = l.tenant_id AND c.channel_id = l.channel
  LEFT JOIN LATERAL (
    SELECT h.received_at, h.msg_id FROM messages h
     WHERE l.typed_by IS NULL AND (l.from_id LIKE 'HUM-%' OR l.from_id LIKE 'GST-%')
       AND h.tenant_id = l.tenant_id AND h.task_id = l.task_id
       AND h.expires_at > now() AND h.received_at > now() - make_interval(days => :days)
       AND h.typed_by IS NULL AND (h.from_id LIKE 'HUM-%' OR h.from_id LIKE 'GST-%')
       AND NOT EXISTS (SELECT 1 FROM messages r
                        WHERE r.tenant_id = h.tenant_id AND r.task_id = h.task_id
                          AND (r.typed_by IS NOT NULL
                               OR (r.from_id NOT LIKE 'HUM-%' AND r.from_id NOT LIKE 'GST-%'))
                          AND (r.received_at, r.msg_id) > (h.received_at, h.msg_id))
     ORDER BY h.received_at, h.msg_id LIMIT 1) f ON true
SQL
}

# spl_sweep_classify <rows> <state> <outdir>: writes report.md, holder.md,
# orch.md (empty = nothing to send), state.new and last into <outdir>.
spl_sweep_classify() {
  SKIP_T="$(spl_test_workspaces)" SKIP_RE="${SWEEP_SKIP_RE-(^|[-_ ])(e2e|test|proof)([-_ ]|$)}" \
  SKIP_CH="${SWEEP_SKIP_CHANNELS-issues tasks probe}" ACKS="$LEASE_DIR/unanswered.acks" \
  SKIP_HUM="${SWEEP_SKIP_HUMANS-$([[ "${ENV:-}" == prd ]] && echo HUM-1)}" MIN_AGE="${SWEEP_MIN_AGE:-15}" RESEND="${SWEEP_RESEND:-7200}" ESC_AGE="${SWEEP_ESCALATE_AGE:-}" \
  MAX_ITEMS="${SWEEP_MAX_ITEMS:-40}" python3 "$(dirname "${BASH_SOURCE[0]}")/../scripts/unanswered-sweep-classify.py" "$@"
}
