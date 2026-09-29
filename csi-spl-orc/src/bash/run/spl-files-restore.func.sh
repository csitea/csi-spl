#!/bin/bash
#------------------------------------------------------------------------------
# @description RESTORE the hub's user files (the 050 bucket, objects at
# @description t/<tenant>/files/<sha256>) from a backup (spec 044 contingency
# @description T078, the files half; do_spl_db_restore is the DB half).
# @description   SOURCE=bkp (default)  gs://csi-spl-bkp-<env>/<env>/files, the
# @description                         off-project copy (iac 046), read as the
# @description                         csi-spl-bkp SA - the env SA cannot read it
# @description   SOURCE=env            the env's own 050 bucket, read as the env
# @description                         SA: the "take it out before a destroy"
# @description                         leg of runbook §3.1, and the proof path
# @description   TARGET=local[:<dir>]  a local dir (default: a throwaway temp
# @description                         dir, removed after the check unless KEEP=1)
# @description   TARGET=env            the env's 050 bucket, no-clobber (an
# @description                         existing object is never replaced); prd
# @description                         only with ALLOW_PRD_RESTORE=1
# @description The two identities never meet: the source leg downloads into a
# @description 0700 temp dir, the target leg uploads from it. Afterwards every
# @description source name must be present in the target (exit 3 otherwise).
# @description DRY_RUN=1 (the default) counts the source and touches nothing.
# @param ENV - required: dev or prd
# @param SOURCE (optional) - bkp (default) | env
# @param TARGET (optional) - local (default) | local:<absolute dir> | env
# @param PREFIX (optional) - restore only names under it, e.g. t/t1/
# @param ALLOW_PRD_RESTORE (optional) - 1 lets TARGET=env write into prd
# @param KEEP (optional) - 1 keeps the throwaway local dir
# @param DRY_RUN (optional) - 1 (default) plan only; 0 restore
# @example ENV=dev SOURCE=env DRY_RUN=0 ./run -a do_spl_files_restore
# @example ENV=prd TARGET=env ALLOW_PRD_RESTORE=1 DRY_RUN=0 ./run -a do_spl_files_restore
#------------------------------------------------------------------------------
do_spl_files_restore() {
  do_require_bin gcloud python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local source="${SOURCE:-bkp}" target="${TARGET:-local}" prefix="${PREFIX:-}" dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ -z "$prefix" || "$prefix" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL PREFIX has characters a 050 name never has: $prefix"; return 1; }
  [[ "$prefix" != *..* ]] || { do_log "FATAL PREFIX must not contain '..'"; return 1; }
  spl_files_restore_guard "$source" "$target" || return 1

  local files src who=env
  files="$(yq -r '.env.steps."050-gcs-files".files_bucket_name // ""' "$SPL_CNF")"
  [[ -n "$files" && "$files" != null ]] || { do_log "FATAL cnf steps.050-gcs-files.files_bucket_name is empty for $ENV"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  if [[ "$source" == bkp ]]; then
    spl_offsite_cnf || return 1
    src="gs://$SPL_OFFSITE_BUCKET/$ENV/files"; who=bkp
    spl_bkp_key >/dev/null || return 1
  else
    src="gs://$files"
  fi
  src="${src%/}${prefix:+/${prefix%/}}"

  local names n
  names="$(spl_gs_names "$src" "$who")"
  n="$(sed '/^$/d' <<<"$names" | wc -l)"
  do_log "INFO $ENV: $n object(s) under $src ($who identity) -> $target"
  (( n > 0 )) || { do_log "FATAL $ENV: nothing to restore under $src"; return 1; }
  if (( dry )); then
    do_log "OK DRY RUN: nothing restored. DRY_RUN=0 to restore."
    printf 'source=%s target=%s objects=%s\n' "$src" "$target" "$n"
    return 0
  fi

  local t0 work dir rc=0 keep="${KEEP:-0}"
  t0="$(date +%s)"
  work="$(umask 077 && mktemp -d)" || return 1
  dir="$work/files"
  [[ "$target" == local:* ]] && { dir="${target#local:}"; keep=1; }
  mkdir -p "$dir" || { rm -rf "$work"; return 1; }
  spl_files_restore_run "$src" "$who" "$dir" "$target" "$files" "$names" || rc=$?
  local rto=$(( $(date +%s) - t0 )) bytes
  bytes="$(du -sb "$dir" 2>/dev/null | cut -f1)"
  [[ "$keep" == 1 ]] || rm -rf "$work"
  [[ "$keep" == 1 && "$target" == local ]] && do_log "INFO $ENV: kept $dir (KEEP=1): delete it when done"
  printf 'source=%s target=%s objects=%s bytes=%s rto_s=%s rc=%s\n' "$src" "$target" "$n" "${bytes:-0}" "$rto" "$rc"
  (( rc == 0 )) && do_log "OK $ENV: restored $n object(s) from $src -> $target in ${rto}s"
  return $rc
}

# spl_files_restore_guard <source> <target> -> refuses the calls that must
# never happen.
spl_files_restore_guard() {
  [[ "$1" == bkp || "$1" == env ]] || { do_log "FATAL SOURCE must be bkp or env, got: $1"; return 1; }
  case "$2" in
    local) ;;
    local:/*) [[ "$2" != *..* ]] || { do_log "FATAL TARGET=local:<dir> must not contain '..'"; return 1; } ;;
    env)
      [[ "$1" != env ]] || { do_log "FATAL SOURCE=env TARGET=env copies the bucket onto itself"; return 1; }
      [[ "$ENV" != prd || "${ALLOW_PRD_RESTORE:-0}" == 1 ]] ||
        { do_log "FATAL TARGET=env on prd writes the production files bucket: set ALLOW_PRD_RESTORE=1 to mean it"; return 1; } ;;
    *) do_log "FATAL TARGET must be local, local:<absolute dir> or env, got: $2"; return 1 ;;
  esac
}

# spl_files_restore_run <src> <who> <dir> <target> <files bucket> <names>
spl_files_restore_run() {
  local src="$1" who="$2" dir="$3" target="$4" files="$5" names="$6" have missing
  if [[ "$who" == bkp ]]; then
    spl_bkp_gcloud storage rsync "$src" "$dir" --recursive --quiet >/dev/null 2>&1 ||
      { do_log "FATAL $ENV: cannot download $src as the csi-spl-bkp SA"; return 1; }
  else
    gcloud storage rsync "$src" "$dir" --recursive --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      { do_log "FATAL $ENV: cannot download $src"; return 1; }
  fi
  if [[ "$target" == env ]]; then
    local dst="gs://$files"
    [[ -n "${PREFIX:-}" ]] && dst="$dst/${PREFIX%/}"
    gcloud storage rsync "$dir" "$dst" --recursive --no-clobber --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      do_log "WARN $ENV: the upload to $dst reported an error; the name check below decides"
    have="$(spl_gs_names "$dst")"
  else
    have="$(cd "$dir" && find . -type f | sed 's|^\./||' | sort -u)"
  fi
  missing="$(comm -23 <(sed '/^$/d' <<<"$names") <(sed '/^$/d' <<<"$have"))"
  if [[ -n "$missing" ]]; then
    do_log "FAIL $ENV: $(wc -l <<<"$missing") object(s) did not arrive in $target, first: $(head -1 <<<"$missing")"
    return 3
  fi
  do_log "INFO $ENV: all $(sed '/^$/d' <<<"$names" | wc -l) object(s) are in $target"
}
