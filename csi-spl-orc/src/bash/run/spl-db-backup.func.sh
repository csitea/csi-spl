#!/bin/bash
#------------------------------------------------------------------------------
# @description Take ONE off-instance dump of a cloud env's hub DB into the
# @description env's backup bucket (iac 045), as the env's project service
# @description account. Owner order 2026-09-20: "a backup job on the db - for
# @description now once daily, triggered from the github actions".
# @description
# @description WHY THIS AND NOT pg_dump THROUGH THE PROXY. `gcloud sql export`
# @description runs INSIDE Google: the instance streams straight to the
# @description bucket, so (a) no row of tenant data transits the GitHub-hosted
# @description runner, (b) the runner needs no database password at all, and
# @description (c) the export runs as the instance's own superuser, so rdb
# @description 0014 FORCE row-level security cannot silently empty a table in
# @description the dump - a proxied pg_dump as the RUNTIME login needs both
# @description --enable-row-security and the operator scope, and is one
# @description forgotten flag away from a dump full of zero-row tables.
# @description
# @description WHY AT ALL, given 040 turns on automated backups and PITR.
# @description Measured 2026-09-21 (do_spl_db_health, section cloudsql): both
# @description are on and green on dev and prd. This is additive, not a
# @description replacement: a Cloud SQL backup restores only into Cloud SQL and
# @description dies with the project, retainedBackups is 7, and a logical dump
# @description can be read, diffed and partially restored.
# @description
# @description DRY_RUN=1 (the default) resolves and prints the target object
# @description and touches nothing. DRY_RUN=0 performs the export.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) plan only; 0 export
# @param SPL_BACKUP_PREFIX (optional) - object prefix, default <env>/
# @param SPL_BACKUP_MIN_BYTES (optional) - refuse a dump smaller than this, default 4096
# @example ENV=dev ./run -a do_spl_db_backup
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_db_backup
#------------------------------------------------------------------------------
do_spl_db_backup() {
  do_require_bin gcloud yq || return 1
  do_spl_cloud_cnf || return 1
  local bucket
  bucket="$(spl_db_backup_bucket)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local uri
  uri="gs://$bucket/${SPL_BACKUP_PREFIX:-$ENV/}$(spl_db_backup_object_name)"
  do_log "INFO $ENV: export $SPL_SQL_CONN/$SPL_DB_NAME -> $uri (as $GCP_ACCOUNT)"

  if spl_dry_run; then
    do_log "OK DRY RUN: nothing exported. DRY_RUN=0 to take the backup."
    printf 'uri=%s\n' "$uri"
    return 0
  fi

  spl_db_backup_export "$uri" || return $?
  spl_db_backup_check "$uri" || return $?
  printf 'uri=%s\n' "$uri"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'uri=%s\n' "$uri" >>"$GITHUB_OUTPUT"
  do_log "OK $ENV: $uri"
}

# spl_db_backup_bucket -> the env's 045 bucket name from the effective cnf, or
# a refusal. Never a guessed name: the bucket is where the only off-instance
# copy of the database lands, and a typo would write it somewhere nobody looks.
spl_db_backup_bucket() {
  local b
  b="$(yq -r '.env.steps."045-gcs-db-backups".backups_bucket_name // ""' "$SPL_CNF")"
  [[ -n "$b" && "$b" != null ]] ||
    { do_log "FATAL cnf env.steps.\"045-gcs-db-backups\".backups_bucket_name is empty for $ENV"; return 1; }
  printf '%s' "$b"
}

# spl_db_backup_object_name -> <db>-<utc>.sql.gz. Cloud SQL compresses when the
# name ends in .gz. The timestamp makes every object unique, which is why the
# bucket needs no versioning and why the instance agent needs no overwrite.
spl_db_backup_object_name() {
  printf '%s-%s.sql.gz' "$SPL_DB_NAME" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# spl_db_backup_export <uri> -> the export, retrying while the instance says an
# operation is already running. The daily automated backup (040, 01:00 UTC) and
# an export cannot overlap, and its window DRIFTS - measured 2026-09-21: a
# 01:00 window enqueued at 02:17Z on dev and 01:54Z on prd. So a collision is
# expected, not exceptional, and a retry is the handling.
spl_db_backup_export() {
  local uri="$1" i out rc
  for i in 1 2 3 4 5 6; do
    out="$(gcloud sql export sql "$SPL_SQL_INSTANCE" "$uri" \
      --database="$SPL_DB_NAME" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --quiet 2>&1)"
    rc=$?
    (( rc == 0 )) && return 0
    if grep -qiE 'operation.*(in progress|already)|instance is currently|HTTP Error 409' <<<"$out"; then
      do_log "INFO $ENV: the instance is busy (attempt $i/6); waiting 120 s"
      sleep 120
      continue
    fi
    do_log "FATAL $ENV: export failed: $out"
    return 3
  done
  do_log "FATAL $ENV: the instance stayed busy for 6 attempts; no backup taken"
  return 3
}

# spl_db_backup_check <uri> -> the object exists and is not a stub. An export
# that "succeeds" and leaves a 0-byte object is the failure this catches; a
# green exit code on its own is not evidence that a backup exists.
spl_db_backup_check() {
  local uri="$1" size min="${SPL_BACKUP_MIN_BYTES:-4096}"
  size="$(gcloud storage objects describe "$uri" --account="$GCP_ACCOUNT" --format='value(size)' 2>/dev/null)"
  [[ -n "$size" ]] || { do_log "FATAL $ENV: the export reported success but $uri does not exist"; return 4; }
  (( size >= min )) ||
    { do_log "FATAL $ENV: $uri is $size bytes, below the $min-byte floor: treating it as a failed dump"; return 4; }
  do_log "INFO $ENV: $uri is $size bytes"
}

#------------------------------------------------------------------------------
# @description PROVE a dump restores. Downloads one object from the env's 045
# @description bucket, restores it into a THROWAWAY local postgres container,
# @description counts every table, and compares that against the live database
# @description read-only. Nothing in GCP is mutated and the live DB is only
# @description read: the scratch database is a container on this box (or on the
# @description runner), and it is removed either way.
# @description
# @description The comparison is deliberately NOT "the counts are equal". The
# @description dump and the live read are two different instants, and dev takes
# @description writes between them, so equality would be red for the wrong
# @description reason. What it asserts instead is what a broken dump actually
# @description looks like: a table that the live DB has and the restore does
# @description not, or a table that restores EMPTY while the live one has rows.
# @description The full per-table table is printed so drift is visible.
# @param ENV - required: dev or prd
# @param OBJECT (optional) - the gs:// uri to verify; default the newest in the bucket
# @param SPL_RESTORE_IMAGE (optional) - default postgres:16-alpine
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev ./run -a do_spl_db_backup_verify
# @example ENV=prd OBJECT=gs://csi-spl-prd-db-backups/prd/spool-20260921T051700Z.sql.gz ./run -a do_spl_db_backup_verify
#------------------------------------------------------------------------------
do_spl_db_backup_verify() {
  do_require_bin gcloud docker psql python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local bucket
  bucket="$(spl_db_backup_bucket)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local uri="${OBJECT:-}"
  [[ -n "$uri" ]] || uri="$(spl_db_backup_newest "$bucket")" ||
    { do_log "FATAL $ENV: no object in gs://$bucket to verify"; return 1; }
  do_log "INFO $ENV: verifying $uri"

  local work rc=0
  work="$(mktemp -d)" || return 1
  gcloud storage cp "$uri" "$work/dump.sql.gz" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { rm -rf "$work"; do_log "FATAL $ENV: cannot download $uri"; return 1; }
  gunzip -f "$work/dump.sql.gz" ||
    { rm -rf "$work"; do_log "FATAL $ENV: $uri is not gzip"; return 4; }
  do_log "INFO $ENV: downloaded $(stat -c %s "$work/dump.sql") bytes of SQL"

  spl_db_backup_restore_counts "$work/dump.sql" >"$work/restored.txt" || rc=$?
  (( rc == 0 )) || { rm -rf "$work"; return $rc; }
  spl_via_proxy _spl_db_backup_live_counts >"$work/live.txt" || rc=$?
  (( rc == 0 )) || { rm -rf "$work"; do_log "FATAL $ENV: cannot read the live counts"; return 1; }

  spl_db_backup_compare "$work/restored.txt" "$work/live.txt" || rc=$?
  rm -rf "$work"
  return $rc
}

# spl_db_backup_newest <bucket> -> the newest object uri in the bucket.
spl_db_backup_newest() {
  local u
  u="$(gcloud storage ls "gs://$1/**" --account="$GCP_ACCOUNT" 2>/dev/null | sort | tail -1)"
  [[ -n "$u" ]] || return 1
  printf '%s' "$u"
}

# spl_db_backup_restore_counts <dump.sql> -> "<table> <count>" per line, from a
# THROWAWAY postgres container that is removed whatever happens. The container
# is the scratch database: nothing local and nothing in the cloud is touched.
spl_db_backup_restore_counts() {
  local dump="$1" img="${SPL_RESTORE_IMAGE:-postgres:16-alpine}" con i
  con="spl-restorecheck-$ENV-$$"
  docker run -d --rm --name "$con" -e POSTGRES_PASSWORD=restorecheck -e POSTGRES_DB=restorecheck \
    "$img" >/dev/null 2>&1 || { do_log "FATAL cannot start $img for the restore check"; return 1; }
  # shellcheck disable=SC2064
  trap "docker rm -f '$con' >/dev/null 2>&1 || true; trap - RETURN" RETURN
  for i in $(seq 60); do
    docker exec "$con" pg_isready -U postgres -q 2>/dev/null && break
    sleep 1
  done
  docker exec "$con" pg_isready -U postgres -q 2>/dev/null ||
    { do_log "FATAL the restore-check container never became ready"; return 1; }

  # The dump names the cloud logins as owners; they do not exist here, so
  # ON_ERROR_STOP stays OFF and the count comparison is what decides, not the
  # exit code of a role-grant line.
  docker exec -i "$con" psql -q -U postgres -d restorecheck -v ON_ERROR_STOP=0 <"$dump" >/dev/null 2>&1
  docker exec "$con" psql -U postgres -d restorecheck -XAtc "
    SELECT table_name FROM information_schema.tables
     WHERE table_type = 'BASE TABLE' AND table_schema = 'public' ORDER BY 1" 2>/dev/null |
    while read -r t; do
      [[ -n "$t" ]] || continue
      printf '%s %s\n' "$t" "$(docker exec "$con" psql -U postgres -d restorecheck -XAtc "SELECT count(*) FROM \"$t\"" 2>/dev/null)"
    done
}

# _spl_db_backup_live_counts -> "<table> <count>" per line from the LIVE DB,
# read-only, in the operator RLS scope (without it every tenant table counts 0
# and the comparison would pass a dump that is actually empty).
_spl_db_backup_live_counts() {
  local tables
  tables="$(spl_psql_ro "$SPL_PROXY_DSN" "SELECT table_name FROM information_schema.tables
     WHERE table_type = 'BASE TABLE' AND table_schema = 'public' ORDER BY 1;")" || return 1
  local t sql=""
  while read -r t; do
    [[ -n "$t" ]] || continue
    sql+="SELECT '$t', count(*) FROM \"$t\" UNION ALL "
  done <<<"$tables"
  [[ -n "$sql" ]] || { do_log "FATAL the live DB reports no table"; return 1; }
  spl_psql_ro "$SPL_PROXY_DSN" "${sql%UNION ALL } ORDER BY 1;" | tr '|' ' '
}

# spl_db_backup_compare <restored> <live> -> the verdict. Exit 5 when a live
# table is missing from the restore, or restored EMPTY while the live one has
# rows. Those are what a truncated or RLS-blanked dump looks like; a plain
# count difference is not, because the two reads are minutes apart.
spl_db_backup_compare() {
  local v
  v="$(python3 -c '
import sys
def load(p):
    d = {}
    for line in open(p):
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            d[parts[0]] = int(parts[1])
    return d
res, live = load(sys.argv[1]), load(sys.argv[2])
missing = sorted(t for t in live if t not in res)
blank = sorted(t for t in live if t in res and live[t] > 0 and res[t] == 0)
print("TABLE RESTORED LIVE")
for t in sorted(set(res) | set(live)):
    print("%s %s %s" % (t, res.get(t, "-"), live.get(t, "-")))
if missing:
    print("VERDICT 5 %d live table(s) missing from the restore: %s" % (len(missing), ",".join(missing)))
elif blank:
    print("VERDICT 5 %d table(s) restored EMPTY while live has rows: %s" % (len(blank), ",".join(blank)))
elif not res:
    print("VERDICT 5 the restore produced no table at all")
else:
    rows = sum(res.values())
    print("VERDICT 0 %d table(s), %d row(s) restored; every live table is present and non-empty where live is" % (len(res), rows))
' "$1" "$2")" || { do_log "FATAL cannot compare the counts"; return 1; }
  printf '%s\n' "$v" | grep -v '^VERDICT '
  local line code msg
  line="$(grep '^VERDICT ' <<<"$v")"
  code="$(awk '{print $2}' <<<"$line")"
  msg="${line#VERDICT $code }"
  if [[ "$code" == 0 ]]; then do_log "OK $ENV restore check: $msg"; else do_log "FAIL $ENV restore check: $msg"; fi
  return "$code"
}
