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
# @description   SPL_WT_ROOT        <main checkout>-wt, the lane worktrees
# @description   SPL_DESK_DIR       <main checkout>-desk-cron
# @description <var> is run.sh's rule: <base>/../var. A cnf value carries the
# @description tokens ${SPL_ORG_DIR} / ${SPL_VAR_APP_DIR}; its reader expands
# @description them with spl_cnf_path_expand (a literal replace, never eval).
# @description Each SPL_* var keeps an env override of the same name.
# @example spl_run_paths && echo "$SPL_WT_ROOT"
#------------------------------------------------------------------------------

# spl_main_checkout -> the main checkout of the git tree whose top is
# dir = APP_PATH, else PROJ_PATH: dir itself when dir/.git is a
# directory; for a worktree (dir/.git is a file "gitdir: <main>/.git/
# worktrees/<id>") its shared clone. Read from the file, no git call: git
# refuses a tree another user owns. Neither: dir; no dir: rc 1.
spl_main_checkout() {
  local d="${APP_PATH:-${PROJ_PATH:-}}" g
  [[ -n "$d" ]] || return 1
  d="${d%/}"
  if [[ -f "$d/.git" ]]; then
    IFS= read -r g <"$d/.git" 2>/dev/null || g=""
    g="${g#gitdir: }"
    [[ "$g" == /*/.git/worktrees/* ]] && { printf '%s\n' "${g%%/.git/worktrees/*}"; return 0; }
  fi
  printf '%s\n' "$d"
}

# spl_run_paths: export SPL_ORG_DIR, SPL_VAR_APP_DIR, SPL_WT_ROOT and
# SPL_DESK_DIR (one already set is kept). rc 1 when no tree is known.
spl_run_paths() {
  local main org base
  main="$(spl_main_checkout)" || return 1
  org="${main%/*}"; base="${org%/*}"
  : "${SPL_ORG_DIR:=$org}"
  : "${SPL_VAR_APP_DIR:=${base%/*}/var/${org##*/}/${main##*/}}"
  : "${SPL_WT_ROOT:=${main}-wt}"
  : "${SPL_DESK_DIR:=${main}-desk-cron}"
  export SPL_ORG_DIR SPL_VAR_APP_DIR SPL_WT_ROOT SPL_DESK_DIR
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
