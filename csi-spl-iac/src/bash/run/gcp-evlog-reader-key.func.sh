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
# @description            key is proven to read the project's logs from its
# @description            temp file, only then replaces the file, then the
# @description            old key id is deleted. A failed proof deletes the
# @description            new key id and leaves the key file as it was. Each
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
# throwaway gcloud config: mint; on a rotation prove the new key BEFORE it
# replaces the key file, then retire the old key id
gcp_evlog_reader_key_run() {
  local sa="$1" key="$2" rot="$3" _spl_sdk_saved _spl_sdk_dir old="" tmp new
  do_require_bin jq || return 1
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  do_gcp_pin_account || return 1
  [[ "$GCP_ACCOUNT" != "$sa" ]] || { do_log "FATAL the pinned identity is the reader SA itself: run as the $ENV project SA"; return 1; }
  if [[ "$rot" == 1 ]]; then
    old="$(jq -r '.private_key_id // ""' "$key" 2>/dev/null)"
    [[ -n "$old" ]] || { do_log "FATAL the key file $key has no private_key_id: not rotating it"; return 1; }
    gcp_evlog_reader_key_prev_refuse "$sa" "$key" || return 1
  fi
  ( umask 077; mkdir -p "$(dirname "$key")" ) || { do_log "FATAL cannot make $(dirname "$key")"; return 1; }
  tmp="$(dirname "$key")/.$(basename "$key").new.$$"
  ( umask 077; gcloud iam service-accounts keys create "$tmp" --iam-account="$sa" --project="$PROJ_ID" \
      --account="$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1 ) ||
    { rm -f "$tmp"; do_log "FATAL gcloud could not create a key for $sa as $GCP_ACCOUNT (is step 071 applied in $PROJ_ID?)"; return 1; }
  chmod 600 "$tmp"
  [[ "$(do_gcp_sa_key_email "$tmp")" == "$sa" ]] ||
    { rm -f "$tmp"; do_log "FATAL the new key is not a key of $sa: discarded (its id stays in GCP: delete it by hand)"; return 1; }
  new="$(jq -r '.private_key_id // ""' "$tmp")"
  if [[ -n "$old" ]]; then
    gcp_evlog_reader_key_prove "$sa" "$key" "$tmp" "$new" || return 1
    mv "$key" "$key.prev" || { gcp_evlog_reader_key_drop "$sa" "$key" "$tmp" "$new" "cannot keep $key as $key.prev"; return 1; }
  fi
  mv "$tmp" "$key" || { do_log "FATAL could not move the new key $new into $key; it is at $tmp"; return 1; }
  do_log "OK new key $new of $sa written to $key (mode 600)"
  [[ -n "$old" ]] || return 0
  gcp_evlog_reader_key_retire "$sa" "$key" "$old"
}

# gcp_evlog_reader_key_prev_refuse <sa> <key> - refuses while <key>.prev is
# there: an earlier rotation stopped after the swap; its old key id may
# still be live in GCP
gcp_evlog_reader_key_prev_refuse() {
  local sa="$1" key="$2" pid
  [[ -e "$key.prev" ]] || return 0
  pid="$(jq -r '.private_key_id // "<unreadable>"' "$key.prev" 2>/dev/null)"
  do_log "FATAL $key.prev exists: an earlier rotation did not finish. It holds key $pid of $sa, which stays live in GCP until deleted: delete it as the $ENV project SA (gcloud iam service-accounts keys delete $pid --iam-account=$sa --project=$PROJ_ID --account=<the $ENV project SA>), then remove $key.prev"
  return 1
}

# gcp_evlog_reader_key_prove <sa> <key> <tmp> <new id> - the new key, still in
# its temp file, activates and reads the project's logs as the reader SA. A
# failure drops it: the key file keeps the old key, untouched.
gcp_evlog_reader_key_prove() {
  local sa="$1" key="$2" tmp="$3" new="$4"
  [[ "$(do_gcp_activate_sa_key "$tmp")" == "$sa" ]] ||
    { gcp_evlog_reader_key_drop "$sa" "$key" "$tmp" "$new" "the new key does not activate"; return 1; }
  gcloud logging read 'severity>=ERROR' --project="$PROJ_ID" --limit=1 --freshness=1h --format='value(timestamp)' \
    --account="$sa" --quiet </dev/null >/dev/null 2>&1 ||
    { gcp_evlog_reader_key_drop "$sa" "$key" "$tmp" "$new" "the new key cannot read the logs of $PROJ_ID"; return 1; }
}

# gcp_evlog_reader_key_drop <sa> <key> <tmp> <new id> <why> - an unproven new
# key: its temp file removed, its id deleted in GCP (as the project SA); the
# key file is not touched
gcp_evlog_reader_key_drop() {
  local sa="$1" key="$2" tmp="$3" new="$4" why="$5"
  rm -f "$tmp"
  if gcloud iam service-accounts keys delete "$new" --iam-account="$sa" --project="$PROJ_ID" \
      --account="$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1; then
    do_log "FATAL $why: the new key $new is deleted in GCP; $key still holds the old key, unchanged"
  else
    do_log "FATAL $why, and gcloud could not delete the new key $new of $sa: it stays live in GCP until deleted by hand; $key still holds the old key, unchanged"
  fi
}

# gcp_evlog_reader_key_retire <sa> <key> <old key id> - after the swap: the
# old key id is deleted (as the project SA) and <key>.prev removed
gcp_evlog_reader_key_retire() {
  local sa="$1" key="$2" old="$3"
  gcloud iam service-accounts keys delete "$old" --iam-account="$sa" --project="$PROJ_ID" \
    --account="$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1 ||
    { do_log "FATAL the new, proven key is in $key, but gcloud could not delete the old key $old of $sa: it stays live in GCP until deleted (gcloud iam service-accounts keys delete $old --iam-account=$sa --project=$PROJ_ID --account=<the $ENV project SA>), then remove $key.prev"; return 1; }
  rm -f "$key.prev"
  do_log "OK rotated: the new key read the logs of $PROJ_ID before the swap; the old key $old is deleted and $key.prev removed"
}
