#!/bin/bash
#------------------------------------------------------------------------------
# @description Build the private doc index of the hand-copy check (SPL-3541,
# @description spec 114 section 9.4 guard 2): for each PRIVATE workspace (a
# @description tenant NOT in cnf docs.repo_export_tenants) the id, the title
# @description and every section heading of each of its qto docs, as HASHES
# @description only (qto-private-index.py build), in a file OUTSIDE the repo,
# @description mode 600. do_check_qto_doc_drift (rule 7) and the wf 10 step
# @description then fail a pushed md file that holds one of them. No title is
# @description written, logged or printed: the log says counts only. Text
# @description the public repo already holds is dropped (no leak, and the
# @description fleet's template headings would else fail every brief).
# @description Reads the hub only (do_spl_desk_doctree list / export); writes
# @description the index file only. A dry run (the default) calls nothing.
# @description Rebuild it often: a public heading added after the build that a
# @description private doc also has fails the check until the next build.
# @param ENV - required: dev or prd (the hub the workspaces live on)
# @param PRIVATE_INDEX_TENANTS - required: the private workspaces, space
# @param   separated; one in docs.repo_export_tenants is refused
# @param PRIVATE_INDEX_SEAT - required: the seat (an agent id) seated in each
# @param   of those workspaces' desks on this box (do_spl_desk_doctree)
# @param QTO_PRIVATE_INDEX (optional) - the index file; default
# @param   ${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/qto-private-index.txt;
# @param   a path inside this repository is refused
# @param QTO_TENANT_CNF (optional) - default <repo>/csi-spl-cnf/csi-spl/all.env.yaml
# @param DRY_RUN (optional) - 1 (default): say what would be read, call nothing
# @example ENV=prd PRIVATE_INDEX_TENANTS="csitea" PRIVATE_INDEX_SEAT=c-914 ./run -a do_spl_private_doc_index
# @example ENV=prd PRIVATE_INDEX_TENANTS="csitea" PRIVATE_INDEX_SEAT=c-914 DRY_RUN=0 ./run -a do_spl_private_doc_index
#------------------------------------------------------------------------------
do_spl_private_doc_index() {
  do_require_bin python3 yq || return 1
  : "${ENV:?ENV must be set (dev or prd)}"
  local tenants="${PRIVATE_INDEX_TENANTS:-}" seat="${PRIVATE_INDEX_SEAT:-}" out t allowed
  out="${QTO_PRIVATE_INDEX:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/qto-private-index.txt}"
  [[ -n "$tenants" ]] || { do_log "FATAL PRIVATE_INDEX_TENANTS must name the private workspaces (tenants not in docs.repo_export_tenants)"; return 1; }
  [[ -n "$seat" ]] || { do_log "FATAL PRIVATE_INDEX_SEAT must name a seat in each of those workspaces' desks"; return 1; }
  _spl_pdi_outside_repo "$out" || return 1
  allowed="$(_spl_pdi_allowed)" || return 1
  for t in $tenants; do
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { do_log "FATAL '$t' is not a workspace id"; return 1; }
    if grep -qxF -- "$t" <<<"$allowed"; then
      do_log "FATAL $t is in cnf docs.repo_export_tenants: its docs are public, not private"
      return 1
    fi
  done
  local rc=0
  spl_dry_run || rc=$?
  (( rc == 2 )) && return 1
  if (( rc == 0 )); then
    do_log "INFO DRY_RUN would read every qto doc of: $tenants (ENV=$ENV, seat $seat) and write hashes only to $out (mode 600)"
    do_log "OK DRY_RUN nothing was read or written. Re-run with DRY_RUN=0 to build it."
    return 0
  fi
  _spl_pdi_build "$tenants" "$seat" "$out"
}

# _spl_pdi_allowed: cnf docs.repo_export_tenants, one per line; unreadable
# or empty is a refusal.
_spl_pdi_allowed() {
  local cnf="${QTO_TENANT_CNF:-$PROJ_PATH/../csi-spl-cnf/csi-spl/all.env.yaml}" list
  list="$(yq -r '.env.docs.repo_export_tenants // [] | .[]' "$cnf" 2>/dev/null)" && [[ -n "$list" ]] ||
    { do_log "FATAL cnf docs.repo_export_tenants is not readable or empty in $cnf"; return 1; }
  printf '%s\n' "$list"
}

# _spl_pdi_outside_repo <path>: 0 when the index path is not in this repo,
# checked on its nearest existing parent BEFORE anything is made; then its
# directory is made (mode 700 when new).
_spl_pdi_outside_repo() {
  local repo dir up rest=""
  dir="$(dirname "$1")"
  repo="$(cd "$PROJ_PATH/.." && pwd -P)" || return 1
  up="$dir"
  while [[ ! -d "$up" ]]; do rest="/$(basename "$up")$rest"; up="$(dirname "$up")"; done
  up="$(cd "$up" && pwd -P)$rest"
  if [[ "$up/" == "$repo/"* ]]; then
    do_log "FATAL QTO_PRIVATE_INDEX must live outside the repository ($repo): $1"
    return 1
  fi
  [[ -d "$dir" ]] || { mkdir -p "$dir" && chmod 700 "$dir"; } || { do_log "FATAL cannot make $dir"; return 1; }
}

# _spl_pdi_build <tenants> <seat> <out>: per tenant the doc list, per doc its
# export (its headings), as records in a private temp dir; then the hashes.
_spl_pdi_build() {
  local tenants="$1" seat="$2" out="$3" tmp t doc docs=0 rc=0
  tmp="$(umask 077 && mktemp -d)" || return 1
  for t in $tenants; do
    if ! TENANT_ID="$t" DESK_AGENT="$seat" DOCTREE_ARGS=list do_spl_desk_doctree >"$tmp/list.json" 2>"$tmp/err"; then
      do_log "FATAL the doc list of workspace $t was not read (seat $seat): nothing written"
      rc=1; break
    fi
    python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])).get("docs") or []:
    print(json.dumps({"kind": "id", "value": d.get("id", "")}))
    print(json.dumps({"kind": "text", "value": d.get("title", "")}))
    print(d.get("id", ""), file=sys.stderr)' "$tmp/list.json" >>"$tmp/records.jsonl" 2>"$tmp/ids" || { rc=1; break; }
    while IFS= read -r doc; do
      [[ -n "$doc" ]] || continue
      if ! TENANT_ID="$t" DESK_AGENT="$seat" DOCTREE_ARGS="export $doc" do_spl_desk_doctree >"$tmp/doc.md" 2>"$tmp/err"; then
        do_log "FATAL a doc of workspace $t was not read: nothing written"
        rc=1; break 2
      fi
      python3 -c 'import json,sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("#"):
        print(json.dumps({"kind": "text", "value": line}))' "$tmp/doc.md" >>"$tmp/records.jsonl" || { rc=1; break 2; }
      docs=$((docs + 1))
    done <"$tmp/ids"
  done
  if (( rc == 0 )); then
    python3 "$PROJ_PATH/src/bash/run/qto-private-index.py" build "$tmp/records.jsonl" "$out" "$PROJ_PATH/.." || rc=1
  fi
  rm -rf "$tmp"
  (( rc == 0 )) || return 1
  do_log "OK $docs private doc(s) of $(wc -w <<<"$tenants") workspace(s) hashed into $out"
  do_log "INFO for CI: base64 -w0 $out, then set it as the repo secret QTO_PRIVATE_INDEX_B64 (gh secret set QTO_PRIVATE_INDEX_B64)"
}
