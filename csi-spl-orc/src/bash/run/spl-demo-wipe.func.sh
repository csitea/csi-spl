#!/bin/bash
#------------------------------------------------------------------------------
# @description The nightly wipe of the demo workspace (spec 077 T017, §3.6):
# @description deletes every message and topic of the workspace cnf
# @description env.demo.workspace names (a topic is its messages' task_id, so
# @description the messages take it with them; their deliveries, reactions,
# @description revisions, answers and flow events cascade), its read marks and
# @description topic watches, then re-seeds its default channels (the hub's
# @description store.DefaultChannels, as rdb 0008/0046 seed a new tenant) and
# @description the pinned welcome. Scheduled by .github/workflows/46_demo-wipe.yml.
# @description GUARDS, each refuses before a row is touched:
# @description   1 cnf: the workspace is env.demo.workspace; DEMO_WIPE_WORKSPACE
# @description     naming any other id is refused. env.demo.enabled not true
# @description     skips (exit 0, nothing read).
# @description   2 DB, inside the wipe's own transaction: the workspace exists
# @description     and has no member whose role is outside demo_user / admin /
# @description     biz_owner (a real workspace has developers); else it aborts.
# @description The SQL runs in TENANT RLS scope (app.tenant_id = the demo id),
# @description so even a wrong WHERE cannot reach another workspace's rows.
# @description PINNED WELCOME: 077 T019 (greeting seed) is not built. The hook
# @description is spl_demo_wipe_welcome: it runs do_spl_demo_greeting_seed when
# @description that action exists, and says it is missing otherwise.
# @description Prints one JSON line on stdout: workspace, env, dry_run, counts.
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default): count in a READ ONLY transaction, delete nothing
# @param DEMO_WIPE_WORKSPACE (optional) - must equal cnf env.demo.workspace
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (do_gcp_account)
# @example ENV=dev ./run -a do_spl_demo_wipe
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_demo_wipe
#------------------------------------------------------------------------------
do_spl_demo_wipe() {
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" ws on out rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  ws="$(spl_demo_wipe_workspace "$SPL_CNF")" || return 1
  on="$(yq -r '.env.demo.enabled // false' "$SPL_CNF")"
  if [[ "$on" != true ]]; then
    do_log "INFO the demo is off in $ENV (cnf env.demo.enabled=$on): nothing to wipe"
    printf '{"workspace":"%s","env":"%s","skipped":"demo_disabled"}\n' "$ws" "$ENV"
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  out="$(mktemp)" || return 1
  DEMO_WS="$ws" DEMO_DRY="$dry" spl_via_proxy _spl_demo_wipe_run "$out" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL the wipe of $ws in $ENV failed, nothing was committed: $(tr '\n' ' ' <"$out")"
    rm -f "$out"; return 1
  fi
  printf '{"workspace":"%s","env":"%s","dry_run":%s,%s}\n' "$ws" "$ENV" \
    "$([[ "$dry" == 1 ]] && echo true || echo false)" "$(tail -n 1 "$out")"
  rm -f "$out"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN counted the wipe of $ws in $ENV, deleted nothing. Re-run with DRY_RUN=0."
    return 0
  fi
  do_log "OK wiped the messages and topics of $ws in $ENV and re-seeded its channels"
  spl_demo_wipe_welcome "$ws"
}

# spl_demo_wipe_workspace <cnf> -> the demo workspace id on stdout. Guard 1:
# the id is cnf env.demo.workspace, a slug; any other id is refused.
spl_demo_wipe_workspace() {
  local ws want="${DEMO_WIPE_WORKSPACE:-}"
  ws="$(yq -r '.env.demo.workspace // ""' "$1")"
  [[ "$ws" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL cnf env.demo.workspace is not a workspace slug: '$ws'"; return 1; }
  if [[ -n "$want" && "$want" != "$ws" ]]; then
    do_log "FATAL $want is not the demo workspace of $ENV (cnf env.demo.workspace=$ws): refused, nothing touched"
    return 1
  fi
  echo "$ws"
}

# spl_demo_wipe_welcome <ws> - the pinned welcome topic in #lobby. It is 077
# T019's (greeting seed, §3.9): once do_spl_demo_greeting_seed exists it runs
# here, after every committed wipe.
spl_demo_wipe_welcome() {
  if declare -F do_spl_demo_greeting_seed >/dev/null; then
    DEMO_WS="$1" do_spl_demo_greeting_seed
    return
  fi
  do_log "INFO no pinned welcome re-seeded: do_spl_demo_greeting_seed (077 T019) is not built yet"
}

# the hub's default channels (store.DefaultChannels), as a postgres array;
# demo-wipe.tst.sh fails when the two drift apart
SPL_DEMO_WIPE_CHANNELS='{lobby,alerts,feedback}'

# _spl_demo_wipe_run <out> - the wipe (DEMO_DRY=0) or its counts (DEMO_DRY=1),
# one transaction through $SPL_PROXY_DSN; the last line of <out> is the counts
# as JSON members. Guard 2 aborts the transaction before any DELETE.
_spl_demo_wipe_run() {
  local body
  if [[ "$DEMO_DRY" == 1 ]]; then body="$(_spl_demo_wipe_sql_count)"; else body="$(_spl_demo_wipe_sql_delete)"; fi
  { _spl_demo_wipe_sql_guard; echo "$body"; echo 'COMMIT;'; } |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v ws="$DEMO_WS" \
      -v seed="$SPL_DEMO_WIPE_CHANNELS" >"$1" 2>&1
}

_spl_demo_wipe_sql_guard() {
  if [[ "$DEMO_DRY" == 1 ]]; then echo 'BEGIN READ ONLY;'; else echo 'BEGIN;'; fi
  cat <<'SQL'
SET LOCAL app.tenant_id = :'ws';
DO $$
DECLARE
    ws  text := current_setting('app.tenant_id');
    bad text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = ws) THEN
        RAISE EXCEPTION 'demo wipe: workspace % does not exist', ws;
    END IF;
    SELECT string_agg(DISTINCT role, ',') INTO bad FROM tenant_memberships
     WHERE tenant_id = ws AND role NOT IN ('demo_user', 'admin', 'biz_owner');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'demo wipe: workspace % has members with role(s) %: not a demo workspace, refused', ws, bad;
    END IF;
END $$;
SQL
}

_spl_demo_wipe_sql_count() {
  cat <<'SQL'
SELECT format('"messages":%s,"topics":%s,"read_marks":%s,"flow_watches":%s,"channels_reseeded":%s',
  (SELECT count(*) FROM messages WHERE tenant_id = :'ws'),
  (SELECT count(DISTINCT task_id) FROM messages WHERE tenant_id = :'ws'),
  (SELECT count(*) FROM read_marks WHERE tenant_id = :'ws'),
  (SELECT count(*) FROM flow_watches WHERE tenant_id = :'ws'),
  (SELECT count(*) FROM unnest(:'seed'::text[]) AS d (c)
    WHERE NOT EXISTS (SELECT 1 FROM channels WHERE tenant_id = :'ws' AND channel_id = d.c)));
SQL
}

_spl_demo_wipe_sql_delete() {
  cat <<'SQL'
WITH m AS (DELETE FROM messages WHERE tenant_id = :'ws' RETURNING task_id),
     r AS (DELETE FROM read_marks WHERE tenant_id = :'ws' RETURNING 1),
     w AS (DELETE FROM flow_watches WHERE tenant_id = :'ws' RETURNING 1),
     c AS (INSERT INTO channels (tenant_id, channel_id, name, created_by, members_open_invite)
           SELECT :'ws', d, d, 'hub', false FROM unnest(:'seed'::text[]) AS d
           ON CONFLICT (tenant_id, channel_id) DO NOTHING RETURNING 1)
SELECT format('"messages":%s,"topics":%s,"read_marks":%s,"flow_watches":%s,"channels_reseeded":%s',
  (SELECT count(*) FROM m), (SELECT count(DISTINCT task_id) FROM m),
  (SELECT count(*) FROM r), (SELECT count(*) FROM w), (SELECT count(*) FROM c));
SQL
}
