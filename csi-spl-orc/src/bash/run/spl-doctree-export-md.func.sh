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
# @description it). The doc's pictures (its root's attrs.assets, spec 137
# @description unified-fs.md section 7, SPL-2201) are written back next to the
# @description md, each to its relative path <page>.assets/NN-name.ext, byte
# @description for byte (spool doctree asset-get). Any repo-relative .md path (spec 137 T017). Byte-stable: an unchanged doc leaves the file as it
# @description is (not even rewritten); a changed node changes only its lines.
# @description It writes the worktree only; committing the result is the
# @description caller's (explicit pathspec).
# @param ENV - required: dev or prd (the hub the qto docs live on; t1's are prd)
# @param TENANT_ID - required: the workspace, e.g. t1; refused unless cnf
# @param   docs.repo_export_tenants lists it (the workspaces the owner allows
# @param   into the PUBLIC repository, spec 114 section 9.4.2), in compare mode too
# @param   A workspace that cnf docs.private_repos maps to a PRIVATE repository
# @param   (owner HUM-10, csitea 8c223c17 msg 2b3de92e, SPL-3543) is exported
# @param   into a clone of THAT repository instead, never into this one
# @param QTO_PRIVATE_REPO_DIR - required for a mapped workspace: the clone of
# @param   its private repository (its origin must be that repository; this
# @param   repository, a path inside it, or a clone of csi-spl is refused); the
# @param   md paths and the map (<clone>/qto-docs.tsv) are relative to it
# @param QTO_MAP_SEED (optional) - 1, a mapped workspace only: before the
# @param   export, add a map row docs/<title slug>.md for every doc of the
# @param   workspace (doctree list) that has none
# @param QTO_TENANT_CNF (optional) - default <repo>/csi-spl-cnf/csi-spl/all.env.yaml
# @param DESK_AGENT - required: a seat of this box's desk (do_spl_desk_doctree)
# @param QTO_DOC (optional) - export this doc id only; default every map row
# @param QTO_MAP (optional) - default <repo>/csi-spl-doc/doc/md/qto-docs.tsv
# @param QTO_CHECK (optional) - 1: compare only, write nothing: each file
# @param   whose bytes differ from its doc's export is a FAIL naming it (a diff
# @param   head below it), every row is still read, and the run fails at the
# @param   end (do_check_qto_doc_drift QTO_DRIFT_LIVE=1, SPL-2164). Pictures
# @param   are not compared.
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-914 ./run -a do_spl_doctree_export_md
# @example ENV=prd TENANT_ID=csitea DESK_AGENT=c-914 QTO_PRIVATE_REPO_DIR=/opt/csi/csitea-ws-docs QTO_MAP_SEED=1 ./run -a do_spl_doctree_export_md
#------------------------------------------------------------------------------
do_spl_doctree_export_md() {
  do_require_bin python3 || return 1
  local QTO_ROOT QTO_PRIVATE_REPO map want="${QTO_DOC:-}" doc rel fs n=0 drift=0 rc
  _spl_doctree_target do_spl_doctree_export_md || return 1
  map="${QTO_MAP:-$QTO_ROOT/csi-spl-doc/doc/md/qto-docs.tsv}"
  [[ -z "$QTO_PRIVATE_REPO" ]] || map="$QTO_ROOT/qto-docs.tsv"
  [[ "${QTO_MAP_SEED:-0}" != 1 ]] || _spl_doctree_map_seed "$map" || return 1
  [[ -r "$map" ]] || { do_log "FATAL no qto doc map: $map"; return 1; }
  [[ "${QTO_CHECK:-0}" == 1 ]] || spl_refuse_desk_cron_tree do_spl_doctree_export_md || return 1
  while IFS=$'\t' read -r doc rel fs; do
    [[ -n "$doc" && "$doc" != \#* ]] || continue
    [[ -z "$want" || "$doc" == "$want" ]] || continue
    _spl_doctree_fs "$fs" || return 1
    rc=0
    QTO_FS="$fs" _spl_doctree_export_one "$doc" "$rel" || rc=$?
    (( rc == 0 || rc == 3 )) || return 1
    (( rc == 3 )) && drift=$((drift + 1))
    n=$((n + 1))
  done <"$map"
  (( n > 0 )) || { do_log "FATAL no row${want:+ for qto doc $want} in $map"; return 1; }
  if [[ "${QTO_CHECK:-0}" == 1 ]]; then
    (( drift == 0 )) || { do_log "FAIL $drift of $n md file(s) differ from their qto doc (above)"; return 1; }
    do_log "OK $n md file(s) equal their qto doc's export"
    return 0
  fi
  do_log "OK $n qto doc(s) exported"
}

# _spl_doctree_export_one <doc id> <md path>: one doc to its md file; the file
# is replaced only when its bytes differ. QTO_CHECK=1: nothing is written, and
# a file that differs returns 3.
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
  elif cmp -s "$tmp/out.md" "$QTO_ROOT/$rel"; then
    do_log "OK $rel unchanged (qto doc $doc)"
  elif [[ "${QTO_CHECK:-0}" == 1 ]]; then
    do_log "FAIL $rel differs from qto doc $doc: a hand edit, or a Qto edit not exported yet"
    diff -u --label "$rel" --label "qto doc $doc" "$QTO_ROOT/$rel" "$tmp/out.md" >"$tmp/drift.diff" 2>&1
    sed -n 1,12p "$tmp/drift.diff"
    rm -rf "$tmp"
    return 3
  else
    mkdir -p "$(dirname "$QTO_ROOT/$rel")" && cp "$tmp/out.md" "$QTO_ROOT/$rel" && do_log "OK $rel written from qto doc $doc" || rc=1
  fi
  (( rc )) || [[ "${QTO_CHECK:-0}" == 1 ]] || _spl_doctree_export_assets "$doc" "$rel" "$tmp" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

# _spl_doctree_export_assets <doc id> <md path> <tmp dir>: each picture the
# doc's root names (tmp/root.json) to <md dir>/<its path>; a file that holds
# the same bytes is not rewritten.
_spl_doctree_export_assets() {
  local doc="$1" rel="$2" tmp="$3" paths path dest how
  paths="$(python3 "$PROJ_PATH/src/bash/run/spl-doctree-md.py" assets "$tmp/root.json")" || { do_log "$paths"; return 1; }
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    dest="$QTO_ROOT/$(dirname "$rel")/$path"
    if ! _spl_doctree_call "asset-get $doc $(_spl_doctree_q "$path")" >"$tmp/asset.json" ||
      ! how="$(python3 "$PROJ_PATH/src/bash/run/spl-doctree-md.py" asset-write "$tmp/asset.json" "$dest" 2>&1)"; then
      do_log "FATAL picture $path of qto doc $doc was not exported: $(tail -c 300 "$tmp/asset.json") $how"
      return 1
    fi
    do_log "OK $(dirname "$rel")/$path $how (qto doc $doc)"
  done <<<"$paths"
}

# _spl_doctree_tenant_allowed <action>: 0 when TENANT_ID is in cnf
# docs.repo_export_tenants (spec 114 section 9.4.2, SPL-2950): a workspace's
# docs reach the PUBLIC repository only when the owner listed it. No list, an
# unreadable cnf or an empty TENANT_ID is a refusal, never a pass.
_spl_doctree_tenant_allowed() {
  local cnf="${QTO_TENANT_CNF:-$PROJ_PATH/../csi-spl-cnf/csi-spl/all.env.yaml}" list
  list="$(yq -r '.env.docs.repo_export_tenants // [] | .[]' "$cnf" 2>/dev/null)" ||
    { do_log "FATAL $1: cnf docs.repo_export_tenants is not readable in $cnf"; return 1; }
  [[ -n "${TENANT_ID:-}" ]] && grep -qxF -- "$TENANT_ID" <<<"$list" && return 0
  do_log "FATAL $1 refuses workspace '${TENANT_ID:-}': not in cnf docs.repo_export_tenants ($(tr '\n' ' ' <<<"$list" | sed 's/ $//')); its docs never go to the public repository"
  return 1
}

# _spl_doctree_target <action>: where TENANT_ID's md files go; sets QTO_ROOT
# and QTO_PRIVATE_REPO. A workspace cnf docs.private_repos maps to a private
# repository (SPL-3543) goes ONLY to QTO_PRIVATE_REPO_DIR, a clone of that
# repository outside this one, and only by the export (the hub keeps the
# primary copy, no import from it: owner polls 7aef27b6 / f76e38e4). Any other
# workspace goes to this repository when docs.repo_export_tenants lists it.
_spl_doctree_target() {
  local cnf="${QTO_TENANT_CNF:-$PROJ_PATH/../csi-spl-cnf/csi-spl/all.env.yaml}" dir app origin
  QTO_ROOT="$APP_PATH"
  QTO_PRIVATE_REPO="$(TENANT_ID="${TENANT_ID:-}" yq -r '.env.docs.private_repos[strenv(TENANT_ID)] // ""' "$cnf" 2>/dev/null)" ||
    QTO_PRIVATE_REPO=""
  if [[ -z "$QTO_PRIVATE_REPO" || -z "${TENANT_ID:-}" ]]; then
    QTO_PRIVATE_REPO=""
    _spl_doctree_tenant_allowed "$1"
    return
  fi
  if [[ ! "$QTO_PRIVATE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    do_log "FATAL $1: cnf docs.private_repos maps '$TENANT_ID' to '$QTO_PRIVATE_REPO', not <owner>/<repo>"
    return 1
  fi
  if grep -qxF -- "$TENANT_ID" <<<"$(yq -r '.env.docs.repo_export_tenants // [] | .[]' "$cnf" 2>/dev/null)"; then
    do_log "FATAL $1: workspace '$TENANT_ID' is in both cnf docs.private_repos and docs.repo_export_tenants; fix the cnf"
    return 1
  fi
  if [[ "$1" != do_spl_doctree_export_md ]]; then
    do_log "FATAL $1 refuses workspace '$TENANT_ID': its docs are exported to its private repository $QTO_PRIVATE_REPO only (an export copy, no import)"
    return 1
  fi
  dir="${QTO_PRIVATE_REPO_DIR:-}"
  [[ -n "$dir" && -d "$dir" ]] && dir="$(cd "$dir" && pwd -P)" && app="$(cd "$APP_PATH" && pwd -P)" ||
    { do_log "FATAL $1: workspace '$TENANT_ID' needs QTO_PRIVATE_REPO_DIR, a clone of $QTO_PRIVATE_REPO (got '${QTO_PRIVATE_REPO_DIR:-}')"; return 1; }
  if [[ "$dir/" == "$app/"* || "$app/" == "$dir/"* ]]; then
    do_log "FATAL $1 refuses QTO_PRIVATE_REPO_DIR $dir for workspace '$TENANT_ID': it is or holds this public repository"
    return 1
  fi
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"
  origin="${origin%/}" && origin="${origin%.git}"
  if [[ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" != "$dir" || "$origin" != *[:/]"$QTO_PRIVATE_REPO" ]]; then
    do_log "FATAL $1 refuses QTO_PRIVATE_REPO_DIR $dir for workspace '$TENANT_ID': not the top of a clone of $QTO_PRIVATE_REPO (origin '$origin')"
    return 1
  fi
  if [[ -n "${QTO_MAP:-}" ]]; then
    do_log "FATAL $1: QTO_MAP is not used for workspace '$TENANT_ID': its map is $dir/qto-docs.tsv"
    return 1
  fi
  QTO_ROOT="$dir"
  do_log "INFO workspace '$TENANT_ID' exports to its private repository $QTO_PRIVATE_REPO ($dir)"
}

# _spl_doctree_map_seed <map>: a workspace with a private repository only: a
# row docs/<doc id>.md for each doc of `doctree list` the map lacks. The path
# is the id, not the title: no doc text reaches a log, and a renamed doc keeps
# its file.
_spl_doctree_map_seed() {
  local map="$1" out
  if [[ -z "$QTO_PRIVATE_REPO" || "${QTO_CHECK:-0}" == 1 ]]; then
    do_log "FATAL QTO_MAP_SEED=1 is for the export of a workspace with a private repository, not in compare mode"
    return 1
  fi
  out="$(QTO_FS=workspace _spl_doctree_call list)" || { do_log "FATAL doctree list failed: $(tail -c 300 <<<"$out")"; return 1; }
  out="$(python3 -c '
import json, os, re, sys
uuid = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
mapf, docs = sys.argv[1], json.loads(sys.stdin.read()).get("docs") or []
have = set()
if os.path.exists(mapf):
    have = {l.split("	")[0] for l in open(mapf, encoding="utf-8") if l.strip() and not l.startswith("#")}
new = [d["id"] for d in docs if uuid.match(str(d.get("id", ""))) and d["id"] not in have]
with open(mapf, "a", encoding="utf-8") as fh:
    if not os.path.getsize(mapf):
        fh.write("# qto doc id TAB md path in this repository (do_spl_doctree_export_md, SPL-3543)\n")
    for i in new:
        fh.write(f"{i}\tdocs/{i}.md\n")
print(len(new), len(docs))' "$map" <<<"$out")" || { do_log "FATAL the map $map was not seeded: $out"; return 1; }
  do_log "OK map seeded: ${out% *} row(s) added for ${out#* } doc(s) of workspace '$TENANT_ID'"
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
