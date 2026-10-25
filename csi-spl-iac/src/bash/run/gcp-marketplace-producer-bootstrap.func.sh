#!/bin/bash
#------------------------------------------------------------------------------
# @description Print the producer-project plan for the Marketplace listing.
# @description DRY_RUN defaults to 1 and creates nothing. DRY_RUN=0 refuses:
# @description the live path waits for a later owner-GO lane.
# @param DRY_RUN (optional) - 1 (default) prints the plan. 0 refuses.
# @param MKT_PUBLIC_PROJECT (optional) - default csi-spl-public.
# @param MKT_PUBLIC_REGION (optional) - default europe-north1.
# @param MKT_RELEASE_BUCKET (optional) - default <project>-mkt-releases.
# @example DRY_RUN=1 ./run -a do_gcp_marketplace_producer_bootstrap
#------------------------------------------------------------------------------

do_gcp_marketplace_producer_bootstrap_plan() {
  local project region bucket
  project="${MKT_PUBLIC_PROJECT:-csi-spl-public}"
  region="${MKT_PUBLIC_REGION:-europe-north1}"
  bucket="${MKT_RELEASE_BUCKET:-${project}-mkt-releases}"
  case "$project" in
    csi-spl-dev|csi-spl-prd)
      do_log "FATAL project ${project} is an estate project"
      return 1
      ;;
  esac
  do_log "INFO plan project=${project} region=${region} bucket=gs://${bucket}"
  do_log "INFO would run: gcloud services enable compute.googleapis.com --project=${project}"
  do_log "INFO would grant roles/editor and roles/servicemanagement.admin to cloud-commerce-marketplace-onboarding@twosync-src.google.com"
  do_log "INFO would grant roles/servicemanagement.configEditor to cloud-commerce-producer@system.gserviceaccount.com"
  do_log "INFO would run: gcloud storage buckets create gs://${bucket} --project=${project} --location=${region} --uniform-bucket-level-access --public-access-prevention"
  do_log "INFO would enable versioning on gs://${bucket}"
  do_log "INFO owner steps skipped: designated security contact, Project Info Form"
  return 0
}

do_gcp_marketplace_producer_bootstrap() {
  local dry
  dry="${DRY_RUN:-1}"
  case "$dry" in
    1)
      if ! do_gcp_marketplace_producer_bootstrap_plan; then
        return 1
      fi
      do_log "OK DRY_RUN complete: nothing was created"
      return 0
      ;;
    0)
      do_log "FATAL live mutation waits for a later owner-GO lane"
      return 1
      ;;
    *)
      do_log "FATAL DRY_RUN must be 0 or 1, got: ${dry}"
      return 1
      ;;
  esac
}
