#!/bin/bash
#------------------------------------------------------------------------------
# @description Write THIS machine's legacy -> new agent id table ONCE (specs/061
# @description section 5, T060): $SPOOL_ROOT/agent-id-aliases.tsv with
# @description CLE-001..003 -> c-001..003, then every live legacy agent (a
# @description window AND an alive identity record), oldest spawn first, on
# @description the next number of the machine's line (next-agent-id.sh, which
# @description claims it). A second run prints the table and changes nothing.
# @description With HUB_ENV the same rows go into the hub table
# @description agent_id_aliases (rdb 0101) of that env, for every tenant whose
# @description desk on this box seats the agent (old or new id); a row that is
# @description already there is kept, and a row mapping the same (old, box)
# @description to ANOTHER new id rolls the whole write back.
# @description Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param MAP_SKIP (optional) - live legacy ids to leave out (a lane mid-push)
# @param HUB_ENV (optional) - dev or prd: also write the hub rows there (prd
# @param   needs the owner's go)
# @param DESK_BOX (optional) - the box column (default SPOOL_DESK_BOX / box.env)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_id_map
# @example DRY_RUN=0 MAP_SKIP="CLE-77940" ./run -a do_spl_agent_id_map
# @example HUB_ENV=dev DRY_RUN=0 ./run -a do_spl_agent_id_map
#------------------------------------------------------------------------------
do_spl_agent_id_map() {
  local dry=1 args=()
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  (( dry )) || args+=(--apply)
  [[ -n "${MAP_SKIP:-}" ]] && args+=(--skip "$MAP_SKIP")
  [[ -n "${DESK_BOX:-}" ]] && export SPOOL_DESK_BOX="$DESK_BOX"
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/agent-id-map.sh" "${args[@]}" || return 1
  [[ -z "${HUB_ENV:-}" ]] && return 0
  [[ "$HUB_ENV" == dev || "$HUB_ENV" == prd ]] || { do_log "FATAL HUB_ENV must be dev or prd, got: '$HUB_ENV'"; return 1; }
  ENV="$HUB_ENV" spl_agent_id_map_hub "$dry"
}

# spl_agent_id_map_hub <dry> - the table's rows x the tenants whose desk seats
# them, into agent_id_aliases of $ENV.
spl_agent_id_map_hub() {
  local dry="$1" table="${SPOOL_ROOT:-/var/spool-hub}/agent-id-aliases.tsv" box
  do_spl_cloud_cnf || return 1
  box="$(spl_desk_box_default)"
  [[ -s "$table" ]] || { do_log "FATAL no alias table $table: run DRY_RUN=0 ./run -a do_spl_agent_id_map first"; return 1; }
  local values="" n=0 old new kind b at t d
  while IFS=$'\t' read -r old new kind b at; do
    # A retire's row (agent-id-retire.sh): no successor, or not a legacy id.
    if [[ "$new" == retired || ! "$old" =~ ^(CLE|GRK|AGY|QWN)-[0-9]+$ ]]; then continue; fi
    # new: rdb 0155's agent_id_aliases_new_id_check ([acgmq], specs/110); kind
    # stays the four legacy kinds, as that table's kind CHECK does (no MST-).
    [[ "$old" =~ ^(CLE|GRK|AGY|QWN)-[0-9]+$ && "$new" =~ ^[acgmq]-[0-9]{3}$ && "$kind" =~ ^(agy|claude|grok|qwen)$ \
      && "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || { do_log "FATAL $table has a malformed row: $old $new $kind $b $at"; return 1; }
    [[ "$b" == "$box" ]] || continue
    for d in "$SPL_STATE_DIR"/desk/*/"$box"/spool; do
      [[ -e "$d/$old" || -L "$d/$old" || -e "$d/$new" ]] || continue
      t="${d%/"$box"/spool}"; t="${t##*/}"
      [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
      # Every value is checked against its grammar above: safe to splice.
      values+="${values:+,}('$t','$old','$new','$kind','$b','$at')"
      n=$((n + 1))
      do_log "INFO $ENV $t: $old -> $new ($kind, $b)"
    done
  done <"$table"
  (( n > 0 )) || { do_log "WARN no desk of $ENV on $box seats any id of $table: no hub row to write"; return 0; }
  if (( dry )); then
    do_log "OK DRY_RUN would write $n alias row(s) into agent_id_aliases on $ENV. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_agent_id_map_hub_run "$values" "$n"
}

_spl_agent_id_map_hub_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 <<SQL
BEGIN;
SET LOCAL app.rls_scope = 'operator';
CREATE TEMP TABLE want (tenant_id text, old_id text, new_id text, kind text, box_id text, mapped_at timestamptz) ON COMMIT DROP;
INSERT INTO want VALUES $1;
SELECT 'differ | ' || count(*) FROM agent_id_aliases a JOIN want w USING (tenant_id, old_id, box_id) WHERE a.new_id <> w.new_id;
SELECT count(*) > 0 AS bad FROM agent_id_aliases a JOIN want w USING (tenant_id, old_id, box_id) WHERE a.new_id <> w.new_id \gset
\if :bad
ROLLBACK;
\else
WITH ins AS (INSERT INTO agent_id_aliases (tenant_id, old_id, new_id, kind, box_id, mapped_at)
             SELECT tenant_id, old_id, new_id, kind, box_id, mapped_at FROM want
             ON CONFLICT (tenant_id, old_id, box_id) DO NOTHING RETURNING 1)
SELECT 'inserted | ' || count(*) FROM ins;
COMMIT;
\endif
SQL
)" || { do_log "FATAL alias rows not written on $ENV: $out"; return 1; }
  local differ inserted
  differ="$(spl_psql_mark "$out" differ)"; inserted="$(spl_psql_mark "$out" inserted)"
  [[ "$differ" == 0 ]] || { do_log "FATAL $differ hub alias row(s) on $ENV map an old id to ANOTHER new id: rolled back"; return 1; }
  do_log "OK $ENV agent_id_aliases ($GCP_ACCOUNT): $2 row(s) wanted, ${inserted:-0} inserted, $(( $2 - ${inserted:-0} )) already there"
}
