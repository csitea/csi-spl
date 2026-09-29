#!/bin/bash
#------------------------------------------------------------------------------
# @description Resolve and export PROJ_ID for the gcp-00N bootstrap actions,
# @description the same way do_gcp_001_create_project does: ENV must be dev,
# @description prd or bkp (the off-project backup project, iac 046, which has
# @description no env file of its own), the id is <org>-<app>-<env>, and the committed cnf
# @description (env.gcp.gcp_project) must agree with it, so a worktree-derived
# @description ORG/APP can never name a different project. No GCP call.
# @param ENV - required: dev, prd or bkp
# @example do_gcp_spl_proj_id || exit 1; echo "$PROJ_ID"
#------------------------------------------------------------------------------
do_gcp_spl_proj_id() {
  do_resolve_oap ORG
  do_resolve_oap APP
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd || "${ENV:-}" == bkp ]] || { do_log "FATAL ENV must be dev, prd or bkp, got: '${ENV:-}'"; return 1; }

  local proj_id="${ORG}-${APP}-${ENV}"
  local cnf_file="${APP_PATH}/${ORG}-${APP}-cnf/${ORG}-${APP}/${ENV}.env.yaml"
  local cnf_proj=""
  if [[ -f "${cnf_file}" ]] && command -v yq &>/dev/null; then
    cnf_proj=$(yq -r '.env.gcp.gcp_project' "${cnf_file}" 2>/dev/null)
  fi
  if [[ -n "${cnf_proj}" && "${cnf_proj}" != "${proj_id}" ]]; then
    do_log "FATAL ${cnf_file} says gcp_project=${cnf_proj}, the convention says ${proj_id}; refusing"
    return 1
  fi
  export PROJ_ID="${proj_id}"
}
