#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove named stale rows from a tenant's agent_seats on ONE box.
# @description A seat row outlives its roster row on purpose (rdb 0107), so a
# @description seat of a retired id stays for good; do_spl_box_purge removes
# @description them only with the whole box, and refuses a box that is live.
# @description Before this, nothing removed a single row short of a hand DELETE.
# @description
# @description WHAT IT KEEPS: messages, deliveries, roster, pins and boxes. The
# @description only table it writes is agent_seats.
# @description
# @description SAFETY. AGENT_IDS is an explicit list, never a pattern: each entry
# @description must be a whole agent id. It refuses a role seat (001..003 in any
# @description current vendor letter, or an orchestrator or dispatcher id of
# @description lease.conf), an id with no seat row for that tenant and box, and
# @description an id with a roster row on that box. A retired legacy id such as
# @description CLE-001 is no role seat here: spec 061 ended that form. A stale row
# @description can still name it (the hub seated legacy ids past the deadline
# @description until SPL-4926), but no agent runs as it, and the roster refusal
# @description still covers it. Every
# @description statement runs under SET LOCAL app.tenant_id (rdb 0107 RLS). The
# @description delete re-checks the roster, is ONE transaction, and is rolled
# @description back unless exactly the named number of rows went.
# @description
# @description DRY_RUN=1 (default) prints the tenant's FULL seat list for that
# @description box with a prune/keep column and deletes nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param BOX_ID - required: the box the seats are on
# @param AGENT_IDS - required: space-separated agent ids, explicitly named
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev TENANT_ID=e2e BOX_ID=box-a AGENT_IDS="CLE-35013 CLE-35014" ./run -a do_spl_agent_seats_prune
# @example ENV=dev TENANT_ID=e2e BOX_ID=box-a AGENT_IDS="CLE-35013" DRY_RUN=0 ./run -a do_spl_agent_seats_prune
#------------------------------------------------------------------------------
do_spl_agent_seats_prune() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${BOX_ID:-}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL BOX_ID '$box' is not a box id"; return 1; }
  local -a agents=()
  _spl_agent_seats_prune_ids || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_PRUNE_AGENTS="${agents[*]}" SPL_PRUNE_TENANT="$tenant" SPL_PRUNE_BOX="$box" SPL_PRUNE_DRY="$dry" \
    spl_via_proxy _spl_agent_seats_prune_run
}

# Fill the caller's agents from AGENT_IDS, or refuse it. read, not an unquoted
# for: a glob in the list must reach the id check, not expand to file names.
_spl_agent_seats_prune_ids() {
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  local -a named=()
  IFS=$' \t\n' read -r -d '' -a named <<<"${AGENT_IDS:-}" || :
  (( ${#named[@]} > 0 )) || { do_log "FATAL AGENT_IDS is required: name every agent explicitly (there is no pattern form)"; return 1; }
  local a
  for a in "${named[@]}"; do
    [[ "$a" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || { do_log "FATAL AGENT_IDS holds '$a', which is not a whole agent id (there is no pattern form)"; return 1; }
    if [[ "$a" =~ ^${SPL_ROLE_SEAT_RX}$ ]] || spl_desk_is_od "$a"; then
      do_log "FATAL $a is an orchestrator or dispatcher seat: it carries the owner's posts and is never pruned by this action"
      return 1
    fi
    [[ " ${agents[*]-} " != *" $a "* ]] || { do_log "FATAL AGENT_IDS names $a twice"; return 1; }
    agents+=("$a")
  done
}

# The plan (always) and, unless SPL_PRUNE_DRY, the delete. Both run under
# SET LOCAL app.tenant_id, so rdb 0107 RLS scopes them to that tenant.
_spl_agent_seats_prune_run() {
  local where="$ENV/$SPL_PRUNE_TENANT/$SPL_PRUNE_BOX" plan want
  want="$(wc -w <<<"$SPL_PRUNE_AGENTS")"
  plan="$(_spl_agent_seats_prune_plan_sql |
    PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_PRUNE_TENANT" -v box="$SPL_PRUNE_BOX" -v agents="$SPL_PRUNE_AGENTS")" ||
    { do_log "FATAL cannot read the seats of $where"; return 1; }
  do_log "INFO every seat of $where, prune is what AGENT_IDS named (enumeration, not a pattern):"
  printf 'agent_id|action|in_roster|seated_at\n'
  [[ -z "$plan" ]] || printf '%s\n' "$plan"

  local a row miss=() live=()
  for a in $SPL_PRUNE_AGENTS; do
    row="$(grep -m1 "^$a|" <<<"$plan")"
    [[ -n "$row" ]] || miss+=("$a")
    [[ "$row" != "$a|prune|t|"* ]] || live+=("$a")
  done
  (( ${#miss[@]} == 0 )) || { do_log "FATAL no seat in $where: ${miss[*]} (nothing was touched)"; return 1; }
  (( ${#live[@]} == 0 )) || { do_log "FATAL a live roster row in $where: ${live[*]} (nothing was touched)"; return 1; }

  if (( SPL_PRUNE_DRY )); then
    do_log "OK DRY_RUN would prune $want seat(s) from $where: $SPL_PRUNE_AGENTS. Re-run with DRY_RUN=0."
    return 0
  fi
  local out n ok gone
  out="$(_spl_agent_seats_prune_sql |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_PRUNE_TENANT" -v box="$SPL_PRUNE_BOX" -v agents="$SPL_PRUNE_AGENTS" -v want="$want")" ||
    { do_log "FATAL the prune statement failed on $where (nothing was committed): $out"; return 1; }
  read -r n ok gone <<<"$(tail -n1 <<<"$out")"
  [[ "$ok" == t ]] || { do_log "FATAL $n of $want seat(s) matched in $where: ROLLED BACK, nothing was deleted. A seat with a roster row is held back on purpose."; return 1; }
  do_log "OK pruned $n seat(s) from $where ($GCP_ACCOUNT): $gone; roster, messages and history kept"
}

# _spl_agent_seats_prune_plan_sql: the box's seats as agent|action|in_roster|
# seated_at, in a transaction that only reads.
_spl_agent_seats_prune_plan_sql() {
  cat <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT s.agent_id,
       CASE WHEN s.agent_id = ANY (string_to_array(:'agents', ' ')) THEN 'prune' ELSE 'keep' END,
       EXISTS (SELECT 1 FROM roster r
                WHERE r.tenant_id = s.tenant_id AND r.box_id = s.box_id AND r.agent_id = s.agent_id),
       s.seated_at
  FROM agent_seats s
 WHERE s.tenant_id = :'tenant' AND s.box_id = :'box'
 ORDER BY s.agent_id;
ROLLBACK;
SQL
}

# _spl_agent_seats_prune_sql: delete the named seats that have no roster row,
# COMMIT only when :want rows went, and echo the counts as one line.
_spl_agent_seats_prune_sql() {
  cat <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
WITH req AS (SELECT unnest(string_to_array(:'agents', ' ')) AS agent_id),
     gone AS (
       DELETE FROM agent_seats s USING req
        WHERE s.tenant_id = :'tenant' AND s.box_id = :'box' AND s.agent_id = req.agent_id
          AND NOT EXISTS (SELECT 1 FROM roster r
                           WHERE r.tenant_id = s.tenant_id AND r.box_id = s.box_id AND r.agent_id = s.agent_id)
       RETURNING s.agent_id)
SELECT count(*)::int AS n, coalesce(string_agg(agent_id, ' ' ORDER BY agent_id), '') AS gone FROM gone \gset
SELECT :n = :want AS ok \gset
\if :ok
COMMIT;
\else
ROLLBACK;
\endif
\echo :n :ok :gone
SQL
}
