#!/bin/bash
#------------------------------------------------------------------------------
# @description Refresh ONLY the box user's installed spool binary (the copy
# @description spool-install puts in <prefix>/share/spool-agent/tools/bin, on
# @description PATH as <prefix>/bin/spool) to trunk, through
# @description `install.sh --binary-only`. The full installer also rewrites
# @description the five config paths below (the agent env reset to dev with
# @description an empty tenant, measured by a dry run 2026-10-04), so this
# @description never runs it: it snapshots those five before and after and
# @description FAILS when any of them changed:
# @description   ~/.config/spool-agent/env, ~/.bashrc, ~/.claude/CLAUDE.md,
# @description   ~/.claude/settings.json, the mcp-bot links (MCP_BOT_HOME)
# @description The checkout must be AT trunk (HEAD == origin/master, run
# @description do_spl_box_update to fetch first); the new binary must run
# @description `spool version` and carry that sha (go version -m), else the
# @description installer puts the old one (kept as spool.bak) back.
# @description Prints the binary's commit and version before and after.
# @description Dry run unless DRY_RUN=0 (the installer prints its plan).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_INSTALL_PREFIX (optional) - default $HOME/.local
# @param SPOOL_REFRESH_TRUNK (optional) - the trunk ref, default origin/master
# @param SPOOL_REFRESH_INSTALLER (optional, tests) - default the checkout's install.sh
# @example ./run -a do_spl_spool_refresh
# @example DRY_RUN=0 ./run -a do_spl_spool_refresh
#------------------------------------------------------------------------------
do_spl_spool_refresh() {
  local dry="${DRY_RUN:-1}" trunk head want before after rc
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  local inst="${SPOOL_REFRESH_INSTALLER:-$PROJ_PATH/src/bash/features/spool-install/install.sh}"
  local bin="${SPOOL_INSTALL_PREFIX:-$HOME/.local}/share/spool-agent/tools/bin/spool"
  [[ -f "$inst" ]] || { do_log "FATAL the installer is missing: $inst"; return 1; }

  head="$(git -C "$APP_PATH" rev-parse -q --verify HEAD 2>/dev/null)"
  trunk="$(git -C "$APP_PATH" rev-parse -q --verify "${SPOOL_REFRESH_TRUNK:-origin/master}^{commit}" 2>/dev/null)"
  [[ -n "$trunk" ]] || { do_log "FATAL cannot resolve ${SPOOL_REFRESH_TRUNK:-origin/master} in $APP_PATH"; return 1; }
  if [[ "$head" != "$trunk" ]]; then
    [[ "$dry" == 1 ]] || { do_log "FATAL $APP_PATH is at ${head:-nothing}, trunk is $trunk: fetch first (do_spl_box_update) - nothing changed"; return 1; }
    echo "WARN $APP_PATH is at ${head:-nothing}, trunk is $trunk: a DRY_RUN=0 run refuses"
  fi
  want="$trunk"

  echo "REFRESH spool binary $bin -> $want (user $USER, DRY_RUN=$dry)"
  echo "BEFORE binary: $(spool_refresh_bin_say "$bin")"
  before="$(spool_refresh_config_fingerprint)"
  printf '%s\n' "$before" | sed 's/^/BEFORE config: /'

  local -a args=(--binary-only)
  [[ "$dry" == 1 ]] && args+=(--dry-run)
  SPOOL_INSTALL_EXPECT_REV="$want" bash "$inst" "${args[@]}" 2>&1 | sed 's/^/  /'
  rc="${PIPESTATUS[0]}"

  after="$(spool_refresh_config_fingerprint)"
  echo "AFTER binary: $(spool_refresh_bin_say "$bin")"
  if [[ "$before" != "$after" ]]; then
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> /CHANGED config: /p'
    do_log "FAIL a config path changed during a binary-only refresh (see CHANGED above)"
    return 1
  fi
  echo "OK config: the five config paths are byte-identical"
  [[ "$rc" == 0 ]] || { do_log "FAIL install.sh --binary-only exited $rc: the old binary was kept or restored"; return 1; }
  if [[ "$dry" == 1 ]]; then do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; fi
  do_log "OK the spool binary is at $want"
}

# spool_refresh_config_fingerprint: one "<path> <sha256|link -> target|absent>"
# line per config path a full install would write, in a fixed order
spool_refresh_config_fingerprint() {
  local p mcp="${MCP_BOT_HOME:-$HOME/.local/mcp-bot}"
  for p in "${XDG_CONFIG_HOME:-$HOME/.config}/spool-agent/env" "$HOME/.bashrc" \
    "$HOME/.claude/CLAUDE.md" "$HOME/.claude/settings.json" \
    "$mcp/mcp-start.sh" "$mcp/mcp-start-chrome.sh" "$mcp/reap-profiles.sh"; do
    if [[ -L "$p" ]]; then echo "$p link -> $(readlink "$p")"
    elif [[ -f "$p" ]]; then echo "$p $(sha256sum "$p" | cut -d' ' -f1)"
    else echo "$p absent"; fi
  done
}

# spool_refresh_bin_say <bin>: "commit <sha> version <v>", or "absent"
spool_refresh_bin_say() {
  [[ -x "$1" ]] || { echo "absent"; return 0; }
  local rev
  if [[ -n "${SPOOL_INSTALL_BINREV:-}" ]]; then rev="$("$SPOOL_INSTALL_BINREV" "$1")"
  else rev="$(spl_host_spool_bin_rev "$1" | cut -d' ' -f1)"; fi
  echo "commit ${rev:-unknown} version $("$1" version 2>/dev/null | sed -n 1p)"
}
