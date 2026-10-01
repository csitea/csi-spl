#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057, owner topic 5fe56859: replicate THIS box's AI-user
# @description setup onto the satellite's box user, over the IAP ssh,
# @description idempotent and re-runnable after a recreate. One REPL verdict
# @description line per part:
# @description   home     the stateful home dirs (SATELLITE_PERSIST) live on
# @description            the DATA disk, /mnt/data/home/<user>/<dir>, linked
# @description            into the home: a recreate wipes the boot disk, not
# @description            them (the owner's claude login in ~/.claude included).
# @description            On a recreate the data copy wins; the fresh boot one
# @description            is kept aside as <dir>.boot-aside
# @description   claude   ~/.claude: CLAUDE.md, statusline-title.sh, skills/,
# @description            commands/, every projects/*/memory/ (the agents'
# @description            memory, NOT transcripts), and settings.json merged
# @description            (this box's keys win, the satellite's own hooks are
# @description            kept). NEVER .credentials.json, history, transcripts
# @description   tmux     ~/.tmux.conf and ~/.tmux/
# @description   git      user.name / user.email from this box's global config,
# @description            and the https helper that reads ~/.github/token
# @description   gh       `gh auth login --with-token` from ~/.github/token
# @description This box's home path inside the copied text files is rewritten
# @description to the satellite's. No credential is copied here (that is
# @description do_satellite_creds_push); the AI CLI logins are the owner's.
# @param SATELLITE_PERSIST (optional) - space list of home dirs on the data
# @param        disk, default ".claude .local .config .cache .gcp .github go .npm .terraform.d .tmux"
# @param DRY_RUN (optional) - 1: list what would be copied, change nothing
# @example ./run -a do_satellite_replicate_ai_user
#------------------------------------------------------------------------------
do_satellite_replicate_ai_user() {
  do_satellite_ssh_opts || return 1
  local persist="${SATELLITE_PERSIST:-.claude .local .config .cache .gcp .github go .npm .terraform.d .tmux}"
  local name email p
  local -a paths=()
  for p in .claude/CLAUDE.md .claude/settings.json .claude/statusline-title.sh .claude/skills .claude/commands .tmux.conf .tmux; do
    [[ -e "$HOME/$p" ]] && paths+=("$p")
  done
  while IFS= read -r p; do paths+=("${p#"$HOME"/}"); done < <(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type d -name memory 2>/dev/null | sort)
  name=$(git config --global user.name 2>/dev/null)
  email=$(git config --global user.email 2>/dev/null)

  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    do_log "INFO DRY_RUN home dirs on the data disk: ${persist}"
    for p in "${paths[@]}"; do do_log "INFO DRY_RUN would copy ~/$p"; done
    do_log "INFO DRY_RUN git identity: ${name:-<unset>} <${email:-unset}>; gh auth from ~/.github/token"
    return 0
  fi

  local tar_excl=(--exclude='*.jsonl' --exclude='.credentials.json' --exclude='node_modules' --exclude='*.sock')
  # the on-VM half first (satellite-replicate-ai-user.sh), then the tar into it
  ssh "${SATELLITE_SSH[@]}" "cat >\"\$HOME/.satellite-replica.sh\"" <"${PROJ_PATH}/src/bash/scripts/satellite-replicate-ai-user.sh" \
    || { do_log "FATAL cannot write the replica script on the satellite"; return 1; }
  # shellcheck disable=SC2029
  tar -C "$HOME" -czf - "${tar_excl[@]}" "${paths[@]}" \
    | ssh "${SATELLITE_SSH[@]}" "BOXHOME='${HOME}' PERSIST='${persist}' GIT_NAME='${name}' GIT_EMAIL='${email}' bash \"\$HOME/.satellite-replica.sh\"" \
    || { do_log "FATAL a REPL part failed (the lines above)"; return 1; }
  do_log "OK the box's AI-user setup is on the satellite: ./run -a do_satellite_verify"
}
