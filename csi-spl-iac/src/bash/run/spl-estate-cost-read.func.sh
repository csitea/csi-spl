#!/bin/bash
#------------------------------------------------------------------------------
# @description Read the GCP billing export into the hub DB's cost_lines and
# @description cost_coverage (spec 123 section 4.2, build lane 2; rdb 0166).
# @description Read-only on GCP: one BigQuery query, as the dedicated reader SA
# @description (Q-2 = A), rows of every project LIKE env.cost.gcp.project_like.
# @description
# @description Identity of the read, never the owner account:
# @description   - a reader key on disk (COST_READER_KEY_FILE, default
# @description     $HOME/.gcp/.<org>/key-<export_project>-cost-reader.json) is
# @description     activated in a private CLOUDSDK_CONFIG; else
# @description   - the <ENV> project SA (do_gcp_pin_account) acts AS the reader
# @description     SA (--impersonate-service-account; the tokenCreator grant of
# @description     do_gcp_billing_export_setup).
# @description
# @description The window is the trailing env.cost.reread_days days ending DAY:
# @description the export lags and revises recent days. Per day:
# @description   - cost_lines, origin=billing_export, source=gcp, tenant_id NULL
# @description     (estate, operator scope): one row per (project[/box=<label>],
# @description     service) with credits netted, UPSERT on the 0166 key; a live
# @description     billing_export row of a read day this run did not return is
# @description     deleted (a revised day may lose a line). A re-run is a no-op.
# @description   - one cost_coverage row (day, gcp): ok | partial | missing with
# @description     the reason. An absent export, dataset, table or identity is
# @description     `missing`, never 0, and deletes nothing.
# @description Money: amount_micros + currency as billed; usd_micros from the
# @description export's own currency_conversion_rate (USD -> billing currency);
# @description eur_micros = the amount when the billing currency is EUR. No EUR
# @description rate source exists yet (spec 123 Q-6): a line billed in another
# @description currency is held back and the day reads `partial`, never 0.
# @description
# @description DRY_RUN=1 (default) reads the export and prints what it would
# @description write; DRY_RUN=0 writes, through the Cloud SQL proxy as the <ENV>
# @description project SA (csi-spl-orc spl_via_proxy, the runtime login) in the
# @description operator RLS scope. COST_DB_DSN (a local Postgres) skips the proxy.
# @param ENV - required: dev or prd, the hub DB written
# @param DAY (optional) - last UTC day of the window, default yesterday (UTC)
# @param DRY_RUN (optional) - 1 (default): read and print. 0: write the rows.
# @param COST_READER_KEY_FILE (optional) - the reader SA key
# @param COST_DB_DSN (optional) - write to this Postgres instead of <ENV>'s hub DB
# @example ENV=prd ./run -a do_spl_estate_cost_read
# @example ENV=prd DAY=2026-10-09 DRY_RUN=0 ./run -a do_spl_estate_cost_read
#------------------------------------------------------------------------------
do_spl_estate_cost_read() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 1; }
  local dry_run="${DRY_RUN:-1}"
  [[ "${dry_run}" == 0 || "${dry_run}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry_run}"; return 1; }
  local b
  for b in gcloud curl jq yq awk; do command -v "${b}" &>/dev/null || { do_log "FATAL ${b} is not installed"; return 1; }; done
  [[ "${dry_run}" == 1 ]] || command -v psql &>/dev/null || { do_log "FATAL psql is not installed"; return 1; }
  local day="${DAY:-$(date -u -d yesterday +%F)}"
  if [[ ! "${day}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$(date -u -d "${day}" +%F 2>/dev/null)" != "${day}" ]]; then
    do_log "FATAL DAY must be a UTC day YYYY-MM-DD, got: ${day}"; return 1
  fi

  do_resolve_oap ORG
  do_resolve_oap APP
  do_spl_cost_gcp_cnf || return 1
  local -a days=()
  local i
  for ((i = COST_REREAD_DAYS - 1; i >= 0; i--)); do days+=("$(date -u -d "${day} -${i} day" +%F)"); done

  local tmp run_id
  tmp=$(umask 077 && mktemp -d) || return 1
  run_id="estate-cost-read-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  do_log "INFO ENV=${ENV} window=${days[0]}..${day} (${COST_REREAD_DAYS} days) export=${COST_EXPORT_PROJECT}.${COST_DATASET} projects LIKE '${COST_PROJECT_LIKE}' reader=${COST_READER_EMAIL} DRY_RUN=${dry_run}"

  _spl_cost_read_export "${tmp}" "${days[0]}" "${day}"
  _spl_cost_sql "${tmp}" "${run_id}" "${days[@]}" >"${tmp}/apply.sql" || { rm -rf "${tmp}"; do_log "FATAL cannot build the cost SQL"; return 1; }
  _spl_cost_report "${tmp}"

  local rc=0
  if [[ "${dry_run}" == 1 ]]; then
    do_log "OK DRY_RUN complete: nothing was written. DRY_RUN=0 applies $(grep -c "'billing_export', '" "${tmp}/apply.sql") cost line(s) and ${COST_REREAD_DAYS} coverage row(s) to the ${ENV} hub DB."
  elif _spl_cost_db_apply "${tmp}/apply.sql"; then
    do_log "OK wrote the window ${days[0]}..${day} to the ${ENV} hub DB (run_id ${run_id})"
  else
    do_log "FATAL could not write the cost rows to the ${ENV} hub DB"; rc=1
  fi
  rm -rf "${tmp}"
  return "${rc}"
}

# _spl_cost_read_export <dir> <d0> <d1> - in a subshell (the identity it pins
# stays there): writes <dir>/rows.tsv (day project box service currency
# amount_micros usd_micros) and <dir>/frontier (the newest export day), or
# <dir>/fail with the reason the export could not be read.
_spl_cost_read_export() {
  (
    local dir="$1" d0="$2" d1="$3" out rc table GCP_BQ_TOKEN
    _spl_cost_fail() { printf '%s' "$1" >"${dir}/fail"; do_log "WARNING export not read: $1"; exit 0; }
    _spl_cost_reader_token "${dir}" || _spl_cost_fail "$(cat "${dir}/token-err" 2>/dev/null)"
    out=$(do_gcp_bq_api GET "projects/${COST_EXPORT_PROJECT}/datasets/${COST_DATASET}/tables?maxResults=1000"); rc=$?
    case "${rc}" in
      0) ;;
      4) _spl_cost_fail "dataset ${COST_EXPORT_PROJECT}.${COST_DATASET} not found: the export is not set up (do_gcp_billing_export_setup, spec 123 Q-3)" ;;
      3) _spl_cost_fail "${COST_READER_EMAIL} may not list ${COST_EXPORT_PROJECT}.${COST_DATASET} (permission, REPORT it): $(do_gcp_bq_error "${out}")" ;;
      *) _spl_cost_fail "cannot list ${COST_EXPORT_PROJECT}.${COST_DATASET}: $(do_gcp_bq_error "${out}")" ;;
    esac
    table=$(jq -r '[.tables[]?.tableReference.tableId | select(test("^gcp_billing_export_v1_[0-9A-Fa-f_]+$"))] | sort | .[0] // ""' <<<"${out}")
    [[ -n "${table}" ]] || _spl_cost_fail "no gcp_billing_export_v1_* table in ${COST_EXPORT_PROJECT}.${COST_DATASET}: the billing export is not turned on yet (spec 123 Q-3)"
    local fq="\`${COST_EXPORT_PROJECT}.${COST_DATASET}.${table}\`"
    _spl_cost_query "${dir}/rows.tsv" "$(_spl_cost_rows_sql "${fq}")" "${d0}" "${d1}" ||
      _spl_cost_fail "the cost query failed: $(cat "${dir}/q-err" 2>/dev/null)"
    _spl_cost_query "${dir}/frontier" "SELECT FORMAT_DATE('%F', MAX(DATE(usage_start_time))) FROM ${fq} WHERE DATE(usage_start_time) >= DATE_SUB(@d0, INTERVAL 31 DAY)" "${d0}" "${d1}" ||
      _spl_cost_fail "the export frontier query failed: $(cat "${dir}/q-err" 2>/dev/null)"
  )
}

# _spl_cost_reader_token <dir> - sets the caller's GCP_BQ_TOKEN to a token that
# acts as the reader SA, or writes <dir>/token-err and returns 1. Runs in the
# export subshell, not in $( ): the private gcloud config it pins must outlive it.
_spl_cost_reader_token() {
  local dir="$1" key tok err
  key="${COST_READER_KEY_FILE:-${HOME}/.gcp/.${COST_EXPORT_PROJECT%%-*}/key-${COST_EXPORT_PROJECT}-cost-reader.json}"
  if [[ -f "${key}" ]]; then
    unset ACCOUNT GCP_ACCOUNT
    GCP_SA_KEY_FILE="${key}" do_gcp_pin_account || { echo "cannot activate the reader key ${key}" >"${dir}/token-err"; return 1; }
    [[ "${GCP_ACCOUNT}" == "${COST_READER_EMAIL}" ]] || { echo "the key ${key} is ${GCP_ACCOUNT}, not ${COST_READER_EMAIL}" >"${dir}/token-err"; return 1; }
    tok=$(gcloud auth print-access-token --account="${GCP_ACCOUNT}" 2>"${dir}/gc-err")
  else
    PROJ_ID="${ORG}-${APP}-${ENV}" do_gcp_pin_account || { echo "no ${ENV} project SA to act as ${COST_READER_EMAIL} (key absent)" >"${dir}/token-err"; return 1; }
    [[ "${GCP_ACCOUNT}" == *.gserviceaccount.com ]] || { echo "${GCP_ACCOUNT} is no service account: refusing (never the owner account)" >"${dir}/token-err"; return 1; }
    tok=$(gcloud auth print-access-token --account="${GCP_ACCOUNT}" --impersonate-service-account="${COST_READER_EMAIL}" 2>"${dir}/gc-err")
  fi
  if [[ -z "${tok}" ]]; then
    err=$(grep -m 1 '^ERROR' "${dir}/gc-err" | sed -E 's/^ERROR: \([^)]*\) //; s/(\.|\]) .*/\1/' | cut -c 1-200)
    [[ -n "${err}" ]] || err=$(tail -n 1 "${dir}/gc-err" | cut -c 1-200)
    echo "cannot act as the reader SA ${COST_READER_EMAIL} (as ${GCP_ACCOUNT}; setup not run or permission missing, REPORT it): ${err}" >"${dir}/token-err"
    return 1
  fi
  # shellcheck disable=SC2034 # the export subshell's local, read by do_gcp_bq_api
  GCP_BQ_TOKEN="${tok}"
}

# _spl_cost_rows_sql <fq table> - per day, project, box label, service and
# currency: the cost with credits netted, in the billing currency and in USD.
_spl_cost_rows_sql() {
  cat <<EOF
SELECT FORMAT_DATE('%F', DATE(usage_start_time)) AS day, project.id AS project,
  IFNULL((SELECT l.value FROM UNNEST(labels) l WHERE l.key = 'box' LIMIT 1), '') AS box,
  service.description AS service, currency,
  CAST(ROUND(SUM(cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) * 1000000) AS INT64) AS amount_micros,
  CAST(ROUND(SUM((cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) / NULLIF(currency_conversion_rate, 0)) * 1000000) AS INT64) AS usd_micros
FROM $1
WHERE DATE(usage_start_time) BETWEEN @d0 AND @d1 AND project.id LIKE @like
GROUP BY day, project, box, service, currency
ORDER BY day, project, box, service
EOF
}

# _spl_cost_query <out.tsv> <sql> <d0> <d1> - jobs.query with named params,
# polled until complete and paged to the end; rows as TSV. Errors: <dir>/q-err.
_spl_cost_query() {
  local tsv="$1" sql="$2" dir body out rc job page="" n
  dir=$(dirname "${tsv}"); body="${dir}/q-body.json"; : >"${tsv}"
  jq -n --arg q "${sql}" --arg d0 "$3" --arg d1 "$4" --arg like "${COST_PROJECT_LIKE}" --arg loc "${COST_LOCATION}" \
    '{query: $q, useLegacySql: false, parameterMode: "NAMED", location: $loc, timeoutMs: 60000, maxResults: 10000,
      queryParameters: [{name: "d0", parameterType: {type: "DATE"}, parameterValue: {value: $d0}},
                        {name: "d1", parameterType: {type: "DATE"}, parameterValue: {value: $d1}},
                        {name: "like", parameterType: {type: "STRING"}, parameterValue: {value: $like}}]}' >"${body}"
  out=$(do_gcp_bq_api POST "projects/${COST_EXPORT_PROJECT}/queries" "${body}"); rc=$?
  for n in $(seq 1 30); do
    [[ ${rc} -eq 0 ]] || { do_gcp_bq_error "${out}" >"${dir}/q-err"; return 1; }
    job=$(jq -r '.jobReference.jobId // ""' <<<"${out}")
    if [[ "$(jq -r '.jobComplete' <<<"${out}")" == true ]]; then
      jq -r '.rows[]? | [.f[].v // ""] | @tsv' <<<"${out}" >>"${tsv}"
      page=$(jq -r '.pageToken // ""' <<<"${out}")
      [[ -n "${page}" ]] || return 0
    fi
    [[ -n "${job}" ]] || { echo "no job id in the answer (try ${n})" >"${dir}/q-err"; return 1; }
    out=$(do_gcp_bq_api GET "projects/${COST_EXPORT_PROJECT}/queries/${job}?location=${COST_LOCATION}&timeoutMs=60000&maxResults=10000${page:+&pageToken=${page}}"); rc=$?
  done
  echo "the query did not finish in 30 polls" >"${dir}/q-err"
  return 1
}

# _spl_cost_sql <dir> <run_id> <day>... - the one transaction for the window, on
# stdout. Also writes <dir>/coverage.tsv (day state reason lines held).
_spl_cost_sql() {
  local dir="$1" run_id="$2"; shift 2
  local frontier="" fail=""
  [[ -s "${dir}/frontier" ]] && frontier=$(head -n 1 "${dir}/frontier")
  [[ -s "${dir}/fail" ]] && fail=$(cat "${dir}/fail")
  [[ -f "${dir}/rows.tsv" ]] || : >"${dir}/rows.tsv"
  awk -F'\t' -v run="${run_id}" -v days="$*" -v frontier="${frontier}" -v fail="${fail}" \
      -v cov="${dir}/coverage.tsv" -f <(_spl_cost_sql_awk) "${dir}/rows.tsv"
}

_spl_cost_sql_awk() {
  cat <<'AWK'
function q(s) { gsub(/'/, "''", s); return "'" s "'" }
function slug(s) { s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); gsub(/^-+|-+$/, "", s); if (s !~ /^[a-z]/) s = "x-" s; return substr(s, 1, 60) }
BEGIN { ndays = split(days, D, " "); for (i = 1; i <= ndays; i++) inwin[D[i]] = 1 }
fail == "" && ($1 in inwin) && $6 ~ /^-?[0-9]+$/ {
  day = $1; pov = $2; if ($3 != "") pov = pov "/box=" slug($3)
  # EUR is the one currency both report figures come from the export itself
  if ($5 != "EUR" || $7 !~ /^-?[0-9]+$/) { held[day]++; next }
  eur = $6 + 0; usd = $7 + 0
  k = day SUBSEP pov SUBSEP slug($4)
  if (!(k in amt)) { order[++n] = k; cur[k] = $5 }
  amt[k] += $6; U[k] += usd; E[k] += eur; rows[day]++
}
END {
  print "BEGIN;"
  print "SET LOCAL app.rls_scope = 'operator';"
  if (n > 0) {
    print "INSERT INTO cost_lines (day, source, project_or_vendor, tenant_id, agent_id, model, kind, units,"
    print "    amount_micros, currency, usd_micros, eur_micros, fx_rate_day, origin, run_id) VALUES"
    for (i = 1; i <= n; i++) {
      split(order[i], p, SUBSEP)
      printf "  (DATE %s, 'gcp', %s, NULL, NULL, NULL, %s, 0, %.0f, %s, %.0f, %.0f, DATE %s, 'billing_export', %s)%s\n",
        q(p[1]), q(p[2]), q(p[3]), amt[order[i]], q(cur[order[i]]), U[order[i]], E[order[i]], q(p[1]), q(run), (i < n ? "," : "")
    }
    print "ON CONFLICT (day, source, project_or_vendor, tenant_id, agent_id, model, kind) WHERE superseded_by IS NULL"
    print "DO UPDATE SET units = EXCLUDED.units, amount_micros = EXCLUDED.amount_micros, currency = EXCLUDED.currency,"
    print "    usd_micros = EXCLUDED.usd_micros, eur_micros = EXCLUDED.eur_micros, fx_rate_day = EXCLUDED.fx_rate_day,"
    print "    origin = EXCLUDED.origin, run_id = EXCLUDED.run_id, read_at = now();"
  }
  read_days = ""; nc = 0
  for (i = 1; i <= ndays; i++) {
    d = D[i]
    if (fail != "") { st = "missing"; why = fail }
    else if (rows[d] > 0 && held[d] > 0) { st = "partial"; why = held[d] " export line(s) held back: billed in a currency with no EUR rate source yet (spec 123 Q-6)" }
    else if (rows[d] > 0 && d == frontier) { st = "partial"; why = "the export is still filling " d " (its newest day)" }
    else if (rows[d] > 0) { st = "ok"; why = "" }
    else if (held[d] > 0) { st = "partial"; why = held[d] " export line(s) held back: billed in a currency with no EUR rate source yet (spec 123 Q-6)" }
    else if (frontier == "" || d > frontier) { st = "missing"; why = "the export has not reached " d " (newest export day: " (frontier == "" ? "none" : frontier) ")" }
    else { st = "missing"; why = "no " "project row of this estate in the export for " d }
    if (st != "missing") read_days = read_days (read_days == "" ? "" : ", ") "DATE " q(d)
    cv[++nc] = sprintf("  (DATE %s, 'gcp', %s, %s, %s)", q(d), q(st), (why == "" ? "NULL" : q(substr(why, 1, 480))), q(run))
    printf "%s\t%s\t%s\t%d\t%d\n", d, st, why, rows[d] + 0, held[d] + 0 > cov
  }
  if (read_days != "")
    print "DELETE FROM cost_lines WHERE source = 'gcp' AND origin = 'billing_export' AND tenant_id IS NULL AND superseded_by IS NULL AND day IN (" read_days ") AND run_id <> " q(run) ";"
  print "INSERT INTO cost_coverage (day, source, state, reason, run_id) VALUES"
  for (i = 1; i <= nc; i++) print cv[i] (i < nc ? "," : "")
  print "ON CONFLICT (day, source) DO UPDATE SET state = EXCLUDED.state, reason = EXCLUDED.reason, run_id = EXCLUDED.run_id, read_at = now();"
  print "COMMIT;"
}
AWK
}

# _spl_cost_report <dir> - one log line per day of the window.
_spl_cost_report() {
  local d st why lines held
  while IFS=$'\t' read -r d st why lines held; do
    do_log "INFO ${d} gcp ${st} lines=${lines} held=${held}${why:+ reason: ${why}}"
  done <"$1/coverage.tsv"
}

# _spl_cost_db_apply <sql file> - COST_DB_DSN, else the <ENV> hub DB through the
# Cloud SQL proxy as the <ENV> project SA (csi-spl-orc's spl_via_proxy). In a
# subshell: the orc resolver's globals and pinned identity stay there.
_spl_cost_db_apply() {
  (
    local orc="${APP_PATH}/${ORG}-${APP}-orc"
    # shellcheck disable=SC1091
    source "${orc}/lib/bash/funcs/spl-cloud-cnf.func.sh" || exit 1
    if [[ -n "${COST_DB_DSN:-}" ]]; then _spl_cost_psql "$1" "${COST_DB_DSN}"; exit; fi
    # shellcheck disable=SC2034 # read by do_spl_cloud_cnf (<org>-<app>-orc)
    PROJ_PATH="${orc}"
    unset PROJ_ID
    do_spl_cloud_cnf || exit 1
    do_gcp_pin_account "${SPL_CNF}" || exit 1
    do_gcp_require_live_account "${GCP_ACCOUNT}" || exit 1
    spl_via_proxy _spl_cost_psql_proxy "$1"
  )
}

_spl_cost_psql_proxy() { _spl_cost_psql "$1" "${SPL_PROXY_DSN}"; }

_spl_cost_psql() { spl_pg_env "$2" psql -X -q -v ON_ERROR_STOP=1 -f "$1"; }
