#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Remove resources from the terraform state of one env + step.
# @description The state is pulled to a timestamped 0600 backup file FIRST, and
# @description a failed, empty or non-state backup aborts before any state rm.
# @description Dry run by default: lists what TARGET matches and removes
# @description nothing; DRY_RUN=0 removes. The state lock is kept unless
# @description FORCE=1, which adds -lock=false (only for a lock held by a dead
# @description run). Restore a backup with TFSTATE_FILE=<backup> do_tf_state_push.
# @param TARGET comma separated resource addresses
# @param DRY_RUN 1 (default) lists only, 0 removes
# @param FORCE 1 skips the state lock, 0 (default) keeps it
# @param TF_STATE_BACKUP_DIR the backup dir, default $PROJ_PATH/dat/tf-state-backup
# @example ENV=dev STEP=<step> TARGET=<addr> ./run -a do_tf_state_remove
# @example ENV=dev STEP=<step> TARGET=<addr>,<addr> DRY_RUN=0 ./run -a do_tf_state_remove
#------------------------------------------------------------------------------
do_tf_state_remove() {

  do_log "INFO START ::: provisioning step ${STEP:-}"

  TARGET=${TARGET:?}
  local dry_run="${DRY_RUN:-1}" lock_flag="" backup target rc=0

  do_tf_init

  backend_config_path="$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/$ENV/tf/$tf_proj.backend-config.tfvars"

  if [[ "${FORCE:-0}" == 1 ]]; then
    lock_flag="-lock=false"
    do_log "WARNING FORCE=1: the state lock is NOT taken for this state rm"
  fi

  terraform -chdir=${tf_run_path} init -backend-config=$backend_config_path -upgrade \
    || { do_log "FATAL terraform init failed, nothing removed"; return 1; }
  terraform -chdir=${tf_run_path} get -update=true \
    || { do_log "FATAL terraform get failed, nothing removed"; return 1; }

  backup=$(_tf_state_remove_backup) || { do_log "FATAL no state backup, so no state rm"; return 1; }
  do_log "INFO state backup: ${backup}"

  while IFS=',' read -ra TARGETS; do
    for target in "${TARGETS[@]}"; do
      [[ -n "${target}" ]] || continue
      if [[ "${dry_run}" != 0 ]]; then
        do_log "INFO DRY_RUN: would remove ${target}; it matches:"
        terraform -chdir=${tf_run_path} state list ${target} || rc=1
      else
        terraform -chdir=${tf_run_path} state rm ${lock_flag} ${target} || rc=1
      fi
    done
  done <<<"$TARGET"

  rm -rf ${tf_run_path}

  [[ "${dry_run}" != 0 ]] && do_log "INFO DRY_RUN: nothing removed; DRY_RUN=0 removes"
  do_simple_log "INFO STOP  ::: provisioning step ${tf_proj}"
  return ${rc}
}

#------------------------------------------------------------------------------
# @description Pull the state of $tf_run_path to a new 0600 file under a 0700
# @description dir and print its path. Returns 1, leaving no file behind, when
# @description the pull fails or does not look like a terraform state. Logs go
# @description to stderr: stdout is the path.
#------------------------------------------------------------------------------
_tf_state_remove_backup() {
  local dir="${TF_STATE_BACKUP_DIR:-${PROJ_PATH}/dat/tf-state-backup}" file
  file="${dir}/${ORG}-${APP}-${ENV}-${tf_proj}-$(date -u +%Y%m%dT%H%M%SZ)-$$.tfstate"
  if ! (umask 077 && mkdir -p "${dir}" && terraform -chdir=${tf_run_path} state pull >"${file}"); then
    rm -f "${file}"
    do_log "FATAL terraform state pull failed into ${file}" >&2
    return 1
  fi
  if ! grep -q '"serial"' "${file}"; then
    rm -f "${file}"
    do_log "FATAL the pulled state is empty or not a terraform state" >&2
    return 1
  fi
  chmod 600 "${file}"
  printf '%s' "${file}"
}
