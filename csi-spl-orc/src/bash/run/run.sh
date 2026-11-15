#!/bin/bash
#
# Minimalistic run.sh framework
# usage: ./run --help

# Ensure ERR trap is inherited by functions
set -E

# Global Error Handler
error_handler() {
  local exit_code=$?
  local line_no=$1
  local cmd="$2"
  # An explicit third argument wins. execute_step detects a failed action with an
  # `if` test, which overwrites $? with the test's own status (0 = "yes, it
  # failed"), so reading $? here reported success and made the whole run exit 0.
  [[ -n "${3:-}" ]] && exit_code="$3"
  # Suppress FATAL message if the exit code is 11 (intentional validation failure)
  if [[ $exit_code -ne 11 ]]; then
    do_log "FATAL Command '$cmd' failed at line $line_no with status $exit_code."
  fi
  exit $exit_code
}

# execute_step_hook <hook> <label> <args...>: run a PRE or POST hook between
# its START and STOP lines, when the action defines one.
execute_step_hook() {
  local hook=$1 label=$2
  shift 2
  type "$hook" &>/dev/null || return 0
  do_log "INFO START ::: running $label :: $hook"
  "$hook" "$@"
  do_log "INFO STOP  ::: running $label :: $hook"
}

# execute_step_flag_maps <func_file>: ONE header parse of the action fills the
# caller's maps (a flag on the command line never re-parses the header):
#   _xs_arg  an explicit `@arg --flag VAR` line         --flag -> VAR
#   _xs_par  every upper-case `@param NAME`             --name -> NAME
#            (IMAGE_REF -> --image-ref; an @arg on the same flag wins)
#   _xs_own  an `@param --flag ...` line: a flag the action reads from "$@"
execute_step_flag_maps() {
  local _line _w1 _w2 _rest _f
  while IFS= read -r _line; do
    case "$_line" in
      arg=*)
        read -r _w1 _w2 _rest <<< "${_line#arg=}" || true
        [[ -n "$_w1" && -n "$_w2" ]] && _xs_arg["$_w1"]="$_w2"
        ;;
      param=*)
        read -r _w1 _rest <<< "${_line#param=}" || true
        if [[ "$_w1" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
          _f="${_w1,,}"
          _xs_par["--${_f//_/-}"]="$_w1"
        elif [[ "$_w1" == --?* ]]; then
          _xs_own["$_w1"]=1
        fi
        ;;
    esac
  done <<< "$(do_parse_metadata "$1" 2>/dev/null)"
  return 0
}

# execute_step_flag_owned <func_file> <flag>: 0 when <flag> is not a variable
# flag but is taken as it is: a framework flag (--json, --quiet), an
# `@param --flag` line, or the flag written in the action's own file (a
# `--kind)` case arm, a `== --purge` test). The file is read once, no fork.
execute_step_flag_owned() {
  case "$2" in --json | --quiet | --help | --actions) return 0 ;; esac
  [[ -n "${_xs_own[$2]:-}" ]] && return 0
  [[ -n "${_xs_src+x}" ]] || _xs_src="$(<"$1")"
  [[ "$_xs_src" =~ (^|[^a-zA-Z0-9_-])"$2"([^a-zA-Z0-9_-]|$) ]]
}

# execute_step_flag_unknown <func_name> <flag>: the FATAL of an unknown flag,
# naming every flag the action takes. A typo must not run the action with
# the variable silently unset or left at the caller's env value.
execute_step_flag_unknown() {
  local _list
  _list="$(printf '%s\n' "${!_xs_arg[@]}" "${!_xs_par[@]}" "${!_xs_own[@]}" | sort -u | tr '\n' ' ')"
  [[ "$_list" == *[![:space:]]* ]] || _list=""
  do_log "FATAL $1: unknown flag $2"
  do_log "FATAL $1 takes: ${_list:-(no flags)}"
  do_log "INFO  each @param NAME is also --name value (a bare --name is true); --json and --quiet are the framework's"
}

# execute_step_parse_args <func_name> <func_file> <args...>: every
# `@param NAME` of the action is also a flag: `--name value` (or
# `--name=value`) exports NAME=value, a bare `--name` (last, or followed by
# another --flag) exports NAME=true. An explicit `@arg --flag VAR` wins over a
# derived flag of the same spelling. A flag beats an env var of the same name
# set by the caller. An unknown --flag fails (return 11). A bare `--` ends the
# flags. Positional args are left alone, and every arg still reaches the
# action. No --flag in the args: no header parse at all.
execute_step_parse_args() {
  local func_name=$1 func_file=$2
  shift 2
  local args=("$@") _a=""
  for _a in "${args[@]}"; do [[ "$_a" == --?* ]] && break; done
  [[ -n "$func_file" && "$_a" == --?* ]] || return 0
  declare -A _xs_arg=() _xs_par=() _xs_own=()
  local _xs_src _i=0 _flag _val _var _next _eq
  execute_step_flag_maps "$func_file"
  while (( _i < ${#args[@]} )); do
    _flag="${args[$_i]}"
    _i=$((_i + 1))
    [[ "$_flag" == -- ]] && break
    [[ "$_flag" == --?* ]] || continue
    _eq=0
    if [[ "$_flag" == *=* ]]; then
      _val="${_flag#*=}" _flag="${_flag%%=*}" _eq=1
    fi
    _var="${_xs_arg[$_flag]:-${_xs_par[$_flag]:-}}"
    if [[ -z "$_var" ]]; then
      execute_step_flag_owned "$func_file" "$_flag" && continue
      execute_step_flag_unknown "$func_name" "$_flag"
      return 11
    fi
    if (( _eq == 0 )); then
      _next="${args[$_i]:-}"
      if [[ -n "$_next" && "$_next" != --* ]]; then
        _val="$_next"
        _i=$((_i + 1))
      else
        _val=true
      fi
    fi
    export "$_var"="$_val"
    do_log "DEBUG Parsed: $_flag -> $_var"
  done
  return 0
}

# Execution Wrapper
execute_step() {
  local func_name=$1
  shift
  local args=("$@")

  # 1. Run PRE hook if exists
  execute_step_hook "${func_name}_pre" "PRE hook " "${args[@]}"

  do_log "INFO START ::: running action    :: $func_name"

  # 1. Run ARGS hook if exists (Decentralized parsing)
  if type "${func_name}_args" &>/dev/null; then
    do_log "DEBUG Running ARGS hook for: $func_name"
    "${func_name}_args" "${args[@]}" || return $?
  fi

  # Map the action's --flag value pairs (@param NAME, @arg) to env vars
  local func_file="${_func_to_file[$func_name]:-}"
  execute_step_parse_args "$func_name" "$func_file" "${args[@]}" || return $?

  # Validate required @param metadata before running (if available)
  if [[ -n "$func_file" ]] && type do_validate_params &>/dev/null; then
    do_validate_params "$func_file"
    local _vp_rc=$?
    if [[ $_vp_rc -ne 0 ]]; then
      return $_vp_rc
    fi
  fi

  # Run the function
  # We temporarily disable the global ERR trap to ensure POST hook can run even on failure
  trap - ERR
  "$func_name" "${args[@]}"
  local exit_status=$?
  trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

  if [[ $exit_status -eq 0 ]]; then
    do_log "INFO STOP  ::: running function  :: $func_name"
  else
    do_log "ERROR Action failed with status $exit_status"
  fi

  # 2. Run POST hook if exists (guaranteed cleanup)
  execute_step_hook "${func_name}_post" "POST hook" "${args[@]}"

  # If the main action failed, now trigger the error handler
  if [[ $exit_status -ne 0 ]]; then
    error_handler "$LINENO" "$func_name" "$exit_status"
  fi

  return $exit_status
}

trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR

# Machine-readable mode. When the caller asks an action for --json (or
# --quiet), STDOUT belongs to that action alone and nothing the framework says
# may land in it -- otherwise `./run -a <action> --json | jq` parses ANSI
# escapes and log lines instead of the document.
#
# Three separate things used to write to stdout: do_flush_screen's raw escapes,
# every do_log line, and the stderr tee below (whose own stdout was the shell's
# stdout, folding stderr back onto stdout). All three are handled here; nothing
# is lost, because the log files still receive every line and a terminal shows
# both streams.
do_detect_stdout_mode() {
  local arg
  RUN_STDOUT_IS_DATA=0
  for arg in "$@"; do
    case "$arg" in
      --json | --quiet) RUN_STDOUT_IS_DATA=1 ;;
    esac
  done
  export RUN_STDOUT_IS_DATA
}

# Quiet logs for agents (token/focus practice 05). An agent reads ./run through
# a pipe, and there ~60% of every byte was decoration: ANSI colour, a date, the
# module, the box, the pid and START/STOP banners. So when stdout is not a
# terminal (or RUN_LOG=compact) a log line prints as `LEVEL msg`, DEBUG is
# dropped (RUN_LOG=debug keeps it) and the framework banners are dropped. The
# log FILE keeps the full line either way. RUN_LOG=full restores the old
# format on a pipe. Decided once here, before main's tee turns stdout into a
# pipe; an inherited value (a ./run inside a ./run) is kept.
do_detect_log_mode() {
  case "${RUN_LOG:-}" in
    full) RUN_LOG_COMPACT=0 ;;
    compact | debug) RUN_LOG_COMPACT=1 ;;
    *)
      if [[ -z "${RUN_LOG_COMPACT:-}" ]]; then
        if [[ -t 1 ]]; then RUN_LOG_COMPACT=0; else RUN_LOG_COMPACT=1; fi
      fi
      ;;
  esac
  export RUN_LOG_COMPACT
}

# do_run_top_pad <args>: re-exec this Bash once with
# GLIBC_TUNABLES=...glibc.malloc.top_pad=134217728 when the variable carries
# no top_pad yet. glibc reads the tunable only at exec, so an export alone
# would reach the children and not this shell. With the pad, malloc grows the
# heap in 128 MiB steps that transparent huge pages can back, and every fork
# of a loaded ./run copies fewer 4 KiB page-table entries: -41% kernel time,
# -33% wall per fork, +0.5..1.7 MB RSS (spec 027 os-tweaks-analysis.md 2.5,
# row 1b, n = 3 per arm). An existing GLIBC_TUNABLES is appended to, never
# replaced; one that already sets top_pad wins (top_pad=131072, glibc's
# default, turns the pad off). Runs before anything is sourced; the pid guard
# stops a loop when the environment drops the variable.
do_run_top_pad() {
  case ":${GLIBC_TUNABLES:-}:" in *:glibc.malloc.top_pad=*) return 0 ;; esac
  [[ "${RUN_TOP_PAD_PID:-}" != "$$" ]] || return 0
  export RUN_TOP_PAD_PID=$$
  export GLIBC_TUNABLES="${GLIBC_TUNABLES:+${GLIBC_TUNABLES}:}glibc.malloc.top_pad=134217728"
  local _o=()
  [[ $- == *x* ]] && _o+=(-x)
  [[ $- == *v* ]] && _o+=(-v)
  exec "$BASH" "${_o[@]}" "$0" "$@"
}

# Repo-root ./run (SPL-5550, spec 011). The repo root carries its own copy of
# this file (src/bash/run/run.sh, the root ./run points to it); a module's
# ./run is unchanged. The copy knows it is the root when the dir of its ./run
# has module children (<dir>/*/src/bash/run/run.sh), read from $0 before
# anything else runs: no fork, so a module pays one glob and nothing more.
# At the root:
#   - an action defined in the root's own src/bash/run/*.func.sh runs here;
#   - `./run -a do_x` execs the ./run of the one module that defines do_x
#     (its src/bash/run/ or lib/bash/funcs/<name>.func.sh, as the module's
#     loader finds it) with the same argv and env, `-m <module>` left out;
#   - two or more owners: named, refused (exit 2) unless `-m <module>` picks
#     one (orc, csi-spl-orc); no owner: the modules' "NOT found" and exit 1;
#   - `./run`, `./run --help`: the actions grouped by module.
# Guard: csi-spl-orc/src/bash/tests/run-root-dispatch.tst.sh.
do_root_dispatch() {
  local _rd_root _rd_mods=() _rd_argv=() _rd_acts=() _rd_pick="" _rd_help=0
  do_root_find_modules || return 0
  while (($# > 0)); do
    case "$1" in
    -m | --module) _rd_pick="${2:-}"; shift; (($# > 0)) && shift ;;
    -a | --actions)
      local _rd_w=()
      read -r -a _rd_w <<<"${2:-}" || true
      _rd_acts+=("${_rd_w[@]}"); _rd_argv+=("$1" "${2:-}")
      shift; (($# > 0)) && shift ;;
    -h | --help) _rd_help=1; _rd_argv+=("$1"); shift ;;
    *) _rd_argv+=("$1"); shift ;;
    esac
  done
  if ((_rd_help == 1 || ${#_rd_acts[@]} == 0)); then
    do_root_help
    exit 0
  fi
  shopt -s globstar nullglob
  local _rd_to
  _rd_to=$(do_root_pick_target) || exit $?
  shopt -u globstar nullglob
  [[ "$_rd_to" == "$_rd_root" ]] && return 0
  exec "$_rd_to/run" "${_rd_argv[@]}"
}

# do_root_find_modules: sets _rd_root (the dir of this ./run) and _rd_mods
# (its module dirs); returns 1 when this ./run is not the root.
do_root_find_modules() {
  local _rd_m
  _rd_root="${0%/*}"
  [[ "$_rd_root" == "$0" ]] && _rd_root=.
  [[ "$_rd_root" == src/bash/run ]] && _rd_root=.
  [[ "$_rd_root" == */src/bash/run ]] && _rd_root="${_rd_root%/src/bash/run}"
  for _rd_m in "$_rd_root"/*/src/bash/run/run.sh; do
    [[ -e "$_rd_m" ]] && _rd_mods+=("${_rd_m%/src/bash/run/run.sh}")
  done
  ((${#_rd_mods[@]} > 0))
}

# do_root_pick_target: prints the dir whose ./run runs every action of
# _rd_acts (_rd_root for the root's own), or names why not and returns
# 1 (no owner) or 2 (two owners, an unknown -m, actions of two modules).
do_root_pick_target() {
  local _rd_a _rd_own=() _rd_to="" _rd_m
  if [[ -n "$_rd_pick" ]]; then
    for _rd_m in "${_rd_mods[@]}"; do
      [[ "${_rd_m##*/}" == "$_rd_pick" || "${_rd_m##*/}" == *-"$_rd_pick" ]] && { echo "$_rd_m"; return 0; }
    done
    echo "FATAL -m $_rd_pick: no such module; modules: $(do_root_names "${_rd_mods[@]}")" >&2
    return 2
  fi
  for _rd_a in "${_rd_acts[@]}"; do
    do_root_owners "$_rd_a"
    if ((${#_rd_own[@]} == 0)); then
      echo "FATAL action(s) requested: \"$_rd_a\" NOT found !!!" >&2
      echo "FATAL 1. check the spelling of your action" >&2
      echo "FATAL 2. check the available actions by: ./run --help" >&2
      echo "FATAL the run failed !" >&2
      return 1
    fi
    if ((${#_rd_own[@]} > 1)); then
      echo "FATAL action \"$_rd_a\" is defined in $(do_root_names "${_rd_own[@]}"): pick one with -m <module>" >&2
      return 2
    fi
    if [[ -n "$_rd_to" && "$_rd_to" != "${_rd_own[0]}" ]]; then
      echo "FATAL the actions run in $(do_root_names "$_rd_to" "${_rd_own[0]}"): one ./run call per module" >&2
      return 2
    fi
    _rd_to="${_rd_own[0]}"
  done
  echo "$_rd_to"
}

# do_root_owners <action>: sets _rd_own to the dirs (root, then modules)
# with a <name>.func.sh that defines the action, the file the loader maps it
# from: do_a_b is defined in an a-b or a_b file, .func.sh. Needs globstar and nullglob.
do_root_owners() {
  local _rd_n="$1" _rd_g _rd_m _rd_f _rd_body
  _rd_own=()
  [[ "$_rd_n" != do_* ]] && _rd_n="do_${_rd_n//-/_}"
  _rd_n="${_rd_n//-/_}"
  [[ "$_rd_n" =~ ^do_[A-Za-z0-9_]+$ ]] || return 0
  _rd_g="${_rd_n#do_}" && _rd_g="${_rd_g//_/[-_]}"
  for _rd_m in "$_rd_root" "${_rd_mods[@]}"; do
    for _rd_f in "$_rd_m"/src/bash/run/**/$_rd_g.func.sh "$_rd_m"/lib/bash/funcs/**/$_rd_g.func.sh; do
      _rd_body=""
      read -r -d '' _rd_body <"$_rd_f" || true
      if [[ "$_rd_body" =~ (^|$'\n')[[:space:]]*(function[[:space:]]+)?${_rd_n}[[:space:]]*\(\) ]]; then
        _rd_own+=("$_rd_m")
        break
      fi
    done
  done
  return 0
}

# do_root_names <dir...>: the dirs' names, comma separated ("." = the root).
do_root_names() {
  local _rd_out="" _rd_d _rd_b
  for _rd_d in "$@"; do
    _rd_b="${_rd_d##*/}"
    [[ "$_rd_d" == "$_rd_root" ]] && _rd_b="the repo root"
    _rd_out="${_rd_out:+$_rd_out, }$_rd_b"
  done
  echo "$_rd_out"
}

# do_root_help: the actions of the root and of each module, grouped, one
# line per name the module's ./run dispatches from its src/bash/run/.
do_root_help() {
  local _rd_m _rd_f _rd_b _rd_n _rd_body _rd_list
  echo "   Usage: ./run -a <action> [-m <module>]"
  echo "   At the repo root, ./run hands the action to the module that defines it."
  shopt -s globstar nullglob
  for _rd_m in "$_rd_root" "${_rd_mods[@]}"; do
    _rd_list=""
    for _rd_f in "$_rd_m"/src/bash/run/**/*.func.sh; do
      _rd_b="${_rd_f##*/}" && _rd_b="${_rd_b%.func.sh}"
      [[ "$_rd_b" == *.pre || "$_rd_b" == *.post ]] && continue
      _rd_n="do_${_rd_b//-/_}" && _rd_body=""
      read -r -d '' _rd_body <"$_rd_f" || true
      [[ "$_rd_body" =~ (^|$'\n')[[:space:]]*(function[[:space:]]+)?${_rd_n}[[:space:]]*\(\) ]] &&
        _rd_list+="	 ./run -a ${_rd_n}"$'\n'
    done
    [[ -n "$_rd_list" ]] || continue
    echo ""
    echo "   $(do_root_names "$_rd_m"):"
    printf '%s' "$_rd_list" | sort -u
  done
  shopt -u globstar nullglob
}

main() {
  do_root_dispatch "$@"
  do_run_top_pad "$@"
  do_detect_stdout_mode "$@"
  do_detect_log_mode
  [[ "${RUN_STDOUT_IS_DATA:-0}" == "1" || "$RUN_LOG_COMPACT" == "1" ]] || do_flush_screen
  do_set_vars "$@"
  ts=$(date "+%Y%m%d_%H%M%S")
  main_log_dir=~/var/log/${PROJ:-run.sh}/
  mkdir -p $main_log_dir
  # The two tees are named fds with known pids, so the exit can wait for them:
  # an unwaited tee could copy the last stdout line after ./run returned, and a
  # caller doing `./run ... >f; grep f` read f too early (SPL-2820). Each fd
  # is closed in main_exec and in the other tee, so EOF follows main_exec.
  # The log copy is masked (do_run_log_tee, SPL-3614); stdout keeps every byte.
  exec {RUN_TEE_OUT_FD}> >(do_run_log_tee $main_log_dir/${RUN_UNIT:-run.sh}.$ts.out.log)
  RUN_TEE_PIDS=$!
  exec {RUN_TEE_ERR_FD}> >(exec {RUN_TEE_OUT_FD}>&- && do_run_log_tee $main_log_dir/${RUN_UNIT:-run.sh}.$ts.err.log >&2)
  RUN_TEE_PIDS+=" $!"
  trap do_wait_tees EXIT
  # exec, not a redirection on the main_exec call: for that one bash keeps a
  # saved copy of each tee fd, which an `exit` inside main_exec (error_handler,
  # an action's own exit) never closes, so every failing ./run idled to the
  # RUN_TEE_WAIT_S cap in do_wait_tees (SPL-5192, run-log.tst.sh case 5).
  exec >&$RUN_TEE_OUT_FD 2>&$RUN_TEE_ERR_FD {RUN_TEE_OUT_FD}>&- {RUN_TEE_ERR_FD}>&-
  main_exec "$@"
  exit $?
}

# do_run_log_tee <log>: the tee of main. stdin goes to stdout unchanged and to
# <log> with private key values masked (do_mask_private_keys): an action that
# prints a secret once on stdout, as do_spl_tenant_create prints the tenant
# root private key, must not leave it in a group-readable run log (SPL-3614).
# Waits for the masking writer, so the log is complete when this tee ends.
do_run_log_tee() {
  tee >(do_mask_private_keys >"$1")
  wait $! 2>/dev/null || true
}

# do_mask_private_keys: a stdin-to-stdout filter that replaces the value of a
# "..private_key": "<v>" JSON field (or ..privateKey, any case; a \" or \\ in
# <v> stays inside it), a ..PRIVATE_KEY=<v> assignment and a PEM PRIVATE KEY
# block (one line or many) with <redacted>. A mask hides only the
# shapes it names: an action prints a secret in one of them, or not at all.
do_mask_private_keys() {
  sed -u -E \
    -e 's/("[A-Za-z0-9_]*private_?key"[[:space:]]*:[[:space:]]*")([^"\\]|\\.)*"/\1<redacted>"/gI' \
    -e 's/([A-Za-z0-9_]*private_?key=)[^[:space:]"]+/\1<redacted>/gI' \
    -e 's/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*-----END [A-Z0-9 ]*PRIVATE KEY-----/<redacted private key>/g' \
    -e '/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,/-----END [A-Z0-9 ]*PRIVATE KEY-----/c\
<redacted private key>'
}

# do_wait_tees: the EXIT trap of main, so an `exit` from error_handler or an
# action waits too. Closes this shell's ends of the tee pipes, then waits for
# both tees, bounded by RUN_TEE_WAIT_S (2) seconds: a detached child that kept
# a copy of stdout holds a tee open, and must not hold ./run. Polls with
# kill -0, never a bare `wait` (it also waits on the procsubs and can hang).
do_wait_tees() {
  [[ -n "${RUN_TEE_PIDS:-}" && "$BASHPID" == "$$" ]] || return 0
  local pid end=$((SECONDS + ${RUN_TEE_WAIT_S:-2}))
  exec >&- 2>&- {RUN_TEE_OUT_FD}>&- {RUN_TEE_ERR_FD}>&-
  for pid in $RUN_TEE_PIDS; do
    while kill -0 "$pid" 2>/dev/null && ((SECONDS < end)); do
      sleep 0.01
    done
  done
  RUN_TEE_PIDS=
}

main_exec() {
  local args=("$@")
  do_load_functions
  do_detect_base_paths
  do_load_config
  do_require_bins
  do_verify_symlinks
  test -z "${actions:-}" && actions=' do_print_help '
  do_run_actions "$actions" "${args[@]:2}"
  local _run_rc=$?
  do_finalize "$_run_rc"
  return $_run_rc
}

# Framework core dependencies
do_require_bins() {
  # Core run.sh requirements
  do_require_bin perl find sed awk hostname date tee mkdir
}

# Legacy get_function_list — kept for backward compatibility with any
# external callers.  No longer used in the hot path; the optimised
# do_load_functions builds the _func_to_file map from filename conventions.
get_function_list() {
  env -i PATH=/bin:/usr/bin:/usr/local/bin bash --noprofile --norc -c '
      source "'"$1"'"
      typeset -f |
      grep '\''^[^{} ].* () $'\'' |
      awk "{print \$1}" |
      while read -r fnc_name; do
         type "$fnc_name" | sed -n 1p | grep "is a function$" >/dev/null || continue
            echo "$fnc_name"
            done
            '
}

do_read_cmd_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -a | --actions) shift && actions="${actions:-}${1:-} " && shift ;;
    -h | --help) actions=' do_print_help ' && ENV='dev' && shift ;;
    *) shift ;;  # Pass unrecognized arguments to the functions
    esac
  done
}

# Optimised action dispatcher: looks up pre-built _func_to_file map
# instead of spawning find + get_function_list subprocesses per action.
do_run_actions() {
  actions=$1
  local args=("${@:2}")
  actions_found=0
  cd ${PROJ_PATH:-}
  # Space-separated names, empty fields dropped. Was echo | tr | sed,
  # one fork pair on every ./run including the action-not-found path.
  local _an_raw="${actions}" _an_piece _an_nl
  _an_nl=$'\n'
  actions=""
  while [[ "${_an_raw}" == *" "* ]]; do
    _an_piece="${_an_raw%% *}"
    _an_raw="${_an_raw#* }"
    if [[ -n "${_an_piece}" ]]; then
      if [[ -n "${actions}" ]]; then
        actions="${actions}${_an_nl}${_an_piece}"
      else
        actions="${_an_piece}"
      fi
    fi
  done
  if [[ -n "${_an_raw}" ]]; then
    if [[ -n "${actions}" ]]; then
      actions="${actions}${_an_nl}${_an_raw}"
    else
      actions="${_an_raw}"
    fi
  fi
  run_funcs=''
  do_log "DEBUG do_run_actions: actions=$actions, args=${args[*]}"
  while IFS= read -r arg_action || [[ -n "${arg_action:-}" ]]; do
    [[ -z "${arg_action:-}" ]] && continue
    # Normalise to do_snake_case
    local lookup="$arg_action"
    [[ "$lookup" != do_* ]] && lookup="do_${lookup//-/_}"
    lookup="${lookup//-/_}"

    if [[ -n "${_func_to_file[$lookup]:-}" ]]; then
      actions_found=$((actions_found + 1))
      if [[ -n "${run_funcs}" ]]; then
        run_funcs="${run_funcs}${_an_nl}${lookup}"
      else
        run_funcs="${lookup}"
      fi
    fi
  done <<< "${actions}"

  do_log "DEBUG actions_found=$actions_found"
  test $actions_found -eq 0 && {
    do_log "FATAL action(s) requested: \"$actions\" NOT found !!!"
    do_log "FATAL 1. check the spelling of your action"
    do_log "FATAL 2. check the available actions by: ./run --help"
    do_log "FATAL the run failed !"
    exit 1
  }

  # A for loop over an array, not `while read ... <<< "$run_funcs"`: the
  # actions keep the CALLER's stdin (a pipe, the owner's tty), and an action
  # that reads stdin cannot swallow the rest of the list (run-action-stdin.tst.sh)
  local _final_rc=0 _run_list=()
  mapfile -t _run_list <<< "${run_funcs}"
  for run_func in "${_run_list[@]}"; do
    [[ -z "${run_func:-}" ]] && continue
    cd ${PROJ_PATH:-}
    execute_step "$run_func" "${args[@]}"
    local _step_rc=$?
    (( _step_rc != 0 )) && _final_rc=$_step_rc
  done
  return $_final_rc
}


do_flush_screen() {
  printf "\033[2J"
  printf "\033[0;0H"
}

do_log() {
  # In machine-readable mode the caller owns stdout, so every framework line
  # goes to stderr instead. Re-entering with the stream already swapped is what
  # keeps this to four lines: the guard stops the second pass from swapping
  # again. The log FILE still gets the line either way.
  if [[ "${RUN_STDOUT_IS_DATA:-0}" == "1" && -z "${_DO_LOG_ON_STDERR:-}" ]]; then
    _DO_LOG_ON_STDERR=1 do_log "$@" >&2
    return $?
  fi

  print_ok() { echo -e "\033[0;32m ✔ ${1:-} \033[0m"; }
  print_warning() { echo -e "\033[33m ⚠ ${1:-} \033[0m"; }
  print_info() { echo -e "\033[0;34m ℹ ${1:-} \033[0m"; }
  print_debug() { echo -e "\033[0;36m ⚙ ${1:-} \033[0m"; }
  print_fail() { echo -e "\033[0;31m ❌ [NOK] ${1:-}\033[0m"; }
  print_fatal() { echo -e "\033[0;31m 💣 [FATAL] ${1:-}\033[0m"; }

  # The steps below share these locals (bash dynamic scope) and set the
  # globals type_of_msg, action, rest_of_msg, msg, log_dir and log_file.
  local display_type _do_log_day
  _do_log_split_words "$@"
  _do_log_format_line
  _do_log_resolve_dir
  _do_log_resolve_file

  # Compact mode (do_detect_log_mode; a do_log sourced without main keeps the
  # full line): the file gets the full line, stdout `LEVEL msg`.
  if [[ "${RUN_LOG_COMPACT:-0}" == "1" ]]; then
    _do_log_emit_compact "$@"
    return 0
  fi
  _do_log_emit_full
}

# First two words and the remainder, the same bytes as
# `echo $* | cut -d" " -f1/-f2/-f3-`, with no fork. Unquoted $* collapses
# IFS whitespace; a line with no space has no delimiter, and cut prints
# that whole line for every -f.
_do_log_split_words() {
  local _do_log_words=()
  read -r -a _do_log_words <<< "$*" || true
  if ((${#_do_log_words[@]} <= 1)); then
    type_of_msg="${_do_log_words[0]:-}"
    action="$type_of_msg"
    rest_of_msg="$type_of_msg"
  else
    type_of_msg="${_do_log_words[0]}"
    action="${_do_log_words[1]}"
    if ((${#_do_log_words[@]} > 2)); then
      rest_of_msg="${_do_log_words[*]:2}"
    else
      rest_of_msg=""
    fi
  fi
}

# The full line into msg. RUN_LOG_EPOCH (seconds) freezes both stamps for a
# byte-compare; unset means now. printf %()T matches date in the same TZ.
_do_log_format_line() {
  display_type="${type_of_msg/WARNING/WARN}"
  local type_padded
  type_padded=$(printf "%-7s" "[$display_type]")

  local _do_log_ts
  printf -v _do_log_ts '%(%Y-%m-%d %H:%M:%S %Z)T' "${RUN_LOG_EPOCH:--1}"
  printf -v _do_log_day '%(%Y%m%d)T' "${RUN_LOG_EPOCH:--1}"

  if [[ "$action" == "START" || "$action" == "STOP" ]]; then
    formatted_action=$(printf "%-5s" "$action")
    msg=" $type_padded ${_do_log_ts} [${PROJ:-}][@${HOST_NAME:-}] [$$] $formatted_action $rest_of_msg"
  else
    msg=" $type_padded ${_do_log_ts} [${PROJ:-}][@${HOST_NAME:-}] [$$] $action $rest_of_msg"
  fi
}

# One mkdir per directory, not one per line. Resolve again only when
# LOG_DIR changes or the directory is gone.
_do_log_resolve_dir() {
  if [[ "${_do_log_dir_ready:-}" != "${LOG_DIR:-}" || -z "${LOG_DIR:-}" ]] ||
    [[ ! -d "${LOG_DIR:-}" && "${_do_log_off:-}" != "${LOG_DIR:-}" ]]; then
    local _log_dir
    if [[ -n "${LOG_DIR:-}" ]]; then
      _log_dir="$LOG_DIR"
      mkdir -p "$_log_dir" 2>/dev/null || true
    elif [[ -n "${PROJ:-}" && -n "${ORG:-}" && -n "${APP:-}" ]]; then
      _log_dir="${VAR_DIR:-/var}/${ORG}/${APP}/${PROJ}/dat/log/bash"
      if ! mkdir -p "$_log_dir" 2>/dev/null; then
        _log_dir="${PROJ_PATH:-$(pwd)}/dat/log/bash"
        mkdir -p "$_log_dir" 2>/dev/null || true
      fi
    else
      _log_dir="${PROJ_PATH:-$(pwd)}/dat/log/bash"
      mkdir -p "$_log_dir" 2>/dev/null || true
    fi
    log_dir="$_log_dir"
    export LOG_DIR="$log_dir"
    _do_log_dir_ready="$LOG_DIR"
    _do_log_off=""
  fi
  log_dir="$LOG_DIR"
}

# A log dir or file nobody can write never aborts the command (SPL-2617):
# the append failed and the ERR trap turned the run FATAL. Log to a
# per-user temp dir instead, else keep no log file; say so on stderr.
_do_log_resolve_file() {
  log_file="$log_dir/${PROJ:-run}.${_do_log_day}.log"
  if [[ "${_do_log_off:-}" != "$log_dir" ]] &&
    [[ ! -w "$log_dir" || ( -e "$log_file" && ! -w "$log_file" ) ]]; then
    local _log_fb="${TMPDIR:-/tmp}/run-log-${EUID}"
    if [[ "$log_dir" != "$_log_fb" ]] && mkdir -p "$_log_fb" 2>/dev/null && [[ -w "$_log_fb" ]]; then
      echo "WARN log $log_file is not writable, logging to $_log_fb" >&2
      export LOG_DIR="$_log_fb" && _do_log_dir_ready="$_log_fb" && log_dir="$_log_fb"
      log_file="$log_dir/${PROJ:-run}.${_do_log_day}.log"
    else
      echo "WARN log $log_file is not writable, no log file" >&2
      _do_log_off="$log_dir"
    fi
  fi
  if [[ "${_do_log_off:-}" == "$log_dir" ]]; then log_file=/dev/null; fi
}

# _do_log_emit_compact <do_log args>: the full line to the file, `LEVEL msg`
# to stdout; debug lines (unless RUN_LOG=debug), the runner's own START/STOP
# and its completion line are file-only.
_do_log_emit_compact() {
  case "$type_of_msg" in
  'FATAL') print_fatal "$msg" ;;
  'ERROR') print_fail "$msg" ;;
  'WARNING'|'WARN') print_warning "$msg" ;;
  'INFO') print_info "$msg" ;;
  'OK')    print_ok    "$msg" ;;
  'DEBUG') print_debug "$msg" ;;
  *) echo "$msg" ;;
  esac >>"$log_file"
  [[ "$type_of_msg" == "DEBUG" && "${RUN_LOG:-}" != "debug" ]] && return 0
  [[ ( "$action" == "START" || "$action" == "STOP" ) && "$rest_of_msg" == "::: running "* ]] && return 0
  [[ "$*" == *"'s run completed" ]] && return 0
  local _body="$*"
  _body="${_body#"$type_of_msg"}"
  if [[ "$_body" == "$*" ]]; then
    echo "$*"
  else
    echo "$display_type ${_body# }"
  fi
  return 0
}

# The full line to stdout and the log file.
_do_log_emit_full() {
  case "$type_of_msg" in
  'FATAL') print_fatal "$msg" | tee -a "$log_file" ;;
  'ERROR') print_fail "$msg" | tee -a "$log_file" ;;
  'WARNING'|'WARN') print_warning "$msg" | tee -a "$log_file" ;;
  'INFO') print_info "$msg" | tee -a "$log_file" ;;
  'OK')    print_ok    "$msg" | tee -a "$log_file" ;;
  'DEBUG') print_debug "$msg" | tee -a "$log_file" ;;
  *) echo "$msg" | tee -a "$log_file" ;;
  esac
}

do_set_vars() {
  set -u -o pipefail
  do_read_cmd_args "$@"
  # Follow $0's symlinks one hop at a time and stop at the first file whose
  # dir resolves to a <dir>/src/bash/run/ dir: only that dir is
  # abs_path-resolved, never the file, so a module whose src/bash/run/run.sh
  # links to another module's run.sh keeps its own paths and actions
  # (SPL-5536), however $0 was spelled (bash run.sh, a linked run dir). Today's
  # layout (./run -> src/bash/run/run.sh) resolves exactly as abs_path did. One
  # perl, as before; a dir that does not resolve still fails fast.
  unit_run_dir=$(perl -e 'use File::Basename; use Cwd "abs_path"; my ($p, $d, $n) = ($ARGV[0]);
    while (1) { $d = abs_path(dirname($p)) // die "abs_path: $p\n";
      last if $d =~ m{/src/bash/run$} || !-l $p || ++$n > 40;
      my $t = readlink $p; $p = $t =~ m{^/} ? $t : dirname($p) . "/$t"; }
    print $d;' -- "$0")
  # Parameter expansion, not basename/dirname: each $(basename ...) is a fork
  # + exec, and every ./run pays them before it does anything (perf round 4 C1).
  # unit_run_dir is already abs_path-resolved, so ${x##*/} is its basename.
  declare -gx RUN_UNIT="${unit_run_dir##*/}.sh" && export RUN_UNIT
  declare -gx PROJ_PATH="$(cd "${unit_run_dir:-}/../../.." && pwd)" && export PROJ_PATH
  declare -gx APP_PATH="$(cd "${unit_run_dir:-}/../../../.." && pwd)" && export APP_PATH
  declare -gx ORG_APP_PATH="${APP_PATH}" && export ORG_APP_PATH
  declare -gx ORG_PATH="$(cd "${unit_run_dir:-}/../../../../.." && pwd)" && export ORG_PATH
  declare -gx BASE_PATH="$(cd "${unit_run_dir:-}/../../../../../.." && pwd)" && export BASE_PATH
  _above_base="${BASE_PATH%/*}" && declare -gx VAR_DIR="${VAR_DIR:-${_above_base%/}/var}" && export VAR_DIR
  # Detect framework layer: if parent of PROJ_PATH matches *-frw, expose it as FRW_PATH
  _frw_candidate="${PROJ_PATH%/*}"
  if [[ "${_frw_candidate##*/}" == *-frw ]]; then
    declare -gx FRW_PATH="${_frw_candidate}" && export FRW_PATH
  else
    declare -gx FRW_PATH="" && export FRW_PATH
  fi
  do_ensure_logical_link
  # Path-derived building blocks. Env override wins; otherwise derived from the
  # canonical layout: BASE_PATH/ORG/APP/APP-PROJ_KIND.
  declare -gx ORG="${ORG:-${ORG_PATH##*/}}" && export ORG
  declare -gx APP="${APP:-${APP_PATH##*/}}" && export APP
  declare -gx PROJ="${PROJ_PATH##*/}" && export PROJ
  declare -gx PROJ_KIND="${PROJ_KIND:-${PROJ#${APP}-}}" && export PROJ_KIND

  declare -gx USER="${USER:-$(id -un)}" && export USER
  declare -gx HOST_NAME="$(hostname -s)" && export HOST_NAME
  declare -gx LOG_DIR="" && export LOG_DIR
}

do_ensure_logical_link() {
  if [[ "${unit_run_dir:-}" != */src/bash/run ]]; then
    export PROJ_PATH=$(cd $unit_run_dir && echo $(pwd))
  fi
}

do_finalize() {
  local _rc="${1:-$?}"
  do_log "INFO OK $RUN_UNIT's run completed"
  return "$_rc"
}

# Lazy function loader (spec 027 row 1). Sourcing every *.func.sh at start
# made the orc ./run Bash 69 MB, and each fork it made ($( ), a pipeline, a
# subshell) copied that: 5.1..5.6 ms kernel time per fork, 0.3 ms from a
# small Bash (os-tweaks-analysis.md 2.3). Now one awk pass (_RUN_INDEX_AWK)
# reads every *.func.sh under lib/bash/funcs/ and src/bash/run/ (subdirs
# too, one `find`, sorted as before) and sorts them in two kinds:
#   - a file with only function definitions at top level is NOT sourced.
#     Each of its functions gets a one-line stub that sources the file on
#     the first call, then calls the real function: an action, a helper of
#     another file, a PRE/POST/ARGS hook and a `declare -F x || source`
#     guard all find it, so no list of "always needed" libs has to be kept.
#   - a file that runs anything else at top level (a variable, a `source`,
#     an `if`) is sourced at start, after the stubs, in the old order:
#     what it sets may be read by any other file, so it stays eager.
# A stub needs _rl_load and _rl_files of this shell: a function shipped
# with `declare -f` to a child Bash must be loaded first (today every such
# function ships from the action's own file, which its call has loaded).
# _func_to_file keeps its old meaning: kebab-case.func.sh -> do_snake_case,
# registered when that function exists (a stub counts), .pre/.post skipped.
# Guard: run-lazy-loader.tst.sh (the index agrees with what sourcing each
# file defines; ./run -a sources only the files it needs).
read -r -d '' _RUN_INDEX_AWK <<'EOF_RUN_INDEX_AWK' || true
function unquote(s,   out, i, c, n, q) {
  out = ""; n = length(s); q = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "'") { if (c == "'") q = ""; continue }
    if (q == "\"") { if (c == "\\") i++; else if (c == "\"") q = ""; continue }
    if (c == "\\") { i++; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) break
    if (c == "<" && substr(s, i, 2) == "<<" && substr(s, i + 2, 1) != "<" && (i == 1 || substr(s, i - 1, 1) != "<")) {
      out = out "<<"; i += 2
      if (substr(s, i, 1) == "-") { out = out "-"; i++ }
      while (substr(s, i, 1) ~ /[ \t]/) i++
      c = substr(s, i, 1)
      if (c == "'" || c == "\"") { q = c; i++; while (i <= n && substr(s, i, 1) != q) out = out substr(s, i++, 1); q = ""; continue }
      i--; continue
    }
    if (c == "'" || c == "\"") { q = c; continue }
    out = out c
  }
  return out
}
function hd_scan(line,   s, m) {
  if (index(line, "<<") == 0) return
  s = unquote(line)
  while (match(s, /<<-?[A-Za-z_][A-Za-z0-9_]*/)) {
    m = substr(s, RSTART, RLENGTH); hdtab[++nhd] = (m ~ /^<<-/)
    sub(/^<<-?/, "", m); hd[nhd] = m
    s = substr(s, RSTART + RLENGTH)
  }
  if (nhd) hi = 1
}
function sq(s) { gsub(/'/, "'\\''", s); return "'" s "'" }
function flush() {
  if (file == "") return
  nfile++; files[nfile] = file; feager[nfile] = eager; fguards[nfile] = guards
  for (i = 1; i <= nf; i++) { ffn[nfile, i] = fn[i]; known[fn[i]] = 1 }
  fnf[nfile] = nf
}
function emit(k,   i, b, q, g, ng, eager) {
  q = sq(files[k]); eager = feager[k]
  ng = split(fguards[k], g, " ")
  for (i = 1; i <= ng; i++) if (!(g[i] in known)) eager = 1
  if (eager) print "_rl_eager+=(" q ")"
  else {
    print "_rl_files[" k "]=" q
    for (i = 1; i <= fnf[k]; i++) printf "%s() { _rl_load %d %s \"$@\"; }\n", ffn[k, i], k, ffn[k, i]
  }
  b = files[k]; sub(/^.*\//, "", b); sub(/\.func\.sh$/, "", b)
  if (b !~ /\.(pre|post)$/) { gsub(/-/, "_", b); print "_rl_cand+=(do_" b " " q ")" }
}
FNR == 1 { flush(); file = FILENAME; eager = 0; nf = 0; st = "top"; nhd = 0; hi = 0; guards = ""; cont = 0 }
{
  line = $0
  if (hi > 0) {
    t = line; if (hdtab[hi]) sub(/^\t+/, "", t)
    if (t == hd[hi]) { hi++; if (hi > nhd) { hi = 0; nhd = 0 } }
    next
  }
  if (st == "top") {
    if (line ~ /^[ \t]*(#.*)?$/) next
    if (cont) { cont = 0; if (line ~ /^[ \t]*(source|\.)[ \t]/) next; eager = 1 }
    # `declare -F f >/dev/null || source <file>`: a no-op once f has a stub,
    # so it keeps the file lazy when f is a known function (checked at END)
    if (match(line, /^[ \t]*(declare[ \t]+-F|type|command[ \t]+-v)[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*(&?>[ \t]*\/dev\/null)?([ \t]*2>&1)?[ \t]*\|\|/)) {
      rest = substr(line, RLENGTH + 1); g = line
      sub(/^[ \t]*(declare[ \t]+-F|type|command[ \t]+-v)[ \t]+/, "", g); sub(/[ \t&>|].*$/, "", g)
      if (rest ~ /^[ \t]*$/) { cont = 1; guards = guards " " g; next }
      if (rest ~ /^[ \t]*(source|\.)[ \t]+[^;&|<>`]*$/) { guards = guards " " g; next }
    }
    if (match(line, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*/) ||
        match(line, /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*(\{|$)/)) {
      name = line; sub(/^[ \t]*(function[ \t]+)?/, "", name); sub(/[ \t({].*$/, "", name)
      rest = substr(line, RLENGTH + 1); if (rest == "" && line ~ /\{[ \t]*$/) rest = "{"
      fn[++nf] = name
      if (rest ~ /^[ \t]*$/) { st = "brace"; next }
      if (rest ~ /^[{(].*[;&][ \t]*[})][ \t]*(#.*)?$/) next
      st = "body"; hd_scan(rest); next
    }
    eager = 1; hd_scan(line); next
  }
  if (st == "brace") {
    if (line ~ /^[ \t]*$/) next
    if (line ~ /^[ \t]*[{(][ \t]*$/) { st = "body"; next }
    eager = 1; st = "top"; next
  }
  if (line ~ /^[})]([ \t;|&<>].*)?$/) { st = "top"; next }
  hd_scan(line)
}
END { flush(); for (k = 1; k <= nfile; k++) emit(k) }
EOF_RUN_INDEX_AWK

# _rl_index <dir...>: runs the index (_RUN_INDEX_AWK) in the caller's scope,
# from a per-user cache when it is current (spec 027 perf round 7 row 03:
# the awk pass is ~165 ms of a ~950 ms orc start, the key ~12 ms). The key
# is the md5 of the sorted `mtime size path` list of every *.func.sh plus
# the awk program itself (not run.sh's file: a test may source run.sh from
# a pipe), so a touched, added or removed file or a new index rebuilds it. The cache file starts with a line that returns 9 unless _rl_key is
# its key, so a stale one is never used; it is written atomically (mv),
# and a cache dir that cannot be written only costs the awk pass. A failed
# awk pass is not cached. A miss also drops the cache of a tree that is gone
# (a retired lane worktree), so the dir does not grow with every lane.
_rl_index() {
  local _rl_key _rl_c _rl_t _rl_idx _rl_s
  _rl_c="${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/run-index"
  _rl_key=$({ find "$@" -type f -name "*.func.sh" -printf '%T@ %s %p\0' 2>/dev/null | sort -z || :
    printf '%s' "$_RUN_INDEX_AWK"; } | md5sum)
  _rl_key=${_rl_key%% *}
  _rl_t="$_rl_c/${PROJ_PATH//\//%}"
  # shellcheck source=/dev/null # the cache file is written below
  [[ -r "$_rl_t" ]] && source "$_rl_t" 2>/dev/null && return 0
  _rl_idx=$(find "$@" -type f -name "*.func.sh" -print0 2>/dev/null | sort -z |
    xargs -0 -r awk "$_RUN_INDEX_AWK") || _rl_t=""
  eval "$_rl_idx"
  [[ -n "$_rl_t" ]] || return 0
  { mkdir -p "$_rl_c" &&
    printf '[[ "$_rl_key" == %s ]] || return 9\n%s\n' "$_rl_key" "$_rl_idx" >"$_rl_t.$$" &&
    mv -f "$_rl_t.$$" "$_rl_t"; } 2>/dev/null || rm -f "$_rl_t.$$" 2>/dev/null
  for _rl_s in "$_rl_c"/%*; do
    _rl_t=${_rl_s##*/}; _rl_t=${_rl_t//%//}
    [[ -e "$_rl_s" && ! -d "$_rl_t" && ! -d "${_rl_t%.*}" ]] && rm -f "$_rl_s" 2>/dev/null
  done
  return 0
}

do_load_functions() {
  declare -gA _func_to_file
  declare -ga _rl_files=() _rl_done=()
  local _rl_dirs=() _rl_eager=() _rl_cand=() _rl_f _rl_i
  # Scan only dirs that exist (avoids `find` printing errors for missing trees).
  [[ -d "${PROJ_PATH:-}/lib/bash/funcs" ]] && _rl_dirs+=("${PROJ_PATH}/lib/bash/funcs")
  [[ -d "${PROJ_PATH:-}/src/bash/run" ]]   && _rl_dirs+=("${PROJ_PATH}/src/bash/run")
  (( ${#_rl_dirs[@]} == 0 )) && return
  _rl_index "${_rl_dirs[@]}"
  for _rl_f in "${_rl_eager[@]}"; do
    # shellcheck source=/dev/null # the file list is found at run time
    source "$_rl_f"
  done
  for ((_rl_i = 0; _rl_i < ${#_rl_cand[@]}; _rl_i += 2)); do
    declare -F "${_rl_cand[_rl_i]}" >/dev/null &&
      _func_to_file["${_rl_cand[_rl_i]}"]="${_rl_cand[_rl_i + 1]}"
  done
  return 0
}

# _rl_load <k> <fn> <args...>: the body of every stub. Sources lazy file k
# once, then runs <fn> <args...>, now the real function. No locals: the
# first call runs in this frame's dynamic scope. A file that does not define
# <fn> after all (an index fault) fails loudly instead of recursing.
_rl_load() {
  if [[ -n "${_rl_done[$1]:-}" ]]; then
    echo "run.sh: ${_rl_files[$1]} defines no $2" >&2
    return 127
  fi
  _rl_done[$1]=1
  # shellcheck source=/dev/null # the file list is found at run time
  source "${_rl_files[$1]}" || return
  shift
  "$@"
}

quit_on(){
  rv=$?
  if [ $rv -ne 0 ]; then
    do_log "FATAL Error: Failed to $1"
    exit $rv
  fi
}

main "$@"

#==============================================================================
# run.sh — minimalistic bash framework
# Version:  3.10.0
# Upstream: a sibling project (its -utl, v3.8.2)
#------------------------------------------------------------------------------
# Version history (newest first):
#   3.10.0 2026-11-15  The repo root carries its own copy: at the root, ./run
#                      hands -a do_x to the module that defines it (-m picks
#                      one of two), --help groups the actions by module
#                      (do_root_dispatch). SPL-5550.
#   3.9.0  2026-11-13  Lazy loader: a *.func.sh with only function definitions
#                      is sourced on the first call of one of them (stubs,
#                      _rl_load); one awk pass indexes the files. Spec 027
#                      row 1, SPL-5421.
#   3.8.4  2026-11-13  ./run re-execs once with GLIBC_TUNABLES
#                      glibc.malloc.top_pad=134217728 (do_run_top_pad),
#                      spec 027 row 1b, SPL-5421.
#   3.8.3  2026-10-22  ./run exits only after its stdout/stderr tees ended
#                      (bounded, RUN_TEE_WAIT_S), SPL-2820.
#   3.8.2  2026-10-21  One copy in csi-spl-iac, -orc and -utl, byte-identical
#                      (run-sh-parity.tst.sh, SPL-2756).
#   3.8.2  2026-10-16  Copied unchanged into csi-spl-utl from csi-spl-orc (SPL-2110).
#   3.8.2  2026-09-18  Copied unchanged into csi-spl-orc from csi-spl-iac.
#   3.8.2  2026-09-17  Copied unchanged into csi-spl-iac from sibling-prj-utl (the
#                      newest of the sibling-prj and csi-rel copies).
#   3.8.0  2026-04-30  Sync framework primitives from app-edw-utl: write-probe
#                      in do_detect_base_paths (more reliable than -w on some
#                      FUSE/NFS filesystems); path-derived LOG_DIR formula in
#                      do_log (both lib/bash/funcs/log.func.sh and run.sh
#                      inline copy) — removes hardcoded /var/<org>/<project>/
#                      sibling-prj-utl literal so logs land at
#                      \${VAR_DIR}/\${ORG}/\${APP}/\${PROJ}/dat/log/bash for
#                      whichever project clones this framework; +docker hint
#                      in do_require_bin install map.
#   3.7.0  2026-04-30  Forked back to csitea/sibling-prj as a minimal bootstrap.
#                      Slimmed: dropped Make, Docker, Confluence/Jira/GCP
#                      actions; nested under sibling-prj-utl/. Imported from
#                      sibling-prj-utl: auto-discovered actions, named-args + PRE/
#                      POST hooks, do_load_config, do_detect_base_paths,
#                      do_verify_symlinks, do_help_with, test fixtures.
#   3.6.4  2026-04-30  Sync point with sibling-prj-utl (full feature set, downstream).
#   2.x    2024-08     RUN_UNIT var resolution, OS-distro vars hardening
#                      (debian/suse/fedora), do_set_vars_v204 era.
#   1.1    2024-02     do_log split into a truly re-usable helper; DIR -> PATH
#                      naming refactor across the framework (<REDACTED>).
#   1.0.3  2023-01-11  First tagged release: limited support to invoke run from
#                      non-symlink <<PRODUCT_DIR>>/run + do_zip_me + per-distro
#                      set-vars-on-<<os>> hooks.
#
# When copying this file into a downstream project: bump the version above and
# append a new entry describing the local change. Keep the banner intact.
#==============================================================================
# csi-spl ::: v3.10.0
