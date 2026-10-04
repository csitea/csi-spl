#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed a THROWAWAY tenant on DEV with a large synthetic message set,
# @description so the search queries can be measured at scale (specs/022 §9,
# @description CLE-34992: 1M messages, 10k topics, 1k channels). DEV only: prd
# @description is refused. The tenant id must start with "seed-", which is also
# @description what do_spl_search_seed_purge insists on before it deletes. Rows
# @description expire after 3 days, so a forgotten seed is swept by retention.
# @description Bodies mix 20 common words (~10% each), a rare token term<n>
# @description (n < 50000) and one accented word (~10% each), so a query can
# @description pick a common, a rare, a prefix and an accent-folded case.
# @description Runs as the hub's runtime login under the operator RLS scope,
# @description in SEED_BATCH-row statements; re-running resumes (ON CONFLICT DO
# @description NOTHING). Dry run unless DRY_RUN=0: prints the plan and the SQL.
# @param ENV - required: dev (prd is refused)
# @param SEED_TENANT (optional) - default seed-search; must match ^seed-[a-z0-9-]{1,26}$
# @param SEED_MSGS (optional) - messages, 1..2000000, default 1000000
# @param SEED_TOPICS (optional) - tasks, 1..100000, default 10000
# @param SEED_CHANNELS (optional) - channels, 1..5000, default 1000
# @param SEED_BATCH (optional) - rows per INSERT, 1000..200000, default 100000
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_search_seed
#------------------------------------------------------------------------------
do_spl_search_seed() {
  do_require_bin yq psql || return 1
  spl_search_seed_args || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_log "INFO seed $SEED_TENANT on $ENV: $SEED_MSGS messages, $SEED_TOPICS topics, $SEED_CHANNELS channels, $SEED_BATCH per statement"
  if [[ $dry -eq 1 ]]; then
    spl_search_seed_sql
    do_log "INFO DRY_RUN=1: nothing written (DRY_RUN=0 seeds)"
    return 0
  fi
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_search_seed_run
}

# spl_search_seed_args validates ENV and the SEED_* knobs, exporting defaults.
spl_search_seed_args() {
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL the search seed is DEV only (ENV=${ENV:-})"; return 1; }
  SEED_TENANT="${SEED_TENANT:-seed-search}"
  SEED_MSGS="${SEED_MSGS:-1000000}" SEED_TOPICS="${SEED_TOPICS:-10000}"
  SEED_CHANNELS="${SEED_CHANNELS:-1000}" SEED_BATCH="${SEED_BATCH:-100000}"
  [[ "$SEED_TENANT" =~ ^seed-[a-z0-9-]{1,26}$ ]] || { do_log "FATAL SEED_TENANT must match ^seed-[a-z0-9-]{1,26}\$, got: $SEED_TENANT"; return 1; }
  spl_search_seed_int SEED_MSGS "$SEED_MSGS" 1 2000000 || return 1
  spl_search_seed_int SEED_TOPICS "$SEED_TOPICS" 1 100000 || return 1
  spl_search_seed_int SEED_CHANNELS "$SEED_CHANNELS" 1 5000 || return 1
  spl_search_seed_int SEED_BATCH "$SEED_BATCH" 1000 200000 || return 1
  export SEED_TENANT SEED_MSGS SEED_TOPICS SEED_CHANNELS SEED_BATCH
}

spl_search_seed_int() { # <name> <value> <min> <max>
  [[ "$2" =~ ^[0-9]{1,9}$ ]] && (($2 >= $3 && $2 <= $4)) && return 0
  do_log "FATAL $1 must be an integer $3..$4, got: $2"
  return 1
}

# spl_search_seed_sql prints the seed script: the tenant, its channels, then
# one INSERT per batch. Every value is a validated integer or the seed- slug.
spl_search_seed_sql() {
  local t="$SEED_TENANT" lo hi
  cat <<SQL
SET statement_timeout = 0;
SELECT set_config('app.rls_scope', 'operator', false);
INSERT INTO tenants (tenant_id, root_pubkey, display_name)
  VALUES ('$t', decode(repeat('00', 32), 'hex'), 'Search seed (throwaway)') ON CONFLICT (tenant_id) DO NOTHING;
INSERT INTO channels (tenant_id, channel_id, name, created_by)
  SELECT '$t', 'seed-ch-' || c, 'seed channel ' || c, 'HUM-1' FROM generate_series(0, $SEED_CHANNELS - 1) c
  ON CONFLICT DO NOTHING;
SQL
  for ((lo = 0; lo < SEED_MSGS; lo += SEED_BATCH)); do
    hi=$((lo + SEED_BATCH - 1)); ((hi >= SEED_MSGS)) && hi=$((SEED_MSGS - 1))
    cat <<SQL
\\echo seed rows $lo..$hi
INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, kind, body,
    files, msg, env_sig, env, received_at, expires_at, channel)
SELECT '$t', md5('$t-m-' || i)::uuid, md5('$t-t-' || (i % $SEED_TOPICS))::uuid, at, 'box-seed', 'CLE-' || (i % 50),
    'box-seed', 'GRK-' || (i % 30), 'note',
    w[1 + (i * 7) % 20] || ' ' || w[1 + (i * 13 / 7) % 20] || ' term' || ((i * 7919) % 50000) || ' '
      || a[1 + (i * 31 / 3) % 10] || ' seed message ' || i,
    '[]'::jsonb, '{}'::jsonb, 'seed', '\\x00'::bytea, at, now() + interval '3 days',
    CASE WHEN (i % $SEED_TOPICS) % 20 = 0 THEN NULL ELSE 'seed-ch-' || ((i % $SEED_TOPICS) % $SEED_CHANNELS) END
FROM (SELECT i, now() - (i::float8 / $SEED_MSGS) * interval '7 days' AS at,
        ARRAY['deploy','hub','build','test','release','merge','review','ticket','error','fix',
              'plan','report','search','index','query','agent','channel','topic','tenant','event'] AS w,
        ARRAY['café','résumé','Straße','naïve','São','Zürich','Ångström','crème','façade','piñata'] AS a
      FROM generate_series($lo::bigint, $hi::bigint) i) s
ON CONFLICT (tenant_id, msg_id) DO NOTHING;
SQL
  done
  echo "SELECT count(*) AS seeded FROM messages WHERE tenant_id = '$t';"
}

_spl_search_seed_run() {
  spl_search_seed_sql | spl_pg_env "$SPL_PROXY_DSN" psql -X -q -v ON_ERROR_STOP=1 -P pager=off -f -
}
