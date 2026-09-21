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

  spl_db_backup_bucket_exists "$bucket" || return $?
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

# spl_db_backup_bucket_exists <bucket> -> exit 2 and the command that fixes it
# when the 045 bucket is not there yet. Without this the run dies on a raw
# gcloud "bucket does not exist", which reads like a broken backup job rather
# than like an apply nobody has run. The scheduled workflow goes red either
# way, which is correct - but only one of the two tells the reader what to do.
spl_db_backup_bucket_exists() {
  gcloud storage buckets describe "gs://$1" --account="$GCP_ACCOUNT" --format='value(name)' >/dev/null 2>&1 && return 0
  do_log "FATAL $ENV: gs://$1 does not exist (or is not readable as $GCP_ACCOUNT)."
  do_log "FATAL apply the iac step that creates it, with the owner's go for that call:"
  do_log "FATAL   cd csi-spl-orc && ENV=$ENV STEP=045-gcs-db-backups make do-tf-plan"
  do_log "FATAL   cd csi-spl-orc && ENV=$ENV STEP=045-gcs-db-backups make do-provision"
  return 2
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
