#!/bin/bash
# The off-project backups (iac 046, spec 044 contingency T077): shared by
# do_spl_backup_offsite (the env copies IN, write-only) and the restores
# (do_spl_db_restore, do_spl_files_restore: they read OUT as csi-spl-bkp).

# spl_offsite_cnf -> SPL_OFFSITE_BUCKET, SPL_OFFSITE_ENABLED (true|false) and
# SPL_BKP_PROJECT from the effective cnf (steps."046-gcs-offsite-backups").
# Needs do_spl_cloud_cnf first.
spl_offsite_cnf() {
  local -a v=()
  mapfile -t v < <(yq -r '.env.steps."046-gcs-offsite-backups" | [.offsite_bucket_name, .copy_enabled, .tf_key_project] | .[] | (. // "")' "$SPL_CNF" 2>/dev/null)
  [[ ${#v[@]} -eq 3 && -n "${v[0]}" && "${v[0]}" != null && -n "${v[2]}" ]] ||
    { do_log "FATAL cnf env.steps.\"046-gcs-offsite-backups\" (offsite_bucket_name, tf_key_project) is missing for $ENV"; return 1; }
  SPL_OFFSITE_BUCKET="${v[0]}"
  SPL_OFFSITE_ENABLED="${v[1]:-false}"
  SPL_BKP_PROJECT="${v[2]}"
  export SPL_OFFSITE_BUCKET SPL_OFFSITE_ENABLED SPL_BKP_PROJECT
}

# spl_bkp_gcloud <gcloud args...> -> gcloud as the csi-spl-bkp project SA, from
# its key ~/.gcp/.<org>/key-<bkp project>.json, in a throwaway CLOUDSDK_CONFIG:
# nothing is activated and the shared gcloud config is never written. This is
# the ONE identity that can read the off-project copies back; the env SAs
# cannot (they may only add). Never the owner account.
spl_bkp_gcloud() {
  local key account cfg rc=0
  key="$(spl_bkp_key)" || return 1
  account="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["client_email"])' "$key" 2>/dev/null)" ||
    { do_log "FATAL $key carries no client_email"; return 1; }
  cfg="$(umask 077 && mktemp -d)" || return 1
  CLOUDSDK_CONFIG="$cfg" CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$key" \
    gcloud "$@" --account="$account" || rc=$?
  rm -rf "$cfg"
  return $rc
}

# spl_bkp_key -> the csi-spl-bkp SA key path, or a refusal that names the
# bootstrap which mints it. Call it before any bkp read: a missing key would
# otherwise surface as "no object found".
spl_bkp_key() {
  local key="${SPL_BKP_KEY_FILE:-$HOME/.gcp/.${SPL_BKP_PROJECT%%-*}/key-$SPL_BKP_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no key for $SPL_BKP_PROJECT at $key (the owner's ENV=bkp do_gcp_000_bootstrap_gcp_env mints it)" >&2; return 1; }
  printf '%s' "$key"
}

# spl_gs_names <gs://prefix> [bkp] -> the object names under the prefix,
# relative to it, sorted; as the env SA, or as the bkp SA when $2 is bkp.
spl_gs_names() {
  local p="${1%/}" out
  if [[ "${2:-}" == bkp ]]; then
    out="$(spl_bkp_gcloud storage ls "$p/**" 2>/dev/null)"
  else
    out="$(gcloud storage ls "$p/**" --account="$GCP_ACCOUNT" 2>/dev/null)"
  fi
  [[ -n "$out" ]] || return 0
  sed -n "s|^$p/||p" <<<"$out" | grep -v '/$' | sort -u
}
