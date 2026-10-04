#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Wire the GitHub repo VARIABLES that wf 20 (hub) and wf 30 (WUI)
# @description read for keyless WIF deploys, from terraform's own outputs
# @description (spec 072 A11, manual step 4.3 #11): no hand `gh variable set`.
# @description Per env (<E> = the env upper-cased):
# @description   GCP_WIF_PROVIDER_<E>              step 017 wif_provider_name
# @description   GCP_DEPLOY_SA_EMAIL_<E>           step 017 deploy_sa_email
# @description   GCP_FIREBASE_DEPLOY_SA_EMAIL_<E>  step 016 firebase_deploy_sa_email
# @description Each output is read from the step's state object in the env's
# @description tfstate bucket (bucket + prefix from the rendered
# @description <env>/tf/<step>.backend-config.tfvars), as that env's project SA
# @description in a private gcloud config (do_gcp_pin_account). Only the named
# @description outputs are kept; the state itself is never printed or saved.
# @description A value that is missing (step not applied) or malformed is
# @description refused with the step to apply; the other variables still run.
# @description Prints one line per variable: unchanged / would create / would
# @description update (old -> new). DRY_RUN=1 (the default) changes nothing;
# @description DRY_RUN=0 writes each differing variable, then reads it back.
# @param GH_WIRE_ENVS (optional) - space-separated envs, default: every env
# @param        whose cnf has a rendered step 017 backend config
# @param GH_WIRE_REPO (optional) - <owner>/<repo>, default: parsed from the
# @param        checkout's `origin` remote (no literal default)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_gh_wire
# @example GH_WIRE_ENVS=dev DRY_RUN=0 ./run -a do_spl_gh_wire
#------------------------------------------------------------------------------

# the wired variables, one NAME_PREFIX<TAB>STEP<TAB>OUTPUT<TAB>VALUE-REGEX line each
_sgw_map() {
  local wif='^projects/[0-9]+/locations/global/workloadIdentityPools/[^/]+/providers/[^/]+$'
  local sa='^[a-z][a-z0-9-]*@[a-z][a-z0-9-]*\.iam\.gserviceaccount\.com$'
  printf 'GCP_WIF_PROVIDER\t017-github-wif-deploy\twif_provider_name\t%s\n' "$wif"
  printf 'GCP_DEPLOY_SA_EMAIL\t017-github-wif-deploy\tdeploy_sa_email\t%s\n' "$sa"
  printf 'GCP_FIREBASE_DEPLOY_SA_EMAIL\t016-firebase-deploy-iam\tfirebase_deploy_sa_email\t%s\n' "$sa"
}

_sgw_cnf_dir() { printf '%s\n' "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP"; }

_sgw_envs() {
  if [[ -n "${GH_WIRE_ENVS:-}" ]]; then tr -s ' ' '\n' <<<"$GH_WIRE_ENVS" | sed '/^$/d'; return 0; fi
  local f
  for f in "$(_sgw_cnf_dir)"/*/tf/017-github-wif-deploy.backend-config.tfvars; do
    [[ -f "$f" ]] && basename "$(dirname "$(dirname "$f")")"
  done
  return 0
}

_sgw_repo() {
  if [[ -n "${GH_WIRE_REPO:-}" ]]; then printf '%s\n' "$GH_WIRE_REPO"; return 0; fi
  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

# <tfvars> <key> - the value of a `key = "value"` line of a rendered backend config
_sgw_tfvar() { sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$1" | awk 'NR==1'; }

# <env> <out-file> - one NAME VALUE STEP OUTPUT REGEX line per wired variable
# of <env>, separated by $'\x1f' (a tab is IFS whitespace: `read` would
# collapse an empty VALUE, i.e. an output that is absent). Runs in a
# subshell: the env's SA is activated in a private gcloud config that the
# subshell's EXIT removes, and no ENV / project leaks to the next env.
_sgw_read_env() {
  local env="$1" out="$2"
  (
    export ENV="$env"
    unset PROJ_ID SPL_PROJECT GCP_PROJECT
    do_gcp_pin_account || exit 1
    local prefix step output re bcfg bucket sprefix state_json="" last_step="" val
    while IFS=$'\t' read -r prefix step output re; do
      if [[ "$step" != "$last_step" ]]; then
        last_step="$step"; state_json=""
        bcfg="$(_sgw_cnf_dir)/$env/tf/$step.backend-config.tfvars"
        if [[ ! -f "$bcfg" ]]; then
          do_log "ERROR $env: no $bcfg; render it: ENV=$env ./run -a do_tpl_gen" >&2
        else
          bucket="$(_sgw_tfvar "$bcfg" bucket)"; sprefix="$(_sgw_tfvar "$bcfg" prefix)"
          state_json="$(gcloud storage cat --account="${GCP_ACCOUNT}" "gs://$bucket/$sprefix/default.tfstate" 2>/dev/null \
            | jq -c '.outputs // {} | map_values(.value)' 2>/dev/null)" \
            || { state_json=""; do_log "ERROR $env: cannot read the state of step $step (gs://$bucket/$sprefix) as $GCP_ACCOUNT" >&2; }
        fi
      fi
      val=""
      [[ -n "$state_json" ]] && val="$(jq -r --arg o "$output" '.[$o] // "" | strings' <<<"$state_json")"
      printf '%s_%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$prefix" "${env^^}" "$val" "$step" "$output" "$re"
    done < <(_sgw_map) >"$out"
  )
}

# the current value, empty when the variable does not exist (gh prints the
# 404 body on stdout, so the value counts only when gh exits 0)
_sgw_get() {  # <repo> <name>
  local v; v="$(gh api "repos/$1/actions/variables/$2" --jq .value 2>/dev/null)" && printf '%s\n' "$v"
  return 0
}

# <repo> <env> <name> <want> <step> <output> <regex> <dry> - 0 = in place (or would be set)
_sgw_apply() {
  local repo="$1" env="$2" name="$3" want="$4" step="$5" output="$6" re="$7" dry="$8" have
  if [[ -z "$want" ]]; then
    do_log "ERROR $name: step $step has no output $output in $env; apply it first: ENV=$env STEP=$step make do-tf-plan, then make do-provision (owner go)"
    return 1
  fi
  [[ "$want" =~ $re ]] || { do_log "ERROR $name: step $step output $output in $env is malformed: $want"; return 1; }
  have="$(_sgw_get "$repo" "$name")"
  if [[ "$have" == "$want" ]]; then do_log "OK $repo $name unchanged: $want"; return 0; fi
  if [[ "$dry" != 0 ]]; then
    if [[ -z "$have" ]]; then do_log "INFO DRY_RUN $repo $name would create: $want"
    else do_log "INFO DRY_RUN $repo $name would update: $have -> $want"; fi
    return 0
  fi
  gh variable set "$name" --repo "$repo" --body "$want" >/dev/null \
    || { do_log "ERROR cannot set $repo $name"; return 1; }
  have="$(_sgw_get "$repo" "$name")"
  [[ "$have" == "$want" ]] || { do_log "ERROR $repo $name reads back '$have', want '$want'"; return 1; }
  do_log "OK $repo $name set: $want"
}

do_spl_gh_wire() {
  local tool
  for tool in gh jq gcloud; do
    command -v "$tool" >/dev/null 2>&1 || { do_log "FATAL $tool not found"; return 1; }
  done
  local repo re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' dry="${DRY_RUN:-1}" bad=0 n=0 env envs=() tmp
  # ORG / APP from the project dir's own name: right in an agent worktree too
  do_resolve_oap ORG && do_resolve_oap APP || return 1
  repo="$(_sgw_repo)"
  [[ "$repo" =~ $re ]] || { do_log "FATAL no <owner>/<repo>: set GH_WIRE_REPO (no default); origin gave '$repo'"; return 1; }
  mapfile -t envs < <(_sgw_envs)
  ((${#envs[@]})) || { do_log "FATAL no env: no $(_sgw_cnf_dir)/<env>/tf/017-github-wif-deploy.backend-config.tfvars; render one or set GH_WIRE_ENVS"; return 1; }
  gh api "repos/$repo" --jq .full_name >/dev/null || { do_log "FATAL cannot read $repo with gh"; return 1; }
  tmp="$(mktemp -d)" || return 1
  local name want step output vre
  for env in "${envs[@]}"; do
    [[ "$env" =~ ^[a-z][a-z0-9]*$ ]] || { do_log "ERROR not an env name: '$env'"; bad=1; continue; }
    _sgw_read_env "$env" "$tmp/$env" || { do_log "ERROR $env: no identity to read its state with"; bad=1; continue; }
    while IFS=$'\x1f' read -r name want step output vre; do
      n=$((n + 1))
      _sgw_apply "$repo" "$env" "$name" "$want" "$step" "$output" "$vre" "$dry" || bad=1
    done <"$tmp/$env"
  done
  rm -rf "$tmp"
  if ((bad)); then do_log "ERROR not every variable is wired; fix the lines above and re-run"; return 1; fi
  if [[ "$dry" != 0 ]]; then
    do_log "OK DRY_RUN $n variables resolved for ${envs[*]}; nothing written. Re-run with DRY_RUN=0 to set what differs."
  else
    do_log "OK $n variables wired on $repo for ${envs[*]}: gh variable list --repo $repo"
  fi
  return 0
}
