#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the OpenAI Codex CLI for the box's AGENT user (spec 161
# @description 2.2): a thin wrapper over the box installer,
# @description `spool-install/install.sh --cli codex --cli-only`, run as the
# @description agent user (never the human user) in its own home. It installs
# @description EXACTLY the cnf pin env.box.openai_codex.version of the npm
# @description package @openai/codex (never latest); a codex already at the
# @description pin is not reinstalled. Then the flag contract (codex --help
# @description names exec, resume, --ask-for-approval and
# @description --dangerously-bypass-approvals-and-sandbox, else the pin is
# @description refused), telemetry off ([analytics] enabled = false), no
# @description self-update (check_for_update_on_startup = false) and
# @description cli_auth_credentials_store = "file" in ~/.codex/config.toml,
# @description and the subscription login ~/.codex/auth.json by mode and
# @description owner only (the cnf auth marker; the owner logs in with
# @description `codex login --device-auth`, nothing here writes it).
# @description Codex stays off until then: it has no weight in
# @description agent_split_by_kind. DRY_RUN=1 (the DEFAULT) prints the plan
# @description and changes nothing; DRY_RUN=0 installs.
# @param DRY_RUN (optional) - 1 prints the plan, changes nothing (default 1); 0 installs
# @param SPOOL_AGENT_USER (optional) - the agent user, default from $SPOOL_ROOT/box.env
# @param OPENAI_CODEX_AGENT_HOME (optional) - the agent home, default its passwd entry
# @param OPENAI_CODEX_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param OPENAI_CODEX_INSTALLER (optional, tests) - default the checkout's install.sh
# @example ./run -a do_install_openai_codex
# @example DRY_RUN=0 ./run -a do_install_openai_codex
#------------------------------------------------------------------------------
do_install_openai_codex() {
  local inst="" cnf="" pin="" agent="" home="" rc=0 dry=()
  # shellcheck source=install-agy-cli.func.sh
  declare -F _spl_agent_cli_prep >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/install-agy-cli.func.sh" || return 1
  _spl_agent_cli_prep openai_codex "" "one pinned X.Y.Z" 1 \
    "${OPENAI_CODEX_INSTALLER:-}" "${OPENAI_CODEX_CNF:-}" "${OPENAI_CODEX_AGENT_HOME:-}" || return $?
  do_log "INFO @openai/codex $pin (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)${dry:+, DRY RUN}"
  local args=(--cli codex --cli-only "${dry[@]}")
  _spl_agent_cli_exec "$agent" "$home" SPOOL_INSTALL_CODEX_VERSION="$pin" -- bash "$inst" "${args[@]}" || rc=$?
  (( rc == 0 )) || { do_log "FAIL install.sh --cli codex exited $rc"; return "$rc"; }
  (( ${#dry[@]} )) && { do_log "OK dry run: nothing installed (DRY_RUN=0 installs)"; return 0; }
  do_log "OK @openai/codex $pin for $agent"
}
