#!/bin/bash
#------------------------------------------------------------------------------
# @description The box paths an action needs, derived at run time from where
# @description this tree sits, never written in code or in the cnf (owner
# @description HUM-10, t1 #refactoring: "There should be no paths in the
# @description configuration files"; SPL-5527, spec 011).
# @description run.sh (do_set_vars) derives APP_PATH, ORG_PATH, BASE_PATH and
# @description VAR_DIR from the real path of ./run. In an agent worktree
# @description (<org dir>/<app>-wt/<id>) those read one level off, so these
# @description helpers start from the MAIN checkout of the repo (the parent
# @description of git's common dir), the same answer in every worktree:
# @description   spl_main_checkout  <base>/<org>/<app>, the shared clone
# @description   SPL_ORG_DIR        <base>/<org>, the org's repos
# @description   SPL_VAR_APP_DIR    <var>/<org>/<app>, state and logs
# @description   SPL_VAR_ORG_DIR    <var>/<org>, the org's state
# @description   SPL_WT_ROOT        <main checkout>-wt, the lane worktrees
# @description   SPL_DESK_DIR       <main checkout>-desk-cron
# @description <var> is run.sh's rule: <base>/../var. A cnf value carries the
# @description tokens ${SPL_ORG_DIR} / ${SPL_VAR_APP_DIR}; its reader expands
# @description them with spl_cnf_path_expand (a literal replace, never eval).
# @description Each SPL_* var keeps an env override of the same name.
# @example spl_run_paths && echo "$SPL_WT_ROOT"
#------------------------------------------------------------------------------

# _spl_run_paths_top -> the checkout this file sits in
# (<top>/csi-spl-orc/lib/bash/funcs): the last resort of spl_main_checkout,
# so a script that sources an action without ./run (a cron such as
# file-stream-follow-cron.sh) still derives every path. SPL_RUN_PATHS_TOP
# set (even empty) overrides it. -P resolves symlinks, as run.sh's abs_path
# does. A function, not a top-level assignment: a file with only
# definitions gets lazy stubs from the orc ./run index (spec 027,
# run-eager-files.tst.sh); BASH_SOURCE[0] in a function is its own file.
_spl_run_paths_top() {
  if [[ -n "${SPL_RUN_PATHS_TOP+x}" ]]; then printf '%s\n' "$SPL_RUN_PATHS_TOP"; return 0; fi
  (cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." 2>/dev/null && pwd -P)
}

# spl_main_checkout -> the main checkout of the git tree whose top is
# dir = APP_PATH, else PROJ_PATH/.. (run.sh's PROJ_PATH is
# <top>/csi-spl-<module>), else the checkout this file sits in. dir itself
# when dir/.git is a directory; for a worktree (dir/.git is a file "gitdir:
# <main>/.git/worktrees/<id>", absolute or relative to dir) its shared
# clone. Read from the file, no git call: git refuses a tree another user
# owns. rc 1 only when no dir is known at all.
spl_main_checkout() {
  local d g
  if [[ -n "${APP_PATH:-}" ]]; then d="$APP_PATH"
  elif [[ -n "${PROJ_PATH:-}" ]]; then d="${PROJ_PATH%/}/.."
  else d="$(_spl_run_paths_top)"; fi
  [[ -n "$d" ]] || return 1
  d="${d%/}"
  [[ "$d" == */.. ]] && d="$(cd "$d" 2>/dev/null && pwd -P)"
  [[ -n "$d" ]] || return 1
  if [[ -f "$d/.git" ]]; then
    IFS= read -r g <"$d/.git" 2>/dev/null || g=""
    g="${g#gitdir: }"
    [[ -n "$g" && "$g" != /* ]] && g="$d/$g"
    [[ "$g" == /*/.git/worktrees/* ]] && { g="${g%%/.git/worktrees/*}"; printf '%s\n' "$(cd "$g" 2>/dev/null && pwd -P || printf '%s' "$g")"; return 0; }
  fi
  printf '%s\n' "$d"
}

# spl_run_paths: export SPL_ORG_DIR, SPL_VAR_APP_DIR, SPL_VAR_ORG_DIR
# (<var>/<org>, org state), SPL_WT_ROOT and SPL_DESK_DIR (one already set
# is kept). rc 1 when no tree is known.
spl_run_paths() {
  local main org base
  main="$(spl_main_checkout)" || return 1
  org="${main%/*}"; base="${org%/*}"
  : "${SPL_ORG_DIR:=$org}"
  : "${SPL_VAR_APP_DIR:=${base%/*}/var/${org##*/}/${main##*/}}"
  : "${SPL_VAR_ORG_DIR:=${base%/*}/var/${org##*/}}"
  : "${SPL_WT_ROOT:=${main}-wt}"
  : "${SPL_DESK_DIR:=${main}-desk-cron}"
  export SPL_ORG_DIR SPL_VAR_APP_DIR SPL_VAR_ORG_DIR SPL_WT_ROOT SPL_DESK_DIR
}

# spl_cnf_path_expand < lines -> the lines with each ${SPL_ORG_DIR} and
# ${SPL_VAR_APP_DIR} token of a cnf value replaced by its derived value
# (spl_run_paths). A literal replace: no other $ in a value is touched; a
# token that cannot be derived stays, so an absolute-path check refuses it.
spl_cnf_path_expand() {
  spl_run_paths 2>/dev/null || true
  local l o='${SPL_ORG_DIR}' v='${SPL_VAR_APP_DIR}'
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ -n "${SPL_ORG_DIR:-}" ]] && l="${l//"$o"/$SPL_ORG_DIR}"
    [[ -n "${SPL_VAR_APP_DIR:-}" ]] && l="${l//"$v"/$SPL_VAR_APP_DIR}"
    printf '%s\n' "$l"
  done
}
