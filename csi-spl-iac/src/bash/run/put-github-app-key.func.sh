#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Put the Docs GitHub App private key into this env's Secret
# @description Manager slot: the named action of spec 075 repo-edit §9 / T04.
# @description The slot is cnf env.docs.repo_edit.secret_env.SPOOL_GITHUB_APP_KEY
# @description (GH_APP_SECRET overrides). KEY_FILE must be a PEM private key, or
# @description it is refused before any gcloud call; its contents are never
# @description printed (gcloud reads the file). The put itself is
# @description do_spl_gh_app_key_put: the env's project SA, a private gcloud
# @description config, a version only when the sha256 differs, verified after.
# @description SHRED=1 (the prd call, after dev holds the key) shreds KEY_FILE
# @description once the version is in; refused on any other env.
# @description DRY_RUN=1 (default): names the secret, compares, changes nothing.
# @param ENV - required: dev or prd
# @param KEY_FILE - required: the App's .pem, as downloaded from GitHub
# @param SHRED (optional) - 0 (default) or 1; 1 only with ENV=prd
# @param GH_APP_SECRET (optional) - overrides the cnf slot id
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev KEY_FILE=$HOME/Downloads/<app-slug>.private-key.pem ./run -a do_put_github_app_key
# @example ENV=prd KEY_FILE=$HOME/Downloads/<app-slug>.private-key.pem SHRED=1 DRY_RUN=0 ./run -a do_put_github_app_key
#------------------------------------------------------------------------------
do_put_github_app_key() {
  local dry="${DRY_RUN:-1}" shred_it="${SHRED:-0}" key="${KEY_FILE:-}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$shred_it" == 0 || "$shred_it" == 1 ]] || { do_log "FATAL SHRED must be 0 or 1, got: $shred_it"; return 2; }
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 2; }
  [[ "$shred_it" == 0 || "$ENV" == prd ]] ||
    { do_log "FATAL SHRED=1 is the prd call only: the file must survive until prd holds the key"; return 2; }
  [[ -n "$key" && -f "$key" && -s "$key" ]] || { do_log "FATAL KEY_FILE must name a non-empty key file"; return 2; }
  _put_github_app_key_is_pem "$key" ||
    { do_log "FATAL KEY_FILE $key is not a PEM private key (contents not shown)"; return 2; }

  local sec="${GH_APP_SECRET:-}"
  if [[ -z "$sec" ]]; then
    local cnf_dir
    cnf_dir="$(mktemp -d)"
    do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf_dir/cnf.yaml" &&
      sec="$(yq -r '.env.docs.repo_edit.secret_env.SPOOL_GITHUB_APP_KEY // ""' "$cnf_dir/cnf.yaml")"
    rm -rf "$cnf_dir"
    [[ -n "$sec" ]] || { do_log "FATAL the $ENV cnf has no env.docs.repo_edit.secret_env.SPOOL_GITHUB_APP_KEY"; return 1; }
  fi
  do_log "INFO $ENV: GitHub App key -> secret $sec (KEY_FILE is a PEM private key; contents not shown)"

  # a subshell: the put exports GCP_ACCOUNT, which must not outlive its config
  ( GH_APP_SECRET="$sec" DRY_RUN="$dry" do_spl_gh_app_key_put ) || return $?

  [[ "$shred_it" == 1 ]] || return 0
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would shred $key once the prd version is in"
    return 0
  fi
  shred -u "$key" 2>/dev/null || rm -f "$key"
  [[ ! -e "$key" ]] || { do_log "ERROR could not remove $key: remove it by hand"; return 1; }
  do_log "OK shredded $key (prd holds the key)"
}

# A PEM private key: a BEGIN line, base64 body, the matching END line. The file
# is only matched, never printed.
_put_github_app_key_is_pem() {
  local f="$1" kind
  kind="$(grep -m1 -oE '^-----BEGIN (RSA |EC )?PRIVATE KEY-----$' "$f" 2>/dev/null)" || return 1
  kind="${kind#-----BEGIN }"; kind="${kind%-----}"
  grep -qxF -- "-----END $kind-----" "$f" || return 1
  ! grep -vqE '^(-----(BEGIN|END) [A-Z ]+-----|[A-Za-z0-9+/=]*)$' "$f"
}
