#!/bin/bash
#------------------------------------------------------------------------------
# @description Validate that required binary/tool is installed and available on PATH.
# @description Prints the do_box_pkg_install command (spec 142) for each missing tool.
# @description Prevents silent failures or cryptic errors halfway through long-running actions.
# @param bin_names (required) - One or more binary names to check (positional arguments)
# @example do_require_bin jq
# @example do_require_bin jq curl pandoc
# @output Logs FATAL with install instructions for each missing tool
#------------------------------------------------------------------------------
do_require_bin() {
  # Map of binary names to their apt package names (default: the name itself)
  _pkg_name() {
    case "$1" in
      pip|pip3) echo "python3-pip" ;;
      node)     echo "nodejs" ;;
      docker)   echo "docker.io" ;;
      awk)      echo "gawk" ;;
      xmllint)  echo "libxml2-utils" ;;
      *)        echo "$1" ;;
    esac
  }
  # The install command for one or more package names. run.sh exports only
  # the env vars set before ./run (trailing VAR=val args are dropped), so the
  # inputs of do_box_pkg_install come first.
  _install_hint() {
    local agent_id="${AGENT_ID:-<your-agent-id>}"
    local reason="Required by do_require_bin for tool validation"
    local pkg_arg="$1"
    [[ "$pkg_arg" == *" "* ]] && pkg_arg="'$pkg_arg'"
    echo "BOX_PKG=$pkg_arg BOX_PKG_REASON='$reason' AGENT_ID=$agent_id ./run -a do_box_pkg_install"
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
    local pkgs=() pkg
    for bin_name in "${missing[@]}"; do
      pkg="$(_pkg_name "$bin_name")"
      pkgs+=("$pkg")
      do_log "INFO Install $bin_name with: $(_install_hint "$pkg")"
    done
    if [[ ${#missing[@]} -gt 1 ]]; then
      do_log "INFO Install all at once: $(_install_hint "${pkgs[*]}")"
    fi
    return 11
  fi
}
# csi-spl ::: copied from sibling-prj-utl
