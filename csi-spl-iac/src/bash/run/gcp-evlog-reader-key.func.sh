#!/bin/bash
#------------------------------------------------------------------------------
# @description The key of the env's read-only event-log reader SA (spec 162
# @description section 10.4.3, row T7a, SPL-5882; owner poll 00d28227 Q1 B),
# @description one per env on each reader box. Terraform step
# @description 071-gcp-evlog-reader-sa makes the SA (cnf
# @description env.gcp.evlog_reader_sa_id, roles/logging.viewer only) and never
# @description its key; this action mints it out of band, on the owner's go:
# @description   DRY_RUN=1 (default) mints nothing, calls no gcloud, prints the
# @description            SA, the key path and, when the file exists, its age
# @description   DRY_RUN=0 one `gcloud iam service-accounts keys create`, as the
# @description            env's PROJECT SA (do_gcp_pin_account, --account on
# @description            every call), written ONLY to
# @description            $HOME/.gcp/.<org>/key-<project>-evlog-reader.json,
# @description            mode 600; refused while that file exists.
# @description   EVLOG_KEY_ROTATE=1 with DRY_RUN=0: the rotation (R9). A new
# @description            key replaces the file, is proven to read the
# @description            project's logs, then the old key id is deleted. Each
# @description            reader box holds its OWN key, never a copy, so this
# @description            needs neither the other-box proof nor the CI run of
# @description            do_gcp_sa_key_rotate, which rotates the one project
# @description            SA key every box and CI share.
# @description The key is never printed, logged or sent to stdout.
# @param ENV (required) - dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param EVLOG_KEY_ROTATE (optional) - 0 (default) or 1: replace an existing key; needed with DRY_RUN=0 when the key file exists
# @param SA_KEY_MAX_AGE_DAYS (optional) - 30, the age past which DRY_RUN=1 says rotate (the project SA key's cadence)
# @example ENV=dev ./run -a do_gcp_evlog_reader_key
# @example ENV=dev DRY_RUN=0 ./run -a do_gcp_evlog_reader_key
#------------------------------------------------------------------------------
do_gcp_evlog_reader_key() {
  local dry="${DRY_RUN:-1}" rot="${EVLOG_KEY_ROTATE:-0}" sa_id sa key
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 2; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$rot" == 0 || "$rot" == 1 ]] || { do_log "FATAL EVLOG_KEY_ROTATE must be 0 or 1, got: $rot"; return 2; }
  do_gcp_spl_proj_id || return 1
  sa_id="$(do_gcp_cnf_value evlog_reader_sa_id)"
  [[ "$sa_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { do_log "FATAL cnf env.gcp.evlog_reader_sa_id is not a service account id: '$sa_id'"; return 1; }
  sa="$sa_id@$PROJ_ID.iam.gserviceaccount.com"
  key="${HOME:?}/.gcp/.$ORG/key-$PROJ_ID-evlog-reader.json"
  do_log "INFO $ENV event-log reader SA: $sa"
  do_log "INFO $ENV its key file on this box: $key"
  if [[ "$dry" == 1 ]]; then
    gcp_evlog_reader_key_dry "$key" "$rot"
    return
  fi
  if [[ -e "$key" && "$rot" != 1 ]]; then
    do_log "FATAL $key exists: one key per env on this box. To replace it: EVLOG_KEY_ROTATE=1 DRY_RUN=0"; return 1
  fi
  if [[ ! -e "$key" && "$rot" == 1 ]]; then
    do_log "FATAL EVLOG_KEY_ROTATE=1 but there is no key at $key to rotate: mint one with DRY_RUN=0 alone"; return 1
  fi
  gcp_evlog_reader_key_run "$sa" "$key" "$rot"
}

# gcp_evlog_reader_key_dry <key> <rotate> - what DRY_RUN=0 would do; no gcloud
gcp_evlog_reader_key_dry() {
  local key="$1" rot="$2" age max="${SA_KEY_MAX_AGE_DAYS:-30}"
  if [[ -e "$key" ]]; then
    age=$(( ($(date +%s) - $(stat -c %Y "$key")) / 86400 ))
    do_log "INFO the key file exists, $age d old (max $max d)"
    (( age > max )) && do_log "WARN the reader key is past the $max d max age: rotate it"
    [[ "$rot" == 1 ]] && { do_log "OK DRY_RUN would mint a new key into $key (mode 600), prove it reads the logs, then delete the old key id"; return 0; }
    do_log "OK DRY_RUN nothing to mint; to rotate: ENV=$ENV EVLOG_KEY_ROTATE=1 DRY_RUN=0 ./run -a do_gcp_evlog_reader_key (with the owner's go)"
    return 0
  fi
  do_log "OK DRY_RUN would mint one key into $key (mode 600) as the $ENV project SA; nothing minted"
  do_log "NEXT with the owner's go: ENV=$ENV DRY_RUN=0 ./run -a do_gcp_evlog_reader_key"
}

# gcp_evlog_reader_key_run <sa> <key> <rotate> - as the project SA, in a
# throwaway gcloud config: mint, and on a rotation prove and retire the old key
gcp_evlog_reader_key_run() {
  local sa="$1" key="$2" rot="$3" _spl_sdk_saved _spl_sdk_dir old="" tmp
  do_require_bin jq || return 1
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  do_gcp_pin_account || return 1
  [[ "$GCP_ACCOUNT" != "$sa" ]] || { do_log "FATAL the pinned identity is the reader SA itself: run as the $ENV project SA"; return 1; }
  if [[ "$rot" == 1 ]]; then
    old="$(jq -r '.private_key_id // ""' "$key" 2>/dev/null)"
    [[ -n "$old" ]] || { do_log "FATAL the key file $key has no private_key_id: not rotating it"; return 1; }
    [[ ! -e "$key.prev" ]] || { do_log "FATAL $key.prev exists: an earlier rotation did not finish; check it, then remove it by hand"; return 1; }
  fi
  ( umask 077; mkdir -p "$(dirname "$key")" ) || { do_log "FATAL cannot make $(dirname "$key")"; return 1; }
  tmp="$(dirname "$key")/.$(basename "$key").new.$$"
  ( umask 077; gcloud iam service-accounts keys create "$tmp" --iam-account="$sa" --project="$PROJ_ID" \
      --account="$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1 ) ||
    { rm -f "$tmp"; do_log "FATAL gcloud could not create a key for $sa as $GCP_ACCOUNT (is step 071 applied in $PROJ_ID?)"; return 1; }
  chmod 600 "$tmp"
  [[ "$(do_gcp_sa_key_email "$tmp")" == "$sa" ]] ||
    { rm -f "$tmp"; do_log "FATAL the new key is not a key of $sa: discarded (its id stays in GCP: delete it by hand)"; return 1; }
  if [[ -n "$old" ]]; then
    mv "$key" "$key.prev" || { rm -f "$tmp"; do_log "FATAL cannot keep $key as $key.prev"; return 1; }
  fi
  mv "$tmp" "$key" || { do_log "FATAL could not move the new key into $key; it is at $tmp"; return 1; }
  do_log "OK new key $(jq -r '.private_key_id' "$key") of $sa written to $key (mode 600)"
  [[ -n "$old" ]] || return 0
  gcp_evlog_reader_key_retire "$sa" "$key" "$old"
}

# gcp_evlog_reader_key_retire <sa> <key> <old key id> - the new key reads the
# project's logs, then the old key id is deleted (as the project SA) and
# <key>.prev removed. A failed proof keeps the old key: nothing deleted.
gcp_evlog_reader_key_retire() {
  local sa="$1" key="$2" old="$3"
  [[ "$(do_gcp_activate_sa_key "$key")" == "$sa" ]] ||
    { do_log "FATAL the new key does not activate: the old key $old is kept ($key.prev)"; return 1; }
  gcloud logging read 'severity>=ERROR' --project="$PROJ_ID" --limit=1 --freshness=1h --format='value(timestamp)' \
    --account="$sa" --quiet </dev/null >/dev/null 2>&1 ||
    { do_log "FATAL the new key cannot read the logs of $PROJ_ID: the old key $old is kept ($key.prev)"; return 1; }
  gcloud iam service-accounts keys delete "$old" --iam-account="$sa" --project="$PROJ_ID" \
    --account="$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1 ||
    { do_log "FATAL the new key works, but gcloud could not delete the old key $old of $sa: delete it by hand, then remove $key.prev"; return 1; }
  rm -f "$key.prev"
  do_log "OK rotated: the new key reads the logs of $PROJ_ID; the old key $old is deleted and $key.prev removed"
}
