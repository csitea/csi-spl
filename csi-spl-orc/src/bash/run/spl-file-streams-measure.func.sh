#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 160 row B7 (case C24): measure the file stream limits on
# @description a cloud hub before their cnf defaults are final. Steps, picked
# @description by MEASURE_STEPS (default fill,size,time,conns):
# @description   fill  - the probe box (do_spl_box_msg_probe pinned it) announces
# @description           MEASURE_STREAMS keys b7-measure-<n> and pushes synthetic
# @description           log lines through `spool file-streams push` (the box
# @description           follower's own verb) until it has pushed MEASURE_LINES
# @description           lines. Each line's `at` lies in the last
# @description           MEASURE_LINES / MEASURE_STREAMS / MEASURE_RATE minutes,
# @description           MEASURE_RATE lines per minute per stream (under the
# @description           hub's 2 x 600 refusal), so the fill takes minutes, not
# @description           an hour. Lines are seeded, deterministic, one in
# @description           1000 carries the word b7needle, one in 3 the word tick
# @description   size  - via do_spl_db_query (read only): the lines kept, the
# @description           mean text bytes, the table + toast + index bytes and
# @description           the bytes per stored line
# @description   time  - MEASURE_N runs (>= 5) of EXPLAIN ANALYZE of the hub's
# @description           own in:file-streams statement (searchFileLinesSQL,
# @description           LIMIT 21) for an absent word, b7needle and tick; the
# @description           execution ms of each run, then min / median / max.
# @description           MEASURE_MATCH=text times the match the hub had
# @description           before row B7 (to_tsvector(l.text)), tsv (default)
# @description           the stored l.search_tsv the hub matches since
# @description   conns - SHOW max_connections
# @description The lines stay until the hub's sweep removes them (7 days, or
# @description the caps). Dry run unless DRY_RUN=0 (it gates the fill only:
# @description the other steps read).
# @param ENV - required: dev (any other env is refused: the fill is dev-only)
# @param TENANT_ID - required: the tenant the probe box is pinned in
# @param PROBE_BOX (optional) - default box-orc-probe
# @param MEASURE_STEPS (optional) - comma list of fill,size,time,conns
# @param MEASURE_LINES (optional) - 1000..500000, default 500000
# @param MEASURE_STREAMS (optional) - 1..8, default 8
# @param MEASURE_RATE (optional) - lines per minute per stream, 1..1200, default 1000
# @param MEASURE_N (optional) - runs per timed query, 5..50, default 5
# @param MEASURE_MATCH (optional) - tsv (default: l.search_tsv, as the hub) or text (to_tsvector(l.text), before row B7)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=spool DRY_RUN=0 ./run -a do_spl_file_streams_measure
# @example ENV=dev TENANT_ID=spool MEASURE_STEPS=time,size ./run -a do_spl_file_streams_measure
#------------------------------------------------------------------------------
do_spl_file_streams_measure() {
  do_require_bin python3 yq || return 1
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL ENV must be dev: the B7 fill writes lines into a workspace (got '${ENV:-}')"; return 1; }
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-orc-probe}" steps="${MEASURE_STEPS:-fill,size,time,conns}"
  local lines="${MEASURE_LINES:-500000}" streams="${MEASURE_STREAMS:-8}" rate="${MEASURE_RATE:-1000}" n="${MEASURE_N:-5}" s
  spl_fsm_num MEASURE_LINES "$lines" 1000 500000 && spl_fsm_num MEASURE_STREAMS "$streams" 1 8 \
    && spl_fsm_num MEASURE_RATE "$rate" 1 1200 && spl_fsm_num MEASURE_N "$n" 5 50 || return 1
  for s in ${steps//,/ }; do
    [[ "$s" =~ ^(fill|size|time|conns)$ ]] || { do_log "FATAL MEASURE_STEPS: unknown step '$s' (fill,size,time,conns)"; return 1; }
  done
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL PROBE_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  spl_require_tenant_slug "$tenant" || return 1
  do_spl_cloud_cnf || return 1
  for s in ${steps//,/ }; do
    "spl_fsm_$s" "$tenant" "$box" "$lines" "$streams" "$rate" "$n" || return 1
  done
}

spl_fsm_num() {  # NAME VALUE MIN MAX
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= $3 && $2 <= $4 )) && return 0
  do_log "FATAL $1 must be $3..$4, got: '$2'"; return 1
}

spl_fsm_fill() {  # TENANT BOX LINES STREAMS RATE
  local tenant="$1" box="$2" lines="$3" streams="$4" rate="$5" dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local hub d="$SPL_STATE_DIR/probe/$tenant/$box"
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  if (( dry )); then
    do_log "INFO DRY_RUN would: push $lines lines in $streams streams b7-measure-<n> from $box to $hub as tenant $tenant, $rate lines a minute per stream"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to fill."
    return 0
  fi
  [[ -f "$d/pinned" ]] || { do_log "FATAL $box is not pinned under $tenant ($d/pinned missing): run do_spl_box_msg_probe first"; return 1; }
  spl_host_spool || return 1
  _fsm_spool() { SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" "$SPL_SPOOL" "$@"; }
  local frame out pushed=0 next=50000 t0 rc=0
  t0=$(date +%s)
  while IFS= read -r frame; do
    out="$(_fsm_spool file-streams push --json - <<<"$frame" 2>&1)" || { rc=1; do_log "FAIL push after $pushed lines: $out"; break; }
    pushed=$((pushed + $(yq -p json -r '.inserted // 0' <<<"$out")))
    (( pushed >= next )) && { do_log "INFO pushed $pushed lines ($(( $(date +%s) - t0 )) s)"; next=$((next + 50000)); }
  done < <(spl_fsm_frames "$lines" "$streams" "$rate")
  unset -f _fsm_spool
  (( rc == 0 )) || return 1
  do_log "OK fill: $pushed lines inserted into $tenant ($ENV) in $(( $(date +%s) - t0 )) s"
}

# spl_fsm_frames LINES STREAMS RATE: one JSON frame per line on stdout, the
# announce first, then pushes of at most 1000 lines per stream key, oldest
# first. seq = the line's minute since the epoch x 10000 + its index in that
# minute, so a re-run pushes new seqs (the hub keys on seq) in order.
spl_fsm_frames() {
  python3 - "$1" "$2" "$3" <<'EOF_PY'
import json, random, sys, time
total, streams, rate = (int(a) for a in sys.argv[1:4])
rnd = random.Random(160)
per = total // streams
minutes = -(-per // rate)
start = int(time.time()) // 60 - minutes
words = ["%s%s" % (rnd.choice("bcdfghjklmnprstvz"), "".join(rnd.choice("aeiouyrnstl") for _ in range(rnd.randint(2, 9)))) for _ in range(3000)]
weights = [1.0 / (i + 1) for i in range(len(words))]
levels = ["INFO"] * 8 + ["WARN", "ERROR"]
comps = ["token-burn", "cron", "spool", "hub-sync", "lane-rotate", "follower", "sweep", "deploy"]
def text(i):
    w = rnd.choices(words, weights, k=rnd.randint(4, 18))
    if i % 3 == 0:
        w.insert(0, "tick")
    if i % 1000 == 7:
        w.append("b7needle")
    kv = " ".join("%s=%d" % (rnd.choice(words), rnd.randint(0, 99999)) for _ in range(rnd.randint(0, 4)))
    return "%s %s[%d]: %s %s id=%08x" % (rnd.choice(levels), rnd.choice(comps), rnd.randint(100, 99999), " ".join(w), kv, rnd.getrandbits(32))
def push(k, batch):
    print(json.dumps({"lane_op": "file_streams_push", "stream_key": k, "lines": batch, "dropped": 0, "redactions": {}}))
keys = ["b7-measure-%d" % (s + 1) for s in range(streams)]
print(json.dumps({"lane_op": "file_streams_announce", "streams": [{"stream_key": k, "path": "/var/log/b7-measure/%s.log" % k, "state": "following"} for k in keys]}))
for k in keys:
    batch, made = [], 0
    for m in range(minutes):
        for j in range(min(rate, per - made)):
            at = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime((start + m) * 60 + j * 60 // rate)) + "Z"
            batch.append({"seq": (start + m) * 10000 + j + 1, "at": at, "text": text(made), "marker": False})
            made += 1
            if len(batch) == 1000:
                push(k, batch)
                batch = []
    if batch:
        push(k, batch)
EOF_PY
}

spl_fsm_q() {  # SQL: one read-only statement through do_spl_db_query, its rows only
  SQL="$1" do_spl_db_query 2>&1 | grep -vE '^(INFO|WARN) '
  return "${PIPESTATUS[0]}"
}

spl_fsm_size() {  # TENANT
  local t="$1"
  spl_fsm_q "SELECT (SELECT count(*) FROM file_stream_lines WHERE tenant_id = '$t') AS lines_tenant,
    (SELECT round(avg(octet_length(text)), 1) FROM file_stream_lines WHERE tenant_id = '$t') AS mean_text_bytes,
    (SELECT round(avg(pg_column_size(search_tsv)), 1) FROM file_stream_lines WHERE tenant_id = '$t') AS mean_tsv_bytes,
    (SELECT count(*) FROM file_stream_lines) AS lines_all,
    pg_table_size('file_stream_lines') AS table_bytes,
    pg_indexes_size('file_stream_lines') AS index_bytes,
    pg_total_relation_size('file_stream_lines') AS total_bytes,
    round(pg_total_relation_size('file_stream_lines')::numeric / greatest((SELECT count(*) FROM file_stream_lines), 1), 1) AS bytes_per_line"
}

# spl_fsm_time TENANT _ _ _ _ N: the statement of searchFileLinesSQL for
# `in:file-streams <word>`, with the tenant and the word as literals (the
# hub binds them) and LIMIT 21 (a page of 20 plus one). It runs in the
# operator scope of do_spl_db_query, not the hub's tenant scope.
spl_fsm_time() {
  local t="$1" n="$6" w i ms m
  local -a all
  case "${MEASURE_MATCH:-tsv}" in
    text) m="to_tsvector('spool_search', l.text)" ;;
    tsv) m="l.search_tsv" ;;
    *) do_log "FATAL MEASURE_MATCH must be text or tsv, got: '${MEASURE_MATCH:-}'"; return 1 ;;
  esac
  for w in b7absentword b7needle tick; do
    all=()
    for (( i = 1; i <= n; i++ )); do
      ms="$(spl_fsm_q "EXPLAIN (ANALYZE, FORMAT JSON) SELECT l.stream_id::text, s.box_id, s.stream_key, l.seq, l.at, l.text
        FROM file_stream_lines l
        JOIN file_streams s ON s.tenant_id = l.tenant_id AND s.id = l.stream_id
        WHERE l.tenant_id = '$t' AND s.tenant_id = '$t' AND NOT l.marker
          AND $m @@ plainto_tsquery('spool_search', '$w'::text)
        ORDER BY l.at DESC, l.stream_id::text DESC, l.seq DESC LIMIT 21" | grep -oE '"Execution Time": [0-9.]+' | grep -oE '[0-9.]+$')"
      [[ -n "$ms" ]] || { do_log "FAIL time: no Execution Time for '$w' run $i"; return 1; }
      all+=("$ms")
    done
    python3 - "$w" "${all[@]}" <<'EOF_PY'
import statistics, sys
w, ms = sys.argv[1], [float(x) for x in sys.argv[2:]]
print("time %-13s n=%d ms=%s min=%.0f median=%.0f max=%.0f" % (w, len(ms), ",".join("%.0f" % x for x in ms), min(ms), statistics.median(ms), max(ms)))
EOF_PY
  done
}

spl_fsm_conns() {
  spl_fsm_q "SHOW max_connections"
}
