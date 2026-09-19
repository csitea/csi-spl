#!/bin/env bash

#------------------------------------------------------------------------------
# @description Tail / query GCP Cloud Logging for one or all environments.
#              Authenticates with the per-environment service account key and
#              runs `gcloud logging read` with sensible defaults.
#
# @param ENV        - target environment: dev | tst | prd | all  (required)
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
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
  # Pin the gcloud identity for this run (spec 012 C-2). `--project` says WHERE
  # a call lands, never WHO it lands as, and `~/.config/gcloud` is one directory
  # shared by every agent on this box — `gcloud config set account` and
  # `auth activate-service-account` are both global writes, so the ambient
  # account is whichever agent ran one last. Resolved ONCE here so another
  # agent cannot move this run's identity between two of its own calls, passed
  # explicitly to each call below, and logged before the first of them so the
  # identity is auditable afterwards rather than inferable from a config file
  # that will have moved by the time anyone looks.
  local account
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "${project_id:-<unset>}" "${account}" "do_gcp_tail_logs"

  do_resolve_oap ORG
  do_resolve_oap APP

  do_require_var ENV "${ENV:-}"

  local lines="${LINES:-50}"
  local freshness="${FRESHNESS:-1h}"
  local severity="${SEVERITY:-DEFAULT}"
  local extra_filter="${FILTER:-}"
  local format="${FORMAT:-text}"

  # Expand ENV=all into the standard envs
  local envs=()
  if [[ "$ENV" == "all" ]]; then
    envs=(dev tst prd)
  else
    case "$ENV" in
      dev|tst|prd) envs=("$ENV") ;;
      *)
        do_log "FATAL ENV must be one of: dev, tst, prd, all"
        return 1
        ;;
    esac
  fi

  for env in "${envs[@]}"; do
    local project_id="${ORG}-${APP}-${env}"
    local key_file="$HOME/.gcp/.${ORG}/key-${project_id}.json"

    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  ENV: ${env}   PROJECT: ${project_id}"
    echo "═══════════════════════════════════════════════════════════════════════"

    if [[ ! -f "$key_file" ]]; then
      do_log "ERROR Key file not found: $key_file — skipping ${env}"
      continue
    fi

    # Authenticate with the environment's service account
    do_log "INFO Authenticating with $key_file"
    if ! gcloud auth activate-service-account --key-file="$key_file" --quiet 2>/dev/null; then
      do_log "ERROR Failed to authenticate for ${env} — skipping"
      continue
    fi
    account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"

    gcloud config set project "$project_id" --quiet 2>/dev/null

    # Build the filter expression
    local filter_parts=()

    if [[ "$severity" != "DEFAULT" ]]; then
      filter_parts+=("severity>=${severity}")
    fi

    if [[ -n "$extra_filter" ]]; then
      filter_parts+=("${extra_filter}")
    fi

    local filter_str=""
    if [[ ${#filter_parts[@]} -gt 0 ]]; then
      filter_str=$(IFS=" AND "; echo "${filter_parts[*]}")
    fi

    do_log "INFO Reading logs — freshness=${freshness} lines=${lines} severity=${severity}"
    [[ -n "$filter_str" ]] && do_log "INFO Filter: ${filter_str}"
    echo ""

    local gcloud_args=(
      logging read
      --project="$project_id"
      --limit="$lines"
      --freshness="$freshness"
      --order=desc
    )

    case "$format" in
      json)  gcloud_args+=(--format="json") ;;
      table) gcloud_args+=(--format="table(timestamp,severity,textPayload,jsonPayload.message)") ;;
      *)     gcloud_args+=(--format="value(timestamp,severity,textPayload,jsonPayload.message)") ;;
    esac

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

  done
}
