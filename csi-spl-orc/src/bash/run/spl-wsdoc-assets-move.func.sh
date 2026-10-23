#!/bin/bash
#------------------------------------------------------------------------------
# @description COPY every workspace Qto picture from the shared files bucket
# @description (step 050, t/<tenant>/files/<sha256>) to that workspace's own
# @description docs bucket (step 052, <bucket_prefix><tenant>/qto-assets/<sha256>):
# @description spec 114 section 9.3, tasks R4. The references are the
# @description sha256 values of every workspace doc root's attrs.assets (the
# @description same read as do_gcp_audit_wsdoc_buckets, R1), tenant `system`
# @description excluded: it has no 052 bucket.
# @description Per reference it downloads the 050 object, checks its sha256
# @description against its name, uploads it (--if-generation-match=0: never
# @description over another object), then downloads the 052 copy and checks
# @description THAT sha256: only a copy whose bytes hash to its name is
# @description counted moved. One line per reference, then a summary:
# @description   moved       copied and the copy's sha256 verified
# @description   already     the 052 copy was there and its sha256 verified
# @description   would-copy  DRY_RUN=1: the 050 object verified, not copied
# @description   FAIL        bad-ref, no-bucket, src-missing, src-differs,
# @description               dst-differs, copy-differs, or a gcloud error;
# @description               exit 1 on any
# @description Never deletes from 050: the file retention sweep keeps the 050
# @description blob while a doc or a message names it (spec 114 9.3).
# @description Prints tenant slugs, sha256 values and counts only, never a
# @description picture's bytes or a doc's text; the downloads sit in a private
# @description temp dir removed on return. gcloud runs as the env's project
# @description service account (do_gcp_pin_account), --account on every call.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default) verify and report only; 0 copy
# @example ENV=prd ./run -a do_spl_wsdoc_assets_move
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_wsdoc_assets_move
#------------------------------------------------------------------------------
do_spl_wsdoc_assets_move() {
  local dry=1
  spl_require_cloud_env || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_require_bin gcloud yq sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local files bprefix refs
  files="$(yq -r '.env.steps."050-gcs-files".files_bucket_name // ""' "$SPL_CNF")"
  bprefix="$(yq -r '.env.steps."052-gcs-workspace-docs".bucket_prefix // ""' "$SPL_CNF")"
  [[ -n "$files" && "$files" != null ]] || { do_log "FATAL cnf steps.050-gcs-files.files_bucket_name is empty for $ENV"; return 1; }
  [[ -n "$bprefix" && "$bprefix" != null ]] || { do_log "FATAL cnf steps.052-gcs-workspace-docs.bucket_prefix is empty for $ENV: no workspace docs buckets"; return 1; }
  refs="$(_spl_wsdoc_assets_refs)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local work
  work="$(mktemp -d)" || return 1
  chmod 700 "$work"
  trap 'rm -rf "$work"; trap - RETURN' RETURN
  do_log "INFO ENV=$ENV files=gs://$files bucket_prefix=$bprefix GCP_ACCOUNT=$GCP_ACCOUNT refs=$(grep -c . <<<"$refs") dry_run=$dry"

  local t sha last="" bucket_ok=0 v moved=0 already=0 would=0 failed=0
  while read -r t sha; do
    [[ -n "$t" ]] || continue
    if [[ "$t" != "$last" ]]; then
      last="$t" bucket_ok=0
      gcloud storage buckets describe "gs://$bprefix$t" --account="$GCP_ACCOUNT" --format='value(name)' >/dev/null 2>&1 && bucket_ok=1
    fi
    if [[ ! "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ || ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
      v="FAIL bad-ref"
    elif ((bucket_ok == 0)); then
      v="FAIL no-bucket gs://$bprefix$t"
    else
      v="$(_spl_wsdoc_assets_move_one "gs://$files/t/$t/files/$sha" "gs://$bprefix$t/qto-assets/$sha" "$sha" "$work" "$dry")"
    fi
    do_log "${v%% *} $ENV $t $sha${v#"${v%% *}"}"
    case "$v" in
      moved) moved=$((moved + 1)) ;;
      already) already=$((already + 1)) ;;
      would-copy) would=$((would + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done <<<"$refs"

  local sum nrefs
  nrefs="$(grep -c . <<<"$refs")"
  sum="refs=$nrefs moved=$moved already=$already would_copy=$would failed=$failed"
  ((failed == 0)) || { do_log "FATAL ENV=$ENV wsdoc assets: $sum"; return 1; }
  ((dry == 0)) || { do_log "OK DRY RUN ENV=$ENV wsdoc assets: $sum; nothing copied, DRY_RUN=0 to copy"; return 0; }
  do_log "OK ENV=$ENV wsdoc assets: $sum; nothing deleted from gs://$files"
}

# _spl_wsdoc_assets_refs -> "<tenant> <sha256>" lines, sorted, of every
# workspace doc root's attrs.assets, through the read-only do_spl_db_query.
_spl_wsdoc_assets_refs() {
  local out rc=0
  out="$(SQL="select distinct 'ASSET ' || i.tenant_id || ' ' || a.value from workspace_doc_item i, jsonb_each_text(CASE WHEN jsonb_typeof(i.attrs->'assets') = 'object' THEN i.attrs->'assets' ELSE '{}'::jsonb END) a where i.parent_id is null and i.tenant_id <> 'system' order by 1" \
    do_spl_db_query 2>&1)" || rc=$?
  ((rc == 0)) || { do_log "FATAL ENV=$ENV: the hub DB read failed (rc=$rc)" >&2; return 1; }
  awk '$1 == "ASSET" { print $2, $3 }' <<<"$out"
}

# _spl_wsdoc_assets_sha_is <file> <sha256>: the file's bytes hash to sha256.
_spl_wsdoc_assets_sha_is() {
  [[ "$(sha256sum "$1" 2>/dev/null | awk '{ print $1 }')" == "$2" ]]
}

# _spl_wsdoc_assets_move_one <src gs://> <dst gs://> <sha> <work> <dry> ->
# prints one verdict: moved | already | would-copy | FAIL <why>.
_spl_wsdoc_assets_move_one() {
  local src="$1" dst="$2" sha="$3" f="$4/obj" back="$4/back" acct="--account=$GCP_ACCOUNT"
  rm -f "$f" "$back"
  if gcloud storage objects describe "$dst" "$acct" --format='value(name)' >/dev/null 2>&1; then
    gcloud storage cp "$dst" "$back" "$acct" --quiet >/dev/null 2>&1 || { echo "FAIL dst-unreadable"; return 0; }
    _spl_wsdoc_assets_sha_is "$back" "$sha" && echo already || echo "FAIL dst-differs (left as is)"
    return 0
  fi
  gcloud storage objects describe "$src" "$acct" --format='value(name)' >/dev/null 2>&1 || { echo "FAIL src-missing"; return 0; }
  gcloud storage cp "$src" "$f" "$acct" --quiet >/dev/null 2>&1 || { echo "FAIL src-unreadable"; return 0; }
  _spl_wsdoc_assets_sha_is "$f" "$sha" || { echo "FAIL src-differs"; return 0; }
  (($5 == 0)) || { echo would-copy; return 0; }
  gcloud storage cp "$f" "$dst" "$acct" --if-generation-match=0 --content-type=application/octet-stream --quiet >/dev/null 2>&1 ||
    { echo "FAIL put"; return 0; }
  gcloud storage cp "$dst" "$back" "$acct" --quiet >/dev/null 2>&1 || { echo "FAIL copy-unreadable"; return 0; }
  _spl_wsdoc_assets_sha_is "$back" "$sha" && echo moved || echo "FAIL copy-differs"
}
