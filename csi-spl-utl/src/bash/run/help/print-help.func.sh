#!/bin/bash
#------------------------------------------------------------------------------
# @description Display help/usage information for the run.sh framework.
# @description Lists all available actions with their descriptions from metadata tags.
# @example ./run --help
# @example ./run -a do_print_help
#------------------------------------------------------------------------------
do_print_help() {
  cat <<EOF_USAGE
   :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
   run.sh minimalistic framework
   :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

   Usage:
   $0 -a <<action-name>>
   or
   $0 -a <<do_action_name>>

   Available actions:
EOF_USAGE

  local proj="${PROJ_PATH:-$(cd "$(dirname "$0")/../../.." && pwd)}"

  # Two-column layout: col1 fits the longest api-versioned action name;
  # col2 is capped so descriptions never wrap on wide terminals, or shrink
  # gracefully on narrow ones. tput/COLUMNS are unreliable when piped, so
  # default generously to 180 and only use a detected value when it is wide
  # enough to be meaningful.
  local term_width col1 col2
  col1=62                                   # fits "./run -a do_confluence_offline_fetch_parent_page_tree_api1"
  term_width=$(tput cols 2>/dev/null || echo 0)
  [[ $term_width -lt $(( col1 + 50 )) ]] && term_width=180   # piped/narrow: fall back to generous default
  col2=$(( term_width - col1 - 12 ))        # 12 = tab(8) + leading-space(1) + col1 + sep(2) + margin(1)
  [[ $col2 -lt 30 ]] && col2=30            # hard minimum

  # One line per name ./run dispatches, not per file: the names are the keys
  # of run.sh's _func_to_file map (its filename rule plus the extra names a
  # file registers itself, e.g. do_os_reboot_required_check), so every line
  # printed here runs (SPL-4549, print-help.tst.sh)
  local fnc_file action_name
  while IFS=$'\t' read -r fnc_file action_name; do
    # Try to extract @description from structured metadata
    local desc=""
    if type do_get_description &>/dev/null; then
      desc=$(do_get_description "$fnc_file" 2>/dev/null || echo "")
    fi

    # Fallback: extract old-style "# Purpose:" line
    if [[ -z "$desc" ]]; then
      desc=$(sed -n '/^# Purpose:/ {s/^# Purpose:[[:space:]]*//p;q;}' "$fnc_file" 2>/dev/null)
    fi

    if [[ -n "$desc" ]]; then
      # Truncate at last word boucsiry to avoid mid-word cuts
      if [[ ${#desc} -gt $col2 ]]; then
        local short="${desc:0:$(( col2 - 3 ))}"
        short="${short% *}"   # trim to last complete word
        desc="${short}..."
      fi
      printf "\t %-${col1}s  %s\n" "./run -a $action_name" "$desc"
    else
      printf "\t ./run -a %s;\n" "$action_name"
    fi
  done < <(_print_help_actions "$proj")

  # No do_help_with here: utl, iac and orc define none, so the lines naming
  # it ended in "NOT found"; utl has no run-all-tests.sh either
  echo ""
  echo "   Run all tests:"
  echo "     bash ../csi-spl-iac/src/bash/tests/utl-suite.tst.sh"
  echo ""
  export EXIT_CODE=0
}

# _print_help_actions <proj>: "<file>\t<action>" for each dispatched name
# whose file is under <proj>/src/bash/run/ (pre/post hooks left out), sorted
_print_help_actions() {
  local proj="$1" fn f
  # shellcheck disable=SC2154 # built by run.sh do_load_functions
  declare -p _func_to_file &>/dev/null || return 0
  for fn in "${!_func_to_file[@]}"; do
    f="${_func_to_file[$fn]}"
    [[ "$f" == "$proj/src/bash/run/"* ]] || continue
    [[ "$f" == *".pre.func.sh" || "$f" == *".post.func.sh" ]] && continue
    printf '%s\t%s\n' "$f" "$fn"
  done | sort -t $'\t' -k1,1 -k2,2
}
# csi-spl ::: copied from sibling-prj-utl
