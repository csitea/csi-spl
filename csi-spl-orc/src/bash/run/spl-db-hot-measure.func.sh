#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY latency of the hub's HOT statements on one tenant
# @description (SPL-984, spec 029 §8): the statements Query Insights ranks top
# @description by total time (do_spl_db_insights), each PREPAREd with the
# @description store's own text and run MEASURE_N times as EXPLAIN (ANALYZE)
# @description EXECUTE - so the plan cache behaves as it does under pgx (custom
# @description plans first, then generic). The session is
# @description default_transaction_read_only=on (Postgres refuses any write)
# @description and takes the TENANT row-level-security scope the hub uses, as
# @description the hub's runtime login. Prints p50 / p95 / max of Postgres' own
# @description Execution Time per statement, per JIT setting, so one run gives
# @description the JIT on/off pair.
# @description Statement texts are copied from the store (tree at SPL-984):
# @description walk_all / walk_dm = view_postgres.go viewTopicsSQL as
# @description handleViewTopics calls it (Roots, NoIssues, read door, limit 51;
# @description walk_dm adds DM + Viewer); walk_all_pre = walk_all with the
# @description aggregate before CLE-35061 ((array_agg(m.msg))[1]), the CONTROL;
# @description the defaults (bitmap off, custom plans) are the walk's scope; thread = ViewTopic desc page of the
# @description tenant's biggest topic; channels = ViewChannels; issues =
# @description ListIssues; file_door = FileReadableByHuman.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant measured (e.g. t1)
# @param READER - required: the human the read door is evaluated for (e.g. HUM-10)
# @param MEASURE_N (optional) - samples per statement, 3..50, default 10
# @param MEASURE_JIT (optional) - both (default) | on | off
# @param MEASURE_ONLY (optional) - a comma list of statement names; default all
# @param MEASURE_BITMAPSCAN (optional) - both | on | off (default); the walk's scope turns it off since SPL-984
# @param MEASURE_PLAN_CACHE (optional) - force_custom_plan (default, the walk's scope since CLE-35061) | auto (pgx without it) | force_generic_plan
# @param MEASURE_PLANS (optional) - 1 also prints one EXPLAIN (ANALYZE, BUFFERS) per statement
# @param MEASURE_TIMEOUT_MS (optional) - per statement, 100..60000, default 10000
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=prd TENANT_ID=t1 READER=HUM-10 ./run -a do_spl_db_hot_measure
# @example ENV=dev TENANT_ID=t1 READER=HUM-4 MEASURE_ONLY=walk_all MEASURE_PLANS=1 ./run -a do_spl_db_hot_measure
#------------------------------------------------------------------------------
do_spl_db_hot_measure() {
  do_require_bin yq psql python3 || return 1
  spl_db_hot_measure_sql "${TENANT_ID:-}" "${READER:-}" "${MEASURE_N:-10}" "${MEASURE_JIT:-both}" \
    "${MEASURE_ONLY:-}" "${MEASURE_PLANS:-0}" >/dev/null || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_db_hot_measure_run "${TENANT_ID:-}" "${READER:-}" "${MEASURE_N:-10}" "${MEASURE_JIT:-both}" \
    "${MEASURE_ONLY:-}" "${MEASURE_PLANS:-0}"
}

# spl_db_hot_measure_names -> the statement names, one per line.
spl_db_hot_measure_names() {
  printf '%s\n' walk_all walk_all_pre walk_dm thread channels issues file_door
}

# spl_db_hot_measure_prepare -> the PREPAREs (store text, pgx parameter types).
spl_db_hot_measure_prepare() {
  echo "PREPARE walk_all (text, timestamptz, text, text[], text[], int) AS $(spl_db_hot_measure_walk all);"
  echo "PREPARE walk_all_pre (text, timestamptz, text, text[], text[], int) AS $(spl_db_hot_measure_walk all_pre);"
  echo "PREPARE walk_dm (text, timestamptz, text, text, text[], text[], int) AS $(spl_db_hot_measure_walk dm);"
  cat <<'EOF_SQL'
PREPARE thread (text, uuid, timestamptz, text, text[], text[], int) AS SELECT msg_id::text, received_at, env, edited_at, edited_by, CASE WHEN edited_at IS NULL THEN 0 ELSE COALESCE((SELECT MAX(revision) FROM message_revisions r WHERE r.tenant_id = messages.tenant_id AND r.msg_id = messages.msg_id), 0) END, is_parent, typed_by, kind, kind_set_at, kind_set_by FROM messages WHERE tenant_id = $1 AND task_id = $2 AND expires_at > $3 AND ((channel IS NULL AND (from_id = $4 OR to_id = $4)) OR channel = ANY($5::text[]) OR channel = ANY($6::text[])) ORDER BY received_at DESC, msg_id::text DESC LIMIT $7;
PREPARE channels (text, timestamptz) AS SELECT channel, count(*)::int, max(received_at) FROM messages WHERE tenant_id = $1 AND channel IS NOT NULL AND expires_at > $2 GROUP BY channel ORDER BY channel;
PREPARE issues (text) AS SELECT number, title, description, status, priority, level, assignee, labels, deadline, COALESCE(parent_number, 0), task_id::text, created_by, created_at, updated_by, updated_at, completed_at, canceled_at, kind FROM issues WHERE tenant_id = $1 ORDER BY number DESC;
PREPARE file_door (text, text, timestamptz, text, text[], text[]) AS SELECT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = $1 AND m.expires_at > $3 AND (m.files @> jsonb_build_array(jsonb_build_object('file_id', $2::text)) OR m.files @> jsonb_build_array(jsonb_build_object('sha256', $2::text))) AND ((m.channel IS NULL AND (m.from_id = $4 OR m.to_id = $4)) OR m.channel = ANY($5::text[]) OR m.channel = ANY($6::text[])));
EOF_SQL
}

# spl_db_hot_measure_exec <name> -> the EXECUTE for one statement; :'t', :'r',
# :'pub', :'mine', :'task' and :'fid' are psql variables set by the preamble.
spl_db_hot_measure_exec() {
  case "$1" in
    walk_all)  echo "EXECUTE walk_all(:'t', now(), :'r', :'pub', :'mine', 51)" ;;
    walk_all_pre) echo "EXECUTE walk_all_pre(:'t', now(), :'r', :'pub', :'mine', 51)" ;;
    walk_dm)   echo "EXECUTE walk_dm(:'t', now(), :'r', :'r', :'pub', :'mine', 51)" ;;
    thread)    echo "EXECUTE thread(:'t', :'task', now(), :'r', :'pub', :'mine', 51)" ;;
    channels)  echo "EXECUTE channels(:'t', now())" ;;
    issues)    echo "EXECUTE issues(:'t')" ;;
    file_door) echo "EXECUTE file_door(:'t', :'fid', now(), :'r', :'pub', :'mine')" ;;
    *) return 1 ;;
  esac
}

# spl_db_hot_measure_sql <tenant> <reader> <n> <jit> <only> <plans> -> the psql script.
spl_db_hot_measure_sql() {
  local tenant="$1" reader="$2" n="$3" jit="$4" only="$5" plans="$6" to="${MEASURE_TIMEOUT_MS:-10000}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'" >&2; return 1; }
  [[ "$reader" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { do_log "FATAL READER must be a human id (e.g. HUM-10), got: '$reader'" >&2; return 1; }
  [[ "$n" =~ ^[0-9]{1,2}$ ]] && ((n >= 3 && n <= 50)) || { do_log "FATAL MEASURE_N must be 3..50, got: $n" >&2; return 1; }
  [[ "$to" =~ ^[0-9]{3,5}$ ]] && ((to >= 100 && to <= 60000)) || { do_log "FATAL MEASURE_TIMEOUT_MS must be 100..60000, got: $to" >&2; return 1; }
  local pc="${MEASURE_PLAN_CACHE:-force_custom_plan}"
  [[ "$pc" =~ ^(auto|force_custom_plan|force_generic_plan)$ ]] ||
    { do_log "FATAL MEASURE_PLAN_CACHE must be auto, force_custom_plan or force_generic_plan, got: $pc" >&2; return 1; }
  local -a jits bms
  case "${MEASURE_BITMAPSCAN:-off}" in both) bms=(on off) ;; on|off) bms=("${MEASURE_BITMAPSCAN:-off}") ;;
    *) do_log "FATAL MEASURE_BITMAPSCAN must be both, on or off, got: ${MEASURE_BITMAPSCAN}" >&2; return 1 ;; esac
  case "$jit" in both) jits=(on off) ;; on|off) jits=("$jit") ;; *) do_log "FATAL MEASURE_JIT must be both, on or off, got: $jit" >&2; return 1 ;; esac
  local name found=0 j i
  if [[ -n "$only" ]]; then
    for name in ${only//,/ }; do
      spl_db_hot_measure_names | grep -qxF "$name" || { do_log "FATAL MEASURE_ONLY names no statement: $name" >&2; return 1; }
    done
  fi
  echo "SELECT set_config('app.tenant_id', '$tenant', false), set_config('statement_timeout', '$to', false), set_config('plan_cache_mode', '$pc', false);"
  echo "\\set t '$tenant'"
  echo "\\set r '$reader'"
  echo "\\set pub '{lobby,alerts,feedback,issues,tasks}'"
  # The reader's channels, the tenant's biggest topic and one attached file id:
  # the real arguments, read in the same tenant scope the statements run in.
  echo "SELECT COALESCE(array_agg(channel_id ORDER BY channel_id), '{}')::text AS mine FROM channel_humans WHERE tenant_id = '$tenant' AND human_id = '$reader' \\gset"
  echo "SELECT COALESCE((SELECT task_id::text FROM messages WHERE tenant_id = '$tenant' GROUP BY task_id ORDER BY count(*) DESC LIMIT 1), '00000000-0000-0000-0000-000000000000') AS task \\gset"
  echo "SELECT COALESCE((SELECT f->>'file_id' FROM messages m, jsonb_array_elements(m.files) f WHERE m.tenant_id = '$tenant' AND f ? 'file_id' ORDER BY m.received_at LIMIT 1), 'none') AS fid \\gset"
  echo "\\echo @@args tenant=:t reader=:r mine=:mine task=:task"
  spl_db_hot_measure_prepare
  local b tag
  for b in "${bms[@]}"; do
    for j in "${jits[@]}"; do
      echo "SET enable_bitmapscan = $b;"
      echo "SET jit = $j;"
      tag="jit_$j"
      [[ "$b" == off ]] && tag="$tag.nobitmap"
      while IFS= read -r name; do
        [[ -z "$only" || ",$only," == *",$name,"* ]] || continue
        found=1
        if [[ "$plans" == 1 ]]; then
          echo "\\echo @@plan $name $tag"
          echo "EXPLAIN (ANALYZE, BUFFERS) $(spl_db_hot_measure_exec "$name");"
        fi
        for ((i = 0; i < n; i++)); do
          echo "\\echo @@ ${name}.$tag"
          echo "EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF) $(spl_db_hot_measure_exec "$name");"
        done
      done < <(spl_db_hot_measure_names)
    done
  done
  ((found)) || { do_log "FATAL MEASURE_ONLY names no statement: $only" >&2; return 1; }
}

# spl_db_hot_measure_walk <all|dm> -> viewTopicsSQL's text for that shape.
spl_db_hot_measure_walk() {
  case "$1" in
    all) cat <<'EOF_SQL'
WITH RECURSIVE w (task_id, received_at, n) AS ( (SELECT l.task_id, l.received_at, 1 FROM messages l WHERE l.tenant_id = $1 AND l.expires_at > $2 AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE x.tenant_id = $1 AND x.expires_at > $2 AND x.task_id = l.task_id ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1) AND (SELECT true FROM messages d WHERE d.tenant_id = $1 AND d.expires_at > $2 AND d.task_id = l.task_id AND (d.channel = ANY($4::text[]) OR d.channel = ANY($5::text[]) OR (d.channel IS NULL AND (d.from_id = $3 OR d.to_id = $3))) LIMIT 1) AND (SELECT f.parent_task_id IS NULL FROM messages f WHERE f.tenant_id = $1 AND f.expires_at > $2 AND f.task_id = l.task_id ORDER BY f.received_at, f.msg_id::text LIMIT 1) AND (SELECT true FROM issues i WHERE i.tenant_id = $1 AND i.task_id = l.task_id LIMIT 1) IS NULL ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1) UNION ALL SELECT s.task_id, s.received_at, w.n + 1 FROM w CROSS JOIN LATERAL ( SELECT l.task_id, l.received_at FROM messages l WHERE l.tenant_id = $1 AND l.expires_at > $2 AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE x.tenant_id = $1 AND x.expires_at > $2 AND x.task_id = l.task_id ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1) AND (SELECT true FROM messages d WHERE d.tenant_id = $1 AND d.expires_at > $2 AND d.task_id = l.task_id AND (d.channel = ANY($4::text[]) OR d.channel = ANY($5::text[]) OR (d.channel IS NULL AND (d.from_id = $3 OR d.to_id = $3))) LIMIT 1) AND (SELECT f.parent_task_id IS NULL FROM messages f WHERE f.tenant_id = $1 AND f.expires_at > $2 AND f.task_id = l.task_id ORDER BY f.received_at, f.msg_id::text LIMIT 1) AND (SELECT true FROM issues i WHERE i.tenant_id = $1 AND i.task_id = l.task_id LIMIT 1) IS NULL AND l.received_at <= w.received_at AND (l.received_at, l.task_id::text) < (w.received_at, w.task_id::text) ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1 ) s WHERE w.n < $6 ) SELECT w.task_id::text, f.channel, f.parent, f.first_at, w.received_at, a.n, a.kinds, a.parties, f.first_msg FROM w CROSS JOIN LATERAL ( SELECT count(*)::int AS n, array_agg(m.kind ORDER BY m.received_at, m.msg_id::text) AS kinds, array_agg(m.from_id || '@' || m.from_box ORDER BY m.received_at, m.msg_id::text) || array_agg(m.to_id || '@' || m.to_box ORDER BY m.received_at, m.msg_id::text) AS parties FROM messages m WHERE m.tenant_id = $1 AND m.expires_at > $2 AND m.task_id = w.task_id AND (m.channel = ANY($4::text[]) OR m.channel = ANY($5::text[]) OR (m.channel IS NULL AND (m.from_id = $3 OR m.to_id = $3))) ) a LEFT JOIN LATERAL ( SELECT COALESCE(m.channel, '') AS channel, COALESCE(m.parent_task_id::text, '') AS parent, m.received_at AS first_at, m.msg AS first_msg FROM messages m WHERE m.tenant_id = $1 AND m.expires_at > $2 AND m.task_id = w.task_id AND (m.channel = ANY($4::text[]) OR m.channel = ANY($5::text[]) OR (m.channel IS NULL AND (m.from_id = $3 OR m.to_id = $3))) ORDER BY m.received_at, m.msg_id::text LIMIT 1 ) f ON true ORDER BY w.received_at DESC, w.task_id::text DESC
EOF_SQL
      ;;
    all_pre) cat <<'EOF_SQL'
WITH RECURSIVE w (task_id, received_at, n) AS ( (SELECT l.task_id, l.received_at, 1 FROM messages l WHERE l.tenant_id = $1 AND l.expires_at > $2 AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE x.tenant_id = $1 AND x.expires_at > $2 AND x.task_id = l.task_id ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1) AND (SELECT true FROM messages d WHERE d.tenant_id = $1 AND d.expires_at > $2 AND d.task_id = l.task_id AND (d.channel = ANY($4::text[]) OR d.channel = ANY($5::text[]) OR (d.channel IS NULL AND (d.from_id = $3 OR d.to_id = $3))) LIMIT 1) AND (SELECT f.parent_task_id IS NULL FROM messages f WHERE f.tenant_id = $1 AND f.expires_at > $2 AND f.task_id = l.task_id ORDER BY f.received_at, f.msg_id::text LIMIT 1) AND (SELECT true FROM issues i WHERE i.tenant_id = $1 AND i.task_id = l.task_id LIMIT 1) IS NULL ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1) UNION ALL SELECT s.task_id, s.received_at, w.n + 1 FROM w CROSS JOIN LATERAL ( SELECT l.task_id, l.received_at FROM messages l WHERE l.tenant_id = $1 AND l.expires_at > $2 AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE x.tenant_id = $1 AND x.expires_at > $2 AND x.task_id = l.task_id ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1) AND (SELECT true FROM messages d WHERE d.tenant_id = $1 AND d.expires_at > $2 AND d.task_id = l.task_id AND (d.channel = ANY($4::text[]) OR d.channel = ANY($5::text[]) OR (d.channel IS NULL AND (d.from_id = $3 OR d.to_id = $3))) LIMIT 1) AND (SELECT f.parent_task_id IS NULL FROM messages f WHERE f.tenant_id = $1 AND f.expires_at > $2 AND f.task_id = l.task_id ORDER BY f.received_at, f.msg_id::text LIMIT 1) AND (SELECT true FROM issues i WHERE i.tenant_id = $1 AND i.task_id = l.task_id LIMIT 1) IS NULL AND l.received_at <= w.received_at AND (l.received_at, l.task_id::text) < (w.received_at, w.task_id::text) ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1 ) s WHERE w.n < $6 ) SELECT w.task_id::text, a.channel, a.parent, a.first_at, w.received_at, a.n, a.kinds, a.parties, a.first_msg FROM w CROSS JOIN LATERAL ( SELECT (array_agg(COALESCE(m.channel, '') ORDER BY m.received_at, m.msg_id::text))[1] AS channel, (array_agg(COALESCE(m.parent_task_id::text, '') ORDER BY m.received_at, m.msg_id::text))[1] AS parent, min(m.received_at) AS first_at, count(*)::int AS n, array_agg(m.kind ORDER BY m.received_at, m.msg_id::text) AS kinds, array_agg(m.from_id || '@' || m.from_box ORDER BY m.received_at, m.msg_id::text) || array_agg(m.to_id || '@' || m.to_box ORDER BY m.received_at, m.msg_id::text) AS parties, (array_agg(m.msg ORDER BY m.received_at, m.msg_id::text))[1] AS first_msg FROM messages m WHERE m.tenant_id = $1 AND m.expires_at > $2 AND m.task_id = w.task_id AND (m.channel = ANY($4::text[]) OR m.channel = ANY($5::text[]) OR (m.channel IS NULL AND (m.from_id = $3 OR m.to_id = $3))) ) a ORDER BY w.received_at DESC, w.task_id::text DESC
EOF_SQL
      ;;
    dm) cat <<'EOF_SQL'
WITH RECURSIVE w (task_id, received_at, n) AS ( (SELECT l.task_id, l.received_at, 1 FROM messages l WHERE l.tenant_id = $1 AND l.expires_at > $2 AND l.channel IS NULL AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE x.tenant_id = $1 AND x.expires_at > $2 AND x.channel IS NULL AND x.task_id = l.task_id ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1) AND (SELECT true FROM messages v WHERE v.tenant_id = $1 AND v.expires_at > $2 AND v.channel IS NULL AND v.task_id = l.task_id AND (v.from_id = $3 OR v.to_id = $3) LIMIT 1) AND (SELECT true FROM messages d WHERE d.tenant_id = $1 AND d.expires_at > $2 AND d.channel IS NULL AND d.task_id = l.task_id AND (d.channel = ANY($5::text[]) OR d.channel = ANY($6::text[]) OR (d.channel IS NULL AND (d.from_id = $4 OR d.to_id = $4))) LIMIT 1) AND (SELECT f.parent_task_id IS NULL FROM messages f WHERE f.tenant_id = $1 AND f.expires_at > $2 AND f.channel IS NULL AND f.task_id = l.task_id ORDER BY f.received_at, f.msg_id::text LIMIT 1) AND (SELECT true FROM issues i WHERE i.tenant_id = $1 AND i.task_id = l.task_id LIMIT 1) IS NULL ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1) UNION ALL SELECT s.task_id, s.received_at, w.n + 1 FROM w CROSS JOIN LATERAL ( SELECT l.task_id, l.received_at FROM messages l WHERE l.tenant_id = $1 AND l.expires_at > $2 AND l.channel IS NULL AND (SELECT x.msg_id = l.msg_id FROM messages x WHERE x.tenant_id = $1 AND x.expires_at > $2 AND x.channel IS NULL AND x.task_id = l.task_id ORDER BY x.received_at DESC, x.msg_id DESC LIMIT 1) AND (SELECT true FROM messages v WHERE v.tenant_id = $1 AND v.expires_at > $2 AND v.channel IS NULL AND v.task_id = l.task_id AND (v.from_id = $3 OR v.to_id = $3) LIMIT 1) AND (SELECT true FROM messages d WHERE d.tenant_id = $1 AND d.expires_at > $2 AND d.channel IS NULL AND d.task_id = l.task_id AND (d.channel = ANY($5::text[]) OR d.channel = ANY($6::text[]) OR (d.channel IS NULL AND (d.from_id = $4 OR d.to_id = $4))) LIMIT 1) AND (SELECT f.parent_task_id IS NULL FROM messages f WHERE f.tenant_id = $1 AND f.expires_at > $2 AND f.channel IS NULL AND f.task_id = l.task_id ORDER BY f.received_at, f.msg_id::text LIMIT 1) AND (SELECT true FROM issues i WHERE i.tenant_id = $1 AND i.task_id = l.task_id LIMIT 1) IS NULL AND l.received_at <= w.received_at AND (l.received_at, l.task_id::text) < (w.received_at, w.task_id::text) ORDER BY l.received_at DESC, l.task_id::text DESC LIMIT 1 ) s WHERE w.n < $7 ) SELECT w.task_id::text, f.channel, f.parent, f.first_at, w.received_at, a.n, a.kinds, a.parties, f.first_msg FROM w CROSS JOIN LATERAL ( SELECT count(*)::int AS n, array_agg(m.kind ORDER BY m.received_at, m.msg_id::text) AS kinds, array_agg(m.from_id || '@' || m.from_box ORDER BY m.received_at, m.msg_id::text) || array_agg(m.to_id || '@' || m.to_box ORDER BY m.received_at, m.msg_id::text) AS parties FROM messages m WHERE m.tenant_id = $1 AND m.expires_at > $2 AND m.channel IS NULL AND m.task_id = w.task_id AND (m.channel = ANY($5::text[]) OR m.channel = ANY($6::text[]) OR (m.channel IS NULL AND (m.from_id = $4 OR m.to_id = $4))) ) a LEFT JOIN LATERAL ( SELECT COALESCE(m.channel, '') AS channel, COALESCE(m.parent_task_id::text, '') AS parent, m.received_at AS first_at, m.msg AS first_msg FROM messages m WHERE m.tenant_id = $1 AND m.expires_at > $2 AND m.channel IS NULL AND m.task_id = w.task_id AND (m.channel = ANY($5::text[]) OR m.channel = ANY($6::text[]) OR (m.channel IS NULL AND (m.from_id = $4 OR m.to_id = $4))) ORDER BY m.received_at, m.msg_id::text LIMIT 1 ) f ON true ORDER BY w.received_at DESC, w.task_id::text DESC
EOF_SQL
      ;;
  esac
}

_spl_db_hot_measure_run() {
  local out
  # No ON_ERROR_STOP: a timed-out sample is a result, not the end of the run.
  out="$(spl_db_hot_measure_sql "$@" | PGOPTIONS='-c default_transaction_read_only=on' \
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -P pager=off -f - 2>&1)"
  grep -q "Execution Time" <<<"$out" || { printf '%s\n' "$out" | tail -8; do_log "FATAL no sample was measured"; return 1; }
  printf '%s\n' "$out" | grep '^@@args' | sed 's/^@@args /args: /'
  printf '%s\n' "$out" | grep -E '^(ERROR|FATAL)' | sort | uniq -c
  [[ "${6:-0}" == 1 ]] && printf '%s\n' "$out" | awk '/^@@plan/{p=1} /^@@ /{p=0} p'
  printf '%s\n' "$out" | spl_search_measure_summary
}
