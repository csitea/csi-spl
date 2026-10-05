#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed the passwords of the public dataset's two Postgres logins
# @description (spec 091 T004, fence 1) into Secret Manager, the
# @description spl-mail-secret-seed pattern: the slots are cnf
# @description public_dataset.export_password_secret (login export_login) and
# @description public_dataset.names_password_secret (login names_login). The
# @description value is MINTED here (openssl rand -hex 24), so no owner file.
# @description A slot that already has an enabled version is left alone (re-run
# @description = no change) unless ROTATE=1; a missing slot is created
# @description (user-managed replication in the cnf region, labels
# @description role=public-dataset). Every new version is verified by sha256 and,
# @description on ROTATE=1, the older versions are disabled. The value travels in
# @description a 0600 scratch file and gcloud's stdin (--data-file=-) only: never argv,
# @description stdout or a log. The hub never reads these slots.
# @description Next: do_spl_public_export_role sets the logins' passwords from
# @description these slots (run it after every ROTATE=1).
# @description Dry run unless DRY_RUN=0 (a dry run still reads slot states).
# @param ENV - required: dev or prd
# @param ROTATE (optional) - 1: add a new password even when one exists
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param DRY_RUN (optional) - 1 (default): report only. 0: create / add.
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_public_export_secret_seed
# @example ENV=dev DRY_RUN=0 ROTATE=1 ./run -a do_spl_public_export_secret_seed
#------------------------------------------------------------------------------
do_spl_public_export_secret_seed() {
  do_require_bin yq openssl sha256sum gcloud || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "${ROTATE:-0}" =~ ^[01]$ ]] || { do_log "FATAL ROTATE must be 0 or 1"; return 1; }
  [[ "$(do_spl_cloud_provider)" == gcp ]] || { do_log "FATAL do_spl_public_export_secret_seed is Secret Manager only (provider gcp)"; return 1; }

  local -a slots=()
  spl_public_export_slots slots || return 1

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN

  local s login slot state rc=0
  for s in "${slots[@]}"; do
    login="${s%%:*}" slot="${s#*:}"
    state="$(spl_secret_state "$slot")"
    if [[ "$state" == enabled && "${ROTATE:-0}" != 1 ]]; then
      do_log "OK $slot ($login) already has a password: nothing to add (ROTATE=1 to rotate)"
      continue
    fi
    if (( dry )); then
      do_log "OK DRY_RUN would $([[ "$state" == missing ]] && echo 'create the slot and ')add a new $login password to $slot in $SPL_PROJECT"
      continue
    fi
    spl_public_export_secret_put "$login" "$slot" "$state" "$h" || rc=1
  done
  (( rc == 0 )) || { do_log "FAIL public dataset login passwords for $ENV: see above"; return 1; }
  (( dry )) && { do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."; return 0; }
  do_log "OK public dataset login passwords for $ENV are in Secret Manager (values not logged). Next: ENV=$ENV DRY_RUN=0 ./run -a do_spl_public_export_role"
}

# spl_public_export_slots <array name> -> fills the array with
# "<login>:<slot>" for the export and the names login, from cnf
# public_dataset (both must be set and differ).
spl_public_export_slots() {
  local -n _out="$1"
  local el nl es ns
  IFS=$'\t' read -r el nl es ns < <(yq -r '[
      .env.public_dataset.export_login // "",
      .env.public_dataset.names_login // "",
      .env.public_dataset.export_password_secret // "",
      .env.public_dataset.names_password_secret // ""
    ] | @tsv' "$SPL_CNF")
  local v
  for v in "$el" "$nl" "$es" "$ns"; do
    [[ "$v" =~ ^[a-z][a-z0-9_-]*$ ]] || { do_log "FATAL cnf public_dataset export_login / names_login / *_password_secret is unset or malformed for $ENV"; return 1; }
  done
  [[ "$el" != "$nl" && "$es" != "$ns" ]] || { do_log "FATAL cnf public_dataset: the two logins and the two slots must differ"; return 1; }
  # shellcheck disable=SC2034 # a nameref to the caller's array
  _out=("$el:$es" "$nl:$ns")
}

# spl_public_export_secret_put <login> <slot> <state> <scratch dir> -> creates
# the slot when missing, adds a minted password as a new version, verifies it
# by sha256, and on ROTATE=1 disables the older versions.
spl_public_export_secret_put() {
  local login="$1" slot="$2" state="$3" h="$4" want have n
  if [[ "$state" == missing ]]; then
    gcloud secrets create "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
      --replication-policy=user-managed --locations="$SPL_REGION" \
      --labels="org=${SPL_ORG_APP%%-*},app=${SPL_ORG_APP#*-},env=$ENV,role=public-dataset" >/dev/null 2>&1 ||
      { do_log "FATAL could not create the slot $slot in $SPL_PROJECT (does $GCP_ACCOUNT hold secretmanager.secrets.create?)"; return 1; }
    do_log "INFO created the slot $slot in $SPL_PROJECT"
  fi
  (umask 077 && openssl rand -hex 24 | tr -d '\n' >"$h/$login") || return 1
  want="$(sha256sum <"$h/$login" | cut -d' ' -f1)"
  gcloud secrets versions add "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- <"$h/$login" >/dev/null 2>&1 ||
    { do_log "FATAL could not add a version to $slot"; return 1; }
  have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [[ "$have" == "$want" ]] || { do_log "FAIL $slot latest version does not read back what was added (sha256)"; return 1; }
  if [[ "${ROTATE:-0}" == 1 ]]; then
    n="$(spl_secret_disable_older "$slot")" || return 1
    do_log "INFO $slot: $n older version(s) disabled"
  fi
  do_log "OK $slot ($login): new password added and verified by sha256 (value not logged)"
}
