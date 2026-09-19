#!/bin/bash
#------------------------------------------------------------------------------
# @description Require a list of variables to be set and non-empty.
# @description Extracted from the upstream run.sh helper of the same name so the
# @description ported gcp-* actions can call it without replacing this module's
# @description run.sh. Function body is unchanged.
# @param var_list (required) - One or more variable names (positional arguments)
# @example do_require_run_vars ORG APP ENV
#------------------------------------------------------------------------------
do_require_run_vars() {
  local var_list=("$@")
  local set_vars=()
  local unset_vars=()

  for var in "${var_list[@]}"; do
    if [[ -v $var && -n "${!var}" ]]; then
      set_vars+=("$var=${!var}")
    else
      unset_vars+=("$var")
    fi
  done

  if [[ ${#unset_vars[@]} -gt 0 ]]; then
    echo "FATAL: The following variables are not set or empty:" >&2
    printf '%s\n' "${unset_vars[@]}" >&2
    return 1
  fi

  printf "All required variables are set and non-empty:\n"
  printf '%s\n' "${set_vars[@]}" | sort
  return 0
}
