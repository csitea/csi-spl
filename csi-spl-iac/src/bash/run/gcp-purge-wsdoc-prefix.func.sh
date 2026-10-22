#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description PURGE every workspace doc under one path prefix from one
# @description workspace's docs bucket (iac step 052, spec 075): the docs
# @description under <prefix> AND their edit history under .history/<prefix>,
# @description every generation, the noncurrent ones included. A hub DELETE
# @description (spool doc-delete) does not remove a doc's content: it first
# @description writes a .history/ copy, every earlier PUT left one, and the
# @description bucket is versioned, so the old generations stay. This action
# @description is the one way to make a private doc leave the hub's bucket.
# @description The bucket is cnf: steps.052-gcs-workspace-docs.bucket_prefix +
# @description TENANT_ID, and TENANT_ID must be one of that step's workspaces.
# @description It runs as the env's project service account (do_gcp_pin_account,
# @description --account on every call) in a throwaway gcloud config.
# @description DRY_RUN=1 (the default) lists only: one `would delete
# @description <object>#<generation>` line per object generation, then the
# @description counts (docs, history objects, generations). DRY_RUN=0 deletes
# @description those generations and lists again; any left is a FATAL.
# @description Soft-deleted objects (052 keeps them soft_delete_retention_seconds)
# @description are counted and reported, never touched: they are not readable
# @description through the hub and expire on their own.
# @description Object names (paths) are printed, never an object's content.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace slug, one of 052's workspaces
# @param WSDOC_PREFIX - required: a relative doc prefix ending in /, e.g. <prefix>/
# @param DRY_RUN (optional) - 1 (default): list and count. 0: delete.
# @example ENV=prd TENANT_ID=t1 WSDOC_PREFIX='<prefix>/' ./run -a do_gcp_purge_wsdoc_prefix
# @example ENV=prd TENANT_ID=t1 WSDOC_PREFIX='<prefix>/' DRY_RUN=0 ./run -a do_gcp_purge_wsdoc_prefix
#------------------------------------------------------------------------------
do_gcp_purge_wsdoc_prefix() {
  local dry_run="${DRY_RUN:-1}" tenant="${TENANT_ID:-}" prefix="${WSDOC_PREFIX:-}"
  local seg='[A-Za-z0-9_-][A-Za-z0-9._-]*'
  [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry_run'"; return 1; }
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { do_log "FATAL TENANT_ID must be a workspace slug, got: '$tenant'"; return 1; }
  [[ "$prefix" =~ ^($seg/)+$ ]] ||
    { do_log "FATAL WSDOC_PREFIX must be a relative doc prefix ending in / (segments of [A-Za-z0-9._-], none starting with a dot), got: '$prefix'"; return 1; }
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  do_require_bin yq || return 1

  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_gcp_spl_proj_id || return 1
  local cnf="$_spl_sdk_dir/cnf.yaml" bprefix
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  bprefix="$(yq -r '.env.steps."052-gcs-workspace-docs".bucket_prefix // ""' "$cnf")"
  [[ -n "$bprefix" && "$bprefix" != null ]] ||
    { do_log "FATAL ENV=$ENV has no steps.052-gcs-workspace-docs.bucket_prefix: no workspace docs buckets"; return 1; }
  T="$tenant" yq -e '.env.steps."052-gcs-workspace-docs".workspaces[] | select(. == strenv(T))' "$cnf" >/dev/null 2>&1 ||
    { do_log "FATAL TENANT_ID=$tenant is not one of ENV=$ENV's 052 workspaces: no such docs bucket"; return 1; }
  local bucket="gs://$bprefix$tenant"

  do_gcp_pin_account || return 1
  local acct="--account=$GCP_ACCOUNT"
  do_log "INFO PROJ_ID=$PROJ_ID bucket=$bucket prefix=$prefix GCP_ACCOUNT=$GCP_ACCOUNT DRY_RUN=$dry_run"

  local list="$_spl_sdk_dir/objects.tsv"
  _gcp_purge_wsdoc_list "$bucket" "$prefix" "$acct" >"$list" || return 1
  _gcp_purge_wsdoc_count "$list" before
  local soft="unreadable"
  _gcp_purge_wsdoc_list "$bucket" "$prefix" "$acct" --soft-deleted >"$list.soft" 2>/dev/null &&
    soft=$(grep -c . "$list.soft")
  do_log "INFO soft-deleted generations (not touched, they expire per 052's soft_delete_retention_seconds): $soft"

  local name gen
  if [[ "$dry_run" == 1 ]]; then
    while IFS=$'\t' read -r name gen; do
      do_log "INFO DRY_RUN would delete $name#$gen"
    done <"$list"
    do_log "OK DRY_RUN nothing was deleted. Re-run with DRY_RUN=0 to delete."
    return 0
  fi

  local urls=()
  while IFS=$'\t' read -r name gen; do urls+=("$bucket/$name#$gen"); done <"$list"
  local i
  for ((i = 0; i < ${#urls[@]}; i += 100)); do
    gcloud storage rm "${urls[@]:i:100}" --project="$PROJ_ID" "$acct" --quiet ||
      { do_log "FATAL gcloud storage rm failed under $bucket"; return 1; }
  done
  _gcp_purge_wsdoc_list "$bucket" "$prefix" "$acct" >"$list" || return 1
  _gcp_purge_wsdoc_count "$list" after
  [[ ! -s "$list" ]] || { do_log "FATAL $(wc -l <"$list") generation(s) are left under $bucket"; return 1; }
  do_log "OK purged ${#urls[@]} generation(s) under $bucket/$prefix and $bucket/.history/$prefix"
}

# _gcp_purge_wsdoc_list <bucket> <prefix> <--account=..> [--soft-deleted]:
# every generation under <prefix> and .history/<prefix> (gcloud storage ls
# --all-versions prints gs://<bucket>/<name>#<generation>), one
# "name<TAB>gen" per line. 1 with the FATAL (on stderr) when gcloud cannot
# list or a line is not such a URL; no match is an empty listing.
_gcp_purge_wsdoc_list() {
  local bucket="$1" prefix="$2" acct="$3" extra=("${@:4}") p out rc u name gen
  for p in "$prefix" ".history/$prefix"; do
    rc=0
    out=$(gcloud storage ls --all-versions "${extra[@]}" "$bucket/$p**" --project="$PROJ_ID" "$acct" 2>&1) || rc=$?
    if ((rc != 0)); then
      grep -qi 'matched no objects' <<<"$out" && continue
      do_log "FATAL cannot list $bucket/$p (rc=$rc): $out" >&2
      return 1
    fi
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      name="${u#"$bucket/"}" gen="${u##*#}"
      name="${name%#*}"
      [[ "$u" == "$bucket/$p"*"#"* && "$gen" =~ ^[0-9]+$ ]] ||
        { do_log "FATAL not a versioned object URL under $bucket/$p: $u" >&2; return 1; }
      printf '%s\t%s\n' "$name" "$gen"
    done <<<"$out"
  done
  return 0
}

# _gcp_purge_wsdoc_count <list> <label>: the docs (live names under the
# prefix), history objects and generations of a listing, one INFO line.
_gcp_purge_wsdoc_count() {
  local list="$1" label="$2" docs hist gens
  gens=$(grep -c . "$list")
  docs=$(cut -f1 "$list" | grep -v '^\.history/' | sort -u | grep -c .)
  hist=$(cut -f1 "$list" | grep '^\.history/' | sort -u | grep -c .)
  do_log "INFO $label: docs=$docs history_objects=$hist generations=$gens"
}
