#!/bin/bash

#------------------------------------------------------------------------------
# @description Fail when a md file that is a qto doc's export (spec 137, the
#   map csi-spl-doc/doc/md/qto-docs.tsv) drifts from its qto doc (SPL-2164).
#   Two checks:
#   map (default, no hub, well under a second; the cheap pre-push part and
#   CI run it):
#     1 each map row is <uuid> TAB <repo-relative .md> TAB <repo|workspace id>
#       ("repo" = the system tenant's repository docs; SPL-3541)
#     2 no doc id and no path is mapped twice
#     3 each mapped file exists and carries exactly one generated-from line
#       ("> Generated from qto doc `<id>`; edit it there. Workspace `<ws>`."),
#       naming ITS map id and ITS row's workspace
#     4 no md file carries a generated-from line without a map row; in a
#       git checkout only TRACKED md files are read, so a git-ignored
#       generated one (a terraform modules/README.md) is not (SPL-2307)
#     5 the known-drift list (QTO_DRIFT_KNOWN) names only files that still
#       fail 1-4: a fixed one must leave the list (a ratchet)
#     6 every row's and every stamp's workspace is in cnf
#       docs.repo_export_tenants (QTO_TENANT_CNF; spec 114 section 9.4.2,
#       SPL-3541): a private workspace's doc never lands in this PUBLIC
#       repository. A stamp naming no workspace, a bad row and an unreadable
#       or empty cnf list FAIL too, and the known-drift list never makes
#       one of these a WARN
#     7 the hand-copy check (SPL-3541): no md line equals a private
#       workspace doc's id, title or heading, by the hashed index of
#       do_spl_private_doc_index (QTO_PRIVATE_INDEX, outside the repo;
#       qto-private-index.py check). FAIL names file:line, never the text.
#       No index: a WARN that it was NOT RUN, or a FAIL once cnf
#       docs.private_index_required is true
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
# @param QTO_TENANT_CNF (optional) - default
#   <tree>/csi-spl-cnf/csi-spl/all.env.yaml, the cnf of rule 6
# @param QTO_PRIVATE_INDEX (optional) - rule 7's index; default
#   ${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/qto-private-index.txt
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
  local cnf="${QTO_TENANT_CNF:-$tree/csi-spl-cnf/csi-spl/all.env.yaml}"
  _qdd_map "$tree" "$map" "$known" "$cnf" || rc=1
  _qdd_private "$tree" "$cnf" || rc=1
  if [[ "${QTO_DRIFT_LIVE:-0}" == 1 ]]; then
    _qdd_live "$map" || rc=1
  fi
  return "$rc"
}

_qdd_log() { if declare -F do_log >/dev/null; then do_log "$*"; else echo "$*"; fi; }

# _qdd_map <tree> <map> <known> <cnf>: rules 1-6 of the header, by
# check-qto-doc-drift.py; one log line per finding.
_qdd_map() {
  local py out rc=0
  py="$(dirname "${BASH_SOURCE[0]}")/check-qto-doc-drift.py"
  out="$(python3 "$py" "$1" "$2" "$3" "$4")" || rc=$?
  while IFS= read -r line; do [[ -n "$line" ]] && _qdd_log "$line"; done <<<"$out"
  (( rc == 0 )) || _qdd_log "FAIL qto doc drift: export the doc again (cd csi-spl-orc && QTO_DOC=<id> ./run -a do_spl_doctree_export_md) or fix its map row"
  return "$rc"
}

# _qdd_private <tree> <cnf>: rule 7 of the header, by qto-private-index.py.
_qdd_private() {
  local py out rc=0
  local idx="${QTO_PRIVATE_INDEX:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/qto-private-index.txt}"
  py="$(dirname "${BASH_SOURCE[0]}")/qto-private-index.py"
  out="$(python3 "$py" check "$1" "$idx" "$2")" || rc=$?
  while IFS= read -r line; do [[ -n "$line" ]] && _qdd_log "$line"; done <<<"$out"
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
  awk -F'\t' -v w="$want" '/^#/ || NF < 2 { next } { fs = ($3 == "repo" ? "repo" : "workspace") } w == "" || fs == w' "$map" >"$tmp"
  QTO_MAP="$tmp" QTO_CHECK=1 do_spl_doctree_export_md || rc=1
  rm -f "$tmp"
  return "$rc"
}
