#!/bin/bash
#------------------------------------------------------------------------------
# @description The ONE path from this private repo to the public tree (spec 044
# @description T002/T004, FR-OS-001/004). `git archive` of a ref, restricted to
# @description the allow-list csi-spl-orc/cnf/oss/export-allow-list.txt, into a
# @description FRESH dir: committed content only, no .git, no history, no
# @description untracked or ignored file (node_modules, tpl-gen, local env).
# @description Then do_oss_gate on the result; the export's exit code is the
# @description gate's. Never creates a repo, never pushes, never commits: the
# @description first commit of the public repo is the owner's step (T033, D1).
# @description An allow-list entry that is missing at the ref fails the export
# @description unless it is marked optional ('?'). An entry that names a path
# @description outside the repo, or an absolute path, is refused.
# @param OUT_DIR - required: a new or empty dir OUTSIDE this checkout
# @param OSS_REF (optional) - default HEAD; e.g. origin/master
# @param OSS_ALLOW_LIST (optional) - default csi-spl-orc/cnf/oss/export-allow-list.txt
# @param OSS_GATE (optional) - 1 (default) runs do_oss_gate DIR=OUT_DIR; 0 = export only
# @example OUT_DIR=/var/tmp/oss/spool OSS_REF=origin/master ./run -a do_oss_export
#------------------------------------------------------------------------------

# oss_allow_paths <allow-list> <repo> <ref> - print the paths to archive, one
# per line; non-zero when a required entry is missing or an entry is unsafe.
oss_allow_paths() {
  local list="$1" repo="$2" ref="$3" line opt p bad=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    opt=0; [[ "$line" == \?* ]] && { opt=1; line="${line#\?}"; }
    p="${line%/}"
    if [[ "$p" == /* || "/$p/" == */../* || "$p" == . || -z "$p" ]]; then
      echo "unsafe allow-list entry: '$line'" >&2; bad=1; continue
    fi
    if git -C "$repo" cat-file -e "$ref:$p" 2>/dev/null; then
      echo "$p"
    elif (( opt )); then
      echo "optional entry absent at $ref: $p" >&2
    else
      echo "required allow-list entry absent at $ref: $p" >&2; bad=1
    fi
  done <"$list"
  return "$bad"
}

do_oss_export() {
  do_require_bin git tar || return 2
  local out="${OUT_DIR:-}" ref="${OSS_REF:-HEAD}" sha paths
  local list="${OSS_ALLOW_LIST:-${PROJ_PATH:-$APP_PATH/csi-spl-orc}/cnf/oss/export-allow-list.txt}"
  [[ -n "$out" ]] || { do_log "FATAL OUT_DIR must name the export dir"; return 2; }
  [[ -f "$list" ]] || { do_log "FATAL no allow-list at $list"; return 2; }
  mkdir -p "$out" || { do_log "FATAL cannot create $out"; return 2; }
  out=$(cd "$out" && pwd)
  local repo; repo=$(cd "$APP_PATH" && pwd)
  [[ "$out/" != "$repo/"* ]] || { do_log "FATAL OUT_DIR $out is inside the checkout $repo"; return 2; }
  [[ -z "$(ls -A "$out")" ]] || { do_log "FATAL OUT_DIR $out is not empty - the export writes a fresh tree only"; return 2; }
  sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}" 2>/dev/null) \
    || { do_log "FATAL OSS_REF '$ref' is not a commit"; return 2; }
  paths=$(oss_allow_paths "$list" "$repo" "$sha") || { do_log "FATAL the allow-list is not satisfiable at $sha"; return 2; }
  [[ -n "$paths" ]] || { do_log "FATAL the allow-list yields no path"; return 2; }
  local -a arr; mapfile -t arr <<<"$paths"
  git -C "$repo" archive --format=tar "$sha" -- "${arr[@]}" | tar -xf - -C "$out" \
    || { do_log "FATAL git archive of $sha failed"; return 2; }
  do_log "INFO exported $(find "$out" -type f | wc -l) file(s) of ${#arr[@]} allow-list path(s) at $sha into $out (no history)"
  [[ "${OSS_GATE:-1}" == 0 ]] && { do_log "INFO OSS_GATE=0: the gate was NOT run - this tree is unproven"; return 0; }
  DIR="$out" do_oss_gate
}
