#!/bin/bash
#------------------------------------------------------------------------------
# @description Stop the wine-box VM. DRY_RUN defaults to 1: a real
# @description call needs DRY_RUN=0. The dev project SA only (do_gcp_pin_account),
# @description --account on the gcloud call. Destroy is not this action:
# @description   cd csi-spl-orc && ENV=dev STEP=061-gcp-vm-wine-box make do-tf-plan-destroy
# @description   cd csi-spl-orc && ENV=dev STEP=058-gcp-wine-box-budget make do-tf-plan-destroy
# @param DRY_RUN (optional) - 1: print the plan. Default 1.
# @example DRY_RUN=0 ./run -a do_spl_wine_box_stop
# start is spl-wine-box-start.func.sh: ./run registers one action per file name.
#------------------------------------------------------------------------------
_wine_box_power() {
  local verb=$1 proj zone vm
  command -v gcloud >/dev/null 2>&1 || { do_log "FATAL gcloud is not installed"; return 1; }
  proj=$(do_spl_wine_box_cnf gcp_project) || return 1
  zone=$(do_spl_wine_box_cnf gcp_zone) || return 1
  vm=$(do_spl_wine_box_cnf vm_name) || return 1
  unset ACCOUNT GCP_ACCOUNT
  export PROJ_ID="$proj"
  do_gcp_pin_account || return 1
  do_log "INFO destroy stays a plan: cd csi-spl-orc && ENV=dev STEP=061-gcp-vm-wine-box make do-tf-plan-destroy"
  do_log "INFO and the budget: cd csi-spl-orc && ENV=dev STEP=058-gcp-wine-box-budget make do-tf-plan-destroy"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO DRY_RUN would run: gcloud compute instances ${verb} ${vm} --zone=${zone} --project=${proj} --account=<pinned>"
    return 0
  fi
  gcloud compute instances "$verb" "$vm" --zone="$zone" --project="$proj" --account="$GCP_ACCOUNT"
}

do_spl_wine_box_stop() { _wine_box_power stop; }
