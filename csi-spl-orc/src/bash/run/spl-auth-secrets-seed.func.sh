#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed the auth secret VERSIONS that 030's slots need before
# @description SPOOL_HUB_AUTH_PROVIDERS lists a provider (spec 010 T032). The
# @description slots themselves are terraform (030); a version is never tf.
# @description   - session key (cnf auth.social.secret_env.SPOOL_HUB_AUTH_SESSION_KEY):
# @description     48 random bytes, base64, minted ONLY when the secret has no
# @description     version yet. Never rotated here: a new key logs everyone out.
# @description   - Google client secret (...GOOGLE_CLIENT_SECRET): read from the
# @description     owner's OAuth client file $HOME/.gcp/.<org>/.<app>/
# @description     client_secret_<project-number>-*.json (exactly one match;
# @description     web.project_id must be this env's project and web.client_id
# @description     must equal cnf SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID). Added only
# @description     when it differs from the latest version (compared by sha256).
# @description Values travel on stdin only: never argv, never a log, never stdout.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (cnf owner email otherwise)
# @param DRY_RUN (optional) - 1 (default): report only. 0: add the versions.
# @example ENV=dev GCP_ACCOUNT=<project-sa-email> DRY_RUN=0 ./run -a do_spl_auth_secrets_seed
#------------------------------------------------------------------------------
do_spl_auth_secrets_seed() {
  do_require_bin yq python3 sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local org="${SPL_ORG_APP%%-*}" app="${SPL_ORG_APP#*-}"
  local sk gs cid
  sk="$(yq -r '.env.auth.social.secret_env.SPOOL_HUB_AUTH_SESSION_KEY // ""' "$SPL_CNF")"
  gs="$(yq -r '.env.auth.social.secret_env.SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET // ""' "$SPL_CNF")"
  cid="$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID // ""' "$SPL_CNF")"
  [[ -n "$sk" && -n "$gs" ]] || { do_log "FATAL cnf auth.social.secret_env lacks the session-key or google secret slot name"; return 1; }
  [[ -n "$cid" && "$cid" != PLACEHOLDER-* ]] || { do_log "FATAL cnf SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID is unset or a placeholder for $ENV"; return 1; }

  # --- the owner's client file, by project number --------------------------
  local num
  num="$(gcloud projects describe "$SPL_PROJECT" --account="$GCP_ACCOUNT" --format='value(projectNumber)' 2>/dev/null)"
  [[ "$num" =~ ^[0-9]+$ ]] || { do_log "FATAL cannot read the project number of $SPL_PROJECT as $GCP_ACCOUNT"; return 1; }
  local dir="$HOME/.gcp/.$org/.$app" files=()
  shopt -s nullglob; files=("$dir"/client_secret_"$num"-*.json); shopt -u nullglob
  (( ${#files[@]} == 1 )) || { do_log "FATAL expected exactly one $dir/client_secret_$num-*.json, found ${#files[@]}"; return 1; }
  local f="${files[0]}" check
  check="$(python3 - "$f" "$SPL_PROJECT" "$cid" <<'PY'
import json, sys
w = json.load(open(sys.argv[1])).get("web", {})
if w.get("project_id") != sys.argv[2]: print(f"project_id is {w.get('project_id')!r}, not {sys.argv[2]}")
elif w.get("client_id") != sys.argv[3]: print("client_id differs from cnf SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID")
elif not w.get("client_secret"): print("no web.client_secret")
PY
)"
  [[ -z "$check" ]] || { do_log "FATAL $f: $check"; return 1; }
  do_log "INFO google client file for $SPL_PROJECT (#$num): $(basename "$f") (client_id matches cnf)"

  _seed_latest_sha() {  # <secret> -> sha256 of the latest version, empty when none
    gcloud secrets versions access latest --secret="$1" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1
  }
  local empty_sha rc=0
  empty_sha="$(printf '' | sha256sum | cut -d' ' -f1)"

  # --- session key: only when absent ----------------------------------------
  if [[ "$(_seed_latest_sha "$sk")" != "$empty_sha" ]]; then
    do_log "INFO $sk already has a version: kept (never rotated here)"
  elif (( dry )); then
    do_log "INFO DRY_RUN would add a version to $sk (48 random bytes, base64)"
  else
    head -c 48 /dev/urandom | base64 -w0 |
      gcloud secrets versions add "$sk" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1 ||
      { do_log "ERROR could not add a version to $sk"; rc=1; }
    (( rc )) || do_log "INFO $sk: version added (value not logged)"
  fi

  # --- google client secret: when it differs ---------------------------------
  local want
  want="$(python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["web"]["client_secret"])' "$f" | sha256sum | cut -d' ' -f1)"
  if [[ "$(_seed_latest_sha "$gs")" == "$want" ]]; then
    do_log "INFO $gs already holds this client's secret: nothing to add"
  elif (( dry )); then
    do_log "INFO DRY_RUN would add a version to $gs from $(basename "$f")"
  else
    python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["web"]["client_secret"])' "$f" |
      gcloud secrets versions add "$gs" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1 ||
      { do_log "ERROR could not add a version to $gs"; rc=1; }
    [[ "$(_seed_latest_sha "$gs")" == "$want" ]] && do_log "INFO $gs: version added and verified by sha256 (value not logged)" ||
      { do_log "ERROR $gs latest version does not match the client file"; rc=1; }
  fi
  unset -f _seed_latest_sha
  (( rc == 0 )) || return 1
  (( dry )) && do_log "OK DRY_RUN for $SPL_PROJECT: nothing added. Re-run with DRY_RUN=0." || do_log "OK auth secrets seeded in $SPL_PROJECT"
}
