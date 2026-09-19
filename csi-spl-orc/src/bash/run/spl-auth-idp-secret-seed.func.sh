#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed ONE sign-in provider's client secret into its Secret Manager
# @description slot (spec 019 FR-L4, shared with 018): the slot is
# @description cnf auth.social.secret_env.SPOOL_HUB_AUTH_<IDP>_CLIENT_SECRET,
# @description created empty by 030; a version is never terraform. Donor:
# @description csi-rel do_provision_social_provider_secrets, minus the secret in
# @description an env var and minus slot/IAM creation (030 owns both here).
# @description The owner file is $HOME/.gcp/.<org>/.<app>/<idp>-client-<env>.json,
# @description mode 0600, {"client_id": "...", "client_secret": "..."}; its
# @description client_id must equal cnf SPOOL_HUB_AUTH_<IDP>_CLIENT_ID (public,
# @description committed first). For microsoft a bare GUID is refused: that is
# @description Azure's "Secret ID", not the secret "Value".
# @description Runs as the env's project service account in a throwaway
# @description CLOUDSDK_CONFIG (never the owner account, never the shared
# @description ~/.config/gcloud). A version is added only when it differs from
# @description the latest (sha256) and is re-read to verify. The value travels
# @description on stdin only: never argv, never a log, never stdout.
# @description Google keeps do_spl_auth_secrets_seed (its client file + the
# @description session key); this action never mints the session key.
# @description Dry run unless DRY_RUN=0.
# @param IDP - required: facebook | microsoft | linkedin | xai
# @param ENV - required: dev or prd
# @param SPL_SA_KEY (optional) - default $HOME/.gcp/.<org>/key-<project>.json
# @param DRY_RUN (optional) - 1 (default): report only. 0: add the version.
# @example IDP=linkedin ENV=dev ./run -a do_spl_auth_idp_secret_seed
# @example IDP=linkedin ENV=dev DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed
#------------------------------------------------------------------------------
do_spl_auth_idp_secret_seed() {
  do_require_bin gcloud yq python3 sha256sum || return 1
  local idp="${IDP:-}"
  case "$idp" in
    facebook|microsoft|linkedin|xai) ;;
    *) do_log "FATAL IDP must be facebook, microsoft, linkedin or xai (google: do_spl_auth_secrets_seed), got: '$idp'"; return 1 ;;
  esac
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local org="${SPL_ORG_APP%%-*}" app="${SPL_ORG_APP#*-}" up="${idp^^}"
  local slot cid
  slot="$(yq -r ".env.auth.social.secret_env.SPOOL_HUB_AUTH_${up}_CLIENT_SECRET // \"\"" "$SPL_CNF")"
  cid="$(yq -r ".env.auth.social.env.SPOOL_HUB_AUTH_${up}_CLIENT_ID // \"\"" "$SPL_CNF")"
  [[ -n "$slot" && "$slot" != null ]] || { do_log "FATAL cnf auth.social.secret_env has no SPOOL_HUB_AUTH_${up}_CLIENT_SECRET slot"; return 1; }

  local f="$HOME/.gcp/.$org/.$app/$idp-client-$ENV.json"
  [[ -s "$f" ]] || { do_log "FATAL no owner file $f (0600, {\"client_id\":…,\"client_secret\":…}; spec 019 §4)"; return 1; }
  [[ "$(stat -c %a "$f")" == 600 ]] || { do_log "FATAL $f must be mode 0600"; return 1; }
  local fid
  fid="$(python3 - "$f" "$idp" <<'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = None
if not isinstance(d, dict): print("ERR not a JSON object"); sys.exit()
cid, sec = d.get("client_id"), d.get("client_secret")
if not isinstance(cid, str) or not cid.strip(): print("ERR no client_id")
elif not isinstance(sec, str) or not sec.strip(): print("ERR no client_secret")
elif sec != sec.strip(): print("ERR client_secret has leading/trailing whitespace")
elif sys.argv[2] == "microsoft" and re.fullmatch(r"[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}", sec):
    print("ERR client_secret is a bare GUID: that is the Azure Secret ID, paste the secret Value")
else: print("ID " + cid.strip())
PY
)"
  [[ "$fid" == "ID "* ]] || { do_log "FATAL $f: ${fid#ERR }"; return 1; }
  fid="${fid#ID }"
  if [[ -z "$cid" || "$cid" == null || "$cid" == PLACEHOLDER-* ]]; then
    do_log "FATAL cnf SPOOL_HUB_AUTH_${up}_CLIENT_ID is unset or a placeholder for $ENV: commit '$fid' (the public client id from $(basename "$f")) to $SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV.env.yaml first"
    return 1
  fi
  [[ "$fid" == "$cid" ]] || { do_log "FATAL $f client_id '$fid' differs from cnf SPOOL_HUB_AUTH_${up}_CLIENT_ID '$cid'"; return 1; }

  local key="${SPL_SA_KEY:-$HOME/.gcp/.$org/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }
  local cfg rc=0
  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 1; }
    GCP_ACCOUNT="$(do_gcp_isolated_active_account)" || exit 1
    do_gcp_log_identity "$SPL_PROJECT" "$GCP_ACCOUNT" do_spl_auth_idp_secret_seed

    _idp_secret() { python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1]))["client_secret"])' "$f"; }
    _idp_latest_sha() {
      gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null |
        sha256sum | cut -d' ' -f1
    }
    local want
    want="$(_idp_secret | sha256sum | cut -d' ' -f1)"
    if [[ "$(_idp_latest_sha)" == "$want" ]]; then
      do_log "OK $slot already holds the $idp client secret of $(basename "$f"): nothing to add"
      exit 0
    fi
    if (( dry )); then
      do_log "OK DRY_RUN would add a version to $slot in $SPL_PROJECT from $(basename "$f") (client_id matches cnf). Re-run with DRY_RUN=0."
      exit 0
    fi
    _idp_secret | gcloud secrets versions add "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1 ||
      { do_log "FATAL could not add a version to $slot as $GCP_ACCOUNT"; exit 1; }
    [[ "$(_idp_latest_sha)" == "$want" ]] ||
      { do_log "FATAL $slot latest version does not match $(basename "$f") after the add"; exit 1; }
    do_log "OK $slot: version added and verified by sha256 in $SPL_PROJECT (value not logged). Next: list $idp in SPOOL_HUB_AUTH_PROVIDERS for $ENV."
  ) || rc=$?
  rm -rf "$cfg"
  return $rc
}
