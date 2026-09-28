#!/bin/bash
#------------------------------------------------------------------------------
# @description Prove that NO load balancer resource exists in one cloud env
# @description (owner 2026-09-19, "exactly csi-rel: no load balancer"). Lists,
# @description UNFILTERED (no name prefix: a name filter can only find what was
# @description guessed, never prove absence), every resource kind an HTTP(S)
# @description LB is built from: forwarding rules (global + regional), target
# @description http/https proxies, url maps, backend services, backend buckets,
# @description NEGs, Cloud Armor security policies, ssl policies, ssl certs,
# @description reserved addresses, Certificate Manager certs + maps.
# @description Prints "<kind> <count> [names]" per kind; exit 0 only when every
# @description count is 0. A gcloud error is a FAIL (exit 2), never "none".
# @description Read-only, as the env SA in a throwaway CLOUDSDK_CONFIG.
# @param ENV - dev or prd
# @param SPL_SA_KEY (optional) - the env SA key file
# @example ENV=prd ./run -a do_spl_lb_absent_check
#------------------------------------------------------------------------------
do_spl_lb_absent_check() {
  do_require_bin gcloud || return 1
  spl_require_cloud_env || return 1
  do_spl_cloud_cnf || return 1
  local key cfg
  key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }
  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 2; }
    local account
    account="$(do_gcp_isolated_active_account)" || exit 2
    do_gcp_log_identity "$SPL_PROJECT" "$account" "do_spl_lb_absent_check"
    spl_lb_kinds_count "$SPL_PROJECT" "$account"
  )
  local rc=$?
  rm -rf "$cfg"
  case $rc in
    0) do_log "OK $ENV ($SPL_PROJECT): 0 load balancer resources" ;;
    1) do_log "FATAL $ENV ($SPL_PROJECT): load balancer resources remain (listed above)" ;;
    *) do_log "FATAL $ENV ($SPL_PROJECT): a list call failed; absence NOT proven" ;;
  esac
  return $rc
}

# spl_lb_kinds_count <project> <account> -> 0 none, 1 some exist, 2 a call failed
spl_lb_kinds_count() {
  local project="$1" account="$2" found=0 err=0 kind out n
  local kinds=(
    "compute forwarding-rules" "compute target-http-proxies" "compute target-https-proxies"
    "compute url-maps" "compute backend-services" "compute backend-buckets"
    "compute network-endpoint-groups" "compute security-policies" "compute ssl-policies"
    "compute ssl-certificates" "compute addresses"
    "certificate-manager certificates" "certificate-manager maps"
  )
  for kind in "${kinds[@]}"; do
    # shellcheck disable=SC2086
    if ! out="$(gcloud $kind list --project="$project" --account="$account" --format='value(name)' 2>&1)"; then
      printf '%-36s ERROR %s\n' "$kind" "$(tr '\n' ' ' <<<"$out" | cut -c1-200)"
      err=1
      continue
    fi
    n="$(grep -c . <<<"$out")"
    printf '%-36s %s %s\n' "$kind" "$n" "$(tr '\n' ' ' <<<"$out")"
    (( n > 0 )) && found=1
  done
  (( err )) && return 2
  (( found )) && return 1
  return 0
}
