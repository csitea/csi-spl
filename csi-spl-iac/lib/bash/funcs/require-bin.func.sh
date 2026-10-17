#!/bin/bash
#------------------------------------------------------------------------------
# @description Validate that required binary/tool is installed and available on PATH.
# @description Provides exact one-liner install commands when tools are missing.
# @description Prevents silent failures or cryptic errors halfway through long-running actions.
# @param bin_names (required) - One or more binary names to check (positional arguments)
# @example do_require_bin jq
# @example do_require_bin jq curl pandoc
# @output Logs FATAL with install instructions for each missing tool
#------------------------------------------------------------------------------
do_require_bin() {
  # Map of known tools to their install commands
  _install_hint() {
    local agent_id="${AGENT_ID:-unknown}"
    local reason="Required by do_require_bin for tool validation"
    echo "./run -a do_box_pkg_install BOX_PKG=$1 BOX_PKG_REASON='$reason' AGENT_ID=$agent_id"
  }

  if [[ $# -eq 0 ]]; then
    do_log "ERROR do_require_bin called with no arguments"
    return 11
  fi

  local missing=()
  for bin_name in "$@"; do
    if ! command -v "$bin_name" &>/dev/null; then
      missing+=("$bin_name")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    do_log "FATAL Missing required tool(s): ${missing[*]}"
    for bin_name in "${missing[@]}"; do
      do_log "INFO Install $bin_name with: $(_install_hint "$bin_name")"
    done
    if [[ ${#missing[@]} -gt 1 ]]; then
      local all_pkgs="${missing[*]}"
      do_log "INFO Install all at once: sudo apt-get install -y ${all_pkgs}"
    fi
    return 11
  fi
}
# csi-spl ::: copied from sibling-prj-utl
