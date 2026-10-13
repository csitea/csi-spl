#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the agy (Antigravity) CLI for the box's AGENT user: a
# @description thin wrapper over the box installer,
# @description `spool-install/install.sh --cli agy --cli-only`, run as the
# @description agent user (never the human user) in its own home, with the cnf
# @description pin env.box.agy_cli.version (1.3.4 while the cnf has none). The
# @description vendor serves only its latest from its own installer and agy
# @description updates itself, so the pin is a FLOOR: an agy at or above it is
# @description not touched, none is installed by the vendor installer, one
# @description below it is moved up with `agy update`; still below the pin is
# @description refused (exit 4). Then `agy --version` as the agent user. The
# @description sign-in is never read or copied: an unsigned agy is signed in
# @description on its box by its user. DRY_RUN=1 (the default) prints the plan.
# @param DRY_RUN (optional) - 1 prints the plan, changes nothing (default 1)
# @param SPOOL_AGENT_USER (optional) - the agent user, default from $SPOOL_ROOT/box.env
# @param AGY_CLI_AGENT_HOME (optional) - the agent home, default its passwd entry
# @param AGY_CLI_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param AGY_CLI_INSTALLER (optional, tests) - default the checkout's install.sh
# @example DRY_RUN=1 ./run -a do_install_agy_cli
# @example DRY_RUN=0 ./run -a do_install_agy_cli
#------------------------------------------------------------------------------
do_install_agy_cli() {
  do_require_bin yq || return 1
  local org_app cnf pin agent home have cur rc=0 dry=()
  local inst="${AGY_CLI_INSTALLER:-$PROJ_PATH/src/bash/features/spool-install/install.sh}"
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}"
  cnf="${AGY_CLI_CNF:-$APP_PATH/$org_app-cnf/$org_app/all.env.yaml}"
  [[ -r "$cnf" ]] || { do_log "FATAL no cnf $cnf"; return 1; }
  pin="$(yq -r '.env.box.agy_cli.version // "1.3.4"' "$cnf")"
  [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    do_log "FATAL cnf env.box.agy_cli.version must be one X.Y.Z, got '$pin': never latest ($cnf)"; return 2; }
  case "${DRY_RUN:-1}" in 0) ;; 1) dry=(--dry-run) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 1 ;; esac
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  agent="$(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s' "$SPOOL_AGENT_USER")"
  [[ -n "$agent" ]] || { do_log "FATAL no agent user: set SPOOL_AGENT_USER"; return 1; }
  home="${AGY_CLI_AGENT_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -d "$home" ]] || { do_log "FATAL no home for the agent user $agent: $home"; return 1; }
  do_log "INFO agy $pin or newer (cnf ${cnf#"$APP_PATH"/}) for the agent user $agent ($home)"
  local args=(--cli agy --cli-only "${dry[@]}") envs=(SPOOL_INSTALL_AGY_VERSION="$pin")
  # as_agent <cmd...>: run as the agent user in its home (itself: no sudo)
  as_agent() {
    if [[ "$(id -un)" == "$agent" ]]; then HOME="$home" env "${envs[@]}" "$@"
    else sudo -n -u "$agent" -H env "${envs[@]}" "$@"; fi
  }
  as_agent bash "$inst" "${args[@]}" || rc=$?
  (( rc == 0 )) || { do_log "FAIL install.sh --cli agy exited $rc"; return "$rc"; }
  [[ "${DRY_RUN:-1}" == 1 ]] && { do_log "OK DRY_RUN=1: nothing changed"; return 0; }
  have="$home/.local/bin/agy"
  [[ -x "$have" ]] || have="$(as_agent bash -lc 'command -v agy' 2>/dev/null)"
  cur="$(as_agent "${have:-agy}" --version 2>/dev/null | sed -n 1p)"
  [[ -n "$cur" ]] || { do_log "FAIL agy --version as $agent printed nothing (${have:-no agy})"; return 4; }
  do_log "OK agy $cur for $agent ($have), pin $pin"
}
