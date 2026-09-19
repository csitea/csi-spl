#!/usr/bin/env bash
# File: lib/bash/funcs/define-all-run-vars.sh

do_define_all_run_vars() {
  set -u -o pipefail

  # Determine the directory of this script
  local script_dir
  script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

  # Basic system and project information
  export HOST_NAME
  HOST_NAME="$(hostname -s)"
  

  # Determine directory paths relative to this function's location
  export BASE_PATH
  BASE_PATH="$(cd "$script_dir/../../../../../.." && pwd)"
  
  export ORG_PATH
  ORG_PATH="$(cd "$script_dir/../../../../.." && pwd)"
  
  export APP_PATH
  APP_PATH="$(cd "$script_dir/../../../.." && pwd)"
  
  export PROJ_PATH
  PROJ_PATH="$(cd "$script_dir/../../.." && pwd)"

  # After APP_PATH is set, derive all project-type paths
  source "$(dirname "${BASH_SOURCE[0]}")/resolve-all-proj-paths.func.sh"
  do_resolve_all_proj_paths

  export APP_NAME
  APP_NAME="$(basename "$APP_PATH")"
  
  export RUN_UNIT
  # Using script_dir for RUN_UNIT; adjust logic if necessary
  RUN_UNIT="$(basename "$script_dir").sh"

  # Set project name and environment variables
  export PROJ
  PROJ="$(basename "$PROJ_PATH")"
  
  export ENV
  ENV="${ENV:-lcl}"

  # Setup logging directory and file
  export LOG_DIR
  LOG_DIR="${PROJ_PATH:-}/dat/log/bash"
  mkdir -p "$LOG_DIR"
  
  export LOG_FILE
  LOG_FILE="$LOG_DIR/${PROJ:-}.$(date "+%Y%m%d").log"

  # Change directory to project path
  cd "$PROJ_PATH" || exit 1

  # Set user and group information
  export GROUP
  GROUP="${GROUP:-$(id -gn 2>/dev/null || ps -o group,supgrp $$ | tail -n 1 | awk '{print $1}')}"
  
  export USER
  USER="${USER:-$(id -un)}"

  # Set UID and GID only if not already set
  if ! declare -p UID &>/dev/null; then
    export UID
    UID="$(id -u)"
  fi
  if ! declare -p GID &>/dev/null; then
    export GID
    GID="$(id -g)"
  fi

  # Determine operating system
  export OS
  OS="${OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"

  # Print out all declared variables for verification (optional)
  echo "Declared variables:"
  for var in HOST_NAME RUN_UNIT PROJ_PATH APP_PATH APP_NAME ORG_PATH BASE_PATH PROJ ENV GROUP USER UID GID OS LOG_DIR LOG_FILE UTL_PROJ_PATH ORC_PROJ_PATH IAC_PROJ_PATH API_PROJ_PATH WUI_PROJ_PATH CNF_PROJ_PATH TPG_PROJ_PATH BOT_PROJ_PATH HOME_UTL_PROJ_PATH HOME_ORC_PROJ_PATH HOME_IAC_PROJ_PATH HOME_API_PROJ_PATH HOME_WUI_PROJ_PATH HOME_CNF_PROJ_PATH HOME_TPG_PROJ_PATH HOME_TPL_PROJ_PATH HOME_BOT_PROJ_PATH; do
    printf '%s=%s\n' "$var" "${!var}"
  done
}

# Optionally, call define_all_vars here if you want automatic execution upon sourcing.
# define_all_vars
