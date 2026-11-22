# shellcheck shell=bash
#------------------------------------------------------------------------------
# claude-memory.inc.sh - the claude memory repo, the one copy, and the load of
# the project slug helper (sourced, not executed): steps Y18 (grok) and Y20 (agy)
# source it from this dir. Tests: test-y18-grok-memory.sh 9, orc slug test 4.
#------------------------------------------------------------------------------

# The claude project slug of an absolute path (/opt/x/y-z -> -opt-x-y-z):
# spl_claude_project_slug, the orc's one copy (r88-01).
declare -F spl_claude_project_slug >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/../../../../../lib/bash/funcs/spl-claude-project-slug.func.sh"

spool_install_memory_repo() {
  local here common
  if [ -n "${SPOOL_INSTALL_CLAUDE_MEMORY_REPO:-}" ]; then
    printf '%s\n' "$SPOOL_INSTALL_CLAUDE_MEMORY_REPO"
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dirname "$common"
}
