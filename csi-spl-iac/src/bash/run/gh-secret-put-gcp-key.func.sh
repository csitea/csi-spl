#!/bin/bash
#------------------------------------------------------------------------------
# @description Put this box's per-env project SA key file into the GitHub
# @description Actions repo secret the workflows read (SPL-2893; the runbook:
# @description secret-rotation.md section 5.1 step 3, the copy to CI):
# @description   1. the key file is the one do_gcp_sa_key_file resolves
# @description      ($HOME/.gcp/.<org>/key-<project>.json); its client_email
# @description      must be the env's project SA, <project>@<project>.iam...
# @description   2. the secret name is derived from the project, never listed:
# @description      GCP_KEY_<PROJECT upper, - as _> (GCP_KEY_CSI_SPL_DEV)
# @description   3. gh secret set <name> --repo <origin repo> reads the key on
# @description      STDIN: never in argv, a log, stdout or a temp file
# @description   4. after the put: the secret's updated_at (gh secret list)
# @description Prints only the secret name, the repo, the key's private_key_id
# @description PREFIX (8 chars) and the client_email DOMAIN; never the key.
# @description gh must already be authenticated for the repo: its error is
# @description reported, never worked around with another token.
# @description Dry run unless DRY_RUN=0 (the dry run makes no gh secret set).
# @param ENV - required: dev or prd
# @param GH_SECRET_REPO (optional) - <owner>/<repo>, default: parsed from the
# @param        checkout's `origin` remote (no literal default)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev ./run -a do_gh_secret_put_gcp_key
# @example ENV=prd DRY_RUN=0 ./run -a do_gh_secret_put_gcp_key
#------------------------------------------------------------------------------
do_gh_secret_put_gcp_key() {
  local dry="${DRY_RUN:-1}"
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '${ENV:-}'"; return 2; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin gh jq || return 1
  do_gcp_spl_proj_id || return 1

  local key email kid name repo err listing
  key="$(do_gcp_sa_key_file)" || { do_log "FATAL no project SA key for $PROJ_ID at \$HOME/.gcp/.<org>/key-$PROJ_ID.json on this box"; return 1; }
  [[ ! -L "$key" && -r "$key" ]] || { do_log "FATAL the key file of $PROJ_ID is a symlink or not readable"; return 1; }
  email="$(do_gcp_sa_key_email "$key")" || { do_log "FATAL no client_email in the key file of $PROJ_ID"; return 1; }
  [[ "$email" == "$PROJ_ID@$PROJ_ID.iam.gserviceaccount.com" ]] ||
    { do_log "FATAL the key file of $PROJ_ID is a key of another SA (@${email#*@}), not the project SA of $ENV: nothing put"; return 1; }
  kid="$(jq -r '.private_key_id // ""' "$key" 2>/dev/null)"
  [[ -n "$kid" ]] || { do_log "FATAL the key file of $PROJ_ID has no private_key_id"; return 1; }
  name="$(gh_secret_put_gcp_key_name "$PROJ_ID")"
  repo="$(gh_secret_put_gcp_key_repo)"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    { do_log "FATAL no GitHub repo: set GH_SECRET_REPO=<owner>/<repo> or run from a checkout whose origin is on github.com (got: '$repo')"; return 1; }

  # the auth check: gh's own error is reported, never another token tried
  listing="$(gh secret list --repo "$repo" --json name,updatedAt 2>&1 </dev/null)" ||
    { do_log "FATAL gh cannot list the secrets of $repo (no gh auth for the repo?): $(tail -n1 <<<"$listing")"; return 1; }

  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN would run: gh secret set $name --repo $repo <key file on stdin> (key id ${kid:0:8}..., client_email @${email#*@}); now updated_at=$(gh_secret_put_gcp_key_updated "$listing" "$name")"
    do_log "OK DRY_RUN nothing was put. Re-run with DRY_RUN=0 to put it."
    return 0
  fi

  err="$(gh secret set "$name" --repo "$repo" <"$key" 2>&1 >/dev/null)" ||
    { do_log "FATAL gh could not set $name on $repo: $(tail -n1 <<<"$err")"; return 1; }
  listing="$(gh secret list --repo "$repo" --json name,updatedAt 2>&1 </dev/null)" ||
    { do_log "FATAL $name was set, but gh cannot list the secrets of $repo: $(tail -n1 <<<"$listing")"; return 1; }
  do_log "OK put key id ${kid:0:8}... (client_email @${email#*@}) into $repo $name, updated_at=$(gh_secret_put_gcp_key_updated "$listing" "$name")"
}

# gh_secret_put_gcp_key_name <project> - the secret the workflows read
gh_secret_put_gcp_key_name() { printf 'GCP_KEY_%s\n' "$(tr 'a-z-' 'A-Z_' <<<"$1")"; }

# the repo: GH_SECRET_REPO, else the origin remote of the checkout
gh_secret_put_gcp_key_repo() {
  if [[ -n "${GH_SECRET_REPO:-}" ]]; then printf '%s\n' "$GH_SECRET_REPO"; return 0; fi
  local url; url="$(git -C "${APP_PATH:-.}" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

# gh_secret_put_gcp_key_updated <gh secret list json> <name> - its updatedAt, or "none"
gh_secret_put_gcp_key_updated() {
  local at; at="$(jq -r --arg n "$2" '.[] | select(.name == $n) | .updatedAt' <<<"$1" 2>/dev/null)"
  printf '%s\n' "${at:-none}"
}
