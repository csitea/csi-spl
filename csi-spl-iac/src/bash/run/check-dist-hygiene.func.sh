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
# @description That step also refuses a TRACKED .vibe/ dir anywhere in the tree
# @description (spec 110 2.3): the rule lives in the workflow only, so the CI
# @description gate and this action cannot hold two lists.
# @param HYGIENE_TREE (optional) - default: $APP_PATH, the checkout to sweep
# @param HYGIENE_WORKFLOW (optional) - default: <tree>/.github/workflows/10_ci-quality.yml
# @param HYGIENE_MSG_RANGES (optional) - default: none; rev-list ranges whose commit MESSAGES are swept too (do_check_commit_msg_hygiene, SPL-5613)
# @example ./run -a do_check_dist_hygiene
# @example HYGIENE_TREE=/path/to/other/checkout ./run -a do_check_dist_hygiene
#------------------------------------------------------------------------------
# <workflow> <out>: the Sweep step's run: body, read out of the workflow (never
# a copy), so the file sweep and the commit-message sweep hold ONE pattern list.
# A workflow this action cannot read is a REFUSAL, never a pass: a silent "ok"
# from an empty script is the one answer that would be worse than red.
_hyg_sweep_script() {
  yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$1" >"$2" 2>/dev/null
  [[ -s "$2" ]] && grep -q 'allow_line=' "$2"
}

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

  if ! _hyg_sweep_script "$wf" "$tmp/sweep.sh"; then
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
  # The messages of the outgoing commits (SPL-5613): the pre-push hygiene part
  # passes its range here, so one call (and one test stub) covers both sweeps.
  if [[ -n "${HYGIENE_MSG_RANGES:-}" ]]; then
    HYGIENE_TREE="$tree" HYGIENE_WORKFLOW="$wf" do_check_commit_msg_hygiene || rc=1
  fi

  if [[ "$rc" -ne 0 ]]; then
    do_log "FATAL the distribution-hygiene gate would FAIL on this tree (rc=$rc) -- fix the file:line (or reword the <sha>.msg commit) named above, do not push"
    return "$rc"
  fi
  do_log "INFO distribution-hygiene: clean over the tracked tree of $tree"
  return 0
}
