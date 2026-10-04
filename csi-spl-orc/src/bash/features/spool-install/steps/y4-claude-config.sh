#!/usr/bin/env bash
# y4-claude-config.sh — install.sh step (spec 069 lane Y4): the fleet's
# standing orders into ~/.claude/CLAUDE.md and its fleet settings into
# ~/.claude/settings.json, rendered from spool-install/assets/claude.
#
#   CLAUDE.md: the fragments of assets/claude/claude-md/NN-<slug>.md, joined
#     in NN order, go into ONE block between
#       <!-- spool-install: begin claude-md ... -->
#       <!-- spool-install: end claude-md sha256=<hex> -->
#     Everything outside the block (the owner's personal fragments: Slack,
#     HTML docs, doc-hub - spec 069 Q4) is never touched, except that a
#     fragment an older renderer wrote under the SAME NN
#     (`<!-- fragment <layer>/NN-<slug> -->` ... `<!-- /fragment -->`) is
#     taken over: removed and named, so no rule is there twice. A re-run
#     rewrites the block only while its sha256 still matches (untouched); a
#     hand-edited block is left alone and named (--force-skills replaces it,
#     the old file kept as CLAUDE.md.bak-spool-install).
#   settings.json: assets/claude/settings/NN-<slug>.json deep-merged in NN
#     order over the current file (other keys kept, ours win), and the marker
#     env.SPOOL_INSTALL_SETTINGS=sha256=<hex of the merged fragments>.
#     The mirror hooks are step 5 of install.sh, not this step.
#     00-fleet.json sets skillOverrides.auto-mode-setup to "off" so a seat
#     is not offered "Teach auto mode about your environment?" (Claude Code
#     docs, auto-mode-config, "Turn off /auto-mode-setup", read 2026-10-04,
#     https://code.claude.com/docs/en/auto-mode-config). That page documents
#     no environment variable for the offer. disableBundledSkills does not
#     turn the command off.
#
# Placeholders ({{KEY}}) and where their values come from - never a literal:
#   AGENT_USER    SPOOL_AGENT_USER, else the user running install.sh
#   AGENT_HOME    that user's home (passwd)
#   BOX_USER      SPOOL_BOX_USER, else the owner of this checkout
#   BOX_HOME      that user's home (passwd)
#   TMUX_SOCKET   SPOOL_TMUX_SOCKET, else /tmp/tmux-<uid of BOX_USER>/default
#   BOX_TAG       SPOOL_BOX_TAG (env, else the spool-agent config), else <tag>
#   AGENT_CEILING SPOOL_AGENT_CEILING, else 40
#
# Env: SPOOL_INSTALL_CLAUDE_CONFIG=0 skips the step;
#      SPOOL_INSTALL_CLAUDE_ASSETS overrides the assets dir (tests).
# Reads install.sh's DRY, FORCE_SKILLS and ROOT when set.

spool_install_claude_config() {
  [ "${SPOOL_INSTALL_CLAUDE_CONFIG:-1}" = 0 ] && return 0
  local here assets root agent_user box_user box_tag
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  assets="${SPOOL_INSTALL_CLAUDE_ASSETS:-$here/../assets/claude}"
  root="${ROOT:-$(cd "$here/../../../../.." && pwd)}"
  agent_user="${SPOOL_AGENT_USER:-$(id -un)}"
  box_user="${SPOOL_BOX_USER:-$(stat -c %U "$root" 2>/dev/null || id -un)}"
  box_tag="${SPOOL_BOX_TAG:-}"
  if [ -z "$box_tag" ] && declare -F cfg_get >/dev/null; then box_tag="$(cfg_get SPOOL_BOX_TAG)"; fi
  python3 "$here/y4-claude-config.py" "$assets" "$HOME" "${DRY:-0}" "${FORCE_SKILLS:-0}" \
    "AGENT_USER=$agent_user" \
    "AGENT_HOME=$(getent passwd "$agent_user" | cut -d: -f6)" \
    "BOX_USER=$box_user" \
    "BOX_HOME=$(getent passwd "$box_user" | cut -d: -f6)" \
    "TMUX_SOCKET=${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$box_user" 2>/dev/null)/default}" \
    "BOX_TAG=${box_tag:-<tag>}" \
    "AGENT_CEILING=${SPOOL_AGENT_CEILING:-40}"
}
