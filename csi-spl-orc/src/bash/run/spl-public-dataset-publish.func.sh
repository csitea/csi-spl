#!/bin/bash
#------------------------------------------------------------------------------
# @description The public dataset PUBLISH (spec 091 T008; sections 6, 8.4). Run
# @description as the publish SA, refused for any other account. On prd it
# @description refuses while cnf public_dataset.enabled is false, whatever
# @description PUBLIC_DATASET_FORCE says; on dev the force stands in for it.
# @description   1. drops every staged candidate older than cnf
# @description      candidate_ttl_hours, with its name lists and verdicts
# @description   2. takes PD_CANDIDATE, else the newest candidate left, and
# @description      re-hashes its file against its manifest
# @description   3. requires three verdict files under verdicts/<sha256>/ of
# @description      kinds exactly {agy, grok, claude}, distinct lane ids of
# @description      their kind's prefix, each PASS on that sha256, each
# @description      hub_msg_id a hub message from that lane on PD_TOPIC
# @description      carrying the same sha256 and verdict
# @description   4. server-side copies the file and the verdicts, then writes
# @description      the manifest with the verdicts consolidated, under daily/
# @description      of the public bucket; proves the exact object set and that
# @description      no name list is public; writes latest.json LAST
# @description      (Cache-Control: no-cache)
# @description   5. deletes both name lists from staging and proves them gone
# @description Anything less in 2 or 3: nothing is published, exit 1, and a note
# @description on PD_TOPIC names what is missing, class only. A re-run after a
# @description partial publish is safe: copies never overwrite, and a different
# @description file under a published name is refused. Output names classes and
# @description object names, never row content (section 5.6).
# @param ENV - required: dev or prd
# @param PD_TOPIC - required: the dataset topic's task uuid
# @param TENANT_ID - required: the workspace of the dataset topic
# @param DESK_AGENT - required: the desk agent that reads the topic and posts the note
# @param GCP_SA_KEY_FILE - required unless GCP_ACCOUNT is the publish SA: the publish SA's key
# @param DRY_RUN (optional) - 1 (default): resolve the cnf and name the buckets, no cloud. 0: publish.
# @param PD_CANDIDATE (optional) - <YYYY-MM-DD>-v<X.Y.Z>; default the newest staged candidate
# @param PUBLIC_DATASET_FORCE (optional) - 1: dev only, run although cnf public_dataset.enabled is false
# @param DESK_BOX (optional) - default the desk box, the same value do_spl_desk_up used
# @example ENV=dev PUBLIC_DATASET_FORCE=1 PD_TOPIC=<uuid> TENANT_ID=t1 DESK_AGENT=c-001 ./run -a do_spl_public_dataset_publish
#------------------------------------------------------------------------------
do_spl_public_dataset_publish() {
  do_require_bin yq jq python3 sha256sum || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_desk_cnf || return 1
  spl_pd_publish_switch || return 1
  local -A P=()
  spl_pd_publish_cnf P || return 1
  if (( dry )); then
    do_log "INFO DRY_RUN would: as ${P[sa]} check ${P[cand]:-the newest candidate} in gs://${P[staging]}/candidates/ against its three verdicts on topic ${P[topic]}"
    do_log "INFO DRY_RUN would: copy it to gs://${P[public]}/daily/, write latest.json last, delete its name lists from staging"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to publish."
    return 0
  fi
  [[ "$(do_spl_cloud_provider)" == gcp ]] || { do_log "FATAL do_spl_public_dataset_publish needs GCS (provider gcp)"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_require_bin gcloud || return 1
  [[ "$GCP_ACCOUNT" == "${P[sa]}" ]] ||
    { do_log "FATAL the publish runs as the publish SA ${P[sa]} only (GCP_SA_KEY_FILE = its key), got $GCP_ACCOUNT"; return 1; }
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_desk_validate "${P[tenant]}" "${P[box]}" "${P[agent]}" || return 1
  spl_host_spool || return 1
  local h
  h="$(mktemp -d)" && chmod 700 "$h" && mkdir -m 700 "$h/v" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$h'; trap - RETURN" RETURN
  spl_pd_publish_candidates P "$h" || return 1
  if [[ -z "${P[cand]}" ]]; then
    do_log "OK public dataset publish ($ENV): no candidate is staged, nothing to publish"
    return "${P[droprc]}"
  fi
  local missing
  missing="$(spl_pd_publish_missing P "$h")" || return 1
  if [[ -n "$missing" ]]; then
    spl_pd_publish_note P "public dataset candidate ${P[cand]} ($ENV): nothing published. Missing: $missing"
    do_log "FAIL public dataset publish ($ENV): nothing published for ${P[cand]}. Missing: $missing"
    return 1
  fi
  spl_pd_publish_copy P "$h" || return 1
  spl_pd_publish_drop_names P || return 1
  do_log "OK public dataset published ($ENV): gs://${P[public]}/daily/${P[name]}.sql.gz sha256 ${P[sha]}, latest.json names it, its name lists are gone from staging"
  return "${P[droprc]}"
}

# spl_pd_publish_switch: 0 = go on. Prd has no way past cnf enabled false.
spl_pd_publish_switch() {
  local on
  on="$(yq -r '.env.public_dataset.enabled // false' "$SPL_CNF")"
  [[ "$on" == true ]] && return 0
  if [[ "$ENV" != prd && "${PUBLIC_DATASET_FORCE:-}" == 1 ]]; then return 0; fi
  do_log "FATAL public dataset publish ($ENV) refused: cnf public_dataset.enabled is $on${PUBLIC_DATASET_FORCE:+ (PUBLIC_DATASET_FORCE does not lift it on prd)}"
  return 1
}

# spl_pd_publish_cnf <assoc name>: buckets, the publish SA, the ttl, the topic
# and the desk that reads it.
spl_pd_publish_cnf() {
  local -n _c="$1"
  local staging public said ttl
  IFS=$'\t' read -r staging public said ttl < <(yq -r '[.env.steps."053-gcs-public-dataset".staging_bucket_name // "",
      .env.steps."053-gcs-public-dataset".public_bucket_name // "", .env.steps."053-gcs-public-dataset".publish_sa_account_id // "",
      .env.public_dataset.candidate_ttl_hours // ""] | @tsv' "$SPL_CNF")
  spl_pd_buckets_check "$staging" "$public" || return 1
  [[ "$said" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { do_log "FATAL cnf publish_sa_account_id of step 053 is unset for $ENV"; return 1; }
  [[ "$ttl" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL cnf public_dataset.candidate_ttl_hours is unset for $ENV"; return 1; }
  [[ "${PD_TOPIC:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL PD_TOPIC must be the dataset topic's lowercase task UUID"; return 1; }
  [[ -z "${PD_CANDIDATE:-}" || "$PD_CANDIDATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { do_log "FATAL PD_CANDIDATE must be <YYYY-MM-DD>-v<X.Y.Z>"; return 1; }
  _c[staging]="$staging" _c[public]="$public" _c[ttl]="$ttl" _c[topic]="$PD_TOPIC" _c[cand]="${PD_CANDIDATE:-}"
  _c[sa]="$said@$SPL_PROJECT.iam.gserviceaccount.com" _c[droprc]=0
  _c[tenant]="${TENANT_ID:-}" _c[agent]="${DESK_AGENT:-}" _c[box]="${DESK_BOX:-$(spl_desk_box_default)}"
}

# spl_pd_buckets_check <staging> <public>: both set, and never the same bucket.
spl_pd_buckets_check() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{2,62}$ ]] || { do_log "FATAL cnf staging_bucket_name of step 053 is unset for $ENV"; return 1; }
  [[ "$2" =~ ^[a-z0-9][a-z0-9._-]{2,62}$ ]] || { do_log "FATAL cnf public_bucket_name of step 053 is unset for $ENV"; return 1; }
  [[ "$1" != "$2" ]] || { do_log "FATAL the staging bucket is the public bucket: nothing private would stay private"; return 1; }
}

# spl_pd_gs <gcloud storage args>: every storage call of the publish and the
# take-down, pinned. Its stderr stays out of a public CI log.
spl_pd_gs() { gcloud storage "$@" --account="$GCP_ACCOUNT" 2>/dev/null; }

# spl_pd_gs_none <uri>: 0 only when gcloud answers that nothing is there. An
# outage or a refused listing is not that answer.
spl_pd_gs_none() {
  local rc=0 err
  err="$(gcloud storage ls "$1" --account="$GCP_ACCOUNT" 2>&1 >/dev/null)" || rc=$?
  (( rc != 0 )) && [[ "$err" == *"matched no objects"* ]]
}

# spl_pd_publish_candidates <assoc name> <scratch>: drops every candidate past
# the ttl, then settles P[cand]: the one asked for, else the newest left. A
# failed drop is reported through P[droprc]: it never blocks a good candidate.
spl_pd_publish_candidates() {
  local -n _d="$1"
  local h="$2" c ts sha base="gs://${_d[staging]}/candidates" now newest="" wanted="${_d[cand]}" dropped=0 asked=0
  now="$(date -u +%s)"
  while IFS= read -r c; do
    [[ "$c" == "$wanted" ]] && asked=1
    spl_pd_gs cat "$base/$c/spool-hub-public-$c.manifest.json" >"$h/m.json" || : >"$h/m.json"
    ts="$(jq -r '.exported_at // ""' "$h/m.json" 2>/dev/null)"
    sha="$(jq -r '.sha256 // ""' "$h/m.json" 2>/dev/null)"
    [[ -n "$ts" ]] || ts="${c%%-v*}T00:00:00Z"
    ts="$(date -u -d "$ts" +%s 2>/dev/null)" || ts=0
    if (( now - ts <= _d[ttl] * 3600 )); then newest="$c"; continue; fi
    spl_pd_publish_drop "$1" "$c" "$sha" || _d[droprc]=1
    [[ "$c" == "$wanted" ]] && dropped=1
  done < <(spl_pd_gs ls "$base/" | sed -nE 's|.*/candidates/([0-9]{4}-[0-9]{2}-[0-9]{2}-v[0-9]+\.[0-9]+\.[0-9]+)/$|\1|p' | sort -V)
  [[ -n "$wanted" ]] || { _d[cand]="$newest"; return 0; }
  (( dropped == 0 && asked == 1 )) && return 0
  local why=candidate-missing
  (( dropped )) && why=candidate-expired
  spl_pd_publish_note "$1" "public dataset candidate $wanted ($ENV): nothing published. Missing: $why"
  do_log "FAIL public dataset publish ($ENV): nothing published for $wanted. Missing: $why"
  return 1
}

# spl_pd_publish_drop <assoc name> <candidate> <sha256 or ""> : the candidate,
# its name lists and its verdicts leave staging. A published candidate stays in
# staging until here, so the note first asks the public bucket: routine cleanup
# of a published one posts nothing, and only a real "no" says not published.
spl_pd_publish_drop() {
  local -n _r="$1"
  local rc=0 c="$2" sha="$3" f="gs://${_r[public]}/daily/spool-hub-public-$2.sql.gz"
  spl_pd_gs rm --recursive "gs://${_r[staging]}/candidates/$c/" >/dev/null || rc=1
  [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]] || spl_pd_gs rm --recursive "gs://${_r[staging]}/verdicts/$sha/" >/dev/null || rc=1
  if (( rc )); then
    do_log "FATAL candidate $c is past candidate_ttl_hours and could NOT be dropped from staging (does ${_r[sa]} hold objects.delete there?): its name lists are still in staging, the bucket's lifecycle rule is the backstop"
    return 1
  fi
  do_log "INFO candidate $c is past candidate_ttl_hours: dropped with its name lists and verdicts"
  if spl_pd_gs ls "$f" >/dev/null; then
    do_log "INFO $c stays public at $f: only its staged copy went"
  elif spl_pd_gs_none "$f"; then
    spl_pd_publish_note "$1" "public dataset candidate $c ($ENV): dropped, older than candidate_ttl_hours and not published"
  else
    spl_pd_publish_note "$1" "public dataset candidate $c ($ENV): dropped, older than candidate_ttl_hours; whether it was published could not be read"
  fi
}

# spl_pd_publish_note <assoc name> <text>: a note on the dataset topic. A note
# that cannot be sent is a WARN: it never turns a refusal into a publish.
spl_pd_publish_note() {
  local -n _n="$1"
  local d
  d="$(spl_desk_dir "${_n[tenant]}" "${_n[box]}")" || [[ $? -eq 1 ]] || d=""
  spl_desk_spool "$d" "${_n[box]}" "${_n[tenant]}" "$SPL_HUB_URL" -- send --from "${_n[agent]}" --to ALL-0 \
    --to-box box-wui --task "${_n[topic]}" --kind note --body "$2" >/dev/null 2>&1 ||
    do_log "WARN the note on topic ${_n[topic]} could not be sent as ${_n[agent]} on ${_n[box]}"
}

# spl_pd_publish_missing <assoc name> <scratch> -> stdout: what is missing, as
# space-separated classes, empty when all of it holds. It leaves manifest.json,
# verdicts.json and the verified file in <scratch>.
spl_pd_publish_missing() {
  local -n _m="$1"
  local h="$2" name="spool-hub-public-${_m[cand]}" base="gs://${_m[staging]}" sha u d cls=() more=()
  if ! spl_pd_gs cat "$base/candidates/${_m[cand]}/$name.manifest.json" >"$h/manifest.json" ||
     ! jq -e --arg f "$name.sql.gz" --arg e "$ENV" '.file == $f and .source_env == $e and (.sha256 | test("^[0-9a-f]{64}$"))' "$h/manifest.json" >/dev/null 2>&1; then
    echo manifest; return 0
  fi
  sha="$(jq -r .sha256 "$h/manifest.json")"
  spl_pd_gs cp "$base/candidates/${_m[cand]}/$name.sql.gz" "$h/file.sql.gz" >/dev/null || { echo candidate-file; return 0; }
  [[ "$(sha256sum "$h/file.sql.gz" | cut -d' ' -f1)" == "$sha" ]] || cls+=(sha256-mismatch)
  spl_pd_publish_newer "$1" "$name.sql.gz" || cls+=(newer-published)
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    [[ "${u##*/}" =~ ^[a-z0-9_.-]+$ ]] && spl_pd_gs cp "$u" "$h/v/${u##*/}" >/dev/null || cls+=(verdict-unreadable)
  done < <(spl_pd_gs ls "$base/verdicts/$sha/")
  d="$(spl_desk_dir "${_m[tenant]}" "${_m[box]}")" || [[ $? -eq 1 ]] || d=""
  spl_desk_spool "$d" "${_m[box]}" "${_m[tenant]}" "$SPL_HUB_URL" -- hub-tail --task "${_m[topic]}" --json >"$h/tail.ndjson" 2>/dev/null ||
    { cls+=(hub-unreachable); : >"$h/tail.ndjson"; }
  mapfile -t more < <(spl_pd_publish_verdicts "$h/v" "$sha" "${_m[topic]}" "$h/tail.ndjson" "$h/verdicts.json" || echo verdict-check-failed)
  cls+=("${more[@]}")
  printf '%s\n' "${cls[@]}" | sed '/^$/d' | sort -u | paste -sd' ' -
}

# spl_pd_publish_newer <assoc name> <file name>: exit 1 when latest.json already
# names a file with a newer date and version than <file name>.
spl_pd_publish_newer() {
  local -n _w="$1"
  local cur
  cur="$(spl_pd_gs cat "gs://${_w[public]}/latest.json" | jq -r '.file // ""' 2>/dev/null)"
  [[ -n "$cur" && "$cur" != "$2" ]] || return 0
  [[ "$(printf '%s\n%s\n' "$cur" "$2" | sort -V | tail -1)" == "$2" ]]
}

# spl_pd_publish_verdicts <verdict dir> <sha256> <topic> <hub tail ndjson> <out>
# -> stdout: one class per failed condition of section 8.4. <out> gets the
# verdicts sorted by kind. It prints classes only, never a body or a detail.
spl_pd_publish_verdicts() {
  python3 - "$@" <<'EOF_PY'
import json, os, re, sys
vdir, sha, topic, tail, out = sys.argv[1:6]
PRE = {"agy": "a-", "grok": "g-", "claude": "c-"}
cls, vs = set(), []
bare = lambda x: str(x or "").split("@")[0]
for f in sorted(os.listdir(vdir)):
    try:
        v = json.load(open(os.path.join(vdir, f), encoding="utf-8"))
        if not isinstance(v, dict):
            raise ValueError
        vs.append((f, v))
    except ValueError:
        cls.add("verdict-unreadable")
msgs = {}
for line in open(tail, encoding="utf-8"):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and m.get("msg_id"):
        msgs[m["msg_id"]] = m
if len(vs) != 3:
    cls.add("verdict-count")
if sorted(str(v.get("lane_kind")) for _, v in vs) != sorted(PRE) or any(f != "%s.json" % v.get("lane_kind") for f, v in vs):
    cls.add("lane-kinds")
if len({bare(v.get("lane_id")) for _, v in vs}) != len(vs):
    cls.add("lane-id-duplicate")
for _, v in vs:
    pre = PRE.get(v.get("lane_kind"), "x-")
    if v.get("v") != 1:
        cls.add("verdict-schema")
    if not re.fullmatch(re.escape(pre) + r"[0-9]{3}(@[a-z0-9-]+)?", str(v.get("lane_id"))):
        cls.add("lane-id-prefix")
    if v.get("verdict") != "PASS":
        cls.add("verdict-not-pass")
    if v.get("file_sha256") != sha:
        cls.add("sha256-mismatch")
    m = msgs.get(v.get("hub_msg_id"))
    if m is None:
        cls.add("hub-msg-missing")
        continue
    if bare(m.get("from")) != bare(v.get("lane_id")):
        cls.add("hub-msg-sender")
    if m.get("task_id") != topic:
        cls.add("hub-msg-topic")
    body = str(m.get("body", ""))
    if sha not in body or set(re.findall(r"\b(?:PASS|FAIL)\b", body)) != {v.get("verdict")}:
        cls.add("hub-msg-content")
json.dump(sorted((v for _, v in vs), key=lambda v: str(v.get("lane_kind"))), open(out, "w", encoding="utf-8"), sort_keys=True)
print("\n".join(sorted(cls)))
EOF_PY
}

# spl_pd_publish_copy <assoc name> <scratch>: the file, the verdicts and the
# consolidated manifest under daily/, nothing overwritten; the object set
# proved; latest.json last. A name list is never in the copy list: the proof
# below is the check on that, not the reason for it.
spl_pd_publish_copy() {
  local -n _o="$1"
  local h="$2" name="spool-hub-public-${_o[cand]}" k src ptr sha at crc_src crc_pub
  local pub="gs://${_o[public]}/daily/$name" base="gs://${_o[staging]}"
  sha="$(jq -r .sha256 "$h/manifest.json")" at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _o[name]="$name" _o[sha]="$sha"
  src="$base/candidates/${_o[cand]}/$name.sql.gz"
  spl_pd_gs cp --no-clobber "$src" "$pub.sql.gz" >/dev/null || { do_log "FATAL cannot copy the file to $pub.sql.gz: latest.json not touched"; return 1; }
  crc_src="$(spl_pd_gs objects describe "$src" --format='value(crc32c_hash)')"
  crc_pub="$(spl_pd_gs objects describe "$pub.sql.gz" --format='value(crc32c_hash)')"
  [[ -n "$crc_src" && -n "$crc_pub" ]] ||
    { do_log "FATAL no crc32c to compare for $pub.sql.gz, so it is not proved the verified file: latest.json not touched"; return 1; }
  [[ "$crc_src" == "$crc_pub" ]] ||
    { do_log "FATAL $pub.sql.gz is not the verified file (a different file holds that name): latest.json not touched"; return 1; }
  for k in agy claude grok; do
    spl_pd_gs cp --no-clobber "$base/verdicts/$sha/$k.json" "$pub.verdicts/$k.json" >/dev/null ||
      { do_log "FATAL cannot copy the $k verdict: latest.json not touched"; return 1; }
  done
  jq --slurpfile v "$h/verdicts.json" --arg at "$at" '. + {verdicts: $v[0], published_at: $at}' "$h/manifest.json" >"$h/published.json" ||
    { do_log "FATAL cannot consolidate the manifest"; return 1; }
  spl_pd_gs cp --no-clobber "$h/published.json" "$pub.manifest.json" >/dev/null || { do_log "FATAL cannot write the manifest: latest.json not touched"; return 1; }
  [[ "$(spl_pd_gs cat "$pub.manifest.json" | jq -r '.sha256 // ""' 2>/dev/null)" == "$sha" ]] ||
    { do_log "FATAL the published manifest names another sha256: latest.json not touched"; return 1; }
  spl_pd_publish_prove "$1" || return 1
  ptr="$(jq -c '{v: 1, file: .file, object: ("daily/" + .file), manifest: ("daily/" + (.file | sub("\\.sql\\.gz$"; ".manifest.json"))),
    sha256: .sha256, version: .version, published_at: .published_at}' "$h/published.json")" || return 1
  spl_pd_latest_write "${_o[public]}" "$h" "$ptr"
}

# spl_pd_publish_prove <assoc name>: under this file's name exactly the five
# objects it copied, and no name list anywhere in the public bucket.
spl_pd_publish_prove() {
  local -n _v="$1"
  local all want got prefix="gs://${_v[public]}/daily/${_v[name]}"
  all="$(spl_pd_gs ls "gs://${_v[public]}/**")" || { do_log "FATAL cannot list the public bucket: no proof, latest.json not touched"; return 1; }
  if grep -qE '(^|/)names(/|\.tsv$|\.sha256$)' <<<"$all"; then
    do_log "FATAL a name list is in the public bucket (class name-list-public): latest.json not touched, take it down now"
    return 1
  fi
  want="$(printf '%s\n' "$prefix.manifest.json" "$prefix.sql.gz" "$prefix.verdicts/agy.json" "$prefix.verdicts/claude.json" "$prefix.verdicts/grok.json" | sort)"
  got="$(grep -F "$prefix." <<<"$all" | sort)"
  [[ "$got" == "$want" ]] || { do_log "FATAL the public objects of ${_v[name]} are not the five it copied (class public-object-set): latest.json not touched"; return 1; }
}

# spl_pd_latest_write <public bucket> <scratch> <json>: the one overwritten
# object, never cached.
spl_pd_latest_write() {
  printf '%s\n' "$3" >"$2/latest.json" || return 1
  spl_pd_gs cp --cache-control=no-cache "$2/latest.json" "gs://$1/latest.json" >/dev/null ||
    { do_log "FATAL cannot write gs://$1/latest.json"; return 1; }
}

# spl_pd_publish_drop_names <assoc name>: both name lists leave staging, and the
# listing proves it: only `ls` answering "no such objects" is proof. Reached
# after the publish, so a failure here says the file IS public.
spl_pd_publish_drop_names() {
  local -n _g="$1"
  local dir="gs://${_g[staging]}/candidates/${_g[cand]}/names" f
  for f in names.tsv names.sha256; do spl_pd_gs rm "$dir/$f" >/dev/null; done
  spl_pd_gs_none "$dir/" && return 0
  do_log "FATAL ${_g[name]} IS published, but its name lists could not be proved gone from $dir/ (does ${_g[sa]} hold objects.delete there?): the bucket's lifecycle rule is the backstop"
  return 1
}
