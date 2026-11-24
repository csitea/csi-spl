#!/bin/bash
#------------------------------------------------------------------------------
# @description Check every cnf env file against the JSON schema
# @description csi-spl-cnf/schema/env-schema.json (SPL-451, spec 011 T025,
# @description FR-R10): all.env.yaml as it is, and dev, prd and lde as their
# @description EFFECTIVE config (do_spl_merged_cnf: all.env.yaml deep-merged
# @description under <env>.env.yaml), the file tpl-gen renders from. A bad key
# @description fails with one line naming its path, e.g.
# @description "FAIL dev.env.yaml(+all): env.gcp.gcp_region: 5 is not of type 'string'".
# @description The schema is GENERATED from the pydantic models
# @description (conf_validator/env_schema_export.py), which stay the gate before
# @description tpl-gen; this check needs only jsonschema + pyyaml.
# @description Exit 0 = all valid, 1 = a file is invalid, 2 = NOTHING WAS
# @description VALIDATED (no jsonschema, no schema, a missing env file).
# @param ENVS (optional) - the env files to check, default "all dev prd lde"
# @param CNF_DIR (optional) - the dir of the env yaml, default $APP_PATH/<org>-<app>-cnf/<org>-<app>
# @param ENV_SCHEMA (optional) - the schema, default $APP_PATH/<org>-<app>-cnf/schema/env-schema.json
# @param PYTHON (optional) - interpreter with jsonschema + pyyaml, default the conf-validator .venv, else python3
# @example ./run -a do_check_env_schema
# @example ENVS="dev" CNF_DIR=/tmp/cnf ./run -a do_check_env_schema
#------------------------------------------------------------------------------
do_check_env_schema() {
  do_resolve_oap ORG
  do_resolve_oap APP
  do_require_bin yq || return 2
  local cnf_proj="$APP_PATH/$ORG-$APP-cnf"
  local cnf_dir="${CNF_DIR:-$cnf_proj/$ORG-$APP}"
  local schema="${ENV_SCHEMA:-$cnf_proj/schema/env-schema.json}"
  local vdir="$cnf_proj/src/python/conf-validator"
  local py="${PYTHON:-}"
  [[ -n "$py" ]] || { [[ -x "$vdir/.venv/bin/python" ]] && py="$vdir/.venv/bin/python"; } || py=python3
  local work env args=() rc=0
  work=$(mktemp -d) || return 2
  for env in ${ENVS:-all dev prd lde}; do
    if [[ "$env" == all ]]; then
      [[ -f "$cnf_dir/all.env.yaml" ]] || { do_log "FATAL NOTHING WAS VALIDATED: no $cnf_dir/all.env.yaml"; rc=2; break; }
      args+=("all.env.yaml=$cnf_dir/all.env.yaml")
      continue
    fi
    do_spl_merged_cnf "$cnf_dir" "$env" "$work/$env.env.yaml" ||
      { do_log "FATAL NOTHING WAS VALIDATED: cannot build the effective config of $env"; rc=2; break; }
    args+=("$env.env.yaml(+all)=$work/$env.env.yaml")
  done
  if [[ "$rc" -eq 0 ]]; then
    "$py" -I "$vdir/env_schema_check.py" "$schema" "${args[@]}"
    rc=$?
  fi
  rm -rf "$work"
  case "$rc" in
    0) do_log "INFO env schema: ${ENVS:-all dev prd lde} valid against $schema" ;;
    1) do_log "FATAL env schema: invalid key(s) above; fix the yaml (or, for a deliberate shape change, the pydantic model + a re-export)" ;;
    *) do_log "FATAL env schema: NOTHING WAS VALIDATED (rc $rc)"; rc=2 ;;
  esac
  return "$rc"
}
