#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only status of the blog picture keys on THIS box
# @description (do_spl_blog_image's two routes): the AI Studio key file, the
# @description cnf Vertex project + region, the per-env SA key
# @description <agent-home>/.gcp/.csi/key-<project>.json and whether a token
# @description can be minted from it (throwaway CLOUDSDK_CONFIG, never the
# @description owner account), and the encoder. Prints one "key value" line
# @description each and "routes ..."; never a key, a token or an e-mail
# @description address (the SA's domain only). Copies nothing.
# @description Exit 0 when at least one route can make a picture, else 1.
# @description On another box: run it there, e.g. over the satellite alias.
# @param NANO_BANANA_CRS (optional) - as do_spl_blog_image
# @param BLOG_IMAGE_CNF (optional) - as do_spl_blog_image
# @param BLOG_IMAGE_VERTEX_KEY (optional) - as do_spl_blog_image
# @param BLOG_IMAGE_CHECK_MINT (optional) - 1 (default) mints a token to prove the key works, 0 skips it
# @example ./run -a do_spl_blog_image_check
#------------------------------------------------------------------------------
do_spl_blog_image_check() {
  local crs studio=no vx=no mint=skipped enc=no dom="" routes=""
  crs="$(spl_bimg_crs)"
  spl_bimg_header "$crs" 2>/dev/null | grep '^x-goog-api-key: [A-Za-z0-9._-]' >/dev/null && studio=yes
  spl_bimg_vx_cfg
  if [[ -n "$SPL_BIMG_VX_KEY" ]]; then
    vx=yes
    dom="$(spl_bimg_vx_domain "$SPL_BIMG_VX_KEY")"
    if [[ "${BLOG_IMAGE_CHECK_MINT:-1}" == 1 ]]; then
      spl_bimg_vx_header "$SPL_BIMG_VX_KEY" | grep '^Authorization: Bearer ' >/dev/null && mint=ok || mint=failed
    fi
  fi
  command -v "${BLOG_IMAGE_CWEBP:-cwebp}" >/dev/null 2>&1 && enc=yes
  [[ "$studio" == yes ]] && routes="aistudio"
  [[ "$vx" == yes && "$mint" != failed ]] && routes="${routes:+$routes+}vertex"
  [[ "$enc" == yes ]] || routes=""
  do_log "INFO aistudio_key $studio ${crs:-<no agent home>}"
  do_log "INFO vertex_cnf ${SPL_BIMG_VX_PROJECT:-<unset>}/${SPL_BIMG_VX_LOCATION:-<unset>}"
  do_log "INFO vertex_sa_key $vx ${SPL_BIMG_VX_KEY:-$SPL_BIMG_VX_WHY}${dom:+ (sa domain $dom)}"
  do_log "INFO vertex_token $mint"
  do_log "INFO encoder $enc ${BLOG_IMAGE_CWEBP:-cwebp}"
  [[ -n "$routes" ]] && { do_log "OK routes $routes"; return 0; }
  do_log "WARN routes none: a post gets no picture on this box"; return 1
}

# spl_bimg_vx_domain <key>: the domain part of the key's client_email.
spl_bimg_vx_domain() {
  local run=()
  [[ -r "$1" ]] || run=(sudo -n -u "$(stat -c %U "$1")")
  "${run[@]}" jq -r '.client_email // "" | sub("^[^@]*@"; "")' "$1" 2>/dev/null
}
