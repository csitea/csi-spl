#!/bin/bash
#------------------------------------------------------------------------------
# @description Restore a box's state from the env's box state bucket (iac 056)
# @description onto this box: the counterpart of do_spl_box_state_backup, for
# @description a new box (owner t1 d80ed72c).
# @description
# @description BOX + DATE pick the object: the newest under
# @description gs://<bucket>/<BOX>/<DATE>/, listed and read as the env's project
# @description SA (the box writer SA cannot read). The archive is scanned like
# @description the backup's (an excluded path or key material refuses, exit 3),
# @description then extracted to a STAGING dir, and every file it would write
# @description is compared with the target: NEW, OVERWRITE (content differs) or
# @description same. Nothing outside the staging dir changes unless DRY_RUN=0.
# @description DRY_RUN=0 copies the staging tree onto the target root; with the
# @description root / it runs as root (sudo -n) and keeps the archive's owners.
# @description It never deletes a file the archive does not hold.
# @param ENV - required: dev or prd
# @param DATE - required: YYYY-MM-DD, the night to restore
# @param BOX (optional) - the box whose state to restore; default this box
# @param DRY_RUN (optional) - 1 (default): stage and compare, change nothing
# @param BOX_STATE_STAGING (optional) - the staging dir (default a new mktemp dir)
# @param BOX_STATE_RESTORE_ROOT (optional) - the target root, default /
# @param BOX_STATE_ARCHIVE (optional) - a local .tar.zst instead of the bucket
# @example ENV=prd BOX=box1 DATE=2026-10-10 ./run -a do_spl_box_state_restore
# @example ENV=prd BOX=box1 DATE=2026-10-10 DRY_RUN=0 ./run -a do_spl_box_state_restore
#------------------------------------------------------------------------------
do_spl_box_state_restore() {
  spl_require_cloud_env || return 1
  local dry=1 drc
  if spl_dry_run; then :; else drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local date="${DATE:-}" box root="${BOX_STATE_RESTORE_ROOT:-/}" stage arch src
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { do_log "FATAL DATE must be YYYY-MM-DD (the night to restore), got: '$date'"; return 1; }
  declare -F spl_box_state_box >/dev/null || source "$PROJ_PATH/src/bash/run/spl-box-state-backup.func.sh"
  box="$(spl_box_state_box)" || return 1
  [[ -d "$root" ]] || { do_log "FATAL BOX_STATE_RESTORE_ROOT $root is not a dir"; return 1; }
  do_require_bin tar || return 1
  spl_box_state_tools zstd rsync || return 1

  stage="${BOX_STATE_STAGING:-$(umask 077 && mktemp -d "${TMPDIR:-/var/tmp}/box-state-restore.XXXXXX")}" || return 1
  mkdir -p "$stage" && chmod 700 "$stage" || return 1
  [[ -z "$(ls -A "$stage" 2>/dev/null)" ]] || { do_log "FATAL the staging dir $stage is not empty"; return 1; }
  arch="$stage/archive.tar.zst"

  if [[ -n "${BOX_STATE_ARCHIVE:-}" ]]; then
    [[ -f "$BOX_STATE_ARCHIVE" ]] || { do_log "FATAL BOX_STATE_ARCHIVE $BOX_STATE_ARCHIVE is not a file"; return 1; }
    cp "$BOX_STATE_ARCHIVE" "$arch" || return 1
    src="$BOX_STATE_ARCHIVE"
  else
    src="$(spl_box_state_fetch "$box" "$date" "$arch")" || return 1
  fi
  if ! spl_box_state_scan "$arch"; then
    do_log "FATAL $src holds an excluded path or key material (HIT lines above): restore REFUSED; the archive is left in $stage for a look"
    return 3
  fi
  mkdir -p "$stage/root" || return 1
  zstd -dcq "$arch" | tar -xf - -C "$stage/root" --no-same-owner 2>/dev/null ||
    { do_log "FATAL cannot extract $src into $stage/root"; return 1; }

  local plan nnew nover
  plan="$stage/plan.txt"
  spl_box_state_plan "$stage/root" "$root" >"$plan" || return 1
  nnew="$(grep -c '^NEW ' "$plan")"; nover="$(grep -c '^OVERWRITE ' "$plan")"
  do_log "INFO $box $date from $src: staged in $stage/root; onto $root it would write $nnew new and OVERWRITE $nover existing file(s) (the full list: $plan)"
  grep -m "${BOX_STATE_SHOW:-50}" '^OVERWRITE ' "$plan" | sed 's/^/  /'
  (( nover > ${BOX_STATE_SHOW:-50} )) && echo "  ... $((nover - ${BOX_STATE_SHOW:-50})) more in $plan"

  if (( dry )); then
    do_log "OK $ENV DRY_RUN: nothing outside $stage changed. DRY_RUN=0 applies it."
    return 0
  fi
  local -a asroot=()
  [[ "$root" == / && "$(id -u)" != 0 ]] && asroot=(sudo -n)
  zstd -dcq "$arch" | "${asroot[@]}" tar -xf - -C "$root" --keep-directory-symlink ${asroot:+--same-owner -p} ||
    { do_log "FATAL the apply onto $root failed part way: $plan lists what it was writing"; return 1; }
  do_log "OK $ENV: $box $date restored onto $root ($nnew new, $nover overwritten)"
}

# spl_box_state_fetch <box> <date> <local file> -> downloads the newest object
# of <box>/<date>/ as the project SA; prints its gs:// uri
spl_box_state_fetch() {
  local box="$1" date="$2" out="$3" bucket uri
  do_require_bin gcloud yq || return 1
  do_spl_cloud_cnf || return 1
  bucket="$(spl_box_state_cnf state_bucket_name)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  uri="$(gcloud storage ls "gs://$bucket/$box/$date/" --account="$GCP_ACCOUNT" 2>/dev/null | grep -E '\.tar\.zst$' | sort | tail -n 1)"
  [[ -n "$uri" ]] || { do_log "FATAL no object under gs://$bucket/$box/$date/ (the bucket keeps 30 days)" >&2; return 1; }
  gcloud storage cp "$uri" "$out" --account="$GCP_ACCOUNT" >/dev/null 2>&1 || { do_log "FATAL cannot read $uri" >&2; return 1; }
  printf '%s' "$uri"
}

# spl_box_state_plan <staged root> <target root> -> NEW <path> / OVERWRITE
# <path> per file the apply would write, content compared (rsync -c, dry)
spl_box_state_plan() {
  local from="$1" to="$2"
  rsync -rlcn --out-format='%i %n' "$from/" "$to/" 2>/dev/null |
    awk -v r="${to%/}" '$1 ~ /^[>c][fL]/ { p = substr($0, index($0, " ") + 1); print (($1 ~ /\+\+\+/) ? "NEW " : "OVERWRITE ") r "/" p }'
}
