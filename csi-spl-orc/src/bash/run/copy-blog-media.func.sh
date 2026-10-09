#!/bin/bash
#------------------------------------------------------------------------------
# @description The blog's picture copy (spec 111 T006b, Q4 (a), s111-3 change
# @description 10): a step of the WUI deploy (workflow 30), after nuxt generate
# @description and before firebase deploy. Reads the pictures the generated
# @description blog index names (.output/public/blog-md/index.json, every
# @description locale's `image`, plus its <id>-og.webp crop when the bucket
# @description holds one) from the env's private picture bucket (iac step
# @description 054-gcs-blog-media, object key = the file name), and copies them
# @description into .output/public/blog/img/, so the site serves its own copy
# @description (CSP img-src 'self' unchanged).
# @description Checks, in this order, before any copy:
# @description   1. the name is ^<post-id>(-og)?\.webp$ for the entry naming it
# @description      (a key like ../x or $(...) never reaches gcloud)
# @description   2. the file is not empty
# @description   3. the file is at most 300 KB (307200 bytes, as T006's
# @description      do_spl_blog_image)
# @description   4. the file starts with the RIFF....WEBP magic bytes
# @description Any failed check fails the action (rc 1), names each bad file
# @description and copies NOTHING. A picture the bucket does not hold is a
# @description WARN and is skipped: pictures never block a post (s111-4).
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
    if spl_blog_media_name_ok "$id" "$img"; then want+=("$img"); else bad+=("$img: not $id.webp or $id-og.webp"); fi
  done < <(jq -r '.locales[]?[]? | select(.image != null) | [.id, .image] | @tsv' "$index" | sort -u)
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
    { do_log "WARN cannot list gs://$bucket as $GCP_ACCOUNT: the site ships without pictures"; return 0; }
  have="$(sed "s|^gs://$bucket/||" <<<"$have")"
  for n in "${want[@]}"; do
    [[ "$n" == *-og.webp ]] || want+=("${n%.webp}-og.webp")
  done
  local -a got=()
  for n in $(printf '%s\n' "${want[@]}" | sort -u); do
    if ! grep -qxF "$n" <<<"$have"; then
      [[ "$n" == *-og.webp ]] || do_log "WARN gs://$bucket holds no $n: that post ships without its picture"
      continue
    fi
    gcloud storage cp "gs://$bucket/$n" "$stage/$n" --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      { do_log "FATAL cannot read gs://$bucket/$n"; return 1; }
    got+=("$n")
  done

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
# <post-id>.webp or <post-id>-og.webp and the id is a post id
# (<yyyy-mm-dd>-<slug>, sync-blog.mjs ID_RE).
spl_blog_media_name_ok() {
  local id="$1" img="$2"
  [[ "$id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
  [[ "$img" == "$id.webp" || "$img" == "$id-og.webp" ]]
}

# spl_blog_media_check <file>: rc 0 for a non-empty RIFF/WEBP file of at most
# 300 KB; else prints why and returns 1.
spl_blog_media_check() {
  local f="$1" size m
  size="$(stat -c %s "$f" 2>/dev/null)" || { echo "unreadable"; return 1; }
  ((size > 0)) || { echo "empty"; return 1; }
  ((size <= 307200)) || { echo "$size bytes, over the 300 KB limit (307200)"; return 1; }
  m="$(head -c 12 "$f" | tr -c 'A-Z' '.')"
  [[ "${m:0:4}" == RIFF && "${m:8:4}" == WEBP ]] || { echo "not a webp (no RIFF/WEBP magic bytes)"; return 1; }
}

# spl_blog_media_refuse <line>...: one FATAL per bad picture, then the total.
spl_blog_media_refuse() {
  local b
  for b in "$@"; do do_log "FATAL blog picture refused: $b"; done
  do_log "FATAL $# bad blog picture(s): nothing copied"
}
