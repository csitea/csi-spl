# usage: do_resolve_oap ORG, do_resolve_oap APP, do_resolve_oap PROJ
# Resolves ORG, APP, PROJ from the environment or the directory structure.
# If already set (e.g. from GitHub Actions vars via Terraform step 120), use as-is
# UNLESS the value mismatches the current directory (stale from another project).
# Otherwise derive from the directory convention:
#   <base>/<ORG>/<ORG>-<APP>/<ORG>-<APP>-<PROJ_TYPE>
#
# A LINKED GIT WORKTREE breaks that convention: its root is
# <base>/<ORG>/<ORG>-<APP>-wt/<AGENT-ID>, which would derive ORG=<ORG>-<APP>-wt
# and APP=<AGENT-ID> and send every *_PROJ_PATH at a directory that does not
# exist. ORG/APP are therefore derived from the MAIN worktree's path, while
# APP_PATH itself stays the worktree, so paths resolve inside the worktree
# with the repo's real ORG/APP.
_do_oap_canonical_app_path() {
  local p="${APP_PATH:-}" gd
  if [[ -f "${p}/.git" ]]; then
    gd="$(sed -n 's/^gitdir: *//p' "${p}/.git" 2>/dev/null)"
    if [[ "$gd" == */.git/worktrees/* ]]; then
      printf '%s\n' "${gd%%/.git/worktrees/*}"
      return 0
    fi
  fi
  printf '%s\n' "$p"
}

do_resolve_oap() {
  local canonical_app_path
  canonical_app_path="$(_do_oap_canonical_app_path)"
  case "$1" in
    ORG)
      local derived_org="$(basename "$(dirname "$canonical_app_path")")"
      if [[ -n "${ORG:-}" ]] && [[ "$ORG" == "$derived_org" ]]; then
        return 0
      fi
      export ORG="$derived_org"
      return 0
      ;;
    APP)
      local derived_app="$(basename "$canonical_app_path")"
      if [[ -n "${APP:-}" ]] && [[ "$APP" == "$derived_app" ]]; then
        return 0
      fi
      export APP="$derived_app"
      return 0
      ;;
    PROJ)
      local derived_proj="$(basename "$PROJ_PATH" | cut -d'-' -f3)"
      if [[ -n "${PROJ:-}" ]] && [[ "$PROJ" == "$derived_proj" ]]; then
        return 0
      fi
      export PROJ="$derived_proj"
      return 0
      ;;
    *)
      echo "Invalid argument. Use ORG, APP or PROJ." >&2
      return 1
      ;;
  esac
}
