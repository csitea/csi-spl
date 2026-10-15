#!/bin/bash
#------------------------------------------------------------------------------
# @description Write qto documents (spec 113 / 120, the workspace doctree) back
# @description to their md files in git. The qto doc is the primary copy; the
# @description md file is its export and says so in its second line ("generated
# @description from qto doc <id>; edit it there"). Which doc goes to which file
# @description is the map csi-spl-doc/doc/md/qto-docs.tsv (doc id, TAB, md path
# @description relative to the repo root, and a third column "repo" for a doc
# @description of the repository docs, the system tenant, spec 137 T030a);
# @description do_spl_doctree_import_md adds a row.
# @description Per doc it reads, through do_spl_desk_doctree (so no key or desk
# @description path reaches the caller), the head (title, hidden root), the
# @description root read (its attrs.front_matter) and the Markdown of
# @description `spool doctree export` (the WUI's export rules: it opens with
# @description the preamble, the root's body before section 1, SPL-1612), and
# @description composes: front matter, title, generated-from line, preamble,
# @description the sections one heading level down, each heading after its
# @description section anchor line `<a id="ws-doc-<item id>"></a>` (spec 138 G4:
# @description the WUI's section link lands in the md too; the import drops
# @description it). Any repo-relative .md path (spec 137 T017). Byte-stable: an unchanged doc leaves the file as it
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
  local map="${QTO_MAP:-$APP_PATH/csi-spl-doc/doc/md/qto-docs.tsv}" want="${QTO_DOC:-}" doc rel fs n=0
  [[ -r "$map" ]] || { do_log "FATAL no qto doc map: $map"; return 1; }
  while IFS=$'\t' read -r doc rel fs; do
    [[ -n "$doc" && "$doc" != \#* ]] || continue
    [[ -z "$want" || "$doc" == "$want" ]] || continue
    _spl_doctree_fs "$fs" || return 1
    QTO_FS="$fs" _spl_doctree_export_one "$doc" "$rel" || return 1
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

# _spl_doctree_call <doctree args> [DOCTREE_IN]: one do_spl_desk_doctree verb
# in the tree QTO_FS names, its output on stdout; writes run (DRY_RUN=0): the
# caller decided already.
_spl_doctree_call() {
  DOCTREE_ARGS="$1" DOCTREE_IN="${2:-}" DOCTREE_FS="${QTO_FS:-}" DRY_RUN=0 do_spl_desk_doctree
}

# _spl_doctree_fs <fs>: 0 for a qto tree: "" or workspace (the workspace's
# docs) or repo (the repository docs, spec 137 T030a).
_spl_doctree_fs() {
  [[ "$1" == "" || "$1" == workspace || "$1" == repo ]] && return 0
  do_log "FATAL a qto tree is workspace or repo, not '$1'"
  return 1
}

# _spl_doctree_md_path <rel>: 0 for a repo-relative .md path (no leading /,
# no .. step, no .git/ part).
_spl_doctree_md_path() {
  local p="/$1/"
  [[ "$1" == *?.md && "$1" != /* && "$p" != */../* && "$p" != */./* && "$p" != */.git/* && "$1" != *//* ]] && return 0
  do_log "FATAL a qto export path must be a repo-relative .md file (no leading /, no . or .. step, not under .git/): '$1'"
  return 1
}
