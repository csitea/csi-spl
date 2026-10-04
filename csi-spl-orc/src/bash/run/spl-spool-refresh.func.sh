#!/bin/bash
#------------------------------------------------------------------------------
# @description Refresh ONLY the installed spool binary to trunk, through
# @description `install.sh --binary-only`. ONE installed copy per machine
# @description (owner, 2026-10-04: "keep one installed copy, so every update
# @description reaches everything at once"): the build goes to the shared
# @description SPOOL_SHARED_BIN, and every box user's (the box user, the
# @description agent user) <prefix>/share/spool-agent/tools/bin/spool is a
# @description link to it - <prefix>/bin/spool stays a link to that. A real
# @description file at the tools path is kept as spool.bak, then linked. The
# @description other users are linked through `sudo -n -u <user>` running
# @description the same installer with SPOOL_INSTALL_NO_BUILD=1 (links only).
# @description A second run changes nothing. The full installer also rewrites
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
# @param SPOOL_SHARED_BIN (optional) - the one copy. Unset: where this user's
# @param   tools/bin/spool already links (adopted), else this user's own copy
# @param   only, and the adopt line is printed (the path to use is
# @param   /var/<org>/<org>-<app>/spool/bin/spool). Empty: own copy only.
# @param SPOOL_REFRESH_USERS (optional) - default $USER plus the box's
# @param   SPOOL_AGENT_USER (spool_env_resolve, the box config)
# @param SPOOL_REFRESH_HOMES (optional, tests) - "<user>=<home> ..." instead of getent
# @param SPOOL_REFRESH_AS (optional, tests) - the user hop, default "sudo -n -u"
# @example ./run -a do_spl_spool_refresh
# @example DRY_RUN=0 ./run -a do_spl_spool_refresh
# @example SPOOL_SHARED_BIN=/var/<org>/<org>-<app>/spool/bin/spool DRY_RUN=1 ./run -a do_spl_spool_refresh
#------------------------------------------------------------------------------
do_spl_spool_refresh() {
  local dry="${DRY_RUN:-1}" trunk head want before after rc u h org_app shared grp
  local -a users=() others=()
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  local inst="${SPOOL_REFRESH_INSTALLER:-$PROJ_PATH/src/bash/features/spool-install/install.sh}"
  local bin="${SPOOL_INSTALL_PREFIX:-$HOME/.local}/share/spool-agent/tools/bin/spool"
  [[ -f "$inst" ]] || { do_log "FATAL the installer is missing: $inst"; return 1; }
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  # adopting the shared copy is an explicit act (SPOOL_SHARED_BIN); after it
  # the tools path is a link, and every later run (the cron) follows it
  shared="${SPOOL_SHARED_BIN-}"
  if [[ -z "${SPOOL_SHARED_BIN+x}" ]]; then
    if [[ -L "$bin" ]]; then shared="$(readlink -f "$bin")"
    else echo "NOTE per-user copy: adopt the one installed copy with SPOOL_SHARED_BIN=/var/${org_app%%-*}/$org_app/spool/bin/spool"; fi
  fi
  if [[ -n "$shared" ]]; then
    read -r -a users <<<"${SPOOL_REFRESH_USERS:-$USER $(spool_refresh_agent_user)}"
    for u in "${users[@]}"; do
      [[ "$u" == "$USER" || " ${others[*]} " == *" $u "* ]] && continue
      [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL bad user in SPOOL_REFRESH_USERS: '$u'"; return 1; }
      h="$(spool_refresh_home_of "$u")"
      [[ -n "$h" ]] || { do_log "FATAL no home for user '$u'"; return 1; }
      others+=("$u")
    done
    grp="$(stat -c %G "${SPOOL_ROOT:-/var/spool-hub}" 2>/dev/null)"
    [[ "$grp" == UNKNOWN ]] && grp=""
  fi

  head="$(git -C "$APP_PATH" rev-parse -q --verify HEAD 2>/dev/null)"
  trunk="$(git -C "$APP_PATH" rev-parse -q --verify "${SPOOL_REFRESH_TRUNK:-origin/master}^{commit}" 2>/dev/null)"
  [[ -n "$trunk" ]] || { do_log "FATAL cannot resolve ${SPOOL_REFRESH_TRUNK:-origin/master} in $APP_PATH"; return 1; }
  if [[ "$head" != "$trunk" ]]; then
    [[ "$dry" == 1 ]] || { do_log "FATAL $APP_PATH is at ${head:-nothing}, trunk is $trunk: fetch first (do_spl_box_update) - nothing changed"; return 1; }
    echo "WARN $APP_PATH is at ${head:-nothing}, trunk is $trunk: a DRY_RUN=0 run refuses"
  fi
  want="$trunk"

  echo "REFRESH spool binary ${shared:-$bin} -> $want (user $USER${others[*]:+, linked: ${others[*]}}, DRY_RUN=$dry)"
  echo "BEFORE binary: $(spool_refresh_bin_say "$bin")"
  for u in "${others[@]}"; do echo "BEFORE $u: $(spool_refresh_user_say "$u")"; done
  before="$(spool_refresh_config_fingerprint; for u in "${others[@]}"; do spool_refresh_as_fp "$u"; done)"
  printf '%s\n' "$before" | sed 's/^/BEFORE config: /'

  local -a args=(--binary-only)
  [[ "$dry" == 1 ]] && args+=(--dry-run)
  SPOOL_INSTALL_SHARED="$shared" SPOOL_INSTALL_SHARED_GROUP="${grp:-}" SPOOL_INSTALL_EXPECT_REV="$want" \
    bash "$inst" "${args[@]}" 2>&1 | sed 's/^/  /'
  rc="${PIPESTATUS[0]}"
  # the other users only link to the copy built above: never a second build
  if [[ "$rc" == 0 ]]; then
    for u in "${others[@]}"; do
      echo "LINK $u -> $shared"
      h="$(spool_refresh_home_of "$u")"
      spool_refresh_as "$u" env HOME="$h" XDG_CONFIG_HOME= SPOOL_INSTALL_PREFIX="$h/.local" \
        SPOOL_INSTALL_SHARED="$shared" SPOOL_INSTALL_NO_BUILD=1 \
        SPOOL_INSTALL_EXPECT_REV="$want" ${SPOOL_INSTALL_BINREV:+SPOOL_INSTALL_BINREV="$SPOOL_INSTALL_BINREV"} \
        PATH="$PATH" bash "$inst" "${args[@]}" 2>&1 | sed 's/^/  /'
      [[ "${PIPESTATUS[0]}" == 0 ]] || { echo "FAIL link $u: its installer run failed (named above)"; rc=1; }
    done
  fi

  after="$(spool_refresh_config_fingerprint; for u in "${others[@]}"; do spool_refresh_as_fp "$u"; done)"
  echo "AFTER binary: $(spool_refresh_bin_say "$bin")"
  for u in "${others[@]}"; do echo "AFTER $u: $(spool_refresh_user_say "$u")"; done
  if [[ "$before" != "$after" ]]; then
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> /CHANGED config: /p'
    do_log "FAIL a config path changed during a binary-only refresh (see CHANGED above)"
    return 1
  fi
  echo "OK config: the five config paths are byte-identical"
  [[ "$rc" == 0 ]] || { do_log "FAIL install.sh --binary-only exited $rc: the old binary was kept or restored"; return 1; }
  if [[ "$dry" == 1 ]]; then do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; fi
  if [[ -n "$shared" ]]; then
    for u in "$USER" "${others[@]}"; do
      h="$(spool_refresh_as "$u" readlink -f "$(spool_refresh_home_of "$u")/.local/bin/spool" 2>/dev/null)"
      [[ "$h" == "$(readlink -f "$shared")" ]] || { do_log "FAIL $u's spool resolves to '${h:-nothing}', not $shared"; return 1; }
    done
    do_log "OK one installed copy: $shared at $want, run by ${users[*]}"; return 0
  fi
  do_log "OK the spool binary is at $want"
}

# spool_refresh_agent_user: the box's agent user (the box config), or nothing
spool_refresh_agent_user() {
  declare -F spool_env_resolve >/dev/null || return 0
  ( SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "${SPOOL_AGENT_USER:-}" )
}

# spool_refresh_home_of <user>: SPOOL_REFRESH_HOMES, else $HOME for $USER, else getent
spool_refresh_home_of() {
  local kv
  for kv in ${SPOOL_REFRESH_HOMES:-}; do [[ "${kv%%=*}" == "$1" ]] && { echo "${kv#*=}"; return 0; }; done
  [[ "$1" == "$USER" ]] && { echo "$HOME"; return 0; }
  getent passwd "$1" | cut -d: -f6
}

# spool_refresh_as <user> <cmd...>: run as that user (direct when it is us)
spool_refresh_as() {
  local u="$1"; shift
  if [[ "$u" == "$USER" ]]; then "$@"; return; fi
  local -a hop
  read -r -a hop <<<"${SPOOL_REFRESH_AS:-sudo -n -u}"
  "${hop[@]}" "$u" -- "$@"
}

# spool_refresh_as_fp <user>: that user's config fingerprint, read as them
spool_refresh_as_fp() {
  spool_refresh_as "$1" env HOME="$(spool_refresh_home_of "$1")" XDG_CONFIG_HOME= MCP_BOT_HOME= \
    bash -c "$(declare -f spool_refresh_config_fingerprint); spool_refresh_config_fingerprint" 2>/dev/null ||
    echo "$1 unreadable"
}

# spool_refresh_user_say <user>: "<tools path> -> <file> sha256 <12>", read as them
spool_refresh_user_say() {
  local t
  t="$(spool_refresh_home_of "$1")/.local/share/spool-agent/tools/bin/spool"
  spool_refresh_as "$1" bash -c 'f="$(readlink -f "$1")"; [ -f "$f" ] || { echo "$1 absent"; exit 0; }
    echo "$1 -> $f sha256 $(sha256sum <"$f" | cut -c1-12)"' _ "$t" 2>/dev/null || echo "$t unreadable"
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
