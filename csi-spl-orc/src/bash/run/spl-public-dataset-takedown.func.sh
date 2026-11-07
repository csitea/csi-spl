#!/bin/bash
#------------------------------------------------------------------------------
# @description The public dataset TAKE-DOWN (spec 091 T008; section 10). A
# @description delete, so it refuses without TAKEDOWN_GO=<the same file name>
# @description and TAKEDOWN_OWNER_MSG=<the owner's message id>, set only after
# @description the orchestrator relays the owner's go; the id is checked for
# @description form and logged, not looked up. The check comes first, dry run or
# @description not. For one published file it:
# @description   1. points latest.json at the newest other published file with
# @description      three PASS verdicts when latest.json names this file or
# @description      cannot be read; with none left, at {file: null}. This comes
# @description      first, so latest.json never names a deleted file
# @description   2. removes the candidate and its verdicts from staging, so the
# @description      next publish cannot put the same file back. If that fails the
# @description      public delete still goes on, exit 1, and a re-run finishes
# @description      staging: a file only in staging is still worked on, the
# @description      refusal needs it gone from both. Until that re-run the next
# @description      publish COULD put it back
# @description   3. deletes the file, its manifest and its verdicts wherever
# @description      they sit in the public bucket (daily/ and stable/) and
# @description      proves them gone
# @description It stays possible while cnf public_dataset.enabled is false: the
# @description switch being off must not hold back removing a bad file. It runs
# @description as the per-env project SA, since the publish SA can only create.
# @description A downloaded copy cannot be recalled (section 10).
# @param ENV - required: dev or prd
# @param TAKEDOWN_FILE - required: spool-hub-public-<YYYY-MM-DD>-v<X.Y.Z>.sql.gz
# @param TAKEDOWN_GO - required: the same file name, set only after the orchestrator relays the owner's go
# @param TAKEDOWN_OWNER_MSG - required: the id of the owner's message giving the go (8+ hex)
# @param DRY_RUN (optional) - 1 (default): name what would go, no cloud. 0: delete.
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @example ENV=dev TAKEDOWN_FILE=spool-hub-public-2026-11-03-v1.5.0.sql.gz TAKEDOWN_GO=spool-hub-public-2026-11-03-v1.5.0.sql.gz TAKEDOWN_OWNER_MSG=<owner msg id> ./run -a do_spl_public_dataset_takedown
#------------------------------------------------------------------------------
do_spl_public_dataset_takedown() {
  do_require_bin yq jq || return 1
  local file="${TAKEDOWN_FILE:-}" dry=1
  [[ "$file" =~ ^spool-hub-public-[0-9]{4}-[0-9]{2}-[0-9]{2}-v[0-9]+\.[0-9]+\.[0-9]+\.sql\.gz$ ]] ||
    { do_log "FATAL TAKEDOWN_FILE must be spool-hub-public-<YYYY-MM-DD>-v<X.Y.Z>.sql.gz"; return 1; }
  [[ "${TAKEDOWN_GO:-}" == "$file" ]] ||
    { do_log "FATAL take-down refused: a delete needs the owner's go, relayed by the orchestrator, as TAKEDOWN_GO=$file"; return 1; }
  [[ "${TAKEDOWN_OWNER_MSG:-}" =~ ^[0-9a-f]{8}[0-9a-f-]*$ ]] ||
    { do_log "FATAL take-down refused: a delete needs the id of the owner's message as TAKEDOWN_OWNER_MSG (8+ hex)"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  local staging public
  IFS=$'\t' read -r staging public < <(yq -r '[.env.steps."053-gcs-public-dataset".staging_bucket_name // "",
      .env.steps."053-gcs-public-dataset".public_bucket_name // ""] | @tsv' "$SPL_CNF")
  spl_pd_buckets_check "$staging" "$public" || return 1
  local name="${file%.sql.gz}" cand="${file#spool-hub-public-}"
  cand="${cand%.sql.gz}"
  if (( dry )); then
    do_log "INFO DRY_RUN would: repoint gs://$public/latest.json if it names $file, remove candidates/$cand/ and its verdicts from gs://$staging, delete $name.* from gs://$public"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to delete."
    return 0
  fi
  [[ "$(do_spl_cloud_provider)" == gcp ]] || { do_log "FATAL do_spl_public_dataset_takedown needs GCS (provider gcp)"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_require_bin gcloud || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local h all objs u rc=0 sha
  do_log "INFO take-down of $file on the owner's message $TAKEDOWN_OWNER_MSG, as $GCP_ACCOUNT"
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$h'; trap - RETURN" RETURN
  all="$(spl_pd_gs ls "gs://$public/**")" || { do_log "FATAL cannot list gs://$public: nothing deleted"; return 1; }
  objs="$(spl_pd_takedown_objects "$name" <<<"$all")"
  if [[ -z "$objs" ]] && spl_pd_gs_none "gs://$staging/candidates/$cand/"; then
    do_log "FATAL $file is not in gs://$public and not staged in gs://$staging: nothing deleted"
    return 1
  fi
  sha="$(spl_pd_gs cat "gs://$public/daily/$name.manifest.json" | jq -r '.sha256 // ""' 2>/dev/null)"
  spl_pd_takedown_repoint "$public" "$h" "$file" "$all" || return 1
  spl_pd_takedown_unstage "$staging" "$cand" "$name" "$sha" ||
    { rc=1; do_log "FATAL $cand could not be removed from gs://$staging: the next publish could put it back until a re-run finishes it. The public delete goes on."; }
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    spl_pd_gs rm "$u" >/dev/null || { do_log "FATAL cannot delete $u"; rc=1; }
  done <<<"$objs"
  # latest.json always stays, so a listing that fails or comes back empty is no proof
  all="$(spl_pd_gs ls "gs://$public/**")" && [[ -n "$all" && -z "$(spl_pd_takedown_objects "$name" <<<"$all")" ]] ||
    { do_log "FATAL objects of $file may still be in gs://$public (no clean listing): a re-run continues"; return 1; }
  (( rc == 0 )) || return 1
  do_log "OK public dataset take-down ($ENV): $file, its manifest and its verdicts are gone from gs://$public and its candidate from gs://$staging. Copies already downloaded cannot be recalled."
}

# spl_pd_takedown_objects <name> < listing: the listed objects of that file:
# the file, its manifest, its verdicts, in any prefix. Fixed strings only.
spl_pd_takedown_objects() {
  grep -F -e "/$1.sql.gz" -e "/$1.manifest.json" -e "/$1.verdicts/"
}

# spl_pd_takedown_unstage <staging> <candidate> <name> <public sha256 or "">: the
# verdicts first, then the candidate, stopping at a failure: its manifest is what
# tells a re-run the sha256 once the public one is gone. Already gone is fine (a
# re-run, or a candidate the lifecycle already took).
spl_pd_takedown_unstage() {
  local uri="gs://$1/candidates/$2/" sha staged
  staged="$(spl_pd_gs cat "$uri$3.manifest.json" | jq -r '.sha256 // ""' 2>/dev/null)"
  [[ "$staged" != "$4" ]] || staged=""
  for sha in "$4" "$staged"; do
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || continue
    spl_pd_gs rm --recursive "gs://$1/verdicts/$sha/" >/dev/null || spl_pd_gs_none "gs://$1/verdicts/$sha/" || return 1
  done
  spl_pd_gs rm --recursive "$uri" >/dev/null || spl_pd_gs_none "$uri"
}

# spl_pd_takedown_repoint <public bucket> <scratch> <file> <listing>: nothing to
# do while latest.json names another file; else the newest other file whose
# manifest carries three PASS verdicts on its own sha256, or {file: null}.
spl_pd_takedown_repoint() {
  local public="$1" h="$2" file="$3" all="$4" cur m ptr='' f
  cur="$(spl_pd_gs cat "gs://$public/latest.json" | jq -r '.file // ""' 2>/dev/null)"
  [[ -z "$cur" || "$cur" == "$file" ]] || return 0
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    spl_pd_gs cat "$m" >"$h/prev.json" || continue
    f="$(jq -r '.file // ""' "$h/prev.json" 2>/dev/null)"
    [[ "$f" != "$file" ]] && grep -qF "/daily/$f" <<<"$all" || continue
    spl_pd_takedown_good "$h/prev.json" || continue
    ptr="$(jq -c '{v: 1, file: .file, object: ("daily/" + .file), manifest: ("daily/" + (.file | sub("\\.sql\\.gz$"; ".manifest.json"))),
      sha256: .sha256, version: .version, published_at: .published_at}' "$h/prev.json")" && break
  done < <(grep -E '/daily/spool-hub-public-[^/]+\.manifest\.json$' <<<"$all" | sort -rV)
  if [[ -z "$ptr" ]]; then
    ptr='{"v":1,"file":null}'
    do_log "INFO no other good published file: latest.json now names none"
  else
    do_log "INFO latest.json now names $(jq -r .file <<<"$ptr")"
  fi
  spl_pd_latest_write "$public" "$h" "$ptr"
}

# spl_pd_takedown_good <manifest>: three PASS verdicts of the three kinds on
# this manifest's sha256, the loader's own test of a published manifest.
spl_pd_takedown_good() {
  jq -e '.sha256 as $sha | {"agy": "a-", "grok": "g-", "claude": "c-"} as $pre | (.verdicts // []) as $v
    | ($v | length) == 3 and ([$v[].lane_kind] | sort) == ["agy", "claude", "grok"] and ([$v[].lane_id] | unique | length) == 3
    and all($v[]; .lane_kind as $k | .verdict == "PASS" and .file_sha256 == $sha and (.lane_id | test("^" + $pre[$k] + "[0-9]{3}(@[a-z0-9-]+)?$")))' "$1" >/dev/null 2>&1
}
