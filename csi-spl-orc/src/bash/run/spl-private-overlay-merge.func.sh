#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-5124: merge ONE list section into the private overlay of the
# @description running user on the overlay's master box (SPL_PRIVATE_MASTER_BOX,
# @description default sat). Adds the section, or replaces it when it exists.
# @description Refuses, before any write: another box; a section file that is
# @description a symlink, is not YAML, or is not exactly one top-level key
# @description holding a non-empty list of strings in the "  - item" form the
# @description overlay's readers parse; the sections that have their own
# @description owner (workspaces, forms_only, orgs, deny); an overlay that is
# @description not valid YAML; a result in which any other section differs.
# @description Backs the overlay up beside itself first, keeps its mode and
# @description ACL, and prints the section name and counts, never the content.
# @description It does not copy to the other user, box or the CI secret
# @description (csi-spl-doc/doc/md/private-overlay.md section 4).
# @param OVERLAY_SECTION_FILE - required: a YAML file holding the one section
# @param SPL_PRIVATE_CNF (optional) - the overlay, default the user's own
# @param SPL_PRIVATE_MASTER_BOX (optional) - default sat
# @param DRY_RUN (optional) - 1 (default): validate and report, write nothing. 0: merge.
# @example OVERLAY_SECTION_FILE=section.yaml DRY_RUN=0 ./run -a do_spl_private_overlay_merge
#------------------------------------------------------------------------------
do_spl_private_overlay_merge() {
  do_require_bin yq sha256sum || return 1
  local dry=1 master="${SPL_PRIVATE_MASTER_BOX:-sat}" here src="${OVERLAY_SECTION_FILE:-}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  here="$(spl_desk_box_default)"
  [[ "$here" == "$master" ]] || { do_log "FATAL this box ($here) does not hold the master private overlay (box $master): nothing merged"; return 1; }
  [[ -n "$src" && -f "$src" && -r "$src" && ! -L "$src" ]] || { do_log "FATAL OVERLAY_SECTION_FILE is unset, unreadable or a symlink: nothing merged"; return 1; }
  # shellcheck source=/dev/null
  source "$APP_PATH/csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh" || return 1
  spl_private_require 2>/dev/null || { do_log "FATAL no private overlay here: nothing merged"; return 1; }
  local f sec n h
  f="$(readlink -f "$(spl_private_cnf_path)")"
  sec="$(spl_pom_section_name "$src")" || return 1
  n="$(yq -r ".$sec | length" "$src")"
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$h'; trap - RETURN" RETURN
  spl_pom_build "$f" "$src" "$sec" "$h" || return 1
  if cmp -s "$f" "$h/new"; then do_log "OK section $sec already holds these $n entries: nothing to merge"; return 0; fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: back up the overlay and write section $sec ($n entries; before: $(yq -r ".$sec // [] | length" "$f"))"
    do_log "OK DRY_RUN nothing was merged. Re-run with DRY_RUN=0 to merge."
    return 0
  fi
  spl_pom_write "$f" "$h/new" "$sec" "$n"
}

# spl_pom_section_name <file> -> the file's one section name, or a FATAL.
spl_pom_section_name() {
  local sec bad
  [[ "$(yq -r 'keys | length' "$1" 2>/dev/null)" == 1 ]] || { do_log "FATAL the section file is not YAML with exactly one top-level key: nothing merged" >&2; return 1; }
  sec="$(yq -r 'keys | .[0]' "$1" 2>/dev/null)"
  [[ "$sec" =~ ^[a-z_]+$ ]] || { do_log "FATAL the section name is not [a-z_]+: nothing merged" >&2; return 1; }
  case "$sec" in
    customer_strings|customer_ignore|customer_channels) ;;
    workspaces|forms_only|orgs|deny) do_log "FATAL section $sec has its own owner (private-overlay.md section 2): nothing merged" >&2; return 1 ;;
    *) do_log "FATAL section $sec is not one of the three customer sections ruled for this action: nothing merged" >&2; return 1 ;;
  esac
  [[ "$(yq -r ".$sec | tag" "$1" 2>/dev/null)" == '!!seq' && "$(yq -r ".$sec | length" "$1" 2>/dev/null)" -gt 0 &&
     "$(yq -r "[.${sec}[] | select(tag != \"!!str\" or . == \"\")] | length" "$1" 2>/dev/null)" == 0 ]] ||
    { do_log "FATAL section $sec is not a non-empty list of strings: nothing merged" >&2; return 1; }
  bad="$(awk -v s="$sec:" '/^[[:space:]]*(#|$)/ { next } $0 == s && !h { h = 1; next } !/^  - [^[:space:]]/ || /[[:space:]]#/ { n++ } END { print n + 0 }' "$1")"
  [[ "$bad" == 0 ]] || { do_log "FATAL $bad line(s) of the section file are not in the form '  - item': nothing merged" >&2; return 1; }
  printf '%s\n' "$sec"
}

# spl_pom_build <overlay> <section file> <section> <dir>: <dir>/new is the overlay
# with the section replaced or appended, proven to change nothing else.
spl_pom_build() {
  local f="$1" src="$2" sec="$3" h="$4"
  yq -o=json 'del(.["'"$sec"'"])' "$f" >"$h/old.json" 2>/dev/null || { do_log "FATAL the overlay is not valid YAML: nothing merged"; return 1; }
  { awk -v want="$sec" '/^[^[:space:]#]/ { s = $0; sub(/:.*/, "", s) } s != want' "$f"; grep -vE '^[[:space:]]*(#|$)' "$src"; } >"$h/new"
  yq -o=json 'del(.["'"$sec"'"])' "$h/new" >"$h/new.json" 2>/dev/null || { do_log "FATAL the merged overlay is not valid YAML: nothing merged"; return 1; }
  cmp -s "$h/old.json" "$h/new.json" || { do_log "FATAL the merge would change another section: nothing merged"; return 1; }
  [[ "$(yq -o=json ".$sec" "$h/new" 2>/dev/null)" == "$(yq -o=json ".$sec" "$src" 2>/dev/null)" ]] ||
    { do_log "FATAL the merged section differs from the section file: nothing merged"; return 1; }
}

# spl_pom_write <overlay> <new> <section> <n>: backup, then an atomic replace
# that keeps the overlay's mode and ACL; the sha256 is checked after the move.
spl_pom_write() {
  local f="$1" new="$2" bak tmp sha
  bak="$f.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
  cp -p "$f" "$bak" || { do_log "FATAL cannot back up the overlay: nothing merged"; return 1; }
  tmp="$f.tmp.$$"
  cp -p "$f" "$tmp" && cat "$new" >"$tmp" || { rm -f "$tmp"; do_log "FATAL cannot write beside the overlay: nothing merged"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; do_log "FATAL cannot replace the overlay: nothing merged"; return 1; }
  sha="$(sha256sum <"$new" | cut -d' ' -f1)"
  [[ "$(sha256sum <"$f" | cut -d' ' -f1)" == "$sha" ]] || { do_log "FATAL the overlay does not read back as written; backup: $bak"; return 1; }
  do_log "OK section $3 merged ($4 entries), backup $bak. The other user, box and the CI secret are NOT updated (private-overlay.md section 4)"
}
