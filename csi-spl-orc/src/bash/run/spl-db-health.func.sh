#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY health report of a cloud env's hub DB: size, load,
# @description vacuum/wraparound, schema shape, and the Cloud SQL instance
# @description itself. One Cloud SQL proxy session for the whole report
# @description (do_spl_db_query starts one per statement, which is ~12 s of
# @description proxy start per question).
# @description
# @description Nothing is mutated. The psql session runs with
# @description default_transaction_read_only=on inside BEGIN READ ONLY and
# @description ends in ROLLBACK, so Postgres itself refuses a write; the
# @description gcloud half only describes and lists. The transaction takes the
# @description operator row-level-security scope (rdb 0014, 017 FR-SEC-013):
# @description without it every tenant table reads empty to the hub login.
# @description
# @description A statement the hub's RUNTIME login may not run (for example
# @description pg_stat_statements without pg_read_all_stats, or pg_ls_waldir
# @description without pg_monitor) prints its ERROR and the report continues:
# @description psql runs with ON_ERROR_ROLLBACK=on, so each statement has its
# @description own savepoint. "Not permitted" is itself a finding, so it is
# @description printed rather than hidden.
# @param ENV - required: dev or prd
# @param SECTION (optional) - all (default) | size | load | vacuum | structure | cloudsql
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_db_health
# @example ENV=prd SECTION=vacuum ./run -a do_spl_db_health
#------------------------------------------------------------------------------
do_spl_db_health() {
  do_require_bin gcloud psql python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local section="${SECTION:-all}"
  spl_db_health_known_section "$section" ||
    { do_log "FATAL SECTION must be all or one of: $(spl_db_health_sections | tr '\n' ' ')"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  printf '===== csi-spl db health: env=%s project=%s instance=%s db=%s section=%s utc=%s\n' \
    "$ENV" "$SPL_PROJECT" "$SPL_SQL_INSTANCE" "$SPL_DB_NAME" "$section" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local rc=0
  if [[ "$section" == all || "$section" == cloudsql ]]; then
    spl_db_health_cloudsql || rc=$?
  fi
  if [[ "$section" != cloudsql ]]; then
    spl_via_proxy _spl_db_health_run "$section" || rc=$?
  fi
  return $rc
}

# spl_db_health_sections -> the sections, one per line, in report order.
spl_db_health_sections() {
  printf '%s\n' size load vacuum structure cloudsql
}

# spl_db_health_known_section <name> -> 0 when it is "all" or a known section.
spl_db_health_known_section() {
  [[ "$1" == all ]] && return 0
  spl_db_health_sections | grep -xF "$1" >/dev/null
}

# _spl_db_health_run <section> -> the SQL half, with SPL_PROXY_DSN in the env.
_spl_db_health_run() {
  local sql
  sql="$(spl_db_health_sql "$1")" || return 1
  spl_psql_report "$SPL_PROXY_DSN" "$sql"
}

# spl_psql_report <proxy dsn> <sql> -> psql in a read-only transaction with
# ALIGNED output (a report is read by a person, not parsed), the operator RLS
# scope, and a savepoint per statement so one refused catalog read does not
# abort the rest. The login travels in PG* env vars only, never argv.
spl_psql_report() {
  local parts
  parts="$(python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("\n".join([u.unquote(p.username or ""), u.unquote(p.password or ""), p.hostname or "", str(p.port or 5432), p.path.lstrip("/")]))
' "$1")" || return 1
  local -a f
  mapfile -t f <<<"$parts"
  printf 'BEGIN READ ONLY;\nSET LOCAL app.rls_scope = '\''operator'\'';\n%s\nROLLBACK;\n' "$2" |
    PGUSER="${f[0]}" PGPASSWORD="${f[1]}" PGHOST="${f[2]}" PGPORT="${f[3]}" PGDATABASE="${f[4]}" \
    PGSSLMODE=disable PGCONNECT_TIMEOUT=15 PGOPTIONS='-c default_transaction_read_only=on' \
    psql -X -q -v ON_ERROR_STOP=0 -v ON_ERROR_ROLLBACK=on -P pager=off 2>&1
}

# spl_db_health_sql <all|size|load|vacuum|structure> -> the report's SQL, one
# read-only script per section in csi-spl-orc/src/sql/db-health/<section>.sql.
spl_db_health_sql() {
  local want="$1" s dir
  dir="$(dirname "${BASH_SOURCE[0]}")/../../sql/db-health"
  for s in size load vacuum structure; do
    [[ "$want" == all || "$want" == "$s" ]] || continue
    cat "$dir/$s.sql" || return 1
  done
}

# spl_db_health_cloudsql -> the Cloud SQL instance itself: tier, disk, backups,
# PITR, maintenance window, insights, and the most recent backup runs.
# Read-only: describe and list only, every call pinned to $GCP_ACCOUNT.
spl_db_health_cloudsql() {
  local rc=0
  echo
  echo "--- cloudsql: instance $SPL_SQL_INSTANCE"
  gcloud sql instances describe "$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --format='yaml(name, databaseVersion, state, gceZone, region,
      settings.tier, settings.edition, settings.availabilityType, settings.dataDiskType,
      settings.dataDiskSizeGb, settings.storageAutoResize, settings.storageAutoResizeLimit,
      settings.backupConfiguration, settings.maintenanceWindow, settings.insightsConfig,
      settings.databaseFlags, settings.deletionProtectionEnabled,
      settings.ipConfiguration.sslMode, settings.userLabels)' || rc=1

  echo
  echo "--- cloudsql: the last 10 backup runs (automated and on demand)"
  gcloud sql backups list --instance="$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --limit=10 --format='table(id, type, status, windowStartTime, enqueuedTime, location)' || rc=1

  echo
  echo "--- cloudsql: disk and CPU as the platform measures them (last 24 h)"
  spl_db_health_metrics || rc=1
  return $rc
}

# spl_db_health_metrics -> the Cloud Monitoring series the size question needs
# (bytes used against the disk quota, CPU, backends, id utilization) over the
# last 24 h, as latest / min / max plus the 24 h delta, which is the growth
# rate. `gcloud monitoring` has no time-series verb (measured 2026-09-21:
# "Invalid choice: 'time-series'"), so this reads the v3 REST endpoint with an
# access token for $GCP_ACCOUNT. The bearer header moved off curl argv into a
# 0600 -K config file, removed after the loop. That move is a behaviour change
# from -H "Authorization: Bearer ...".
spl_db_health_metrics() {
  do_require_bin curl python3 || return 1
  local since until m tok hdr rc=0
  until="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  since="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" || return 1
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$tok" ]] || { do_log "ERROR no access token for $GCP_ACCOUNT: no platform metrics"; return 1; }
  hdr="$(mktemp)" || return 1
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$hdr"; )
  for m in database/disk/bytes_used database/disk/quota database/cpu/utilization \
           database/postgresql/num_backends database/postgresql/transaction_id_utilization; do
    printf '%-50s ' "${m#database/}"
    curl -s --connect-timeout 10 --max-time 30 -G "https://monitoring.googleapis.com/v3/projects/$SPL_PROJECT/timeSeries" \
      -K "$hdr" \
      --data-urlencode "filter=metric.type=\"cloudsql.googleapis.com/$m\" AND resource.labels.database_id=\"$SPL_PROJECT:$SPL_SQL_INSTANCE\"" \
      --data-urlencode "interval.startTime=$since" \
      --data-urlencode "interval.endTime=$until" |
      spl_db_health_series || rc=1
  done
  rm -f "$hdr"
  return $rc
}

# spl_db_health_series -> one line out of a Monitoring v3 timeSeries response
# on stdin: n points, the newest and oldest value, min, max and the delta
# across the window (the growth rate the size question asks for).
spl_db_health_series() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("no data (%s)" % e); sys.exit(0)
if "error" in d:
    print("error: %s" % d["error"].get("message", d["error"])); sys.exit(0)
pts = []
for s in d.get("timeSeries", []):
    for p in s.get("points", []):
        v = p.get("value", {})
        val = v.get("int64Value", v.get("doubleValue", v.get("boolValue")))
        if val is None:
            continue
        pts.append((p["interval"]["endTime"], float(val)))
if not pts:
    print("no points in the window"); sys.exit(0)
pts.sort()
oldest, newest = pts[0][1], pts[-1][1]
lo = min(v for _, v in pts); hi = max(v for _, v in pts)
def f(x):
    return "%.4f" % x if abs(x) < 10 else "%.0f" % x
print("n=%d newest=%s oldest=%s min=%s max=%s delta_24h=%s" % (
    len(pts), f(newest), f(oldest), f(lo), f(hi), f(newest - oldest)))
'
}
