#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the Mistral Vibe CLI for the box's AGENT user (spec 110
# @description 2.2): a thin wrapper over the box installer,
# @description `spool-install/install.sh --cli mistral --cli-only`, run as the
# @description agent user (never the human user) in its own home. It installs
# @description EXACTLY the cnf pin env.box.mistral_vibe.version of the PyPI
# @description package mistral-vibe (uv tool install, else pipx; never
# @description curl | bash); a vibe already at the pin is not reinstalled.
# @description Then the flag contract (vibe --help names --auto-approve,
# @description --resume, --continue and -p, else the pin is refused), the
# @description dependency list, active_model (cnf env.box.mistral_vibe.model)
# @description in ~/.vibe/config.toml when it has none, and the login file's
# @description mode and owner. The key is never read: do_set_mistral_key
# @description writes it. On the satellite, run it there (its agent user is
# @description the box user). DRY_RUN=1 prints the plan.
# @param DRY_RUN (optional) - 1 prints the plan, changes nothing (default 0)
# @param SPOOL_AGENT_USER (optional) - the agent user, default from $SPOOL_ROOT/box.env
# @param MISTRAL_VIBE_AGENT_HOME (optional) - the agent home, default its passwd entry
# @param MISTRAL_VIBE_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param MISTRAL_VIBE_INSTALLER (optional, tests) - default the checkout's install.sh
# @example ./run -a do_install_mistral_vibe
# @example DRY_RUN=1 ./run -a do_install_mistral_vibe
#------------------------------------------------------------------------------
do_install_mistral_vibe() {
  local inst="" cnf="" pin="" model agent="" home="" rc=0 dry=()
  # shellcheck source=install-agy-cli.func.sh
  declare -F _spl_agent_cli_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/install-agy-cli.func.sh" || return 1
  _spl_agent_cli_prep mistral_vibe "" "one pinned X.Y.Z" 0 \
    "${MISTRAL_VIBE_INSTALLER:-}" "${MISTRAL_VIBE_CNF:-}" "${MISTRAL_VIBE_AGENT_HOME:-}" || return $?
  model="$(yq -r '.env.box.mistral_vibe.model // ""' "$cnf")"
  do_log "INFO mistral-vibe $pin (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)"
  local args=(--cli mistral --cli-only "${dry[@]}")
  _spl_agent_cli_exec "$agent" "$home" SPOOL_INSTALL_MISTRAL_VERSION="$pin" SPOOL_INSTALL_MISTRAL_MODEL="$model" \
    -- bash "$inst" "${args[@]}" || rc=$?
  (( rc == 0 )) || { do_log "FAIL install.sh --cli mistral exited $rc"; return "$rc"; }
  do_log "OK mistral-vibe $pin for $agent"
}
