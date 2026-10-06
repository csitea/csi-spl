#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Run the csi-rel do_provision_firebase_dns (copied UNCHANGED from
#              csi-rel-iac, provision-firebase-dns.func.sh) for one csi-spl env,
#              as that env's PROJECT SERVICE ACCOUNT (owner rule 2026-09-19:
#              never the owner account). Setup only, no DNS logic here:
#                - a throwaway CLOUDSDK_CONFIG with the env SA key activated, so
#                  --account=<SA> resolves and the shared ~/.config/gcloud is
#                  never touched;
#                - DNS_ZONE / DNS_ZONE_PROJECT from cnf 025 (the env's own zone:
#                  prd apex zone, dev subzone), FIREBASE_PROJECT / SITE_ID from
#                  cnf gcp_project / 019 site_id (csi-rel derives them from the
#                  APP_PATH basename, which is a worktree id outside the main
#                  checkout).
#              FQDN defaults to the zone apex (prd <domain>, dev dev.<domain>),
#              exactly as csi-rel. Spec 007 §3 (owner: WUI domains as csi-rel).
# @param ENV - required: dev or prd
# @example ENV=prd ./run -a do_provision_firebase_dns_env
#------------------------------------------------------------------------------
do_provision_firebase_dns_env() {
  do_require_var ENV "${ENV:-}"
  [[ "${ENV}" == dev || "${ENV}" == prd ]] || quit_on "ENV must be dev or prd, got: ${ENV}"

  local cnf="${APP_PATH}/${ORG:-csi}-${APP:-spl}-cnf/${ORG:-csi}-${APP:-spl}/${ENV}.env.json"
  [[ -f "${cnf}" ]] || cnf="${PROJ_PATH}/../csi-spl-cnf/csi-spl/${ENV}.env.json"
  [[ -f "${cnf}" ]] || quit_on "cnf not found: ${cnf} (run ENV=${ENV} ./run -a do_tpl_gen)"

  local proj zone site
  read -r proj zone site < <(python3 - "${cnf}" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["env"]
print(e["gcp"]["gcp_project"], e["steps"]["025-gcp-dns-zone"]["zone_name"], e["steps"]["019-firebase-static-site"]["site_id"])
PY
)
  [[ -n "${zone}" ]] || quit_on "cnf steps.025-gcp-dns-zone.zone_name is empty for ${ENV}"

  local key="${HOME}/.gcp/.${ORG:-csi}/key-${proj}.json"
  [[ -f "${key}" ]] || quit_on "SA key not found: ${key}"

  # the config holds the activated SA credential. A RETURN trap alone misses an
  # exit and an interrupt, so an EXIT trap removes it too until this function
  # returns; the RETURN trap then puts the caller's EXIT trap back.
  local cfg sa caller_exit_trap
  cfg=$(mktemp -d)
  caller_exit_trap=$(trap -p EXIT)
  # shellcheck disable=SC2064
  trap "rm -rf '${cfg:?}'" EXIT
  trap 'rm -rf "${cfg}"; eval "${caller_exit_trap:-trap - EXIT}"; trap - RETURN' RETURN
  # an unreadable key leaves sa empty; the activate below then quits on it
  sa=$(do_gcp_sa_key_email "${key}")
  CLOUDSDK_CONFIG="${cfg}" gcloud auth activate-service-account --key-file="${key}" >/dev/null 2>&1 \
    || { rm -rf "${cfg}"; quit_on "could not activate ${sa} from ${key}"; }

  local rc=0
  CLOUDSDK_CONFIG="${cfg}" ACCOUNT="${sa}" DNS_ZONE="${zone}" DNS_ZONE_PROJECT="${proj}" \
    FIREBASE_PROJECT="${proj}" SITE_ID="${site}" \
    do_provision_firebase_dns || rc=$?
  return "${rc}"
}
