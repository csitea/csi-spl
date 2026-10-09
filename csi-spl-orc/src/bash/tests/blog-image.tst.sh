#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_blog_image (spec 111 T006, test 9-i), hermetic: a stubbed
#          Gemini vendor (curl) and encoder (cwebp), a fake canary key.
#   1. a stubbed call writes <id>.webp + <id>-og.webp (RIFF/WEBP) and sets
#      image, image_alt, image_prompt; the request carries the fixed
#      no-people/no-logo/no-text rule, IMAGE only, 16:9; the key arrives as
#      the x-goog-api-key header from a file descriptor; cwebp gets
#      -metadata none and the centre crops for 1600x900 and 1200x630
#   2. no crs, an empty key, a vendor error, an answer with no picture, no
#      encoder, a non-webp encoder output, an oversize picture: no picture,
#      the post unchanged, exit 0
#   3. CONTROL bad names: an id that is no post id is refused (exit 1, no
#      vendor call); the name check refuses ../x, a .png, another id
#   4. the canary key is in no output, stub argv/env or ps sample
#   5. CONTROL: a planted echo of the key in the output, in argv and in an
#      exported env var IS caught by the same leak check (T011's)
#   6. Vertex route (owner t1 d49b6b76 option b): a 429 on AI Studio leads to
#      the Vertex call in the cnf project + region, its token minted by a
#      stubbed gcloud from a planted fake SA key (throwaway CLOUDSDK_CONFIG,
#      the key by CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE, --account = the key's
#      client_email) and sent as the Authorization header on fd 3; no crs
#      goes to Vertex straight away; the key and the token leak nowhere
#   7. CONTROL: a 500 on AI Studio does NOT go to Vertex; a 429 with no SA key,
#      no cnf project, or a Vertex error: no picture, post unchanged, exit 0
#   8. do_spl_blog_image_check: both keys + a mintable token = "routes
#      aistudio+vertex", exit 0; the SA domain only, never the key, the token
#      or the account; CONTROL a token that cannot be minted drops vertex,
#      no key at all = "routes none", exit 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

KEY="canaryBi${RANDOM}${RANDOM}x${RANDOM}Q"
ID="2026-10-09-first-light"
mkdir -p "$T/stub" "$T/home/.nano-banana" "$T/img" "$T/posts"
CRS="$T/home/.nano-banana/crs"
printf 'GEMINI_API_KEY=%s\n' "$KEY" >"$CRS"; chmod 600 "$CRS"
: >"$T/calls.log"

# a 1344x768 PNG header: the stub vendor's picture (only the size is read)
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x05\x40\x00\x00\x03\x00\x08\x02\x00\x00\x00' >"$T/fake.png"
B64="$(base64 -w0 <"$T/fake.png")"

# stub vendor: argv + env to the log; the fd-3 header compared, never logged;
# the body kept; the answer by $FAKE_VENDOR (ok | http429 | http500 | noimage)
# for AI Studio, by $FAKE_VX (ok | http403) for a Vertex (aiplatform) URL
cat >"$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
{ echo "curl $*"; env; } >>"$STUB_LOG"
out="" hdr="" url=""
while (($#)); do case "$1" in -o) out="$2"; shift 2 ;; -H) [[ "$2" == @* ]] && hdr="${2#@}"; shift 2 ;; https://*) url="$1"; shift ;; *) shift ;; esac; done
[[ -n "$out" ]] || exit 0
ok() { printf '{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"%s"}}]}}]}' "$FAKE_B64" >"$out"; printf 200; }
if [[ "$url" == *aiplatform* ]]; then
  [[ -n "$hdr" && "$(cat "$hdr")" == "Authorization: Bearer $(cat "$FAKE_DIR/token")" ]] && echo ok >"$FAKE_DIR/vhdr" || echo bad >"$FAKE_DIR/vhdr"
  cat >"$FAKE_DIR/vbody.json"
  case "$FAKE_VX" in ok) ok ;; *) printf '{"error":{"code":403,"status":"PERMISSION_DENIED"}}' >"$out"; printf 403 ;; esac
  exit 0
fi
[[ -n "$hdr" && "$(cat "$hdr")" == "x-goog-api-key: $(sed -n 's/^GEMINI_API_KEY=//p' "$FAKE_CRS")" ]] && echo ok >"$FAKE_DIR/hdr" || echo bad >"$FAKE_DIR/hdr"
cat >"$FAKE_DIR/body.json"
case "$FAKE_VENDOR" in
  ok) ok ;;
  noimage) printf '{"candidates":[{"finishReason":"IMAGE_SAFETY","content":{"parts":[]}}]}' >"$out"; printf 200 ;;
  http429) printf '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"free_tier limit 0"}}' >"$out"; printf 429 ;;
  *) printf '{"error":{"code":500,"status":"INTERNAL","message":"boom"}}' >"$out"; printf 500 ;;
esac
EOF
# stub gcloud: argv + env to the log; prints the fake token only for
# "auth print-access-token" with a throwaway CLOUDSDK_CONFIG and the key by
# CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
{ echo "gcloud $*"; env; } >>"$STUB_LOG"
[[ "$1 $2" == "auth print-access-token" && -d "${CLOUDSDK_CONFIG:-}" && "$CLOUDSDK_CONFIG" != "$HOME/.config/gcloud" &&
   -f "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}" ]] || exit 1
echo "$CLOUDSDK_CONFIG" >"$FAKE_DIR/gcfg"
cat "$FAKE_DIR/token"
EOF
# stub encoder: argv to the log; writes a webp-shaped file ($FAKE_ENC: webp | junk | big)
cat >"$T/stub/cwebp" <<'EOF'
#!/usr/bin/env bash
echo "cwebp $*" >>"$STUB_LOG"
out=""; while (($#)); do [[ "$1" == -o ]] && out="$2"; shift; done
case "$FAKE_ENC" in
  junk) printf 'GIF89a-not-webp' >"$out" ;;
  big) { printf 'RIFF\x00\x00\x00\x00WEBPVP8 '; head -c 400000 /dev/zero; } >"$out" ;;
  *) printf 'RIFF\x1a\x00\x00\x00WEBPVP8 \x0e\x00\x00\x00fake-webp-body' >"$out" ;;
esac
EOF
chmod +x "$T/stub/"*

# the cnf (a fake project + region) and a fake SA key with a canary private key
VX_PROJECT="test-vx-proj${RANDOM}"; VX_LOC="europe-west9"
printf 'env:\n  blog:\n    image:\n      vertex_project: %s\n      vertex_location: %s\n' "$VX_PROJECT" "$VX_LOC" >"$T/cnf.yaml"
SAKEY_CANARY="canarySa${RANDOM}${RANDOM}k${RANDOM}"
VX_ACCOUNT="blog-image@$VX_PROJECT.example"
VX_KEY="$T/home/.gcp/.csi/key-$VX_PROJECT.json"
TOKEN="ya29.canaryTok${RANDOM}${RANDOM}${RANDOM}x"; printf "%s\n" "$TOKEN" >"$T/token"
plant_sa() { mkdir -p "$(dirname "$VX_KEY")"; jq -n --arg e "$VX_ACCOUNT" --arg k "$SAKEY_CANARY" \
  '{type:"service_account",client_email:$e,private_key:$k}' >"$VX_KEY"; chmod 600 "$VX_KEY"; }

post() {
  cat >"$T/posts/$ID.md" <<EOF
---
id: $ID
lang: en
type: news
title: "First light"
image_prompt: "a lighthouse at dusk, flat colours"
draft: false
---
Body.
EOF
}
# bi [VAR=value]...: in_orc with the hermetic key, dirs and stubs
bi() {
  env -u TMUX HOME="$T/home" NANO_BANANA_CRS="$CRS" BLOG_FILE="$T/posts/$ID.md" BLOG_IMAGE_DIR="$T/img" \
    BLOG_IMAGE_CNF="$T/cnf.yaml" FAKE_VX="${FAKE_VX:-ok}" \
    FAKE_CRS="$CRS" FAKE_DIR="$T" FAKE_B64="$B64" FAKE_VENDOR="${FAKE_VENDOR:-ok}" FAKE_ENC="${FAKE_ENC:-webp}" \
    SNIPPET="${SNIPPET:-do_spl_blog_image}" "$@" bash -c in_orc </dev/null >"$T/o" 2>&1
}
export -f in_orc
export PROJ_ROOT APP_ROOT T
( while :; do ps -eo args= 2>/dev/null; sleep 0.05; done >>"$T/ps.log" ) & PS_PID=$!
no_leak() { ! grep -qF "$1" "$T/o" "$T/calls.log" "$T/ps.log"; }
webp() { local m; m="$(head -c 12 "$1" | tr -c 'A-Z' '.')"; [[ "${m:0:4}" == RIFF && "${m:8:4}" == WEBP ]]; }

# --- 1. stubbed vendor -> two webp files and the frontmatter --------------------------------------
post; bi; rc=$?
f="$T/posts/$ID.md"
if [[ $rc -eq 0 ]] && webp "$T/img/$ID.webp" && webp "$T/img/$ID-og.webp" && grep -qx "image: $ID.webp" "$f" &&
   grep -qx 'image_alt: "a lighthouse at dusk, flat colours"' "$f" && grep -qx 'image_prompt: "a lighthouse at dusk, flat colours"' "$f" &&
   [[ "$(grep -c '^image' "$f")" == 3 ]] && grep -q "^OK image $ID.webp" "$T/o"; then
  pass "1: a stubbed call writes $ID.webp + $ID-og.webp (RIFF/WEBP) and sets image, image_alt, image_prompt"
else fail "1: stubbed call (rc=$rc): $(tail -n3 "$T/o")"; fi
[[ "$(cat "$T/hdr")" == ok ]] && grep -q 'curl .*-H @/dev/fd/3 .*models/gemini-2.5-flash-image:generateContent' "$T/calls.log" &&
  pass "1: the key reaches the vendor as the x-goog-api-key header from a file descriptor" || fail "1: header: $(cat "$T/hdr")"
jq -e '(.contents[0].parts[0].text | startswith("No people, no human figures, no faces, no logos, no brand marks, and no text") and endswith("a lighthouse at dusk, flat colours"))
  and .generationConfig.responseModalities == ["IMAGE"] and .generationConfig.imageConfig.aspectRatio == "16:9"' "$T/body.json" >/dev/null &&
  pass "1: the request carries the fixed no-people/no-logo/no-text rule, IMAGE only, 16:9" || fail "1: body: $(cat "$T/body.json")"
grep -q -- '-metadata none -q 82 -crop 0 6 1344 756 -resize 1600 900 ' "$T/calls.log" &&
  grep -q -- '-metadata none -q 82 -crop 0 31 1344 705 -resize 1200 630 ' "$T/calls.log" &&
  pass "1: cwebp strips metadata and centre-crops 1344x768 to 1600x900 and 1200x630" || fail "1: cwebp argv: $(grep cwebp "$T/calls.log")"
if compgen -G "$T/img/.bimg*" >/dev/null || compgen -G "$T/posts/.bimg*" >/dev/null; then
  fail "1: a temp file was left behind"; else pass "1: no temp file left"; fi
post; printf 'image: old.webp\nimage_alt: "x \\"q\\""\n' >"$T/x"; sed -i "/^draft:/r $T/x" "$f"
bi BLOG_IMAGE_ALT='a "tall" light'; [[ "$(grep -c '^image' "$f")" == 3 ]] && grep -qx "image: $ID.webp" "$f" &&
  grep -qxF 'image_alt: "a \"tall\" light"' "$f" && pass "1: an existing image/image_alt is replaced, quotes escaped" ||
  fail "1: replace: $(sed -n '2,9p' "$f")"

# --- 2. no picture, exit 0, the post unchanged -------------------------------------------------------
# nopic <label> [VAR=value]...: rc 0, a "no picture" WARN, no image written, the post byte-identical
nopic() {
  local label="$1"; shift
  post; rm -f "$T/img/"*.webp; local before; before="$(sha256sum <"$f")"
  bi "$@"; local rc=$?
  [[ $rc -eq 0 ]] && grep -q 'WARN no picture' "$T/o" && [[ "$(sha256sum <"$f")" == "$before" ]] &&
    ! compgen -G "$T/img/*.webp" >/dev/null && pass "2: $label -> no picture, post unchanged, exit 0" ||
    fail "2: $label (rc=$rc): $(tail -n2 "$T/o")"
}
: >"$T/calls.log"; nopic "no crs" NANO_BANANA_CRS="$T/none/crs"
grep -q '^curl' "$T/calls.log" && fail "2: no crs still called the vendor" || pass "2: no crs: the vendor is never called"
printf 'GEMINI_API_KEY=\n' >"$T/empty-crs"; nopic "an empty key" NANO_BANANA_CRS="$T/empty-crs"
nopic "a vendor error (http 500)" FAKE_VENDOR=http500
grep -q 'vendor error http 500' "$T/o" || fail "2: the vendor error is not named"
nopic "an answer with no picture" FAKE_VENDOR=noimage
nopic "no encoder" BLOG_IMAGE_CWEBP=no-such-cwebp
nopic "a non-webp encoder output" FAKE_ENC=junk
nopic "a picture over 300 KB at every quality" FAKE_ENC=big
[[ "$(grep -c '^cwebp .*-resize 1600 900' "$T/calls.log")" -ge 4 ]] && pass "2: oversize retried at lower quality" || fail "2: no quality ladder"

# --- 3. CONTROL: bad names refused ---------------------------------------------------------------------
post; sed -i "s|^id: .*|id: ../x|" "$f"; : >"$T/calls.log"; bi
[[ $? -eq 1 ]] && grep -q 'FATAL the post id' "$T/o" && ! grep -q '^curl' "$T/calls.log" &&
  pass "3: CONTROL an id that is no post id is refused, exit 1, no vendor call" || fail "3: bad id: $(tail -n2 "$T/o")"
for n in "../x.webp" "$ID.png" "2026-10-09-other.webp" "$ID-og.webp/x" "$ID-small.webp"; do
  SNIPPET="spl_bimg_name_ok $ID '$n'" bi
  [[ $? -ne 0 ]] && grep -q 'REFUSE image name' "$T/o" && pass "3: CONTROL name '$n' is refused" || fail "3: name '$n' was accepted"
done
SNIPPET="spl_bimg_name_ok $ID $ID.webp && spl_bimg_name_ok $ID $ID-og.webp" bi &&
  pass "3: $ID.webp and $ID-og.webp pass the name check" || fail "3: good names refused: $(cat "$T/o")"

# --- 4. leak check -----------------------------------------------------------------------------------
post; bi
no_leak "$KEY" && pass "4: the canary key is in no output, stub argv/env or ps sample" ||
  fail "4: the canary key leaked: $(grep -lF "$KEY" "$T/o" "$T/calls.log" "$T/ps.log" | xargs -n1 basename | paste -sd' ')"

# --- 5. CONTROLS: a planted echo is caught ------------------------------------------------------------
# plant <statement> <label>: the action with <statement> injected at the top of spl_bimg_call ($2 = the crs)
plant() {
  local s
  s='eval "$(declare -f spl_bimg_call | sed "0,/local model/s||'"$1"'; &|")"; do_spl_blog_image'
  post; : >"$T/calls.log"; : >"$T/ps.log"
  SNIPPET="$s" bi
  no_leak "$KEY" && fail "5: CONTROL $2: the planted echo was NOT caught" || pass "5: CONTROL $2: the leak check catches it"
}
plant 'sed -n s/^GEMINI_API_KEY=//p \"\$2\"' "output/log"
plant 'curl -s \"\$(sed -n s/^GEMINI_API_KEY=//p \"\$2\")\"' "argv"
plant 'K=\"\$(sed -n s/^GEMINI_API_KEY=//p \"\$2\")\" curl -s' "env"

# --- 6. Vertex on a 429 -------------------------------------------------------------------------------
vx_url="curl .*-H @/dev/fd/3 .*https://$VX_LOC-aiplatform.googleapis.com/v1/projects/$VX_PROJECT/locations/$VX_LOC/publishers/google/models/gemini-2.5-flash-image:generateContent"
plant_sa; post; rm -f "$T/img/"*.webp "$T/vhdr" "$T/gcfg"; : >"$T/calls.log"; : >"$T/ps.log"
FAKE_VENDOR=http429 bi; rc=$?
[[ $rc -eq 0 ]] && webp "$T/img/$ID.webp" && grep -qx "image: $ID.webp" "$f" && grep -q 'generativelanguage' "$T/calls.log" &&
  grep -q "$vx_url" "$T/calls.log" && grep -q "INFO AI Studio answered 429, using Vertex $VX_PROJECT/$VX_LOC" "$T/o" &&
  pass "6: a 429 on AI Studio leads to the Vertex call in the cnf project + region, the picture is written" ||
  fail "6: 429 -> Vertex (rc=$rc): $(tail -n3 "$T/o")"
[[ "$(cat "$T/vhdr" 2>/dev/null)" == ok ]] && grep -q "^gcloud auth print-access-token --account=$VX_ACCOUNT\$" "$T/calls.log" &&
  grep -q "^CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=$VX_KEY\$" "$T/calls.log" && [[ -s "$T/gcfg" && ! -e "$(cat "$T/gcfg")" ]] &&
  pass "6: the SA token (key override, --account = client_email, throwaway config removed after) is the Authorization header on fd 3" ||
  fail "6: token path: vhdr=$(cat "$T/vhdr" 2>/dev/null) $(grep '^gcloud' "$T/calls.log")"
jq -e '.contents[0].role == "user" and (.contents[0].parts[0].text | startswith("No people")) and .generationConfig.imageConfig.aspectRatio == "16:9"' \
  "$T/vbody.json" >/dev/null && pass "6: the Vertex body carries role user, the fixed rule and 16:9" || fail "6: vbody: $(cat "$T/vbody.json")"
no_leak "$SAKEY_CANARY" && no_leak "$TOKEN" && no_leak "$KEY" &&
  pass "6: the SA key, the token and the AI Studio key are in no output, stub argv/env or ps sample" ||
  fail "6: leak: $(grep -lF -e "$SAKEY_CANARY" -e "$TOKEN" -e "$KEY" "$T/o" "$T/calls.log" "$T/ps.log" | xargs -n1 basename | paste -sd' ')"
post; : >"$T/calls.log"; bi NANO_BANANA_CRS="$T/none/crs" BLOG_IMAGE_VERTEX_KEY="$VX_KEY"
[[ $? -eq 0 ]] && grep -qx "image: $ID.webp" "$f" && ! grep -q generativelanguage "$T/calls.log" && grep -q "$vx_url" "$T/calls.log" &&
  grep -q 'INFO AI Studio has no key, using Vertex' "$T/o" && pass "6: no crs goes to Vertex straight away" || fail "6: no crs -> Vertex: $(tail -n2 "$T/o")"

# --- 7. CONTROLS: what must not reach Vertex, and the never-block rule ---------------------------------
: >"$T/calls.log"; nopic "a 500 on AI Studio (with an SA key)" FAKE_VENDOR=http500
grep -q aiplatform "$T/calls.log" && fail "7: CONTROL a 500 went to Vertex" || pass "7: CONTROL a 500 on AI Studio does not go to Vertex"
: >"$T/calls.log"; nopic "a Vertex error (http 403)" FAKE_VENDOR=http429 FAKE_VX=http403
grep -q 'Vertex error http 403 403 PERMISSION_DENIED' "$T/o" || fail "7: the Vertex error is not named: $(tail -n2 "$T/o")"
printf 'env: {}\n' >"$T/nocnf.yaml"; : >"$T/calls.log"; nopic "a 429 and no cnf project" FAKE_VENDOR=http429 BLOG_IMAGE_CNF="$T/nocnf.yaml"
grep -q 'aiplatform\|^gcloud' "$T/calls.log" && fail "7: no cnf project still called Vertex" || pass "7: no cnf project: Vertex is never called"
rm -f "$VX_KEY"; : >"$T/calls.log"; nopic "a 429 and no SA key" FAKE_VENDOR=http429
grep -q 'aiplatform\|^gcloud' "$T/calls.log" && fail "7: no SA key still called Vertex" || pass "7: no SA key: Vertex is never called"
: >"$T/calls.log"; nopic "no crs and no SA key" NANO_BANANA_CRS="$T/none/crs"
grep -q 'and no Vertex key: no SA key at' "$T/o" && ! grep -q '^curl\|^gcloud' "$T/calls.log" &&
  pass "7: no key at all: no vendor call, the reason names both keys" || fail "7: no key at all: $(tail -n2 "$T/o")"

# --- 8. the named check -------------------------------------------------------------------------------
plant_sa; : >"$T/calls.log"; : >"$T/ps.log"; SNIPPET=do_spl_blog_image_check bi; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'OK routes aistudio+vertex' "$T/o" && grep -qx 'INFO vertex_token ok' "$T/o" &&
  grep -qx "INFO vertex_sa_key yes $VX_KEY (sa domain $VX_PROJECT.example)" "$T/o" && grep -qx "INFO vertex_cnf $VX_PROJECT/$VX_LOC" "$T/o" &&
  pass "8: the check reports both routes, the cnf project/region, the key path and the SA domain, exit 0" || fail "8: check (rc=$rc): $(cat "$T/o")"
no_leak "$SAKEY_CANARY" && no_leak "$TOKEN" && no_leak "$KEY" && ! grep -qF "$VX_ACCOUNT" "$T/o" &&
  pass "8: the check prints no key, token or account" || fail "8: the check leaked"
mv "$T/token" "$T/token.off"; SNIPPET=do_spl_blog_image_check bi NANO_BANANA_CRS="$T/none/crs" BLOG_IMAGE_VERTEX_KEY="$VX_KEY"; rc=$?
mv "$T/token.off" "$T/token"
[[ $rc -eq 1 ]] && grep -qx 'INFO vertex_token failed' "$T/o" && grep -q '^WARN routes none' "$T/o" &&
  pass "8: CONTROL a token that cannot be minted drops the vertex route, exit 1" || fail "8: mint control (rc=$rc): $(cat "$T/o")"
rm -f "$VX_KEY"; SNIPPET=do_spl_blog_image_check bi NANO_BANANA_CRS="$T/none/crs"; rc=$?
[[ $rc -eq 1 ]] && grep -q '^WARN routes none' "$T/o" && grep -q '^INFO vertex_sa_key no no SA key at' "$T/o" &&
  pass "8: CONTROL no key at all = routes none, exit 1" || fail "8: none (rc=$rc): $(cat "$T/o")"

kill "$PS_PID" 2>/dev/null; wait "$PS_PID" 2>/dev/null
echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
