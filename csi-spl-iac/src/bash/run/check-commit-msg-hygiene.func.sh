#!/bin/bash
#------------------------------------------------------------------------------
# @description Sweep the MESSAGES of the commits a push carries with the SAME
# @description banned-literal patterns as the file sweep (SPL-5613): csi-spl is a
# @description public repository and a push of ANY branch publishes its commit
# @description messages, which do_check_dist_hygiene (tracked files only) never
# @description reads. 2026-11-14: a wip push published a hidden workspace slug
# @description and a private channel name in one commit body, every gate green.
# @description The patterns are the 10 ci "distribution-hygiene" Sweep step,
# @description read out of the workflow (_hyg_sweep_script), never a copy: each
# @description message is written as <sha>.msg and the step runs over them, so
# @description a hit names the commit sha, the line and the pattern label, never
# @description the matched text. The cnf file allowances never apply here.
# @description Each range is listed on its own (git rev-list), so the negative
# @description end of one range never hides the commits of another; a commit
# @description already on the base of its range is not re-read.
# @param HYGIENE_MSG_RANGES (optional) - whitespace-separated rev-list ranges (<a>..<b>), default: none (nothing to sweep, rc 0)
# @param HYGIENE_TREE (optional) - default: $APP_PATH, the checkout holding those commits
# @param HYGIENE_WORKFLOW (optional) - default: <tree>/.github/workflows/10_ci-quality.yml
# @example HYGIENE_MSG_RANGES=origin/master..HEAD ./run -a do_check_commit_msg_hygiene
#------------------------------------------------------------------------------
do_check_commit_msg_hygiene() {
  local tree="${HYGIENE_TREE:-$APP_PATH}" ranges="${HYGIENE_MSG_RANGES:-}"
  local wf="${HYGIENE_WORKFLOW:-$tree/.github/workflows/10_ci-quality.yml}"
  local tmp shas rc=0 n=0 r s d; local -a rs
  [[ -n "${ranges//[[:space:]]/}" ]] || { do_log "INFO commit-message hygiene: no range given, nothing to sweep"; return 0; }
  command -v yq >/dev/null 2>&1 \
    || { do_log "FATAL yq is required: the Sweep step is read out of the workflow, never copied"; return 1; }
  [[ -f "$wf" ]] || { do_log "FATAL no workflow at $wf"; return 1; }
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 || { do_log "FATAL $tree is not a git checkout"; return 1; }
  tmp=$(mktemp -d) || return 1
  if ! _hyg_sweep_script "$wf" "$tmp/sweep.sh"; then
    do_log "FATAL no distribution-hygiene Sweep step with its allow-list in $wf -- this check proved nothing"
    rm -rf "$tmp"; return 1
  fi
  # An unknown range is a REFUSAL: "no commits" from a typo is a vacuous pass.
  read -r -a rs <<<"$ranges"
  for r in "${rs[@]}"; do
    s="$(git -C "$tree" rev-list "$r" -- 2>/dev/null)" \
      || { do_log "FATAL commit-message hygiene: git rev-list '$r' failed in $tree -- nothing was swept"; rm -rf "$tmp"; return 1; }
    shas+="$s"$'\n'
  done
  d="$tmp/msgs"; mkdir -p "$d"
  # The Sweep step reads the private overlay lib and BASE_DOMAIN by path from
  # its cwd: link those two dirs in. grep -r and find do not follow a symlink
  # met while recursing, so neither dir is swept.
  ln -s "$tree/csi-spl-iac" "$d/csi-spl-iac" && ln -s "$tree/csi-spl-cnf" "$d/csi-spl-cnf"
  while IFS= read -r s; do
    [[ -n "$s" && ! -e "$d/$s.msg" ]] || continue
    git -C "$tree" log -1 --format=%B "$s" >"$d/$s.msg" || { do_log "FATAL could not read the message of $s"; rm -rf "$tmp"; return 1; }
    n=$((n + 1))
  done <<<"$shas"
  (( n )) || { do_log "INFO commit-message hygiene: no commit in $ranges"; rm -rf "$tmp"; return 0; }
  (cd "$d" && bash "$tmp/sweep.sh") || rc=$?
  rm -rf "$tmp"
  if [[ "$rc" -ne 0 ]]; then
    do_log "FATAL commit-message hygiene: a banned literal in the message of the <sha>.msg commit(s) named above (rc=$rc) -- reword it (git commit --amend / rebase), do not push"
    return "$rc"
  fi
  do_log "INFO commit-message hygiene: clean over $n commit message(s) in $ranges"
  return 0
}
