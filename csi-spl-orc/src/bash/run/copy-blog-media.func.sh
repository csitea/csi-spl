#!/bin/bash
#------------------------------------------------------------------------------
# @description The blog's picture copy (spec 111 T006b, Q4 (a), s111-3 change
# @description 10): a step of the WUI deploy (workflow 30), after nuxt generate
# @description and before firebase deploy. Reads the pictures the generated
# @description blog index names (.output/public/blog-md/index.json, every
# @description locale's `image`, plus its <id>-og crop of the same type when the
# @description bucket holds one; .webp, or .jpg for a picture a link preview
# @description such as LinkedIn must read as og:image) from the env's private
# @description picture bucket (iac step
# @description 054-gcs-blog-media, object key = the file name), and copies them
# @description into .output/public/blog/img/, so the site serves its own copy
# @description (CSP img-src 'self' unchanged). Also every `gallery` picture
# @description of an entry (SPL-3787, <id>-g<n>.webp or .jpg, the pictures the
# @description post page shows after its body); a gallery picture has no -og crop.
# @description Checks, in this order, before any copy:
# @description   1. the name is ^<post-id>(-og|-g[1-9])?\.(webp|jpg)$ for the entry naming it
# @description      (a key like ../x or $(...) never reaches gcloud)
# @description   2. the file is not empty
# @description   3. the file is at most 300 KB (307200 bytes, as T006's
# @description      do_spl_blog_image)
# @description   4. the file starts with the RIFF....WEBP magic bytes (a .jpg:
# @description      the FF D8 FF JPEG ones)
# @description Any failed check fails the action (rc 1), names each bad file
# @description and copies NOTHING. So does a named picture, or its <id>-og
# @description crop, that the bucket does not hold, and a bucket that cannot
# @description be listed (SPL-3546): the site answers a missing blog/img file
# @description with its HTML, so the post and its link preview show no
# @description picture. Until 2026-10-26 that was a WARN with rc 0, and
# @description 2026-10-25-the-ai-software-making-machine shipped without its
# @description picture on dev and prd. Put it first: do_spl_blog_media_put.
# @description A post that names no picture still ships (spec 111 5.4).
# @description No index, or no post with a picture: an INFO and rc 0.
# @description As the env's project service account (GCP_SA_KEY_FILE in CI),
# @description never the owner account.
# @param ENV - required: dev or prd
# @param BLOG_MEDIA_OUT (optional) - the generated site, default <wui>/.output/public
# @param GCP_SA_KEY_FILE / GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev GCP_SA_KEY_FILE="$GOOGLE_APPLICATION_CREDENTIALS" ./run -a do_copy_blog_media
#------------------------------------------------------------------------------
do_copy_blog_media() {
  spl_require_cloud_env || return 1
  do_require_bin jq gcloud || return 1
  local out="${BLOG_MEDIA_OUT:-$APP_PATH/csi-spl-wui/.output/public}"
  local index="$out/blog-md/index.json" cnf="$APP_PATH/csi-spl-cnf/csi-spl/$ENV.env.json"
  [[ -s "$index" ]] || { do_log "INFO no blog index at $index: no pictures to copy"; return 0; }

  local -a want=() bad=()
  local id img
  while IFS=$'\t' read -r id img; do
    if spl_blog_media_name_ok "$id" "$img"; then want+=("$img"); else bad+=("$img: not $id(-og).webp, $id(-og).jpg or $id-g<n>.webp"); fi
    # the header picture brings its -og crop; a gallery picture has none
    if [[ "$img" == "$id.webp" || "$img" == "$id.jpg" ]]; then want+=("$id-og.${img##*.}"); fi
  done < <(jq -r '.locales[]?[]? | . as $e | ([$e.image] + [($e.gallery // [])[].image]) | .[] | select(. != null) | [$e.id, .] | @tsv' "$index" | sort -u)
  ((${#bad[@]} == 0)) || { spl_blog_media_refuse "${bad[@]}"; return 1; }
  ((${#want[@]})) || { do_log "INFO no post names a picture: nothing to copy"; return 0; }

  local bucket
  bucket="$(jq -r '.env.steps."054-gcs-blog-media".media_bucket_name // ""' "$cnf" 2>/dev/null)"
  [[ -n "$bucket" ]] || { do_log "FATAL no env.steps.054-gcs-blog-media.media_bucket_name in $cnf"; return 1; }
  do_gcp_pin_account "$cnf" || return 1

  local stage have n
  stage="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'; trap - RETURN" RETURN
  have="$(gcloud storage ls "gs://$bucket/" --account="$GCP_ACCOUNT" 2>/dev/null)" ||
    { do_log "FATAL cannot list gs://$bucket as $GCP_ACCOUNT: the posts would ship without their pictures"; return 1; }
  have="$(sed "s|^gs://$bucket/||" <<<"$have")"
  local -a got=() miss=()
  for n in $(printf '%s\n' "${want[@]}" | sort -u); do
    if ! grep -qxF "$n" <<<"$have"; then miss+=("$n"); continue; fi
    gcloud storage cp "gs://$bucket/$n" "$stage/$n" --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      { do_log "FATAL cannot read gs://$bucket/$n"; return 1; }
    got+=("$n")
  done

  ((${#miss[@]} == 0)) || { spl_blog_media_missing "$bucket" "${miss[@]}"; return 1; }
  local why
  for n in "${got[@]}"; do
    why="$(spl_blog_media_check "$stage/$n")" || bad+=("$n: $why")
  done
  ((${#bad[@]} == 0)) || { spl_blog_media_refuse "${bad[@]}"; return 1; }
  ((${#got[@]})) || { do_log "INFO none of the named pictures is in gs://$bucket: nothing copied"; return 0; }
  mkdir -p "$out/blog/img" && cp "${got[@]/#/$stage/}" "$out/blog/img/" ||
    { do_log "FATAL copy into $out/blog/img failed"; return 1; }
  do_log "OK ${#got[@]} picture(s) copied from gs://$bucket to blog/img: ${got[*]}"
}

# spl_blog_media_name_ok <post-id> <image>: rc 0 when the image is
# <post-id>(-og).webp or <post-id>(-og).jpg, or a gallery picture
# <post-id>-g<1-9>.webp / .jpg, and the id is a post id
# (<yyyy-mm-dd>-<slug>, sync-blog.mjs ID_RE).
spl_blog_media_name_ok() {
  local id="$1" img="$2" ext
  [[ "$id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
  for ext in webp jpg; do
    [[ "$img" == "$id.$ext" || "$img" == "$id-og.$ext" ]] && return 0
    [[ "$img" == "$id-g"[1-9]".$ext" ]] && return 0
  done
  return 1
}

# spl_blog_media_check <file>: rc 0 for a non-empty RIFF/WEBP file (a *.jpg:
# a JPEG file) of at most 300 KB; else prints why and returns 1.
spl_blog_media_check() {
  local f="$1" size m
  size="$(stat -c %s "$f" 2>/dev/null)" || { echo "unreadable"; return 1; }
  ((size > 0)) || { echo "empty"; return 1; }
  ((size <= 307200)) || { echo "$size bytes, over the 300 KB limit (307200)"; return 1; }
  if [[ "$f" == *.jpg ]]; then
    [[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" == ffd8ff ]] || { echo "not a jpeg (no FF D8 FF magic bytes)"; return 1; }
    return 0
  fi
  m="$(head -c 12 "$f" | tr -c 'A-Z' '.')"
  [[ "${m:0:4}" == RIFF && "${m:8:4}" == WEBP ]] || { echo "not a webp (no RIFF/WEBP magic bytes)"; return 1; }
}

# spl_blog_media_missing <bucket> <name>...: one FATAL per picture the bucket
# lacks, then the total and how to put it.
spl_blog_media_missing() {
  local b="$1" n; shift
  for n in "$@"; do do_log "FATAL gs://$b holds no $n: its post would serve the site's HTML as that picture"; done
  do_log "FATAL $# blog picture(s) missing: nothing copied; put each with ENV=$ENV ./run -a do_spl_blog_media_put"
}

# spl_blog_media_refuse <line>...: one FATAL per bad picture, then the total.
spl_blog_media_refuse() {
  local b
  for b in "$@"; do do_log "FATAL blog picture refused: $b"; done
  do_log "FATAL $# bad blog picture(s): nothing copied"
}
