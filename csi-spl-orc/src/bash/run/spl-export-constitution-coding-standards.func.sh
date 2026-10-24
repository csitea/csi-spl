#!/bin/bash

# The qto node of the developer guide's "Coding Standards" section (qto doc
# c65bbfbd, depth 1, relayed by build row 01, SPL-3249): the ONE place its
# id lives (coding-standards-panel-plan.md section 3.2).
EXPORT_CS_NODE_ID="5396f07f-c552-4cc4-a2e1-f4d29d060d43"
_ECS_BEGIN='<!-- BEGIN CODING STANDARDS'
_ECS_END='<!-- END CODING STANDARDS -->'

#------------------------------------------------------------------------------
# @description Export the developer guide's Coding Standards section into
#   the spec-kit constitution (spec 135, coding-standards-panel-plan.md
#   sections 3.1-3.5, build row 02). The guide (qto doc c65bbfbd's export)
#   is the source; the constitution carries a verbatim copy between
#     <!-- BEGIN CODING STANDARDS (exported from developer-guide.md; DO NOT EDIT DIRECTLY) -->
#     <!-- END CODING STANDARDS -->
#   The slice is cut by the section's stable qto node anchor, never by its
#   heading text: from the line <a id="ws-doc-<node id>"></a> (followed by
#   a "## " heading) to the next anchor whose heading is "## " or "# ", or
#   the end of the file. Trailing blank lines are dropped.
#   When the slice differs from the block, the block is replaced and the
#   version is bumped one patch step past the higher of the body
#   (**Version**: X.Y.Z) and footer (<!-- version: X.Y.Z ...) versions, with
#   today's Last Amended / updated date and last-edit time. An equal block
#   changes nothing, so a check run never diffs on its own stamp.
#   Refuses, writing nothing: a missing or repeated node anchor, an anchor
#   with no "## " heading under it, a BEGIN or END marker missing or
#   repeated, END before BEGIN, a body or footer version line missing or
#   repeated.
# @param DRY_RUN (optional) - 1: compare only, exit 1 with the diff when the
#   block differs (drift fact 8 runs it so); default 0 writes
# @param EXPORT_CS_TREE (optional) - default: $APP_PATH, the checkout
# @param EXPORT_CS_GUIDE (optional) - default
#   <tree>/csi-spl-doc/doc/md/developer-guide.md
# @param EXPORT_CS_CONSTITUTION (optional) - default
#   <tree>/csi-spl-doc/.specify/memory/constitution.md
# @param EXPORT_CS_NODE (optional) - the node id, default EXPORT_CS_NODE_ID
# @param EXPORT_CS_NOW (optional) - the stamp time, ISO-8601 UTC
#   (YYYY-MM-DDTHH:MM:SSZ), default now
# @example ./run -a do_spl_export_constitution_coding_standards
# @example DRY_RUN=1 ./run -a do_spl_export_constitution_coding_standards
# @prereq the constitution carries the BEGIN and END markers (build row 06)
#------------------------------------------------------------------------------
do_spl_export_constitution_coding_standards() {
  local tree="${EXPORT_CS_TREE:-${APP_PATH:-}}" node="${EXPORT_CS_NODE:-$EXPORT_CS_NODE_ID}"
  local guide con now tmp rc=0
  guide="${EXPORT_CS_GUIDE:-$tree/csi-spl-doc/doc/md/developer-guide.md}"
  con="${EXPORT_CS_CONSTITUTION:-$tree/csi-spl-doc/.specify/memory/constitution.md}"
  now="${EXPORT_CS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  [[ "$node" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    do_log "FATAL the Coding Standards node id is not set or not a uuid ('$node'): set EXPORT_CS_NODE_ID (build row 01)"; return 1; }
  [[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    do_log "FATAL EXPORT_CS_NOW '$now' is not YYYY-MM-DDTHH:MM:SSZ"; return 1; }
  [[ -f "$guide" ]] || { do_log "FATAL no developer guide at $guide"; return 1; }
  [[ -f "$con" ]] || { do_log "FATAL no constitution at $con"; return 1; }
  tmp="$(mktemp -d)" || return 1
  _ecs_run "$guide" "$con" "$node" "$now" "$tmp" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# _ecs_run <guide> <constitution> <node> <now> <tmp dir>: the export, once
# every input has passed its checks.
_ecs_run() {
  local guide="$1" con="$2" node="$3" now="$4" tmp="$5"
  _ecs_slice "$guide" "$node" >"$tmp/slice" || return 1
  _ecs_block "$con" >"$tmp/block" || return 1
  _ecs_versions "$con" >"$tmp/ver" || return 1
  if cmp -s "$tmp/slice" "$tmp/block"; then
    do_log "OK the constitution's Coding Standards block equals the guide's section (node ${node:0:8}); nothing written"
    return 0
  fi
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    diff -u --label "constitution.md (Coding Standards block)" --label "developer-guide.md (node ${node:0:8})" \
      "$tmp/block" "$tmp/slice"
    do_log "FAIL the constitution's Coding Standards block differs from the guide's section: run do_spl_export_constitution_coding_standards"
    return 1
  fi
  _ecs_write "$con" "$tmp" "$now" || return 1
  do_log "OK exported the Coding Standards section (node ${node:0:8}) into $con, version $(cat "$tmp/new_ver")"
}

# _ecs_slice <guide> <node>: print the section that starts at the node's
# anchor, up to the next level-1/2 anchor or the end of the file. Like
# every helper that prints data, it logs its refusals to stderr.
_ecs_slice() {
  local guide="$1" node="$2" out rc=0
  out="$(awk -v anchor="<a id=\"ws-doc-$node\"></a>" '
    function is_anchor(s) { return s ~ /^<a id="ws-doc-[0-9a-f-]+"><\/a>$/ }
    { line[NR] = $0 } $0 == anchor { hits++; start = NR }
    END {
      if (hits != 1) { print "anchor " hits + 0; exit 2 }
      if (line[start + 1] !~ /^## /) { print "heading"; exit 3 }
      stop = NR + 1
      for (i = start + 1; i <= NR; i++)
        if (is_anchor(line[i]) && line[i + 1] ~ /^##? /) { stop = i; break }
      while (stop - 1 > start && line[stop - 1] ~ /^[ \t]*$/) stop--
      for (i = start; i < stop; i++) print line[i]
    }' "$guide")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" ;;
    2) do_log "FATAL ${guide##*/}: the node anchor ws-doc-$node appears ${out#anchor } times, want 1" >&2; return 1 ;;
    3) do_log "FATAL ${guide##*/}: the node anchor ws-doc-$node is not followed by a '## ' heading" >&2; return 1 ;;
    *) do_log "FATAL ${guide##*/}: cannot read it (awk rc $rc)" >&2; return 1 ;;
  esac
}

# _ecs_markers <constitution>: print "<begin line> <end line>", or refuse.
_ecs_markers() {
  local con="$1" b e
  b="$(grep -n -- "^$_ECS_BEGIN" "$con" | cut -d: -f1 | tr '\n' ' ')"
  e="$(grep -nxF -- "$_ECS_END" "$con" | cut -d: -f1 | tr '\n' ' ')"
  [[ "$b" =~ ^[0-9]+\ $ ]] || { do_log "FATAL ${con##*/}: want one BEGIN CODING STANDARDS marker, found lines: ${b:-none}" >&2; return 1; }
  [[ "$e" =~ ^[0-9]+\ $ ]] || { do_log "FATAL ${con##*/}: want one END CODING STANDARDS marker, found lines: ${e:-none}" >&2; return 1; }
  (( ${e% } > ${b% } )) || { do_log "FATAL ${con##*/}: the END marker (line ${e% }) is before the BEGIN marker (line ${b% })" >&2; return 1; }
  echo "${b% } ${e% }"
}

# _ecs_block <constitution>: print the lines between the markers, without
# the blank lines that pad them.
_ecs_block() {
  local con="$1" m
  m="$(_ecs_markers "$con")" || return 1
  awk -v b="${m% *}" -v e="${m#* }" '
    NR > b && NR < e { line[++n] = $0 }
    END {
      s = 1; while (s <= n && line[s] ~ /^[ \t]*$/) s++
      while (n >= s && line[n] ~ /^[ \t]*$/) n--
      for (i = s; i <= n; i++) print line[i]
    }' "$con"
}

# _ecs_versions <constitution>: print the body and footer versions (read
# outside the block), or refuse when either line is missing or repeated.
_ecs_versions() {
  local con="$1" m body foot
  m="$(_ecs_markers "$con")" || return 1
  body="$(awk -v b="${m% *}" -v e="${m#* }" 'NR < b || NR > e' "$con" | sed -nE 's/^\*\*Version\*\*: ([0-9]+\.[0-9]+\.[0-9]+) .*/\1/p')"
  foot="$(awk -v b="${m% *}" -v e="${m#* }" 'NR < b || NR > e' "$con" | sed -nE 's/^<!-- version: ([0-9]+\.[0-9]+\.[0-9]+) .*/\1/p')"
  [[ "$body" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { do_log "FATAL ${con##*/}: want one '**Version**: X.Y.Z' line, found: ${body:-none}" >&2; return 1; }
  [[ "$foot" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { do_log "FATAL ${con##*/}: want one '<!-- version: X.Y.Z' footer line, found: ${foot:-none}" >&2; return 1; }
  echo "$body $foot"
}

# _ecs_write <constitution> <tmp dir> <now>: replace the block with the
# slice, bump the version and dates; the file is composed whole in <tmp>
# first, then written over the original in place (its mode is kept).
_ecs_write() {
  local con="$1" tmp="$2" now="$3" m hi new
  m="$(_ecs_markers "$con")" || return 1
  hi="$(tr ' ' '\n' <"$tmp/ver" | sort -V | tail -1)"
  new="${hi%.*}.$(( ${hi##*.} + 1 ))"
  echo "$new" >"$tmp/new_ver"
  awk -v b="${m% *}" -v e="${m#* }" -v slice="$tmp/slice" -v ver="$new" \
      -v day="${now%%T*}" -v ts="$now" '
    NR == b { print; print ""; while ((getline l < slice) > 0) print l; print ""; next }
    NR > b && NR < e { next }
    /^\*\*Version\*\*: [0-9]+\.[0-9]+\.[0-9]+ / {
      sub(/^\*\*Version\*\*: [0-9]+\.[0-9]+\.[0-9]+/, "**Version**: " ver)
      sub(/\*\*Last Amended\*\*: .*/, "**Last Amended**: " day " (Coding Standards exported from developer-guide.md)")
    }
    /^<!-- version: [0-9]+\.[0-9]+\.[0-9]+ / {
      $0 = "<!-- version: " ver " · updated: " day " · last-edit: " ts " -->"
    }
    { print }' "$con" >"$tmp/out" || { do_log "FATAL cannot compose the new ${con##*/}"; return 1; }
  cat "$tmp/out" >"$con" || { do_log "FATAL cannot write $con"; return 1; }
}
