# shellcheck shell=bash
#------------------------------------------------------------------------------
# claude-memory.inc.sh - the claude memory repo and its project slug, the one
# copy (sourced, not executed): steps Y18 (grok) and Y20 (agy) source it from
# this dir. Test: tests/test-y18-grok-memory.sh case 9.
#------------------------------------------------------------------------------

# The claude project slug of an absolute path: /opt/x/y-z -> -opt-x-y-z.
spool_install_memory_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

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
