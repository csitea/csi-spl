#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_blog_media_served (spec 111 4.3, SPL-3546), hermetic: a
#          stubbed curl serves a map of URL -> status, type, body.
#   1. every post's picture and its page's og:image answer 200 image/*: rc 0
#   2. a picture or og:image the site answers with its HTML (200 text/html,
#      the 2026-10-25 bug), a 404, or a page with no og:image: rc 1, each
#      post and URL named
#   3. no index / no post with a picture: rc 0; BLOG_SITE_URL unset: refused
#   4. CONTROL: a copy of the action whose type check accepts any 200 lets
#      the HTML picture through (red)
#   5. wf 30 runs it after the deploy probe, on the deployed site
#   6. SPL-4968: a failing answer logs its time, host and CDN node; each failing
#      URL is re-asked 2 times, 10 s apart, as evidence; a picture that clears
#      on the re-ask still reds the check. CONTROL: a copy that turns the
#      cleared re-ask into a pass goes green (red)
#   7. a page cut off after its og:image (curl fails on a 200) still reds the
#      check, as `curl -f` did, with curl's rc logged. CONTROL: a copy that
#      ignores the rc goes green (red)
#   8. R7 on 2116b7c1c: an og:image URL holding ", page " is asked whole; a header
#      holding it is a false red, never a green; a page answering anything but
#      200 fails even with its og:image; no ask carries --retry. CONTROL for each
#      (red)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ACTION="$PROJ_ROOT/src/bash/run/check-blog-media-served.func.sh"
W30="$APP_ROOT/.github/workflows/30_wui-build-deploy.yml"
SITE="https://site.example.com"
ID="2026-10-09-first-light"
MAP="$T/map"
mkdir -p "$T/stub" "$T/body"

# stub curl: the last argument is the URL; its $MAP line "<url> <code> <type>
# [body]" answers, or from its 2nd ask on its "$MAP.then" line if it has one.
# -w prints "<code> <type>" after the -D headers ($MAP.node "<url> <node>"), and
# the body goes to -o, and curl exits with its "$MAP.crc" line "<url> <rc>";
# otherwise the body ($T/body/<n>) on a 200 goes to stdout,
# exit 22 (as -f) on anything else.
cat >"$T/stub/curl" <<'SH'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
url="${!#}" w=0 out="" prev=""
for a in "$@"; do
  [[ "$a" == -w ]] && w=1
  [[ "$prev" == -o ]] && out="$a"
  prev="$a"
done
line="$(awk -v u="$url" '$1 == u { print; exit }' "$MAP")"
asks="$(awk -v u="$url" '$NF == u { n++ } END { print n + 0 }' "$STUB_LOG")"
if ((asks > 1)) && [[ -f "$MAP.then" ]]; then
  then_line="$(awk -v u="$url" '$1 == u { print; exit }' "$MAP.then")"
  [[ -n "$then_line" ]] && line="$then_line"
fi
[[ -n "$line" ]] || line="- 200 text/html;charset=utf-8"
read -r _ code type body <<<"$line"
if ((w)); then
  node="$(awk -v u="$url" '$1 == u { sub(/^[^ ]+ /, ""); print; exit }' "$MAP.node" 2>/dev/null)"
  [[ -n "$node" ]] && printf 'HTTP/2 %s\r\nX-Served-By: %s\r\nx-cache: MISS\r\n\r\n' "$code" "$node"
  [[ "$out" != /dev/null && -n "$out" && -n "${body:-}" ]] && cat "$BODY_DIR/$body" >"$out"
  printf '%s %s' "$code" "$type"
  crc="$(awk -v u="$url" '$1 == u { print $2; exit }' "$MAP.crc" 2>/dev/null)"
  exit "${crc:-0}"
fi
[[ "$code" == 200 ]] || exit 22
[[ -n "${body:-}" ]] && cat "$BODY_DIR/$body"
exit 0
SH
# stub sleep: no real wait; the test reads the waits from the call log
printf '#!/bin/sh\necho "sleep $*" >>"$STUB_LOG"\n' >"$T/stub/sleep"
chmod +x "$T/stub/sleep"
chmod +x "$T/stub/curl"

# site <og-image-url|-> <img-code> <img-type> <og-code> <og-type>: one post
# naming $ID.webp; "-" = its page has no og:image
site() {
  local og="$1"
  echo "{\"locales\":{\"en\":[{\"id\":\"$ID\",\"image\":\"$ID.webp\"}]}}" >"$T/body/index"
  if [[ "$og" == - ]]; then echo '<html><head><title>t</title></head></html>' >"$T/body/page"
  else echo "<html><head><meta property=\"og:image\" content=\"$og\"></head></html>" >"$T/body/page"; fi
  rm -f "$MAP.then" "$MAP.node" "$MAP.crc"
  cat >"$MAP" <<EOF
$SITE/blog-md/index.json 200 application/json index
$SITE/blog/$ID 200 text/html page
$SITE/blog/img/$ID.webp $2 $3
$SITE/blog/img/$ID-og.webp $4 $5
EOF
  : >"$T/calls.log"
}
# cs [action-file] [site] [VAR=value]...: run the action; rc in $rc, output in $T/o
cs() {
  SNIPPET="source '${1:-$ACTION}'; do_check_blog_media_served" in_orc MAP="$MAP" BODY_DIR="$T/body" \
    BLOG_SITE_URL="${2-$SITE}" "${@:3}" </dev/null >"$T/o" 2>&1
  rc=$?
}
export -f in_orc
OG="$SITE/blog/img/$ID-og.webp"

# --- 1. good ----------------------------------------------------------------
site "$OG" 200 image/webp 200 image/webp; cs
((rc == 0)) && grep -q "OK 2 blog picture URL" "$T/o" && pass "the picture and its og:image answer 200 image/*: rc 0" ||
  fail "good: rc=$rc $(cat "$T/o")"

# --- 2. not served ----------------------------------------------------------
site "$OG" 200 'text/html;charset=utf-8' 200 'text/html;charset=utf-8'; cs
((rc == 1)) && grep -q "$ID: $SITE/blog/img/$ID.webp answers 200 text/html" "$T/o" && grep -q "$ID: $OG answers 200 text/html" "$T/o" &&
  pass "the site's HTML as the picture and og:image (the 2026-10-25 bug): rc 1, both named" || fail "html: rc=$rc $(cat "$T/o")"
site "$OG" 200 image/webp 200 'text/html;charset=utf-8'; cs
((rc == 1)) && grep -q "$OG answers 200 text/html" "$T/o" && ! grep -q "img/$ID.webp answers" "$T/o" &&
  pass "only the og:image missing: rc 1, the og:image named" || fail "og only: rc=$rc $(cat "$T/o")"
site "$OG" 404 text/html 200 image/webp; cs
((rc == 1)) && grep -q "img/$ID.webp answers 404" "$T/o" && pass "a 404 picture: rc 1" || fail "404: rc=$rc $(cat "$T/o")"
site - 200 image/webp 200 image/webp; cs
((rc == 1)) && grep -q "$SITE/blog/$ID names no og:image" "$T/o" && pass "a page with no og:image: rc 1" || fail "no og: rc=$rc $(cat "$T/o")"

# --- 3. nothing to check / refused ------------------------------------------
: >"$MAP"; echo '<html>' >"$T/body/index"; echo "$SITE/blog-md/index.json 404 text/html" >"$MAP"; cs
((rc == 0)) && grep -q "INFO no blog index" "$T/o" && pass "no index: rc 0" || fail "no index: rc=$rc $(cat "$T/o")"
echo '{"locales":{"en":[{"id":"'"$ID"'"}]}}' >"$T/body/index"; echo "$SITE/blog-md/index.json 200 application/json index" >"$MAP"; cs
((rc == 0)) && grep -q "INFO no post names a picture" "$T/o" && pass "no post names a picture: rc 0" || fail "no picture: rc=$rc $(cat "$T/o")"
site "$OG" 200 image/webp 200 image/webp; cs "" ""
((rc != 0)) && grep -q "BLOG_SITE_URL must be set" "$T/o" && ! grep -q curl "$T/calls.log" &&
  pass "BLOG_SITE_URL unset: refused before any request" || fail "no site: rc=$rc $(cat "$T/o")"

# --- 4. control --------------------------------------------------------------
sed 's/\^200\\ image\//^200/' "$ACTION" >"$T/m-type.sh"
if cmp -s "$ACTION" "$T/m-type.sh"; then fail "CONTROL type: the sed changed nothing"; else
  site "$OG" 200 'text/html;charset=utf-8' 200 'text/html;charset=utf-8'; cs "$T/m-type.sh"
  ((rc == 0)) && pass "CONTROL: without the image/* check the HTML picture passes (red)" || fail "CONTROL type: still rc=$rc"
fi

# --- 6. evidence on a failure; the verdict stays red (SPL-4968) ---------------
asks() { awk -v u="$1" '$1 == "curl" && $NF == u { n++ } END { print n + 0 }' "$T/calls.log"; }
sleeps() { grep -c '^sleep 10$' "$T/calls.log"; }
site "$OG" 200 image/webp 200 image/webp; cs
[[ "$(asks "$OG")" == 1 && "$(sleeps)" == 0 ]] && pass "a good site: one ask per URL, no re-ask, no wait" ||
  fail "good asks: $(asks "$OG") sleeps $(sleeps)"

site "$OG" 200 image/webp 200 'text/html;charset=utf-8'
echo "$OG 200 image/webp" >"$MAP.then"; echo "$OG cache-test-1-HEL" >"$MAP.node"; cs
grep -E "FATAL blog picture not served: .*$OG answers 200 text/html;charset=utf-8 \(at [0-9-]+T[0-9:]+Z, host site.example.com, node cache-test-1-HEL, x-cache MISS\), not an image" "$T/o" >/dev/null &&
  pass "a failing answer logs its UTC time, host, CDN node and x-cache" || fail "evidence: $(cat "$T/o")"
grep -q "INFO re-ask 1 of 2: $OG right: 200 image/webp" "$T/o" && grep -q "INFO re-ask 2 of 2: $OG right: 200 image/webp" "$T/o" &&
  [[ "$(asks "$OG")" == 3 && "$(sleeps)" == 2 ]] && pass "the failing URL is re-asked 2 times, 10 s apart, each answer logged" ||
  fail "re-asks: asks $(asks "$OG") sleeps $(sleeps) $(cat "$T/o")"
((rc == 1)) && grep -q "INFO every re-asked URL answers right" "$T/o" && grep -q "FATAL 1 of the blog's pictures" "$T/o" &&
  pass "a picture that clears on the re-ask still reds the check: rc 1" || fail "cleared: rc=$rc $(cat "$T/o")"
grep -E "FATAL|re-ask" "$T/o" | sed 's/^/  | /'

sed 's/do_log "INFO every re-asked URL answers right.*/return 0/' "$ACTION" >"$T/m-clear.sh"
if cmp -s "$ACTION" "$T/m-clear.sh"; then fail "CONTROL re-ask: the sed changed nothing"; else
  cs "$T/m-clear.sh"
  ((rc == 0)) && pass "CONTROL: a copy where a cleared re-ask passes goes green on the same site (red)" || fail "CONTROL re-ask: still rc=$rc"
fi

site "$OG" 200 image/webp 200 'text/html;charset=utf-8'; cs
((rc == 1)) && grep -q "INFO re-ask 2 of 2: $OG still wrong: 200 text/html" "$T/o" && ! grep -q "every re-asked" "$T/o" && [[ "$(asks "$OG")" == 3 ]] &&
  pass "a picture truly served as HTML: rc 1, still wrong on both re-asks" || fail "still wrong: rc=$rc $(cat "$T/o")"

site - 200 image/webp 200 image/webp
echo "<html><head><meta property=\"og:image\" content=\"$OG\"></head></html>" >"$T/body/page2"
echo "$SITE/blog/$ID 200 text/html page2" >"$MAP.then"; cs
((rc == 1)) && grep -q "INFO re-ask 1 of 2: $SITE/blog/$ID right: $OG, page 200 text/html (at " "$T/o" && grep -q "$SITE/blog/$ID names no og:image, answers 200 text/html" "$T/o" &&
  pass "a page with no og:image that clears on the re-ask still reds the check" || fail "page cleared: rc=$rc $(cat "$T/o")"

# --- 7. a page cut off mid-body (R7 W1) ---------------------------------------
for crc in 18 28; do
  site "$OG" 200 image/webp 200 image/webp; echo "$SITE/blog/$ID $crc" >"$MAP.crc"; cs
  ((rc == 1)) && grep -q "$SITE/blog/$ID names no og:image, answers 200 text/html.*curl rc $crc" "$T/o" &&
    pass "a page with its og:image, cut off with curl rc $crc: rc 1, the rc logged" || fail "cut off $crc: rc=$rc $(cat "$T/o")"
done
sed 's/ && "$got" != \*", curl rc "\*//' "$ACTION" >"$T/m-crc.sh"
if cmp -s "$ACTION" "$T/m-crc.sh"; then fail "CONTROL cut off: the sed changed nothing"; else
  cs "$T/m-crc.sh"
  ((rc == 0)) && pass "CONTROL: a copy that ignores curl's rc passes the cut-off page (red)" || fail "CONTROL cut off: still rc=$rc"
fi

site "$OG" 200 'text/html;charset=utf-8' 200 'text/html;charset=utf-8'; cs "" "$SITE" BLOG_SERVED_REASK_URLS=1
((rc == 1)) && grep -q "re-asking the first 1 of the 2 failing URLs" "$T/o" && [[ "$(asks "$OG")" == 1 && "$(asks "$SITE/blog/img/$ID.webp")" == 3 ]] &&
  pass "only the first BLOG_SERVED_REASK_URLS failing URLs are re-asked: the wait stays bounded" || fail "cap: rc=$rc $(cat "$T/o")"

# --- 8. the og URL, the page's status, no retry inside an ask (R7 c-318) ------
site "$OG, page 2" 200 image/webp 200 image/webp; cs
((rc == 1)) && grep -q "$ID: $OG, page 2 answers 200 text/html" "$T/o" &&
  pass "an og:image URL holding ', page ' is asked whole, only its shorter URL exists: rc 1" || fail "og sep: rc=$rc $(cat "$T/o")"
sed 's/og="${og%, page \*}"/og="${og%%, page *}"/' "$ACTION" >"$T/m-sep.sh"
if cmp -s "$ACTION" "$T/m-sep.sh"; then fail "CONTROL og sep: the sed changed nothing"; else
  cs "$T/m-sep.sh"
  ((rc == 0)) && pass "CONTROL: a copy cutting at the first separator passes that page (red)" || fail "CONTROL og sep: still rc=$rc"
fi

site "$OG" 200 image/webp 200 image/webp; echo "$SITE/blog/$ID cache, page 9" >"$MAP.node"; cs
((rc == 1)) && grep -qF "$OG, page 200 text/html (at " "$T/o" &&
  pass "the known limit: a page header holding ', page ' is a false red, never a false green" || fail "header limit: rc=$rc $(cat "$T/o")"

for code in 201 302 404 500; do
  site "$OG" 200 image/webp 200 image/webp; sed -i "s|^$SITE/blog/$ID 200 |$SITE/blog/$ID $code |" "$MAP"; cs
  ((rc == 1)) && grep -q "$SITE/blog/$ID names no og:image, answers $code text/html" "$T/o" &&
    pass "a page answering $code with its og:image: rc 1" || fail "page $code: rc=$rc $(cat "$T/o")"
done
sed 's/"$got" =~ ^200\\  && //' "$ACTION" >"$T/m-status.sh"
if cmp -s "$ACTION" "$T/m-status.sh"; then fail "CONTROL page status: the sed changed nothing"; else
  cs "$T/m-status.sh"
  ((rc == 0)) && pass "CONTROL: a copy that accepts any page status passes the 500 page (red)" || fail "CONTROL page status: still rc=$rc"
fi

curls() { grep -c '^curl ' "$T/calls.log"; }
retries() { grep -cE '^curl .*--retry' "$T/calls.log"; }
site "$OG" 200 image/webp 200 image/webp; cs
[[ "$(curls)" == 4 && "$(retries)" == 0 ]] && pass "a good site: none of its 4 asks carries --retry" || fail "retry good: $(curls) asks, $(retries) retries"
site "$OG" 200 'text/html;charset=utf-8' 200 'text/html;charset=utf-8'; cs
[[ "$(curls)" == 8 && "$(retries)" == 0 ]] && pass "a failing site: none of its 8 asks and re-asks carries --retry" || fail "retry failing: $(curls) asks, $(retries) retries"
sed 's/curl -/curl --retry 3 --retry-all-errors -/' "$ACTION" >"$T/m-retry.sh"
if cmp -s "$ACTION" "$T/m-retry.sh"; then fail "CONTROL retry: the sed changed nothing"; else
  site "$OG" 200 image/webp 200 image/webp; cs "$T/m-retry.sh"
  [[ "$(retries)" == 4 ]] && pass "CONTROL: a copy with a retry inside its curl is seen on all 4 asks (red)" || fail "CONTROL retry: $(retries) of $(curls)"
fi

# --- 5. wf 30 wiring ----------------------------------------------------------
if command -v yq >/dev/null; then
  steps=$(yq -r '.jobs.deploy.steps[].name' "$W30")
  at() { grep -nF -- "$1" <<<"$steps" | tail -1 | cut -d: -f1; }
  p=$(at "Probe the deployed commit"); c=$(at "Check the served blog pictures")
  if [[ -n "$p" && -n "$c" ]] && ((p < c)); then pass "wf 30: the served check runs after the deploy probe ($p < $c)"
  else fail "wf 30 order: probe=$p check=$c"; fi
  run=$(yq -r '.jobs.deploy.steps[] | select(.name == "Check the served blog pictures (do_check_blog_media_served)") | .run' "$W30")
  grep -q 'BLOG_SITE_URL="https://${SITE}.web.app" ./csi-spl-orc/run -a do_check_blog_media_served' <<<"$run" &&
    pass "wf 30: the step checks the deployed site" || fail "wf 30 run line: '$run'"
else fail "yq is required"; fi

((fails == 0)) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
