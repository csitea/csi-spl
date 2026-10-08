#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: the done-% of every spec dir, by ONE rule (spec 112
# @description 5.1). For each csi-spl-doc/specs/[0-9][0-9][0-9]-*/ it counts in
# @description tasks.md the lines ^\s*- \[[xX]\] (x), ^\s*- \[~\] (p) and
# @description ^\s*- \[ \] (o). [~] is OPEN, never done. States: no-tasks (no
# @description tasks.md), no-boxes (x+p+o = 0), planned (x = p = 0, o > 0),
# @description done (x > 0, p+o = 0), in-progress (everything else).
# @description pct = floor(100 x / (x+p+o)), empty when x+p+o = 0.
# @description Prints TSV "spec state x p o pct", one row per spec dir, then
# @description one "# total" line naming the sha. --sha reads git archive of
# @description that ref, never the worktree. --json prints the roadmap.json
# @description shape instead (WUI-1 adds the goals). Writes nothing.
# @param SPEC_PROGRESS_ROOT (optional) - the repo root; default APP_PATH
# @example ./run -a do_spl_spec_progress
# @example ./run -a do_spl_spec_progress --sha fecc09693 --exclude 112
# @example ./run -a do_spl_spec_progress --json
#------------------------------------------------------------------------------
do_spl_spec_progress() {
  local root="${SPEC_PROGRESS_ROOT:-${APP_PATH:-}}" ref="" json=0 exclude="" tmp="" specs sha rc
  while (( $# )); do
    case "$1" in
      --sha) ref="${2:-}"; [[ -n "$ref" ]] || { do_log "FATAL --sha needs a ref"; return 2; }; shift ;;
      --json) json=1 ;;
      --exclude) exclude="${2:-}"; shift ;;
      *) do_log "FATAL unknown argument: $1 (use --sha <ref>, --json, --exclude <NNN,...>)"; return 2 ;;
    esac
    shift
  done
  [[ -n "$root" && -d "$root" ]] || { do_log "FATAL no repo root (SPEC_PROGRESS_ROOT or APP_PATH)"; return 2; }
  if (( json )); then do_require_bin jq || return 1; fi
  if [[ -n "$ref" ]]; then
    sha="$(git -C "$root" rev-parse --verify --quiet "$ref^{commit}")" \
      || { do_log "FATAL --sha $ref is not a commit in $root"; return 2; }
    tmp="$(mktemp -d)"
    git -C "$root" archive "$sha" csi-spl-doc/specs | tar -x -C "$tmp" \
      || { rm -rf "$tmp"; do_log "FATAL git archive of $sha failed"; return 1; }
    specs="$tmp/csi-spl-doc/specs"
  else
    sha="$(git -C "$root" rev-parse --verify --quiet HEAD 2>/dev/null)+worktree" || sha="worktree"
    specs="$root/csi-spl-doc/specs"
  fi
  if (( json )); then
    _spl_spec_progress_rows "$specs" "$exclude" | _spl_spec_progress_json "$root" "$sha" "${ref:-HEAD}"
  else
    _spl_spec_progress_rows "$specs" "$exclude" | _spl_spec_progress_tsv "$sha"
  fi
  rc=$?
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  return "$rc"
}

# _spl_spec_progress_count <file> <ERE> -> the number of matching lines (0 if none).
_spl_spec_progress_count() {
  local n
  n="$(grep -cE "$2" "$1" 2>/dev/null)" || true
  echo "${n:-0}"
}

# _spl_spec_progress_rows <specs-dir> <exclude-csv> -> TSV
# "spec state x p o pct title", one row per spec dir, sorted by dir name. An
# empty pct travels as "-": a tab-IFS read would collapse an empty field.
_spl_spec_progress_rows() {
  local specs="$1" exclude=",${2:-}," d id x p o state pct title
  [[ -d "$specs" ]] || { do_log "FATAL no specs dir: $specs"; return 1; }
  for d in "$specs"/[0-9][0-9][0-9]-*/; do
    [[ -d "$d" ]] || continue
    id="$(basename "$d")"
    [[ "$exclude" == *",${id:0:3},"* ]] && continue
    x=0 p=0 o=0 pct=-
    if [[ ! -f "$d/tasks.md" ]]; then
      state=no-tasks
    else
      x="$(_spl_spec_progress_count "$d/tasks.md" '^[[:space:]]*- \[[xX]\]')"
      p="$(_spl_spec_progress_count "$d/tasks.md" '^[[:space:]]*- \[~\]')"
      o="$(_spl_spec_progress_count "$d/tasks.md" '^[[:space:]]*- \[ \]')"
      if (( x + p + o == 0 )); then
        state=no-boxes
      else
        pct=$(( 100 * x / (x + p + o) ))
        if (( x == 0 && p == 0 )); then state=planned
        elif (( p + o == 0 )); then state="done"
        else state=in-progress
        fi
      fi
    fi
    title="$(sed -n 's/^#[[:space:]]\{1,\}//p;T;q' "$d/spec.md" 2>/dev/null)"
    title="${title//$'\t'/ }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$state" "$x" "$p" "$o" "$pct" "$title"
  done
}

# _spl_spec_progress_tsv <sha> -> the header, the rows without the title, the total.
_spl_spec_progress_tsv() {
  awk -F'\t' -v sha="$1" '
    BEGIN { OFS = "\t"; print "spec", "state", "x", "p", "o", "pct" }
    { print $1, $2, $3, $4, $5, ($6 == "-" ? "" : $6); n++; c[$2]++; t += ($2 != "no-tasks") }
    END {
      printf "# total sha=%s specs=%d tasks.md=%d done=%d in-progress=%d no-boxes=%d planned=%d no-tasks=%d\n",
        sha, n, t, c["done"], c["in-progress"], c["no-boxes"], c["planned"], c["no-tasks"]
    }'
}

# _spl_spec_progress_json <root> <sha> <ref> -> the roadmap.json shape:
# {sha, rule, totals, specs: [{id, title, state, x, p, o, pct, tasks_changed}]}.
# tasks_changed is the last commit date of tasks.md at <ref> (empty without git).
_spl_spec_progress_json() {
  local root="$1" sha="$2" ref="$3" id state x p o pct title changed
  while IFS=$'\t' read -r id state x p o pct title; do
    changed="$(git -C "$root" log -1 --format=%cI "$ref" -- "csi-spl-doc/specs/$id/tasks.md" 2>/dev/null)" || changed=""
    jq -cn --arg id "$id" --arg title "$title" --arg state "$state" --argjson x "$x" \
      --argjson p "$p" --argjson o "$o" --arg pct "$pct" --arg changed "$changed" \
      '{id: $id, title: $title, state: $state, x: $x, p: $p, o: $o,
        pct: (if $pct == "-" then null else ($pct | tonumber) end), tasks_changed: $changed}'
  done | jq -s --arg sha "$sha" '{
    sha: $sha,
    rule: "spec 112 5.1: [~] is open; pct = floor(100 x / (x+p+o))",
    totals: (reduce .[] as $r ({specs: 0, done: 0, "in-progress": 0, "no-boxes": 0, planned: 0, "no-tasks": 0};
      .specs += 1 | .[$r.state] += 1)),
    specs: .}'
}
