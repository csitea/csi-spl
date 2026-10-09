#!/bin/bash
#------------------------------------------------------------------------------
# @description Refresh ONLY the agent skills and slash commands from the
# @description checkout's spawn-agents/assets into ~/.claude (and ~/.qwen/skills,
# @description ~/.gemini/config/skills where those dirs exist), for every box
# @description user. It runs step 5b's own renderer, read out of
# @description spool-install/install.sh at run time (one copy of the rule):
# @description a file is written only when it is absent or carries the
# @description spool-install marker; an unmarked (hand-made, engine) file and a
# @description hand-edited marked one are left alone and named. Nothing else of
# @description the full installer runs: the full one resets the agent env to
# @description dev with an empty tenant and rewrites .bashrc, CLAUDE.md,
# @description settings.json and the mcp-bot links, so this snapshots those
# @description five config paths before and after (spl-spool-refresh's
# @description fingerprint) and FAILS when any of them changed. The other users
# @description are reached through `sudo -n -u <user>` as do_spl_spool_refresh
# @description does (SPOOL_REFRESH_USERS / _HOMES / _AS). A second run writes
# @description nothing. Dry run unless DRY_RUN=0: the renderer runs on a scratch
# @description copy of each user's skill dirs and prints what it would write.
# @description The checkout must be AT trunk for DRY_RUN=0 (do_spl_box_update).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SKILLS_REFRESH_CHECKOUT (optional) - the repo root the skills are
# @param   rendered from (their {{HARNESS_DIR}}), default the MAIN checkout of
# @param   this clone (never a worktree, which goes away)
# @param SKILLS_REFRESH_TRUNK (optional) - the trunk ref, default origin/master
# @param SKILLS_REFRESH_INSTALLER (optional, tests) - the install.sh 5b is read from
# @param SPOOL_REFRESH_USERS / SPOOL_REFRESH_HOMES / SPOOL_REFRESH_AS - as do_spl_spool_refresh
# @example ./run -a do_spl_skills_refresh
# @example DRY_RUN=0 ./run -a do_spl_skills_refresh
#------------------------------------------------------------------------------
do_spl_skills_refresh() {
  local dry="${DRY_RUN:-1}" co head trunk inst harness py before after rc=0 u h
  local -a others=()
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  co="${SKILLS_REFRESH_CHECKOUT:-$(spl_skills_refresh_main_checkout)}"
  [[ -n "$co" && -d "$co" ]] || { do_log "FATAL cannot find the main checkout of $APP_PATH"; return 1; }
  harness="$co/$(basename "$PROJ_PATH")/src/bash/features/spawn-agents"
  inst="${SKILLS_REFRESH_INSTALLER:-$co/$(basename "$PROJ_PATH")/src/bash/features/spool-install/install.sh}"
  [[ -d "$harness/assets/skills" ]] || { do_log "FATAL no skills in $harness/assets"; return 1; }
  py="$(spl_skills_refresh_renderer "$inst")"
  [[ -n "$py" ]] || { do_log "FATAL step 5b's renderer (<<'EOF_PY' ... EOF_PY) is not in $inst"; return 1; }

  head="$(git -C "$co" rev-parse -q --verify HEAD 2>/dev/null)"
  trunk="$(git -C "$co" rev-parse -q --verify "${SKILLS_REFRESH_TRUNK:-origin/master}^{commit}" 2>/dev/null)"
  [[ -n "$trunk" ]] || { do_log "FATAL cannot resolve ${SKILLS_REFRESH_TRUNK:-origin/master} in $co"; return 1; }
  if [[ "$head" != "$trunk" ]]; then
    [[ "$dry" == 1 ]] || { do_log "FATAL $co is at ${head:-nothing}, trunk is $trunk: fetch first (do_spl_box_update) - nothing changed"; return 1; }
    echo "WARN $co is at ${head:-nothing}, trunk is $trunk: a DRY_RUN=0 run refuses"
  fi

  u="$(spool_refresh_other_users)" || return 1
  read -r -a others <<<"$u"
  echo "REFRESH skills + commands from $harness/assets at ${head:0:12} (user $USER${others[*]:+, also: ${others[*]}}, DRY_RUN=$dry)"
  before="$(spool_refresh_config_fingerprint; for u in "${others[@]}"; do spool_refresh_as_fp "$u"; done)"
  printf '%s\n' "$before" | sed 's/^/BEFORE config: /'

  for u in "$USER" "${others[@]}"; do
    h="$(spool_refresh_home_of "$u")"
    echo "SKILLS $u ($h)"
    spool_refresh_as "$u" env HOME="$h" XDG_CONFIG_HOME= XDG_STATE_HOME= PATH="$PATH" \
      bash -c "$(declare -f spl_skills_refresh_user); spl_skills_refresh_user \"\$@\"" _ \
      "$h" "$harness" "$dry" "$py" "${SPOOL_ROOT:-}" "${SPOOL_AGENT_CEILING:-40}" "${SPOOL_ORCHESTRATOR_ID:-orchestrator}" 2>&1 | sed 's/^/  /'
    [[ "${PIPESTATUS[0]}" == 0 ]] || { echo "FAIL skills $u: the render failed (named above)"; rc=1; }
  done

  after="$(spool_refresh_config_fingerprint; for u in "${others[@]}"; do spool_refresh_as_fp "$u"; done)"
  if [[ "$before" != "$after" ]]; then
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n 's/^> /CHANGED config: /p'
    do_log "FAIL a config path changed during a skills-only refresh (see CHANGED above)"
    return 1
  fi
  echo "OK config: the five config paths are byte-identical"
  [[ "$rc" == 0 ]] || { do_log "FAIL the skills render failed for a user (named above)"; return 1; }
  if [[ "$dry" == 1 ]]; then do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; fi
  do_log "OK skills + commands at ${head:0:12} for $USER${others[*]:+ ${others[*]}}"
}

# spl_skills_refresh_main_checkout: the main checkout of APP_PATH's clone (a
# linked worktree resolves to it), or nothing
spl_skills_refresh_main_checkout() {
  local g
  g="$(git -C "$APP_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [[ -n "$g" ]] && (cd "$g/.." 2>/dev/null && pwd)
}

# spl_skills_refresh_renderer <install.sh>: the body of step 5b's python
# renderer (the <<'EOF_PY' heredoc), or nothing
spl_skills_refresh_renderer() {
  [[ -f "$1" ]] || return 0
  awk '/<<.EOF_PY./ { on = 1; next } on && /^EOF_PY$/ { exit } on' "$1"
}

# spl_skills_refresh_user <home> <harness> <dry> <py> <root|""> <ceiling> <orc>:
# run as the user (declare -f'd across the sudo hop). Renders into <home>, or
# with dry=1 into a scratch copy of its skill dirs and prints what would change.
spl_skills_refresh_user() {
  local home="$1" harness="$2" dry="$3" py="$4" root="$5" ceiling="$6" orc="$7"
  local qwen=0 agy=0 fleet tgt d f rel n=0
  [ -d "$home/.qwen" ] && qwen=1
  [ -d "$home/.gemini" ] && agy=1
  # install.sh's own SPOOL_ROOT default: the fleet's, else the user's state dir
  fleet="$(sed -n 's/^SPOOL_INSTALL_FLEET=//p' "$home/.config/spool-agent/env" 2>/dev/null | tail -1)"
  [ -n "$fleet" ] || { grep -qF '<!-- spool-install: begin claude-md' "$home/.claude/CLAUDE.md" 2>/dev/null && fleet=1; }
  if [ -z "$root" ]; then
    if [ "$fleet" = 1 ]; then root=/var/spool-hub; else root="$home/.local/state/spool-hub"; fi
  fi
  tgt="$home"
  if [ "$dry" = 1 ]; then
    tgt="$(mktemp -d)" || return 1
    for d in .claude/commands .claude/skills .qwen/skills .gemini/config/skills; do
      [ -d "$home/$d" ] || continue
      mkdir -p "$tgt/${d%/*}" && cp -a "$home/$d" "$tgt/$d" 2>/dev/null
    done
  fi
  python3 - "$harness/assets" "$tgt" "$qwen" 0 "$harness" "$root" "$ceiling" "$orc" "$agy" <<<"$py" 2>&1 |
    sed "s#$tgt/#$home/#g"
  [ "${PIPESTATUS[0]}" = 0 ] || { [ "$dry" = 1 ] && rm -rf "$tgt"; return 1; }
  if [ "$dry" = 1 ]; then
    while IFS= read -r f; do
      rel="${f#"$tgt"/}"
      cmp -s "$f" "$home/$rel" || { echo "would write $home/$rel"; n=$((n + 1)); }
    done < <(find "$tgt" -type f -name '*.md' | sort)
    echo "would write $n file(s)"
    rm -rf "$tgt"
  fi
}
