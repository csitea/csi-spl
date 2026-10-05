#!/bin/bash
#------------------------------------------------------------------------------
# spl_newest_tenant_key <dir> <tenant>
#   Print the lexically last <dir>/<tenant>.*.json and return 0. The timestamp
#   sits in the file name, so lexical order is time order and the last name is
#   the newest saved tenant key. Return 1 and print nothing when none match.
#
# A nullglob array, not ls | sort | tail. Parsed ls output splits a name that
# contains a newline, and "no match" collapses to an empty string. The array
# keeps the name whole and the count is explicit. The caller's nullglob is
# restored. A bare `shopt -q` returns 1 when the option is off and, under
# set -e, aborts the caller, so the probe sits inside `if`.
# Both desk rebox and the M3 prd prepare use this one lookup.
#------------------------------------------------------------------------------

# spl_newest_tenant_key <dir> <tenant>: 0 and the path, or 1 when none match.
spl_newest_tenant_key() {
  local dir="$1" tenant="$2" nullglob_was=0
  local -a ks=()
  if shopt -q nullglob; then nullglob_was=1; fi
  shopt -s nullglob
  ks=("$dir/$tenant".*.json)
  if (( nullglob_was == 0 )); then
    shopt -u nullglob
  fi
  [[ ${#ks[@]} -gt 0 ]] || return 1
  printf '%s\n' "${ks[-1]}"
}
