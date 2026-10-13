#!/bin/bash
#------------------------------------------------------------------------------
# @description The local hub's backups (lane L4): the dumps in the backups
# @description volume, newest last. Runs as the hub user (re-executes as it).
# @example ./run -a do_spl_local_hub_backup_list
#------------------------------------------------------------------------------
do_spl_local_hub_backup_list() {
  spl_lhb_as_hub_user do_spl_local_hub_backup_list || return "$SPL_LHB_RC"
  spl_lhb_env || return 1
  lde_compose run --rm -T backup list
}
