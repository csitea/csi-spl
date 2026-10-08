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
  do_require_bin yq || return 1
  local org_app cnf pin model agent home rc=0 dry=()
  local inst="${MISTRAL_VIBE_INSTALLER:-$PROJ_PATH/src/bash/features/spool-install/install.sh}"
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}"
  cnf="${MISTRAL_VIBE_CNF:-$APP_PATH/$org_app-cnf/$org_app/all.env.yaml}"
  [[ -r "$cnf" ]] || { do_log "FATAL no cnf $cnf"; return 1; }
  pin="$(yq -r '.env.box.mistral_vibe.version // ""' "$cnf")"
  model="$(yq -r '.env.box.mistral_vibe.model // ""' "$cnf")"
  [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    do_log "FATAL cnf env.box.mistral_vibe.version must be one pinned X.Y.Z, got '$pin': never latest ($cnf)"; return 2; }
  case "${DRY_RUN:-0}" in 0) ;; 1) dry=(--dry-run) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 1 ;; esac
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "$SPOOL_AGENT_USER")"
  [[ -n "$agent" ]] || { do_log "FATAL no agent user: set SPOOL_AGENT_USER"; return 1; }
  home="${MISTRAL_VIBE_AGENT_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -d "$home" ]] || { do_log "FATAL no home for the agent user $agent: $home"; return 1; }
  do_log "INFO mistral-vibe $pin (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)"
  local args=(--cli mistral --cli-only "${dry[@]}")
  local envs=(SPOOL_INSTALL_MISTRAL_VERSION="$pin" SPOOL_INSTALL_MISTRAL_MODEL="$model")
  if [[ "$(id -un)" == "$agent" ]]; then HOME="$home" env "${envs[@]}" bash "$inst" "${args[@]}" || rc=$?
  else sudo -n -u "$agent" -H env "${envs[@]}" bash "$inst" "${args[@]}" || rc=$?
  fi
  (( rc == 0 )) || { do_log "FAIL install.sh --cli mistral exited $rc"; return "$rc"; }
  do_log "OK mistral-vibe $pin for $agent"
}
