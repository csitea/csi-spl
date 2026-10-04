#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Set this repo's GitHub Actions repository VARIABLES that make the
# @description workflows fork-portable (spec 072 A13, research 12 C1). One table,
# @description one place: never a hand `gh variable set`.
# @description   SPOOL_CI_RUNNER  the `runs-on` of wf 10, as JSON (a label array
# @description                    or a quoted string). Unset -> ubuntu-latest, so
# @description                    a fork's gate runs on GitHub-hosted runners; this
# @description                    repo sets its self-hosted label, so here nothing
# @description                    changes.
# @description Prints one line per variable: unchanged / would create / would
# @description update (old -> new). DRY_RUN=1 (the default) changes nothing;
# @description DRY_RUN=0 writes each differing variable, then reads it back.
# @param GH_CI_VARS_REPO (optional) - <owner>/<repo>, default: parsed from the
# @param        checkout's `origin` remote (no literal default)
# @param SPOOL_CI_RUNNER (optional) - JSON, default ["self-hosted","spool-ci"]
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_gh_set_ci_vars
# @example DRY_RUN=0 ./run -a do_gh_set_ci_vars
#------------------------------------------------------------------------------

# the wanted variables, one NAME<TAB>VALUE line each
_gscv_wanted() {
  printf 'SPOOL_CI_RUNNER\t%s\n' "${SPOOL_CI_RUNNER:-[\"self-hosted\",\"spool-ci\"]}"
}

_gscv_repo() {
  if [[ -n "${GH_CI_VARS_REPO:-}" ]]; then printf '%s\n' "$GH_CI_VARS_REPO"; return 0; fi
  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

# the current value, empty when the variable does not exist (gh prints the
# 404 body on stdout, so the value counts only when gh exits 0)
_gscv_get() {  # <repo> <name>
  local v; v="$(gh api "repos/$1/actions/variables/$2" --jq .value 2>/dev/null)" && printf '%s\n' "$v"
  return 0
}

# <repo> <name> <want> <dry> - 0 = in place (or would be set), 1 = error
_gscv_apply() {
  local repo="$1" name="$2" want="$3" dry="$4" have
  jq -e 'type == "array" or type == "string"' <<<"$want" >/dev/null 2>&1 \
    || { do_log "ERROR $name is not JSON (a label array or a quoted string): $want"; return 1; }
  have="$(_gscv_get "$repo" "$name")"
  if [[ "$have" == "$want" ]]; then do_log "OK $repo $name unchanged: $want"; return 0; fi
  if [[ "$dry" != 0 ]]; then
    if [[ -z "$have" ]]; then do_log "INFO DRY_RUN $repo $name would create: $want"
    else do_log "INFO DRY_RUN $repo $name would update: $have -> $want"; fi
    return 0
  fi
  gh variable set "$name" --repo "$repo" --body "$want" >/dev/null \
    || { do_log "ERROR cannot set $repo $name"; return 1; }
  have="$(_gscv_get "$repo" "$name")"
  [[ "$have" == "$want" ]] || { do_log "ERROR $repo $name reads back '$have', want '$want'"; return 1; }
  do_log "OK $repo $name set: $want"
}

do_gh_set_ci_vars() {
  command -v gh >/dev/null 2>&1 || { do_log "FATAL gh not found"; return 1; }
  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq not found"; return 1; }
  local repo re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' dry="${DRY_RUN:-1}" name want bad=0
  repo="$(_gscv_repo)"
  [[ "$repo" =~ $re ]] || { do_log "FATAL no <owner>/<repo>: set GH_CI_VARS_REPO (no default); origin gave '$repo'"; return 1; }
  gh api "repos/$repo" --jq .full_name >/dev/null || { do_log "FATAL cannot read $repo with gh"; return 1; }
  while IFS=$'\t' read -r name want; do
    _gscv_apply "$repo" "$name" "$want" "$dry" || bad=1
  done < <(_gscv_wanted)
  ((bad)) && return 1
  [[ "$dry" != 0 ]] && do_log "OK DRY_RUN nothing written. Re-run with DRY_RUN=0 to set what differs."
  return 0
}
