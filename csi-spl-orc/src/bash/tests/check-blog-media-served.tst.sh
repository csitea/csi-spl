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

# stub curl: the last argument is the URL; its $MAP line "<url> <code> <type>"
# answers. -w prints "<code> <type>"; otherwise the body ($T/body/<n>) on a
# 200, exit 22 (as -f) on anything else.
cat >"$T/stub/curl" <<'SH'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
url="${!#}" w=0
for a in "$@"; do [[ "$a" == -w ]] && w=1; done
line="$(awk -v u="$url" '$1 == u { print; exit }' "$MAP")"
[[ -n "$line" ]] || line="$url 200 text/html;charset=utf-8"
read -r _ code type body <<<"$line"
if ((w)); then printf '%s %s' "$code" "$type"; exit 0; fi
[[ "$code" == 200 ]] || exit 22
[[ -n "${body:-}" ]] && cat "$BODY_DIR/$body"
exit 0
SH
chmod +x "$T/stub/curl"

# site <og-image-url|-> <img-code> <img-type> <og-code> <og-type>: one post
# naming $ID.webp; "-" = its page has no og:image
site() {
  local og="$1"
  echo "{\"locales\":{\"en\":[{\"id\":\"$ID\",\"image\":\"$ID.webp\"}]}}" >"$T/body/index"
  if [[ "$og" == - ]]; then echo '<html><head><title>t</title></head></html>' >"$T/body/page"
  else echo "<html><head><meta property=\"og:image\" content=\"$og\"></head></html>" >"$T/body/page"; fi
  cat >"$MAP" <<EOF
$SITE/blog-md/index.json 200 application/json index
$SITE/blog/$ID 200 text/html page
$SITE/blog/img/$ID.webp $2 $3
$SITE/blog/img/$ID-og.webp $4 $5
EOF
  : >"$T/calls.log"
}
# cs [action-file] [site]: run the action; rc in $rc, output in $T/o
cs() {
  SNIPPET="source '${1:-$ACTION}'; do_check_blog_media_served" in_orc MAP="$MAP" BODY_DIR="$T/body" \
    BLOG_SITE_URL="${2-$SITE}" </dev/null >"$T/o" 2>&1
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
