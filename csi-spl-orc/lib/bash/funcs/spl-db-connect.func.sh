#!/bin/bash
#------------------------------------------------------------------------------
# The connect block of the read-only hub Postgres actions (refactor r5-04):
# do_spl_db_rls_check, do_spl_db_period_count_check, do_spl_consumer_lag,
# do_spl_db_message_show and do_spl_hub_member_list call it.
#------------------------------------------------------------------------------

# spl_db_require_bins <provider> -> rc 0 when the binaries the provider needs
# are on PATH: psql and python3, plus gcloud unless the provider is none.
spl_db_require_bins() {
  if [[ "$1" == none ]]; then
    do_require_bin psql python3
  else
    do_require_bin gcloud psql python3
  fi
}

# spl_db_query_rc <provider> <query fn> -> the query fn's rc, run with $dsn
# bound to the hub runtime login (spl_db_runtime_local); 1 when no login.
# The query fn sees the caller's locals (dynamic scope) and stops the proxy.
# provider none: the local Postgres, no gcloud call. Otherwise the env's
# project SA key (SPL_SA_KEY, default $HOME/.gcp/.<org>/key-<project>.json)
# activated in a throwaway CLOUDSDK_CONFIG, never the shared one. That dir
# holds the activated credential: the subshell's EXIT trap removes it on every
# subshell exit (an interrupt too), the rm after it is the backstop. No RETURN
# trap here: bash fires a RETURN trap when the function that set it returns.
spl_db_query_rc() {
  local _sdq_provider="$1" _sdq_query="$2"
  if [[ "$_sdq_provider" == none ]]; then
    # shellcheck disable=SC2034 # read by the query fn, via dynamic scope
    local dsn _sdq_rc=0
    spl_db_runtime_local || return 1
    "$_sdq_query" || _sdq_rc=$?
    unset dsn
    return "$_sdq_rc"
  fi
  local _sdq_key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$_sdq_key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $_sdq_key (set SPL_SA_KEY)"; return 1; }
  local _sdq_cfg _sdq_rc=0
  _sdq_cfg="$(mktemp -d)" || return 1
  (
    trap 'rm -rf "$_sdq_cfg"' EXIT
    export CLOUDSDK_CONFIG="$_sdq_cfg"
    gcloud auth activate-service-account --key-file="$_sdq_key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $_sdq_key"; exit 1; }
    GCP_ACCOUNT="$(do_gcp_isolated_active_account)" || exit 1
    export GCP_ACCOUNT
    spl_db_runtime_local || exit 1
    "$_sdq_query"
    exit $?
  ) || _sdq_rc=$?
  rm -rf "$_sdq_cfg"
  return "$_sdq_rc"
}
