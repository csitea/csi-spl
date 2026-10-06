#!/bin/bash
#------------------------------------------------------------------------------
# @description P0 of spec 100 (search index, T001): prove S1r on Cloud SQL
# @description DEV inside ONE transaction that always ends in ROLLBACK, so dev
# @description ends unchanged. As the schema owner (the migrate login, the
# @description do_spl_db_bootstrap path) through the Cloud SQL proxy it runs
# @description the P1 DDL of spec section 9, one step at a time, each step
# @description reported ok or with its error (psql ON_ERROR_ROLLBACK: a failed
# @description step is undone and the next one still runs):
# @description   role     spool_search_reader NOLOGIN NOBYPASSRLS
# @description   grant    column SELECT on messages to it
# @description   ext      CREATE EXTENSION IF NOT EXISTS btree_gin      (G6)
# @description   index    messages_search USING gin (tenant_id, search_tsv),
# @description            timed; plain CREATE INDEX holds a SHARE lock   (G2)
# @description   fn       spool_search_candidates, spec section 5.1
# @description   fn_grant EXECUTE to the runtime login, none to PUBLIC
# @description   owner    ALTER FUNCTION ... OWNER TO spool_search_reader (G7);
# @description            on a refusal it retries after a self-grant WITH
# @description            SET TRUE (pg 16 needs SET on the new owner), then
# @description            after GRANT CREATE ON SCHEMA public to the new
# @description            owner (an owner needs CREATE on its schema), and
# @description            reports each, so T002 knows which ones it needs
# @description   policy   search_reader_all FOR SELECT TO it USING (true);
# @description            last, because CREATE POLICY holds an ACCESS
# @description            EXCLUSIVE lock on messages until the ROLLBACK
# @description Then SET LOCAL ROLE to the runtime login (the same self-grant
# @description fallback) and EXPLAIN (ANALYZE, BUFFERS) a rare-word
# @description spool_search_candidates call (G1). A SECURITY DEFINER body is
# @description never inlined, so the outer plan shows a Function Scan: the
# @description index the call used is read from pg_stat_get_xact_numscans
# @description (this transaction's scans of messages_search, before and
# @description after), and the body's own plan is EXPLAINed as
# @description spool_search_reader. Insert cost (G3 dev): PROBE_N inserts of
# @description PROBE_BODY_CHARS-char bodies cut from the tenant's own latest
# @description bodies (real text), each a copy of the tenant's latest row
# @description with a new msg_id, timed one by one before the index exists
# @description and again after it; p50 / p95 of each (2 warm-up rows per
# @description phase are not counted). A second, read-only session afterwards
# @description shows the role, index and function are absent again.
# @description Locks on dev while it runs: SHARE on messages (hub writes wait)
# @description from the index step to the ROLLBACK, ACCESS EXCLUSIVE for the
# @description last second. lock_timeout (PROBE_LOCK_TIMEOUT) bounds each wait.
# @description ENV=prd is REFUSED: prd gets P1 only through rdb T002, with the
# @description owner's go.
# @param ENV - required: dev (prd is refused)
# @param TENANT_ID (optional) - the tenant probed, default t1
# @param PROBE_WORD (optional) - the rare word; default: a word found in one
# @param   of the tenant's latest 2000 messages only
# @param PROBE_N (optional) - timed inserts per phase, 20..200, default 20
# @param PROBE_CAP (optional) - the function's cap, default 500 (spec 5.1)
# @param PROBE_BODY_CHARS (optional) - insert body length, 1024..8192, default 3072
# @param PROBE_LOCK_TIMEOUT (optional) - lock_timeout for the DDL, default 5s
# @param PROBE_STATEMENT_TIMEOUT (optional) - default 10min
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_search_index_probe
# @example ENV=dev TENANT_ID=t1 PROBE_N=40 ./run -a do_spl_search_index_probe
#------------------------------------------------------------------------------
do_spl_search_index_probe() {
  spl_search_index_probe_check || return 1
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  if [[ "$(do_spl_cloud_provider)" != none ]]; then
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  [[ "$SPL_DB_USER" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
    { do_log "FATAL cnf hub.db_user '$SPL_DB_USER' is not a plain role name"; return 1; }
  local owner_dsn user
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" ]] || { do_log "FATAL cannot read $SPL_OWNER_DSN_SECRET: the probe's DDL needs the schema owner"; return 1; }
  user="$(spl_dsn_user "$owner_dsn")"
  [[ "$user" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_OWNER_DSN_SECRET logs in as '$user', not the owner $SPL_DB_OWNER_USER"; return 1; }
  local rc=0 pdsn out
  spl_sql_proxy_start || return 1
  pdsn="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the owner DSN is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; return 1; }
  do_log "INFO $ENV: one transaction as $user, ROLLBACK at the end; runtime login $SPL_DB_USER"
  # Never psql -1 / --single-transaction: that COMMITs. No ON_ERROR_STOP: a
  # failed step is a result, and the script must reach its ROLLBACK.
  out="$(spl_search_index_probe_sql "${TENANT_ID:-t1}" "$SPL_DB_USER" "${PROBE_WORD:-}" |
    spl_pg_env "$pdsn" psql -X -q -At -P pager=off -f - 2>&1)" || rc=1
  printf '%s\n' "$out"
  spl_pg_env "$pdsn" psql -X -q -At -P pager=off -c "$(spl_search_index_probe_after_sql)" 2>&1 || rc=1
  spl_sql_proxy_stop
  grep -qx '@@rolled_back' <<<"$out" ||
    { do_log "FATAL the probe script did not reach its ROLLBACK (the server rolls an open transaction back on disconnect)"; return 1; }
  spl_search_index_probe_verdict <<<"$out"
  return $rc
}

# spl_search_index_probe_check -> 0 when ENV is dev and every PROBE_* knob is
# well formed; refuses prd before any cnf, gcloud or psql call.
spl_search_index_probe_check() {
  [[ "${ENV:-}" != prd ]] ||
    { do_log "FATAL ENV=prd is refused: the probe runs DDL (rolled back) on dev only; prd gets P1 through rdb T002 with the owner's go"; return 1; }
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev, got '${ENV:-}'"; return 1; }
  [[ "${TENANT_ID:-t1}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got '${TENANT_ID:-}'"; return 1; }
  [[ -z "${PROBE_WORD:-}" || "$PROBE_WORD" =~ ^[a-z0-9]{2,40}$ ]] || { do_log "FATAL PROBE_WORD must be one lowercase word, got '$PROBE_WORD'"; return 1; }
  local n="${PROBE_N:-20}" cap="${PROBE_CAP:-500}" b="${PROBE_BODY_CHARS:-3072}"
  [[ "$n" =~ ^[0-9]{2,3}$ ]] && ((n >= 20 && n <= 200)) || { do_log "FATAL PROBE_N must be 20..200, got '$n'"; return 1; }
  [[ "$cap" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL PROBE_CAP must be 1..99999, got '$cap'"; return 1; }
  [[ "$b" =~ ^[0-9]{4}$ ]] && ((b >= 1024 && b <= 8192)) || { do_log "FATAL PROBE_BODY_CHARS must be 1024..8192, got '$b'"; return 1; }
  [[ "${PROBE_LOCK_TIMEOUT:-5s}" =~ ^[0-9]+(ms|s)$ ]] || { do_log "FATAL PROBE_LOCK_TIMEOUT must look like 5s or 500ms, got '${PROBE_LOCK_TIMEOUT:-}'"; return 1; }
  [[ "${PROBE_STATEMENT_TIMEOUT:-10min}" =~ ^[0-9]+(s|min)$ ]] || { do_log "FATAL PROBE_STATEMENT_TIMEOUT must look like 600s or 10min, got '${PROBE_STATEMENT_TIMEOUT:-}'"; return 1; }
}

# spl_search_index_probe_step <name> <sql> -> the statement, then one line
# "@@step <name> ok" or "@@step <name> error <message>" (psql's own ERROR).
spl_search_index_probe_step() {
  printf '%s\n' "$2"
  printf '\\if :ERROR\n  \\echo @@step %s error :LAST_ERROR_MESSAGE\n\\else\n  \\echo @@step %s ok\n\\endif\n' "$1" "$1"
}

# spl_search_index_probe_inserts <tenant> <phase> <n> <chars> -> a DO block
# timing n + 2 inserts (2 warm-up rows not kept) into pg_temp.spl_probe_ins.
spl_search_index_probe_inserts() {
  cat <<EOF_SQL
DO \$probe\$
DECLARE
  cols text; src uuid; pool text; t0 timestamptz; i int;
BEGIN
  SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols FROM pg_attribute
   WHERE attrelid = 'public.messages'::regclass AND attnum > 0 AND NOT attisdropped
     AND attgenerated = '' AND attname NOT IN ('msg_id', 'body', 'received_at');
  SELECT msg_id INTO src FROM public.messages WHERE tenant_id = '$1' ORDER BY received_at DESC LIMIT 1;
  IF src IS NULL THEN RAISE EXCEPTION 'tenant $1 has no message to copy'; END IF;
  SELECT string_agg(body, ' ') INTO pool FROM (SELECT body FROM public.messages
   WHERE tenant_id = '$1' ORDER BY received_at DESC LIMIT 2000) b;
  pool := repeat(pool || ' ', ceil(($3 + 3) * $4.0 / greatest(length(pool), 1))::int);
  FOR i IN 1..$3 + 2 LOOP
    t0 := clock_timestamp();
    EXECUTE format('INSERT INTO public.messages (msg_id, body, received_at, %s) SELECT gen_random_uuid(), \$1, clock_timestamp(), %s FROM public.messages WHERE tenant_id = \$2 AND msg_id = \$3', cols, cols)
      USING substr(pool, 1 + (i - 1) * $4, $4), '$1', src;
    IF i > 2 THEN
      INSERT INTO pg_temp.spl_probe_ins VALUES ('$2', extract(epoch FROM clock_timestamp() - t0) * 1000);
    END IF;
  END LOOP;
END
\$probe\$;
EOF_SQL
}

# spl_search_index_probe_sql <tenant> <runtime role> [word] -> the psql script:
# BEGIN, the steps, ROLLBACK. ROLLBACK is the last SQL statement on every path.
spl_search_index_probe_sql() {
  local t="$1" rt="$2" word="${3:-}" n="${PROBE_N:-20}" b="${PROBE_BODY_CHARS:-3072}"
  cat <<EOF_SQL
\\set ON_ERROR_STOP 0
\\set ON_ERROR_ROLLBACK on
BEGIN;
SELECT set_config('app.tenant_id', '$t', true), set_config('lock_timeout', '${PROBE_LOCK_TIMEOUT:-5s}', true),
       set_config('statement_timeout', '${PROBE_STATEMENT_TIMEOUT:-10min}', true) \\g /dev/null
EOF_SQL
  spl_search_index_probe_head "$t" "$word"
  spl_search_index_probe_step ins_noindex "$(spl_search_index_probe_inserts "$t" noindex "$n" "$b")"
  # The inserts queue deferred trigger events (change_stamp), and CREATE INDEX
  # refuses a table with pending ones: fire them now, then defer again.
  echo "SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;"
  spl_search_index_probe_ddl "$rt"
  spl_search_index_probe_step ins_index "$(spl_search_index_probe_inserts "$t" index "$n" "$b")"
  cat <<EOF_SQL
SELECT '@@ins ' || phase || ' n=' || count(*) || ' p50_ms=' || round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 2)
    || ' p95_ms=' || round(percentile_cont(0.95) WITHIN GROUP (ORDER BY ms)::numeric, 2)
    || ' max_ms=' || round(max(ms)::numeric, 2)
  FROM pg_temp.spl_probe_ins GROUP BY phase ORDER BY phase DESC;
EOF_SQL
  spl_search_index_probe_step policy "CREATE POLICY search_reader_all ON public.messages FOR SELECT TO spool_search_reader USING (true);"
  spl_search_index_probe_plans "$rt" "${PROBE_CAP:-500}"
  cat <<EOF_SQL
ROLLBACK;
\\echo @@rolled_back
EOF_SQL
}

# spl_search_index_probe_head <tenant> [word] -> the context line, the
# timing table and the rare word (psql :w), picked before the probe's own
# inserts, which copy recent bodies.
spl_search_index_probe_head() {
  local t="$1" word="${2:-}"
  cat <<EOF_SQL
SELECT '@@ctx login=' || current_user || ' server=' || current_setting('server_version')
    || ' messages_rows~' || (SELECT reltuples::bigint FROM pg_class WHERE oid = 'public.messages'::regclass)
    || ' btree_gin_available=' || COALESCE((SELECT default_version FROM pg_available_extensions WHERE name = 'btree_gin'), 'none')
    || ' btree_gin_installed=' || COALESCE((SELECT extversion FROM pg_extension WHERE extname = 'btree_gin'), 'no')
    || ' reader_role=' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_search_reader')
    || ' index=' || COALESCE(to_regclass('public.messages_search')::text, 'none')
    || ' fn=' || COALESCE(to_regprocedure('public.spool_search_candidates(tsquery,integer)')::text, 'none');
CREATE TEMP TABLE spl_probe_ins (phase text, ms float8);
EOF_SQL
  if [[ -n "$word" ]]; then
    echo "\\set w '$word'"
  else
    cat <<EOF_SQL
SELECT COALESCE((SELECT word FROM ts_stat(\$s\$SELECT search_tsv FROM public.messages WHERE tenant_id = '$t' ORDER BY received_at DESC LIMIT 2000\$s\$)
  WHERE ndoc = 1 AND word ~ '^[a-z]{7,30}\$' ORDER BY word LIMIT 1), 'zzqprobe') AS w \\gset
EOF_SQL
  fi
}

# spl_search_index_probe_ddl <runtime role> -> the P1 DDL steps (spec 100
# section 9) but the policy, with the OWNER TO fallbacks.
spl_search_index_probe_ddl() {
  local rt="$1"
  spl_search_index_probe_step role "CREATE ROLE spool_search_reader NOLOGIN NOBYPASSRLS;"
  spl_search_index_probe_step grant "GRANT SELECT (tenant_id, msg_id, received_at, search_tsv) ON public.messages TO spool_search_reader;"
  spl_search_index_probe_step ext "CREATE EXTENSION IF NOT EXISTS btree_gin;"
  echo "SELECT clock_timestamp() AS probe_t0 \\gset"
  spl_search_index_probe_step index "CREATE INDEX messages_search ON public.messages USING gin (tenant_id, search_tsv);"
  cat <<EOF_SQL
SELECT '@@build_ms ' || round(extract(epoch FROM clock_timestamp() - :'probe_t0'::timestamptz) * 1000)
    || ' index_bytes=' || COALESCE(pg_relation_size(to_regclass('public.messages_search'))::text, 'none');
EOF_SQL
  spl_search_index_probe_step fn "CREATE FUNCTION public.spool_search_candidates(q tsquery, cap int)
    RETURNS TABLE (msg_id uuid, received_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER ROWS 200
    SET search_path = pg_catalog, public, pg_temp
AS \$fn\$
    SELECT m.msg_id, m.received_at FROM public.messages m
    WHERE m.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
      AND m.search_tsv @@ q
    LIMIT cap + 1
\$fn\$;"
  spl_search_index_probe_step fn_grant "REVOKE ALL ON FUNCTION public.spool_search_candidates(tsquery, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.spool_search_candidates(tsquery, int) TO $rt;"
  spl_search_index_probe_step owner "ALTER FUNCTION public.spool_search_candidates(tsquery, int) OWNER TO spool_search_reader;"
  echo "\\if :ERROR"
  spl_search_index_probe_step owner_self_grant "GRANT spool_search_reader TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;"
  spl_search_index_probe_step owner_after_grant "ALTER FUNCTION public.spool_search_candidates(tsquery, int) OWNER TO spool_search_reader;"
  echo "\\if :ERROR"
  spl_search_index_probe_step owner_schema_grant "GRANT CREATE ON SCHEMA public TO spool_search_reader;"
  spl_search_index_probe_step owner_after_schema_grant "ALTER FUNCTION public.spool_search_candidates(tsquery, int) OWNER TO spool_search_reader;"
  echo "\\endif"
  echo "\\endif"
}

# spl_search_index_probe_plans <runtime role> <cap> -> as the runtime login,
# EXPLAIN the call (G1) and count its index scans; as spool_search_reader,
# EXPLAIN the body. Ends at role reset, inside the transaction.
spl_search_index_probe_plans() {
  local rt="$1" cap="$2" q="plainto_tsquery('spool_search', :'w')"
  cat <<EOF_SQL
\\echo @@word :w
SELECT COALESCE(pg_stat_get_xact_numscans(to_regclass('public.messages_search'))::text, 'none') AS probe_idx0 \\gset
SET LOCAL ROLE $rt;
\\if :ERROR
EOF_SQL
  spl_search_index_probe_step rt_self_grant "GRANT $rt TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;"
  echo "SET LOCAL ROLE $rt;"
  echo "\\endif"
  cat <<EOF_SQL
SELECT current_user = '$rt' AS probe_as_rt \\gset
\\if :probe_as_rt
\\echo @@plan runtime begin
EXPLAIN (ANALYZE, BUFFERS) SELECT msg_id FROM public.spool_search_candidates($q, $cap);
\\if :ERROR
  \\echo @@step g1_call error :LAST_ERROR_MESSAGE
\\else
  \\echo @@step g1_call ok
\\endif
\\echo @@plan runtime end
\\else
\\echo @@step g1_call error not the runtime login: SET ROLE $rt refused
\\endif
RESET ROLE;
SELECT '@@idx_scan messages_search before=' || :'probe_idx0'
    || ' after=' || COALESCE(pg_stat_get_xact_numscans(to_regclass('public.messages_search'))::text, 'none');
SET LOCAL ROLE spool_search_reader;
\\if :ERROR
\\echo @@step body_plan error SET ROLE spool_search_reader refused
\\else
\\echo @@plan reader begin
EXPLAIN (ANALYZE, BUFFERS) SELECT m.msg_id, m.received_at FROM public.messages m
 WHERE m.tenant_id = NULLIF(current_setting('app.tenant_id', true), '') AND m.search_tsv @@ $q LIMIT $cap + 1;
\\echo @@plan reader end
RESET ROLE;
\\endif
EOF_SQL
}

# spl_search_index_probe_after_sql -> a read in a NEW session: none of the
# probe's objects survived the ROLLBACK.
spl_search_index_probe_after_sql() {
  cat <<'EOF_SQL'
SELECT '@@after_rollback reader_role=' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_search_reader')
    || ' index=' || COALESCE(to_regclass('public.messages_search')::text, 'none')
    || ' fn=' || COALESCE(to_regprocedure('public.spool_search_candidates(tsquery,integer)')::text, 'none')
EOF_SQL
}

# spl_search_index_probe_verdict <- the probe output -> one line per gap.
spl_search_index_probe_verdict() {
  awk '
    function p95(s) { if (match(s, /p95_ms=[0-9.]+/)) return substr(s, RSTART + 7, RLENGTH - 7); return "" }
    /^@@step / { st[$2] = $3 }
    /^@@build_ms / { build = $2 " ms, " $3 }
    /^@@ins / { ins[$2] = $0 }
    /^@@idx_scan / { split($3, x0, "="); split($4, x1, "="); used = x1[2] ~ /^[0-9]+$/ && x1[2] + 0 > (x0[2] ~ /^[0-9]+$/ ? x0[2] + 0 : 0) }
    /^@@plan reader begin/ { inr = 1 }
    /^@@plan reader end/ { inr = 0 }
    inr && /messages_search/ { rplan = 1 }
    END {
      print "G6 btree_gin: " (st["ext"] == "ok" ? "ok" : "FAILED")
      g7 = st["owner"] == "ok" ? "ok (direct)" : st["owner_after_grant"] == "ok" ? "ok only after GRANT spool_search_reader TO the owner WITH SET TRUE" : \
        st["owner_after_schema_grant"] == "ok" ? "ok only after GRANT spool_search_reader TO the owner WITH SET TRUE and GRANT CREATE ON SCHEMA public TO spool_search_reader" : "FAILED"
      print "G7 OWNER TO spool_search_reader: " g7
      print "G1 runtime call: " (st["g1_call"] == "ok" ? "ok" : "FAILED") \
        (st["rt_self_grant"] != "" ? " (SET ROLE to the runtime needed a self-grant: " st["rt_self_grant"] ")" : "") \
        ", messages_search scanned by the call: " (used ? "yes" : "NO") ", in the reader plan: " (rplan ? "yes" : "NO")
      print "G2 build: " (st["index"] == "ok" ? build : "FAILED")
      a = p95(ins["noindex"]); b = p95(ins["index"])
      print "G3 insert p95: no index " a " ms, with index " b " ms" (a != "" && b != "" ? ", delta " sprintf("%.2f", b - a) " ms" : "")
    }'
}
