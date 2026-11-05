#!/bin/bash
#------------------------------------------------------------------------------
# @description Close the never-answered "from_agent: <id>@<box>" blocker
# @description issues as diss, once (RCA SPL-4850, csi-spl-doc/specs/
# @description 157-dispatch-automation/rca-blocker-issues-from-agent.md
# @description section 3 B1; owner HUM-10, t1 8c64225e, msg 70d39d81, answer
# @description 2 = A). A candidate is an issue (not deleted or archived) whose
# @description parent is ISSUE_EPIC_NUM, status todo and title LIKE
# @description 'from_agent:%', plus each number of ISSUE_EXTRA_NUMS. No other
# @description issue is read. Read-only from the hub Postgres as the env's
# @description project SA (do_spl_db_message_show's path), then the moves
# @description through the desk. DRY_RUN=1 (the default) prints the plan, one
# @description TSV line per candidate: key, status, verdict, why, title. MOVE
# @description = an open issue; SKIP = one closed (done or diss) already.
# @description DRY_RUN=0 needs ISSUE_OWNER_GO, re-reads each MOVE item first
# @description (skips one whose status is no longer the plan's, or that it
# @description cannot read), comments the reason, sets diss,
# @description never deletes, and writes a 0600 undo file, one command per
# @description item. A re-run finds no open item left and changes nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (e.g. t1)
# @param DESK_AGENT - required: the agent the desk writes as
# @param ISSUE_EPIC_NUM (optional) - the blocker epic's number, default 2394 (SPL-2394)
# @param ISSUE_EXTRA_NUMS (optional) - more issue numbers, comma separated, default 1555; '' for none. Each one is a candidate in ANY open status: review the plan before DRY_RUN=0
# @param ISSUE_OWNER_GO - required with DRY_RUN=0: the owner's go message uuid, cited in each comment
# @param ISSUE_REASON (optional) - the comment, default the RCA's; the owner go is appended to it either way
# @param ISSUE_PLAN (optional) - default $SPL_STATE_DIR/issue-blocker-rca/<tenant>-<utc>.plan.tsv
# @param SPL_STATE_DIR (optional) - set by do_spl_cloud_cnf from ENV; the plan's default dir
# @param DESK_BOX (optional) - the desk box spl_desk_issue_run writes through
# @param ISSUE_UNDO (optional) - default the plan path, .undo.sh
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-996 ./run -a do_spl_issue_blocker_rca_close
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-996 ISSUE_OWNER_GO=<owner msg uuid> DRY_RUN=0 ./run -a do_spl_issue_blocker_rca_close
#------------------------------------------------------------------------------
do_spl_issue_blocker_rca_close() {
  local dry=1 plan rows rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_issue_brc_check "$dry" || return 1
  do_spl_cloud_cnf || return 1
  plan="$(spl_issue_brc_plan_path)" || return 1
  rows="$(mktemp)"
  if spl_issue_brc_read >"$rows" && spl_issue_brc_verdicts <"$rows" >"$plan"; then
    do_log "INFO $(grep -c . "$plan" || true) candidates: $(cut -f3 "$plan" | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
    if (( dry )); then
      cat "$plan"
      do_log "OK DRY_RUN nothing was moved. PLAN $plan"
    else
      spl_issue_brc_apply "$plan" || rc=1
    fi
  else
    rc=1
  fi
  rm -f "$rows"
  return $rc
}

# spl_issue_brc_check DRY: every knob's shape before any read; the values it
# checks are the only literals the SQL interpolates.
spl_issue_brc_check() {
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '${TENANT_ID:-}'"; return 1; }
  [[ "${ISSUE_EPIC_NUM:-2394}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL ISSUE_EPIC_NUM must be a number, got: '${ISSUE_EPIC_NUM:-}'"; return 1; }
  [[ "${ISSUE_EXTRA_NUMS-1555}" =~ ^([1-9][0-9]*(,[1-9][0-9]*)*)?$ ]] ||
    { do_log "FATAL ISSUE_EXTRA_NUMS must be numbers, comma separated, got: '${ISSUE_EXTRA_NUMS:-}'"; return 1; }
  [[ -n "${DESK_AGENT:-}" ]] || { do_log "FATAL DESK_AGENT must be set (the agent the desk writes as)"; return 1; }
  [[ "$1" == 1 || "${ISSUE_OWNER_GO:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL DRY_RUN=0 needs ISSUE_OWNER_GO, the owner's go message uuid (full, lowercase), got: '${ISSUE_OWNER_GO:-}'"; return 1; }
}

# spl_issue_brc_plan_path -> ISSUE_PLAN, or a fresh name in a 0700 state dir.
# The plan holds titles (workspace data): 0600, never in git.
spl_issue_brc_plan_path() {
  local p="${ISSUE_PLAN:-${SPL_STATE_DIR}/issue-blocker-rca/${TENANT_ID}-$(date -u +%Y%m%dT%H%M%SZ).plan.tsv}"
  mkdir -p "$(dirname "$p")" || return 1
  [[ -n "${ISSUE_PLAN:-}" ]] || chmod 700 "$(dirname "$p")"
  (umask 077; : >"$p") && chmod 600 "$p" || return 1
  printf '%s\n' "$p"
}

# spl_issue_brc_read -> one TSV row per candidate from the hub Postgres:
# key, status, title. Read-only, as the SA.
spl_issue_brc_read() {
  local provider
  provider="$(do_spl_cloud_provider)" || return 1
  spl_db_require_bins "$provider" || return 1
  spl_db_query_rc "$provider" _spl_issue_brc_query
}

# _spl_issue_brc_query: the read, once $dsn is the local login. Stops the proxy.
# shellcheck disable=SC2154 # dsn: bound by spl_db_query_rc, via dynamic scope
_spl_issue_brc_query() {
  local out qrc
  out="$(spl_psql_ro "$dsn" "$(spl_issue_brc_sql)")"
  qrc=$?
  spl_sql_proxy_stop
  [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; return 1; }
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# spl_issue_brc_sql -> the open from_agent: children of the epic, plus the
# extra numbers in any status. Every literal is checked by spl_issue_brc_check.
spl_issue_brc_sql() {
  local extra="${ISSUE_EXTRA_NUMS-1555}"
  cat <<EOF_SQL
SELECT concat_ws(E'\t', c.prefix || '-' || i.number, i.status,
  replace(replace(i.title, E'\t', ' '), E'\n', ' '))
FROM issues i JOIN issue_counters c ON c.tenant_id = i.tenant_id
WHERE i.tenant_id = '$TENANT_ID' AND i.deleted_at IS NULL AND i.archived_at IS NULL
  AND ((i.parent_number = ${ISSUE_EPIC_NUM:-2394} AND i.status = 'todo' AND i.title LIKE 'from_agent:%')
    OR i.number IN (${extra:-NULL}))
ORDER BY i.number;
EOF_SQL
}

# spl_issue_brc_verdicts: the read rows on stdin -> the plan (key, status,
# verdict, why, title). MOVE (open) or SKIP (done or diss already).
spl_issue_brc_verdicts() {
  awk -F'\t' -v OFS='\t' '
    NF >= 3 {
      if ($2 == "done" || $2 == "diss") print $1, $2, "SKIP", "closed already", $3
      else print $1, $2, "MOVE", "unanswered from_agent: blocker (RCA SPL-4850)", $3
    }'
}

# spl_issue_brc_apply PLAN: per MOVE item, re-read it, comment, then diss; the
# undo file grows a line as each item changes.
spl_issue_brc_apply() {
  local plan="$1" undo="${ISSUE_UNDO:-${1%.tsv}.undo.sh}" key status verdict n=0 gone=0 fail=0 now
  local why="${ISSUE_REASON:-Closed as diss by the RCA of the never-closed from_agent: blocker issues (SPL-4850, csi-spl-doc/specs/157-dispatch-automation/rca-blocker-issues-from-agent.md, section 3 B1): an automated cross-box alarm or an old blocker that got no answer in its topic. Nothing was deleted; setting the old status back undoes it.} (owner go $ISSUE_OWNER_GO)"
  (umask 077; printf '#!/bin/bash\n# undo do_spl_issue_blocker_rca_close (%s): each item back to its old status\n' "$plan" >"$undo") && chmod 600 "$undo" || return 1
  spl_desk_issue_once || return 1
  while IFS=$'\t' read -r key status verdict _; do
    [[ "$verdict" == MOVE ]] || continue
    now="$(spl_desk_issue_run get --ref "$key" 2>/dev/null | python3 -c 'import json,sys
d = json.loads(sys.stdin.read() or "{}").get("result") or {}
print((d.get("issue") or d).get("status", ""))' 2>/dev/null)" || now=""
    if [[ "$now" != "$status" ]]; then
      do_log "INFO $key is '${now:-unreadable}' now, the plan read '$status': left alone"
      gone=$((gone + 1)); continue
    fi
    if spl_issue_brc_one "$key" "$why"; then
      printf 'cd %q && ENV=%q TENANT_ID=%q DESK_AGENT=%q ISSUE_REF=%q ISSUE_STATUS=%q DRY_RUN=0 ./run -a do_spl_issue_update\n' \
        "$PROJ_PATH" "$ENV" "$TENANT_ID" "$DESK_AGENT" "$key" "$status" >>"$undo"
      n=$((n + 1))
    else
      fail=$((fail + 1))
    fi
  done <"$plan"
  do_log "UNDO $undo"
  (( fail == 0 )) || { do_log "FATAL moved $n, $fail failed (above)"; return 1; }
  do_log "OK moved $n items to diss, $gone already closed by someone else"
}

# spl_issue_brc_one KEY WHY: the reason comment, then status diss.
spl_issue_brc_one() {
  local key="$1" why="$2" out
  out="$(spl_desk_issue_run comment --ref "$key" --body "$why" 2>&1)" || { do_log "FATAL comment $key: $out"; return 1; }
  out="$(spl_desk_issue_run update --ref "$key" --status diss 2>&1)" || { do_log "FATAL diss $key: $out"; return 1; }
}
