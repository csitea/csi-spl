#!/bin/bash
#------------------------------------------------------------------------------
# @description Fill every EMPTY Secret Manager slot of an env with one command
# @description (spec 072 A30, research 09 K2): the seven seed actions, in
# @description order, only for the slots that still have no enabled version
# @description (the slot table and states of do_spl_secrets_check; a slot with
# @description a version is skipped, so a second run adds 0 versions).
# @description   generated, no input: the DB DSNs (do_spl_db_bootstrap), the
# @description     session key (minted here: 48 random bytes, base64, stdin to
# @description     --data-file=-), the box-wui key, the release-note bans.
# @description     Seeded whenever empty, injected or not.
# @description   outside values (SMTP, IdP, payment): only for a slot the
# @description     rendered 030 tfvars INJECT; a disabled IdP or rail is never a
# @description     question. Their seeds read the owner files they name; a
# @description     missing file is listed at the end as what you still provide.
# @description A failing seed does not stop the next one. Values never touch
# @description argv, stdout or a log. Ends with do_spl_secrets_check (real run).
# @description Dry run unless DRY_RUN=0 (each seed then runs in its own dry run).
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param DRY_RUN (optional) - 1 (default): report only. 0: seed.
# @param STRIPE_API_BASE (optional) - when set, an injected empty webhook slot runs do_spl_provision_stripe_endpoints
# @param SPL_TFVARS_DIR (optional) - default: the rendered <org>-<app>-cnf/<org>-<app>/<env>/tf
# @example ENV=dev ./run -a do_spl_secrets_seed_all
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_secrets_seed_all
#------------------------------------------------------------------------------
do_spl_secrets_seed_all() {
  do_require_bin gcloud yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local rows
  rows="$(spl_secrets_slots)" || return 1

  local slot envvar req kind seed state c
  local -a cmds=() need=() failed=()
  local session_slot="" blocked=0
  while IFS=$'\t' read -r slot envvar req kind seed; do
    [[ -n "$slot" ]] || continue
    state="$(spl_secret_state "$slot")"
    if [[ "$state" == enabled ]]; then
      do_log "KEEP $slot: has an enabled version"; continue
    fi
    if [[ "$state" == missing ]]; then
      if [[ "$req" == required ]]; then
        do_log "WAIT $slot: no such slot in $SPL_PROJECT: apply $(spl_secret_step "$envvar") first"; blocked=$((blocked + 1))
      fi
      continue
    fi
    if [[ "$kind" == ask && "$req" != required ]]; then
      do_log "SKIP $slot: $envvar is not injected for $ENV: nothing to ask"; continue
    fi
    if [[ -z "$seed" ]]; then
      need+=("$slot: no seed action known for $envvar"); continue
    fi
    if [[ "$envvar" == SPOOL_HUB_AUTH_SESSION_KEY ]]; then
      session_slot="$slot"; continue
    fi
    for c in "${cmds[@]}"; do [[ "$c" == "$seed" ]] && continue 2; done
    cmds+=("$seed")
  done <<<"$rows"

  if [[ -n "$session_slot" ]]; then
    if (( dry )); then
      do_log "INFO DRY_RUN would add a version to $session_slot (48 random bytes, base64)"
    elif head -c 48 /dev/urandom | base64 -w0 |
        gcloud secrets versions add "$session_slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1; then
      do_log "INFO $session_slot: version added (value not logged)"
    else
      do_log "ERROR could not add a version to $session_slot"; failed+=("$session_slot")
    fi
  fi

  local pre act
  for c in "${cmds[@]}"; do
    pre="" act="${c##*./run -a }"
    [[ "$c" == *=*" ./run -a "* ]] && pre="${c%% ./run -a *}"
    if [[ "$pre" == STRIPE_API_BASE=* ]]; then
      [[ -n "${STRIPE_API_BASE:-}" ]] || { need+=("set STRIPE_API_BASE, then: ENV=$ENV DRY_RUN=0 $c"); continue; }
      pre=""
    fi
    do_log "INFO seed: ENV=$ENV DRY_RUN=$dry $c"
    if ( [[ -z "$pre" ]] || export "${pre?}"; DRY_RUN="$dry" "$act" ); then :; else
      failed+=("$c")
      need+=("fix what $act logged above (an owner file or a step), then: ENV=$ENV DRY_RUN=0 $c")
    fi
  done

  local n count=${#cmds[@]}
  [[ -z "$session_slot" ]] || count=$((count + 1))
  for n in "${need[@]}"; do do_log "NEED $n"; done
  if (( dry )); then
    (( ${#failed[@]} == 0 )) || { do_log "FAIL DRY_RUN: ${#failed[@]} seed(s) cannot run as things stand: see NEED above"; return 1; }
    do_log "OK DRY_RUN for $SPL_PROJECT: $count seed(s) would run, nothing added. Re-run with DRY_RUN=0."
    return 0
  fi
  local rc=0
  do_spl_secrets_check || rc=1
  (( ${#failed[@]} == 0 && blocked == 0 )) || rc=1
  return $rc
}
