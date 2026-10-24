#!/bin/env bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"

#------------------------------------------------------------------------------
# @description Tail / query GCP Cloud Logging for one or all environments.
#              Authenticates with the per-environment service account key and
#              runs `gcloud logging read` with sensible defaults.
#
# @param ENV        - target environment: dev | tst | prd | all  (required);
#                     each env reads as its own project SA (ACCOUNT /
#                     GCP_ACCOUNT override it); all refuses GCP_SA_KEY_FILE,
#                     PROJ_ID, SPL_PROJECT and GCP_PROJECT (one project)
# @param LINES      - max log entries to return            (default: 50)
# @param FRESHNESS  - how far back to look, e.g. 1h 6h 1d (default: 1h)
# @param SEVERITY   - minimum severity level               (default: DEFAULT  = all)
#                     use ERROR, WARNING, INFO, DEBUG, etc.
# @param FILTER     - extra gcloud logging filter string   (default: empty)
# @param FORMAT     - output format: text | json | table   (default: text)
#
# @example ENV=dev ./run -a do_gcp_tail_logs
# @example ENV=prd SEVERITY=ERROR FRESHNESS=6h ./run -a do_gcp_tail_logs
# @example ENV=all LINES=20 SEVERITY=WARNING ./run -a do_gcp_tail_logs
# @example ENV=dev FILTER="resource.type=\"cloud_run_revision\"" ./run -a do_gcp_tail_logs
# @example ENV=prd FORMAT=json LINES=10 ./run -a do_gcp_tail_logs
#------------------------------------------------------------------------------
do_gcp_tail_logs() {
  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  # ORG, APP and ENV first: the identity is the per-env project SA from
  # $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json, so resolving it before them
  # looked for a key with no project and refused (SPL-3260).
  do_resolve_oap ORG
  do_resolve_oap APP

  do_require_var ENV "${ENV:-}"

  _gcp_tail_logs_check_env "$ENV" || return 1
  # Expand ENV=all into the standard envs. Each env resolves its OWN identity
  # in _gcp_tail_logs_env: one account for all three would read two projects
  # as the wrong SA. A one-project pin would do exactly that, so it refuses.
  local envs=("$ENV") env n_read=0
  if [[ "$ENV" == "all" ]]; then
    envs=(dev tst prd)
    if [[ -n "${GCP_SA_KEY_FILE:-}${PROJ_ID:-}${SPL_PROJECT:-}${GCP_PROJECT:-}" ]]; then
      do_log "FATAL GCP_SA_KEY_FILE / PROJ_ID / SPL_PROJECT / GCP_PROJECT name one project: set ENV to one env, not all"
      return 1
    fi
  fi

  for env in "${envs[@]}"; do
    _gcp_tail_logs_env "$env" "${LINES:-50}" "${FRESHNESS:-1h}" "${SEVERITY:-DEFAULT}" "${FILTER:-}" "${FORMAT:-text}" \
      && n_read=$((n_read + 1))
  done
  # an env without an identity is skipped; none read at all is a failure
  [[ $n_read -gt 0 ]]
}

# _gcp_tail_logs_check_env <ENV>: one of the standard envs or all, else fatal
_gcp_tail_logs_check_env() {
  case "$1" in
    dev|tst|prd|all) ;;
    *)
      do_log "FATAL ENV must be one of: dev, tst, prd, all"
      return 1
      ;;
  esac
}

# _gcp_tail_logs_filter <severity> <extra_filter> -> the filter expression,
# its parts space-joined (IFS uses only its first char; Cloud Logging ANDs
# adjacent terms); empty when there is none
_gcp_tail_logs_filter() {
  local severity="$1" extra_filter="$2" filter_parts=()

  if [[ "$severity" != "DEFAULT" ]]; then
    filter_parts+=("severity>=${severity}")
  fi

  if [[ -n "$extra_filter" ]]; then
    filter_parts+=("${extra_filter}")
  fi

  if [[ ${#filter_parts[@]} -gt 0 ]]; then
    (IFS=" AND "; echo "${filter_parts[*]}")
  fi
}

# _gcp_tail_logs_format <format> -> the --format argument for `logging read`
_gcp_tail_logs_format() {
  case "$1" in
    json)  echo '--format=json' ;;
    table) echo '--format=table(timestamp,severity,textPayload,jsonPayload.message)' ;;
    *)     echo '--format=value(timestamp,severity,textPayload,jsonPayload.message)' ;;
  esac
}

# _gcp_tail_logs_env <env> <lines> <freshness> <severity> <extra_filter> <format>
# -> the rc of the logging read; resolves the env's identity ONCE (spec 012 C-2: ACCOUNT > GCP_ACCOUNT > the
# env's project SA key, activated in the private config), logs it before the
# first gcloud call, and reads its logs as it; returns 1, skipping the env,
# when no identity resolves. `--project` says WHERE a call lands, never WHO it
# lands as, so the account is passed explicitly to the call.
_gcp_tail_logs_env() {
  local env="$1" lines="$2" freshness="$3" severity="$4" extra_filter="$5" format="$6"
  local project_id="${ORG}-${APP}-${env}"
  local key_file="$HOME/.gcp/.${ORG}/key-${project_id}.json"
  local account filter_str

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "  ENV: ${env}   PROJECT: ${project_id}"
  echo "═══════════════════════════════════════════════════════════════════════"

  if ! account=$(ENV="$env" do_gcp_account); then
    do_log "ERROR no gcloud identity for ${env} (no ACCOUNT / GCP_ACCOUNT, no key at ${key_file}) — skipping ${env}"
    return 1
  fi
  do_gcp_log_identity "$project_id" "$account" "do_gcp_tail_logs"

  filter_str=$(_gcp_tail_logs_filter "$severity" "$extra_filter")

  do_log "INFO Reading logs — freshness=${freshness} lines=${lines} severity=${severity}"
  [[ -n "$filter_str" ]] && do_log "INFO Filter: ${filter_str}"
  echo ""

  local gcloud_args=(
    logging read
    --project="$project_id"
    --limit="$lines"
    --freshness="$freshness"
    --order=desc
    "$(_gcp_tail_logs_format "$format")"
  )

  if [[ -n "$filter_str" ]]; then
    gcloud "${gcloud_args[@]}" "$filter_str" --account="${account}" --project="$project_id"
  else
    gcloud "${gcloud_args[@]}" --account="${account}" --project="$project_id"
  fi

  local exit_code=$?
  echo ""
  if [[ $exit_code -eq 0 ]]; then
    do_log "OK Done for ${env}"
  else
    do_log "ERROR gcloud logging read failed for ${env} (exit ${exit_code})"
  fi
  return "$exit_code"
}
