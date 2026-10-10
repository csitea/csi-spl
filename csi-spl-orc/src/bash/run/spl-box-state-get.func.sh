#!/bin/bash
#------------------------------------------------------------------------------
# @description Download an object, or every object under a prefix, of the env's
# @description box state bucket (iac 056) to a local dir with gcloud storage,
# @description mounted or not. Read as the env's project SA (--account pinned).
# @description The dir is created 0700: a backup holds agent transcripts.
# @param ENV - required: dev or prd
# @param SRC - required: a relative object path; ending in / = a whole prefix
# @param DEST - required: the local dir to download into
# @param DRY_RUN (optional) - 1 (default): print the plan; 0 downloads
# @example ENV=dev SRC=shared/notes/ DEST=/var/tmp/notes ./run -a do_spl_box_state_get
# @example ENV=dev SRC=shared/notes/ DEST=/var/tmp/notes DRY_RUN=0 ./run -a do_spl_box_state_get
#------------------------------------------------------------------------------
do_spl_box_state_get() {
  spl_require_cloud_env || return 1
  local dry=1 drc src="${SRC:-}" dest="${DEST:-}" uri
  if spl_dry_run; then :; else drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ -n "$src" ]] || { do_log "FATAL SRC is required: the object or prefix (ending /) to download"; return 1; }
  spl_box_state_rel SRC "$src" || return 1
  [[ -n "$dest" ]] || { do_log "FATAL DEST is required: the local dir to download into"; return 1; }
  if (( dry )); then
    spl_box_state_gs_begin || return 1
    do_log "OK $ENV DRY_RUN: would download gs://$SPL_BOX_STATE_BUCKET/$src into $dest. DRY_RUN=0 downloads it."
    return 0
  fi
  spl_box_state_gs_begin gcloud || return 1
  (umask 077 && mkdir -p "$dest") || { do_log "FATAL cannot create $dest"; return 1; }
  uri="gs://$SPL_BOX_STATE_BUCKET/$src"
  [[ "$src" == */ ]] && uri="$uri*"
  gcloud storage cp -r "$uri" "$dest/" --account="$GCP_ACCOUNT" ||
    { do_log "FAIL $ENV: cannot download gs://$SPL_BOX_STATE_BUCKET/$src as $GCP_ACCOUNT"; return 1; }
  do_log "OK $ENV: gs://$SPL_BOX_STATE_BUCKET/$src -> $dest ($(find "$dest" -type f | wc -l) file(s) there)"
}
