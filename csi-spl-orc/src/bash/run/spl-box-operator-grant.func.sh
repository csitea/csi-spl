#!/bin/bash
#------------------------------------------------------------------------------
# @description Bind a tenant member as the OPERATOR of one box (rdb 0040,
# @description specs/036 FR-010): the human who types at that box's agent
# @description terminals. The hub accepts a send frame's typed_by=<HUM-n> only
# @description for a bound (tenant, box, human), so a terminal-typed line then
# @description shows in the web UI as that human, "via terminal <agent>".
# @description The grant is a tenant owner / admin decision, never the box's:
# @description GRANTED_BY is 'operator' (this operator path) or a HUM-* that
# @description holds biz_owner / admin in the tenant, checked in the same
# @description statement. HUMAN_ID must be a member of the tenant (FK). A
# @description second grant of the same row is a no-op. Values travel as psql
# @description variables (:'var'), never spliced into the SQL. Exactly one row
# @description must be returned, or the transaction is rolled back.
# @description Per env the ids differ: nothing here defaults a HUM id.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param BOX_ID - required: the box whose terminals the human types into
# @param HUMAN_ID - required: e.g. HUM-4 (a member of TENANT_ID)
# @param GRANTED_BY (optional) - 'operator' (default) or the granting owner /
# @param   admin HUM-*
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 BOX_ID=box-a HUMAN_ID=HUM-4 DRY_RUN=0 ./run -a do_spl_box_operator_grant
#------------------------------------------------------------------------------
do_spl_box_operator_grant() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  spl_box_operator_args grant || return 1
  local by="${GRANTED_BY:-operator}" dry=1
  [[ "$by" == operator || "$by" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL GRANTED_BY must be 'operator' or a HUM-* id, got: '$by'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would bind $SPL_BOP_HUMAN as operator of box $SPL_BOP_BOX in $SPL_BOP_TENANT (granted by $by) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_box_operator_grant_run "$SPL_BOP_TENANT" "$SPL_BOP_BOX" "$SPL_BOP_HUMAN" "$by"
}

_spl_box_operator_grant_run() {
  local out n
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v box="$2" -v human="$3" -v by="$4" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
INSERT INTO box_operators (tenant_id, box_id, human_id, granted_by)
SELECT :'tenant', :'box', :'human', :'by'
 WHERE EXISTS (SELECT 1 FROM tenant_memberships WHERE tenant_id = :'tenant' AND human_id = :'human')
   AND (:'by' = 'operator' OR EXISTS (SELECT 1 FROM tenant_memberships
         WHERE tenant_id = :'tenant' AND human_id = :'by' AND role IN ('biz_owner', 'admin', 'owner')))
ON CONFLICT (tenant_id, box_id, human_id) DO UPDATE SET granted_by = box_operators.granted_by
RETURNING format('%s | %s | %s | %s | %s', tenant_id, box_id, human_id, granted_by, granted_at);
SELECT :ROW_COUNT = 1 AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL operator grant of $3 on $2 in $1 failed: $out"; return 1; }
  n="$(grep -c ' | ' <<<"$out")"
  (( n == 1 )) || { do_log "FATAL no grant: $3 is not a member of $1, or $4 is not its owner / admin - rolled back"; return 1; }
  do_log "OK $1 box $2 operator $3 ($GCP_ACCOUNT): $out"
}

# spl_box_operator_args <verb> -> validates TENANT_ID / BOX_ID / HUMAN_ID for
# the box-operator actions into SPL_BOP_{TENANT,BOX,HUMAN}. list takes an
# optional BOX_ID and no HUMAN_ID.
spl_box_operator_args() {
  SPL_BOP_TENANT="${TENANT_ID:-}" SPL_BOP_BOX="${BOX_ID:-}" SPL_BOP_HUMAN="${HUMAN_ID:-}"
  [[ "$SPL_BOP_TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$SPL_BOP_TENANT'"; return 1; }
  if [[ "$1" == list && -z "$SPL_BOP_BOX" ]]; then return 0; fi
  [[ "$SPL_BOP_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL BOX_ID must be a box id, got: '$SPL_BOP_BOX'"; return 1; }
  [[ "$1" == list ]] && return 0
  [[ "$SPL_BOP_HUMAN" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$SPL_BOP_HUMAN'"; return 1; }
}
