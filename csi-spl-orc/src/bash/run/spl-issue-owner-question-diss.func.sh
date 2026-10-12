#!/bin/bash
#------------------------------------------------------------------------------
# @description Move the owner's questions that the escalation path filed as
# @description issues to diss, once (owner HUM-10, t1 5ea2e615, msg db5ed497:
# @description "An owner question should not become an issue until the owner
# @description decides that"). A candidate is an open issue (not done / diss,
# @description not deleted or archived) labelled blocker, assigned to
# @description OWNER_ID, created on ISSUE_CREATED_DAY (UTC), its number in
# @description ISSUE_NUM_FROM..ISSUE_NUM_TO. It is KEPT when the owner touched
# @description it: a history event by OWNER_ID other than its creation (a
# @description change, a reopen), or a comment from OWNER_ID on its topic; and
# @description SKIPPED when ISSUE_SKIP_KEYS_FILE names it (another mover owns
# @description it: one move per issue). Read-only from the hub Postgres as the
# @description env's project SA (do_spl_db_message_show's path), then the
# @description moves through the desk. DRY_RUN=1 (the default) prints the plan,
# @description one TSV line per candidate: key, status, verdict, why, title.
# @description DRY_RUN=0 re-reads each MOVE item first (skips one that is
# @description already done or diss), comments the reason, sets diss, never
# @description deletes, and writes a 0600 undo file, one command per item.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (e.g. t1)
# @param DESK_AGENT - required: the agent the desk writes as
# @param OWNER_ID - required: the owner's member id (the assignee)
# @param ISSUE_CREATED_DAY - required: YYYY-MM-DD, the UTC day the escalation filed them
# @param ISSUE_NUM_FROM - required: the first issue number
# @param ISSUE_NUM_TO - required: the last issue number
# @param ISSUE_SKIP_KEYS_FILE (optional) - keys another mover owns, one a line
# @param ISSUE_REASON (optional) - the comment, default the owner's rule
# @param ISSUE_PLAN (optional) - default $SPL_STATE_DIR/issue-owner-question/<tenant>-<utc>.plan.tsv
# @param ISSUE_UNDO (optional) - default the plan path, .undo.sh
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 OWNER_ID=HUM-10 ISSUE_CREATED_DAY=2026-10-11 ISSUE_NUM_FROM=1351 ISSUE_NUM_TO=1471 ./run -a do_spl_issue_owner_question_diss
#------------------------------------------------------------------------------
do_spl_issue_owner_question_diss() {
  local dry=1 plan rows rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_issue_oq_check || return 1
  plan="$(spl_issue_oq_plan_path)" || return 1
  rows="$(mktemp)"
  if spl_issue_oq_read >"$rows" && spl_issue_oq_verdicts <"$rows" >"$plan"; then
    do_log "INFO $(grep -c . "$plan" || true) candidates: $(cut -f3 "$plan" | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
    if (( dry )); then
      cat "$plan"
      do_log "OK DRY_RUN nothing was moved. PLAN $plan"
    else
      spl_issue_oq_apply "$plan" || rc=1
    fi
  else
    rc=1
  fi
  rm -f "$rows"
  return $rc
}

# spl_issue_oq_check: every knob's shape before any read; the values it
# checks are the only literals the SQL interpolates.
spl_issue_oq_check() {
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '${TENANT_ID:-}'"; return 1; }
  [[ "${OWNER_ID:-}" =~ ^[A-Z]{2,4}-[0-9]+$ ]] || { do_log "FATAL OWNER_ID must be a member id like HUM-1, got: '${OWNER_ID:-}'"; return 1; }
  [[ "${ISSUE_CREATED_DAY:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
    { do_log "FATAL ISSUE_CREATED_DAY must be YYYY-MM-DD, got: '${ISSUE_CREATED_DAY:-}'"; return 1; }
  if ! [[ "${ISSUE_NUM_FROM:-}" =~ ^[1-9][0-9]*$ && "${ISSUE_NUM_TO:-}" =~ ^[1-9][0-9]*$ ]] || (( ISSUE_NUM_FROM > ISSUE_NUM_TO )); then
    do_log "FATAL ISSUE_NUM_FROM..ISSUE_NUM_TO must be numbers, from <= to, got: '${ISSUE_NUM_FROM:-}..${ISSUE_NUM_TO:-}'"
    return 1
  fi
  [[ -z "${ISSUE_SKIP_KEYS_FILE:-}" || -r "$ISSUE_SKIP_KEYS_FILE" ]] ||
    { do_log "FATAL ISSUE_SKIP_KEYS_FILE is not a readable file: '$ISSUE_SKIP_KEYS_FILE'"; return 1; }
  [[ -n "${DESK_AGENT:-}" ]] || { do_log "FATAL DESK_AGENT must be set (the agent the desk writes as)"; return 1; }
}

# spl_issue_oq_plan_path -> ISSUE_PLAN, or a fresh name in a 0700 state dir.
# The plan holds titles (workspace data): 0600, never in git.
spl_issue_oq_plan_path() {
  local p="${ISSUE_PLAN:-${SPL_STATE_DIR}/issue-owner-question/${TENANT_ID}-$(date -u +%Y%m%dT%H%M%SZ).plan.tsv}"
  mkdir -p "$(dirname "$p")" || return 1
  [[ -n "${ISSUE_PLAN:-}" ]] || chmod 700 "$(dirname "$p")"
  (umask 077; : >"$p") || return 1
  printf '%s\n' "$p"
}

# spl_issue_oq_read -> one TSV row per candidate from the hub Postgres:
# key, status, owner events, owner comments, title. Read-only, as the SA.
spl_issue_oq_read() {
  local provider
  provider="$(do_spl_cloud_provider)" || return 1
  spl_db_require_bins "$provider" || return 1
  do_spl_cloud_cnf || return 1
  spl_db_query_rc "$provider" _spl_issue_oq_query
}

# _spl_issue_oq_query: the read, once $dsn is the local login. Stops the proxy.
# shellcheck disable=SC2154 # dsn: bound by spl_db_query_rc, via dynamic scope
_spl_issue_oq_query() {
  local out qrc
  out="$(spl_psql_ro "$dsn" "$(spl_issue_oq_sql)")"
  qrc=$?
  spl_sql_proxy_stop
  [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; return 1; }
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# spl_issue_oq_sql -> the candidates with the owner's touches counted. Every
# literal is checked by spl_issue_oq_check first.
spl_issue_oq_sql() {
  cat <<EOF_SQL
SELECT concat_ws(E'\t', c.prefix || '-' || i.number, i.status,
  (SELECT count(*) FROM issue_events e WHERE e.tenant_id = i.tenant_id AND e.number = i.number
     AND e.actor = '$OWNER_ID' AND e.event <> 'created'),
  (SELECT count(*) FROM messages m WHERE m.tenant_id = i.tenant_id AND m.task_id = i.task_id
     AND m.from_id = '$OWNER_ID'),
  replace(replace(i.title, E'\t', ' '), E'\n', ' '))
FROM issues i JOIN issue_counters c ON c.tenant_id = i.tenant_id
WHERE i.tenant_id = '$TENANT_ID' AND i.assignee = '$OWNER_ID' AND 'blocker' = ANY (i.labels)
  AND i.status NOT IN ('done', 'diss') AND i.deleted_at IS NULL AND i.archived_at IS NULL
  AND i.number BETWEEN $ISSUE_NUM_FROM AND $ISSUE_NUM_TO
  AND (i.created_at AT TIME ZONE 'UTC')::date = DATE '$ISSUE_CREATED_DAY'
ORDER BY i.number;
EOF_SQL
}

# spl_issue_oq_verdicts: the read rows on stdin -> the plan (key, status,
# verdict, why, title). MOVE, KEEP (the owner touched it) or SKIP (another
# mover's key).
spl_issue_oq_verdicts() {
  awk -F'\t' -v OFS='\t' -v skipf="${ISSUE_SKIP_KEYS_FILE:-}" '
    BEGIN { if (skipf != "") while ((getline l < skipf) > 0) { split(l, w, /[ \t]/); if (w[1] != "") skip[w[1]] = 1 } }
    NF >= 5 {
      if ($1 in skip) print $1, $2, "SKIP", "another mover owns it", $5
      else if ($3 > 0 || $4 > 0) print $1, $2, "KEEP", "the owner changed it " $3 "x, commented " $4 "x", $5
      else print $1, $2, "MOVE", "owner question, not an issue", $5
    }'
}

# spl_issue_oq_apply PLAN: per MOVE item, re-read it, comment, then diss; the
# undo file grows a line as each item changes.
spl_issue_oq_apply() {
  local plan="$1" undo="${ISSUE_UNDO:-${1%.tsv}.undo.sh}" key status verdict n=0 gone=0 fail=0 now
  local why="${ISSUE_REASON:-owner question, not an issue (owner db5ed497): it becomes an issue only when the owner decides that. Nothing was deleted; setting the old status back undoes it.}"
  (umask 077; printf '#!/bin/bash\n# undo do_spl_issue_owner_question_diss (%s): each item back to its old status\n' "$plan" >"$undo") || return 1
  spl_desk_issue_once || return 1
  while IFS=$'\t' read -r key status verdict _; do
    [[ "$verdict" == MOVE ]] || continue
    now="$(spl_desk_issue_run get --ref "$key" 2>&1 | python3 -c 'import json,sys
d = json.loads(sys.stdin.read() or "{}").get("result") or {}
print((d.get("issue") or d).get("status", ""))' 2>/dev/null)"
    if [[ "$now" == "done" || "$now" == "diss" ]]; then
      do_log "INFO $key is $now already: left alone (one move per issue)"
      gone=$((gone + 1)); continue
    fi
    if spl_issue_oq_one "$key" "$why"; then
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

# spl_issue_oq_one KEY WHY: the reason comment, then status diss.
spl_issue_oq_one() {
  local key="$1" why="$2" out
  out="$(spl_desk_issue_run comment --ref "$key" --body "$why" 2>&1)" || { do_log "FATAL comment $key: $out"; return 1; }
  out="$(spl_desk_issue_run update --ref "$key" --status diss 2>&1)" || { do_log "FATAL diss $key: $out"; return 1; }
}
