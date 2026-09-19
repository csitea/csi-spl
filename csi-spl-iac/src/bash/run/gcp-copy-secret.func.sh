#!/bin/bash
#------------------------------------------------------------------------------
# @description Copy the latest version of one Secret Manager secret into a
# @description secret of this env's project (harvested from the 2026-09-19
# @description csi-rel-prd SMTP password -> csi-spl-prd copy, adhoc-harvest.md).
# @description Each side runs as ITS OWN project's service account (the source
# @description project's key reads the source, the env's key writes the
# @description target), both in one private gcloud config. The value travels
# @description on a pipe only: never argv, a file, stdout or a log; the check
# @description is by sha256. A version is added only when the target's latest
# @description differs. The target secret must exist (terraform owns slots).
# @description DRY_RUN=1 (default): read and compare, add nothing.
# @param ENV - required: dev or prd (the target project, from cnf)
# @param SRC_PROJECT - required: the source GCP project, e.g. csi-rel-prd
# @param SRC_SECRET - required: the source secret id
# @param TGT_SECRET - required: the target secret id in this env's project,
# @param   e.g. the cnf slot mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd SRC_PROJECT=csi-rel-prd SRC_SECRET=csi-rel-smtp-pass TGT_SECRET=csi-spl-hub-mail-smtp-password ./run -a do_gcp_copy_secret
#------------------------------------------------------------------------------
do_gcp_copy_secret() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN

  : "${SRC_PROJECT:?SRC_PROJECT must be set (the source GCP project)}"
  : "${SRC_SECRET:?SRC_SECRET must be set (the source secret id)}"
  : "${TGT_SECRET:?TGT_SECRET must be set (the target secret id)}"
  local dry="${DRY_RUN:-1}" id
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  for id in "$SRC_PROJECT" "$SRC_SECRET" "$TGT_SECRET"; do
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL not a project / secret id: '$id'"; return 1; }
  done
  do_gcp_spl_proj_id || return 1
  local tp="$PROJ_ID" ssa tsa
  # target: the env's project SA (cc7f79f); source: ITS project's own key
  do_gcp_pin_account || return 1
  tsa="$GCP_ACCOUNT"
  ssa="$(_gcp_env_sa "$SRC_PROJECT")" || return 1
  do_gcp_log_identity "$SRC_PROJECT" "$ssa" "do_gcp_copy_secret source"

  _cs_src() { gcloud secrets versions access latest --secret="$SRC_SECRET" --project="$SRC_PROJECT" --account="$ssa" 2>/dev/null; }
  _cs_tgt() { gcloud secrets versions access latest --secret="$TGT_SECRET" --project="$tp" --account="$tsa" 2>/dev/null; }
  local want n have rc=0
  want="$(_cs_src | sha256sum | cut -d' ' -f1)"
  n="$(_cs_src | wc -c)"
  if (( n == 0 )); then
    do_log "FATAL $SRC_PROJECT/$SRC_SECRET is unreadable or empty as $ssa"; rc=1
  elif ! gcloud secrets describe "$TGT_SECRET" --project="$tp" --account="$tsa" >/dev/null 2>&1; then
    do_log "FATAL $tp/$TGT_SECRET does not exist or is not visible to $tsa (terraform creates the slot)"; rc=1
  else
    do_log "INFO source $SRC_PROJECT/$SRC_SECRET readable: $n bytes (value not shown)"
    have="$(_cs_tgt | sha256sum | cut -d' ' -f1)"
    if [[ "$have" == "$want" ]]; then
      do_log "OK $tp/$TGT_SECRET already holds the source value (sha256): nothing to add"
    elif [[ "$dry" == 1 ]]; then
      do_log "OK DRY_RUN would add a version to $tp/$TGT_SECRET. Re-run with DRY_RUN=0 to copy."
    elif ! _cs_src | gcloud secrets versions add "$TGT_SECRET" --project="$tp" --account="$tsa" --data-file=- >/dev/null 2>&1; then
      do_log "FATAL could not add a version to $tp/$TGT_SECRET"; rc=1
    elif [[ "$(_cs_tgt | sha256sum | cut -d' ' -f1)" == "$want" ]]; then
      do_log "OK $tp/$TGT_SECRET: new version verified by sha256 (value not shown)"
    else
      do_log "ERROR $tp/$TGT_SECRET latest version does not match the source (sha256)"; rc=1
    fi
  fi
  unset -f _cs_src _cs_tgt
  return $rc
}

# _gcp_env_sa <project> -> activates <project>'s service-account key
# ($HOME/.gcp/.<org>/key-<project>.json, do_gcp_sa_key_file) in the CURRENT
# private CLOUDSDK_CONFIG (do_gcp_activate_sa_key refuses the shared one) and
# prints its account. Several projects may be activated in one private config.
_gcp_env_sa() {
  local key
  key="$(PROJ_ID="$1" GCP_SA_KEY_FILE='' do_gcp_sa_key_file)" ||
    { do_log "FATAL no service-account key for $1 at \$HOME/.gcp/.${1%%-*}/key-$1.json (gcp-002 mints it)" >&2; return 1; }
  do_gcp_activate_sa_key "$key"
}
