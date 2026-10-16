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
# @description      grok at user scope, agy, qwen at user scope and trusted,
# @description      mistral vibe as a [[mcp_servers]] stdio entry in
# @description      <agent home>/.vibe/config.toml), added only when missing
# @description   4. SEATED ENVS (MCP_SEAT_ENVS, default dev; SPL-2106): a
# @description      registration is per OS user, not per agent, and lanes are
# @description      seated in prd only, so a user-scope spool-dev failed to
# @description      start ("<ID> has 0 seats ... in dev") in every lane. For
# @description      such an env the user-scope entry is removed from every CLI
# @description      and claude gets spool-<env> at LOCAL scope (its project =
# @description      the agent's cwd) for each LIVE claude agent of AGENT_USER
# @description      that holds exactly one seat in that env on this desk box
# @description      (<box state>/cloud/<env>/desk/*/<box>/spool/<ID>, the
# @description      lookup spool-mcp makes); an unseated agent's local entry
# @description      is removed. A seated agent of another CLI is named: those
# @description      CLIs have no per-agent scope. Seats change and nothing
# @description      re-runs this by itself: after seating an agent in such an
# @description      env (do_spl_desk_up), RE-RUN this action and it adds
# @description      spool-<env> back for that agent (then restart its CLI).
# @description What the agent user can reach afterwards: the five tools for
# @description ITS OWN seat, over stdio. It cannot read the desk tree or the box
# @description key (both stay 0700 box user); the one sudo hop happens at server
# @description start and names the id with --as, and the server refuses any
# @description other from/as with exit 78. A server with no id refuses to start.
# @description A running CLI loads a new server only after a restart.
# @description Dry run unless DRY_RUN=0.
# @param AGENT_USER - required: the OS user the agent CLIs run as (no default)
# @param MCP_ENVS (optional) - default "dev prd"
# @param MCP_CLIS (optional) - default "claude grok agy qwen mistral"; a CLI that is
# @param   not at <agent home>/.local/bin/<cli> (where their installers put them;
# @param   mistral's binary is vibe) is skipped and named
# @param MCP_SEAT_ENVS (optional) - default "dev": the envs of MCP_ENVS registered
# @param   per agent, only where it holds a seat (4. above); "" = all user scope
# @param SPL_AGENT_MCP_LIVE (optional) - tests: a file of "<cli> <id> <cwd>" lines
# @param   in place of the live agent processes of AGENT_USER
# @param SPL_AGENT_MCP_STATE_ROOT (optional) - tests: the box state cloud/ dir
# @param DRY_RUN (optional) - 1 (default) or 0
# @example AGENT_USER=<agent user> DRY_RUN=0 ./run -a do_spl_agent_mcp_install
#------------------------------------------------------------------------------
do_spl_agent_mcp_install() {
  do_require_bin python3 getent sudo install || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local agent="${AGENT_USER:-}" envs="${MCP_ENVS:-dev prd}" clis="${MCP_CLIS:-claude grok agy qwen mistral}" seatenvs="${MCP_SEAT_ENVS-dev}"
  [[ "$agent" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL AGENT_USER must name the agent OS user (no default), got: '$agent'"; return 1; }
  local e c
  for e in $envs; do [[ "$e" =~ ^(dev|prd)$ ]] || { do_log "FATAL MCP_ENVS may hold dev and prd only, got: '$e'"; return 1; }; done
  for e in $seatenvs; do [[ "$e" =~ ^(dev|prd)$ ]] || { do_log "FATAL MCP_SEAT_ENVS may hold dev and prd only, got: '$e'"; return 1; }; done
  for c in $clis; do [[ "$c" =~ ^(claude|grok|agy|qwen|mistral)$ ]] || { do_log "FATAL MCP_CLIS may hold claude, grok, agy, qwen and mistral only, got: '$c'"; return 1; }; done

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
  # 4. the seat lookup of spool-mcp: <box state>/cloud/<env>/desk/*/<box>/spool/<ID>
  local stateroot="${SPL_AGENT_MCP_STATE_ROOT:-$(dirname "$mcpdir")/cloud}" deskbox="${SPOOL_DESK_BOX:-}" bin="$ahome/.local/bin/spool-mcp"
  [[ -n "$deskbox" ]] || deskbox="$(sed -n "s/^SPOOL_DESK_BOX=[\"']\{0,1\}\([a-z0-9-]*\).*/\1/p" "${SPOOL_BOX_ENV:-/var/spool-hub/box.env}" 2>/dev/null | tail -1)"
  deskbox="${deskbox:-box-desk}"

  if (( dry )); then
    do_log "INFO DRY_RUN would: build spool from $APP_PATH into $mcpdir/spool and install $mcpdir/spool-mcp.sh (box user $me)"
    do_log "INFO DRY_RUN would: install $ahome/.local/bin/spool-mcp and $ahome/.config/spool-mcp/env as $agent"
    do_log "INFO DRY_RUN would: register spool-{$envs} in: $clis (where installed and missing; per seated agent for: ${seatenvs:-none})"
    for e in $seatenvs; do spl_agent_mcp_seat_env "$e"; done
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to install."
    return 0
  fi

  # 1. box side
  spl_agent_mcp_box_side "$mcpdir" "$build" "$src" || return 1

  # 2. agent side. The content goes through stdin: the agent user cannot read
  # the box user's checkout or state.
  local conf="$ahome/.config/spool-mcp/env" ts
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
    [[ "$c" == mistral ]] && cli="$ahome/.local/bin/vibe"
    # asked AS the agent: its CLIs are often links into dirs the box user cannot read
    as_agent test -x "$cli" || { do_log "INFO $c is not installed for $agent ($cli): skipped"; continue; }
    for e in $envs; do
      [[ " $seatenvs " == *" $e "* ]] && continue
      have="$(spl_agent_mcp_registered "$c" "$cli" "$ahome" "spool-$e" "$bin" "$e")"
      if [[ "$have" == yes ]]; then do_log "INFO $c: spool-$e already runs $bin $e"; continue; fi
      case "$c" in
        claude) as_agent "$cli" mcp add -s user "spool-$e" -- "$bin" "$e" >/dev/null 2>&1 ;;
        grok)   as_agent "$cli" mcp add -s user "spool-$e" "$bin" -- "$e" >/dev/null 2>&1 ;;
        agy)    as_agent "$cli" mcp add "spool-$e" "$bin" "$e" >/dev/null 2>&1 ;;
        qwen)   as_agent "$cli" mcp add -s user --trust --description "spool desk ($e)" "spool-$e" "$bin" "$e" >/dev/null 2>&1 ;;
        mistral) spl_agent_mcp_vibe add "$ahome/.vibe/config.toml" "spool-$e" "$bin" "$e" >/dev/null 2>&1 ;;
      esac || { do_log "FAIL $c: could not register spool-$e"; rc=1; continue; }
      [[ "$(spl_agent_mcp_registered "$c" "$cli" "$ahome" "spool-$e" "$bin" "$e")" == yes ]] &&
        do_log "INFO $c: registered spool-$e -> $bin $e" || { do_log "FAIL $c: spool-$e is still not registered"; rc=1; }
    done
  done
  for e in $seatenvs; do spl_agent_mcp_seat_env "$e" || rc=1; done
  (( rc == 0 )) || return 1
  do_log "OK spool-{${envs// /,}} installed for $agent; a running CLI sees them after a restart"
}

# spl_agent_mcp_box_side <mcp dir> <build.sh> <spool-mcp.sh>: as the box user,
# build the spool binary into <mcp dir>, refuse one older than the seated
# server, and install the box half of spool-mcp next to it.
spl_agent_mcp_box_side() {
  local mcpdir="$1" build="$2" src="$3" out
  mkdir -p "$mcpdir" && chmod 700 "$mcpdir" || { do_log "FATAL cannot create $mcpdir"; return 1; }
  out="$(bash "$build" "$mcpdir/spool.new" 2>&1)" || { rm -f "$mcpdir/spool.new"; do_log "FATAL spool build failed: $out"; return 1; }
  mv -f "$mcpdir/spool.new" "$mcpdir/spool" || return 1
  # An older binary ignores --as and serves (then exits 0 on EOF): refuse it.
  SPOOL_ROOT="$mcpdir/.probe" "$mcpdir/spool" mcp --as 'not an id' </dev/null >/dev/null 2>&1 &&
    { do_log "FATAL $mcpdir/spool accepts an invalid --as: it is older than the seated server"; return 1; }
  install -m 0755 "$src" "$mcpdir/spool-mcp.sh.new" && mv -f "$mcpdir/spool-mcp.sh.new" "$mcpdir/spool-mcp.sh" || return 1
  do_log "INFO box side: $mcpdir/spool-mcp.sh + $mcpdir/spool ($out)"
}

# spl_agent_mcp_seat_env <env> (SPL-2106): spool-<env> only for an agent that
# holds a seat in <env>. Removes the user-scope entry from every installed CLI,
# then per live agent of AGENT_USER: claude gets (seated) or loses (unseated)
# spool-<env> at local scope in its cwd. Reads the caller's locals (agent,
# ahome, bin, clis, dry, stateroot, deskbox); with dry set it only logs.
spl_agent_mcp_seat_env() {
  local e="$1" name="spool-$1" c cli id cwd rc=0 nseat=0 nunseat=0
  for c in $clis; do
    cli="$ahome/.local/bin/$c"; [[ "$c" == mistral ]] && cli="$ahome/.local/bin/vibe"
    as_agent test -x "$cli" || continue
    [[ "$(spl_agent_mcp_has "$c" "$cli" "$ahome" "$name")" == yes ]] || continue
    if (( dry )); then do_log "INFO DRY_RUN would: remove the user-scope $name from $c (seated per agent)"; continue; fi
    case "$c" in
      claude|grok|qwen) as_agent "$cli" mcp remove -s user "$name" >/dev/null 2>&1 ;;
      agy) as_agent "$cli" mcp remove "$name" >/dev/null 2>&1 ;;
      mistral) spl_agent_mcp_vibe remove "$ahome/.vibe/config.toml" "$name" "" "" >/dev/null 2>&1 ;;
    esac && [[ "$(spl_agent_mcp_has "$c" "$cli" "$ahome" "$name")" == no ]] &&
      do_log "INFO $c: removed the user-scope $name (it is registered per seated agent)" ||
      { do_log "FAIL $c: could not remove the user-scope $name"; rc=1; }
  done
  cli="$ahome/.local/bin/claude"
  while read -r c id cwd; do
    [[ -n "$cwd" ]] || continue
    local seats=("$stateroot/$e/desk/"*"/$deskbox/spool/$id") have
    [[ -d "${seats[0]}" ]] || seats=()
    if [[ "$c" != claude ]]; then
      (( ${#seats[@]} == 1 )) && do_log "INFO $id ($c) has a seat in $e but $c has no per-agent scope: no $name for it"
      continue
    fi
    have="$(spl_agent_mcp_local "$ahome" "$cwd" "$name" "$bin" "$e")"
    if (( ${#seats[@]} == 1 )); then
      nseat=$((nseat + 1))
      [[ "$have" == yes ]] && { do_log "INFO claude $id: $name already registered in $cwd"; continue; }
      if (( dry )); then do_log "INFO DRY_RUN would: register $name for $id (seated) in $cwd"; continue; fi
      as_agent bash -c 'cd "$1" && shift && exec "$@"' _ "$cwd" "$cli" mcp add -s local "$name" -- "$bin" "$e" >/dev/null 2>&1
      [[ "$(spl_agent_mcp_local "$ahome" "$cwd" "$name" "$bin" "$e")" == yes ]] &&
        do_log "INFO claude $id: registered $name in $cwd (seated in $e)" || { do_log "FAIL claude $id: $name is still not registered in $cwd"; rc=1; }
    else
      nunseat=$((nunseat + 1))
      [[ "$have" == no ]] && continue
      if (( dry )); then do_log "INFO DRY_RUN would: remove $name of $id (${#seats[@]} seats in $e) in $cwd"; continue; fi
      as_agent bash -c 'cd "$1" && shift && exec "$@"' _ "$cwd" "$cli" mcp remove -s local "$name" >/dev/null 2>&1
      [[ "$(spl_agent_mcp_local "$ahome" "$cwd" "$name" "" "")" == no ]] &&
        do_log "INFO claude $id: removed $name in $cwd (${#seats[@]} seats in $e)" || { do_log "FAIL claude $id: $name is still in $cwd"; rc=1; }
    fi
  done < <(spl_agent_mcp_live)
  do_log "INFO $name: $nseat live claude agent(s) of $agent seated in $e on $deskbox, $nunseat not (no $name for them)"
  return "$rc"
}

# spl_agent_mcp_live: "<cli> <id> <cwd>" per live agent CLI process of the
# agent user (SPL_AGENT_MCP_LIVE: a fixture file instead). Read as the agent:
# /proc/<pid>/environ is its own. The id is SPOOL_AGENT_ID or MCP_BOT_AGENT_ID.
spl_agent_mcp_live() {
  if [[ -n "${SPL_AGENT_MCP_LIVE:-}" ]]; then cat "$SPL_AGENT_MCP_LIVE"; return; fi
  as_agent python3 - 2>/dev/null <<'EOF_PY'
import os, re
ID = re.compile(r"^([acgmq]-[0-9]{3}|[A-Z]{2,4}-[0-9]+)$")
CLI = {"claude": "claude", "grok": "grok", "agy": "agy", "qwen": "qwen", "vibe": "mistral"}
me = os.getuid()
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        if os.stat("/proc/" + pid).st_uid != me:
            continue
        argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
        names = [os.path.basename(a.decode(errors="replace")) for a in argv[:2]]
        cli = CLI.get(names[0]) or (CLI.get(names[1]) if len(names) > 1 and names[1] == "vibe" else None)
        if not cli:
            continue
        env = dict(kv.split(b"=", 1) for kv in open("/proc/%s/environ" % pid, "rb").read().split(b"\0") if b"=" in kv)
        aid = (env.get(b"SPOOL_AGENT_ID") or env.get(b"MCP_BOT_AGENT_ID") or b"").decode()
        if ID.match(aid):
            print(cli, aid, os.readlink("/proc/%s/cwd" % pid))
    except (OSError, ValueError):
        continue
EOF_PY
}

# spl_agent_mcp_has <cli> <cli path> <agent home> <name>: yes when the CLI has
# a user-scope server <name>, whatever it runs. as_agent is the caller's.
spl_agent_mcp_has() {
  local c="$1" cli="$2" ahome="$3" name="$4"
  case "$c" in
    mistral) spl_agent_mcp_vibe has "$ahome/.vibe/config.toml" "$name" "" "" ;;
    claude|qwen)
      local conf="$ahome/.claude.json"; [[ "$c" == qwen ]] && conf="$ahome/.qwen/settings.json"
      as_agent python3 -c 'import json, sys
try: s = json.load(open(sys.argv[1])).get("mcpServers", {})
except (OSError, ValueError): s = {}
print("yes" if sys.argv[2] in s else "no")' "$conf" "$name" 2>/dev/null ;;
    grok|agy)
      as_agent "$cli" mcp list 2>/dev/null | grep -E "(^|[[:space:]])$name(:|[[:space:]])" >/dev/null && echo yes || echo no ;;
  esac
}

# spl_agent_mcp_local <agent home> <cwd> <name> <bin> <env>: yes when claude's
# local scope of project <cwd> (~/.claude.json projects.<cwd>.mcpServers) runs
# <bin> <env> as <name>; with an empty <bin>, when it holds <name> at all.
spl_agent_mcp_local() {
  as_agent python3 -c 'import json, sys
p, cwd, name, b, e = sys.argv[1:]
try: s = json.load(open(p)).get("projects", {}).get(cwd, {}).get("mcpServers", {})
except (OSError, ValueError): s = {}
ok = name in s if not b else (s.get(name, {}).get("command") == b and s.get(name, {}).get("args") == [e])
print("yes" if ok else "no")' "$1/.claude.json" "$2" "$3" "$4" "$5" 2>/dev/null
}

# spl_agent_mcp_registered <cli> <cli path> <agent home> <name> <bin> <env>:
# prints yes when the CLI already runs <bin> <env> as <name>. claude is read
# from ~/.claude.json and qwen from ~/.qwen/settings.json (their `mcp list`
# starts every server to health-check it), mistral from ~/.vibe/config.toml
# (vibe has no `mcp add`); grok and agy print their config. as_agent is the
# caller's.
spl_agent_mcp_registered() {
  local c="$1" cli="$2" ahome="$3" name="$4" bin="$5" e="$6"
  local conf="$ahome/.claude.json"
  [[ "$c" == qwen ]] && conf="$ahome/.qwen/settings.json"
  case "$c" in
    mistral) spl_agent_mcp_vibe check "$ahome/.vibe/config.toml" "$name" "$bin" "$e" ;;
    claude|qwen)
      as_agent python3 - "$conf" "$name" "$bin" "$e" 2>/dev/null <<'EOF_PY'
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
        grep -E "(^|[[:space:]])$name(:|[[:space:]]).*$bin $e([[:space:]]|$)" >/dev/null && echo yes || echo no
      ;;
  esac
}

# spl_agent_mcp_vibe check|has|add|remove <config.toml> <name> <bin> <env>, as the agent
# (as_agent is the caller's). mistral vibe 2.26.0 reads stdio MCP servers from
# [[mcp_servers]] tables (name, transport, command, args) and starts each with
# a SAFE env only (HOME, PATH, ... plus the entry's own literal env), so the
# agent id a launcher exports never reaches spool-mcp. The entry therefore
# runs /bin/sh, which reads SPOOL_AGENT_ID / MCP_BOT_AGENT_ID from its parent
# (the vibe process, same user) and execs <bin> <env>; spool-mcp still refuses
# an id that has no seat. check prints yes when exactly that entry is there;
# has prints yes when any table of that name is there; add replaces any other
# [[mcp_servers]] table of that name (remove drops them all), keeps the rest of
# the file, and writes it 0600 (vibe's own mode).
spl_agent_mcp_vibe() {
  as_agent python3 - "$@" 2>/dev/null <<'EOF_PY'
import json, os, re, sys
mode, path, name, b, e = sys.argv[1:]
shim = ("id=$(tr '\\0' '\\n' 2>/dev/null </proc/$PPID/environ"
        " | sed -n 's/^SPOOL_AGENT_ID=//p;s/^MCP_BOT_AGENT_ID=//p' | head -n 1);"
        ' [ -n "$id" ] && export MCP_BOT_AGENT_ID="$id"; exec "$1" "$2"')
want = {"name": name, "transport": "stdio", "command": "/bin/sh", "args": ["-c", shim, "spool-mcp", b, e]}
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
try:
    import tomllib
    have = [s for s in tomllib.loads(text).get("mcp_servers", []) if isinstance(s, dict) and s.get("name") == name]
except ImportError:
    have = None
if mode == "has":
    print("yes" if have else "no")
    sys.exit(0)
if mode == "check":
    ok = have is not None and len(have) == 1 and all(have[0].get(k) == v for k, v in want.items())
    print("yes" if ok else "no")
    sys.exit(0)
blocks = re.split(r"(?m)^(?=\[)", text)
keep = [x for x in blocks if not (x.startswith("[[mcp_servers]]")
                                  and re.search(r"(?m)^name\s*=\s*" + re.escape(json.dumps(name)) + r"\s*$", x))]
text = "".join(keep).rstrip("\n")
entry = "[[mcp_servers]]\n" + "".join("%s = %s\n" % (k, json.dumps(v)) for k, v in want.items())
if mode == "add":
    text = (text + "\n\n" if text else "") + entry
else:
    text += "\n"
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
tmp = path + ".tmp.%d" % os.getpid()
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(text)
os.replace(tmp, path)
EOF_PY
}
