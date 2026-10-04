#!/bin/bash
#------------------------------------------------------------------------------
# @description The shell cloud dispatch router (spec 076 T004, spec.md 4.2):
# @description do_spl_cloud_dispatch <family> <verb> [args...] resolves the
# @description provider with do_spl_cloud_provider (SPOOL_CLOUD_PROVIDER >
# @description the effective cnf's env.cloud.provider > gcp) and calls
# @description do_<family>_<verb>_<provider> [args...].
# @description
# @description The contract T005..T008 (and the aws adapters, T014) build on:
# @description 1. An adapter is a function named do_<family>_<verb>_<provider>,
# @description    provider one of gcp | none | aws; family and verb are
# @description    [a-z][a-z0-9_]* (e.g. hub_deploy verify -> do_hub_deploy_verify_none).
# @description 2. The args reach the adapter untouched (each word as given,
# @description    spaces kept); its stdout and stderr are the caller's, and its
# @description    exit code is the router's.
# @description 3. No fallback, ever: a provider with no adapter for the action
# @description    is a FATAL on stderr naming the function looked for, return 1.
# @description    A none box never reaches a gcp adapter (so never gcloud).
# @description 4. An unknown provider is do_spl_cloud_provider's FATAL, return 1;
# @description    a bad call (no family / verb, or not [a-z][a-z0-9_]*) returns 2.
# @description    Router FATALs go to stderr, so stdout stays the adapter's data.
# @param SPOOL_CLOUD_PROVIDER (optional) - gcp | none | aws, wins over the cnf
# @example do_spl_cloud_dispatch db_proxy start
# @example SPOOL_CLOUD_PROVIDER=none do_spl_cloud_dispatch hub_deploy verify "$url"
#------------------------------------------------------------------------------
do_spl_cloud_dispatch() {
  local family="${1-}" verb="${2-}" provider target re='^[a-z][a-z0-9_]*$'
  if [[ $# -lt 2 || ! "$family" =~ $re || ! "$verb" =~ $re ]]; then
    do_log "FATAL usage: do_spl_cloud_dispatch <family> <verb> [args], family and verb [a-z][a-z0-9_]*; got: '$family' '$verb'" >&2
    return 2
  fi
  shift 2
  # shellcheck source=spl-cloud-cnf.func.sh
  declare -F do_spl_cloud_provider >/dev/null || source "${BASH_SOURCE[0]%/*}/spl-cloud-cnf.func.sh"
  # do_log prints to stdout, so the provider's FATAL lands in the capture:
  # hand it on to stderr rather than lose it.
  provider="$(do_spl_cloud_provider)" || { [[ -n "$provider" ]] && printf '%s\n' "$provider" >&2; return 1; }
  target="do_${family}_${verb}_${provider}"
  declare -F "$target" >/dev/null || {
    do_log "FATAL cloud provider '$provider' has no adapter for ${family} ${verb}: $target is not defined (no fallback to another provider)" >&2
    return 1
  }
  "$target" "$@"
}
