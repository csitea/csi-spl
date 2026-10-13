#!/bin/bash
#------------------------------------------------------------------------------
# @description List every database export object of a cloud env and whether
# @description the internet can read it, as the env's project service account.
# @description Read only: it changes nothing, so it takes no DRY_RUN.
# @description
# @description Owner, 2026-10-13 (topic dd1fdead): "the db exports which are
# @description public to the Internet should contain only the data from the
# @description spool tenant". Before deleting or re-exporting anything, this
# @description measures which exports exist and which are public. It reads:
# @description   - every bucket of the env's project: its IAM policy (an
# @description     allUsers / allAuthenticatedUsers member = public) and its
# @description     uniform bucket-level access;
# @description   - every object of the 045 dump bucket and, when the env SA
# @description     may list it, the env's prefix of the 046 off-project copy.
# @description One TSV line per object: env, bucket, object, bytes, public.
# @description Names and sizes only: no object is downloaded or opened.
# @param ENV - required: dev or prd
# @example ENV=prd ./run -a do_spl_db_export_audit
#------------------------------------------------------------------------------
do_spl_db_export_audit() {
  do_require_bin gcloud yq || return 1
  do_spl_cloud_cnf || return 1
  local db
  db="$(spl_db_backup_bucket)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local buckets b pub n_pub=0 n_obj=0 n_obj_pub=0
  buckets="$(gcloud storage buckets list --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --format='value(name)' 2>/dev/null)" ||
    { do_log "FATAL $ENV: cannot list the buckets of $SPL_PROJECT as $GCP_ACCOUNT"; return 2; }
  for b in $buckets; do
    pub="$(spl_db_export_bucket_public "$b")"
    [[ "$pub" == yes ]] && n_pub=$((n_pub + 1))
    printf 'bucket\t%s\t%s\tpublic=%s\n' "$ENV" "$b" "$pub"
  done

  local offsite="" src name size public
  spl_offsite_cnf >/dev/null 2>&1 && offsite="$SPL_OFFSITE_BUCKET"
  for src in "gs://$db" ${offsite:+"gs://$offsite/$ENV/db"}; do
    b="${src#gs://}"; b="${b%%/*}"
    public="$(spl_db_export_bucket_public "$b")"
    # the off-project bucket's policy is readable only as the csi-spl-bkp SA
    [[ "$public" == unknown && "$b" == "$offsite" ]] && spl_bkp_key >/dev/null 2>&1 &&
      public="$(SPL_DB_EXPORT_AS_BKP=1 spl_db_export_bucket_public "$b")"
    while IFS=$'\t' read -r name size; do
      [[ -n "$name" ]] || continue
      n_obj=$((n_obj + 1))
      [[ "$public" == yes ]] && n_obj_pub=$((n_obj_pub + 1))
      printf 'object\t%s\t%s\t%s\t%s\tpublic=%s\n' "$ENV" "$b" "${name#gs://"$b"/}" "$size" "$public"
    done < <(spl_db_export_objects "$src")
  done
  do_log "OK $ENV: $n_pub public bucket(s) in $SPL_PROJECT; $n_obj db export object(s), $n_obj_pub of them public"
}

# spl_db_export_bucket_public <bucket> -> yes, no, acl (no uniform access, so
# objects may carry their own public ACL) or unknown (the policy is not
# readable, e.g. the off-project bucket as the env SA).
spl_db_export_bucket_public() {
  local policy ubla
  policy="$(_spl_db_export_gcloud storage buckets get-iam-policy "gs://$1" --format=json 2>/dev/null)" ||
    { echo unknown; return 0; }
  if grep -qE '"(allUsers|allAuthenticatedUsers)"' <<<"$policy"; then echo yes; return 0; fi
  ubla="$(_spl_db_export_gcloud storage buckets describe "gs://$1" \
    --format='value(uniform_bucket_level_access)' 2>/dev/null)"
  [[ "${ubla,,}" == true ]] && echo no || echo acl
}

# _spl_db_export_gcloud <args...> -> gcloud as the env SA, or as the
# csi-spl-bkp SA (spl_bkp_gcloud pins its own --account) when
# SPL_DB_EXPORT_AS_BKP=1.
_spl_db_export_gcloud() {
  if [[ "${SPL_DB_EXPORT_AS_BKP:-0}" == 1 ]]; then spl_bkp_gcloud "$@"; return; fi
  gcloud "$@" --account="$GCP_ACCOUNT"
}

# spl_db_export_objects <gs://bucket[/prefix]> -> "<url>\t<bytes>" per object.
spl_db_export_objects() {
  gcloud storage ls -l "${1%/}/**" --account="$GCP_ACCOUNT" 2>/dev/null |
    awk '$3 ~ /^gs:\/\// && $3 !~ /\/$/ { print $3 "\t" $1 }'
}
