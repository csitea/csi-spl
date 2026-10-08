#!/bin/bash
#------------------------------------------------------------------------------
# @description Run the 10 ci "distribution-hygiene" Sweep BEFORE pushing, so a
# @description banned literal is caught in the lane that wrote it instead of on
# @description trunk. The step's own `run:` body is extracted from
# @description .github/workflows/10_ci-quality.yml with yq -- never a copy, so
# @description this action cannot drift from the gate it predicts -- and is
# @description applied to a tracked-file export of the working tree, which is
# @description what actions/checkout hands the job.
# @description Exit code IS the prediction: 0 the sweep passes in CI, non-zero
# @description it fails, and the ::error:: lines above name file:line.
# @description Measured 2026-09-21: 12 consecutive trunk runs (12:54Z..13:08Z)
# @description were red on ONE banned line in one spec.md -- every push in the
# @description window inherited it. This action is the cheapest way to not be
# @description the lane that lands the next one.
# @description It also refuses a TRACKED .vibe/ dir anywhere in the tree (spec
# @description 110 2.3, seat-4 change 3): every worktree is a trusted Vibe
# @description folder, whose .vibe/{config.toml,hooks.toml,AGENTS.md} is read
# @description first, so one commit could change the model, add an MCP server
# @description or run a pre_tool hook on every m- seat.
# @param HYGIENE_TREE (optional) - default: $APP_PATH, the checkout to sweep
# @param HYGIENE_WORKFLOW (optional) - default: <tree>/.github/workflows/10_ci-quality.yml
# @example ./run -a do_check_dist_hygiene
# @example HYGIENE_TREE=/path/to/other/checkout ./run -a do_check_dist_hygiene
#------------------------------------------------------------------------------
do_check_dist_hygiene() {
  local tree="${HYGIENE_TREE:-$APP_PATH}"
  local wf="${HYGIENE_WORKFLOW:-$tree/.github/workflows/10_ci-quality.yml}"
  local tmp rc=0

  command -v yq >/dev/null 2>&1 \
    || { do_log "FATAL yq is required: the Sweep step is read out of the workflow, never copied"; return 1; }
  [[ -f "$wf" ]] || { do_log "FATAL no workflow at $wf"; return 1; }
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 \
    || { do_log "FATAL $tree is not a git checkout -- the sweep runs over its tracked files"; return 1; }

  tmp=$(mktemp -d) || return 1

  yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$wf" >"$tmp/sweep.sh" 2>/dev/null
  # A workflow this action cannot read is a REFUSAL, never a pass: a silent
  # "ok" from an empty script is the one answer that would be worse than red.
  if [[ ! -s "$tmp/sweep.sh" ]] || ! grep -q 'allow_line=' "$tmp/sweep.sh"; then
    do_log "FATAL no distribution-hygiene Sweep step with its allow-list in $wf -- this check proved nothing"
    rm -rf "$tmp"
    return 1
  fi

  mkdir -p "$tmp/tree"
  # Tracked files only, contents as they are on disk: an uncommitted edit is
  # swept (that is the point), a git-ignored dir is not (CI never sees it).
  if ! git -C "$tree" ls-files -z | (cd "$tree" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$tmp/tree"; then
    do_log "FATAL could not export the tracked tree of $tree"
    rm -rf "$tmp"
    return 1
  fi

  (cd "$tmp/tree" && bash "$tmp/sweep.sh") || rc=$?
  rm -rf "$tmp"
  _check_dist_hygiene_vibe "$tree" || rc=1

  if [[ "$rc" -ne 0 ]]; then
    do_log "FATAL the distribution-hygiene gate would FAIL on this tree (rc=$rc) -- fix the file:line named above, do not push"
    return "$rc"
  fi
  do_log "INFO distribution-hygiene: clean over the tracked tree of $tree"
  return 0
}

# _check_dist_hygiene_vibe <tree>: 1 and one ::error:: line per tracked file
# under a .vibe/ dir (spec 110 2.3), 0 when there is none.
_check_dist_hygiene_vibe() {
  local f n=0
  while IFS= read -r -d '' f; do
    echo "::error file=$f::a tracked .vibe/ file: Vibe reads it first in every trusted worktree (model, MCP servers, pre_tool hooks) - git rm --cached it (spec 110 2.3)"
    n=$((n + 1))
  done < <(git -C "$1" ls-files -z | grep -zE '(^|/)\.vibe/')
  (( n == 0 )) || { do_log "FAIL $n tracked .vibe/ file(s): refused"; return 1; }
}
