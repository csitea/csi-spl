#!/bin/bash
#------------------------------------------------------------------------------
# @description ERASE one stored file (a file_id = the sha256 of its bytes) on
# @description the owner's request: a file posted by mistake that must not
# @description stay anywhere we hold it. Three legs, each read back:
# @description   HUB_LEG=1  the hub's object t/<tenant>/files/<file_id> in the
# @description              env's 050 bucket, deleted as the env SA: the
# @description              object DELETE /v1/files/{file_id} removes (that
# @description              route needs a WS-minted upload token of a box the
# @description              read door lets in, which no operator holds).
# @description              Read-back: the object is gone (the verdict) and an
# @description              unauthenticated GET /v1/files/<id> answers 4xx.
# @description              A hub instance may still serve its in-memory copy
# @description              for up to the blob cache ttl (10 min).
# @description   BOX_LEG=1  every path on THIS box whose name carries the
# @description              file_id (desk spool files/, /var/spool-hub,
# @description              /var/tmp ...), under every real home, found with
# @description              find -xdev per root. Read-back: the same search
# @description              prints nothing.
# @description   BKP_LEG=1  REPORT ONLY: whether the off-project backup (iac
# @description              046) holds the object, and its retention. A delete
# @description              there needs the owner's go for that delete.
# @description DRY_RUN=1 (the default) prints the plan and deletes nothing.
# @description Never opens, copies or hashes the file: names only.
# @param FILE_ID - required: 64 lowercase hex
# @param ENV - required for HUB_LEG/BKP_LEG: dev or prd
# @param TENANT (or TENANT_ID) - required for HUB_LEG/BKP_LEG: the tenant slug
# @param HUB_LEG, BOX_LEG, BKP_LEG (optional) - 1 (default) or 0
# @param FILE_ERASE_ROOTS (optional) - colon list of roots to search, replacing
#   the default (every real home, /root, /var/spool-hub, /var/tmp, /tmp,
#   /var/csi, /opt)
# @param FILE_ERASE_SUDO (optional) - prefix for find/rm; default `sudo -n`
#   unless root, so other users' 0700 homes are searched too
# @param DRY_RUN (optional) - 1 (default) plan only; 0 erase
# @example FILE_ID=<sha256> ENV=prd TENANT=t1 ./run -a do_spl_file_erase
# @example FILE_ID=<sha256> ENV=prd TENANT=t1 HUB_LEG=0 BKP_LEG=0 DRY_RUN=0 ./run -a do_spl_file_erase
#------------------------------------------------------------------------------
do_spl_file_erase() {
  local fid="${FILE_ID:-}" tenant="${TENANT:-${TENANT_ID:-}}" dry=1 rc=0 leg
  local hub="${HUB_LEG:-1}" box="${BOX_LEG:-1}" bkp="${BKP_LEG:-1}"
  [[ "$fid" =~ ^[0-9a-f]{64}$ ]] || { do_log "FATAL FILE_ID must be 64 lowercase hex (a sha256 file_id), got: '$fid'"; return 1; }
  for leg in "HUB_LEG=$hub" "BOX_LEG=$box" "BKP_LEG=$bkp"; do
    [[ "${leg#*=}" == 0 || "${leg#*=}" == 1 ]] || { do_log "FATAL ${leg%%=*} must be 0 or 1, got: ${leg#*=}"; return 1; }
  done
  [[ "$hub$box$bkp" != 000 ]] || { do_log "FATAL HUB_LEG, BOX_LEG and BKP_LEG are all 0: nothing to do"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if [[ "$hub$bkp" != 00 ]]; then
    spl_require_tenant_slug "$tenant" || return 1
    do_require_bin gcloud yq curl || return 1
    do_spl_cloud_cnf || return 1
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  if (( hub )); then spl_file_erase_hub "$fid" "$tenant" "$dry" || rc=1; fi
  if (( box )); then spl_file_erase_box "$fid" "$dry" || rc=1; fi
  if (( bkp )); then spl_file_erase_bkp_report "$fid" "$tenant" || rc=1; fi
  if (( dry )); then
    do_log "OK DRY RUN: nothing was deleted. DRY_RUN=0 to erase."
  elif (( rc == 0 )); then
    do_log "OK file $fid erased from every leg run; each read-back passed"
  fi
  return $rc
}

# spl_file_erase_hub <fid> <tenant> <dry> -> deletes the 050 object as the env
# SA and reads it back; prints hub_object=... hub_get=...
spl_file_erase_hub() {
  local fid="$1" tenant="$2" dry="$3" bucket obj api code
  bucket="$(yq -r '.env.steps."050-gcs-files".files_bucket_name // ""' "$SPL_CNF")"
  [[ -n "$bucket" && "$bucket" != null ]] || { do_log "FATAL cnf steps.050-gcs-files.files_bucket_name is empty for $ENV"; return 1; }
  spl_cnf_api_fqdn api || return 1
  obj="gs://$bucket/t/$tenant/files/$fid"
  if ! spl_file_erase_gs_exists "$obj"; then
    do_log "INFO $ENV hub: $obj is absent (nothing to delete)"
  elif (( dry )); then
    do_log "INFO DRY_RUN would delete $obj as $GCP_ACCOUNT"
    printf 'hub_object=present (dry run)\n'
    return 0
  else
    gcloud storage rm "$obj" --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      do_log "WARN $ENV hub: the delete of $obj reported an error; the read-back decides"
  fi
  if spl_file_erase_gs_exists "$obj"; then
    printf 'hub_object=present\n'
    do_log "FAIL $ENV hub: $obj is still there after the delete"
    return 3
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "X-Spool-Tenant: $tenant" "https://$api/v1/files/$fid")"
  printf 'hub_object=absent hub_get=%s\n' "${code:-000}"
  [[ "$code" =~ ^4[0-9][0-9]$ ]] || { do_log "FAIL $ENV hub: GET /v1/files/<id> answered ${code:-no reply}, not a 4xx"; return 3; }
  do_log "INFO $ENV hub: object absent, GET answers $code (the object store is the verdict: an anonymous GET is refused either way)"
}

# spl_file_erase_gs_exists <gs://object> -> 0 when the object exists (env SA).
spl_file_erase_gs_exists() {
  gcloud storage objects describe "$1" --account="$GCP_ACCOUNT" --format='value(name)' >/dev/null 2>&1
}

# spl_file_erase_sudo -> the prefix for find/rm: FILE_ERASE_SUDO when set (even
# empty), else `sudo -n` unless root.
spl_file_erase_sudo() {
  if [[ -n "${FILE_ERASE_SUDO+x}" ]]; then
    printf '%s' "$FILE_ERASE_SUDO"
  elif [[ "$(id -u)" != 0 ]]; then
    printf 'sudo -n'
  fi
}

# spl_file_erase_roots -> the search roots, one per line: FILE_ERASE_ROOTS, else
# every real home (passwd + the /home and /mnt/data/home dirs) and the shared
# spool/tmp/work trees.
spl_file_erase_roots() {
  if [[ -n "${FILE_ERASE_ROOTS:-}" ]]; then
    tr ':' '\n' <<<"$FILE_ERASE_ROOTS" | sed '/^$/d'
    return 0
  fi
  {
    getent passwd 2>/dev/null | awk -F: '$3 == 0 || $3 >= 1000 { print $6 }'
    ls -d /home/* /mnt/data/home/* 2>/dev/null
    printf '%s\n' /root /var/spool-hub /var/tmp /tmp /var/csi /opt
  } | sort -u | while read -r d; do [[ -d "$d" && "$d" != / ]] && echo "$d"; done
}

# spl_file_erase_find <fid> <roots...> -> every path whose name carries fid.
spl_file_erase_find() {
  local fid="$1" sudo_ r
  shift
  sudo_="$(spl_file_erase_sudo)"
  for r in "$@"; do
    $sudo_ find "$r" -xdev -name "*$fid*" -prune -print 2>/dev/null
  done | sort -u
}

# spl_file_erase_box <fid> <dry> -> removes every copy on this box, reads back.
spl_file_erase_box() {
  local fid="$1" dry="$2" sudo_ hits n p
  sudo_="$(spl_file_erase_sudo)"
  local -a roots=()
  mapfile -t roots < <(spl_file_erase_roots)
  (( ${#roots[@]} )) || { do_log "FATAL no search root exists on this box"; return 1; }
  hits="$(spl_file_erase_find "$fid" "${roots[@]}")"
  n="$(sed '/^$/d' <<<"$hits" | wc -l)"
  do_log "INFO box: $n path(s) carry the file_id under ${#roots[@]} root(s): ${roots[*]}"
  [[ -z "$hits" ]] || sed 's/^/  /' <<<"$hits"
  if (( dry )); then
    printf 'box_copies=%s (dry run)\n' "$n"
    return 0
  fi
  while IFS= read -r p; do
    [[ -n "$p" && "$(basename "$p")" == *"$fid"* ]] || continue
    $sudo_ rm -rf --one-file-system -- "$p" || do_log "WARN box: cannot remove $p; the read-back decides"
  done <<<"$hits"
  hits="$(spl_file_erase_find "$fid" "${roots[@]}")"
  n="$(sed '/^$/d' <<<"$hits" | wc -l)"
  printf 'box_copies=%s roots=%s\n' "$n" "${#roots[@]}"
  (( n == 0 )) || { do_log "FAIL box: $n copy(ies) left, first: $(head -1 <<<"$hits")"; return 3; }
  do_log "INFO box: read-back clean, find -xdev prints nothing under ${#roots[@]} root(s)"
}

# spl_file_erase_bkp_report <fid> <tenant> -> whether the off-project copy holds
# the object, and the retention that keeps it. Never deletes.
spl_file_erase_bkp_report() {
  local fid="$1" tenant="$2" obj out held=unknown soft
  local -a ret=()
  spl_offsite_cnf || return 1
  obj="gs://$SPL_OFFSITE_BUCKET/$ENV/files/t/$tenant/files/$fid"
  # The env SA may list names in the copy (objectCreator + list), never read.
  if out="$(gcloud storage ls "$obj" --account="$GCP_ACCOUNT" 2>&1)"; then
    if grep -q "$fid" <<<"$out"; then held=yes; else held=no; fi
  elif grep -qiE 'matched no objects|not found|404' <<<"$out"; then
    held=no
  fi
  mapfile -t ret < <(yq -r '.env.steps."046-gcs-offsite-backups" | [.retention_days, .max_age_days, .soft_delete_retention_seconds] | .[] | (. // "")' "$SPL_CNF")
  soft=$(( ${ret[2]:-0} / 86400 ))
  printf 'bkp_object=%s bkp_bucket=%s retention_days=%s max_age_days=%s soft_delete_days=%s\n' \
    "$held" "$SPL_OFFSITE_BUCKET" "${ret[0]:-?}" "${ret[1]:-?}" "$soft"
  if [[ "$held" == yes ]]; then
    do_log "INFO bkp: the off-project copy holds it; its retention policy (${ret[0]:-?} d) refuses a delete of a younger object, and deleting it needs the owner's go for THAT delete. Not deleted."
  elif [[ "$held" == unknown ]]; then
    do_log "WARN bkp: cannot tell whether $obj exists: $(head -1 <<<"$out")"
  fi
}
