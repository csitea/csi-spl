#!/bin/bash
#------------------------------------------------------------------------------
# @description Render csi-spl-cnf/csi-spl/<env>/tf/*.tfvars and <env>.env.json
# @description from the EFFECTIVE config of the env: all.env.yaml deep-merged
# @description under <env>.env.yaml plus the derived env.dns.fqdn
# @description (do_spl_merged_cnf). tpl-gen runs locally from its venv.
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
  local cnf_dir="$cnf_proj/$ORG-$APP"

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
  local work cnf_src
  work=$(mktemp -d) || return 1
  cnf_src="$work/$ENV.env.yaml"
  do_spl_merged_cnf "$cnf_dir" "$ENV" "$cnf_src" || { rm -rf "$work"; do_log "FATAL cannot build the effective config for $ENV"; return 1; }

  do_log "INFO rendering all.env.yaml + $ENV.env.yaml -> $cnf_dir/$ENV/tf/"
  (
    cd "$py_proj" &&
      ORG="$ORG" APP="$APP" ENV="$ENV" \
        CNF_SRC="$cnf_src" \
        TPL_SRC="$PROJ_PATH/src/tpl/%org%-%app%/%env%/tf" \
        TGT="$cnf_proj" \
        .venv/bin/python tpl_gen/tpl_gen.py >/dev/null
  ) || { rm -rf "$work"; do_log "FATAL tpl-gen failed for ENV=$ENV"; return 1; }
  yq -o json '.' "$cnf_src" >"$cnf_dir/$ENV.env.json" || { rm -rf "$work"; return 1; }
  rm -rf "$work"
  do_log "INFO rendered $cnf_dir/$ENV.env.json (effective config, generated)"

  local f
  for f in "$cnf_proj/$ORG-$APP/$ENV/tf/"*.tfvars; do
    grep -q '{{\|{%\|%org%\|%env%' "$f" && { do_log "FATAL unrendered token left in $f"; return 1; }
    do_log "INFO rendered $f"
  done
  return 0
}
