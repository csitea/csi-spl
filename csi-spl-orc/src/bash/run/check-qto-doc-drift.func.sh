#!/bin/bash

#------------------------------------------------------------------------------
# @description Fail when a md file that is a qto doc's export (spec 137, the
#   map csi-spl-doc/doc/md/qto-docs.tsv) drifts from its qto doc (SPL-2164).
#   Two checks:
#   map (default, no hub, well under a second; the cheap pre-push part and
#   CI run it):
#     1 each map row is <uuid> TAB <repo-relative .md> [TAB workspace|repo]
#     2 no doc id and no path is mapped twice
#     3 each mapped file exists and carries exactly one generated-from line
#       ("> Generated from qto doc `<id>`"), naming ITS map id
#     4 no md file carries a generated-from line without a map row; in a
#       git checkout only TRACKED md files are read, so a git-ignored
#       generated one (a terraform modules/README.md) is not (SPL-2307)
#     5 the known-drift list (QTO_DRIFT_KNOWN) names only files that still
#       fail 1-4: a fixed one must leave the list (a ratchet)
#   It cannot see a hand edit of the text under a correct stamp: the qto docs
#   live on the hub (the system tenant for "repo" rows, spec 137 unified-fs.md
#   section 1), which CI cannot reach. That is the live check:
#   live (QTO_DRIFT_LIVE=1, a box with a seated desk): exports every mapped
#   doc in compare mode (do_spl_doctree_export_md QTO_CHECK=1, nothing
#   written) and fails on each file whose bytes differ from its qto doc's
#   export, naming it. QTO_DRIFT_FS=repo|workspace limits it to one tree.
#   Read-only. A failure names the file and the rule.
# @param QTO_DRIFT_TREE (optional) - default: $APP_PATH, the checkout to read
# @param QTO_MAP (optional) - default <tree>/csi-spl-doc/doc/md/qto-docs.tsv
# @param QTO_DRIFT_KNOWN (optional) - default
#   <tree>/csi-spl-doc/doc/md/qto-docs-drift-known.tsv (path TAB reason): the
#   files the map check reports as WARN, not FAIL
# @param QTO_DRIFT_LIVE (optional) - 1: also the live check; then ENV,
#   TENANT_ID and DESK_AGENT are required (do_spl_doctree_export_md)
# @param QTO_DRIFT_FS (optional) - live only: repo or workspace; default both
# @example ./run -a do_check_qto_doc_drift
# @example QTO_DRIFT_LIVE=1 ENV=prd TENANT_ID=t1 DESK_AGENT=<seat> ./run -a do_check_qto_doc_drift
#------------------------------------------------------------------------------
do_check_qto_doc_drift() {
  local tree="${QTO_DRIFT_TREE:-${APP_PATH:-}}" rc=0
  [[ -n "$tree" && -d "$tree" ]] || { _qdd_log "FATAL QTO_DRIFT_TREE is not a directory: '$tree'"; return 1; }
  local map="${QTO_MAP:-$tree/csi-spl-doc/doc/md/qto-docs.tsv}"
  local known="${QTO_DRIFT_KNOWN:-$tree/csi-spl-doc/doc/md/qto-docs-drift-known.tsv}"
  [[ -r "$map" ]] || { _qdd_log "FATAL no qto doc map: $map"; return 1; }
  command -v python3 >/dev/null || { _qdd_log "FATAL python3 is not on PATH"; return 1; }
  _qdd_map "$tree" "$map" "$known" || rc=1
  if [[ "${QTO_DRIFT_LIVE:-0}" == 1 ]]; then
    _qdd_live "$map" || rc=1
  fi
  return "$rc"
}

_qdd_log() { if declare -F do_log >/dev/null; then do_log "$*"; else echo "$*"; fi; }

# _qdd_map <tree> <map> <known>: rules 1-5 of the header, by
# check-qto-doc-drift.py; one log line per finding.
_qdd_map() {
  local py out rc=0
  py="$(dirname "${BASH_SOURCE[0]}")/check-qto-doc-drift.py"
  out="$(python3 "$py" "$1" "$2" "$3")" || rc=$?
  while IFS= read -r line; do [[ -n "$line" ]] && _qdd_log "$line"; done <<<"$out"
  (( rc == 0 )) || _qdd_log "FAIL qto doc drift: export the doc again (cd csi-spl-orc && QTO_DOC=<id> ./run -a do_spl_doctree_export_md) or fix its map row"
  return "$rc"
}

# _qdd_live <map>: the mapped docs exported in compare mode (QTO_CHECK=1),
# only the rows of QTO_DRIFT_FS when it is set.
_qdd_live() {
  local map="$1" want="${QTO_DRIFT_FS:-}" tmp rc=0
  [[ -z "$want" || "$want" == repo || "$want" == workspace ]] ||
    { _qdd_log "FATAL QTO_DRIFT_FS is repo or workspace, not '$want'"; return 1; }
  declare -F do_spl_doctree_export_md >/dev/null ||
    { _qdd_log "FATAL the live check needs do_spl_doctree_export_md: run it through csi-spl-orc ./run"; return 1; }
  tmp="$(mktemp /tmp/qto-drift-map.XXXXXX)" || return 1
  awk -F'\t' -v w="$want" '/^#/ || NF < 2 { next } { fs = ($3 == "" ? "workspace" : $3) } w == "" || fs == w' "$map" >"$tmp"
  QTO_MAP="$tmp" QTO_CHECK=1 do_spl_doctree_export_md || rc=1
  rm -f "$tmp"
  return "$rc"
}
