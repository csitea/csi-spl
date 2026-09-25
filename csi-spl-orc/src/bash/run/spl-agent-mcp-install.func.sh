#!/bin/bash
#------------------------------------------------------------------------------
# @description Give every agent CLI on this box the spool as MCP tools, seated:
# @description `spool-dev` / `spool-prd`, each the five spool tools acting for
# @description the CALLING agent only (`spool mcp --as <ID>`), so an agent
# @description sends, reads its inbox and moves files as tool calls - no ./run,
# @description no rebuild and no sudo per call.
# @description ONE SERVER PER ENV, not one server with an env argument: the env
# @description is then in every tool name (mcp__spool-prd__spool_send), so a
# @description prd send is never an argument away from a dev one, and each
# @description server holds one desk's settings for the whole session.
# @description What it installs (features/spawn-agents/scripts/spool-mcp.sh):
# @description   1. box side, as the box user (who runs this action):
# @description      <box home>/.local/share/<org>-<app>/mcp/spool-mcp.sh and
# @description      the `spool` binary it runs, built from THIS checkout. The
# @description      desk actions and the reconcile cron rebuild
# @description      cloud/<env>/bin/spool from the shared checkout; this binary
# @description      is touched by nothing but this action
# @description   2. agent side, as AGENT_USER: <agent home>/.local/bin/spool-mcp
# @description      (a replaced file is kept as .bak-<ts>) and
# @description      <agent home>/.config/spool-mcp/env naming the box user
# @description   3. the registration `spool-<env>` -> `spool-mcp <env>` in
# @description      each agent CLI that is installed (claude at user scope,
# @description      grok at user scope, agy), added only when missing
# @description What the agent user can reach afterwards: the five tools for
# @description ITS OWN seat, over stdio. It cannot read the desk tree or the box
# @description key (both stay 0700 box user); the one sudo hop happens at server
# @description start and names the id with --as, and the server refuses any
# @description other from/as with exit 78. A server with no id refuses to start.
# @description A running CLI loads a new server only after a restart.
# @description Dry run unless DRY_RUN=0.
# @param AGENT_USER - required: the OS user the agent CLIs run as (no default)
# @param MCP_ENVS (optional) - default "dev prd"
# @param MCP_CLIS (optional) - default "claude grok agy"; a CLI that is not at
# @param   <agent home>/.local/bin/<cli> (where their installers put them) is
# @param   skipped and named
# @param DRY_RUN (optional) - 1 (default) or 0
# @example AGENT_USER=<agent user> DRY_RUN=0 ./run -a do_spl_agent_mcp_install
#------------------------------------------------------------------------------
do_spl_agent_mcp_install() {
  do_require_bin python3 getent sudo install || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local agent="${AGENT_USER:-}" envs="${MCP_ENVS:-dev prd}" clis="${MCP_CLIS:-claude grok agy}"
  [[ "$agent" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL AGENT_USER must name the agent OS user (no default), got: '$agent'"; return 1; }
  local e c
  for e in $envs; do [[ "$e" =~ ^(dev|prd)$ ]] || { do_log "FATAL MCP_ENVS may hold dev and prd only, got: '$e'"; return 1; }; done
  for c in $clis; do [[ "$c" =~ ^(claude|grok|agy)$ ]] || { do_log "FATAL MCP_CLIS may hold claude, grok and agy only, got: '$c'"; return 1; }; done

  local proj_base org_app me ahome mcpdir src build
  proj_base="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"
  [[ "$proj_base" =~ ^([a-z]+)-([a-z]+)-orc$ ]] || { do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  me="$(id -un)"
  ahome="${SPL_AGENT_MCP_HOME:-$(getent passwd "$agent" | cut -d: -f6)}"
  [[ -n "$ahome" && -d "$ahome" ]] || { do_log "FATAL no home for AGENT_USER '$agent'"; return 1; }
  mcpdir="${SPL_AGENT_MCP_DIR:-$HOME/.local/share/$org_app/mcp}"
  src="$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-mcp.sh"
  build="${SPL_AGENT_MCP_BUILD:-$APP_PATH/$org_app-api/src/bash/build.sh}"
  [[ -r "$src" ]] || { do_log "FATAL missing $src"; return 1; }
  as_agent() { if [[ "$agent" == "$me" ]]; then "$@"; else sudo -n -u "$agent" -H "$@"; fi; }

  if (( dry )); then
    do_log "INFO DRY_RUN would: build spool from $APP_PATH into $mcpdir/spool and install $mcpdir/spool-mcp.sh (box user $me)"
    do_log "INFO DRY_RUN would: install $ahome/.local/bin/spool-mcp and $ahome/.config/spool-mcp/env as $agent"
    do_log "INFO DRY_RUN would: register spool-{$envs} in: $clis (where installed and missing)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to install."
    return 0
  fi

  # 1. box side
  mkdir -p "$mcpdir" && chmod 700 "$mcpdir" || { do_log "FATAL cannot create $mcpdir"; return 1; }
  local out
  out="$(bash "$build" "$mcpdir/spool.new" 2>&1)" || { rm -f "$mcpdir/spool.new"; do_log "FATAL spool build failed: $out"; return 1; }
  mv -f "$mcpdir/spool.new" "$mcpdir/spool" || return 1
  # An older binary ignores --as and serves (then exits 0 on EOF): refuse it.
  SPOOL_ROOT="$mcpdir/.probe" "$mcpdir/spool" mcp --as 'not an id' </dev/null >/dev/null 2>&1 &&
    { do_log "FATAL $mcpdir/spool accepts an invalid --as: it is older than the seated server"; return 1; }
  install -m 0755 "$src" "$mcpdir/spool-mcp.sh.new" && mv -f "$mcpdir/spool-mcp.sh.new" "$mcpdir/spool-mcp.sh" || return 1
  do_log "INFO box side: $mcpdir/spool-mcp.sh + $mcpdir/spool ($out)"

  # 2. agent side. The content goes through stdin: the agent user cannot read
  # the box user's checkout or state.
  local bin="$ahome/.local/bin/spool-mcp" conf="$ahome/.config/spool-mcp/env" ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  as_agent bash -c 'set -e; mkdir -p "$(dirname "$1")" "$(dirname "$2")"
    cat >"$1.new"; chmod 755 "$1.new"
    if [ -e "$1" ] && ! cmp -s "$1" "$1.new"; then cp -p "$1" "$1.bak-$3"; fi
    mv -f "$1.new" "$1"
    printf "SPOOL_MCP_BOX_USER=%s\nSPOOL_MCP_SERVE=%s\n" "$4" "$5" >"$2.new"; mv -f "$2.new" "$2"' \
    _ "$bin" "$conf" "$ts" "$me" "$mcpdir/spool-mcp.sh" <"$src" ||
    { do_log "FATAL cannot install $bin as $agent"; return 1; }
  do_log "INFO agent side: $bin, $conf"

  # 3. registrations
  local rc=0 have
  for c in $clis; do
    local cli="$ahome/.local/bin/$c"
    [[ -x "$cli" ]] || { do_log "INFO $c is not installed for $agent ($cli): skipped"; continue; }
    for e in $envs; do
      have="$(spl_agent_mcp_registered "$c" "$cli" "$ahome" "spool-$e" "$bin" "$e")"
      if [[ "$have" == yes ]]; then do_log "INFO $c: spool-$e already runs $bin $e"; continue; fi
      case "$c" in
        claude) as_agent "$cli" mcp add -s user "spool-$e" -- "$bin" "$e" >/dev/null 2>&1 ;;
        grok)   as_agent "$cli" mcp add -s user "spool-$e" "$bin" -- "$e" >/dev/null 2>&1 ;;
        agy)    as_agent "$cli" mcp add "spool-$e" "$bin" "$e" >/dev/null 2>&1 ;;
      esac || { do_log "FAIL $c: could not register spool-$e"; rc=1; continue; }
      [[ "$(spl_agent_mcp_registered "$c" "$cli" "$ahome" "spool-$e" "$bin" "$e")" == yes ]] &&
        do_log "INFO $c: registered spool-$e -> $bin $e" || { do_log "FAIL $c: spool-$e is still not registered"; rc=1; }
    done
  done
  (( rc == 0 )) || return 1
  do_log "OK spool-{${envs// /,}} installed for $agent; a running CLI sees them after a restart"
}

# spl_agent_mcp_registered <cli> <cli path> <agent home> <name> <bin> <env>:
# prints yes when the CLI already runs <bin> <env> as <name>. claude is read
# from ~/.claude.json (its `mcp list` starts every server to health-check it);
# grok and agy print their config. as_agent is the caller's.
spl_agent_mcp_registered() {
  local c="$1" cli="$2" ahome="$3" name="$4" bin="$5" e="$6"
  case "$c" in
    claude)
      as_agent python3 - "$ahome/.claude.json" "$name" "$bin" "$e" 2>/dev/null <<'EOF_PY'
import json, sys
p, name, b, e = sys.argv[1:]
try:
    s = json.load(open(p)).get("mcpServers", {}).get(name, {})
except (OSError, ValueError):
    s = {}
print("yes" if s.get("command") == b and s.get("args") == [e] else "no")
EOF_PY
      ;;
    grok|agy)
      as_agent "$cli" mcp list 2>/dev/null |
        grep -qE "(^|[[:space:]])$name(:|[[:space:]]).*$bin $e([[:space:]]|$)" && echo yes || echo no
      ;;
  esac
}
