#!/bin/bash
#------------------------------------------------------------------------------
# @description List the env's box state bucket (iac 056) with gcloud storage,
# @description mounted or not: object names, sizes and times only, never
# @description content. Read as the env's project SA (--account pinned).
# @param ENV - required: dev or prd
# @param PREFIX (optional) - a relative object path, e.g. shared/ or box1/2026-10-10/
# @param RECURSIVE (optional) - 1 lists every object under PREFIX (default 0: one level)
# @example ENV=dev ./run -a do_spl_box_state_ls
# @example ENV=dev PREFIX=shared/ RECURSIVE=1 ./run -a do_spl_box_state_ls
#------------------------------------------------------------------------------
do_spl_box_state_ls() {
  spl_require_cloud_env || return 1
  local pre="${PREFIX:-}"
  local -a rec=()
  spl_box_state_rel PREFIX "$pre" empty-ok || return 1
  case "${RECURSIVE:-0}" in 0) ;; 1) rec=(-r) ;; *) do_log "FATAL RECURSIVE must be 0 or 1"; return 1 ;; esac
  spl_box_state_gs_begin gcloud || return 1
  gcloud storage ls -l "${rec[@]}" "gs://$SPL_BOX_STATE_BUCKET/$pre" --account="$GCP_ACCOUNT" ||
    { do_log "FAIL $ENV: cannot list gs://$SPL_BOX_STATE_BUCKET/$pre as $GCP_ACCOUNT"; return 1; }
}
