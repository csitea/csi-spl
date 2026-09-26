#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY latency of the hub's search SQL on one tenant (specs/022
# @description §9, CLE-34992): each query runs MEASURE_N times as EXPLAIN
# @description (ANALYZE) in a session whose default_transaction_read_only is on
# @description (Postgres refuses any write), under the TENANT row-level-security
# @description scope the hub uses. Every statement stands alone, so a sample past
# @description MEASURE_TIMEOUT_MS is counted as a timeout and the run goes on; and the
# @description action prints p50 / p95 / max of Postgres' own Execution Time,
# @description per query. The query shapes are the store's
# @description (store/search_postgres.go, door off): the message section
# @description (exact, rare, as-you-type prefix, accent-folded) and the topic
# @description section both BEFORE (full aggregate) and AFTER (topicCandidates
# @description prefilter), so one run gives the before/after pair.
# @description Network time and the hub's own work are not in these numbers.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant measured (e.g. seed-search)
# @param MEASURE_N (optional) - samples per query, 3..50, default 15
# @param MEASURE_ONLY (optional) - a comma list of query names; default all
# @param MEASURE_PLANS (optional) - 1 also prints one EXPLAIN (ANALYZE, BUFFERS) per query
# @param MEASURE_TIMEOUT_MS (optional) - per statement, 100..60000, default 5000 (the hub's budget is 2000)
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev TENANT_ID=seed-search ./run -a do_spl_search_measure
#------------------------------------------------------------------------------
do_spl_search_measure() {
  do_require_bin yq psql python3 || return 1
  local tenant="${TENANT_ID:-}" n="${MEASURE_N:-15}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$n" =~ ^[0-9]{1,2}$ ]] && ((n >= 3 && n <= 50)) || { do_log "FATAL MEASURE_N must be 3..50, got: $n"; return 1; }
  local to="${MEASURE_TIMEOUT_MS:-5000}"
  [[ "$to" =~ ^[0-9]{3,5}$ ]] && ((to >= 100 && to <= 60000)) || { do_log "FATAL MEASURE_TIMEOUT_MS must be 100..60000, got: $to"; return 1; }
  export MEASURE_TIMEOUT_MS="$to"
  spl_search_measure_sql "$tenant" "$n" "${MEASURE_ONLY:-}" "${MEASURE_PLANS:-0}" >/dev/null || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_search_measure_run "$tenant" "$n" "${MEASURE_ONLY:-}" "${MEASURE_PLANS:-0}"
}

# spl_search_measure_queries prints "<name>|<sql>" lines; @T@ is the tenant.
spl_search_measure_queries() {
  local msg_head="SELECT m.msg_id FROM messages m WHERE m.tenant_id = '@T@' AND m.expires_at > now() AND COALESCE((m.search_tsv @@ "
  local msg_tail="), false) ORDER BY m.received_at DESC, m.msg_id::text DESC LIMIT 6"
  local exact_common="plainto_tsquery('spool_search', 'deploy')"
  local exact_rare="plainto_tsquery('spool_search', 'term4242')"
  local prefix_rare="(NULLIF(plainto_tsquery('spool_search', 'term424')::text, '') || ':*')::tsquery"
  local prefix_short="(NULLIF(plainto_tsquery('spool_search', 'de')::text, '') || ':*')::tsquery"
  local accent="(NULLIF(plainto_tsquery('spool_search', 'cafe')::text, '') || ':*')::tsquery"
  echo "msg_common|$msg_head$exact_common$msg_tail"
  echo "msg_rare|$msg_head$exact_rare$msg_tail"
  echo "msg_prefix_rare|$msg_head$prefix_rare$msg_tail"
  echo "msg_prefix_short|$msg_head$prefix_short$msg_tail"
  echo "msg_accent|$msg_head$accent$msg_tail"
  local q
  for q in "common:$exact_common" "rare:$exact_rare" "prefix_rare:$prefix_rare"; do
    echo "topic_${q%%:*}_before|$(spl_search_measure_topic_sql "${q#*:}" "")"
    echo "topic_${q%%:*}_after|$(spl_search_measure_topic_sql "${q#*:}" " AND task_id IN (SELECT k.task_id FROM messages k WHERE k.tenant_id = '@T@' AND k.expires_at > now() AND k.search_tsv @@ ${q#*:})")"
  done
}

# spl_search_measure_topic_sql <tsquery> <candidate clause>: SearchTopics' SQL.
spl_search_measure_topic_sql() {
  local first=" ORDER BY received_at, msg_id)"
  printf '%s' "WITH live AS (SELECT task_id::text AS task_id, msg_id::text AS msg_id, received_at, kind, from_id, from_box, to_id, to_box, COALESCE(channel, '') AS channel, COALESCE(parent_task_id::text, '') AS parent, body, msg FROM messages WHERE tenant_id = '@T@' AND expires_at > now()$2), t AS (SELECT task_id, (array_agg(channel$first)[1] AS channel, (array_agg(parent$first)[1] AS parent, left(btrim(split_part((array_agg(body$first)[1], E'\\n', 1)), 140) AS title, min(received_at) AS first_at, max(received_at) AS last_at, count(*)::int AS n, array_agg(kind$first AS kinds, array_agg(from_id || '@' || from_box) || array_agg(to_id || '@' || to_box) AS parties, (array_agg(msg$first)[1] AS first_msg FROM live GROUP BY task_id) SELECT task_id, channel, parent, title, first_at, last_at, n FROM t WHERE COALESCE((to_tsvector('spool_search', t.title) @@ $1), false) ORDER BY last_at DESC, task_id DESC LIMIT 6"
}

# spl_search_measure_sql <tenant> <n> <only> <plans>: the psql script.
spl_search_measure_sql() {
  local tenant="$1" n="$2" only="$3" plans="$4" line name sql i found=0
  echo "SELECT set_config('app.tenant_id', '$tenant', false), set_config('statement_timeout', '${MEASURE_TIMEOUT_MS:-5000}', false), set_config('jit', 'off', false);"
  while IFS= read -r line; do
    name="${line%%|*}" sql="${line#*|}"
    [[ -z "$only" || ",$only," == *",$name,"* ]] || continue
    found=1
    sql="${sql//@T@/$tenant}"
    if [[ "$plans" == 1 ]]; then echo "\\echo @@plan $name"; echo "EXPLAIN (ANALYZE, BUFFERS) $sql;"; fi
    for ((i = 0; i < n; i++)); do
      echo "\\echo @@ $name"
      echo "EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF) $sql;"
    done
  done < <(spl_search_measure_queries)
  ((found)) || { do_log "FATAL MEASURE_ONLY names no query: $only"; return 1; }
}

# spl_search_measure_summary reads the psql output: p50 / p95 / max per query;
# a statement timeout is a sample too, printed as ">timeout" where it lands.
spl_search_measure_summary() {
  python3 -c '
import sys, re
cur, t, order = None, {}, []
for line in sys.stdin:
    s = line.strip()
    if s.startswith("@@plan"):
        cur = None  # a plan run is not a sample
        continue
    if s.startswith("@@ "):
        cur = s[3:]
        if cur not in t: t[cur] = []; order.append(cur)
    m = re.search(r"Execution Time: ([0-9.]+) ms", s)
    if m and cur: t[cur].append(float(m.group(1)))
    if cur and "canceling statement due to statement timeout" in s: t[cur].append(float("inf"))
print("%-26s %4s %9s %9s %9s %8s" % ("query", "n", "p50 ms", "p95 ms", "max ms", "timeouts"))
f = lambda x: ">timeout" if x == float("inf") else "%.1f" % x
for k in order:
    v = sorted(t[k]); n = len(v)
    if not n: continue
    p = lambda q: v[min(n - 1, int(round(q * (n - 1))))]
    print("%-26s %4d %9s %9s %9s %8d" % (k, n, f(p(0.5)), f(p(0.95)), f(v[-1]), sum(1 for x in v if x == float("inf"))))
'
}

_spl_search_measure_run() {
  local out
  # No ON_ERROR_STOP: a timed-out sample is a result, not the end of the run.
  out="$(spl_search_measure_sql "$@" | PGOPTIONS='-c default_transaction_read_only=on' \
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -P pager=off -f - 2>&1)"
  grep -q "Execution Time" <<<"$out" || { printf '%s\n' "$out" | tail -5; do_log "FATAL no sample was measured"; return 1; }
  [[ "${4:-0}" == 1 ]] && printf '%s\n' "$out" | awk '/^@@plan/{p=1} /^@@ /{p=0} p'
  printf '%s\n' "$out" | spl_search_measure_summary
}
