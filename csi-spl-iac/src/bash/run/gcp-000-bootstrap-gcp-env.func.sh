#!/bin/bash
#------------------------------------------------------------------------------
# @description Bootstrap one env's GCP prerequisites in order: gcp-001 (project +
# @description billing), gcp-002 (IaC SA + key), gcp-003 (roles/owner), gcp-004
# @description (bootstrap APIs). A thin orchestrator: every step is idempotent,
# @description dry-run by default and returns non-zero on its own failure; 000
# @description stops at the first one, so a later step never runs on an
# @description earlier step's unread state. Ported from csi-rel-iac gcp-000, minus its interactive
# @description login and `gcloud config set account`: the caller proves the
# @description identity (gcloud auth login GCP_ACCOUNT, as the box user) first.
# @param ENV - required: dev, prd, bkp (csi-spl-bkp, the off-project backups of iac 046) or all (csi-spl-all, the satellite of spec 057)
# @param GCP_ACCOUNT (optional) - overrides the resolved identity (do_gcp_bootstrap_account: the project SA key once it exists, else cnf env.gcp.gcp_account_owner_email, an org-level human identity; the ONLY actions that may resolve the owner)
# @param GCP_ORG_ID (optional) - overrides cnf env.gcp.gcp_org_id (gcp-002 sets the org policy there; gcp-001 parent)
# @param GCP_BILLING_ACCOUNT_ID - required by gcp-001
# @param DRY_RUN (optional) - 1 (default) for every step. 0: mutate.
# @example ENV=dev GCP_BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX ./run -a do_gcp_000_bootstrap_gcp_env
#------------------------------------------------------------------------------
do_gcp_000_bootstrap_gcp_env() {
  do_resolve_oap ORG
  do_resolve_oap APP
  GCP_ORG_ID=$(do_gcp_org_id)
  do_require_var GCP_ORG_ID "${GCP_ORG_ID:-}"
  export GCP_ORG_ID

  do_log "INFO ============================================"
  do_log "INFO Bootstrap GCP env ${ENV:-<unset>} DRY_RUN=${DRY_RUN:-1}"
  do_log "INFO ============================================"

  # Each step returns non-zero on failure (return, not exit: they are sourced
  # into the ./run shell) and 000 stops at the first one, passing its status
  # on (pinned by gcp-002-004-bootstrap.tst.sh "000 stops at the first ...").
  do_gcp_001_create_project || return $?
  do_gcp_002_create_project_service_account || return $?
  do_gcp_003_configure_proj_sa_permissions || return $?
  do_gcp_004_project_apis_enable || return $?

  do_log "OK Bootstrap complete for ${PROJ_ID:-?}; SA key: \$HOME/.gcp/.${ORG:-<org>}/key-${PROJ_ID:-<project>}.json"
}
