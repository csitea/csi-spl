#!/bin/bash
#------------------------------------------------------------------------------
# @description Snapshot every Cloud DNS managed zone (and each zone's
# @description record-sets) to JSON, per cloud env, for backup / drift review.
# @description
# @description Morph of pas-psf-orc / csi-rel-orc do_export_all_dns_settings
# @description (spec 033). The donor pinned identity by writing the shared
# @description gcloud config and a JSON key on disk — both are forbidden here.
# @description Every gcloud call passes --account and --project. Projects come
# @description from cnf (do_spl_cloud_cnf), never a baked list.
# @description
# @description DRY_RUN=1 (default): print the files a real run would write,
# @description touch no cloud. DRY_RUN=0: prove GCP_ACCOUNT is live, then
# @description write <project>_dns_zones.json and
# @description <project>_<zone>_dns_records.json under the env's cloud state
# @description dir (or DNS_EXPORT_DIR).
# @param ENV (optional) - dev or prd; unset = both
# @param GCP_ACCOUNT (optional) - overrides cnf env.gcp.gcp_account_owner_email (do_gcp_account)
# @param DRY_RUN (optional) - 1 (default): print only. 0: list and write JSON
# @param DNS_EXPORT_DIR (optional) - override the output directory
# @example ENV=dev ./run -a do_export_all_dns_settings
# @example ENV=dev DRY_RUN=0 ./run -a do_export_all_dns_settings
# @arg --env ENV
# @arg --gcp-account GCP_ACCOUNT
# @arg --dns-export-dir DNS_EXPORT_DIR
#------------------------------------------------------------------------------
do_export_all_dns_settings() {
  local dry=1 rc=0
  if declare -f spl_dry_run >/dev/null; then
    if spl_dry_run; then
      dry=1
    else
      rc=$?
      [[ $rc -eq 1 ]] || return "$rc"
      dry=0
    fi
  fi

  local envs=()
  if [[ -n "${ENV:-}" ]]; then
    envs=("$ENV")
  else
    envs=(dev prd)
  fi

  local env project outdir zones_file zone rec_file managed_zones live_checked=0
  local saved_env="${ENV:-}"
  for env in "${envs[@]}"; do
    ENV="$env"
    if ! declare -f do_spl_cloud_cnf >/dev/null; then
      do_log "FATAL do_spl_cloud_cnf is not loaded; run via ./run"
      ENV="$saved_env"
      return 1
    fi
    do_spl_cloud_cnf || { ENV="$saved_env"; return 1; }
    project="$SPL_PROJECT"
    outdir="${DNS_EXPORT_DIR:-$SPL_STATE_DIR}"
    mkdir -p "$outdir" || { ENV="$saved_env"; return 1; }
    zones_file="$outdir/${project}_dns_zones.json"

    if (( dry )); then
      do_log "INFO DRY_RUN would: gcloud dns managed-zones list --format=json --account=\$GCP_ACCOUNT --project=$project > $zones_file"
      do_log "INFO DRY_RUN would then list record-sets per zone into $outdir/${project}_<zone>_dns_records.json"
      continue
    fi

    if (( ! live_checked )); then
      do_require_bin gcloud yq || { ENV="$saved_env"; return $?; }
      # resolved ONCE for every env of this run; every gcloud call carries --account
      do_gcp_pin_account "$SPL_CNF" || { ENV="$saved_env"; return 1; }
      if declare -f do_gcp_require_live_account >/dev/null; then
        do_gcp_require_live_account "$GCP_ACCOUNT" || { ENV="$saved_env"; return 1; }
      fi
      live_checked=1
    fi

    do_log "INFO exporting DNS settings for project $project (account=$GCP_ACCOUNT) -> $zones_file"
    gcloud dns managed-zones list --format=json --account="$GCP_ACCOUNT" --project="$project" >"$zones_file" || {
      do_log "FATAL gcloud dns managed-zones list failed for $project"
      ENV="$saved_env"
      return 1
    }

    managed_zones=$(yq -r '.[].name // ""' "$zones_file" 2>/dev/null || true)
    for zone in $managed_zones; do
      [[ -n "$zone" ]] || continue
      rec_file="$outdir/${project}_${zone}_dns_records.json"
      do_log "INFO exporting DNS records for zone $zone in $project -> $rec_file"
      gcloud dns record-sets list --zone="$zone" --format=json --account="$GCP_ACCOUNT" --project="$project" >"$rec_file" || {
        do_log "FATAL gcloud dns record-sets list failed for zone $zone in $project"
        ENV="$saved_env"
        return 1
      }
    done
  done
  ENV="$saved_env"

  if (( dry )); then
    do_log "OK DRY_RUN DNS export complete: nothing was listed. Re-run with DRY_RUN=0 to write JSON."
  else
    do_log "OK DNS settings export completed"
  fi
}
