#!/usr/bin/env bash
# y1-mcp-bot.sh - install step of spec 069 lane Y1: the browser MCP entrypoints.
#
# y1_mcp_bot FEATURE_DIR
#   Points $MCP_BOT_HOME (default ~/.local/mcp-bot) at FEATURE_DIR/scripts:
#   mcp-start.sh (firefox), mcp-start-chrome.sh (chrome) and reap-profiles.sh
#   become symlinks into this checkout, so every agent's `firefox` and `chrome`
#   MCP server runs the csi-spl copy. A link that points anywhere else (the
#   frozen box engine) is repointed. The base configs are seeded from
#   FEATURE_DIR/assets only when missing: a live config is never rewritten.
#
#   DRY=1 prints the plan and changes nothing. SPOOL_INSTALL_MCP_BOT=0 skips
#   the step (a box whose user runs no browser MCP).
#
# Returns 0 done (or nothing to do), 7 a file in the way is not a symlink
# (left alone; the other entries still ran), 6 a write failed.
y1_mcp_bot() {
  local feat="$1" home="${MCP_BOT_HOME:-$HOME/.local/mcp-bot}" dry="${DRY:-0}" rc=0 n src dst cur
  [ "${SPOOL_INSTALL_MCP_BOT:-1}" = 0 ] && { echo "spool-install: mcp-bot: skipped (SPOOL_INSTALL_MCP_BOT=0)" >&2; return 0; }
  [ -d "$feat/scripts" ] || { echo "spool-install: mcp-bot: FAIL no $feat/scripts" >&2; return 6; }
  [ "$dry" = 1 ] || mkdir -p "$home/run" || return 6
  for n in mcp-start.sh mcp-start-chrome.sh reap-profiles.sh; do
    src="$feat/scripts/$n" dst="$home/$n"
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
      echo "spool-install: mcp-bot: $dst is not a symlink: left alone" >&2; rc=7; continue
    fi
    cur="$(readlink "$dst" 2>/dev/null || true)"
    [ "$cur" = "$src" ] && continue
    if [ "$dry" = 1 ]; then echo "would: link $dst -> $src${cur:+ (was $cur)}"; continue; fi
    ln -sfn "$src" "$dst" || return 6
    echo "spool-install: mcp-bot: $dst -> $src${cur:+ (was $cur)}" >&2
  done
  for n in mcp-config.json mcp-config-chrome.json; do
    dst="$home/$n"
    [ -f "$dst" ] && continue
    if [ "$dry" = 1 ]; then echo "would: seed $dst from $feat/assets/$n"; continue; fi
    sed "s|__MCP_BOT_HOME__|$home|g" "$feat/assets/$n" >"$dst" || return 6
  done
  return "$rc"
}
