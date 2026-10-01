#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057, owner topic b23639e2 ("you had to replicate all of the
# @description bashrc and ai-user environment - check the ysg-box project"):
# @description give the satellite's box user (owner role) and agent user (agent
# @description role) the shell + AI-user environment of ysg-box's claude-config:
# @description .bashrc .bash_profile .profile .bash_logout, ~/.claude CLAUDE.md,
# @description settings, commands, skills, and the dotfiles, rendered for box
# @description `sat` (the csi overlay's boxes/sat) the way the hub renders any
# @description remote box (nea): render + pack HERE, apply THERE per role with
# @description claude-apply.sh (pure bash, writes only that user's HOME, keeps a
# @description backup, holds local edits, smoke-tests a rewritten .bashrc).
# @description The render reads an EXPORT of the overlay without ysg-box-cnf:
# @description that file is the hub's own box layer and the resolver would read
# @description it before boxes/sat/box.env (boxes/sat/box.env says why).
# @description A pack carries no secret (the render lints for them). DRY RUN
# @description (default): render + pack + list, nothing leaves this box.
# @description DRY_RUN=0: ship the pack, apply owner then agent (needs both
# @description users on the VM).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param YSG_BOX_ORG_ROOT - required, no default: the org overlay checkout that
# @param        holds boxes/sat (the hub's main checkout of it)
# @param YSG_BOX_ENGINE (optional) - default: BOX_ENGINE_ROOT of boxes/sat/box.env
# @param SATELLITE_OWNER_USER / SATELLITE_AGENT_USER (optional) - default: the
# @param        BOX_USER / BOX_AGENT_USER of boxes/sat/box.env
# @example YSG_BOX_ORG_ROOT=<overlay> ./run -a do_satellite_claude_config
# @example YSG_BOX_ORG_ROOT=<overlay> DRY_RUN=0 ./run -a do_satellite_claude_config
#------------------------------------------------------------------------------
do_satellite_claude_config() {
  local dry_run="${DRY_RUN:-1}"
  [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  : "${YSG_BOX_ORG_ROOT:?YSG_BOX_ORG_ROOT must be set (no default) - the org overlay checkout holding boxes/sat}"
  local org="$YSG_BOX_ORG_ROOT" benv="$YSG_BOX_ORG_ROOT/boxes/sat/box.env" eng
  [[ -f "$benv" ]] || { do_log "FATAL no $benv"; return 1; }
  eng="${YSG_BOX_ENGINE:-$(sed -n 's/^BOX_ENGINE_ROOT="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$benv")}"
  local scripts="$eng/ysg-box-orc/src/bash/features/claude-config/scripts"
  [[ -f "$scripts/claude-render.sh" ]] || { do_log "FATAL no claude-config scripts under the engine '$eng'"; return 1; }
  local owner agent
  owner="${SATELLITE_OWNER_USER:-$(sed -n 's/^BOX_USER="\{0,1\}\([a-z_][a-z0-9_-]*\)"\{0,1\}.*/\1/p' "$benv")}"
  agent="${SATELLITE_AGENT_USER:-$(sed -n 's/^BOX_AGENT_USER="\{0,1\}\([a-z_][a-z0-9_-]*\)"\{0,1\}.*/\1/p' "$benv")}"
  [[ -n "$owner" && -n "$agent" ]] || { do_log "FATAL no BOX_USER / BOX_AGENT_USER in $benv"; return 1; }

  local work exp render pack
  work=$(mktemp -d "${TMPDIR:-/var/tmp}/satellite-claude-config.XXXXXX") || return 1
  exp="$work/org" render="$work/render" pack="$work/sat.pack"
  rsync -a --exclude .git --exclude ysg-box-cnf "$org/" "$exp/" || { do_log "FATAL export of $org"; return 1; }
  bash "$scripts/claude-render.sh" --out "$render" --box sat --org-root "$exp" --role owner --role agent >"$work/render.log" 2>&1 \
    || { do_log "FATAL claude-render (log $work/render.log): $(tail -n 2 "$work/render.log" | tr '\n' ' ')"; return 1; }
  bash "$scripts/claude-pack.sh" --render "$render" --out "$pack" >"$work/pack.log" 2>&1 \
    || { do_log "FATAL claude-pack (log $work/pack.log)"; return 1; }
  do_log "OK rendered box sat: owner $(($(wc -l <"$render/owner.manifest.tsv") - 1)) files, agent $(($(wc -l <"$render/agent.manifest.tsv") - 1)) files; pack $pack ($(head -c 120 "$pack" | head -n 1))"
  if [[ "$dry_run" == 1 ]]; then
    cut -f1 "$render/owner.manifest.tsv" | tail -n +2 | sed "s#^#INFO DRY_RUN owner ($owner) ~/#"
    cut -f1 "$render/agent.manifest.tsv" | tail -n +2 | sed "s#^#INFO DRY_RUN agent ($agent) ~/#"
    do_log "OK DRY_RUN: nothing left this box. Re-run with DRY_RUN=0 (needs the users $owner + $agent on the VM)"
    return 0
  fi

  do_satellite_ssh_opts || return 1
  local u role remote=/tmp/satellite-claude-config.pack
  # shellcheck disable=SC2029
  ssh "${SATELLITE_SSH[@]}" "cat >$remote && chmod 644 $remote" <"$pack" || { do_log "FATAL ship the pack"; return 1; }
  for role in owner agent; do
    [[ "$role" == owner ]] && u="$owner" || u="$agent"
    # shellcheck disable=SC2029
    ssh "${SATELLITE_SSH[@]}" "id $u >/dev/null 2>&1 || { echo 'no user $u on the satellite'; exit 1; }; cd / && sudo -n -u $u bash $scripts/claude-apply.sh --pack $remote --role $role --box sat" \
      || { do_log "FATAL claude-apply role $role as $u"; return 1; }
  done
  # shellcheck disable=SC2029
  ssh "${SATELLITE_SSH[@]}" "rm -f $remote"
  do_log "OK the satellite's $owner + $agent carry box sat's claude-config (receipts above)"
}
