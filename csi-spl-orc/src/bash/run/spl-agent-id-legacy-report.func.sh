#!/bin/bash
#------------------------------------------------------------------------------
# @description Count the legacy agent ids (CLE-/GRK-/AGY-/QWN-) still in use
# @description (specs/061 FR-013, T062), one LEGACY line per source, the role
# @description ids 001-003 counted apart. On THIS machine: tmux windows, spool
# @description dirs (a rename's old -> new link is not counted), the dirs a
# @description window also carries, registry rows, alive identity records.
# @description With HUB_ENV also the hub of that env, read-only: messages sent
# @description from or to a legacy id in the last 24 h (and the distinct ids),
# @description and live lane rows (fleet_lanes) of a legacy id. Lane L8 runs it
# @description at the cutoff and expects only the role ids.
# @param HUB_ENV (optional) - dev or prd: add the hub counts
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_id_legacy_report
# @example HUB_ENV=prd ./run -a do_spl_agent_id_legacy_report
#------------------------------------------------------------------------------
do_spl_agent_id_legacy_report() {
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-id-legacy-report.sh" || return 1
  [[ -z "${HUB_ENV:-}" ]] && return 0
  [[ "$HUB_ENV" == dev || "$HUB_ENV" == prd ]] || { do_log "FATAL HUB_ENV must be dev or prd, got: '$HUB_ENV'"; return 1; }
  local ENV="$HUB_ENV"
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_agent_id_legacy_report_hub
}

# The hub half: one row per (source, id, count) -> one LEGACY line per source.
_spl_agent_id_legacy_report_hub() {
  local out rx='^(CLE|GRK|AGY|QWN)-[0-9]+$'
  out="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 -c 'BEGIN TRANSACTION READ ONLY' \
      -c "SET LOCAL app.rls_scope = 'operator'" \
      -c "SELECT 'hub_sends_24h', id, count(*) FROM (
            SELECT msg_id, from_id AS id FROM messages WHERE ts > now() - interval '24 hours' AND from_id ~ '$rx'
            UNION SELECT msg_id, to_id FROM messages WHERE ts > now() - interval '24 hours' AND to_id ~ '$rx') s
          GROUP BY id
          UNION ALL
          SELECT 'hub_lanes_live', agent_id, count(*) FROM fleet_lanes WHERE state = 'live' AND agent_id ~ '$rx'
          GROUP BY agent_id ORDER BY 1, 2" -c 'ROLLBACK' </dev/null)" \
    || { do_log "FATAL the $ENV hub counts failed: $out"; return 1; }
  spl_agent_id_legacy_hub_lines "$ENV" <<<"$out"
}

# spl_agent_id_legacy_hub_lines <env> - "<source> <id> <n>" rows on stdin ->
# "LEGACY <env>:<source> <rows> [roles <n>] <ids...>" (hub_sends_24h counts
# messages: an id's sends are summed; a message between two legacy ids counts
# once per id).
spl_agent_id_legacy_hub_lines() {
  awk -v env="$1" '
    NF == 3 { n[$1] += $3; ids[$1] = ids[$1] " " $2; if ($2 ~ /-0*[123]$/) r[$1]++ }
    END {
      split("hub_sends_24h hub_lanes_live", src, " ")
      for (i = 1; i <= 2; i++) {
        s = src[i]
        printf "LEGACY %s:%s %d%s%s\n", env, s, n[s], (r[s] ? " roles " r[s] : ""), ids[s]
      }
    }'
}
