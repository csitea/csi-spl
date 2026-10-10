#!/bin/bash
#------------------------------------------------------------------------------
# @description Upload a local file or dir to the RW prefix of the env's box
# @description state bucket (iac 056), <rw_prefix>/<PREFIX>/, with gcloud
# @description storage, mounted or not. Never beside a backup: the destination
# @description is always under rw_prefix (cnf env.box.box_state_mount). NO
# @description CLOBBER: an object that exists is skipped, never overwritten.
# @description Uploads as the box writer SA (the project SA impersonates it).
# @description Refused (exit 3, nothing sent) when anything under SRC is a
# @description secret: spl_box_state_upload_scan, c-846's one exclude list.
# @param ENV - required: dev or prd
# @param SRC - required: the local file or dir
# @param PREFIX (optional) - a relative path under rw_prefix (default: its root)
# @param DRY_RUN (optional) - 1 (default): scan and print the plan; 0 uploads
# @example ENV=dev SRC=/var/tmp/report.md PREFIX=reports ./run -a do_spl_box_state_put
# @example ENV=dev SRC=/var/tmp/report.md PREFIX=reports DRY_RUN=0 ./run -a do_spl_box_state_put
#------------------------------------------------------------------------------
do_spl_box_state_put() {
  spl_require_cloud_env || return 1
  local dry=1 drc src="${SRC:-}" pre="${PREFIX:-}" dest rc=0
  if spl_dry_run; then :; else drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ -n "$src" && -e "$src" ]] || { do_log "FATAL SRC must be an existing local file or dir, got: '$src'"; return 1; }
  spl_box_state_rel PREFIX "$pre" empty-ok || return 1
  spl_box_state_upload_scan "$src" || return $?
  if (( dry )); then
    spl_box_state_gs_begin || return 1
    do_log "OK $ENV DRY_RUN: $src scanned clean; would upload it to $(spl_box_state_dest "$pre") as $SPL_BOX_STATE_WRITER (no clobber). DRY_RUN=0 uploads it."
    return 0
  fi
  spl_box_state_gs_begin gcloud || return 1
  dest="$(spl_box_state_dest "$pre")"
  gcloud storage cp -r --no-clobber "$src" "$dest" --account="$GCP_ACCOUNT" --impersonate-service-account="$SPL_BOX_STATE_WRITER" || rc=$?
  (( rc == 0 )) || { do_log "FAIL $ENV: cannot upload $src to $dest as $SPL_BOX_STATE_WRITER"; return 1; }
  do_log "OK $ENV: $src -> $dest (as $SPL_BOX_STATE_WRITER, existing objects kept)"
}
