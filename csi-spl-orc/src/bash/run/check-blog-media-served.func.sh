#!/bin/bash
#------------------------------------------------------------------------------
# @description The served blog pictures (spec 111 section 4.3, SPL-3546): a
# @description step of the WUI deploy (workflow 30), after firebase deploy and
# @description its probe. Reads the served blog index
# @description (<site>/blog-md/index.json) and, for every post that names an
# @description `image`, asks for
# @description   1. its picture, <site>/blog/img/<image>
# @description   2. the og:image its page <site>/blog/<id> names (the picture a
# @description      link preview such as LinkedIn shows)
# @description Each must answer 200 with an image/* content type. Fails (rc 1)
# @description naming each post, URL, status and type otherwise, or when a page
# @description names no og:image. Why: the site answers any unknown path with
# @description its HTML (200 text/html), so a picture that never reached
# @description blog/img still answered 200 and a link preview showed no
# @description picture (2026-10-25-the-ai-software-making-machine, dev + prd,
# @description owner HUM-10 topic 1a494e58). No index, or no post with a
# @description picture: an INFO and rc 0. Reads only; changes nothing.
# @param BLOG_SITE_URL - required: the served site, e.g. https://<site>.web.app (no default)
# @param BLOG_SERVED_MAX_TIME (optional) - seconds per request, default 20
# @example BLOG_SITE_URL=https://<site>.web.app ./run -a do_check_blog_media_served
#------------------------------------------------------------------------------
do_check_blog_media_served() {
  : "${BLOG_SITE_URL:?BLOG_SITE_URL must be set (no default), e.g. https://<site>.web.app}"
  do_require_bin curl jq || return 1
  local site="${BLOG_SITE_URL%/}" index rows id img og u why n=0
  local -a bad=()
  index="$(spl_blog_served_get "$site/blog-md/index.json")" ||
    { do_log "INFO no blog index at $site/blog-md/index.json: no pictures to check"; return 0; }
  rows="$(jq -r '[.locales[]?[]? | select(.image != null) | [.id, .image]] | unique[] | @tsv' <<<"$index" 2>/dev/null)" ||
    { do_log "FATAL $site/blog-md/index.json is not the blog index"; return 1; }
  [[ -n "$rows" ]] || { do_log "INFO no post names a picture: nothing to check"; return 0; }
  while IFS=$'\t' read -r id img; do
    og="$(spl_blog_served_og "$site/blog/$id")" || { bad+=("$id: $site/blog/$id names no og:image"); og=""; }
    for u in "$site/blog/img/$img" ${og:+"$og"}; do
      n=$((n + 1))
      why="$(spl_blog_served_image "$u")" || bad+=("$id: $u answers $why, not an image")
    done
  done <<<"$rows"
  if ((${#bad[@]})); then
    for why in "${bad[@]}"; do do_log "FATAL blog picture not served: $why"; done
    do_log "FATAL ${#bad[@]} of the blog's pictures are not served as images on $site"
    return 1
  fi
  do_log "OK $n blog picture URL(s) on $site answer 200 image/* (each post's picture and its page's og:image)"
}

# spl_blog_served_get <url>: the body of a 200 answer, else rc 1.
spl_blog_served_get() {
  curl -fsS --max-time "${BLOG_SERVED_MAX_TIME:-20}" "$1" 2>/dev/null
}

# spl_blog_served_og <page url>: prints the page's og:image URL, else rc 1.
spl_blog_served_og() {
  local page meta
  page="$(spl_blog_served_get "$1")" || return 1
  meta="$(grep -m 1 -oE '<meta[^>]*property="og:image"[^>]*>' <<<"$page")"
  [[ "$meta" =~ content=\"([^\"]+)\" ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# spl_blog_served_image <url>: rc 0 when it answers 200 with an image/* type;
# else prints "<status> <type>" and returns 1.
spl_blog_served_image() {
  local got
  got="$(curl -sS -o /dev/null --max-time "${BLOG_SERVED_MAX_TIME:-20}" -w '%{http_code} %{content_type}' "$1" 2>/dev/null)"
  [[ "$got" =~ ^200\ image/ ]] && return 0
  echo "${got:-no answer}"
  return 1
}
