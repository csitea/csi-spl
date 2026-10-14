#!/bin/bash
#------------------------------------------------------------------------------
# @description Move an md page of the repo into a qto document (spec 113 /
# @description 120 / 137), once: after it the qto doc is the primary copy and
# @description the md file its export (do_spl_doctree_export_md). The page is
# @description an optional YAML front matter, one '# ' title, a preamble, then
# @description sections '## ' .. '###### ', numbered ('## 1. x', '### 1.1 y')
# @description or not ('## Overview': attrs.numbered false, no outline
# @description number; "## 1." keeps its dot, --dotted, SPL-1900); each section
# @description becomes a heading node at its level with
# @description its text as the node's body, the preamble the body of the doc's
# @description hidden root and the front matter its attrs.front_matter.
# @description Refused before any hub call: a path that is not a repo-relative
# @description .md file, a page already in the map, a heading that skips a
# @description level or numbers the doc would not derive (the import never
# @description renumbers what others cite). All or nothing: a write that fails
# @description deletes the doc it created, so no partial doc is left. After the
# @description writes it adds the map row and runs the export, so the md file
# @description carries its "generated from" line in the same run.
# @description Every hub call goes through do_spl_desk_doctree (no key path).
# @description Dry run unless DRY_RUN=0: prints the sections it would write.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace, e.g. t1
# @param DESK_AGENT - required: a seat of this box's desk (do_spl_desk_doctree)
# @param MD_PATH - required: the md page, repo-relative, e.g. csi-spl-doc/doc/md/runbook-dispatcher.md or README.md
# @param QTO_FS (optional) - the tree: workspace (default) or repo, the
# @param   repository docs (the system tenant, spec 137 T030a); repo adds the
# @param   map row with a third column "repo"
# @param QTO_FOLDER (optional) - the folder id to create the doc in; none = top level
# @param QTO_MAP (optional) - default <repo>/csi-spl-doc/doc/md/qto-docs.tsv
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-914 MD_PATH=csi-spl-doc/doc/md/runbook-dispatcher.md QTO_FOLDER=<folder id> DRY_RUN=0 ./run -a do_spl_doctree_import_md
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-914 MD_PATH=csi-spl-doc/doc/md/runbook-dispatcher.md QTO_FS=repo DRY_RUN=0 ./run -a do_spl_doctree_import_md
#------------------------------------------------------------------------------
do_spl_doctree_import_md() {
  do_require_bin python3 || return 1
  local rel="${MD_PATH:-}" map="${QTO_MAP:-$APP_PATH/csi-spl-doc/doc/md/qto-docs.tsv}" tmp plan rc=0
  _spl_doctree_md_path "$rel" || return 1
  _spl_doctree_fs "${QTO_FS:-}" || return 1
  [[ -r "$APP_PATH/$rel" ]] || { do_log "FATAL no such md page: $rel"; return 1; }
  if [[ -r "$map" ]] && cut -f2 "$map" | grep -xF -- "$rel" >/dev/null; then
    do_log "FATAL $rel is already a qto doc export (a row in $map): edit the qto doc, then do_spl_doctree_export_md"
    return 1
  fi
  tmp="$(mktemp -d /tmp/doctree-import.XXXXXX)" || return 1
  if ! plan="$(python3 "$PROJ_PATH/src/bash/run/spl-doctree-md.py" split "$APP_PATH/$rel" "$tmp" 2>&1)"; then
    do_log "$plan"; rm -rf "$tmp"; return 1
  fi
  local drc=0
  spl_dry_run || drc=$?
  if (( drc == 0 )); then
    do_log "INFO DRY_RUN would create qto doc '$(cat "$tmp/title")' with $(wc -l <<<"$plan") sections in the ${QTO_FS:-workspace} tree:"
    cut -f2,3 <<<"$plan" | sed 's/^/  /'
    do_log "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0 to run it."
    rm -rf "$tmp"; return 0
  fi
  (( drc == 1 )) || { rm -rf "$tmp"; return 1; }
  _spl_doctree_import_write "$tmp" "$plan" "$map" "$rel" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

# _spl_doctree_import_write <split dir> <plan> <map> <rel>: create the doc,
# its front matter, preamble and sections, then the map row and the export.
# A failed write after the create deletes the doc (all or nothing).
_spl_doctree_import_write() {
  local dir="$1" plan="$2" map="$3" rel="$4" out doc root args
  args="create --title $(_spl_doctree_q "$(cat "$dir/title")")"
  [[ -z "${QTO_FOLDER:-}" ]] || args+=" --folder $(_spl_doctree_q "$QTO_FOLDER")"
  out="$(_spl_doctree_call "$args")" || { do_log "$out"; return 1; }
  read -r doc root < <(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["id"], d["root"])' "$out") ||
    { do_log "FATAL create did not answer an id and a root: $out"; return 1; }
  do_log "INFO created qto doc $doc"
  if ! out="$(_spl_doctree_import_items "$dir" "$plan" "$doc" "$root")"; then
    do_log "FATAL $rel: $out"
    _spl_doctree_import_rollback "$doc"
    return 1
  fi
  if [[ "${QTO_FS:-}" == repo ]]; then
    printf '%s\t%s\trepo\n' "$doc" "$rel" >>"$map"
  else
    printf '%s\t%s\n' "$doc" "$rel" >>"$map"
  fi
  do_log "OK $rel imported as qto doc $doc ($(wc -l <<<"$plan") sections); map row added"
  QTO_MAP="$map" QTO_DOC="$doc" do_spl_doctree_export_md
}

# _spl_doctree_import_items <split dir> <plan> <doc> <root>: the writes into
# the created doc; stops at the first failure, its reason on stdout.
_spl_doctree_import_items() {
  local dir="$1" plan="$2" doc="$3" root="$4" out lvl num title body gap flag
  if [[ -f "$dir/front_matter.yml" ]]; then
    out="$(_spl_doctree_call "edit $doc $root --field attrs.front_matter" "$dir/front_matter.yml")" ||
      { echo "the front matter: $out"; return 1; }
  fi
  if [[ -s "$dir/preamble.md" && -n "$(tr -d '[:space:]' <"$dir/preamble.md")" ]]; then
    out="$(_spl_doctree_call "edit $doc $root --field body" "$dir/preamble.md")" || { echo "the preamble: $out"; return 1; }
  fi
  while IFS=$'\t' read -r lvl num title body gap; do
    [[ -n "$lvl" ]] || continue # a page with no section: an empty plan (SPL-1909)
    flag=""
    [[ "$num" != "-" ]] || flag=" --unnumbered"
    [[ "$num" != *. ]] || flag=" --dotted"
    [[ ",$gap," != *,tight,* ]] || flag+=" --tight"
    [[ ",$gap," != *,tight_end,* ]] || flag+=" --tight-end"
    out="$(_spl_doctree_call "add $doc --kind heading --level $lvl$flag --title $(_spl_doctree_q "$title")" "$body")" ||
      { echo "section $num $title: $out"; return 1; }
  done <<<"$plan"
}

# _spl_doctree_import_rollback <doc>: delete the doc a failed import created.
_spl_doctree_import_rollback() {
  local out
  if out="$(_spl_doctree_call "delete $1")"; then
    do_log "INFO rolled back: qto doc $1 deleted, nothing of the import is left"
  else
    do_log "FATAL the rollback failed, qto doc $1 is partial: delete it by hand ($out)"
  fi
}

# _spl_doctree_q <text>: one word for DOCTREE_ARGS (its shlex split).
_spl_doctree_q() {
  python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$1"
}
