#!/bin/bash
#------------------------------------------------------------------------------
# @description The 0-seat alarm (spec 158 row B, SPL-3504): a workspace whose
# @description members post while NO agent is seated in it can never be
# @description answered (2026-10-26: member posts from 08:57Z, 0 agent seats,
# @description the sweep's ESC reached c-001 but nobody could act in it). One
# @description read-only operator-scope query lists every workspace that is
# @description not suspended, not archived, not a test one (spl_test_workspace,
# @description the sweep's rule), has at least one HUM-* post in the last
# @description SEAT_ALARM_DAYS days and no roster row of an agent (agent_id not
# @description HUM-* / GST-*, as store.CountBots counts). Those workspaces go
# @description to the orchestrator in ONE spool blocker on task seat-alarm
# @description (spool-send.sh journals a blocker as an ask). A workspace is
# @description alarmed when it is new on the list, and again after
# @description SEAT_ALARM_REALERT seconds while it stays (memory:
# @description <spool root>/dispatch/seat-alarm.state); one that left the list
# @description is forgotten. In fleet mode only the dispatch lease holder's
# @description machine sends, as the sweep does. Dry run unless DRY_RUN=0: the
# @description report and the plan, nothing sent or written. The sweep's cron
# @description script (unanswered-sweep-cron.sh) runs it every minute.
# @param ENV - required: dev or prd
# @param SEAT_ALARM_DAYS (optional) - member posts younger than this count, default 7
# @param SEAT_ALARM_REALERT (optional) - seconds before a workspace still on the list is alarmed again, default 3600
# @param SEAT_ALARM_TO (optional) - who gets the blocker, default LEASE_ORCH (lease.conf), else the orchestrator seat
# @param SEAT_ALARM_FROM (optional) - the sender, default SEAT_ALARM_TO
# @param SEAT_ALARM_ROWS_FILE (optional) - read the rows (tenant, posts, first post epoch; tab separated) from this file, not the hub DB (tests)
# @param SEAT_ALARM_SEND (optional) - the spool sender script (tests)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ./run -a do_spl_workspace_seat_alarm
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_workspace_seat_alarm
#------------------------------------------------------------------------------
declare -F spl_role_seat >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"

do_spl_workspace_seat_alarm() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local v dry="${DRY_RUN:-1}"
  for v in SEAT_ALARM_DAYS SEAT_ALARM_REALERT; do
    [[ -z "${!v:-}" || "${!v}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL $v must be a positive integer, got: '${!v}'"; return 1; }
  done
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_lease_init ro || return 1
  spl_lease_conf
  SAL_TO="${SEAT_ALARM_TO:-${LEASE_ORCH:-$(spl_role_seat 1)}}"
  SAL_FROM="${SEAT_ALARM_FROM:-$SAL_TO}"
  for v in "$SAL_TO" "$SAL_FROM"; do
    [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || { do_log "FATAL '$v' is not an agent id"; return 1; }
  done
  if (( ! dry )) && [[ -z "${SEAT_ALARM_TO:-}" ]] && spl_lease_read && spl_lease_remote; then
    do_log "INFO the fleet's dispatch lease is held by $LH: this machine's seat alarm sends nothing"
    return 0
  fi
  local tmp rc=0
  tmp="$(mktemp -d)" || return 1
  if (( dry )); then
    spl_sal_run "$tmp" 0 || rc=1
  else
    mkdir -p "$LEASE_DIR" || { do_log "FATAL cannot create $LEASE_DIR"; rm -rf "$tmp"; return 1; }
    ( flock -n 9 || { do_log "INFO another seat alarm holds $LEASE_DIR/seat-alarm.lock - skipped"; exit 0; }
      spl_sal_run "$tmp" 1 ) 9> "$LEASE_DIR/seat-alarm.lock" || rc=1
  fi
  rm -rf "$tmp"
  return $rc
}

# spl_sal_run <tmp> <deliver>: read, drop test workspaces, report, alarm.
spl_sal_run() {
  local tmp="$1" deliver="$2" w n first
  spl_sal_rows "$tmp/raw" || return 1
  : >"$tmp/rows"
  while IFS=$'\t' read -r w n first; do
    [[ "$w" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$n" =~ ^[0-9]+$ && "$first" =~ ^[0-9]+$ ]] || continue
    spl_test_workspace "$w" && continue
    printf '%s\t%s\t%s\n' "$w" "$n" "$first" >>"$tmp/rows"
  done <"$tmp/raw"
  echo "## Seat alarm $ENV: $(wc -l <"$tmp/rows") workspace(s) with member posts and 0 agent seats"
  spl_sal_table "$tmp/rows"
  spl_sal_pick "$tmp/rows" "$tmp"
  if (( ! deliver )); then
    [[ -s "$tmp/alert" ]] && echo "PLAN blocker to $SAL_TO: $(cut -f1 "$tmp/alert" | tr '\n' ' ')"
    do_log "OK DRY_RUN nothing was sent or written. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ -s "$tmp/alert" ]]; then
    spl_sal_body "$tmp/alert" >"$tmp/alert.md"
    spl_sal_send "$SAL_TO" "$tmp/alert.md" ||
      { do_log "FATAL the seat alarm to $SAL_TO was not delivered; it repeats on the next run"; return 1; }
  fi
  mv -f "$tmp/state.new" "$LEASE_DIR/seat-alarm.state"
}

# spl_sal_rows <out>: tenant \t member posts \t first post epoch, read-only.
spl_sal_rows() {
  if [[ -n "${SEAT_ALARM_ROWS_FILE:-}" ]]; then
    cp "$SEAT_ALARM_ROWS_FILE" "$1" || { do_log "FATAL cannot read SEAT_ALARM_ROWS_FILE $SEAT_ALARM_ROWS_FILE"; return 1; }
    return 0
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_sal_read "$1" || { do_log "FATAL could not read the workspaces of $ENV"; return 1; }
}

# The one statement: the 0-seat workspaces first (a handful of tenants, not
# every message), then their member posts in the window.
_spl_sal_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v days="${SEAT_ALARM_DAYS:-7}" >/dev/null <<SQL
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
\\o $1
WITH z AS MATERIALIZED (
  SELECT t.tenant_id FROM tenants t
   WHERE t.suspended_at IS NULL AND t.archived_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM roster r WHERE r.tenant_id = t.tenant_id
                        AND r.agent_id NOT LIKE 'HUM-%' AND r.agent_id NOT LIKE 'GST-%'))
SELECT z.tenant_id, count(*), floor(extract(epoch FROM min(m.received_at)))::bigint
  FROM z JOIN messages m ON m.tenant_id = z.tenant_id
 WHERE m.from_id LIKE 'HUM-%' AND m.received_at > now() - make_interval(days => :days)
 GROUP BY z.tenant_id ORDER BY z.tenant_id;
\\o
COMMIT;
SQL
}

# spl_sal_table <rows>: the markdown table, or a line saying none.
spl_sal_table() {
  [[ -s "$1" ]] || { echo; echo "none"; return 0; }
  echo
  echo "| workspace | member posts | first post (UTC) |"
  echo "|---|---|---|"
  while IFS=$'\t' read -r w n first; do
    printf '| %s | %s | %s |\n' "$w" "$n" "$(date -u -d "@$first" +%FT%TZ)"
  done <"$1"
}

# spl_sal_pick <rows> <tmp>: the rows to alarm ($tmp/alert) and the next
# memory ($tmp/state.new: tenant \t last alarm epoch). New on the list, or
# alarmed SEAT_ALARM_REALERT s ago or more.
spl_sal_pick() {
  local state="$LEASE_DIR/seat-alarm.state" now
  now="${SEAT_ALARM_NOW:-$(date +%s)}"
  : >"$2/alert"
  awk -F'\t' -v now="$now" -v re="${SEAT_ALARM_REALERT:-3600}" -v stf="$state" -v out="$2/alert" -v nst="$2/state.new" '
    BEGIN { while ((getline l < stf) > 0) { split(l, a, "\t"); pa[a[1]] = a[2] } }
    { w = $1; at = (w in pa) ? pa[w] : 0
      if (now - at >= re) { print > out; at = now }
      print w "\t" at > nst }
    END { close(nst) }' "$1"
  [[ -e "$2/state.new" ]] || : >"$2/state.new"
}

# spl_sal_body <alert rows>: the blocker text.
spl_sal_body() {
  echo "**Seat alarm $ENV (spec 158 B):** members post in these workspaces and NO agent is seated there, so nobody can answer."
  spl_sal_table "$1"
  echo
  echo "Seat the fleet's desks there (\`do_spl_desk_up\`, needs the workspace root key until spec 158 fleet seating lands); a prd seat change needs the owner's go. Check: \`ENV=$ENV ./run -a do_spl_workspace_seat_alarm\`."
}

# spl_sal_send <to> <body file>: one spool blocker on task seat-alarm.
spl_sal_send() {
  local send="${SEAT_ALARM_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$SAL_FROM" --to "$1" \
    --kind blocker --task seat-alarm --body-file "$2" >/dev/null 2>&1 8>&- 9>&- ||
    { do_log "WARN could not send the seat alarm to $1"; return 1; }
  echo "SENT $1: $(head -1 "$2")"
}
