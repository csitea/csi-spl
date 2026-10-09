#!/bin/bash
#------------------------------------------------------------------------------
# @description List the messages only their writer can read, per workspace of
# @description the env's hub (spec 117 1.3): from a person (HUM-/GST-), to
# @description ALL-0, no channel. The read door shows a channel-less row to its
# @description from and its to only, and ALL-0 is no seat, so such a row is
# @description seen by its writer alone: the writer saw "sent", nobody else saw
# @description anything (prd t1 f87e6c9d, 2026-10-09).
# @description Output: ids, times and seats only - a body is never read.
# @description Test workspaces (spl_test_workspace: e2e, SWEEP_SKIP_TENANTS,
# @description <spool root>/dispatch/test-workspaces, SWEEP_SKIP_RE on the id
# @description or the name) are counted apart and never alerted.
# @description DELIVER=1 sends ONE spool note (task msg-unreadable) to the
# @description orchestrator with the rows NEW since the last delivered run,
# @description and records them in <spool root>/dispatch/unreadable-<env>.state;
# @description a failed send records nothing (the rows stay NEW). While
# @description another machine holds the fleet's dispatch lease this machine
# @description sends nothing (that one does). The daily cron is the box-crons
# @description manifest row msg-unreadable (do_install_box_crons).
# @description Read-only on the hub: one statement in a READ ONLY transaction,
# @description operator RLS scope, as the env SA.
# @param ENV - required: dev or prd
# @param DELIVER (optional) - 1 sends and records; default 0 (report only)
# @param UNREADABLE_DAYS (optional) - lookback in days, default 30
# @param UNREADABLE_MAX_ITEMS (optional) - rows per note, default 40
# @param UNREADABLE_TO / UNREADABLE_FROM (optional) - recipient and sender, default LEASE_ORCH (lease.conf) or c-001
# @param UNREADABLE_ROWS_FILE (optional) - read the rows from this file instead of the hub (tests, an export)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ENV=prd ./run -a do_spl_msg_unreadable
# @example ENV=prd DELIVER=1 ./run -a do_spl_msg_unreadable
#------------------------------------------------------------------------------
do_spl_msg_unreadable() {
  spl_require_cloud_env || return 1
  local deliver="${DELIVER:-0}" v
  [[ "$deliver" == 0 || "$deliver" == 1 ]] || { do_log "FATAL DELIVER must be 0 or 1"; return 1; }
  for v in UNREADABLE_DAYS UNREADABLE_MAX_ITEMS; do
    [[ -z "${!v:-}" || "${!v}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $v must be a positive integer, got: '${!v}'"; return 1; }
  done
  spl_lease_init ro || return 1
  spl_lease_conf
  local to="${UNREADABLE_TO:-${LEASE_ORCH:-c-001}}" tmp rc=0
  [[ "$to" =~ ^[A-Za-z0-9@._-]+$ ]] || { do_log "FATAL UNREADABLE_TO is not an agent id: '$to'"; return 1; }
  # one alert per fleet: the machine that holds the dispatch lease sends it
  if (( deliver )) && [[ -z "${UNREADABLE_TO:-}" ]] && spl_lease_read && spl_lease_remote; then
    do_log "INFO the fleet's dispatch lease is held by $LH: that machine's run sends, this one sends nothing"
    return 0
  fi
  tmp="$(mktemp -d)" || return 1
  spl_unreadable_run "$tmp" "$deliver" "$to" || rc=1
  rm -rf "$tmp"
  return $rc
}

# spl_unreadable_run <tmp> <deliver> <to>: read, classify, report, then send +
# record. The memory moves only when the note landed (or there was none).
spl_unreadable_run() {
  local tmp="$1" deliver="$2" to="$3" state="$LEASE_DIR/unreadable-$ENV.state"
  spl_unreadable_rows "$tmp/rows" || return 1
  spl_unreadable_classify "$tmp/rows" "$state" "$tmp" || return 1
  cat "$tmp/report.md"
  if (( ! deliver )); then
    [[ -s "$tmp/note.md" ]] && echo "PLAN send to $to: $(head -1 "$tmp/note.md")"
    do_log "OK report only - DELIVER=1 sends the NEW rows to $to and records them"
    return 0
  fi
  mkdir -p "$LEASE_DIR" || { do_log "FATAL cannot create $LEASE_DIR"; return 1; }
  if [[ -s "$tmp/note.md" ]]; then
    SWEEP_FROM="${UNREADABLE_FROM:-$to}" spl_sweep_send "$to" "$tmp/note.md" msg-unreadable ||
      { do_log "FATAL the note was not delivered; the rows stay NEW for the next run"; return 1; }
  fi
  mv -f "$tmp/state.new" "$state" || { do_log "FATAL cannot write $state"; return 1; }
}

# spl_unreadable_classify <rows> <state> <outdir>: writes report.md, note.md
# (empty = nothing to send) and state.new (one <tenant>|<msg_id> per line).
spl_unreadable_classify() {
  local rows="$1" state="$2" out="$3" t tn m task ts who kind with tag key line n=0 nnew=0 ntest=0 stamp
  local max="${UNREADABLE_MAX_ITEMS:-40}" live="$3/live" new="$3/new" test="$3/test"
  : >"$live"; : >"$new"; : >"$test"; : >"$out/state.new"; : >"$out/note.md"
  # tab is IFS white space: two tabs around an empty name would fold into one
  while IFS=$'\037' read -r t tn m task ts who kind with; do
    [[ -n "$m" && "$ts" =~ ^[0-9]+$ ]] || continue
    if spl_test_workspace "$t" || { [[ -n "$tn" ]] && spl_test_workspace "$tn"; }; then
      echo "$t" >>"$test"; ntest=$((ntest + 1)); continue
    fi
    key="$t|$m"; n=$((n + 1)); echo "$key" >>"$out/state.new"
    tag=seen; grep -qxF -- "$key" "$state" 2>/dev/null || { tag=NEW; nnew=$((nnew + 1)); }
    printf -v line '| %s | %s | %s | %s | %s | %s | %s | %s |' "$tag" "$t" "$m" "$task" \
      "$(date -u -d "@$ts" +%Y-%m-%dT%H:%MZ)" "$who" "$kind" "${with:-?}"
    echo "$line" >>"$live"
    [[ "$tag" == NEW ]] && echo "$line" >>"$new"
  done < <(tr '\t' '\037' <"$rows")
  stamp="$(date -u +%Y-%m-%dT%H:%MZ)"
  local hdr="| | workspace | msg | topic | posted | from | kind | in topic |"$'\n'"|---|---|---|---|---|---|---|---|"
  { echo "## Messages only their writer can read: $ENV $stamp"
    echo
    echo "From a person, to ALL-0, no channel, last ${UNREADABLE_DAYS:-30} d: the read door shows such a row to its writer alone (spec 117 1.3). Ids, times and seats only. In topic: 'people' = no agent posted in the topic, 'agent' = one did."
    echo; echo "$hdr"
    if [[ -s "$live" ]]; then cat "$live"; else echo "| - | (none) | | | | | | |"; fi
    echo; echo "### Test workspaces (counted, never alerted)"; echo
    echo "| workspace | rows |"; echo "|---|---|"
    if [[ -s "$test" ]]; then sort "$test" | uniq -c | awk '{ print "| " $2 " | " $1 " |" }'; else echo "| (none) | 0 |"; fi
    echo; echo "SUM rows=$n new=$nnew test=$ntest people=$(grep -c ' people |$' "$live") agent=$(grep -c ' agent |$' "$live")"
  } >"$out/report.md"
  (( nnew )) || return 0
  { echo "**Messages only their writer can read** ($ENV, $stamp): $nnew new row(s), $n in all (test workspaces left out: $ntest)."
    echo
    echo "Each row below is from a person, to ALL-0, with no channel: its writer saw it sent, nobody else can read it (spec 117 1.3). Ids, times and seats only. Re-addressing one is a prd write (do_spl_msg_readdress) and needs the owner's go."
    echo; echo "$hdr"; head -n "$max" "$new"
    (( nnew > max )) && printf '\n... and %d more (the full list: ENV=%s ./run -a do_spl_msg_unreadable)\n' $((nnew - max)) "$ENV"
  } >"$out/note.md"
  return 0
}

# spl_unreadable_rows <out>: the rows, one TSV line each (tenant, workspace
# name, msg_id, task_id, epoch, from_id, root|reply, people|agent), from
# UNREADABLE_ROWS_FILE or the hub.
spl_unreadable_rows() {
  if [[ -n "${UNREADABLE_ROWS_FILE:-}" ]]; then
    cp "$UNREADABLE_ROWS_FILE" "$1" || { do_log "FATAL cannot read UNREADABLE_ROWS_FILE $UNREADABLE_ROWS_FILE"; return 1; }
    return 0
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_unreadable_rows_read "$1" || { do_log "FATAL could not read the messages of $ENV"; return 1; }
}

# Read-only, inside spl_via_proxy. No body column is selected.
_spl_unreadable_rows_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v days="${UNREADABLE_DAYS:-30}" > "$1" <<SQL
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
$(_spl_unreadable_rows_sql);
COMMIT;
SQL
}

# The one statement (psql variable :days). The last column says whether an
# agent posted in the topic (as the sweep's cstate thread): 'people' is the
# person-to-person shape of spec 117, 'agent' a reply under an agent's post
# that the hub did not re-address (before 604f9fa22, or no announced agent).
_spl_unreadable_rows_sql() {
  cat <<'SQL'
SELECT m.tenant_id, coalesce(t.display_name, ''), m.msg_id, m.task_id,
       extract(epoch FROM m.received_at)::bigint, m.from_id,
       CASE WHEN m.is_parent = 1 THEN 'root' ELSE 'reply' END,
       CASE WHEN EXISTS (SELECT 1 FROM messages g
                          WHERE g.tenant_id = m.tenant_id AND g.task_id = m.task_id AND g.typed_by IS NULL
                            AND g.from_id NOT LIKE 'HUM-%' AND g.from_id NOT LIKE 'GST-%')
            THEN 'agent' ELSE 'people' END
  FROM messages m
  JOIN tenants t ON t.tenant_id = m.tenant_id
 WHERE m.channel IS NULL AND m.to_id = 'ALL-0'
   AND (m.from_id LIKE 'HUM-%' OR m.from_id LIKE 'GST-%')
   AND m.expires_at > now() AND m.received_at > now() - make_interval(days => :days)
 ORDER BY 1, 5, 3
SQL
}
