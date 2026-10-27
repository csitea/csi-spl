#!/bin/bash
#------------------------------------------------------------------------------
# @description Rewrite a workspace's own old-prefix issue keys (csitea SPL-n ->
# @description CSI-n, owner HUM-10, csitea topic 26a21b5a, msg 642a2179;
# @description SPL-3821, after the read-only scan of SPL-3570) through the
# @description hub's own edit paths, never SQL. Reads the plan that
# @description do_spl_issue_ref_scan wrote (SCAN_PLAN: ids + offsets), reads
# @description each field's CURRENT text in a READ ONLY transaction, re-checks
# @description every key at its offset (src/bash/scripts/issue-ref-rewrite.py)
# @description and prints before/after per key and the count per route:
# @description   edit      a message this desk box sent: do_spl_desk_edit as its
# @description             author (the hub keeps the old body as a revision)
# @description   issue     an issue title/description: do_spl_issue_update as
# @description             ISSUE_AGENT, only when ISSUE_AGENT is set
# @description   other-box another live desk box sent it: run this there
# @description   human     typed in the WUI: its author, the owner or an admin
# @description             edits it there; no agent can
# @description   no-pin    its box's pin is revoked: nobody can re-sign it
# @description   done / stale / gone   skipped (already new, changed, deleted)
# @description Only the plan's keys change; the ambiguous and t1 keys were never
# @description in it. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug (e.g. csitea)
# @param SCAN_PLAN - required: the plan file do_spl_issue_ref_scan wrote
# @param DESK_BOX (optional) - this host's desk box, default spl_desk_box_default
# @param ISSUE_AGENT (optional) - the seated desk agent that edits the issues
# @param   (e.g. c-002); unset = issue fields are listed, not edited
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=csitea SCAN_PLAN=/var/tmp/csitea-refs.json ./run -a do_spl_issue_ref_rewrite
# @example ENV=prd TENANT_ID=csitea SCAN_PLAN=/var/tmp/csitea-refs.json ISSUE_AGENT=c-002 DRY_RUN=0 ./run -a do_spl_issue_ref_rewrite
#------------------------------------------------------------------------------
do_spl_issue_ref_rewrite() {
  spl_issue_ref_rewrite_args || return 1
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local dir rc=0
  dir="$(mktemp -d)" || return 1
  spl_via_proxy _spl_issue_ref_rewrite_rows "$dir/rows.jsonl" || rc=$?
  if [[ $rc == 0 ]]; then
    python3 "$PROJ_PATH/src/bash/scripts/issue-ref-rewrite.py" --plan "$SCAN_PLAN" \
      --box "$DESK_BOX" --out "$dir" <"$dir/rows.jsonl" || rc=$?
    [[ $rc == 0 ]] || do_log "FATAL the planner refused $SCAN_PLAN (exit $rc)"
  fi
  if [[ $rc == 0 ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
      do_log "OK DRY_RUN nothing was edited in $TENANT_ID; re-run with DRY_RUN=0 to apply the edit${ISSUE_AGENT:+ and issue} routes"
    else
      spl_issue_ref_rewrite_apply "$dir/work.tsv" || rc=$?
    fi
  fi
  rm -rf "$dir"
  return $rc
}

# spl_issue_ref_rewrite_args -> checks every input before any cloud call; the
# plan's ids are matched against strict patterns before they reach the SQL.
spl_issue_ref_rewrite_args() {
  DRY_RUN="${DRY_RUN:-1}"
  [[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$DRY_RUN'"; return 1; }
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '${TENANT_ID:-}'"; return 1; }
  [[ -f "${SCAN_PLAN:-}" && -r "$SCAN_PLAN" ]] || { do_log "FATAL SCAN_PLAN must be the readable plan of do_spl_issue_ref_scan, got: '${SCAN_PLAN:-}'"; return 1; }
  DESK_BOX="${DESK_BOX:-$(spl_desk_box_default)}"
  [[ "$DESK_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL DESK_BOX must be a box id, got: '$DESK_BOX'"; return 1; }
  [[ -z "${ISSUE_AGENT:-}" || "$ISSUE_AGENT" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$ ]] || { do_log "FATAL ISSUE_AGENT must be an agent id, got: '$ISSUE_AGENT'"; return 1; }
  python3 - "$SCAN_PLAN" "$TENANT_ID" <<'EOF_PY' || { do_log "FATAL $SCAN_PLAN is not a $TENANT_ID plan of msg uuids and issue numbers"; return 1; }
import json, re, sys
p = json.load(open(sys.argv[1]))
assert p["tenant"] == sys.argv[2] and p["fields"]
for f in p["fields"]:
    if f["src"] == "msg":
        assert f["field"] == "body" and re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", f["id"])
    else:
        assert f["src"] == "issue" and f["field"] in ("title", "description") and re.fullmatch(r"[1-9][0-9]{0,8}", str(f["id"]))
EOF_PY
}

# _spl_issue_ref_rewrite_rows <file> -> the planner's JSON lines into <file>.
_spl_issue_ref_rewrite_rows() {
  local out
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -c 'BEGIN TRANSACTION READ ONLY' \
      -c "SET LOCAL app.rls_scope = 'operator'" \
      -c "$(spl_issue_ref_rewrite_sql "$TENANT_ID" "$SCAN_PLAN")" -c 'ROLLBACK' </dev/null 2>&1)" \
    || { do_log "FATAL the read-only read of $TENANT_ID in $ENV failed: $out"; return 1; }
  printf '%s\n' "$out" >"$1"
}

# spl_issue_ref_rewrite_sql <tenant> <plan> -> the one SELECT: the prefix, the
# live pins, and the current text of every plan field (ids checked by _args).
spl_issue_ref_rewrite_sql() {
  local t="$1" msgs nums
  msgs="$(python3 -c 'import json,sys; print(",".join("'"'"'%s'"'"'" % f["id"] for f in json.load(open(sys.argv[1]))["fields"] if f["src"] == "msg") or "NULL")' "$2")"
  nums="$(python3 -c 'import json,sys; print(",".join(str(f["id"]) for f in json.load(open(sys.argv[1]))["fields"] if f["src"] == "issue") or "NULL")' "$2")"
  cat <<EOF_SQL
SELECT json_build_object('src', 'meta', 'tenant', '$t',
  'prefix', (SELECT prefix FROM issue_counters WHERE tenant_id = '$t'),
  'pins', (SELECT coalesce(json_agg(box_id ORDER BY box_id), '[]'::json) FROM pins WHERE tenant_id = '$t' AND revoked_at IS NULL))
UNION ALL SELECT json_build_object('src', 'msg', 'id', msg_id, 'field', 'body', 'text', body, 'box', from_box, 'from', from_id)
  FROM messages WHERE tenant_id = '$t' AND msg_id IN ($msgs)
UNION ALL SELECT json_build_object('src', 'issue', 'id', number, 'field', 'title', 'text', title)
  FROM issues WHERE tenant_id = '$t' AND number IN ($nums)
UNION ALL SELECT json_build_object('src', 'issue', 'id', number, 'field', 'description', 'text', description)
  FROM issues WHERE tenant_id = '$t' AND number IN ($nums)
EOF_SQL
}

# spl_issue_ref_rewrite_apply <work.tsv> -> each edit/issue line through the
# hub's own path; one failure does not stop the rest, the count says it.
spl_issue_ref_rewrite_apply() {
  local route _src id field from box file ok=0 bad=0 skip=0 prefix
  prefix="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["new"])' "$SCAN_PLAN")"
  while IFS=$'\t' read -r route _src id field from box file; do
    if [[ "$route" == edit ]]; then
      if (DESK_AGENT="$from" DESK_BOX="$box" MSG_ID="$id" DESK_BODY_FILE="$file" DRY_RUN=0 do_spl_desk_edit); then
        ok=$((ok + 1)); else bad=$((bad + 1)); do_log "WARN edit of msg $id by $from on $box failed"; fi
    elif [[ -z "${ISSUE_AGENT:-}" ]]; then
      skip=$((skip + 1)); do_log "INFO issue $prefix-$id $field left: set ISSUE_AGENT to edit it"
    elif _spl_issue_ref_rewrite_issue "$prefix-$id" "$field" "$file"; then
      ok=$((ok + 1)); else bad=$((bad + 1)); do_log "WARN update of issue $prefix-$id $field failed"; fi
  done <"$1"
  do_log "$([[ $bad == 0 ]] && echo OK || echo FATAL) rewrote $ok field(s) in $TENANT_ID, $bad failed, $skip issue field(s) left (no ISSUE_AGENT)"
  [[ $bad == 0 ]]
}

# _spl_issue_ref_rewrite_issue <key> <title|description> <file>
_spl_issue_ref_rewrite_issue() {
  if [[ "$2" == title ]]; then
    (DESK_AGENT="$ISSUE_AGENT" ISSUE_REF="$1" ISSUE_TITLE="$(cat "$3")" DRY_RUN=0 do_spl_issue_update)
  else
    (DESK_AGENT="$ISSUE_AGENT" ISSUE_REF="$1" ISSUE_DESCRIPTION_FILE="$3" DRY_RUN=0 do_spl_issue_update)
  fi
}
