#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_load_body_file <varname>: read DESK_BODY_FILE into the caller's
# variable (a nameref). An unset DESK_BODY_FILE leaves that variable alone.
#
# "not a readable file" hid the case that matters: the file is there, and the
# run user cannot traverse a private parent (an agent scratch directory).
# These are different FATALS:
#   - a searchable parent has no such entry -> "does not exist"
#   - the path exists, or an ancestor cannot be searched -> "exists but is
#     not readable by <run user>", naming that user and a directory both the
#     writer and that user can read (the spool root's dispatch/)
# A visible, readable non-file (a directory) is "not a regular file".
# DESK_BODY and DESK_BODY_FILE together are refused. do_spl_desk_reply and
# do_spl_desk_post both call this, so the wording stays one wording.
#------------------------------------------------------------------------------

# spl_desk_load_body_file <varname>: 0 after copying the file into <varname>,
# or when DESK_BODY_FILE is unset. 1 with the FATAL above otherwise.
spl_desk_load_body_file() {
  local -n _desk_body="$1"
  local path block
  [[ -n "${DESK_BODY_FILE:-}" ]] || return 0
  [[ -z "${_desk_body}" ]] || { do_log "FATAL set DESK_BODY or DESK_BODY_FILE, not both"; return 1; }
  path="$DESK_BODY_FILE"
  if [[ -f "$path" && -r "$path" ]]; then
    _desk_body="$(cat "$path")" && return 0
    spl_desk_body_file_refuse "$path" unreadable
    return 1
  fi
  if spl_desk_body_file_missing "$path"; then
    spl_desk_body_file_refuse "$path" missing
    return 1
  fi
  if [[ -e "$path" && -r "$path" ]]; then
    spl_desk_body_file_refuse "$path" notfile
    return 1
  fi
  block="$(spl_desk_body_file_block "$path")"
  if [[ -n "$block" && "$block" != "$path" ]]; then
    spl_desk_body_file_refuse "$path" traverse "$block"
  else
    spl_desk_body_file_refuse "$path" unreadable
  fi
  return 1
}

# spl_desk_body_file_missing <path>: 0 when a directory this user can search
# has no such entry. 1 when the path is visible, or an ancestor cannot be
# searched (the file may exist behind it; this user cannot tell).
spl_desk_body_file_missing() {
  local path="$1" dir
  if [[ -e "$path" || -L "$path" ]]; then
    return 1
  fi
  dir=$(dirname -- "$path")
  while :; do
    if [[ -d "$dir" && -x "$dir" ]]; then
      return 0
    fi
    if [[ -e "$dir" || -L "$dir" ]]; then
      return 1
    fi
    if [[ "$dir" == "/" || "$dir" == "." ]]; then
      return 0
    fi
    dir=$(dirname -- "$dir")
  done
}

# spl_desk_body_file_block <path>: print the path this user cannot read.
# The file itself when it is visible, otherwise the ancestor that cannot be
# searched. Call only when spl_desk_body_file_missing returned 1.
spl_desk_body_file_block() {
  local path="$1" dir
  if [[ -e "$path" || -L "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  dir=$(dirname -- "$path")
  while :; do
    if [[ -e "$dir" || -L "$dir" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    if [[ "$dir" == "/" || "$dir" == "." ]]; then
      printf '%s\n' "$path"
      return 0
    fi
    dir=$(dirname -- "$dir")
  done
}

# spl_desk_body_file_refuse <path> <why> [block]: the FATAL, then 1.
# why is missing, notfile, unreadable or traverse. traverse names <block>,
# the ancestor this user cannot search.
spl_desk_body_file_refuse() {
  local path="$1" why="$2" block="${3:-}" who hint
  who="$(id -un)"
  hint="Put the body in a directory both the writer and ${who} can read, for example ${SPOOL_LIVE_ROOT:-/var/spool-hub}/dispatch/."
  case "$why" in
    missing) do_log "FATAL DESK_BODY_FILE does not exist: '$path'" ;;
    notfile) do_log "FATAL DESK_BODY_FILE is not a regular file: '$path'" ;;
    traverse) do_log "FATAL DESK_BODY_FILE exists but is not readable by ${who} (cannot traverse '$block'): '$path'. $hint" ;;
    unreadable) do_log "FATAL DESK_BODY_FILE exists but is not readable by ${who}: '$path'. $hint" ;;
    *) do_log "FATAL DESK_BODY_FILE ($why): '$path'" ;;
  esac
  return 1
}
