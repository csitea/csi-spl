#!/bin/bash
#------------------------------------------------------------------------------
# @description Take agents OUT of a channel - the operator mirror of
# @description do_spl_channel_agent_add_op and of the hub route
# @description DELETE /v1/channels/{channel}/agents/{box}/{id}
# @description (RemoveChannelAgent): the seat's origin becomes 'removed', which
# @description the hub reads as not a member and a later announce cannot undo.
# @description Runs as the env's project service account through the Cloud SQL
# @description proxy, one transaction with app.tenant_id set (rdb 0014).
# @description An agent with no live seat in the channel is reported as absent
# @description and changes nothing. Default channels (lobby, alerts, feedback;
# @description general is lobby) are allowed, as they are on the hub; the
# @description reserved #issues and the retired #tasks are refused. The agent's
# @description desk seat and roster row are untouched: DMs and @mentions still
# @description reach it. The number of seats changed must equal the number of
# @description live seats found, or the transaction rolls back. Values travel
# @description as psql variables (:'var'), never spliced into the SQL.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param CHANNEL - required: the channel id
# @param AGENTS - required: space-separated agent ids, e.g. "CLE-7 CLE-8"
# @param AGENT_BOX (optional) - default box-desk. box-wui is reserved.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 CHANNEL=spool-hub-devel AGENTS=CLE-001 DRY_RUN=0 ./run -a do_spl_channel_agent_remove_op
#------------------------------------------------------------------------------
do_spl_channel_agent_remove_op() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" box="${AGENT_BOX:-$(spl_desk_box_default)}" agents="${AGENTS:-}" dry=1 a
  local -a ids=()
  declare -A seen=()
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
  [[ "$ch" == general ]] && ch=lobby
  case "$ch" in
    issues|tasks) do_log "FATAL #$ch is not a channel an agent sits in (reserved / retired)"; return 1 ;;
  esac
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL AGENT_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ -n "$agents" ]] || { do_log "FATAL AGENTS must name at least one agent id"; return 1; }
  for a in $agents; do
    [[ "$a" =~ ^[A-Z]{2,4}-[0-9]+$ && "$a" != HUM-* && "${a%%-*}" != BOX ]] || { do_log "FATAL AGENTS entry '$a' is not an agent id"; return 1; }
    [[ -n "${seen[$a]:-}" ]] && continue
    seen[$a]=1
    ids+=("$a")
  done
  agents="${ids[*]}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would remove $agents on $box from #$ch in $tenant (origin=removed) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_channel_agent_remove_op_run "$tenant" "$ch" "$box" "$agents"
}

# _spl_channel_agent_remove_op_run <tenant> <channel> <box> <agents>, with
# SPL_PROXY_DSN set (inside spl_via_proxy).
_spl_channel_agent_remove_op_run() {
  local out rc=0 n_removed n_absent n_want=0 a ids
  for a in $4; do n_want=$((n_want + 1)); done
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
      -v tenant="$1" -v channel="$2" -v box="$3" -v agents="$4" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT (:'channel' IN ('issues', 'tasks'))::int AS isres \gset
\if :isres
ROLLBACK;
SELECT format('refuse-reserved | %s', :'channel');
\quit 1
\endif
SELECT coalesce(string_agg(s.a, ' ' ORDER BY s.a), '') AS had
  FROM (
         SELECT DISTINCT btrim(x) AS a
           FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
          WHERE btrim(x) <> ''
            AND EXISTS (
              SELECT 1 FROM channel_subscriptions c
               WHERE c.tenant_id = :'tenant' AND c.channel_id = :'channel'
                 AND c.box_id = :'box' AND c.agent_id = btrim(x)
                 AND c.origin <> 'removed'
            )
       ) s \gset
SELECT count(*)::int AS nhad FROM (
         SELECT btrim(x) AS a
           FROM unnest(string_to_array(:'had', ' ')) AS t(x)
          WHERE btrim(x) <> ''
       ) h \gset
UPDATE channel_subscriptions AS c
   SET origin = 'removed'
 WHERE c.tenant_id = :'tenant' AND c.channel_id = :'channel' AND c.box_id = :'box'
   AND c.origin <> 'removed'
   AND c.agent_id IN (
         SELECT DISTINCT btrim(x)
           FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
          WHERE btrim(x) <> ''
       );
SELECT :ROW_COUNT AS nremoved \gset
SELECT (:nremoved::int = :nhad::int)::int AS ok \gset
\if :ok
SELECT format('removed | %s', btrim(x))
  FROM unnest(string_to_array(:'had', ' ')) AS t(x)
 WHERE btrim(x) <> ''
 ORDER BY 1;
SELECT format('absent | %s', btrim(x))
  FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
 WHERE btrim(x) <> ''
   AND NOT (btrim(x) = ANY (string_to_array(:'had', ' ')))
 GROUP BY btrim(x)
 ORDER BY 1;
COMMIT;
\else
ROLLBACK;
SELECT 'refuse-count';
\quit 1
\endif
SQL
)" || rc=$?
  # psql 18 treats "\quit 1" as \quit and exits 0, so a refusal is recognised
  # from the line the script printed, not from rc (as in the add op).
  if grep -q '^refuse-reserved | ' <<<"$out"; then
    do_log "FATAL #$2 is reserved / retired: no agent sits in it"
    return 1
  elif grep -q '^refuse-count$' <<<"$out"; then
    do_log "FATAL agent remove of $4 from #$2 on $3 in $1 changed an unexpected number of rows; rolled back"
    return 1
  elif (( rc != 0 )); then
    do_log "FATAL agent remove of $4 from #$2 on $3 in $1 failed: $out"
    return 1
  fi
  n_removed="$(grep -c '^removed | ' <<<"$out" || true)"
  n_absent="$(grep -c '^absent | ' <<<"$out" || true)"
  if (( n_removed + n_absent != n_want )); then
    do_log "FATAL agent remove of $4 from #$2 on $3 in $1 returned $n_removed removed and $n_absent absent, want $n_want: $out"
    return 1
  fi
  if (( n_removed > 0 )); then
    ids="$(grep '^removed | ' <<<"$out" | sed 's/^removed | //' | paste -sd ' ' -)"
    do_log "OK removed $ids on $3 from #$2 in $1 ($GCP_ACCOUNT)"
  fi
  if (( n_absent > 0 )); then
    ids="$(grep '^absent | ' <<<"$out" | sed 's/^absent | //' | paste -sd ' ' -)"
    do_log "OK $ids had no seat in #$2 on $3 in $1 - nothing to remove ($GCP_ACCOUNT)"
  fi
}
