#!/bin/bash
#------------------------------------------------------------------------------
# @description Validate that a required environment variable has a value.
# @param var_name (required) - Name of the variable to check
# @param var_val (required) - Value of the variable
# @example do_require_var JIRA_PAT "${JIRA_PAT:-}"
#------------------------------------------------------------------------------
do_require_var() {

  var_name="${1:-}"
  var="${2:-}"

  do_simple_log() {
    # First word is the level, the rest is the text. Same bytes as
    # `echo $* | cut -d" " -f1/-f2-` on the real call lines, with no fork.
    # Quoted $* does not re-split (SC2048).
    type_of_msg="${1%% *}"
    msg="${*#"$type_of_msg"}"
    msg="${msg# }"
    echo " [$type_of_msg] $(date "+%Y-%m-%d %H:%M:%S %Z") [$$] $msg "
  }

  if [ -z "${var:-}" ]; then
    do_simple_log 'FATAL The environment variable "'$var_name'" does not have a value !!!'
    do_simple_log 'INFO In the calling shell do "export '$var_name'=your-'$var_name'-value"'
    exit 1
  fi
}
