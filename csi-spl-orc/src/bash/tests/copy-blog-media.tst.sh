#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_copy_blog_media (spec 111 T006b, test 9-i copy controls),
#          hermetic: a stubbed gcloud serves a local dir as the 054 bucket.
#   1. a good webp named by the index is copied to blog/img with its -og crop,
#      byte for byte; a picture of exactly 300 KB (307200 bytes) is copied
#   2. refused, each with rc 1, the file and the reason named, NOTHING copied:
#      a PNG renamed .webp, a 301 KB webp, an empty file
#   3. a name that is not <post-id>(-og).webp (../x, $(...), another id) is
#      refused before any gcloud call
#   4. a picture the bucket lacks: WARN, rc 0; no index / no picture: rc 0
#   5. CONTROLS: a copy of the action with one check removed (the magic bytes,
#      the 300 KB limit, the empty check, the name check) lets its bad file
#      through, so each assertion above goes red without its check
#   6. wf 30 runs the action in the deploy job after the last nuxt generate
#      and before firebase deploy, as the project key
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ACTION="$PROJ_ROOT/src/bash/run/copy-blog-media.func.sh"
W30="$APP_ROOT/.github/workflows/30_wui-build-deploy.yml"
ID="2026-10-09-first-light"
B="$T/bucket"
mkdir -p "$T/stub" "$B"

# stub gcloud: `storage ls gs://<b>/` lists $FAKE_BUCKET, `storage cp
# gs://<b>/<n> <dst>` copies from it; every call logged
cat >"$T/stub/gcloud" <<'SH'
#!/bin/bash
echo "gcloud $*" >>"$STUB_LOG"
case "$1 $2" in
  "storage ls") b="${3#gs://}"; b="${b%/}"; for f in "$FAKE_BUCKET"/*; do [[ -e "$f" ]] && echo "gs://$b/${f##*/}"; done; exit 0 ;;
  "storage cp") cp "$FAKE_BUCKET/${3##*/}" "$4" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$T/stub/gcloud"

# a valid 1x1 lossless webp (34 bytes), padded to a size by RIFF-legal junk
webp() { printf 'UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==' | base64 -d >"$1"; [[ -z "${2:-}" ]] || truncate -s "$2" "$1"; }
index() {  # index <image>... : one en entry per image, id = $ID unless "id:img"
  local e="" x id img
  for x in "$@"; do
    if [[ "$x" == *:* ]]; then id="${x%%:*}"; img="${x#*:}"; else id="$ID"; img="$x"; fi
    e+="${e:+,}$(jq -nc --arg i "$id" --arg m "$img" '{id:$i,title:"t",image:$m,image_alt:"a"}')"
  done
  mkdir -p "$T/out/blog-md"; echo "{\"locales\":{\"en\":[$e]}}" >"$T/out/blog-md/index.json"
}
reset() { rm -rf "$T/out" "$B"; mkdir -p "$B"; : >"$T/calls.log"; }
# cb [action-file]: run the action; rc in $rc, output in $T/o
cb() {
  SNIPPET="source '${1:-$ACTION}'; do_copy_blog_media" in_orc FAKE_BUCKET="$B" BLOG_MEDIA_OUT="$T/out" \
    GCP_ACCOUNT=test-sa@example.com </dev/null >"$T/o" 2>&1
  rc=$?
}
export -f in_orc
copied() { [[ -f "$T/out/blog/img/$1" ]]; }
none_copied() { [[ -z "$(ls -A "$T/out/blog/img" 2>/dev/null)" ]]; }

# --- 1. good ----------------------------------------------------------------
reset; webp "$B/$ID.webp"; webp "$B/$ID-og.webp"; index "$ID.webp"; cb
if ((rc == 0)) && copied "$ID.webp" && copied "$ID-og.webp" && cmp -s "$B/$ID.webp" "$T/out/blog/img/$ID.webp"; then
  pass "a good webp and its -og crop are copied byte for byte"
else fail "good webp: rc=$rc $(cat "$T/o")"; fi
reset; webp "$B/$ID.webp" 307200; index "$ID.webp"; cb
((rc == 0)) && copied "$ID.webp" && pass "a webp of exactly 300 KB (307200 bytes) is copied" || fail "300 KB webp: rc=$rc $(cat "$T/o")"

# --- 2. refused files -------------------------------------------------------
# refused <label> <reason-regex> [action]: rc 1, the file + reason named, nothing copied
refused() {
  cb "${3:-}"
  if ((rc == 1)) && grep -q "refused: $ID.webp: $2" "$T/o" && none_copied; then return 0; fi
  return 1
}
png() { printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00' >"$1"; }
case_png()   { reset; png "$B/$ID.webp"; index "$ID.webp"; }
case_big()   { reset; webp "$B/$ID.webp" 308224; index "$ID.webp"; }
case_empty() { reset; : >"$B/$ID.webp"; index "$ID.webp"; }
case_png;   refused png 'not a webp'  && pass "a PNG renamed .webp is refused and named" || fail "png: rc=$rc $(cat "$T/o")"
case_big;   refused big '308224 bytes, over the 300 KB' && pass "a 301 KB webp is refused and named" || fail "301 KB: rc=$rc $(cat "$T/o")"
case_empty; refused empty 'empty' && pass "an empty file is refused and named" || fail "empty: rc=$rc $(cat "$T/o")"
reset; webp "$B/$ID.webp"; png "$B/$ID-og.webp"; index "$ID.webp"; cb
((rc == 1)) && grep -q "refused: $ID-og.webp" "$T/o" && none_copied &&
  pass "one bad file (the -og crop) copies nothing, not even the good one" || fail "partial: rc=$rc $(cat "$T/o")"

# --- 3. names ---------------------------------------------------------------
for bad in "../x.webp" '$(touch pwn).webp' "2026-10-08-other.webp" "$ID.png" "$ID-og2.webp"; do
  reset; webp "$B/$ID.webp"; index "$bad"; cb
  if ((rc == 1)) && grep -qF "refused: $bad" "$T/o" && ! grep -q "gcloud" "$T/calls.log" && none_copied; then
    pass "name '$bad' refused before any gcloud call"
  else fail "name '$bad': rc=$rc calls=$(cat "$T/calls.log") $(cat "$T/o")"; fi
done
reset; webp "$B/$ID.webp"; index "x-$ID:x-$ID.webp"; cb
((rc == 1)) && ! grep -q gcloud "$T/calls.log" && pass "an id that is not <yyyy-mm-dd>-<slug> is refused" || fail "bad id: rc=$rc"

# --- 4. missing / nothing to do ---------------------------------------------
reset; index "$ID.webp"; cb
((rc == 0)) && grep -q "WARN .*holds no $ID.webp" "$T/o" && none_copied && pass "a missing picture is a WARN, rc 0" || fail "missing: rc=$rc $(cat "$T/o")"
reset; cb
((rc == 0)) && ! grep -q gcloud "$T/calls.log" && pass "no index: rc 0, no gcloud call" || fail "no index: rc=$rc"
reset; mkdir -p "$T/out/blog-md"; echo '{"locales":{"en":[{"id":"'"$ID"'","title":"t"}]}}' >"$T/out/blog-md/index.json"; cb
((rc == 0)) && ! grep -q gcloud "$T/calls.log" && pass "no post names a picture: rc 0, no gcloud call" || fail "no picture: rc=$rc"

# --- 4b. every orc file sourced, as ./run does (wf 30 run 37892580445) -------
# cb re-sources the action LAST, which hid a later file redefining one of its
# helpers: spl-blog-media-put.func.sh's two-argument spl_blog_media_check won
# under ./run and the deploy died on "$2: unbound variable".
PUT="$PROJ_ROOT/src/bash/run/spl-blog-media-put.func.sh"
run_all() { SNIPPET="$1 do_copy_blog_media" in_orc FAKE_BUCKET="$B" BLOG_MEDIA_OUT="$T/out" \
  GCP_ACCOUNT=test-sa@example.com </dev/null >"$T/o" 2>&1; rc=$?; }
reset; webp "$B/$ID.webp"; index "$ID.webp"; run_all ""
((rc == 0)) && copied "$ID.webp" && pass "with every orc file sourced (put file too) a good webp is copied" ||
  fail "all sourced: rc=$rc $(cat "$T/o")"
sed 's/spl_blog_media_put_check/spl_blog_media_check/g' "$PUT" >"$T/put-dup.sh"
if cmp -s "$PUT" "$T/put-dup.sh"; then fail "CONTROL clash: the sed changed nothing"; else
  reset; webp "$B/$ID.webp"; index "$ID.webp"; run_all "source '$T/put-dup.sh';"
  ((rc != 0)) && ! copied "$ID.webp" && pass "CONTROL: the put file's old duplicate name breaks the copy (red)" ||
    fail "CONTROL clash: still copied with the duplicate name: rc=$rc"
fi

# --- 5. controls ------------------------------------------------------------
# mutant <name> <sed-expr>: the action with one check removed; must differ
mutant() {
  sed "$2" "$ACTION" >"$T/m-$1.sh"
  cmp -s "$ACTION" "$T/m-$1.sh" && { fail "control $1: the sed changed nothing"; return 1; }
  echo "$T/m-$1.sh"
}
if m=$(mutant magic '/RIFF && /d'); then
  case_png; refused png 'not a webp' "$m" && fail "CONTROL magic: a PNG still refused without the magic check" ||
    { copied "$ID.webp" && pass "CONTROL: without the magic-byte check the PNG is copied (red)"; } || fail "CONTROL magic: inconclusive"
fi
if m=$(mutant size '/size <= 307200/d'); then
  case_big; refused big 'over the 300 KB' "$m" && fail "CONTROL size: 301 KB still refused without the limit" ||
    { copied "$ID.webp" && pass "CONTROL: without the 300 KB limit the 301 KB file is copied (red)"; } || fail "CONTROL size: inconclusive"
fi
if m=$(mutant empty '/size > 0/d'); then
  case_empty; refused empty 'empty' "$m" && fail "CONTROL empty: still refused as empty without the empty check" ||
    pass "CONTROL: without the empty check the empty-file assertion goes red"
fi
if m=$(mutant name 's/if spl_blog_media_name_ok "$id" "$img"; then/if true; then/'); then
  reset; webp "$B/$ID.webp"; index "../x.webp"; cb "$m"
  grep -q "gcloud" "$T/calls.log" && pass "CONTROL: without the name check ../x.webp reaches gcloud (red)" ||
    fail "CONTROL name: no gcloud call even without the name check"
fi

# --- 6. wf 30 wiring --------------------------------------------------------
if command -v yq >/dev/null; then
  steps=$(yq -r '.jobs.deploy.steps[].name' "$W30")
  at() { grep -nF -- "$1" <<<"$steps" | tail -1 | cut -d: -f1; }
  c=$(at "Copy the blog pictures"); g=$(at "nuxt generate"); d=$(at "firebase deploy")
  if [[ -n "$c" && -n "$g" && -n "$d" ]] && ((g < c && c < d)); then
    pass "wf 30: the copy step runs after the last nuxt generate ($g) and before firebase deploy ($d)"
  else fail "wf 30 order: generate=$g copy=$c deploy=$d"; fi
  run=$(yq -r '.jobs.deploy.steps[] | select(.name == "Copy the blog pictures (do_copy_blog_media)") | .run' "$W30")
  grep -q 'GCP_SA_KEY_FILE="$GOOGLE_APPLICATION_CREDENTIALS" ./csi-spl-orc/run -a do_copy_blog_media' <<<"$run" &&
    pass "wf 30: the step runs do_copy_blog_media as the project key" || fail "wf 30 run line: '$run'"
else fail "yq is required"; fi

((fails == 0)) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
