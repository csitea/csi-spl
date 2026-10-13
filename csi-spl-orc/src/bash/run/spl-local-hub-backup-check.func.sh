#!/bin/bash
#------------------------------------------------------------------------------
# @description The local hub's backups (lane L4): 0 when the keys are fit for
# @description the daily job: the recipient (private config
# @description LOCAL_HUB_BACKUP_RECIPIENT_FILE, default <config
# @description dir>/backup-key/recipient) is a world-readable age PUBLIC key,
# @description and LOCAL_HUB_BACKUP_IDENTITY_FILE, when set, is
# @description passphrase-wrapped (a clear key is refused). Prints env names,
# @description never a key. Runs as the hub user (re-executes as it).
# @param LOCAL_HUB_BACKUP_IDENTITY_FILE (optional) - checked when set
# @example ./run -a do_spl_local_hub_backup_check
#------------------------------------------------------------------------------
do_spl_local_hub_backup_check() {
  spl_lhb_as_hub_user do_spl_local_hub_backup_check LOCAL_HUB_BACKUP_IDENTITY_FILE || return "$SPL_LHB_RC"
  spl_lhb_env && spl_lhb_keys_ok
}
