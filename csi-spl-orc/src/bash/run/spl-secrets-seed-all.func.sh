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
# @description Routed through do_spl_cloud_dispatch (spec 076 T006): the above
# @description is the gcp adapter; under SPOOL_CLOUD_PROVIDER=none it is
# @description do_secrets_seed_none: the self-host .env (mode 600) gets the
# @description missing Postgres passwords and the state dir its session.key,
# @description with no gcloud at all.
# @param ENV - required (gcp): dev or prd
# @param SPOOL_CLOUD_PROVIDER (optional) - gcp (default) | none | aws, else the cnf env.cloud.provider
# @param SPOOL_SELF_HOST_DIR (optional, none) - the dir holding .env (default: this checkout)
# @param SPOOL_STATE_DIR (optional, none) - the hub state dir holding session.key (default /var/lib/spool/state)
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param DRY_RUN (optional) - 1 (default): report only. 0: seed.
# @param STRIPE_API_BASE (optional) - when set, an injected empty webhook slot runs do_spl_provision_stripe_endpoints
# @param SPL_TFVARS_DIR (optional) - default: the rendered <org>-<app>-cnf/<org>-<app>/<env>/tf
# @example ENV=dev ./run -a do_spl_secrets_seed_all
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_secrets_seed_all
# @example SPOOL_CLOUD_PROVIDER=none DRY_RUN=0 ./run -a do_spl_secrets_seed_all
#------------------------------------------------------------------------------
do_spl_secrets_seed_all() {
  do_spl_cloud_dispatch secrets seed "$@"
}

# do_secrets_seed_gcp - the Secret Manager seed (the body of
# do_spl_secrets_seed_all before spec 076, unchanged).
do_secrets_seed_gcp() {
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

# ------------------------------------------------------------ provider none ---
# do_secrets_seed_none - fill what do_secrets_check_none finds empty, in the
# two self-host stores (spl-secrets-check.func.sh): each missing Postgres
# password of .env is generated (24 random bytes, hex, as do_spl_self_host_up
# does; a value already there is kept, so a second run changes nothing), the
# .env is rewritten whole with umask 077 and mode 600, and session.key is
# minted into an existing state dir (32 random bytes, hex, as hub-init does).
# An outside value (the SMTP password) and a public compose default are listed
# as NEED, never invented. Values never touch argv, stdout or a log.
do_secrets_seed_none() {
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local envf statef
  spl_secrets_none_paths || return 1

  local key req kind state
  local -a gen=() need=()
  while IFS=$'\t' read -r key req kind; do
    state="$(spl_secrets_none_state "$(spl_secrets_none_get "$envf" "$key")")"
    case "$state:$req:$kind" in
      set:*) do_log "KEEP $key: set in .env" ;;
      empty:*:gen) gen+=("$key") ;;
      empty:required:ask) need+=("$key (SPOOL_MAIL_TRANSPORT=smtp): set it in $envf, or re-run ./run -a do_spl_self_host_up") ;;
      default:required:*) need+=("$key is the public compose default: rotate it in Postgres, then in $envf") ;;
      *) do_log "SKIP $key: optional, not set" ;;
    esac
  done < <(spl_secrets_none_rows "$envf")

  local errs=0 count=${#gen[@]}
  spl_secrets_none_seed_env
  spl_secrets_none_seed_key

  local n
  for n in "${need[@]}"; do do_log "NEED $n"; done
  if (( dry )); then
    do_log "OK DRY_RUN for the self-host secrets: $count secret(s) would be generated, nothing written. Re-run with DRY_RUN=0."
    return 0
  fi
  local rc=0
  do_secrets_check_none || rc=1
  (( errs == 0 )) || rc=1
  return $rc
}

# spl_secrets_none_seed_env - the .env step of do_secrets_seed_none (reads its
# dry, envf and gen; counts a failure in its errs): generate each key of gen,
# rewrite .env whole (umask 077, mode 600), or only fix a loose mode.
spl_secrets_none_seed_env() {
  local key v fix_mode=0
  local -A val=()
  [[ -f "$envf" && "$(spl_secrets_none_mode "$envf")" != 600 ]] && fix_mode=1
  if (( dry )); then
    for key in "${gen[@]}"; do do_log "INFO DRY_RUN would generate $key into $envf (24 random bytes, hex)"; done
    (( fix_mode == 0 )) || do_log "INFO DRY_RUN would chmod 600 $envf"
    return 0
  fi
  if (( ${#gen[@]} == 0 )); then
    (( fix_mode )) || return 0
    chmod 600 "$envf" && do_log "INFO $envf: mode set to 600" || { do_log "ERROR cannot chmod 600 $envf"; errs=$((errs + 1)); }
    return 0
  fi
  for key in "${gen[@]}"; do
    v="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
    [[ ${#v} -eq 48 ]] || { do_log "ERROR could not generate $key"; errs=$((errs + 1)); continue; }
    val[$key]="$v"
  done
  local tmp="$envf.tmp.$$" line
  if (
    umask 077
    {
      if [[ -f "$envf" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= && -n "${val[${BASH_REMATCH[1]}]+x}" ]] || printf '%s\n' "$line"
        done <"$envf"
      else
        echo "# written by ./run -a do_spl_secrets_seed_all (spec 076, provider none); never commit it."
      fi
      for key in "${gen[@]}"; do [[ -n "${val[$key]+x}" ]] && printf "%s='%s'\n" "$key" "${val[$key]}"; done
    } >"$tmp"
  ) && chmod 600 "$tmp" && mv -f "$tmp" "$envf"; then
    for key in "${!val[@]}"; do do_log "INFO $key generated into $envf (value not logged)"; done
  else
    rm -f "$tmp"; do_log "ERROR cannot write $envf"; errs=$((errs + 1))
  fi
}

# spl_secrets_none_seed_key - the session.key step of do_secrets_seed_none
# (reads its dry and statef; counts into its count and errs): mint the key
# into an existing state dir, or fix a loose mode; no state dir on this host
# is hub-init's to fill.
spl_secrets_none_seed_key() {
  local sdir="${statef%/*}"
  if [[ ! -d "$sdir" ]]; then
    do_log "INFO session.key: no state dir $sdir on this host: hub-init mints it into the hub-state volume"
  elif [[ -s "$statef" ]]; then
    if [[ "$(spl_secrets_none_mode "$statef")" == 600 ]]; then do_log "KEEP session.key: present"
    elif (( dry )); then do_log "INFO DRY_RUN would chmod 600 $statef"
    else chmod 600 "$statef" && do_log "INFO session.key: mode set to 600" || { do_log "ERROR cannot chmod 600 $statef"; errs=$((errs + 1)); }
    fi
  else
    count=$((count + 1))
    if (( dry )); then
      do_log "INFO DRY_RUN would mint session.key into $sdir (32 random bytes, hex)"
    elif (umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$statef") && chmod 600 "$statef"; then
      do_log "INFO session.key minted into $sdir (value not logged)"
    else
      do_log "ERROR cannot write $statef"; errs=$((errs + 1))
    fi
  fi
}
