#!/bin/bash
#------------------------------------------------------------------------------
# @description Clone tpl-gen at the pinned cnf/tpl-gen.ref into the git-ignored
# @description sibling $APP_PATH/tpl-gen and build its local .venv, the exact
# @description layout do_tpl_gen and tf-steps-render-and-validate.tst.sh read.
# @description Idempotent: a clone already at the pin is kept; a clone at any
# @description other sha is REFUSED, never moved (it may be someone's work).
# @description The CI iac-suite job (10_ci-quality.yml) runs this action.
# @param TPL_GEN_REPO_URL - required, no default: the tpl-gen git remote
# @param TPL_GEN_PATH (optional) - default: $APP_PATH/tpl-gen
# @param TPL_GEN_PIP_PKGS (optional) - default: the do_tpl_gen dependency list
# @example TPL_GEN_REPO_URL=https://github.com/<ORG>/tpl-gen.git ./run -a do_setup_tpl_gen
#------------------------------------------------------------------------------
do_setup_tpl_gen() {
  : "${TPL_GEN_REPO_URL:?TPL_GEN_REPO_URL must be set (no default) -- e.g. https://github.com/<ORG>/tpl-gen.git}"
  local tpl_gen="${TPL_GEN_PATH:-$APP_PATH/tpl-gen}"
  local py_proj="$tpl_gen/src/python/tpl-gen"
  local pkgs="${TPL_GEN_PIP_PKGS:-jinja2 pyyaml jq colorama rich pprintjson requests}"
  local want have
  want=$(<"$PROJ_PATH/cnf/tpl-gen.ref") || return 1
  [[ "$want" =~ ^[0-9a-f]{40}$ ]] || { do_log "FATAL cnf/tpl-gen.ref is not a full sha: $want"; return 1; }

  if [[ -d "$tpl_gen/.git" ]]; then
    have=$(git -C "$tpl_gen" rev-parse HEAD) || return 1
    [[ "$have" == "$want" ]] || {
      do_log "FATAL $tpl_gen is at $have, not the pinned $want -- move it yourself, this action never does"
      return 1
    }
    do_log "INFO tpl-gen already at the pinned $want"
  else
    [[ -e "$tpl_gen" ]] && { do_log "FATAL $tpl_gen exists and is not a git clone"; return 1; }
    git clone -q "$TPL_GEN_REPO_URL" "$tpl_gen" || { do_log "FATAL git clone of tpl-gen failed"; return 1; }
    git -C "$tpl_gen" -c advice.detachedHead=false checkout -q "$want" || { do_log "FATAL cannot check out $want"; return 1; }
    do_log "INFO cloned tpl-gen at the pinned $want"
  fi

  if [[ -x "$py_proj/.venv/bin/python" ]]; then
    do_log "INFO tpl-gen venv already at $py_proj/.venv"
  else
    python3 -m venv "$py_proj/.venv" || { do_log "FATAL python3 -m venv failed"; return 1; }
    # shellcheck disable=SC2086
    "$py_proj/.venv/bin/pip" install -q $pkgs || { do_log "FATAL pip install of the tpl-gen dependencies failed"; return 1; }
    do_log "INFO built the tpl-gen venv at $py_proj/.venv"
  fi
  return 0
}
