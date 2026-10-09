#!/bin/bash
#------------------------------------------------------------------------------
# @description Re-address named broadcast messages of one sender to one
# @description recipient, in one tenant of a cloud env (spec 117 FR-6). A row
# @description changes only while it is still to_id='ALL-0' with no channel,
# @description from FROM_ID, in TENANT_ID, and its msg_id is one of MSG_IDS:
# @description to_id and msg->'to' become NEW_TO. The signed env bytes are
# @description left as they are (they keep ALL-0).
# @description
# @description Values travel as psql variables (:'var', quoted by psql), never
# @description spliced into the SQL. ONE transaction under the tenant's RLS
# @description context (app.tenant_id), through the Cloud SQL proxy as the
# @description env's project service account. Every id must match exactly one
# @description row and n must equal the number of ids, else it is refused and
# @description rolled back.
# @description DRY_RUN=1 (default): print the matching rows (ids and to_id,
# @description never a body), n and the UPDATE; change nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param FROM_ID - required: the sender, e.g. HUM-46
# @param NEW_TO - required: the new recipient, e.g. HUM-10
# @param MSG_IDS - required: comma list of full msg uuids or 8-hex prefixes
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev TENANT_ID=t1 FROM_ID=HUM-46 NEW_TO=HUM-10 MSG_IDS=86abbd6a,b7b1b5e7 ./run -a do_spl_msg_readdress
#------------------------------------------------------------------------------
do_spl_msg_readdress() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" from="${FROM_ID:-}" to="${NEW_TO:-}" ids dry=1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$from" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL FROM_ID must look like HUM-46, got: '$from'"; return 1; }
  [[ "$to" =~ ^[A-Z]+-[0-9]+$ && "$to" != ALL-0 ]] || { do_log "FATAL NEW_TO must look like HUM-10 (not ALL-0), got: '$to'"; return 1; }
  ids="$(_spl_msg_readdress_ids "${MSG_IDS:-}")" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_RA_TENANT="$tenant" SPL_RA_FROM="$from" SPL_RA_TO="$to" SPL_RA_IDS="$ids" SPL_RA_DRY="$dry" \
    spl_via_proxy _spl_msg_readdress_run
}

# _spl_msg_readdress_ids <comma list> -> the ids lower-cased, comma-joined;
# fails on an empty list, a malformed id or one given twice (same 8-hex head).
_spl_msg_readdress_ids() {
  local raw="${1,,}" id seen=" " list=() out=()
  raw="${raw// /}"
  [[ -n "$raw" ]] || { do_log "FATAL MSG_IDS must list at least one msg id (uuid or 8-hex prefix)" >&2; return 1; }
  IFS=',' read -r -a list <<<"$raw"
  for id in "${list[@]}"; do
    [[ "$id" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$ ]] ||
      { do_log "FATAL MSG_IDS: '$id' is neither a uuid nor an 8-hex prefix" >&2; return 1; }
    [[ "$seen" != *" ${id:0:8} "* ]] || { do_log "FATAL MSG_IDS: '${id:0:8}' is given twice" >&2; return 1; }
    seen+="${id:0:8} "; out+=("$id")
  done
  local IFS=,; printf '%s\n' "${out[*]}"
}

# The match, the n check and the UPDATE - ONE transaction under the tenant's
# RLS context, committed only when SPL_RA_DRY=0, n is right and the UPDATE
# changed exactly n rows. psql prints MATCH|<msg_id>|<task_id>|<to_id> per
# row, then N|<n>|<ids given>|<ok>, and UPDATE|<rows> when it ran the UPDATE.
_spl_msg_readdress_run() {
  local out n nids ok upd
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$SPL_RA_TENANT" \
    -v from="$SPL_RA_FROM" -v to="$SPL_RA_TO" -v ids="$SPL_RA_IDS" -v dry="$SPL_RA_DRY" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
CREATE TEMP TABLE ra_hit ON COMMIT DROP AS
SELECT i.id, m.msg_id, m.task_id, m.to_id
  FROM unnest(string_to_array(:'ids', ',')) AS i(id)
  LEFT JOIN messages m ON m.tenant_id = :'tenant' AND m.from_id = :'from' AND m.to_id = 'ALL-0'
   AND m.channel IS NULL AND m.msg_id::text LIKE i.id || '%';
SELECT 'MATCH|' || msg_id || '|' || task_id || '|' || to_id FROM ra_hit WHERE msg_id IS NOT NULL ORDER BY msg_id;
SELECT count(DISTINCT msg_id) AS n, count(DISTINCT id) AS nids,
       count(DISTINCT msg_id) = count(DISTINCT id)
       AND NOT EXISTS (SELECT 1 FROM ra_hit GROUP BY id HAVING count(msg_id) <> 1) AS ok
  FROM ra_hit \gset
\echo N|:n|:nids|:ok
\if :dry
ROLLBACK;
\elif :ok
UPDATE messages SET to_id = :'to', msg = jsonb_set(msg, '{to}', to_jsonb(:'to'::text))
 WHERE tenant_id = :'tenant' AND from_id = :'from' AND to_id = 'ALL-0' AND channel IS NULL
   AND msg_id IN (SELECT msg_id FROM ra_hit);
SELECT :ROW_COUNT AS upd, :ROW_COUNT = :n AS same \gset
\echo UPDATE|:upd
\if :same
COMMIT;
\else
ROLLBACK;
\endif
\else
ROLLBACK;
\endif
SQL
  )" || { do_log "FATAL the readdress statement failed on $ENV/$SPL_RA_TENANT (nothing was committed): $out"; return 1; }
  grep '^MATCH|' <<<"$out" | sed 's/^MATCH|/MATCH msg=/; s/|/ task=/; s/|/ to=/'
  IFS='|' read -r _ n nids ok < <(grep '^N|' <<<"$out")
  do_log "INFO n=$n of $nids id(s) in $ENV/$SPL_RA_TENANT from $SPL_RA_FROM (to_id ALL-0, no channel)"
  do_log "INFO UPDATE messages SET to_id='$SPL_RA_TO', msg=jsonb_set(msg,'{to}','\"$SPL_RA_TO\"') WHERE tenant_id='$SPL_RA_TENANT' AND from_id='$SPL_RA_FROM' AND to_id='ALL-0' AND channel IS NULL AND msg_id IN (the $n above)"
  [[ "$ok" == t ]] || { do_log "FATAL n=$n does not match the $nids id(s) given, one row each: refused, nothing changed"; return 1; }
  if (( SPL_RA_DRY )); then
    do_log "OK DRY_RUN rolled back: nothing changed in $ENV/$SPL_RA_TENANT. Re-run with DRY_RUN=0."
    return 0
  fi
  upd="$(grep '^UPDATE|' <<<"$out" | cut -d'|' -f2)"
  [[ "$upd" == "$n" ]] || { do_log "FATAL UPDATE ${upd:-none} != n=$n: rolled back, nothing changed"; return 1; }
  do_log "OK UPDATE $upd: $ENV/$SPL_RA_TENANT messages from $SPL_RA_FROM now to $SPL_RA_TO ($GCP_ACCOUNT)"
}
