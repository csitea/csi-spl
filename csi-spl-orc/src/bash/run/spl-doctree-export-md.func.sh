#!/bin/bash
#------------------------------------------------------------------------------
# @description Write qto documents (spec 113 / 120, the workspace doctree) back
# @description to their md files in git. The qto doc is the primary copy; the
# @description md file is its export and says so in its second line ("generated
# @description from qto doc <id>; edit it there"). Which doc goes to which file
# @description is the map csi-spl-doc/doc/md/qto-docs.tsv (doc id, TAB, md path
# @description relative to the repo root); do_spl_doctree_import_md adds a row.
# @description Per doc it reads, through do_spl_desk_doctree (so no key or desk
# @description path reaches the caller), the head (title, hidden root), the
# @description root's body (the preamble before section 1) and the Markdown of
# @description `spool doctree export` (the WUI's export rules), and composes:
# @description title, generated-from line, preamble, the sections one heading
# @description level down. Byte-stable: an unchanged doc leaves the file as it
# @description is (not even rewritten); a changed node changes only its lines.
# @description It writes the worktree only; committing the result is the
# @description caller's (explicit pathspec).
# @param ENV - required: dev or prd (the hub the qto docs live on; t1's are prd)
# @param TENANT_ID - required: the workspace, e.g. t1
# @param DESK_AGENT - required: a seat of this box's desk (do_spl_desk_doctree)
# @param QTO_DOC (optional) - export this doc id only; default every map row
# @param QTO_MAP (optional) - default <repo>/csi-spl-doc/doc/md/qto-docs.tsv
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-914 ./run -a do_spl_doctree_export_md
#------------------------------------------------------------------------------
do_spl_doctree_export_md() {
  do_require_bin python3 || return 1
  local map="${QTO_MAP:-$APP_PATH/csi-spl-doc/doc/md/qto-docs.tsv}" want="${QTO_DOC:-}" doc rel n=0
  [[ -r "$map" ]] || { do_log "FATAL no qto doc map: $map"; return 1; }
  while IFS=$'\t' read -r doc rel; do
    [[ -n "$doc" && "$doc" != \#* ]] || continue
    [[ -z "$want" || "$doc" == "$want" ]] || continue
    _spl_doctree_export_one "$doc" "$rel" || return 1
    n=$((n + 1))
  done <"$map"
  (( n > 0 )) || { do_log "FATAL no row${want:+ for qto doc $want} in $map"; return 1; }
  do_log "OK $n qto doc(s) exported"
}

# _spl_doctree_export_one <doc id> <md path>: one doc to its md file; the file
# is replaced only when its bytes differ.
_spl_doctree_export_one() {
  local doc="$1" rel="$2" tmp root rc=0
  _spl_doctree_md_path "$rel" || return 1
  tmp="$(mktemp -d /tmp/doctree-export.XXXXXX)" || return 1
  _spl_doctree_call "head $doc" >"$tmp/head.json" &&
    root="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$tmp/head.json")" &&
    _spl_doctree_call "read $doc --item $root" >"$tmp/root.json" &&
    _spl_doctree_call "export $doc" >"$tmp/export.md" &&
    python3 "$PROJ_PATH/src/bash/run/spl-doctree-md.py" compose \
      "$tmp/head.json" "$tmp/root.json" "$tmp/export.md" "$doc" >"$tmp/out.md" || rc=1
  if (( rc )); then
    do_log "FATAL qto doc $doc was not exported: $(cat "$tmp"/*.json "$tmp/export.md" 2>/dev/null | tail -3)"
  elif cmp -s "$tmp/out.md" "$APP_PATH/$rel"; then
    do_log "OK $rel unchanged (qto doc $doc)"
  else
    cp "$tmp/out.md" "$APP_PATH/$rel" && do_log "OK $rel written from qto doc $doc" || rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# _spl_doctree_call <doctree args> [DOCTREE_IN]: one do_spl_desk_doctree verb,
# its output on stdout; writes run (DRY_RUN=0): the caller decided already.
_spl_doctree_call() {
  DOCTREE_ARGS="$1" DOCTREE_IN="${2:-}" DRY_RUN=0 do_spl_desk_doctree
}

# _spl_doctree_md_path <rel>: 0 for an .md path under csi-spl-doc/ of the repo.
_spl_doctree_md_path() {
  [[ "$1" == csi-spl-doc/*.md && "$1" != *..* ]] && return 0
  do_log "FATAL a qto export path must be an .md file under csi-spl-doc/ (repo-relative, no ..): '$1'"
  return 1
}
