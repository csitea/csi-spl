#!/usr/bin/env bash
# y8-vibe-agents.sh — install.sh step (spec 110): the fleet's standing orders
# into ~/.vibe/AGENTS.md, rendered from the SAME parts as the global
# ~/.claude/CLAUDE.md (spool-install/assets/claude/claude-md/NN-<slug>.md).
#
# Why: vibe (mistral) loads a trusted dir's AGENTS.md, never CLAUDE.md
# (measured spec 110 T005, vibe 2.26.0), so a Mistral lane otherwise starts
# without the fleet rules the claude seats get from step y4.
#
#   One block between
#     <!-- spool-install: begin agents-md ... -->
#     <!-- spool-install: end agents-md sha256=<hex> -->
#   Everything outside the block is never touched. A re-run rewrites the
#   block only while its sha256 still matches (untouched); a hand-edited
#   block is left alone and named (--force-skills replaces it). Every write
#   over an existing file first keeps the whole old file as
#   AGENTS.md.bak-spool-install-<UTC stamp> (a new file each time, an older
#   backup is never overwritten).
#
# Placeholders: the same {{KEY}} values as y4-claude-config.sh.
# Env: SPOOL_INSTALL_VIBE_AGENTS=0 skips the step (install.sh sets it without
#      --fleet); SPOOL_INSTALL_CLAUDE_ASSETS overrides the assets dir (tests).
# Reads install.sh's DRY, FORCE_SKILLS and ROOT when set.

spool_install_vibe_agents() {
  [ "${SPOOL_INSTALL_VIBE_AGENTS:-1}" = 0 ] && return 0
  local here assets root agent_user box_user box_tag
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  assets="${SPOOL_INSTALL_CLAUDE_ASSETS:-$here/../assets/claude}"
  root="${ROOT:-$(cd "$here/../../../../.." && pwd)}"
  agent_user="${SPOOL_AGENT_USER:-$(id -un)}"
  box_user="${SPOOL_BOX_USER:-$(stat -c %U "$root" 2>/dev/null || id -un)}"
  box_tag="${SPOOL_BOX_TAG:-}"
  if [ -z "$box_tag" ] && declare -F cfg_get >/dev/null; then box_tag="$(cfg_get SPOOL_BOX_TAG)"; fi
  python3 "$here/y8-vibe-agents.py" "$assets/claude-md" "$HOME/.vibe/AGENTS.md" "${DRY:-0}" "${FORCE_SKILLS:-0}" \
    "AGENT_USER=$agent_user" \
    "AGENT_HOME=$(getent passwd "$agent_user" | cut -d: -f6)" \
    "BOX_USER=$box_user" \
    "BOX_HOME=$(getent passwd "$box_user" | cut -d: -f6)" \
    "TMUX_SOCKET=${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$box_user" 2>/dev/null)/default}" \
    "BOX_TAG=${box_tag:-<tag>}" \
    "AGENT_CEILING=${SPOOL_AGENT_CEILING:-40}"
}
