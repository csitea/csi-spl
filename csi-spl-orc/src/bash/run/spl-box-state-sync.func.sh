#!/bin/bash
#------------------------------------------------------------------------------
# @description Mirror a local dir into the RW prefix of the env's box state
# @description bucket (iac 056), <rw_prefix>/<PREFIX>/, with gcloud storage
# @description rsync, mounted or not: new and changed files go up. It never
# @description deletes a remote object, and it never writes outside rw_prefix
# @description (cnf env.box.box_state_mount), so no backup is touched.
# @description Runs as the box writer SA (the project SA impersonates it); a
# @description changed file needs the step 056 grant on the RW prefix.
# @description Refused (exit 3, nothing sent) when anything under SRC is a
# @description secret: spl_box_state_upload_scan, c-846's one exclude list.
# @param ENV - required: dev or prd
# @param SRC - required: the local dir
# @param PREFIX - required: a relative path under rw_prefix (a sync owns its prefix)
# @param DRY_RUN (optional) - 1 (default): scan and print the plan; 0 syncs
# @example ENV=dev SRC=/var/tmp/notes PREFIX=notes ./run -a do_spl_box_state_sync
# @example ENV=dev SRC=/var/tmp/notes PREFIX=notes DRY_RUN=0 ./run -a do_spl_box_state_sync
#------------------------------------------------------------------------------
do_spl_box_state_sync() {
  spl_require_cloud_env || return 1
  local dry=1 drc src="${SRC:-}" pre="${PREFIX:-}" dest rc=0
  if spl_dry_run; then :; else drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ -n "$src" && -d "$src" ]] || { do_log "FATAL SRC must be an existing local dir, got: '$src'"; return 1; }
  [[ -n "$pre" ]] || { do_log "FATAL PREFIX is required: the folder under the RW prefix this sync owns"; return 1; }
  spl_box_state_rel PREFIX "$pre" || return 1
  spl_box_state_upload_scan "$src" || return $?
  if (( dry )); then
    spl_box_state_gs_begin || return 1
    do_log "OK $ENV DRY_RUN: $src scanned clean; would rsync it to $(spl_box_state_dest "$pre") as $SPL_BOX_STATE_WRITER (no remote delete). DRY_RUN=0 syncs it."
    return 0
  fi
  spl_box_state_gs_begin gcloud || return 1
  dest="$(spl_box_state_dest "$pre")"
  gcloud storage rsync -r "$src" "$dest" --account="$GCP_ACCOUNT" --impersonate-service-account="$SPL_BOX_STATE_WRITER" || rc=$?
  (( rc == 0 )) || { do_log "FAIL $ENV: cannot sync $src to $dest as $SPL_BOX_STATE_WRITER (a changed file needs the step 056 grant on the RW prefix)"; return 1; }
  do_log "OK $ENV: $src -> $dest (as $SPL_BOX_STATE_WRITER, no remote delete)"
}
