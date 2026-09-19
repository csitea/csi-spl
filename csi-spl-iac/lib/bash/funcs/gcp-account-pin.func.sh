#!/bin/bash
#------------------------------------------------------------------------------
# @description Resolve the gcloud identity ONCE per run, so every gcloud
# @description invocation in an action can pin it with `--account` instead of
# @description inheriting whatever the shared config happens to hold.
# @description
# @description Owner rule (2026-09-19): "once the service account keys are
# @description provisioned, then you should be using only the service accounts
# @description per environment for everything. You should not be using the
# @description owner account." So the identity is the per-env project SA from
# @description its key ($HOME/.gcp/.<org>/key-<org>-<app>-<env>.json, minted by
# @description gcp-002), activated in a throwaway CLOUDSDK_CONFIG. The owner
# @description account (env.gcp.gcp_account_owner_email) is read ONLY by the
# @description human bootstrap gcp-000..004 (do_gcp_bootstrap_account), and
# @description only while no key exists yet. The active gcloud account is never
# @description read: ~/.config/gcloud is ONE directory every agent on this box
# @description writes. Nothing resolved is a refusal, never a guess.
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
# @description Succeed when CLOUDSDK_CONFIG names a private gcloud config, i.e.
# @description it is set and is NOT the shared default ~/.config/gcloud.
#------------------------------------------------------------------------------
do_gcp_config_isolated() {
  local cfg="${CLOUDSDK_CONFIG:-}" shared="${HOME:-/nonexistent}/.config/gcloud"
  [[ -n "${cfg}" ]] || return 1
  [[ "$(cd "${cfg}" 2>/dev/null && pwd -P)" != "$(cd "${shared}" 2>/dev/null && pwd -P)" ]]
}

#------------------------------------------------------------------------------
# @description Remove every private gcloud config do_gcp_isolate_config made in
# @description this shell (they hold an activated SA credential).
#------------------------------------------------------------------------------
do_gcp_cleanup_isolated_configs() {
  local d
  for d in ${_SPL_GCP_CFG_DIRS:-}; do rm -rf "${d}"; done
  _SPL_GCP_CFG_DIRS=""
}

#------------------------------------------------------------------------------
# @description Point this shell at a fresh private gcloud config (mode 700,
# @description removed on EXIT, chained before any EXIT trap already set), so
# @description an SA key can be activated without writing the shared config.
# @description A no-op when CLOUDSDK_CONFIG is already private. Must run in the
# @description caller's shell, not in $( ): the export is the point.
#------------------------------------------------------------------------------
do_gcp_isolate_config() {
  do_gcp_config_isolated && return 0
  local dir cur body=""
  dir="$(umask 077 && mktemp -d)" || return 1
  _SPL_GCP_CFG_DIRS="${_SPL_GCP_CFG_DIRS:-} ${dir}"
  cur="$(trap -p EXIT)"
  if [[ "${cur}" != *do_gcp_cleanup_isolated_configs* ]]; then
    [[ -n "${cur}" ]] && { eval "set -- ${cur}"; body="$3"; }
    # shellcheck disable=SC2064
    trap "do_gcp_cleanup_isolated_configs${body:+; ${body}}" EXIT
  fi
  export CLOUDSDK_CONFIG="${dir}"
  do_log "INFO gcloud runs under a private CLOUDSDK_CONFIG for this run; the shared ~/.config/gcloud is not written"
}

#------------------------------------------------------------------------------
# @description Print the per-env project SA key file, or nothing and return 1
# @description when there is none on disk. The project is the first of PROJ_ID,
# @description SPL_PROJECT, GCP_PROJECT, cnf env.gcp.gcp_project, <ORG>-<APP>-<ENV>;
# @description the key is $HOME/.gcp/.<org>/key-<project>.json (the gcp-002
# @description name). GCP_SA_KEY_FILE names the key file explicitly.
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
# @example key=$(do_gcp_sa_key_file) || echo "no key yet"
#------------------------------------------------------------------------------
do_gcp_sa_key_file() {
  local key="${GCP_SA_KEY_FILE:-}" project
  if [[ -z "${key}" ]]; then
    project="${PROJ_ID:-${SPL_PROJECT:-${GCP_PROJECT:-}}}"
    [[ -n "${project}" ]] || project=$(do_gcp_cnf_value gcp_project "${1:-}")
    [[ -n "${project}" || -z "${ORG:-}" || -z "${APP:-}" || -z "${ENV:-}" ]] || project="${ORG}-${APP}-${ENV}"
    [[ -n "${project}" ]] || return 1
    key="${HOME:-/nonexistent}/.gcp/.${project%%-*}/key-${project}.json"
  fi
  [[ -f "${key}" ]] || return 1
  printf '%s' "${key}"
}

#------------------------------------------------------------------------------
# @description Activate the SA key $1 in the PRIVATE gcloud config (refuses the
# @description shared one) unless it is already there, and print its
# @description client_email. The key itself is never printed.
# @param $1 the SA key file
#------------------------------------------------------------------------------
do_gcp_activate_sa_key() {
  local key="${1:?key}" email have
  email=$(jq -r '.client_email // ""' "${key}" 2>/dev/null)
  [[ -n "${email}" && "${email}" != null ]] || { do_log "FATAL no client_email in the SA key ${key}" >&2; return 1; }
  if ! do_gcp_config_isolated; then
    do_log "FATAL refusing to activate ${email} in the shared gcloud config: run under a private CLOUDSDK_CONFIG (do_gcp_pin_account makes one)" >&2
    return 1
  fi
  have=$(gcloud auth list --filter="account:${email}" --format='value(account)' 2>/dev/null | awk 'NR==1')
  if [[ "${have}" != "${email}" ]]; then
    gcloud auth activate-service-account --key-file="${key}" --quiet >/dev/null 2>&1 \
      || { do_log "FATAL gcloud could not activate the SA key ${key}" >&2; return 1; }
  fi
  printf '%s' "${email}"
}

#------------------------------------------------------------------------------
# @description Print the gcloud identity this run must pin, resolved ONCE.
# @description
# @description Precedence, most explicit first:
# @description   1. ACCOUNT      per-run override (csi-rel's name)
# @description   2. GCP_ACCOUNT  explicit override, e.g. CI's deploy SA
# @description   3. the per-env project SA from its key (do_gcp_sa_key_file),
# @description      activated in the private CLOUDSDK_CONFIG
# @description   4. REFUSE. The owner account is never a fallback here; only
# @description      do_gcp_bootstrap_account (gcp-000..004) may resolve it.
# @description
# @description Prints nothing, logs what to provide and returns 1 when none
# @description resolves, so a caller refuses rather than falls through.
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
# @example GCP_ACCOUNT=$(do_gcp_account) || exit 1
#------------------------------------------------------------------------------
do_gcp_account() {
  _do_gcp_resolve_account run "${1:-}"
}

#------------------------------------------------------------------------------
# @description do_gcp_account for the human bootstrap gcp-000..004 ONLY: the
# @description same precedence, then, while the project has no SA key yet,
# @description GCP_ACCOUNT_OWNER_EMAIL > cnf env.gcp.gcp_account_owner_email.
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
#------------------------------------------------------------------------------
do_gcp_bootstrap_account() {
  _do_gcp_resolve_account bootstrap "${1:-}"
}

_do_gcp_resolve_account() {
  local mode="${1:?mode}" cnf="${2:-}" account key
  account="${ACCOUNT:-${GCP_ACCOUNT:-}}"
  if [[ -n "${account}" ]]; then printf '%s' "${account}"; return 0; fi

  if key=$(do_gcp_sa_key_file "${cnf}"); then
    do_gcp_activate_sa_key "${key}"
    return
  fi

  if [[ "${mode}" == bootstrap ]]; then
    account="${GCP_ACCOUNT_OWNER_EMAIL:-}"
    [[ -n "${account}" ]] || account=$(do_gcp_cnf_value gcp_account_owner_email "${cnf}")
    if [[ -n "${account}" ]]; then
      do_log "INFO bootstrap: no project SA key yet, so the owner account from env.gcp.gcp_account_owner_email mints it" >&2
      printf '%s' "${account}"
      return 0
    fi
    do_log "FATAL no gcloud account: no project SA key and no env.gcp.gcp_account_owner_email in the cnf yaml; set ACCOUNT / GCP_ACCOUNT" >&2
    return 1
  fi

  do_log "FATAL no gcloud account: no project SA key at \$HOME/.gcp/.<org>/key-<org>-<app>-<env>.json (set ENV, or GCP_SA_KEY_FILE) and no ACCOUNT / GCP_ACCOUNT; the owner account is used only by the gcp-000..004 bootstrap, and the active gcloud account never" >&2
  return 1
}

#------------------------------------------------------------------------------
# @description Resolve the account once, export it as GCP_ACCOUNT for the rest of
# @description this run (the name every csi-spl wrapper passes as --account) and
# @description log it. When the identity comes from the SA key, first moves this
# @description shell to a private CLOUDSDK_CONFIG (do_gcp_isolate_config).
# @description Idempotent: a second call in the same run resolves to the same
# @description value (gcp-000 runs gcp-001..004).
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
# @example do_gcp_pin_account || exit 1
#------------------------------------------------------------------------------
do_gcp_pin_account() {
  _do_gcp_pin run "${1:-}"
}

#------------------------------------------------------------------------------
# @description do_gcp_pin_account for gcp-000..004 only (do_gcp_bootstrap_account).
# @param $1 (optional) the conf file or dir, as do_gcp_cnf_value
#------------------------------------------------------------------------------
do_gcp_pin_bootstrap_account() {
  _do_gcp_pin bootstrap "${1:-}"
}

_do_gcp_pin() {
  local mode="${1:?mode}" cnf="${2:-}" account
  if [[ -z "${ACCOUNT:-}${GCP_ACCOUNT:-}" ]] && do_gcp_sa_key_file "${cnf}" >/dev/null; then
    do_gcp_isolate_config || return 1
  fi
  account=$(_do_gcp_resolve_account "${mode}" "${cnf}") || return 1
  export GCP_ACCOUNT="${account}"
  do_gcp_log_identity "${PROJ_ID:-${SPL_PROJECT:-<unset>}}" "${GCP_ACCOUNT}" "${FUNCNAME[2]:-}"
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
# @description Print the account a run just activated or logged in INSIDE ITS
# @description OWN isolated gcloud config (CLOUDSDK_CONFIG set by the action to a
# @description private temp dir), so a ported action can re-pin --account to the
# @description only identity that config holds. Refuses (returns 1, prints
# @description nothing) when CLOUDSDK_CONFIG is unset or is the shared default
# @description dir: reading the SHARED active account is exactly the cross-agent
# @description race do_gcp_account removed.
# @example gcloud auth activate-service-account --key-file="$k"; account=$(do_gcp_isolated_active_account) || exit 1
#------------------------------------------------------------------------------
do_gcp_isolated_active_account() {
  local acct
  if ! do_gcp_config_isolated; then
    do_log "FATAL do_gcp_isolated_active_account: CLOUDSDK_CONFIG is not an isolated config; refusing to read the shared active account" >&2
    return 1
  fi
  # awk, not head: head closes the pipe early and SIGPIPEs gcloud under pipefail
  acct=$(gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null | awk 'NR==1')
  [[ -n "${acct}" ]] || { do_log "FATAL no active account in the isolated gcloud config ${CLOUDSDK_CONFIG}" >&2; return 1; }
  printf '%s' "${acct}"
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
