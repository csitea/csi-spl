#!/bin/bash
#------------------------------------------------------------------------------
# @description Import the live objects of a terraform step into its state,
#   THROUGH the tf-runner: for each row of tf-import-table.sh <step> that is
#   not already in state, `docker exec con-<org>-<app>-tf-runner ./run -a
#   do_tf_import` (the same call as `make do-tf-import`). IMPORT ONLY, never
#   apply. Idempotent: an address already in state (read with do_tf_state_list
#   in the same container) is skipped; a failed import (NotFound: not live) is
#   reported and skipped, non-fatal -- the next apply creates it.
#   A NEW TOOL, not a csi-rel port (csi-rel has no importer for these steps);
#   its model is csi-rel's tf-030 importer.
#   Steps: 020-gcp-relay-bucket, 040-cloud-sql-postgres.
# @param ENV - dev or prd [required]
# @param STEP - 020-gcp-relay-bucket | 040-cloud-sql-postgres [required]
# @param DRY_RUN - 1 = read the state and print the plan, import nothing [default: 0]
# @param CON_TF_RUNNER - tf-runner container [default: con-<ORG>-<APP>-tf-runner]
# @example ENV=dev STEP=040-cloud-sql-postgres DRY_RUN=1 ./run -a do_tf_import_existing
# @example ENV=prd STEP=020-gcp-relay-bucket ./run -a do_tf_import_existing
#------------------------------------------------------------------------------
do_tf_import_existing() {
  local env_name="${ENV:-}" step="${STEP:-}" dry_run="${DRY_RUN:-0}"
  case "$env_name" in
    dev|prd) ;;
    *) do_log "FATAL ENV must be one of dev|prd (got '${env_name}')"; return 1 ;;
  esac
  case "$step" in
    020-gcp-relay-bucket|040-cloud-sql-postgres) ;;
    *) do_log "FATAL STEP must be 020-gcp-relay-bucket or 040-cloud-sql-postgres (got '${step}')"; return 1 ;;
  esac

  # tfvars from THIS checkout (as do_tf_030_import_existing_cloud_run does).
  local orc_dir root
  orc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  root="$(cd "${orc_dir}/.." && pwd)"
  local table_sh="${orc_dir}/src/bash/scripts/tf-import-table.sh"
  local vars="${root}/csi-spl-cnf/csi-spl/${env_name}/tf/${step}.vars.tfvars"
  [[ -f "$vars" ]] || { do_log "FATAL missing tfvars $vars"; return 1; }

  local table
  table="$(sh "$table_sh" "$step" "$vars")" || { do_log "FATAL no import table for ${step}"; return 1; }

  # ORG / APP / container exactly as the tf-tasks make targets derive them.
  local org app
  org="$(APP_PATH="$root" ORG= APP= bash -c 'source "$0"; do_resolve_oap ORG; echo "$ORG"' "${orc_dir}/lib/bash/funcs/resolve-oap.func.sh")"
  app="$(APP_PATH="$root" ORG= APP= bash -c 'source "$0"; do_resolve_oap APP; echo "$APP"' "${orc_dir}/lib/bash/funcs/resolve-oap.func.sh")"
  local con="${CON_TF_RUNNER:-con-${org}-${app}-tf-runner}"

  command -v docker >/dev/null 2>&1 || { do_log "FATAL docker is required"; return 1; }
  docker ps --format '{{.Names}}' | grep -qxF "$con" || {
    do_log "FATAL tf-runner ${con} is not running (bring the orc stack up first)"
    return 1
  }

  local -a dexec=(docker exec -e "ORG=${org}" -e "ENV=${env_name}" -e "APP=${app#*-}" -e "STEP=${step}")

  do_log "INFO STATE LIST ${step} env=${env_name} via ${con}"
  local in_state
  if ! in_state="$("${dexec[@]}" "$con" ./run -a do_tf_state_list 2>&1)"; then
    do_log "FATAL do_tf_state_list failed for ${step} ${env_name}; importing nothing"
    printf '%s\n' "$in_state" | tail -n 5 >&2
    return 1
  fi

  local imported=0 skipped=0 failed=0 planned=0 addr id out
  while IFS=$'\t' read -r addr id; do
    [[ -n "$addr" ]] || continue
    if printf '%s\n' "$in_state" | grep -qxF "$addr"; then
      echo "SKIP  already in state: $addr"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ "$dry_run" == "1" ]]; then
      echo "PLAN  $addr  <-  $id"
      planned=$((planned + 1))
      continue
    fi
    echo "IMPORT $addr  <-  $id"
    out="$("${dexec[@]}" -e "TARGET=${addr}" -e "ID=${id}" "$con" ./run -a do_tf_import 2>&1)"
    # do_tf_import logs its verdict; its exit code does not carry it.
    if printf '%s\n' "$out" | grep -qF "OK Resource imported successfully"; then
      echo "OK    imported $addr"
      imported=$((imported + 1))
    else
      echo "WARN  could not import $addr (not live? -- skipped, non-fatal):"
      printf '%s\n' "$out" | grep -iE 'error|fatal' | head -n 3
      failed=$((failed + 1))
    fi
  done <<<"$table"

  echo "----------------------------------------------------------------"
  echo "${step} ${env_name}: imported=$imported skipped=$skipped failed=$failed planned=$planned"
  echo "Next: ENV=${env_name} STEP=${step} make do-tf-plan. This action never applies."
  return 0
}
