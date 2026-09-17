# usage: do_resolve_oap ORG, do_resolve_oap APP, do_resolve_oap PROJ
# Resolves ORG, APP, PROJ from the environment or the directory structure.
# If already set (e.g. from GitHub Actions vars via Terraform step 120), use as-is
# UNLESS the value mismatches the current directory (stale from another project).
# Otherwise derive from the directory convention:
#   <base>/<ORG>/<ORG>-<APP>/<ORG>-<APP>-<PROJ_TYPE>
do_resolve_oap() {
  case "$1" in
    ORG)
      local derived_org="$(basename "$(dirname "$APP_PATH")")"
      if [[ -n "${ORG:-}" ]] && [[ "$ORG" == "$derived_org" ]]; then
        return 0
      fi
      export ORG="$derived_org"
      return 0
      ;;
    APP)
      local app_basename="$(basename "$APP_PATH")"
      local derived_app="${app_basename#*-}"
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
