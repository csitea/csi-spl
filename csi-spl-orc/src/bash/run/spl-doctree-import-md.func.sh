#!/bin/bash
#------------------------------------------------------------------------------
# @description Move a numbered md page of the repo into a qto document (spec
# @description 113 / 120), once: after it the qto doc is the primary copy and
# @description the md file its export (do_spl_doctree_export_md). The page is
# @description one '# ' title, a preamble, then numbered sections ('## 1. x',
# @description '### 1.1 y', '#### 1.1.1 z'); each section becomes a heading
# @description node at its level with its text as the node's body, and the
# @description preamble the body of the doc's hidden root. Refused before any
# @description hub call: a path off csi-spl-doc/*.md, a page already in the
# @description map, a section with no number or numbers the doc would not
# @description derive (the import never renumbers what others cite). After the
# @description writes it adds the map row and runs the export, so the md file
# @description carries its "generated from" line in the same run.
# @description Every hub call goes through do_spl_desk_doctree (no key path).
# @description Dry run unless DRY_RUN=0: prints the sections it would write.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the workspace, e.g. t1
# @param DESK_AGENT - required: a seat of this box's desk (do_spl_desk_doctree)
# @param MD_PATH - required: the md page, repo-relative, e.g. csi-spl-doc/doc/md/runbook-dispatcher.md
# @param QTO_FOLDER (optional) - the folder id to create the doc in; none = top level
# @param QTO_MAP (optional) - default <repo>/csi-spl-doc/doc/md/qto-docs.tsv
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-914 MD_PATH=csi-spl-doc/doc/md/runbook-dispatcher.md QTO_FOLDER=<folder id> DRY_RUN=0 ./run -a do_spl_doctree_import_md
#------------------------------------------------------------------------------
do_spl_doctree_import_md() {
  do_require_bin python3 || return 1
  local rel="${MD_PATH:-}" map="${QTO_MAP:-$APP_PATH/csi-spl-doc/doc/md/qto-docs.tsv}" tmp plan rc=0
  _spl_doctree_md_path "$rel" || return 1
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
    do_log "INFO DRY_RUN would create qto doc '$(cat "$tmp/title")' with $(wc -l <<<"$plan") sections:"
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
# its preamble and sections, then the map row and the export.
_spl_doctree_import_write() {
  local dir="$1" plan="$2" map="$3" rel="$4" out doc root args lvl num title body
  args="create --title $(_spl_doctree_q "$(cat "$dir/title")")"
  [[ -z "${QTO_FOLDER:-}" ]] || args+=" --folder $(_spl_doctree_q "$QTO_FOLDER")"
  out="$(_spl_doctree_call "$args")" || { do_log "$out"; return 1; }
  read -r doc root < <(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["id"], d["root"])' "$out") ||
    { do_log "FATAL create did not answer an id and a root: $out"; return 1; }
  do_log "INFO created qto doc $doc"
  if [[ -s "$dir/preamble.md" && -n "$(tr -d '[:space:]' <"$dir/preamble.md")" ]]; then
    out="$(_spl_doctree_call "edit $doc $root --field body" "$dir/preamble.md")" || { do_log "$out"; return 1; }
  fi
  while IFS=$'\t' read -r lvl num title body; do
    out="$(_spl_doctree_call "add $doc --kind heading --level $lvl --title $(_spl_doctree_q "$title")" "$body")" ||
      { do_log "FATAL section $num of $rel: $out (qto doc $doc is partial: delete it before a re-run)"; return 1; }
  done <<<"$plan"
  printf '%s\t%s\n' "$doc" "$rel" >>"$map"
  do_log "OK $rel imported as qto doc $doc ($(wc -l <<<"$plan") sections); map row added"
  QTO_MAP="$map" QTO_DOC="$doc" do_spl_doctree_export_md
}

# _spl_doctree_q <text>: one word for DOCTREE_ARGS (its shlex split).
_spl_doctree_q() {
  python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$1"
}
