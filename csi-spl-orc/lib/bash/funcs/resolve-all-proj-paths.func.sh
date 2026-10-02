#!/usr/bin/env bash
# File: lib/bash/funcs/resolve-all-proj-paths.func.sh
# Derives all *_PROJ_PATH and HOME_*_PROJ_PATH vars from APP_PATH, ORG, APP, DOCKER_HOME

do_resolve_all_proj_paths() {
  local app_path="${APP_PATH:?APP_PATH must be set}"
  # In a linked git worktree the root basename is the agent id, not <ORG>-<APP>;
  # derive the naming pair from the main worktree so <app>-api etc. resolve.
  # See _do_oap_canonical_app_path in resolve-oap.func.sh.
  source "$(dirname "${BASH_SOURCE[0]}")/resolve-oap.func.sh"
  local canonical_path
  canonical_path="$(_do_oap_canonical_app_path)"
  local app="${APP:-$(basename "$canonical_path")}"
  local docker_home="${DOCKER_HOME:-/home/appusr}"

  # Standard project paths (one per proj_kind)
  export UTL_PROJ_PATH="${app_path}/${app}-utl"
  export ORC_PROJ_PATH="${app_path}/${app}-orc"
  export IAC_PROJ_PATH="${app_path}/${app}-iac"
  export API_PROJ_PATH="${app_path}/${app}-api"
  export WUI_PROJ_PATH="${app_path}/${app}-wui"
  export CNF_PROJ_PATH="${app_path}/${app}-cnf"

  # Special cases
  export TPG_PROJ_PATH="${app_path}/tpl-gen"
  # Bot e2e scripts live in the WUI package (pnpm test:payment / test:e2e).
  export BOT_PROJ_PATH="${WUI_PROJ_PATH}"

  # HOME_* paths (container-relative)
  export HOME_UTL_PROJ_PATH="${docker_home}${UTL_PROJ_PATH}"
  export HOME_ORC_PROJ_PATH="${docker_home}${ORC_PROJ_PATH}"
  export HOME_IAC_PROJ_PATH="${docker_home}${IAC_PROJ_PATH}"
  export HOME_API_PROJ_PATH="${docker_home}${API_PROJ_PATH}"
  export HOME_WUI_PROJ_PATH="${docker_home}${WUI_PROJ_PATH}"
  export HOME_CNF_PROJ_PATH="${docker_home}${CNF_PROJ_PATH}"
  export HOME_TPG_PROJ_PATH="${docker_home}${TPG_PROJ_PATH}"
  export HOME_TPL_PROJ_PATH="${docker_home}${TPG_PROJ_PATH}"
  export HOME_BOT_PROJ_PATH="${docker_home}${BOT_PROJ_PATH}"
}
