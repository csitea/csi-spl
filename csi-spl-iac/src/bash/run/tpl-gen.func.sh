#!/bin/bash
#------------------------------------------------------------------------------
# @description Render csi-spl-cnf/csi-spl/<env>/tf/*.tfvars (and <env>.env.json)
# @description from csi-spl-cnf/csi-spl/<env>.env.yaml with tpl-gen, run
# @description locally from its venv -- no container.
# @description tpl-gen is the git-ignored sibling clone $APP_PATH/tpl-gen; its
# @description HEAD must equal cnf/tpl-gen.ref so a render is reproducible.
# @param ENV - required: dev or prd
# @param TPL_GEN_PATH (optional) - default: $APP_PATH/tpl-gen
# @example ENV=dev ./run -a do_tpl_gen
#------------------------------------------------------------------------------
do_tpl_gen() {
  do_resolve_oap ORG
  do_resolve_oap APP
  do_require_var ENV "${ENV:-}"
  [[ "$ENV" == dev || "$ENV" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: $ENV"; return 1; }

  local tpl_gen="${TPL_GEN_PATH:-$APP_PATH/tpl-gen}"
  local py_proj="$tpl_gen/src/python/tpl-gen"
  local cnf_proj="$APP_PATH/$ORG-$APP-cnf"
  local cnf_src="$cnf_proj/$ORG-$APP/$ENV.env.yaml"

  [[ -d "$tpl_gen/.git" ]] || {
    do_log "FATAL tpl-gen not found at $tpl_gen"
    do_log "INFO  git clone git@github.com:csitea/tpl-gen.git $tpl_gen && git -C $tpl_gen checkout $(cat "$PROJ_PATH/cnf/tpl-gen.ref")"
    return 1
  }
  local want have
  want=$(cat "$PROJ_PATH/cnf/tpl-gen.ref")
  have=$(git -C "$tpl_gen" rev-parse HEAD)
  [[ "$want" == "$have" ]] || {
    do_log "FATAL tpl-gen HEAD $have is not the pinned $want (cnf/tpl-gen.ref)"
    return 1
  }
  [[ -x "$py_proj/.venv/bin/python" ]] || {
    do_log "FATAL no venv at $py_proj/.venv"
    do_log "INFO  python3 -m venv $py_proj/.venv && $py_proj/.venv/bin/pip install jinja2 pyyaml jq colorama rich pprintjson requests"
    return 1
  }
  [[ -f "$cnf_src" ]] || { do_log "FATAL no config: $cnf_src"; return 1; }

  do_log "INFO rendering $cnf_src -> $cnf_proj/$ORG-$APP/$ENV/tf/"
  (
    cd "$py_proj" &&
      ORG="$ORG" APP="$APP" ENV="$ENV" \
        CNF_SRC="$cnf_src" \
        TPL_SRC="$PROJ_PATH/src/tpl/%org%-%app%/%env%/tf" \
        TGT="$cnf_proj" \
        .venv/bin/python tpl_gen/tpl_gen.py >/dev/null
  ) || { do_log "FATAL tpl-gen failed for ENV=$ENV"; return 1; }

  local f
  for f in "$cnf_proj/$ORG-$APP/$ENV/tf/"*.tfvars; do
    grep -q '{{\|{%\|%org%\|%env%' "$f" && { do_log "FATAL unrendered token left in $f"; return 1; }
    do_log "INFO rendered $f"
  done
  return 0
}
