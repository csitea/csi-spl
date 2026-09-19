#!/bin/bash
#------------------------------------------------------------------------------
# @description Resolve the gcloud identity ONCE per run, from the yaml conf, so
# @description every gcloud invocation in an action can pin it with `--account`
# @description instead of inheriting whatever the shared config happens to hold.
# @description
# @description Copied from csi-rel-{iac,orc} lib gcp-account-pin.func.sh, with ONE
# @description owner-directed change (2026-09-19): the last fallback is the conf
# @description key env.gcp.gcp_account_owner_email, NOT the currently ACTIVE
# @description gcloud account. The active account is whichever agent on this box
# @description ran `gcloud config set account` / `auth activate-service-account`
# @description last (~/.config/gcloud is ONE directory every agent writes), so a
# @description run that reads it pins somebody else's identity. No value from
# @description the env and none in the conf is a refusal, never a guess.
# @description
# @description `--project` says WHERE a call lands, never WHO it lands as; the
# @description project SAs hold roles/owner (gcp-003), so a wrong ambient identity
# @description succeeds SILENTLY against a project it can touch. Hence: pin every
# @description invocation.
# @description
# @description This file is kept byte-identical in csi-spl-iac and csi-spl-orc
# @description (csi-spl-iac src/bash/tests/gcloud-account-pinned.tst.sh checks).
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# @description Print one string value of the env.gcp section of the conf, or
# @description nothing. $2 is either a yaml FILE (read as is: e.g. the merged
# @description $SPL_CNF of csi-spl-orc) or a cnf DIR holding all.env.yaml and
# @description <ENV>.env.yaml, deep-merged (the env file wins, as do_tpl_gen).
# @description The default dir is $APP_PATH/$ORG-$APP-cnf/$ORG-$APP. With ENV
# @description unset only all.env.yaml is read.
# @param $1 the key under env.gcp, e.g. gcp_account_owner_email
# @param $2 (optional) the conf file or dir
# @example org=$(do_gcp_cnf_value gcp_org_id)
#------------------------------------------------------------------------------
do_gcp_cnf_value() {
  local key="${1:?key}" cnf="${2:-}"
  [[ -n "${cnf}" ]] || cnf="${APP_PATH:-}/${ORG:-}-${APP:-}-cnf/${ORG:-}-${APP:-}"
  command -v yq &>/dev/null || return 0

  local files=() val
  if [[ -f "${cnf}" ]]; then
    files=("${cnf}")
  elif [[ -d "${cnf}" ]]; then
    [[ -f "${cnf}/all.env.yaml" ]] && files+=("${cnf}/all.env.yaml")
    [[ -n "${ENV:-}" && -f "${cnf}/${ENV}.env.yaml" ]] && files+=("${cnf}/${ENV}.env.yaml")
  fi
  (( ${#files[@]} )) || return 0

  val=$(yq eval-all '. as $i ireduce ({}; . * $i)' "${files[@]}" 2>/dev/null |
    yq -r ".env.gcp.${key} // \"\"" 2>/dev/null)
  [[ "${val}" == null ]] && val=""
  printf '%s' "${val}"
}

#------------------------------------------------------------------------------
# @description Print the gcloud identity this run must pin, resolved ONCE.
# @description
# @description Precedence, most explicit first:
# @description   1. ACCOUNT                  per-run override (csi-rel's name)
# @description   2. GCP_ACCOUNT              explicit override, e.g. CI's project SA
# @description   3. GCP_ACCOUNT_OWNER_EMAIL  the conf key, when a caller already
# @description                               exported the env.gcp section
# @description   4. env.gcp.gcp_account_owner_email read from the conf ($1)
# @description
# @description Prints nothing, logs the yaml key to set and returns 1 when none
# @description resolves, so a caller refuses rather than falls through to ambient.
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
# @example GCP_ACCOUNT=$(do_gcp_account) || exit 1
#------------------------------------------------------------------------------
do_gcp_account() {
  local account="${ACCOUNT:-${GCP_ACCOUNT:-${GCP_ACCOUNT_OWNER_EMAIL:-}}}"
  [[ -n "${account}" ]] || account=$(do_gcp_cnf_value gcp_account_owner_email "${1:-}")

  if [[ -z "${account}" ]]; then
    do_log "FATAL no gcloud account: set env.gcp.gcp_account_owner_email in the cnf yaml (all.env.yaml or <env>.env.yaml), or ACCOUNT / GCP_ACCOUNT; the active gcloud account is never used" >&2
    return 1
  fi
  printf '%s' "${account}"
}

#------------------------------------------------------------------------------
# @description Resolve the account once, export it as GCP_ACCOUNT for the rest of
# @description this run (the name every csi-spl wrapper passes as --account) and
# @description log it. Idempotent: a second call in the same run (gcp-000 runs
# @description gcp-001..004) resolves to the same value.
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
# @example do_gcp_pin_account || exit 1
#------------------------------------------------------------------------------
do_gcp_pin_account() {
  local account
  account=$(do_gcp_account "${1:-}") || return 1
  export GCP_ACCOUNT="${account}"
  do_gcp_log_identity "${PROJ_ID:-${SPL_PROJECT:-<unset>}}" "${GCP_ACCOUNT}" "${FUNCNAME[1]:-}"
}

#------------------------------------------------------------------------------
# @description Print the org the bootstrap works in: GCP_ORG_ID when set (the
# @description env still overrides), else env.gcp.gcp_org_id from the conf.
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
# @example GCP_ORG_ID=$(do_gcp_org_id)
#------------------------------------------------------------------------------
do_gcp_org_id() {
  if [[ -n "${GCP_ORG_ID:-}" ]]; then
    printf '%s' "${GCP_ORG_ID}"
  else
    do_gcp_cnf_value gcp_org_id "${1:-}"
  fi
}

#------------------------------------------------------------------------------
# @description Log the pinned project and identity BEFORE anything is mutated,
# @description so the identity a run used is auditable after the fact rather
# @description than inferred from a shared config that has moved since.
# @param $1 the project the run is pinned to
# @param $2 the account the run is pinned to
# @param $3 (optional) short context, e.g. the calling function
#------------------------------------------------------------------------------
do_gcp_log_identity() {
  local project="${1:-<unset>}" account="${2:-<unset>}" context="${3:-}"
  local suffix=""
  [[ -n "${context}" ]] && suffix=" (${context})"
  do_log "INFO gcloud project=${project} account=${account} — pinned per invocation, not taken from the shared config${suffix}"
}
