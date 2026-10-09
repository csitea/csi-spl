#!/usr/bin/env bash
# y9-vendor-lane-rule.sh — install.sh step: the fleet lane rule (part
# 25-stay-in-your-lane, owner 2026-10-09) into the rules file each OTHER vendor
# loads, rendered by y8's renderer from the same part (one home, no copy).
#
#   claude  ~/.claude/CLAUDE.md                  step y4 (every part)
#   grok    ~/.claude/CLAUDE.md                  grok's compat.claude scan (default on)
#   mistral ~/.vibe/AGENTS.md                    step y8 (every part)
#   agy     ~/.gemini/config/rules/<part>.md     this step (agy loads every rules/*.md, as y6's graft.md)
#   qwen    ~/.qwen/QWEN.md                      this step (qwen's global context; its save_memory
#                                                appends there, so it is qwen's memory file too)
#
# Each file gets one block "spool-install: begin lane-rule ... end lane-rule
# sha256=<hex>"; everything outside it is kept, the old file is backed up, a
# hand-edited block is left alone (--force-skills replaces it): y8's rules.
# A vendor whose home dir (~/.gemini, ~/.qwen) is absent is skipped.
# Env: SPOOL_INSTALL_VENDOR_RULES=0 skips the step (install.sh sets it without
#      --fleet); SPOOL_INSTALL_CLAUDE_ASSETS overrides the assets dir (tests).
# Reads install.sh's DRY and FORCE_SKILLS when set.

spool_install_vendor_lane_rule() {
  [ "${SPOOL_INSTALL_VENDOR_RULES:-1}" = 0 ] && return 0
  local here assets part=25-stay-in-your-lane rc=0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  assets="${SPOOL_INSTALL_CLAUDE_ASSETS:-$here/../assets/claude}"
  _y9_one() {  # TARGET
    Y8_ONLY="$part" Y8_TAG=lane-rule python3 "$here/y8-vibe-agents.py" "$assets/claude-md" "$1" "${DRY:-0}" "${FORCE_SKILLS:-0}" || rc=1
  }
  [ -d "$HOME/.gemini" ] && _y9_one "$HOME/.gemini/config/rules/$part.md"
  [ -d "$HOME/.qwen" ] && _y9_one "$HOME/.qwen/QWEN.md"
  return "$rc"
}
