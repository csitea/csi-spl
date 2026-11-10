#!/bin/bash
#------------------------------------------------------------------------------
# @description ONE-OFF clean-up of the prd db backups in both prd places
# @description (SPL-5187, spec 029; owner HUM-10 topic ef8904c0, msg 5ec19d75:
# @description "Only today's stays, everything older goes"). The 30-day
# @description settings of 045 and 046 do not change: no retention, lock,
# @description lifecycle, soft delete or versioning setting is written.
# @description   045 bucket (steps.045-gcs-db-backups.backups_bucket_name):
# @description       every generation created before today 00:00 UTC goes.
# @description   046 bucket (steps.046-gcs-offsite-backups.offsite_bucket_name),
# @description       only under prd/db/ (the dumps; prd/files/ is counted,
# @description       never touched): every generation 30 days old or older
# @description       whose retention has expired goes; anything younger is
# @description       reported as left by the lock.
# @description Each run lists both buckets live first. A bucket with no dump
# @description created today (UTC) is aborted: nothing in it is deleted.
# @description Report per bucket: before, to remove / removed, after, left by
# @description the lock, and its soft delete and versioning, stated plainly (a
# @description soft-deleted object is hidden, not gone, until its window ends).
# @description Identity: the 045 bucket as the prd project SA
# @description (do_gcp_pin_account), the 046 bucket as the SA of its own
# @description project (steps.046.tf_key_project, key-<project>.json), both in
# @description a throwaway gcloud config, --account on every call. A missing
# @description permission is a FATAL, never retried as another account.
# @param ENV - required: prd. Any other env is refused.
# @param DRY_RUN (optional) - 1 (default): list and report. 0: delete.
# @param SPL_PURGE_NOW (optional) - tests only: "now" as epoch seconds
# @example ENV=prd ./run -a do_gcp_purge_prd_backups
# @example ENV=prd DRY_RUN=0 ./run -a do_gcp_purge_prd_backups
#------------------------------------------------------------------------------
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"

# the 046 bucket keeps a dump at least this long (owner: "The normal
# configuration is to keep 30 days of backups")
SPL_PURGE_OFFSITE_MIN_AGE_DAYS=30

do_gcp_purge_prd_backups() {
  local dry_run="${DRY_RUN:-1}"
  [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry_run'"; return 1; }
  [[ "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be prd (a one-off prd clean-up), got: '${ENV:-}'"; return 1; } # guard:prd-only
  command -v gcloud &>/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  do_require_bin yq || return 1
  do_require_bin jq || return 1

  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_gcp_spl_proj_id || return 1
  local cnf="$_spl_sdk_dir/cnf.yaml" db_bucket off_bucket off_proj
  do_spl_merged_cnf "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP" "$ENV" "$cnf" || return 1
  db_bucket="$(yq -r '.env.steps."045-gcs-db-backups".backups_bucket_name // ""' "$cnf")"
  off_bucket="$(yq -r '.env.steps."046-gcs-offsite-backups".offsite_bucket_name // ""' "$cnf")"
  off_proj="$(yq -r '.env.steps."046-gcs-offsite-backups".tf_key_project // ""' "$cnf")"
  [[ -n "$db_bucket" && -n "$off_bucket" && -n "$off_proj" ]] ||
    { do_log "FATAL ENV=$ENV cnf lacks 045 backups_bucket_name, 046 offsite_bucket_name or 046 tf_key_project"; return 1; }

  do_gcp_pin_account || return 1
  local off_key off_acct
  off_key="$(PROJ_ID="$off_proj" do_gcp_sa_key_file)" ||
    { do_log "FATAL no SA key of $off_proj (\$HOME/.gcp/.<org>/key-$off_proj.json): the 046 bucket is read as its own project's SA, never another account"; return 1; }
  off_acct="$(do_gcp_activate_sa_key "$off_key")" || return 1

  local now today_start
  now="${SPL_PURGE_NOW:-$(date -u +%s)}"
  today_start=$(( now - now % 86400 ))
  do_log "INFO ENV=$ENV DRY_RUN=$dry_run now=$(date -u -d "@$now" +%FT%TZ) today_utc=$(date -u -d "@$now" +%F)"

  local rc=0
  _gcp_purge_prd_bkp_bucket "gs://$db_bucket" "" "$GCP_ACCOUNT" "$today_start" before "$now" "$dry_run" || rc=1
  _gcp_purge_prd_bkp_bucket "gs://$off_bucket" "$ENV/db/" "$off_acct" \
    "$(( now - SPL_PURGE_OFFSITE_MIN_AGE_DAYS * 86400 ))" at "$now" "$dry_run" || rc=1 # guard:30-days
  if ((rc == 0)); then
    do_log "OK both buckets done (DRY_RUN=$dry_run)"
  else
    do_log "FATAL at least one bucket was aborted or failed: see above"
  fi
  return "$rc"
}

# _gcp_purge_prd_bkp_bucket <gs://bucket> <prefix> <account> <cutoff> <at|before> <now> <dry_run>:
# one bucket, end to end. A generation under <prefix> goes when it was
# created at or before <cutoff> ("at", the 046 30 days) or strictly before it
# ("before", the 045 today 00:00 UTC) and its retention has expired at <now>.
_gcp_purge_prd_bkp_bucket() {
  local bucket="$1" prefix="$2" acct="--account=$3" cutoff="$4" edge="$5" now="$6" dry_run="$7"
  local dir="$_spl_sdk_dir/${bucket#gs://}" plan n_today
  mkdir -p "$dir" || return 1
  do_log "INFO == $bucket (scope: ${prefix:-the whole bucket}) as $3"
  _gcp_purge_prd_bkp_settings "$bucket" "$acct" || return 1
  plan="$dir/before.tsv"
  _gcp_purge_prd_bkp_list "$bucket" "$acct" "$prefix" "$cutoff" "$edge" "$now" >"$plan" || return 1
  n_today=$(awk -F'\t' -v t="$(( now - now % 86400 ))" '$1 == "in" && $4 >= t' "$plan" | grep -c .)
  if ((n_today == 0)); then # guard:no-today
    do_log "FATAL ABORT $bucket: no backup created today (UTC) under ${prefix:-/}: nothing is deleted here"
    _gcp_purge_prd_bkp_report "$bucket" "$plan" "" aborted
    return 1
  fi
  local cls url
  if [[ "$dry_run" == 1 ]]; then # guard:dry-run
    while IFS=$'\t' read -r _ cls url _; do
      [[ "$cls" == remove ]] && do_log "INFO DRY_RUN would delete $url"
    done <"$plan"
    _gcp_purge_prd_bkp_report "$bucket" "$plan" "" dry-run
    return 0
  fi
  local urls=() i rm_rc=0 left
  mapfile -t urls < <(awk -F'\t' '$2 == "remove" {print $3}' "$plan")
  for ((i = 0; i < ${#urls[@]}; i += 100)); do
    gcloud storage rm "${urls[@]:i:100}" "$acct" --quiet || rm_rc=1
  done
  _gcp_purge_prd_bkp_list "$bucket" "$acct" "$prefix" "$cutoff" "$edge" "$now" >"$dir/after.tsv" || return 1
  _gcp_purge_prd_bkp_report "$bucket" "$plan" "$dir/after.tsv" deleted
  left=$(awk -F'\t' 'NR == FNR { if ($2 == "remove") want[$3] = 1; next } ($3 in want)' "$plan" "$dir/after.tsv" | grep -c .)
  ((rm_rc == 0 && left == 0)) || { do_log "FATAL $bucket: $left generation(s) meant to go are still there (rm rc=$rm_rc)"; return 1; }
}

# _gcp_purge_prd_bkp_settings <gs://bucket> <--account=..>: soft delete,
# versioning and retention, read and stated plainly; never changed.
_gcp_purge_prd_bkp_settings() {
  local bucket="$1" acct="$2" js soft ver ret
  js=$(gcloud storage buckets describe "$bucket" "$acct" --format=json 2>&1) ||
    { do_log "FATAL cannot read $bucket's settings as ${acct#--account=}: $js"; return 1; }
  soft=$(jq -r '.soft_delete_policy.retentionDurationSeconds // "0"' <<<"$js")
  ver=$(jq -r '.versioning_enabled // false' <<<"$js")
  ret=$(jq -r '.retention_policy.retentionPeriod // "none"' <<<"$js")
  if [[ "$soft" =~ ^[1-9][0-9]*$ ]]; then
    do_log "INFO $bucket soft delete: ON, $((soft / 86400)) day(s). A deleted object is NOT gone: it stays recoverable (and billed) for $((soft / 86400)) day(s), then Google removes it. Not changed here."
  else
    do_log "INFO $bucket soft delete: OFF. A deleted object is gone at once."
  fi
  if [[ "$ver" == true ]]; then
    do_log "INFO $bucket object versioning: ON. Every generation is deleted by its number, so no noncurrent copy stays behind. Not changed here."
  else
    do_log "INFO $bucket object versioning: OFF. Not changed here."
  fi
  do_log "INFO $bucket retention policy (the lock): $ret seconds. Not changed here."
}

# _gcp_purge_prd_bkp_list <gs://bucket> <--account=..> <prefix> <cutoff> <at|before> <now>:
# every generation of the bucket (live and noncurrent), one line each:
#   scope(in|out) <TAB> class(remove|lock|-) <TAB> url#gen <TAB> created_epoch
# lock = stays: too young or under retention. An empty bucket lists nothing.
_gcp_purge_prd_bkp_list() {
  local bucket="$1" acct="$2" prefix="$3" cutoff="$4" edge="$5" now="$6" out rc=0
  out=$(gcloud storage ls --all-versions --json "$bucket/**" "$acct" 2>&1) || rc=$?
  if ((rc != 0)); then
    grep -qi 'matched no objects' <<<"$out" && return 0
    do_log "FATAL cannot list $bucket as ${acct#--account=} (rc=$rc): $out" >&2
    return 1
  fi
  jq -r --arg p "$prefix" --argjson cut "$cutoff" --arg edge "$edge" --argjson now "$now" '
    def epoch: if . == null then null
      elif test("^[0-9-]{10}T[0-9:]{8}(\\.[0-9]+)?(Z|\\+00:00)$") then .[0:19] + "Z" | fromdateiso8601
      else error("not a UTC time: \(.)") end;
    .[] | .metadata as $m | ($m.timeCreated | epoch) as $c | ($m.retentionExpirationTime | epoch) as $r
    | (if ($m.name | startswith($p)) then "in" else "out" end) as $s
    | [$s,
       (if $s == "out" then "-"
        elif ($c < $cut or ($edge == "at" and $c == $cut)) and ($r == null or $r <= $now) then "remove"
        else "lock" end),
       .url, $c] | @tsv' <<<"$out" || { do_log "FATAL cannot parse the listing of $bucket" >&2; return 1; }
}

# _gcp_purge_prd_bkp_report <bucket> <before.tsv> <after.tsv|""> <mode>: the
# one summary line per bucket. In the 045 bucket "left_by_lock" is today's.
_gcp_purge_prd_bkp_report() {
  local bucket="$1" b="$2" a="$3" mode="$4" before go lock out after
  before=$(awk -F'\t' '$1 == "in"' "$b" | grep -c .)
  go=$(awk -F'\t' '$2 == "remove"' "$b" | grep -c .)
  lock=$(awk -F'\t' '$2 == "lock"' "$b" | grep -c .)
  out=$(awk -F'\t' '$1 == "out"' "$b" | grep -c .)
  case "$mode" in
    aborted) do_log "INFO REPORT $bucket ABORTED: before=$before to_remove=0 after=$before left_by_lock=$lock out_of_scope_untouched=$out" ;;
    dry-run) do_log "INFO REPORT $bucket DRY_RUN: before=$before to_remove=$go after=$((before - go)) left_by_lock=$lock out_of_scope_untouched=$out" ;;
    deleted)
      after=$(awk -F'\t' '$1 == "in"' "$a" | grep -c .)
      lock=$(awk -F'\t' '$2 == "lock"' "$a" | grep -c .)
      do_log "INFO REPORT $bucket DELETED: before=$before removed=$((before - after)) after=$after left_by_lock=$lock out_of_scope_untouched=$out" ;;
  esac
}
