#!/bin/bash
#------------------------------------------------------------------------------
# @description The reverse of do_spl_i18n_mask: the reviewed agy/ copy with
# @description every token put back from map.tsv, written to I18N_UNMASK_DST
# @description (same relative paths). A token of map.tsv no longer in the copy
# @description (the review dropped or changed it) is listed as `missing <token>`
# @description and the exit is 4: read those lines by hand.
# @description The helpers and the matcher live in spl-i18n-mask.func.sh (./run
# @description sources every *.func.sh): one action per file for the loader.
# @param I18N_MASK_OUT (optional) - as do_spl_i18n_mask
# @param I18N_UNMASK_DST - required: where the unmasked text goes, outside agy/
# @example I18N_UNMASK_DST=<work>/locales.reviewed LANE_MIX_TASK=<task_id> ./run -a do_spl_i18n_unmask
#------------------------------------------------------------------------------
do_spl_i18n_unmask() {
  do_require_bin perl || return 1
  local out dst="${I18N_UNMASK_DST:-}" rel
  out="$(_spl_i18n_mask_out)" || return 1
  [[ -d "$out/agy" && -f "$out/map.tsv" ]] || { do_log "FATAL no masked copy under $out (run do_spl_i18n_mask first)"; return 1; }
  [[ -n "$dst" ]] || { do_log "FATAL I18N_UNMASK_DST must name where the unmasked text goes"; return 1; }
  dst="$(realpath -m "$dst")" out="$(realpath -m "$out")"
  _spl_i18n_mask_apart "$out/agy" "$dst" || return 1
  (cd "$out/agy" && find . -type f -printf '%P\n' | sort) | while IFS= read -r rel; do
    mkdir -p "$(dirname "$dst/$rel")"
    printf '%s\0%s\0' "$out/agy/$rel" "$dst/$rel"
  done | (umask 077; perl -e "$_SPL_I18N_MASK_PL" unmask "$out/map.tsv")
}
