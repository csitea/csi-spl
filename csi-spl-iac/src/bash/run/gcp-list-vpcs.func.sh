#!/bin/bash

#------------------------------------------------------------------------------
# @description list VPCs, subnets, and peerings for all GCP project environments,
# @description into $APP_PATH/<APP>-cnf/<APP>/gcp/networking-report.txt too.
# @description Each env runs as its own project SA (do_gcp_each_env_sa).
# @example ORG=csi APP=csi-spl ./run -a do_gcp_list_vpcs
#------------------------------------------------------------------------------
_gcp_list_vpcs_one() {
  local project="$1" account="$2" env="$3"
  local vpc="vpc-${ORG}-${APP}-${env}-back"
  echo "START ::: ${project} gcp project entries:" | tee -a "${NETWORKING_REPORT_PATH}"
  do_log "INFO Listing VPCs for project ${project}..."
  {
    gcloud compute networks list --account="${account}" --project="${project}"
    gcloud compute networks peerings list --network="${vpc}" --account="${account}" --project="${project}"
    gcloud compute networks subnets list --network="${vpc}" --account="${account}" --project="${project}"
  } | tee -a "${NETWORKING_REPORT_PATH}"

  if [[ "${env}" != "all" ]]; then
    local peering="peer-${ORG}-${APP}-${env}-to-all-back" state
    do_log "INFO Checking peering status for ${peering}..."
    state=$(gcloud compute networks peerings describe "${peering}" --network="${vpc}" --format="value(state)" --account="${account}" --project="${project}" 2>/dev/null)
    if [[ "${state}" == "ACTIVE" ]]; then
      do_log "INFO Peering ${peering} is ACTIVE."
    else
      do_log "INFO Peering ${peering} is NOT ACTIVE or does not exist."
    fi
    echo "PEERING_STATUS: ${state}" | tee -a "${NETWORKING_REPORT_PATH}"
  fi
  echo "STOP  ::: ${project} gcp project entries:" | tee -a "${NETWORKING_REPORT_PATH}"
}

do_gcp_list_vpcs() {
  do_resolve_oap ORG
  do_resolve_oap APP
  NETWORKING_REPORT_PATH="${APP_PATH}/${APP}-cnf/${APP}/gcp/networking-report.txt"
  mkdir -p "$(dirname "${NETWORKING_REPORT_PATH}")"
  echo "" >"${NETWORKING_REPORT_PATH}"

  do_gcp_each_env_sa _gcp_list_vpcs_one

  do_log "INFO produced the following report file:"
  do_log "INFO ${NETWORKING_REPORT_PATH}"
}
