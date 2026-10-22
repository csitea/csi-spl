#!/bin/bash
#------------------------------------------------------------------------------
# @description Give the claude agents of AGENT_USER the read-only Google Cloud
# @description alert incident tools as the MCP server `gcp-alerts` (SPL-2887,
# @description spec 146): gcp_alert_incidents(env, since) and
# @description gcp_alert_incident(env, id), served by `spool mcp-gcp-alerts`.
# @description Each tool runs a named csi-spl-iac action
# @description (do_gcp_list_alert_incidents, do_gcp_get_alert_incident) as the
# @description AGENT user, which reads that user's per-env service-account key
# @description <agent home>/.gcp/.<org>/key-<org>-<app>-<env>.json; the server
# @description never runs gcloud, never reads the key and refuses a call whose
# @description env has no key file (exit 78) before the action starts.
# @description Not the spool servers (do_spl_agent_mcp_install): those run as
# @description the box user, seated, per env; this one needs no seat, no desk
# @description and no sudo hop, so it is one user-scope server with env as an
# @description argument (read-only, so a dev/prd mix-up costs nothing).
# @description What it installs, as AGENT_USER (content through stdin):
# @description   1. <agent home>/.local/share/<org>-<app>/gcp-alerts-mcp/spool,
# @description      built from THIS checkout (a replaced one is kept as .bak-<ts>)
# @description   2. <agent home>/.local/bin/gcp-alerts-mcp, which execs it with
# @description      --iac <the iac dir> --org --app
# @description   3. claude's user-scope `gcp-alerts` -> gcp-alerts-mcp, added
# @description      only when missing or different. Other CLIs: not yet.
# @description The iac dir must outlive the install: run it from the main
# @description checkout (a lane worktree is swept 24 h after its lane), or set
# @description GCP_ALERTS_IAC. A running CLI loads the server after a restart.
# @description Dry run unless DRY_RUN=0.
# @param AGENT_USER - required: the OS user the agent CLIs run as (no default)
# @param GCP_ALERTS_IAC (optional) - default $APP_PATH/<org>-<app>-iac
# @param SPL_AGENT_MCP_HOME, SPL_AGENT_MCP_BUILD (optional) - tests: the agent
# @param   home and the build script
# @param DRY_RUN (optional) - 1 (default) or 0
# @example AGENT_USER=<agent user> DRY_RUN=0 ./run -a do_spl_agent_mcp_gcp_alerts_install
#------------------------------------------------------------------------------
do_spl_agent_mcp_gcp_alerts_install() {
  do_require_bin python3 getent sudo || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local agent="${AGENT_USER:-}" me org app ahome iac build share bin wrap tmp ts out
  [[ "$agent" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL AGENT_USER must name the agent OS user (no default), got: '$agent'"; return 1; }
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+)-([a-z]+)-orc$ ]] || { do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org="${BASH_REMATCH[1]}" app="${BASH_REMATCH[2]}" me="$(id -un)"
  ahome="${SPL_AGENT_MCP_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -n "$ahome" && -d "$ahome" ]] || { do_log "FATAL no home for AGENT_USER '$agent'"; return 1; }
  iac="${GCP_ALERTS_IAC:-$APP_PATH/$org-$app-iac}"
  [[ -x "$iac/run" ]] || { do_log "FATAL no executable $iac/run (GCP_ALERTS_IAC)"; return 1; }
  if [[ -z "${GCP_ALERTS_IAC:-}" && -f "$APP_PATH/.git" ]]; then
    do_log "FATAL $APP_PATH is a git worktree, swept 24 h after its lane: run this from the main checkout or set GCP_ALERTS_IAC"; return 1
  fi
  build="${SPL_AGENT_MCP_BUILD:-$APP_PATH/$org-$app-api/src/bash/build.sh}"
  share="$ahome/.local/share/$org-$app/gcp-alerts-mcp" bin="$ahome/.local/share/$org-$app/gcp-alerts-mcp/spool"
  wrap="$ahome/.local/bin/gcp-alerts-mcp"
  as_agent() { if [[ "$agent" == "$me" ]]; then "$@"; else sudo -n -u "$agent" -H "$@"; fi; }

  if (( dry )); then
    do_log "INFO DRY_RUN would: build spool from $APP_PATH into $bin and write $wrap (--iac $iac --org $org --app $app) as $agent"
    do_log "INFO DRY_RUN would: register gcp-alerts -> $wrap in claude at user scope (where installed and missing)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to install."
    return 0
  fi

  # 1. build as the caller, probe that it serves the verb, hand it over by stdin
  tmp="$(mktemp -d)" || return 1
  out="$(bash "$build" "$tmp/spool" 2>&1)" || { rm -rf "$tmp"; do_log "FATAL spool build failed: $out"; return 1; }
  out="$("$tmp/spool" mcp-gcp-alerts --iac "$tmp/none" </dev/null 2>&1)"  # refuses by design: no run there
  [[ "$out" == *"no executable"* ]] ||
    { rm -rf "$tmp"; do_log "FATAL $tmp/spool has no mcp-gcp-alerts verb: it is older than SPL-2887"; return 1; }
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  as_agent bash -c 'set -e; mkdir -p "$1" "$(dirname "$3")"; chmod 700 "$1"
    cat >"$2.new"; chmod 755 "$2.new"
    if [ -e "$2" ] && ! cmp -s "$2" "$2.new"; then cp -p "$2" "$2.bak-$4"; fi
    mv -f "$2.new" "$2"
    printf "#!/bin/sh\n# gcp-alerts MCP server (do_spl_agent_mcp_gcp_alerts_install, SPL-2887)\nexec \"%s\" mcp-gcp-alerts --iac \"%s\" --org %s --app %s \"\$@\"\n" "$2" "$5" "$6" "$7" >"$3.new"
    chmod 755 "$3.new"; mv -f "$3.new" "$3"' \
    _ "$share" "$bin" "$wrap" "$ts" "$iac" "$org" "$app" <"$tmp/spool"
  local rc=$?; rm -rf "$tmp"
  (( rc == 0 )) || { do_log "FATAL cannot install $bin / $wrap as $agent"; return 1; }
  do_log "INFO agent side: $bin + $wrap (--iac $iac)"

  # 2. claude, user scope
  local cli="$ahome/.local/bin/claude"
  as_agent test -x "$cli" || { do_log "INFO claude is not installed for $agent ($cli): not registered"; return 0; }
  if [[ "$(spl_agent_mcp_gcp_alerts_registered "$ahome" "$wrap")" != yes ]]; then
    as_agent "$cli" mcp remove -s user gcp-alerts >/dev/null 2>&1
    as_agent "$cli" mcp add -s user gcp-alerts -- "$wrap" >/dev/null 2>&1
    [[ "$(spl_agent_mcp_gcp_alerts_registered "$ahome" "$wrap")" == yes ]] ||
      { do_log "FAIL claude: gcp-alerts is still not registered"; return 1; }
    do_log "INFO claude: registered gcp-alerts -> $wrap"
  else
    do_log "INFO claude: gcp-alerts already runs $wrap"
  fi
  do_log "OK gcp-alerts installed for $agent; a running claude sees it after a restart"
}

# spl_agent_mcp_gcp_alerts_registered <agent home> <wrapper>: yes when claude's
# user scope (~/.claude.json mcpServers) runs <wrapper> with no args as
# gcp-alerts. as_agent is the caller's.
spl_agent_mcp_gcp_alerts_registered() {
  as_agent python3 -c 'import json, sys
try: s = json.load(open(sys.argv[1])).get("mcpServers", {}).get("gcp-alerts", {})
except (OSError, ValueError): s = {}
print("yes" if s.get("command") == sys.argv[2] and not s.get("args") else "no")' "$1/.claude.json" "$2" 2>/dev/null
}
