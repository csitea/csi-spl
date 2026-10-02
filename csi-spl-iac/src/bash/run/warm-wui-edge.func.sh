#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Warm the CDN edge after a WUI deploy (perf round 4, C7; round 3
# @description P3-08). A Hosting deploy empties the edge cache, so the first
# @description reader of each document and /_nuxt file pays the origin fetch
# @description (round 3: document 222 ms MISS vs 21 ms HIT). This fetches every
# @description prerendered document and every /_nuxt file it reaches ONCE per
# @description cache key, so readers behind the same POP start on a HIT.
# @description The edge keys on the RAW Accept-Encoding header (measured
# @description 2026-10-03, n=3: a HIT for "br" is a MISS for "gzip, deflate,
# @description br, zstd"), so each URL is fetched once per header a browser
# @description really sends, never once per encoding name.
# @description It warms only the POPs the host running it reaches.
# @description Documents: "/" and "/login" plus each locale's copy, read from the
# @description deployed "/" itself (its locales:[...] list), so the set follows
# @description the deploy, not this file. Files: the /_nuxt refs in those
# @description documents, then every "./<chunk>" a fetched /_nuxt file names,
# @description plus /_nuxt/builds/latest.json and meta/<buildId>.json. A /_nuxt
# @description ref answered with HTML (the SPA fallback: the file is not there)
# @description is named and skipped.
# @description GENTLE BY DESIGN: a CDN that sees a burst of new connections
# @description rate-limits the IP (measured 2026-10-03: ~1000 GETs at 8 in
# @description parallel from one box, then most connects timed out). Each worker
# @description is ONE curl on one kept-alive connection, paced by --rate; at most
# @description 2 workers. Read-only GETs, no credentials.
# @param ENV (required unless WARM_WUI_URLS) - dev|prd; the host is cnf
# @param        env.dns.fqdn in csi-spl-cnf/csi-spl/<env>.env.json, so no
# @param        host literal lives here
# @param WARM_WUI_URLS (optional) - space-separated base URLs, overrides cnf
# @param WARM_WUI_ENCODINGS (optional) - '|'-separated Accept-Encoding values;
# @param        default: Chrome/Firefox/Edge ("gzip, deflate, br, zstd") and
# @param        Safari ("gzip, deflate, br")
# @param WARM_WUI_PARALLEL (optional) - workers, 1 or 2, default 2
# @param WARM_WUI_RATE (optional) - curl --rate per worker, default 4/s
# @param WARM_WUI_MAX_FILES (optional) - crawl cap per host, default 2000
# @example ENV=dev ./run -a do_warm_wui_edge
# @example WARM_WUI_URLS=https://<<run-time>>.csitea.net ./run -a do_warm_wui_edge
#------------------------------------------------------------------------------

_WARM_WUI_DEFAULT_ENCODINGS='gzip, deflate, br, zstd|gzip, deflate, br'

# _warm_wui_edge_base_urls <env> - https://<env.dns.fqdn> from cnf.
_warm_wui_edge_base_urls() {
  local cnf="${WARM_WUI_CNF_DIR:-${APP_PATH:-}/csi-spl-cnf/csi-spl}/$1.env.json"
  [[ -f "$cnf" ]] || { do_log "FATAL no cnf $cnf for ENV=$1" >&2; return 1; }
  python3 -c 'import json,sys; print("https://" + json.load(open(sys.argv[1]))["env"]["dns"]["fqdn"])' "$cnf"
}

# _warm_wui_edge_check_knobs - refuse a parallelism or rate that could get the
# running host's IP rate-limited by the CDN.
_warm_wui_edge_check_knobs() {
  local par="${WARM_WUI_PARALLEL:-2}" rate="${WARM_WUI_RATE:-4/s}"
  [[ "$par" =~ ^[12]$ ]] || { do_log "FATAL WARM_WUI_PARALLEL must be 1 or 2 (a burst gets the IP rate-limited), got '$par'"; return 1; }
  [[ "$rate" =~ ^[1-9][0-9]?/(s|m)$ ]] || { do_log "FATAL WARM_WUI_RATE must look like 4/s (at most 99/s), got '$rate'"; return 1; }
}

# _warm_wui_edge_documents <index-html-file> - document paths, one per line:
# "/" and "/login", and "/<code>" + "/<code>/login" for every locale the
# document lists except its defaultLocale (i18n prefix_except_default).
_warm_wui_edge_documents() {
  local html="$1" codes def c
  printf '/\n/login\n'
  codes=$(grep -oE 'locales:\[("[A-Za-z-]+",?)+\]' "$html" | head -1 | grep -oE '"[A-Za-z-]+"' | tr -d '"')
  def=$(grep -oE 'defaultLocale:"[A-Za-z-]+"' "$html" | head -1 | cut -d'"' -f2)
  for c in $codes; do
    [[ "$c" == "$def" ]] && continue
    printf '/%s\n/%s/login\n' "$c" "$c"
  done
}

# _warm_wui_edge_refs <file> - the /_nuxt paths a document or /_nuxt file
# names: absolute /_nuxt/... refs, "./x" and url(./x) siblings (vite chunk
# imports and CSS assets sit beside their importer in /_nuxt/), and the
# build meta of a document's buildId.
_warm_wui_edge_refs() {
  local f="$1" ext='(js|mjs|css|json|woff2?|ttf|svg|png|webp|ico)'
  {
    grep -oE "/_nuxt/[A-Za-z0-9._/-]+\.$ext" "$f"
    grep -oE "[\"'(]\./[A-Za-z0-9._-]+\.$ext" "$f" | sed 's#^.\./#/_nuxt/#'
    grep -oE 'buildId:"[A-Za-z0-9-]+"' "$f" | head -1 | cut -d'"' -f2 | sed 's#^#/_nuxt/builds/meta/#; s#$#.json#'
  } | sort -u
}

# _warm_wui_edge_cfg_quote <s> - a curl config string literal.
_warm_wui_edge_cfg_quote() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }

# _warm_wui_edge_curl <cfg-prefix> <out> - run each curl config file
# <cfg-prefix>.<n> as one serial curl paced by WARM_WUI_RATE (one kept-alive
# connection), the files side by side, and append every transfer's
# write-out line to <out>.
_warm_wui_edge_curl() {
  local pre="$1" out="$2" rate="${WARM_WUI_RATE:-4/s}" f
  local -a pids=()
  for f in "$pre".[0-9]; do
    [[ -s "$f" ]] || continue
    curl -sS --rate "$rate" --max-time 30 --config "$f" >"$f.out" 2>/dev/null &
    pids+=("$!")
  done
  (( ${#pids[@]} )) && wait "${pids[@]}"
  for f in "$pre".[0-9].out; do [[ -f "$f" ]] && cat "$f" >>"$out"; done
  return 0
}

# _warm_wui_edge_crawl <base> <workdir> - every live document and /_nuxt path,
# one per line, breadth first from the deployed documents. Bodies come with
# curl's own --compressed header, which is not a browser's: the crawl only
# discovers, the fetch pass warms.
_warm_wui_edge_crawl() {
  local base="$1" w="$2" max="${WARM_WUI_MAX_FILES:-2000}" par="${WARM_WUI_PARALLEL:-2}"
  local level=0 i p code ctype
  curl -fsS --compressed --max-time 30 "$base/" -o "$w/index.html" \
    || { do_log "FATAL $base/ unreachable" >&2; return 1; }
  { _warm_wui_edge_documents "$w/index.html"; echo /_nuxt/builds/latest.json; } | sort -u >"$w/frontier"
  : >"$w/seen"; : >"$w/live"; : >"$w/dead"
  while [[ -s "$w/frontier" ]]; do
    sort -u "$w/seen" "$w/frontier" -o "$w/seen"
    if (( $(wc -l <"$w/seen") > max )); then
      do_log "WARN $base: crawl cap WARM_WUI_MAX_FILES=$max reached" >&2; break
    fi
    level=$((level + 1)); mkdir "$w/b.$level"
    i=0
    while IFS= read -r p; do
      {
        echo "next"
        echo "compressed"
        echo "url = $(_warm_wui_edge_cfg_quote "$base$p")"
        echo "output = $(_warm_wui_edge_cfg_quote "$w/b.$level/$i")"
        echo "write-out = \"%{http_code}\\t%{content_type}\\t$i\\t$p\\n\""
      } >>"$w/crawl.$((i % par))"
      i=$((i + 1))
    done <"$w/frontier"
    : >"$w/scan"
    _warm_wui_edge_curl "$w/crawl" "$w/scan"
    rm -f "$w"/crawl.*
    : >"$w/found"
    while IFS=$'\t' read -r code ctype i p; do
      if [[ "$code" != 2* || ( "$p" == /_nuxt/* && "$ctype" == text/html* ) ]]; then
        echo "$p" >>"$w/dead"; continue
      fi
      echo "$p" >>"$w/live"
      case "$ctype" in *html*|*javascript*|*css*) _warm_wui_edge_refs "$w/b.$level/$i" >>"$w/found" ;; esac
    done <"$w/scan"
    rm -rf "${w:?}/b.$level"
    sort -u "$w/found" | comm -23 - "$w/seen" >"$w/frontier"
  done
  if [[ -s "$w/dead" ]]; then
    do_log "WARN $base: $(sort -u "$w/dead" | wc -l) referenced path(s) are not there (SPA fallback or error), skipped: $(sort -u "$w/dead" | head -5 | paste -sd' ')" >&2
  fi
  sort -u "$w/live"
}

# _warm_wui_edge_fetch_cfg <base> <paths-file> <cfg-prefix> [<query>] - curl
# configs that GET every path once per WARM_WUI_ENCODINGS header, round-robin
# over WARM_WUI_PARALLEL workers. Write-out per transfer:
# "<http_code> <ttfb_s> <x-cache> <url> [<accept-encoding>]".
_warm_wui_edge_fetch_cfg() {
  local base="$1" paths="$2" pre="$3" q="${4:-}" par="${WARM_WUI_PARALLEL:-2}" i=0 p e
  local -a el
  IFS='|' read -ra el <<<"${WARM_WUI_ENCODINGS:-$_WARM_WUI_DEFAULT_ENCODINGS}"
  while IFS= read -r p; do
    for e in "${el[@]}"; do
      {
        echo "next"
        echo "url = $(_warm_wui_edge_cfg_quote "$base$p$q")"
        echo "header = $(_warm_wui_edge_cfg_quote "accept-encoding: $e")"
        echo "output = \"/dev/null\""
        echo "write-out = \"%{http_code} %{time_starttransfer} %header{x-cache} %{url} [$e]\\n\""
      } >>"$pre.$((i % par))"
      i=$((i + 1))
    done
  done <"$paths"
}

do_warm_wui_edge() {
  local urls="${WARM_WUI_URLS:-}" base w rc=0 n bad miss keys
  command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
    || { do_log "FATAL curl and python3 are required"; return 1; }
  _warm_wui_edge_check_knobs || return 1
  if [[ -z "$urls" ]]; then
    [[ -n "${ENV:-}" ]] || { do_log "FATAL ENV must be set (dev|prd), or WARM_WUI_URLS"; return 1; }
    urls=$(_warm_wui_edge_base_urls "$ENV") || return 1
  fi
  keys=$(awk -F'|' '{print NF}' <<<"${WARM_WUI_ENCODINGS:-$_WARM_WUI_DEFAULT_ENCODINGS}")
  for base in $urls; do
    base="${base%/}"
    w=$(mktemp -d)
    if ! _warm_wui_edge_crawl "$base" "$w" >"$w/paths"; then rc=1; rm -rf "${w:?}"; continue; fi
    _warm_wui_edge_fetch_cfg "$base" "$w/paths" "$w/warm"
    : >"$w/out"
    _warm_wui_edge_curl "$w/warm" "$w/out"
    n=$(wc -l <"$w/out")
    bad=$(awk '$1 !~ /^[23]/' "$w/out" | wc -l)
    miss=$(awk '$3 == "MISS"' "$w/out" | wc -l)
    do_log "INFO $base: $(wc -l <"$w/paths") paths x $keys encodings = $n fetches; $miss were cold (MISS) and are now warm, $bad failed"
    awk '$1 !~ /^[23]/ {print "  failed: " $0}' "$w/out" | head -20
    # A broken host is a red warm; a few stray refs are logged, not fatal.
    if (( n == 0 || bad * 10 > n )); then do_log "ERROR $base: $bad of $n fetches failed"; rc=1; fi
    rm -rf "${w:?}"
  done
  return "$rc"
}
