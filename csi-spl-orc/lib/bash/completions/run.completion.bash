#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Tab completion for csi-spl's ./run (spec 069 lane Y10):  ./run -a <TAB>
#
# Sourced from ~/.bashrc by the spool-install step steps/y10-run-completion.sh;
# by hand:  . <checkout>/csi-spl-orc/lib/bash/completions/run.completion.bash
#
# The project is the directory of the command word (./run -> the CWD), so it
# completes in csi-spl-iac, csi-spl-orc or any <app>-<part> that has
# src/bash/run/. Actions are what run.sh's do_load_functions registers from
# there: src/bash/run/**/<kebab>.func.sh -> do_<snake>, hooks (*.pre, *.post)
# skipped. lib/bash/funcs helpers are not offered: they are not user actions.
# Both forms are offered, do_<snake> first-class (run.sh accepts either).
# After the action, its `# @arg --flag VAR` header lines complete as flags.
# No cache file: one find per <TAB> (measured ~10 ms on 224 actions).
#------------------------------------------------------------------------------

# The project dir of the run command being completed, or nothing.
_spl_run_proj() {
  local w="${COMP_WORDS[0]}" d
  [[ "$w" == */* ]] && d="${w%/*}" || d="."
  [[ -d "$d/src/bash/run" ]] && printf '%s\n' "$d"
}

# Every action file of project $1 (hooks excluded), one path per line.
_spl_run_func_files() {
  find -L "$1/src/bash/run" -type f -name '*.func.sh' \
    ! -name '*.pre.func.sh' ! -name '*.post.func.sh' 2>/dev/null
}

# The action names of project $1: do_<snake> and <kebab> for each file.
_spl_run_actions() {
  local f base
  while IFS= read -r f; do
    base="${f##*/}"
    base="${base%.func.sh}"
    printf 'do_%s\n%s\n' "${base//-/_}" "$base"
  done < <(_spl_run_func_files "$1")
}

# The `# @arg --flag VAR` flags of action $2 in project $1.
_spl_run_action_flags() {
  local a="${2#do_}" f
  a="${a//_/-}"
  f="$(_spl_run_func_files "$1" | grep -m1 -E "/${a}\.func\.sh$")"
  [[ -n "$f" ]] && sed -n 's/^#[[:space:]]*@arg[[:space:]]\{1,\}\(-[^[:space:]]*\).*/\1/p' "$f"
}

_spl_run_completions() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}" proj i action=""
  COMPREPLY=()
  proj="$(_spl_run_proj)"
  if [[ "$prev" == "-a" || "$prev" == "--actions" ]]; then
    [[ -n "$proj" ]] || return 0
    mapfile -t COMPREPLY < <(compgen -W "$(_spl_run_actions "$proj")" -- "$cur")
    return 0
  fi
  for ((i = 1; i < COMP_CWORD; i++)); do
    if [[ "${COMP_WORDS[i]}" == "-a" || "${COMP_WORDS[i]}" == "--actions" ]]; then
      action="${COMP_WORDS[i+1]:-}"
      break
    fi
  done
  if [[ -n "$action" && -n "$proj" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(_spl_run_action_flags "$proj" "$action")" -- "$cur")
    return 0
  fi
  mapfile -t COMPREPLY < <(compgen -W "-a --actions -h --help" -- "$cur")
}

complete -F _spl_run_completions run ./run
