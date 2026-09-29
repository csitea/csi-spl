#!/bin/bash
#------------------------------------------------------------------------------
# @description Copy an env's backups OUT of its project (spec 044 contingency
# @description T077): every 045 dump and every 050 file that the off-project
# @description bucket (iac 046, gs://csi-spl-bkp-<env> in csi-spl-bkp) does not
# @description hold yet. Runs as the env's project SA, which on that bucket may
# @description only ADD an object and list names: it cannot read one back,
# @description overwrite or delete it, so a compromised env key cannot reach
# @description the copies (restores read them as the csi-spl-bkp SA).
# @description   gs://csi-spl-<env>-db-backups/<env>/<dump>  -> <env>/db/<dump>
# @description   gs://csi-spl-<env>-files/<path>             -> <env>/files/<path>
# @description `gcloud storage rsync -n` (no-clobber, never deletes): a
# @description bucket-to-bucket rewrite inside Google, so no byte transits the
# @description runner. Afterwards every source name must be present in the
# @description copy (exit 3 otherwise): the check, not rsync's exit code, is
# @description the verdict.
# @description While cnf steps.046.copy_enabled is false (csi-spl-bkp not yet
# @description bootstrapped + applied) it logs that and exits 0, so the daily
# @description workflow 45 stays green; SPL_OFFSITE_REQUIRED=1 makes it exit 2.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): count what is missing, copy nothing
# @param SPL_OFFSITE_REQUIRED (optional) - 1: a disabled copy is an error (exit 2)
# @param SPL_OFFSITE_PARTS (optional) - "db files" (default), or one of them
# @example ENV=dev ./run -a do_spl_backup_offsite
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_backup_offsite
#------------------------------------------------------------------------------
do_spl_backup_offsite() {
  do_require_bin gcloud yq || return 1
  do_spl_cloud_cnf || return 1
  spl_offsite_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if [[ "$SPL_OFFSITE_ENABLED" != true ]]; then
    do_log "INFO $ENV: the off-project copy is not enabled yet (cnf steps.046-gcs-offsite-backups.copy_enabled=$SPL_OFFSITE_ENABLED): csi-spl-bkp must be bootstrapped and 046 applied first"
    [[ "${SPL_OFFSITE_REQUIRED:-0}" == 1 ]] && return 2
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local db files part rc=0
  db="$(spl_db_backup_bucket)" || return 1
  files="$(yq -r '.env.steps."050-gcs-files".files_bucket_name // ""' "$SPL_CNF")"
  [[ -n "$files" && "$files" != null ]] || { do_log "FATAL cnf steps.050-gcs-files.files_bucket_name is empty for $ENV"; return 1; }
  for part in ${SPL_OFFSITE_PARTS:-db files}; do
    case "$part" in
      db)    spl_offsite_sync "gs://$db/$ENV" "gs://$SPL_OFFSITE_BUCKET/$ENV/db" "$dry" || rc=$? ;;
      files) spl_offsite_sync "gs://$files" "gs://$SPL_OFFSITE_BUCKET/$ENV/files" "$dry" || rc=$? ;;
      *) do_log "FATAL SPL_OFFSITE_PARTS takes db and/or files, got: $part"; return 1 ;;
    esac
  done
  if (( rc == 0 && dry )); then do_log "OK $ENV: DRY RUN - nothing copied. DRY_RUN=0 to copy."
  elif (( rc == 0 )); then do_log "OK $ENV: the off-project copy in gs://$SPL_OFFSITE_BUCKET is complete"; fi
  return $rc
}

# spl_offsite_sync <src prefix> <dst prefix> <dry> -> copies what dst lacks,
# then proves every src name is in dst.
spl_offsite_sync() {
  local src="$1" dst="$2" dry="$3" s d missing
  s="$(spl_gs_names "$src")"
  d="$(spl_gs_names "$dst")"
  missing="$(comm -23 <(printf '%s\n' "$s" | sed '/^$/d') <(printf '%s\n' "$d" | sed '/^$/d') | wc -l)"
  do_log "INFO $ENV: $src -> $dst: $(sed '/^$/d' <<<"$s" | wc -l) source object(s), $missing missing from the copy"
  (( missing == 0 )) && return 0
  if (( dry )); then
    do_log "INFO DRY_RUN would copy $missing object(s) with: gcloud storage rsync $src $dst --recursive --no-clobber --account=$GCP_ACCOUNT"
    return 0
  fi
  gcloud storage rsync "$src" "$dst" --recursive --no-clobber --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
    do_log "WARN $ENV: rsync $src -> $dst reported an error; the name check below decides"
  d="$(spl_gs_names "$dst")"
  missing="$(comm -23 <(printf '%s\n' "$s" | sed '/^$/d') <(printf '%s\n' "$d" | sed '/^$/d'))"
  if [[ -n "$missing" ]]; then
    do_log "FAIL $ENV: $(wc -l <<<"$missing") object(s) of $src are still not in $dst, first: $(head -1 <<<"$missing")"
    return 3
  fi
  do_log "INFO $ENV: every object of $src is in $dst"
}
