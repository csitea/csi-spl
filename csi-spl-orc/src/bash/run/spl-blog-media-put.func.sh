#!/bin/bash
#------------------------------------------------------------------------------
# @description Put ONE blog picture into the env's private blog-media bucket
# @description (spec 111, iac step 054) and prove it landed byte for byte.
# @description
# @description Every local check runs BEFORE any gcloud call, so a bad file or
# @description a bad name never reaches `gcloud storage cp`:
# @description   - the file is a RIFF....WEBP file (magic bytes, not the suffix)
# @description   - it is not empty and not over 300 KB (307200 bytes)
# @description   - the object name is YYYY-MM-DD-<slug>.webp (an -og slug too),
# @description     so a key like `../x` or `$(...)` is refused here
# @description The bucket is cnf env.steps."054-gcs-blog-media".media_bucket_name,
# @description never a literal. The identity is the per-env project SA
# @description (do_gcp_pin_account: private CLOUDSDK_CONFIG, --account on every
# @description call), never the owner account.
# @description
# @description An object already there with the SAME sha256 is OK and is not
# @description written again; with ANOTHER sha256 it is refused unless
# @description BLOG_IMG_REPLACE=1. After the put the object is read back and
# @description its sha256 must equal the source's: the read-back is the
# @description verdict, not the exit code of the upload.
# @param ENV - required: dev or prd
# @param BLOG_IMG_SRC - required: the local .webp file
# @param BLOG_IMG_NAME - required: the object name, e.g. 2026-10-09-hello-world.webp
# @param DRY_RUN (optional) - default 1: checks and reads only, writes nothing
# @param BLOG_IMG_REPLACE (optional) - 1 overwrites an object with another sha256
# @example ENV=dev BLOG_IMG_SRC=/tmp/x.webp BLOG_IMG_NAME=2026-10-09-hello-world.webp ./run -a do_spl_blog_media_put
# @example ENV=prd BLOG_IMG_SRC=/tmp/x.webp BLOG_IMG_NAME=2026-10-09-hello-world.webp DRY_RUN=0 ./run -a do_spl_blog_media_put
#------------------------------------------------------------------------------
do_spl_blog_media_put() {
  local src="${BLOG_IMG_SRC:-}" name="${BLOG_IMG_NAME:-}" sha bucket uri rc=0
  spl_require_cloud_env || return 1
  spl_blog_media_check "$src" "$name" || return 2
  sha="$(sha256sum <"$src" | awk '{print $1}')"

  do_require_bin gcloud yq sha256sum || return 1
  do_spl_cloud_cnf || return 1
  bucket="$(spl_blog_media_bucket)" || return 1
  uri="gs://$bucket/$name"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  do_log "INFO $ENV: $src ($(stat -c %s "$src") bytes, sha256 $sha) -> $uri"

  local work
  work="$(mktemp -d)" || return 1
  spl_blog_media_put_verified "$src" "$uri" "$sha" "$work" || rc=$?
  rm -rf "$work"
  return $rc
}

# spl_blog_media_put_verified <src> <uri> <sha256> <work dir>: the gcloud half.
# 0 = the object holds <sha256> (or DRY_RUN=1 and it would be put);
# 3 = an object with another sha256 is there; 4 = read-back mismatch.
spl_blog_media_put_verified() {
  local src="$1" uri="$2" sha="$3" work="$4" have
  have="$(spl_blog_media_remote_sha "$uri" "$work/existing")" || return 1
  if [[ "$have" == "$sha" ]]; then
    do_log "OK $ENV $uri sha256=$sha (already there, not written again)"
    return 0
  fi
  if [[ -n "$have" && "${BLOG_IMG_REPLACE:-0}" != 1 ]]; then
    do_log "FATAL $ENV: $uri already holds sha256 $have, not $sha; BLOG_IMG_REPLACE=1 overwrites it"
    return 3
  fi
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO $ENV: DRY_RUN=1, nothing written: would put $uri${have:+ (replacing sha256 $have)}; DRY_RUN=0 puts it"
    return 0
  fi
  gcloud storage cp "$src" "$uri" --content-type=image/webp --account="$GCP_ACCOUNT" >/dev/null 2>"$work/put.err" ||
    { do_log "FATAL $ENV: cannot put $uri: $(tail -n 2 "$work/put.err" | tr '\n' ' ')"; return 1; }
  have="$(spl_blog_media_remote_sha "$uri" "$work/readback")" || return 1
  [[ "$have" == "$sha" ]] ||
    { do_log "FATAL $ENV: read-back of $uri is sha256 '${have:-<none>}', the source is $sha"; return 4; }
  do_log "OK $ENV $uri sha256=$sha"
}

# spl_blog_media_check <src> <name>: every local refusal, with its reason, and
# no gcloud call. The magic bytes decide the type: a PNG named .webp is refused.
spl_blog_media_check() {
  local src="$1" name="$2" size
  [[ -n "$src" ]] || { do_log "FATAL BLOG_IMG_SRC is required (the local .webp file)"; return 1; }
  [[ -f "$src" && -r "$src" ]] || { do_log "FATAL BLOG_IMG_SRC $src is not a readable file"; return 1; }
  [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*\.webp$ ]] ||
    { do_log "FATAL BLOG_IMG_NAME '$name' must be YYYY-MM-DD-<slug>.webp or YYYY-MM-DD-<slug>-og.webp (slug: a-z, 0-9, -)"; return 1; }
  size="$(stat -c %s "$src")"
  (( size > 0 )) || { do_log "FATAL $src is empty"; return 1; }
  (( size <= 307200 )) || { do_log "FATAL $src is $size bytes, over the 300 KB (307200 bytes) limit"; return 1; }
  [[ "$(head -c 4 "$src")" == RIFF && "$(dd if="$src" bs=1 skip=8 count=4 2>/dev/null)" == WEBP ]] ||
    { do_log "FATAL $src is not a webp: its first bytes are not RIFF....WEBP"; return 1; }
}

# spl_blog_media_bucket -> the env's 054 bucket from the effective cnf, or a
# refusal. Never a guessed name.
spl_blog_media_bucket() {
  local b
  b="$(yq -r '.env.steps."054-gcs-blog-media".media_bucket_name // ""' "$SPL_CNF")"
  [[ -n "$b" && "$b" != null ]] ||
    { do_log "FATAL cnf env.steps.\"054-gcs-blog-media\".media_bucket_name is empty for $ENV" >&2; return 1; }
  printf '%s' "$b"
}

# spl_blog_media_remote_sha <uri> <local file> -> the sha256 of the object, read
# back into <local file>; empty output and 0 when there is no such object; 1
# when gcloud fails for any other reason (a refusal is never read as "absent").
spl_blog_media_remote_sha() {
  local uri="$1" out="$2" err
  err="$(gcloud storage ls "$uri" --account="$GCP_ACCOUNT" 2>&1 >/dev/null)" || {
    [[ "$err" == *"matched no objects"* ]] && return 0
    do_log "FATAL $ENV: cannot list $uri: $(tail -n 2 <<<"$err" | tr '\n' ' ')" >&2
    return 1
  }
  gcloud storage cp "$uri" "$out" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { do_log "FATAL $ENV: cannot read back $uri" >&2; return 1; }
  sha256sum <"$out" | awk '{print $1}'
}
