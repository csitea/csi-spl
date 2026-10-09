#!/bin/bash
#------------------------------------------------------------------------------
# @description The blog post picture (spec 111 section 5.4, T006, test 9-i):
# @description Nano Banana (Gemini 2.5 Flash Image) through the Gemini API
# @description generateContent, with the key do_set_nano_banana_key (T011)
# @description wrote to the agent user's ~/.nano-banana/crs
# @description (GEMINI_API_KEY=<key>). The key goes to curl as the
# @description x-goog-api-key header read from a file descriptor: never in
# @description argv, an exported env var, a shell variable, a log or git.
# @description The fixed "no people, no logos, no text" instruction is put in
# @description front of every prompt (the API's ImageConfig has aspectRatio
# @description and imageSize only, no person switch). The answer is
# @description re-encoded by cwebp (metadata none: no EXIF/XMP) to
# @description <id>.webp 1600x900 and the Open Graph crop <id>-og.webp
# @description 1200x630, each centre-cropped, each under 300 KB, checked for
# @description the RIFF/WEBP magic, written atomically into BLOG_IMAGE_DIR;
# @description then the post's frontmatter gets image, image_alt and
# @description image_prompt.
# @description Never blocks a post: no crs, an empty key, no cwebp, a vendor
# @description error or no picture in the answer leave the post as it was
# @description and exit 0 ("no picture: <why>"). Exit 1 only for a bad call:
# @description no post file, an id that is no post id, an image name that
# @description does not match ^<id>(-og)?\.webp$.
# @param BLOG_FILE (required) - the post markdown (its frontmatter has id)
# @param BLOG_IMAGE_PROMPT (optional) - the picture prompt, default the post's image_prompt
# @param BLOG_IMAGE_ALT (optional) - the alt text, default the post's image_alt, else the prompt
# @param BLOG_IMAGE_DIR (optional) - where the pictures go, default $HOME/.local/share/csi-spl/blog/img
# @param NANO_BANANA_CRS (optional) - the key file, default <agent-home>/.nano-banana/crs
# @param BLOG_IMAGE_MODEL (optional) - default gemini-2.5-flash-image
# @param BLOG_IMAGE_CWEBP (optional) - the encoder, default cwebp (Debian package webp)
# @example BLOG_FILE=/tmp/draft.md ./run -a do_spl_blog_image
# @example BLOG_FILE=/tmp/draft.md BLOG_IMAGE_PROMPT='a lighthouse at dusk, flat colours' ./run -a do_spl_blog_image
#------------------------------------------------------------------------------
do_spl_blog_image() {
  local xt=0; [[ $- == *x* ]] && xt=1; set +x
  local rc=0; spl_bimg_main || rc=$?
  (( xt )) && set -x
  return "$rc"
}

SPL_BIMG_RULE="No people, no human figures, no faces, no logos, no brand marks, and no text, letters or numbers anywhere in the picture."
SPL_BIMG_MAX_BYTES=307200

spl_bimg_main() {
  local f="${BLOG_FILE:-}" id prompt alt dir crs work rc=0
  [[ -n "$f" && -f "$f" && -r "$f" ]] || { do_log "FATAL BLOG_FILE is no readable file: '${f}'"; return 1; }
  id="$(spl_bimg_fm "$f" id)"
  [[ "$id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
    { do_log "FATAL the post id is not <yyyy-mm-dd>-<slug>: '$id'"; return 1; }
  spl_bimg_name_ok "$id" "$id.webp" && spl_bimg_name_ok "$id" "$id-og.webp" || return 1
  prompt="${BLOG_IMAGE_PROMPT:-$(spl_bimg_fm "$f" image_prompt)}"
  prompt="$(tr '\r\n\t' '   ' <<<"$prompt" | tr -s ' ')"; prompt="${prompt# }"; prompt="${prompt% }"
  [[ -n "$prompt" ]] || { spl_bimg_none "no image prompt (BLOG_IMAGE_PROMPT or image_prompt)"; return 0; }
  alt="${BLOG_IMAGE_ALT:-$(spl_bimg_fm "$f" image_alt)}"; alt="${alt:-${prompt:0:160}}"
  dir="${BLOG_IMAGE_DIR:-$HOME/.local/share/csi-spl/blog/img}"
  crs="$(spl_bimg_crs)"
  spl_bimg_header "$crs" 2>/dev/null | grep '^x-goog-api-key: [A-Za-z0-9._-]' >/dev/null ||
    { spl_bimg_none "no key in ${crs:-<no agent home>} (owner: ./run -a do_set_nano_banana_key)"; return 0; }
  command -v "${BLOG_IMAGE_CWEBP:-cwebp}" >/dev/null 2>&1 ||
    { spl_bimg_none "no encoder ${BLOG_IMAGE_CWEBP:-cwebp} (Debian package webp)"; return 0; }
  mkdir -p "$dir" || { do_log "FATAL cannot create BLOG_IMAGE_DIR $dir"; return 1; }
  work="$(mktemp -d "$dir/.bimg.XXXXXX")" || { do_log "FATAL no temp dir in $dir"; return 1; }
  spl_bimg_make "$id" "$prompt" "$crs" "$work" "$dir" || rc=$?
  rm -rf "$work"
  (( rc == 0 )) || return 0
  spl_bimg_set_fm "$f" "$id.webp" "$alt" "$prompt" || { do_log "FATAL could not write the frontmatter of $f"; return 1; }
  do_log "OK image $id.webp + $id-og.webp in $dir; $f has image: $id.webp"
}

# spl_bimg_make <id> <prompt> <crs> <work> <dir>: call, decode, encode, move.
# Non-zero = no picture (already logged); the post is left as it was.
spl_bimg_make() {
  local id="$1" prompt="$2" crs="$3" work="$4" dir="$5" mime w h
  spl_bimg_call "$prompt" "$crs" "$work/resp.json" || return 1
  mime="$(jq -r '[.candidates[]?.content.parts[]? | (.inlineData // .inline_data) | select(. != null)][0] | (.mimeType // .mime_type // "")' "$work/resp.json" 2>/dev/null)"
  [[ "$mime" == image/png || "$mime" == image/jpeg ]] ||
    { spl_bimg_none "no picture in the answer (finish: $(jq -r '.candidates[0]?.finishReason // .promptFeedback.blockReason // "?"' "$work/resp.json" 2>/dev/null))"; return 1; }
  jq -r '[.candidates[]?.content.parts[]? | (.inlineData // .inline_data) | select(. != null)][0].data' "$work/resp.json" |
    base64 -d >"$work/src" 2>/dev/null || { spl_bimg_none "the answer's picture is not base64"; return 1; }
  read -r w h < <(spl_bimg_dims "$work/src") && [[ "$w" =~ ^[1-9][0-9]*$ && "$h" =~ ^[1-9][0-9]*$ ]] ||
    { spl_bimg_none "cannot read the $mime size"; return 1; }
  spl_bimg_encode "$work/src" "$w" "$h" 1600 900 "$work/$id.webp" &&
    spl_bimg_encode "$work/src" "$w" "$h" 1200 630 "$work/$id-og.webp" || return 1
  mv -f "$work/$id.webp" "$dir/$id.webp" && mv -f "$work/$id-og.webp" "$dir/$id-og.webp" ||
    { spl_bimg_none "cannot move the pictures into $dir"; return 1; }
}

# spl_bimg_call <prompt> <crs> <out>: the Gemini request. The key reaches
# curl as a header file on fd 3; the body goes on stdin.
spl_bimg_call() {
  local model="${BLOG_IMAGE_MODEL:-gemini-2.5-flash-image}" code
  [[ "$model" =~ ^[a-z0-9][a-z0-9.-]{0,63}$ ]] || { spl_bimg_none "BLOG_IMAGE_MODEL is no model name: '$model'"; return 1; }
  code="$(jq -n --arg p "$SPL_BIMG_RULE $1" \
      '{contents:[{parts:[{text:$p}]}],generationConfig:{responseModalities:["IMAGE"],imageConfig:{aspectRatio:"16:9"}}}' |
    curl -sS --max-time 180 -o "$3" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H @/dev/fd/3 \
      --data-binary @- "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent" \
      3< <(spl_bimg_header "$2") 2>/dev/null)" || true
  [[ "$code" == 200 ]] && return 0
  spl_bimg_none "vendor error http ${code:-none} $(jq -r '.error | "\(.code // "") \(.status // "")"' "$3" 2>/dev/null)"
  return 1
}

# spl_bimg_header <crs>: the header line on stdout (to a pipe or fd, never a
# variable); as the crs owner when this user cannot read it.
spl_bimg_header() {
  local crs="$1" owner
  [[ -n "$crs" && -f "$crs" && ! -L "$crs" ]] || return 1
  if [[ -r "$crs" ]]; then sed -n 's/^GEMINI_API_KEY=/x-goog-api-key: /p' "$crs" | tail -n1
  else owner="$(stat -c %U "$crs")" && sudo -n -u "$owner" sed -n 's/^GEMINI_API_KEY=/x-goog-api-key: /p' "$crs" | tail -n1
  fi
}

# spl_bimg_crs: the key file: NANO_BANANA_CRS, else the agent user's (the
# user do_set_nano_banana_key writes for), else $HOME's.
spl_bimg_crs() {
  local agent home
  [[ -n "${NANO_BANANA_CRS:-}" ]] && { printf '%s' "$NANO_BANANA_CRS"; return 0; }
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" 2>/dev/null &&
    agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "${SPOOL_AGENT_USER:-}")"
  [[ -n "${agent:-}" ]] && home="$(getent passwd "$agent" | cut -d: -f6)"
  printf '%s/.nano-banana/crs' "${home:-$HOME}"
}

# spl_bimg_dims <file>: "W H" of a PNG (IHDR) or a JPEG (first SOFn).
spl_bimg_dims() {
  python3 -I - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
if b[:8] == b"\x89PNG\r\n\x1a\n" and b[12:16] == b"IHDR":
    print(*struct.unpack(">II", b[16:24])); sys.exit(0)
i = 2
while b[:2] == b"\xff\xd8" and i + 9 < len(b) and b[i] == 0xFF:
    m, n = b[i + 1], struct.unpack(">H", b[i + 2:i + 4])[0]
    if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
        h, w = struct.unpack(">HH", b[i + 5:i + 9]); print(w, h); sys.exit(0)
    i += 2 + n
sys.exit(1)
PY
}

# spl_bimg_encode <src> <w> <h> <W> <H> <out>: centre-crop to W:H, resize to
# WxH, webp without metadata; lower quality until it is under the limit.
spl_bimg_encode() {
  local src="$1" w="$2" h="$3" W="$4" H="$5" out="$6" cw ch x y q sz
  if (( w * H > h * W )); then ch=$h; cw=$(( h * W / H )); else cw=$w; ch=$(( w * H / W )); fi
  x=$(( (w - cw) / 2 )); y=$(( (h - ch) / 2 ))
  for q in 82 72 60 50; do
    "${BLOG_IMAGE_CWEBP:-cwebp}" -quiet -metadata none -q "$q" -crop "$x" "$y" "$cw" "$ch" -resize "$W" "$H" "$src" -o "$out" >/dev/null 2>&1 ||
      { spl_bimg_none "the encoder failed on ${W}x${H}"; return 1; }
    spl_bimg_is_webp "$out" || { spl_bimg_none "the encoder wrote no RIFF/WEBP file for ${W}x${H}"; return 1; }
    sz="$(stat -c %s "$out")"
    (( sz <= SPL_BIMG_MAX_BYTES )) && return 0
  done
  spl_bimg_none "${W}x${H} is $sz bytes at q 50, over $SPL_BIMG_MAX_BYTES"; return 1
}

spl_bimg_is_webp() { local m; m="$(head -c 12 "$1" 2>/dev/null | tr -c 'A-Z' '.')"; [[ "${m:0:4}" == RIFF && "${m:8:4}" == WEBP ]]; }

# spl_bimg_name_ok <id> <name>: the 4.3 rule, before a name reaches a path.
spl_bimg_name_ok() {
  local re="^${1//./\\.}(-og)?\\.webp\$"
  [[ "$2" =~ $re && "$2" != */* ]] && return 0
  do_log "FATAL REFUSE image name '$2' does not match ^<post-id>(-og)?\\.webp\$ for id '$1'"; return 1
}

spl_bimg_none() { do_log "WARN no picture: $*"; }

# spl_bimg_fm <file> <key>: a scalar from the first --- block, quotes stripped.
spl_bimg_fm() {
  awk -v k="$2" 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit}
    NR>1 && index($0, k ":")==1 { v=substr($0, length(k)+2); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/) { v=substr(v, 2, length(v)-2); gsub(/\\"/, "\"", v) } print v; exit }' "$1"
}

# spl_bimg_set_fm <file> <image> <alt> <prompt>: set the three keys in the
# frontmatter (replace, or add before its closing ---), via a temp file + mv.
spl_bimg_set_fm() {
  local f="$1" t
  t="$(mktemp "$(dirname "$f")/.bimg-fm.XXXXXX")" || return 1
  BIMG_I="$2" BIMG_A="$(spl_bimg_q "$3")" BIMG_P="$(spl_bimg_q "$4")" awk '
    BEGIN { img=ENVIRON["BIMG_I"]; alt=ENVIRON["BIMG_A"]; pr=ENVIRON["BIMG_P"] }
    function put(k, v) { print k ": " v; done[k]=1 }
    NR==1 { print; next }
    !end && $0=="---" { if (!done["image"]) put("image", img); if (!done["image_alt"]) put("image_alt", alt)
      if (!done["image_prompt"]) put("image_prompt", pr); end=1; print; next }
    !end && /^image:/ { put("image", img); next }
    !end && /^image_alt:/ { put("image_alt", alt); next }
    !end && /^image_prompt:/ { put("image_prompt", pr); next }
    { print }' "$f" >"$t" && chmod --reference="$f" "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
}

# spl_bimg_q <text>: a YAML double-quoted scalar.
spl_bimg_q() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
