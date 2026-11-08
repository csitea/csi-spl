#!/bin/bash
#------------------------------------------------------------------------------
# @description Add one GitHub-only row to this box's landed-repos file, the
# @description SPOOL_LANDED_REPOS_FILE that spl_landed_repo_rows reads (SPL-5083),
# @description so a lane that lands in a repo the tree must not name can end its
# @description issue. The file is written by the spool root's owner, mode 0644;
# @description a re-run is a no-op; a name a cnf or workspace map row has is
# @description refused. A dry run (the default) writes nothing. Never in git:
# @description the row's values are given here and no line printed repeats them.
# @param LANDED_REPO_NAME - required: the name lanes pass as LANE_LANDED_REPO
# @param LANDED_REPO_GITHUB - required: <owner>/<repo>
# @param LANDED_REPO_TRUNK - required: the trunk branch
# @param LANDED_REPO_BOX - required: the box the repo's work lands from
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param SPOOL_LANDED_REPOS_FILE (optional) - default <spool root>/landed-repos.yaml; required under SPOOL_TEST=1
# @example LANDED_REPO_NAME=<name> LANDED_REPO_GITHUB=<owner>/<repo> LANDED_REPO_TRUNK=master LANDED_REPO_BOX=<box> ./run -a do_spl_landed_repo_put
# @example LANDED_REPO_NAME=<name> LANDED_REPO_GITHUB=<owner>/<repo> LANDED_REPO_TRUNK=master LANDED_REPO_BOX=<box> DRY_RUN=0 ./run -a do_spl_landed_repo_put
#------------------------------------------------------------------------------
do_spl_landed_repo_put() {
  local name="${LANDED_REPO_NAME:-}" github="${LANDED_REPO_GITHUB:-}" trunk="${LANDED_REPO_TRUNK:-}" box="${LANDED_REPO_BOX:-}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" file owner have out
  do_require_bin yq
  declare -F spl_landed_repo_rows >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-issue.func.sh" || return 1
  spl_landed_repo_put_args_ok "$name" "$github" "$trunk" "$box" || return 1
  [[ "${SPOOL_TEST:-}" != 1 || -n "${SPOOL_LANDED_REPOS_FILE:-}" ]] ||
    { do_log "FATAL SPOOL_LANDED_REPOS_FILE must be set in a test sandbox: refused, nothing changed"; return 1; }
  file="${SPOOL_LANDED_REPOS_FILE:-$root/landed-repos.yaml}"
  owner="$(stat -L -c %U "$root" 2>/dev/null)" || { do_log "FATAL cannot read the owner of the spool root $root: refused, nothing changed"; return 1; }
  if spl_landed_repo_put_taken "$name" "$file"; then
    do_log "FATAL a cnf or workspace map row already has that name: refused, nothing changed"
    return 1
  fi
  if [[ -e "$file" ]]; then
    spl_landed_repo_box_file_ok "$file" || { do_log "FATAL $file is not trusted, so its rows cannot be carried over: refused, nothing changed"; return 1; }
    have="$(LRP_NAME="$name" yq -r '.env.box.landed_repos[]? | select(.name == strenv(LRP_NAME)) | [.github, .trunk, .box] | @tsv' "$file" 2>/dev/null)" ||
      { do_log "FATAL cannot parse $file: refused, nothing changed"; return 1; }
    if [[ "$have" == "$github"$'\t'"$trunk"$'\t'"$box" ]]; then
      do_log "OK $file already has this row: nothing to do"
      return 0
    fi
    [[ -z "$have" ]] || { do_log "FATAL $file has that name with other values: refused, nothing changed"; return 1; }
  fi
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN would add the row to $file as $owner, mode 0644"
    return 0
  fi
  out="$(spl_landed_repo_put_render "$file" "$name" "$github" "$trunk" "$box")" && [[ -n "$out" ]] ||
    { do_log "FATAL cannot parse $file: refused, nothing changed"; return 1; }
  spl_landed_repo_put_write "$file" "$owner" "$out" || return 1
  do_log "OK added the row to $file, owned by $owner, mode 0644"
}

# spl_landed_repo_put_args_ok NAME GITHUB TRUNK BOX: the charsets the resolver
# accepts (spl_landed_repo_rows), one FATAL per bad value that does not echo it.
spl_landed_repo_put_args_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]] || { do_log "FATAL LANDED_REPO_NAME must be a repo name, not empty, a path or a URL: refused, nothing changed"; return 1; }
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ && "$2" != *..* ]] || { do_log "FATAL LANDED_REPO_GITHUB must be <owner>/<repo>, not empty or a URL: refused, nothing changed"; return 1; }
  [[ "$3" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$3" != *..* ]] || { do_log "FATAL LANDED_REPO_TRUNK must be a branch name: refused, nothing changed"; return 1; }
  [[ "$4" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL LANDED_REPO_BOX must be a box tag: refused, nothing changed"; return 1; }
}

# spl_landed_repo_put_taken NAME FILE: true when a cnf (dev or prd: the file
# serves both) or workspace map row has NAME. FILE's own rows do not count:
# the resolver is pointed at a path that does not exist.
spl_landed_repo_put_taken() {
  local e
  for e in dev prd; do
    ENV="$e" SPOOL_LANDED_REPOS_FILE="$2.absent" spl_landed_repo_rows 2>/dev/null
  done | awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit !f }'
}

# spl_landed_repo_put_render FILE NAME GITHUB TRUNK BOX -> FILE's YAML with
# the row appended; a missing or empty FILE starts a new document.
spl_landed_repo_put_render() {
  local expr='.env.box.landed_repos += [{"name": strenv(LRP_NAME), "github": strenv(LRP_GITHUB), "trunk": strenv(LRP_TRUNK), "box": strenv(LRP_BOX)}]'
  local -a src=(-n)
  [[ -s "$1" ]] && src=("$1")
  LRP_NAME="$2" LRP_GITHUB="$3" LRP_TRUNK="$4" LRP_BOX="$5" yq "$expr" "${src[@]}" 2>/dev/null
}

# spl_landed_repo_put_as OWNER CMD...: CMD as OWNER, through sudo when this
# user is someone else.
spl_landed_repo_put_as() {
  local o="$1"; shift
  if [[ "$(id -un)" == "$o" ]]; then "$@"; else sudo -n -u "$o" "$@"; fi
}

# spl_landed_repo_put_write FILE OWNER CONTENT: a temp file beside FILE, then
# mv, so a reader never sees half a file; no temp file is left on a failure.
spl_landed_repo_put_write() {
  local tmp
  tmp="$(spl_landed_repo_put_as "$2" mktemp "$1.XXXXXX")" || { do_log "FATAL cannot create a temp file beside $1 as $2: refused, nothing changed"; return 1; }
  if spl_landed_repo_put_as "$2" tee "$tmp" <<<"$3" >/dev/null && spl_landed_repo_put_as "$2" chmod 0644 "$tmp" &&
    spl_landed_repo_put_as "$2" mv -f "$tmp" "$1"; then
    return 0
  fi
  spl_landed_repo_put_as "$2" rm -f "$tmp"
  do_log "FATAL cannot write $1 as $2: refused, nothing changed"
  return 1
}
