#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY latency of the hub's HOT statements on one tenant
# @description (SPL-984, spec 029 §8; api perf round ap-00): the statements
# @description Query Insights ranks top by total time, each PREPAREd with the
# @description text the hub SENDS TODAY and run MEASURE_N times as EXPLAIN
# @description (ANALYZE) EXECUTE, so the plan cache behaves as it does under pgx
# @description (an untyped PREPARE, as pgx's Parse; custom plans first, then
# @description generic). The session is default_transaction_read_only=on
# @description (Postgres refuses any write) and takes the TENANT row-level-
# @description security scope the hub uses, as the hub's runtime login.
# @description Prints p50 / p95 / max of Postgres' own Execution Time per
# @description statement and the sha256 of every statement text it prepared.
# @description The texts are NOT hand copies: spl-db-hot-measure.stmt.sql beside
# @description this file is printed by the store's own builders
# @description (csi-spl-api internal/store/stmt_print_test.go), and its Go test
# @description goes red when a builder changes and the copy does not. Each
# @description statement runs under the hub's OWN session settings for it, read
# @description from the scope statement the hub sends first in its batch: the
# @description walks (walk_all, walk_dm: viewTopicsSQL as handleViewTopics calls
# @description it) under the walk scope (jit off, bitmap scans off, sorts off,
# @description custom plans); thread (the topic page, desc), flow_counts
# @description (FlowRead's counts), ch_counts / ch_marked / ch_hidden
# @description (ViewChannelStats' reads, no read= cursor) under the plain tenant
# @description scope (the server's defaults). Spec 099 T008: the head reads
# @description (viewTopicsHeadSQL) under the head scope (jit off, sorts and
# @description bitmap scans on, custom plans): walk_all_head, walk_dm_head,
# @description walk_dm_head_worst (the same DM page for the worst reader, the
# @description first channel member with no DM part, else a reader in none:
# @description the walk reads every DM head) and walk_parent_head (parent=, the
# @description children of the tenant's topic with the most child topics).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant measured (e.g. t1)
# @param READER - required: the human the read door is evaluated for (e.g. HUM-10)
# @param MEASURE_N (optional) - samples per statement, 3..50, default 10
# @param MEASURE_ONLY (optional) - a comma list of statement names; default all
# @param MEASURE_JIT (optional) - hub (default: the statement's own scope) | on | off | both
# @param MEASURE_BITMAPSCAN (optional) - hub (default) | on | off | both: enable_bitmapscan
# @param MEASURE_SORT (optional) - hub (default) | on | off | both: enable_sort
# @param MEASURE_PLAN_CACHE (optional) - hub (default) | auto | force_custom_plan | force_generic_plan
# @param   A setting other than hub applies to every measured statement and is
# @param   named in the row's tag (e.g. flow_counts.pc_auto.jit_off); all hub = .hub
# @param MEASURE_LOBBY (optional) - the lobby task uuid; default the cnf's
# @param   env.hub.env.SPOOL_HUB_LOBBY_TASK_ID (what the hub binds)
# @param MEASURE_PLANS (optional) - 1 also prints one EXPLAIN (ANALYZE, BUFFERS) per statement
# @param MEASURE_TIMEOUT_MS (optional) - per statement, 100..60000, default 10000
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd TENANT_ID=t1 READER=HUM-10 MEASURE_N=20 MEASURE_ONLY=walk_dm ./run -a do_spl_db_hot_measure
# @example ENV=prd TENANT_ID=t1 READER=HUM-10 MEASURE_N=20 MEASURE_JIT=both MEASURE_ONLY=flow_counts ./run -a do_spl_db_hot_measure
# @example ENV=dev TENANT_ID=t1 READER=HUM-4 MEASURE_ONLY=ch_hidden MEASURE_PLANS=1 ./run -a do_spl_db_hot_measure
# @example ENV=prd TENANT_ID=t1 READER=HUM-10 MEASURE_N=20 MEASURE_ONLY=walk_dm,walk_dm_head,walk_dm_head_worst,walk_parent_head ./run -a do_spl_db_hot_measure
#------------------------------------------------------------------------------
do_spl_db_hot_measure() {
  do_require_bin yq psql python3 sha256sum || return 1
  spl_db_hot_measure_sql "${TENANT_ID:-}" "${READER:-}" "${MEASURE_N:-10}" "${MEASURE_JIT:-hub}" \
    "${MEASURE_ONLY:-}" "${MEASURE_PLANS:-0}" "${MEASURE_LOBBY:-}" >/dev/null || return 1
  do_spl_cloud_cnf || return 1
  local lobby="${MEASURE_LOBBY:-}"
  [[ -n "$lobby" ]] || lobby="$(yq -r '.env.hub.env.SPOOL_HUB_LOBBY_TASK_ID // ""' "$SPL_CNF")" || return 1
  [[ "$lobby" != null ]] || lobby=""
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_db_hot_measure_run "${TENANT_ID:-}" "${READER:-}" "${MEASURE_N:-10}" "${MEASURE_JIT:-hub}" \
    "${MEASURE_ONLY:-}" "${MEASURE_PLANS:-0}" "$lobby"
}

# spl_db_hot_measure_stmt_file -> the builders' printed copy of the statements.
spl_db_hot_measure_stmt_file() {
  echo "${SPL_HOT_STMT_FILE:-$(dirname "${BASH_SOURCE[0]}")/spl-db-hot-measure.stmt.sql}"
}

# spl_db_hot_measure_names -> the statement names, one per line, in file order.
spl_db_hot_measure_names() {
  awk '/^-- @@stmt /{print $3}' "$(spl_db_hot_measure_stmt_file)"
}

# spl_db_hot_measure_field <name> <sha256|scope|exec> -> that header field.
spl_db_hot_measure_field() {
  awk -v n="$1" -v f="$2" '$1 == "--" && $2 == "@@stmt" && $3 == n {
    for (i = 4; i <= NF; i++) if (index($i, f "=") == 1) { print substr($i, length(f) + 2); exit } }' \
    "$(spl_db_hot_measure_stmt_file)"
}

# spl_db_hot_measure_body <name> -> the statement text, byte for byte the
# builder's (the lines after its @@scope line, up to the next @@stmt).
spl_db_hot_measure_body() {
  local body
  body="$(awk -v n="$1" '/^-- @@stmt /{p = ($3 == n); next} p && /^-- @@scope /{next} p' "$(spl_db_hot_measure_stmt_file)")"
  printf '%s' "$body"
}

# spl_db_hot_measure_headers -> one line per statement, in one pass:
# <name> <sha256> <scope> <exec> <jit> <enable_bitmapscan> <enable_sort>
# <plan_cache_mode>, each setting the value the hub's scope statement for it
# sets, or DEFAULT when the scope leaves it to the server.
spl_db_hot_measure_headers() {
  awk 'function f(k,   i) { for (i = 4; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2) }
    function g(k,   m) { if (match(sc, "set_config\\(\x27" k "\x27, \x27[a-z_]+\x27")) { m = substr(sc, RSTART, RLENGTH); sub(/.*, \x27/, "", m); sub(/\x27$/, "", m); return m } return "DEFAULT" }
    /^-- @@stmt / { n = $3; h = n " " f("sha256") " " f("scope") " " f("exec"); next }
    /^-- @@scope / && n != "" { sc = $0; print h, g("jit"), g("enable_bitmapscan"), g("enable_sort"), g("plan_cache_mode"); n = "" }' \
    "$(spl_db_hot_measure_stmt_file)"
}

# spl_db_hot_measure_check -> 0 when every statement's text still has the
# sha256 its builder printed (a hand edit of the copy is refused).
spl_db_hot_measure_check() {
  local name want have n=0
  while IFS= read -r name; do
    want="$(spl_db_hot_measure_field "$name" sha256)"
    have="$(spl_db_hot_measure_body "$name" | sha256sum | cut -d' ' -f1)"
    [[ -n "$want" && "$want" == "$have" ]] ||
      { do_log "FATAL $name's text in $(spl_db_hot_measure_stmt_file) is not its builder's (sha256 $have, printed $want)" >&2; return 1; }
    n=$((n + 1))
  done < <(spl_db_hot_measure_names)
  ((n > 0)) || { do_log "FATAL no statement in $(spl_db_hot_measure_stmt_file)" >&2; return 1; }
}

# spl_db_hot_measure_knob <env-name> <value> <allowed...> -> the values one
# MEASURE_* knob expands to (both = on off), one per line; refuses the rest.
spl_db_hot_measure_knob() {
  local name="$1" v="$2"
  shift 2
  [[ "$v" == both && " $* " == *" on "* ]] && { printf '%s\n' on off; return 0; }
  [[ " $* " == *" $v "* ]] || { do_log "FATAL $name must be one of: $* (or both for on/off), got: $v" >&2; return 1; }
  echo "$v"
}

# spl_db_hot_measure_set <name> <guc> <knob value> <tag prefix> -> the SET for
# guc before name's samples: the hub's own value when the knob is hub, else
# the knob's, which is then named in the caller's tag.
spl_db_hot_measure_set() {
  local v="$3"
  if [[ "$v" == hub ]]; then
    v="${_hm_set[$1.$2]:-DEFAULT}"
  else
    tag+=".$4${v#force_}"
  fi
  echo "SET $2 = $v;"
}

# spl_db_hot_measure_head_args <tenant> <names...> -> spec 099 T008's psql
# arguments (the worst reader, the parent), read only when their statement is
# measured: they read topic_head_parts, which no older statement needs.
spl_db_hot_measure_head_args() {
  local tenant="$1"
  shift
  if [[ " $* " == *" walk_dm_head_worst "* ]]; then
    echo "SELECT COALESCE((SELECT c.human_id FROM channel_humans c WHERE c.tenant_id = '$tenant' AND NOT EXISTS (SELECT 1 FROM topic_head_parts e WHERE e.tenant_id = '$tenant' AND e.channel IS NULL AND (e.dm_a = c.human_id OR e.dm_b = c.human_id)) ORDER BY c.human_id LIMIT 1), 'HUM-0') AS w \\gset"
    echo "SELECT COALESCE(array_agg(channel_id ORDER BY channel_id), '{}')::text AS wmine FROM channel_humans WHERE tenant_id = '$tenant' AND human_id = :'w' \\gset"
    echo "\\echo @@args worst=:w wmine=:wmine"
  fi
  if [[ " $* " == *" walk_parent_head "* ]]; then
    echo "SELECT COALESCE((SELECT parent_task_id::text FROM messages WHERE tenant_id = '$tenant' AND parent_task_id IS NOT NULL GROUP BY parent_task_id ORDER BY count(DISTINCT task_id) DESC, parent_task_id::text LIMIT 1), '00000000-0000-0000-0000-000000000000') AS parent \\gset"
    echo "\\echo @@args parent=:parent"
  fi
}

# spl_db_hot_measure_sql <tenant> <reader> <n> <jit> <only> <plans> [lobby] -> the psql script.
spl_db_hot_measure_sql() {
  local tenant="$1" reader="$2" n="$3" jit="$4" only="$5" plans="$6" lobby="${7:-}" to="${MEASURE_TIMEOUT_MS:-10000}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'" >&2; return 1; }
  [[ "$reader" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { do_log "FATAL READER must be a human id (e.g. HUM-10), got: '$reader'" >&2; return 1; }
  [[ "$n" =~ ^[0-9]{1,2}$ ]] && ((n >= 3 && n <= 50)) || { do_log "FATAL MEASURE_N must be 3..50, got: $n" >&2; return 1; }
  [[ "$to" =~ ^[0-9]{3,5}$ ]] && ((to >= 100 && to <= 60000)) || { do_log "FATAL MEASURE_TIMEOUT_MS must be 100..60000, got: $to" >&2; return 1; }
  [[ -z "$lobby" || "$lobby" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL MEASURE_LOBBY must be a lowercase uuid, got: '$lobby'" >&2; return 1; }
  local -a jits bms sorts
  local pc
  mapfile -t jits < <(spl_db_hot_measure_knob MEASURE_JIT "$jit" hub on off) && ((${#jits[@]})) || return 1
  mapfile -t bms < <(spl_db_hot_measure_knob MEASURE_BITMAPSCAN "${MEASURE_BITMAPSCAN:-hub}" hub on off) && ((${#bms[@]})) || return 1
  mapfile -t sorts < <(spl_db_hot_measure_knob MEASURE_SORT "${MEASURE_SORT:-hub}" hub on off) && ((${#sorts[@]})) || return 1
  pc="$(spl_db_hot_measure_knob MEASURE_PLAN_CACHE "${MEASURE_PLAN_CACHE:-hub}" hub auto force_custom_plan force_generic_plan)" || return 1
  spl_db_hot_measure_check || return 1
  local name
  local -a names=()
  mapfile -t names < <(spl_db_hot_measure_names)
  if [[ -n "$only" ]]; then
    for name in ${only//,/ }; do
      [[ " ${names[*]} " == *" $name "* ]] || { do_log "FATAL MEASURE_ONLY names no statement: $name (have: ${names[*]})" >&2; return 1; }
    done
    local -a keep=()
    for name in "${names[@]}"; do [[ ",$only," == *",$name,"* ]] && keep+=("$name"); done
    names=("${keep[@]}")
  fi
  echo "SELECT set_config('app.tenant_id', '$tenant', false), set_config('statement_timeout', '$to', false);"
  echo "\\set t '$tenant'"
  echo "\\set r '$reader'"
  echo "\\set lobby '$lobby'"
  echo "\\set pub '$(awk '/^-- @@pub /{print $3; exit}' "$(spl_db_hot_measure_stmt_file)")'"
  # The reader's channels and the tenant's biggest topic: the real arguments,
  # read in the same tenant scope the statements run in.
  echo "SELECT COALESCE(array_agg(channel_id ORDER BY channel_id), '{}')::text AS mine FROM channel_humans WHERE tenant_id = '$tenant' AND human_id = '$reader' \\gset"
  echo "SELECT COALESCE((SELECT task_id::text FROM messages WHERE tenant_id = '$tenant' GROUP BY task_id ORDER BY count(*) DESC LIMIT 1), '00000000-0000-0000-0000-000000000000') AS task \\gset"
  echo "\\echo @@args tenant=:t reader=:r mine=:mine task=:task lobby=:lobby"
  spl_db_hot_measure_head_args "$tenant" "${names[@]}"
  # Read each statement's header once: the script has n x settings lines per statement.
  local -A _hm_exec=() _hm_set=()
  local h_sum h_scope h_exec h_jit h_bm h_sort h_pc
  while read -r name h_sum h_scope h_exec h_jit h_bm h_sort h_pc; do
    [[ " ${names[*]} " == *" $name "* ]] || continue
    echo "\\echo @@stmt $name sha256=$h_sum scope=$h_scope"
    _hm_exec[$name]="$h_exec"
    _hm_set[$name.jit]="$h_jit" _hm_set[$name.enable_bitmapscan]="$h_bm"
    _hm_set[$name.enable_sort]="$h_sort" _hm_set[$name.plan_cache_mode]="$h_pc"
  done < <(spl_db_hot_measure_headers)
  for name in "${names[@]}"; do
    printf 'PREPARE %s AS %s;\n' "$name" "$(spl_db_hot_measure_body "$name")"
  done
  local j b so tag i
  for so in "${sorts[@]}"; do
    for b in "${bms[@]}"; do
      for j in "${jits[@]}"; do
        for name in "${names[@]}"; do
          tag=""
          spl_db_hot_measure_set "$name" jit "$j" jit_ || return 1
          spl_db_hot_measure_set "$name" enable_bitmapscan "$b" bitmap_ || return 1
          spl_db_hot_measure_set "$name" enable_sort "$so" sort_ || return 1
          spl_db_hot_measure_set "$name" plan_cache_mode "$pc" pc_ || return 1
          tag="${tag:-.hub}"
          if [[ "$plans" == 1 ]]; then
            echo "\\echo @@plan $name$tag"
            echo "EXPLAIN (ANALYZE, BUFFERS) EXECUTE $name(${_hm_exec[$name]});"
          fi
          for ((i = 0; i < n; i++)); do
            echo "\\echo @@ $name$tag"
            echo "EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF) EXECUTE $name(${_hm_exec[$name]});"
          done
        done
      done
    done
  done
}

_spl_db_hot_measure_run() {
  local out
  # No ON_ERROR_STOP: a timed-out sample is a result, not the end of the run.
  out="$(spl_db_hot_measure_sql "$@" | PGOPTIONS='-c default_transaction_read_only=on' \
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -P pager=off -f - 2>&1)"
  grep -q "Execution Time" <<<"$out" || { printf '%s\n' "$out" | tail -8; do_log "FATAL no sample was measured"; return 1; }
  printf '%s\n' "$out" | grep '^@@args' | sed 's/^@@args /args: /'
  printf '%s\n' "$out" | grep '^@@stmt' | sed 's/^@@stmt /statement: /'
  printf '%s\n' "$out" | grep -E '^(ERROR|FATAL)' | sort | uniq -c
  [[ "${6:-0}" == 1 ]] && printf '%s\n' "$out" | awk '/^@@plan/{p=1} /^@@ /{p=0} p'
  printf '%s\n' "$out" | spl_search_measure_summary
}
