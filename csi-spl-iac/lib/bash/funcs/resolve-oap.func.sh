#!/usr/bin/env bash
# usage: do_resolve_oap ORG, do_resolve_oap APP, do_resolve_oap PROJ
# Resolves ORG, APP, PROJ from the environment or the directory structure.
# If already set (e.g. from GitHub Actions vars via Terraform step 120), use as-is
# UNLESS the value mismatches the current directory (stale from another project).
# Otherwise derive from the project dir's OWN name, <ORG>-<APP>-<PROJ_TYPE>
# (basename of PROJ_PATH). That name is the same in the canonical layout
#   <base>/<ORG>/<ORG>-<APP>/<ORG>-<APP>-<PROJ_TYPE>
# and in an agent worktree
#   <base>/<ORG>/<ORG>-<APP>-wt/<ID>/<ORG>-<APP>-<PROJ_TYPE>
# where the parent dirs are not <ORG>/<ORG>-<APP> (deriving from them gave
# ORG=csi-spl-wt APP=3344 there; spec 007 T069).
_oap_field() { basename "$PROJ_PATH" | cut -d'-' -f"$1"; }

do_resolve_oap() {
  case "$1" in
    ORG)
      local derived_org="$(_oap_field 1)"
      if [[ -n "${ORG:-}" ]] && [[ "$ORG" == "$derived_org" ]]; then
        return 0
      fi
      export ORG="$derived_org"
      return 0
      ;;
    APP)
      local derived_app="$(_oap_field 2)"
      if [[ -n "${APP:-}" ]] && [[ "$APP" == "$derived_app" ]]; then
        return 0
      fi
      export APP="$derived_app"
      return 0
      ;;
    PROJ)
      local derived_proj="$(_oap_field 3)"
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
