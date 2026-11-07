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
# @description On a failure (SPL-4968) each line carries the answer's UTC time,
# @description host, CDN node, x-cache and last-modified, and the first failing
# @description URLs are re-asked as evidence, 10 s apart, 2 times. The check still
# @description fails whatever the re-asks say. It cannot read the `release
# @description complete` time: that line is earlier in the same job log.
# @param BLOG_SITE_URL - required: the served site, e.g. https://<site>.web.app (no default)
# @param BLOG_SERVED_MAX_TIME (optional) - seconds per request, default 20
# @param BLOG_SERVED_REASK_WAIT (optional) - seconds before each re-ask, default 10
# @param BLOG_SERVED_REASK_URLS (optional) - failing URLs to re-ask, the first ones, default 6
# @example BLOG_SITE_URL=https://<site>.web.app ./run -a do_check_blog_media_served
#------------------------------------------------------------------------------
do_check_blog_media_served() {
  : "${BLOG_SITE_URL:?BLOG_SITE_URL must be set (no default), e.g. https://<site>.web.app}"
  do_require_bin curl jq || return 1
  local site="${BLOG_SITE_URL%/}" index rows id img og u why n=0
  local -a bad=() ask=()
  index="$(spl_blog_served_get "$site/blog-md/index.json")" ||
    { do_log "INFO no blog index at $site/blog-md/index.json: no pictures to check"; return 0; }
  rows="$(jq -r '[.locales[]?[]? | select(.image != null) | [.id, .image]] | unique[] | @tsv' <<<"$index" 2>/dev/null)" ||
    { do_log "FATAL $site/blog-md/index.json is not the blog index"; return 1; }
  [[ -n "$rows" ]] || { do_log "INFO no post names a picture: nothing to check"; return 0; }
  while IFS=$'\t' read -r id img; do
    og="$(spl_blog_served_og "$site/blog/$id")" ||
      { bad+=("$id: $site/blog/$id names no og:image, answers $og"); ask+=("og $site/blog/$id"); og=""; }
    og="${og%%, page *}"
    for u in "$site/blog/img/$img" ${og:+"$og"}; do
      n=$((n + 1))
      why="$(spl_blog_served_image "$u")" || { bad+=("$id: $u answers $why, not an image"); ask+=("image $u"); }
    done
  done <<<"$rows"
  if ((${#bad[@]})); then
    for why in "${bad[@]}"; do do_log "FATAL blog picture not served: $why"; done
    if spl_blog_served_reask "${ask[@]}"; then
      do_log "INFO every re-asked URL answers right on the last re-ask; the check still fails on the first answer"
    fi
    do_log "FATAL ${#bad[@]} of the blog's pictures are not served as images on $site"
    return 1
  fi
  do_log "OK $n blog picture URL(s) on $site answer 200 image/* (each post's picture and its page's og:image)"
}

# spl_blog_served_get <url>: the body of a 200 answer, else rc 1.
spl_blog_served_get() {
  curl -fsS --max-time "${BLOG_SERVED_MAX_TIME:-20}" "$1" 2>/dev/null
}

# spl_blog_served_answer <url> [body file]: asks once; prints "<status> <type>
# (at <utc>, host <host>[, node <x-served-by>][, x-cache <v>][, last-modified <v>][, curl rc <n>])".
spl_blog_served_answer() {
  local raw at host h v extra="" crc=0
  raw="$(curl -sS -o "${2:-/dev/null}" -D - --max-time "${BLOG_SERVED_MAX_TIME:-20}" -w '%{http_code} %{content_type}' "$1" 2>/dev/null)" || crc=$?
  at="$(date -u +%FT%TZ)"
  host="${1#*://}"; host="${host%%/*}"
  for h in x-served-by x-cache last-modified; do
    v="$(awk -v h="$h:" 'tolower($1) == h { sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print; exit }' <<<"$raw")"
    [[ -n "$v" ]] && extra+=", ${h/x-served-by/node} $v"
  done
  ((crc == 0)) || extra+=", curl rc $crc"
  echo "$(tail -n 1 <<<"$raw") (at $at, host $host$extra)"
}

# spl_blog_served_og <page url>: rc 0 and "<og:image URL>, page <answer>"; else
# rc 1 and the page's answer. A page curl failed on is no page, even with the
# og:image in the part that arrived.
spl_blog_served_og() {
  local body got meta
  body="$(mktemp)"
  got="$(spl_blog_served_answer "$1" "$body")"
  meta="$(grep -m 1 -oE '<meta[^>]*property="og:image"[^>]*>' "$body" || true)"
  rm -f "$body"
  if [[ "$got" =~ ^200\  && "$got" != *", curl rc "* && "$meta" =~ content=\"([^\"]+)\" ]]; then echo "${BASH_REMATCH[1]}, page $got"; return 0; fi
  echo "$got"
  return 1
}

# spl_blog_served_image <url>: prints its answer; rc 0 when that is 200 image/*.
spl_blog_served_image() {
  local got
  got="$(spl_blog_served_answer "$1")"
  echo "$got"
  [[ "$got" =~ ^200\ image/ ]] && return 0
  return 1
}

# spl_blog_served_reask <"image|og url">...: evidence only, never a verdict. Asks
# each failing URL again, 2 rounds, logging every answer. rc 0 when all answered
# right in the last round. Longest: 2 waits + 2 rounds x the URLs x MAX_TIME.
spl_blog_served_reask() {
  local wait="${BLOG_SERVED_REASK_WAIT:-10}" max="${BLOG_SERVED_REASK_URLS:-6}" round e got left=0
  local -a asks=("$@")
  if (($# > max)); then
    do_log "INFO re-asking the first $max of the $# failing URLs"
    asks=("${asks[@]:0:max}")
  fi
  for round in 1 2; do
    sleep "$wait"
    left=0
    for e in "${asks[@]}"; do
      if got="$("spl_blog_served_${e%% *}" "${e#* }")"; then
        do_log "INFO re-ask $round of 2: ${e#* } right: $got"
      else
        left=$((left + 1))
        do_log "INFO re-ask $round of 2: ${e#* } still wrong: $got"
      fi
    done
  done
  ((left == 0)) && return 0
  return 1
}
