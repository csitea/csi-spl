#!/bin/bash
#------------------------------------------------------------------------------
# @description Print p50 / p90 / max and n of every hop an agent-to-agent
# @description message crosses, READ-ONLY (spec 053 section 8, SPL-6511): the one
# @description named measurement every later "faster" claim is held against
# @description (lesson-speed-up-measure-first.md).
# @description
# @description Box hops come from the poke ledger, <spool root>/<id>/lifetime/
# @description poke-ledger.tsv, which spool_notify_poke and spool-agent-hook.sh
# @description write: send script, inbox file to poke (send and sidecar paths),
# @description the poke itself, poke to the next prompt, and inbox file to seen,
# @description idle (UserPromptSubmit) and busy (PostToolUse); plus the poke
# @description exit codes (6 = refused, unsent text).
# @description
# @description With ENV set it adds the hub hops through do_spl_db_query (read
# @description only, ids and timestamps, never a body): P-A sender ts to hub,
# @description hub to sent, sent to box ack, per sender vendor; P-B hub to sent
# @description per receiving box.
# @description
# @description It sends nothing and writes nothing. do_spl_latency_probe is the
# @description other probe: it DMs a seated desk on the live path, a write.
# @param LAT_SPOOL_ROOT (optional) - the spool root to read; default SPOOL_ROOT, else /var/spool-hub
# @param LAT_HOURS (optional) - the window in hours, default 24
# @param LAT_NOW (optional) - the window's end, epoch seconds; default now (tests pin it)
# @param ENV (optional) - dev or prd; set it to add the hub hops
# @param TENANT_ID (optional) - the tenant of the hub hops; needed with ENV
# @example ./run -a do_spl_latency_hops
# @example ENV=prd TENANT_ID=t1 LAT_HOURS=6 ./run -a do_spl_latency_hops
#------------------------------------------------------------------------------
do_spl_latency_hops() {
  do_require_bin python3 || return 1
  local root="${LAT_SPOOL_ROOT:-${SPOOL_ROOT:-/var/spool-hub}}" hours="${LAT_HOURS:-24}" tenant="${TENANT_ID:-}"
  [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]] || { do_log "FATAL LAT_HOURS must be a number of hours, got '$hours'"; return 1; }
  [[ -z "${LAT_NOW:-}" || "$LAT_NOW" =~ ^[0-9]+$ ]] || { do_log "FATAL LAT_NOW must be epoch seconds, got '$LAT_NOW'"; return 1; }
  [[ -d "$root" ]] || { do_log "FATAL no spool root at $root (LAT_SPOOL_ROOT)"; return 1; }
  echo "== box hops, $root, last ${hours} h (poke ledger) =="
  python3 -I "$PROJ_PATH/src/bash/scripts/latency-hops.py" "$root" "$hours" ${LAT_NOW:+"$LAT_NOW"} || return 1
  if [[ -z "${ENV:-}" ]]; then
    do_log "INFO hub hops skipped: set ENV=<dev|prd> and TENANT_ID to add P-A and P-B"
    return 0
  fi
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { do_log "FATAL TENANT_ID is needed with ENV, a tenant id, got '$tenant'"; return 1; }
  echo "== hub hops P-A, $ENV $tenant, last ${hours} h (ms, by sender vendor) =="
  SQL="$(spl_lat_hops_sql_pa "$tenant" "$hours")" do_spl_db_query || return 1
  echo "== hub hops P-B, $ENV $tenant, last ${hours} h (hub received -> sent, ms, by box) =="
  SQL="$(spl_lat_hops_sql_pb "$tenant" "$hours")" do_spl_db_query || return 1
}

# P-A (lat-measure c-458): sender ts -> hub received, received -> sent to the
# box, sent -> box ack, per sender vendor (first letter of the id, or human).
# Ids and timestamps only. TENANT and HOURS are validated by the caller.
spl_lat_hops_sql_pa() {  # TENANT HOURS
  printf '%s' "with m as (select msg_id, ts, received_at, case when from_id like 'HUM-%' then 'human' else substr(from_id, 1, 1) end fv from messages where tenant_id = '$1' and received_at > now() - interval '$2 hours'), " \
    "h as (select 'A send->hub' hop, fv, extract(epoch from received_at - ts) * 1000 ms from m " \
    "union all select 'B hub->sent', m.fv, extract(epoch from d.sent_at - m.received_at) * 1000 from m join deliveries d on d.tenant_id = '$1' and d.msg_id = m.msg_id where d.sent_at is not null " \
    "union all select 'C sent->ack', m.fv, extract(epoch from d.acked_at - d.sent_at) * 1000 from m join deliveries d on d.tenant_id = '$1' and d.msg_id = m.msg_id where d.acked_at is not null) " \
    "select hop, coalesce(fv, 'all') vendor, count(*) n, round(percentile_disc(0.5) within group (order by ms)) p50_ms, " \
    "round(percentile_disc(0.9) within group (order by ms)) p90_ms, round(max(ms)) max_ms from h group by hop, rollup(fv) order by 1, 2"
}

# P-B: hub received -> sent, per receiving box (a late-connecting box shows here).
spl_lat_hops_sql_pb() {  # TENANT HOURS
  printf '%s' "select coalesce(d.to_box, 'all') to_box, count(*) n, " \
    "round(percentile_disc(0.5) within group (order by extract(epoch from d.sent_at - m.received_at) * 1000)) p50_ms, " \
    "round(percentile_disc(0.9) within group (order by extract(epoch from d.sent_at - m.received_at) * 1000)) p90_ms, " \
    "round(max(extract(epoch from d.sent_at - m.received_at) * 1000)) max_ms " \
    "from messages m join deliveries d on d.tenant_id = m.tenant_id and d.msg_id = m.msg_id " \
    "where m.tenant_id = '$1' and m.received_at > now() - interval '$2 hours' and d.sent_at is not null group by rollup(d.to_box) order by 1"
}
