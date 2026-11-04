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
# @description refused), telemetry off ([analytics] enabled = false) and
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
  do_require_bin yq || return 1
  local org_app cnf pin agent home rc=0 dry=()
  local inst="${OPENAI_CODEX_INSTALLER:-$PROJ_PATH/src/bash/features/spool-install/install.sh}"
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}"
  cnf="${OPENAI_CODEX_CNF:-$APP_PATH/$org_app-cnf/$org_app/all.env.yaml}"
  [[ -r "$cnf" ]] || { do_log "FATAL no cnf $cnf"; return 1; }
  pin="$(yq -r '.env.box.openai_codex.version // ""' "$cnf")"
  [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    do_log "FATAL cnf env.box.openai_codex.version must be one pinned X.Y.Z, got '$pin': never latest ($cnf)"; return 2; }
  case "${DRY_RUN:-1}" in 0) ;; 1) dry=(--dry-run) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 1 ;; esac
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "$SPOOL_AGENT_USER")"
  [[ -n "$agent" ]] || { do_log "FATAL no agent user: set SPOOL_AGENT_USER"; return 1; }
  home="${OPENAI_CODEX_AGENT_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -d "$home" ]] || { do_log "FATAL no home for the agent user $agent: $home"; return 1; }
  do_log "INFO @openai/codex $pin (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)${dry:+, DRY RUN}"
  local args=(--cli codex --cli-only "${dry[@]}")
  local envs=(SPOOL_INSTALL_CODEX_VERSION="$pin")
  if [[ "$(id -un)" == "$agent" ]]; then HOME="$home" env "${envs[@]}" bash "$inst" "${args[@]}" || rc=$?
  else sudo -n -u "$agent" -H env "${envs[@]}" bash "$inst" "${args[@]}" || rc=$?
  fi
  (( rc == 0 )) || { do_log "FAIL install.sh --cli codex exited $rc"; return "$rc"; }
  (( ${#dry[@]} )) && { do_log "OK dry run: nothing installed (DRY_RUN=0 installs)"; return 0; }
  do_log "OK @openai/codex $pin for $agent"
}
