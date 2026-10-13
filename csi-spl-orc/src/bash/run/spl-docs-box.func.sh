#!/bin/bash
#------------------------------------------------------------------------------
# @description Where an agy documentation lane starts (owner HUM-10, t1
# @description ee1e58d5, msgs 9466b9aa and cb1b623e, 2026-10-13). An agy lane
# @description whose kind is specs_and_docs, or the aliases spec, review and
# @description code_review, goes to sat when the measured map says sat has
# @description the agy CLI. Otherwise it falls back to the one other box in
# @description that map that has agy. When more than one other box has agy,
# @description the fallback is DOCS_BOX_FALLBACK, else SPOOL_BOX_TAG (the box
# @description this process runs on). The source does not name that box: the
# @description distribution sweep forbids the home box id. Any other vendor
# @description or kind is not this rule: the function prints nothing and the
# @description caller keeps the load pick. The CLI map is measured by the
# @description caller, never a hand-kept list. Wiring into spawn-window.sh is
# @description the vendor-CLI placement lane: call this before the load pick,
# @description then refuse a box that measurement says lacks agy.
# @param DOCS_BOX_VENDOR - the harness (agy, claude, ...)
# @param DOCS_BOX_KIND - LANE_MIX_KIND, aliases included
# @param DOCS_BOX_CLIS - space-separated box=vendor,vendor pairs
# @param DOCS_BOX_FALLBACK - which other box, when several have agy (optional)
# @example DOCS_BOX_VENDOR=agy DOCS_BOX_KIND=specs_and_docs DOCS_BOX_CLIS='sat=claude,agy pc=claude,agy' ./run -a do_spl_docs_box
#------------------------------------------------------------------------------

# spl_docs_box_pick VENDOR KIND CLIS [FALLBACK] -> one pick line, or nothing.
# CLIS is "sat=claude,agy pc=claude,agy". Return 0 on a pick or when the rule
# does not apply. Return 2 when the rule applies and no box has agy, or when
# sat has none and more than one other box does and no fallback is named.
spl_docs_box_pick() {
  local vendor="$1" kind="$2" clis="${3:-}" box has id prefer=0
  local fb="${4:-${DOCS_BOX_FALLBACK:-${SPOOL_BOX_TAG:-}}}"
  local fb_has=0 other="" n_other=0
  local -a pairs=()
  case "$vendor" in agy) ;; *) return 0 ;; esac
  case "$kind" in specs_and_docs|spec|review|code_review) ;; *) return 0 ;; esac
  read -r -a pairs <<< "$clis"
  for box in "${pairs[@]}"; do
    has=",${box#*=},"
    [[ "$has" == *,agy,* ]] || continue
    id="${box%%=*}"
    if [[ "$id" == sat ]]; then
      prefer=1
    elif [[ -n "$fb" && "$id" == "$fb" ]]; then
      fb_has=1
    else
      n_other=$((n_other + 1))
      other="$id"
    fi
  done
  if (( prefer )); then
    printf 'pick=sat reason=agy %s goes to sat: sat has the agy CLI\n' "$kind"
  elif (( fb_has )); then
    printf 'pick=%s reason=agy %s falls back to %s: sat has no agy CLI\n' "$fb" "$kind" "$fb"
  elif (( n_other == 1 )); then
    printf 'pick=%s reason=agy %s falls back to %s: sat has no agy CLI\n' "$other" "$kind" "$other"
  else
    printf 'pick= reason=agy %s has nowhere to go: sat has no agy CLI\n' "$kind"
    return 2
  fi
}

do_spl_docs_box() {
  [[ -n "${DOCS_BOX_VENDOR:-}" && -n "${DOCS_BOX_KIND:-}" ]] || {
    do_log "FATAL DOCS_BOX_VENDOR and DOCS_BOX_KIND are required"; return 1; }
  spl_docs_box_pick "$DOCS_BOX_VENDOR" "$DOCS_BOX_KIND" "${DOCS_BOX_CLIS:-}" "${DOCS_BOX_FALLBACK:-}"
}
