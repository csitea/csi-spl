#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Measure what do_warm_wui_edge buys (perf round 4, C7): the TTFB
# @description and x-cache a FIRST reader gets on a cold edge key, unwarmed vs
# @description warmed. A real deploy empties the edge; here each sample gets its
# @description own never-seen key instead (?edgewarm=<run>-<arm><i>), which the
# @description edge also has to fetch from origin, so the two arms can be
# @description INTERLEAVED per path on the same live deploy (box load moves
# @description both arms alike) with no deploy needed:
# @description   cold: reader GET of a fresh key                  (= before C7)
# @description   warm: warm GET of a fresh key, pause, reader GET (= after C7)
# @description Every GET uses the header a browser sends ("gzip, deflate, br,
# @description zstd": the edge keys on the raw Accept-Encoding).
# @description GENTLE: ONE request at a time with MEASURE_WUI_PAUSE between any
# @description two (a burst got one box's IP rate-limited by the CDN, and the
# @description measuring box may be the owner's desktop). The path list comes
# @description from do_warm_wui_edge's crawl at 1 worker, 2/s, capped.
# @description Reports per arm and class (document, /_nuxt): n, median TTFB
# @description (whole, and server-side = TTFB minus TLS connect) and HIT share;
# @description writes every sample as TSV.
# @param ENV (required unless MEASURE_WUI_URL) - dev|prd; host from cnf
# @param        env.dns.fqdn (see warm-wui-edge.func.sh)
# @param MEASURE_WUI_URL (optional) - base URL, overrides cnf
# @param MEASURE_WUI_ARMS (optional) - both (default, interleaved) | cold | warm
# @param MEASURE_WUI_N (optional) - /_nuxt files to sample, default 60; plus
# @param        up to MEASURE_WUI_DOCS documents (default 10)
# @param MEASURE_WUI_PAUSE (optional) - seconds between requests, default 0.5,
# @param        never below 0.2
# @param MEASURE_WUI_OUT (optional) - TSV path, default
# @param        $HOME/.cache/csi-spl/edge-warm/<env>-<utc>.tsv
# @example ENV=dev MEASURE_WUI_ARMS=both ./run -a do_measure_wui_edge_warm
#------------------------------------------------------------------------------

_MEASURE_WUI_ENC='gzip, deflate, br, zstd'

# _measure_wui_get <url> - one GET with the browser header; prints
# "<http_code>\t<ttfb_s>\t<server_ttfb_s>\t<x-cache>".
_measure_wui_get() {
  curl -sS -o /dev/null --max-time 30 -H "accept-encoding: $_MEASURE_WUI_ENC" \
    -w '%{http_code}\t%{time_starttransfer}\t%{time_appconnect}\t%header{x-cache}\n' "$1" 2>/dev/null \
    | awk -F'\t' '{ s = $2 - $3; if (s < 0) s = $2; printf "%s\t%s\t%.6f\t%s\n", $1, $2, s, ($4 == "" ? "-" : $4) }' \
    || printf '000\t0\t0\t-\n'
}

# _measure_wui_summary <tsv> - n, medians and HIT share per arm and class.
_measure_wui_summary() {
  python3 - "$1" <<'PY'
import csv, statistics, sys
rows = [r for r in csv.DictReader(open(sys.argv[1]), delimiter="\t") if r["step"] == "reader"]
print("| arm | class | n | median TTFB ms | median server TTFB ms | HIT |")
print("|---|---|---|---|---|---|")
for arm in ("cold", "warm"):
    for cls in ("document", "nuxt"):
        rs = [r for r in rows if r["arm"] == arm and r["class"] == cls and r["code"].startswith(("2", "3"))]
        if not rs:
            continue
        t = statistics.median(float(r["ttfb_s"]) for r in rs) * 1000
        s = statistics.median(float(r["server_ttfb_s"]) for r in rs) * 1000
        # the EDGE (last) entry: a shield lists itself first ("MISS, HIT")
        hit = sum(r["x_cache"].split(",")[-1].strip() == "HIT" for r in rs)
        print(f"| {arm} | {cls} | {len(rs)} | {t:.0f} | {s:.0f} | {hit}/{len(rs)} |")
PY
}

do_measure_wui_edge_warm() {
  local base="${MEASURE_WUI_URL:-}" arms="${MEASURE_WUI_ARMS:-both}" n="${MEASURE_WUI_N:-60}"
  local ndocs="${MEASURE_WUI_DOCS:-10}" pause="${MEASURE_WUI_PAUSE:-0.5}" out="${MEASURE_WUI_OUT:-}"
  local w run i p cls url line arm
  local -a todo
  command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
    || { do_log "FATAL curl and python3 are required"; return 1; }
  declare -F _warm_wui_edge_crawl >/dev/null || { do_log "FATAL warm-wui-edge.func.sh is not loaded"; return 1; }
  case "$arms" in both) todo=(cold warm) ;; cold|warm) todo=("$arms") ;;
    *) do_log "FATAL MEASURE_WUI_ARMS must be both, cold or warm, got '$arms'"; return 1 ;; esac
  [[ "$n" =~ ^[1-9][0-9]*$ && "$ndocs" =~ ^[0-9]+$ ]] || { do_log "FATAL MEASURE_WUI_N / MEASURE_WUI_DOCS must be integers"; return 1; }
  [[ "$pause" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v p="$pause" 'BEGIN { exit !(p >= 0.2) }' \
    || { do_log "FATAL MEASURE_WUI_PAUSE must be >= 0.2 s (one request at a time, paced), got '$pause'"; return 1; }
  if [[ -z "$base" ]]; then
    [[ -n "${ENV:-}" ]] || { do_log "FATAL ENV must be set (dev|prd), or MEASURE_WUI_URL"; return 1; }
    base=$(_warm_wui_edge_base_urls "$ENV") || return 1
  fi
  base="${base%/}"
  run=$(date -u +%Y%m%dT%H%M%SZ)
  [[ -n "$out" ]] || out="$HOME/.cache/csi-spl/edge-warm/${ENV:-url}-$run.tsv"
  mkdir -p "$(dirname "$out")"
  w=$(mktemp -d)
  # the crawl at 1 worker, 2/s, capped: enough paths to sample, no burst
  if ! WARM_WUI_PARALLEL=1 WARM_WUI_RATE=2/s WARM_WUI_MAX_FILES="${MEASURE_WUI_MAX_FILES:-$(( n * 4 + 80 ))}" \
       _warm_wui_edge_crawl "$base" "$w" >"$w/paths"; then rm -rf "${w:?}"; return 1; fi
  { grep -v '^/_nuxt/' "$w/paths" | head -n "$ndocs"; grep -E '^/_nuxt/.*\.(js|css)$' "$w/paths" | head -n "$n"; } >"$w/sample"
  do_log "INFO $base: sampling $(grep -vc '^/_nuxt/' "$w/sample") documents + $(grep -c '^/_nuxt/' "$w/sample") /_nuxt files, arms: ${todo[*]}, ${pause}s between requests -> $out"
  printf 'run\tarm\tstep\tclass\tpath\tcode\tttfb_s\tserver_ttfb_s\tx_cache\n' >"$out"
  i=0
  while IFS= read -r p; do
    i=$((i + 1))
    if [[ "$p" == /_nuxt/* ]]; then cls=nuxt; else cls=document; fi
    for arm in "${todo[@]}"; do
      url="$base$p?edgewarm=$run-${arm:0:1}$i"
      if [[ "$arm" == warm ]]; then
        line=$(_measure_wui_get "$url"); printf '%s\t%s\twarmer\t%s\t%s\t%s\n' "$run" "$arm" "$cls" "$p" "$line" >>"$out"
        sleep "$pause"
      fi
      line=$(_measure_wui_get "$url"); printf '%s\t%s\treader\t%s\t%s\t%s\n' "$run" "$arm" "$cls" "$p" "$line" >>"$out"
      sleep "$pause"
    done
  done <"$w/sample"
  rm -rf "${w:?}"
  _measure_wui_summary "$out"
  do_log "INFO samples: $out"
}
