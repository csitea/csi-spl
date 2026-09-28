#!/usr/bin/env bash
# spool-mcp.sh + do_spl_agent_mcp_install, hermetic: a fake desk tree, a fake
# hub-run sidecar (a process whose argv reads `spool hub-run`) and a fake spool
# binary that records its argv and environment instead of serving.
#
# What must hold:
#   - the server never starts unseated: no id / a bad id refuse (exit 4), on
#     both halves, and the fake binary is never run
#   - an unseated desk (5) and a dead sidecar (6) refuse
#   - a seated start runs `spool mcp --as <ID>` with ONLY the sidecar's
#     spool settings (not its notify hook, not the caller's env)
#   - the install writes both halves, backs up a replaced agent script,
#     registers each CLI once, and refuses a binary that ignores --as
# CONTROL: a box half that dropped --as would serve unseated; the argv check
# below is what catches it, so it is asserted on the recorded argv itself.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
SH="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spool-mcp.sh"
T="$(mktemp -d)"; SIDE=""
trap '[ -n "$SIDE" ] && kill "$SIDE" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ME="$(id -un)"

# ── fixture: <T>/share/mcp holds the box half, <T>/share/cloud/dev the desk ──
MCP="$T/share/mcp"; D="$T/share/cloud/dev/desk/t1/box-desk"
mkdir -p "$MCP" "$D/spool/CLE-07/inbox" "$D/spool/.hub" "$D/keys"
cp "$SH" "$MCP/spool-mcp.sh"
cat >"$MCP/spool" <<EOF
#!/usr/bin/env bash
{ printf 'ARGV %s\n' "\$*"; env | grep -E '^(SPOOL_|LEAK)' | sort; } >"$T/served"
EOF
chmod +x "$MCP/spool" "$MCP/spool-mcp.sh"
box() { env LEAK=caller "$MCP/spool-mcp.sh" --serve "$@" >"$T/out" 2>&1 </dev/null; }

# ── 1. the box half refuses to start unseated ───────────────────────────────
for bad in "" "not-an-id" "BOX-1" "cle-07"; do
  rm -f "$T/served"
  if [ -z "$bad" ]; then box dev; else box --as "$bad" dev; fi; rc=$?
  [[ $rc -eq 4 && ! -e "$T/served" ]] && pass "1. --as '$bad' refuses (4), nothing served" ||
    fail "1. --as '$bad': rc $rc served=$([ -e "$T/served" ] && echo yes) $(cat "$T/out")"
done

# ── 2. no seat / no sidecar ─────────────────────────────────────────────────
box --as CLE-08 dev; rc=$?
[[ $rc -eq 5 ]] && grep -q 'CLE-08 has 0 seats' "$T/out" && pass "2. an unseated id refuses (5)" || fail "2. unseated: rc $rc $(cat "$T/out")"
box --as CLE-07 dev; rc=$?
[[ $rc -eq 6 && ! -e "$T/served" ]] && pass "2. no sidecar pid refuses (6)" || fail "2. no sidecar: rc $rc $(cat "$T/out")"
echo 1 >"$D/spool/.hub/hub-run.pid"   # pid 1 is alive but is not a hub-run
box --as CLE-07 dev; rc=$?
[[ $rc -eq 6 ]] && pass "2. a live pid that is not hub-run refuses (6)" || fail "2. foreign pid: rc $rc $(cat "$T/out")"

# ── 3. seated: the sidecar's spool settings, and --as ───────────────────────
env -i PATH=/usr/bin:/bin SPOOL_ROOT="$D/spool" SPOOL_KEYS_DIR="$D/keys" SPOOL_BOX_ID=box-desk \
  SPOOL_HUB_URL=https://hub.example.net SPOOL_TENANT=t1 SPOOL_NOTIFY_CMD=/bin/true SPOOL_POKE=1 \
  bash -c 'exec -a "spool hub-run" sleep 60' &
SIDE=$!
echo "$SIDE" >"$D/spool/.hub/hub-run.pid"
for _ in $(seq 50); do tr '\0' ' ' <"/proc/$SIDE/cmdline" 2>/dev/null | grep -q ' hub-run' && break; sleep 0.1; done
box --as CLE-07 dev; rc=$?
if [[ $rc -eq 0 && -s "$T/served" ]]; then
  grep -qx 'ARGV mcp --as CLE-07' "$T/served" && pass "3. runs spool mcp --as CLE-07" || fail "3. argv: $(head -1 "$T/served")"
  want="SPOOL_BOX_ID=box-desk SPOOL_HUB_URL=https://hub.example.net SPOOL_KEYS_DIR=$D/keys SPOOL_LOG_LEVEL=error SPOOL_ROOT=$D/spool SPOOL_TENANT=t1"
  got="$(grep -v '^ARGV' "$T/served" | tr '\n' ' ' | sed 's/ $//')"
  [[ "$got" == "$want" ]] && pass "3. only the sidecar's spool settings (no notify hook, no caller env)" ||
    fail "3. env:\n got  $got\n want $want"
else
  fail "3. seated start: rc $rc $(cat "$T/out")"
fi
box --as CLE-07 dev t1 box-desk; rc=$?
[[ $rc -eq 0 ]] && pass "3. an explicit tenant + box works" || fail "3. explicit: rc $rc $(cat "$T/out")"

# ── 4. the agent half: config, id resolution, the hop ───────────────────────
CONF="$T/agent.env"
agent() { env -u MCP_BOT_AGENT_ID -u SPOOL_AGENT_ID -u TMUX_PANE -u CLE_TMUX_PANE SPOOL_MCP_CONF="$CONF" "$@" >"$T/out" 2>&1 </dev/null; }
rm -f "$T/served"
agent MCP_BOT_AGENT_ID=CLE-07 "$SH" dev; rc=$?
[[ $rc -eq 3 && ! -e "$T/served" ]] && pass "4. no config refuses (3)" || fail "4. no config: rc $rc $(cat "$T/out")"
printf 'SPOOL_MCP_BOX_USER=%s\nSPOOL_MCP_SERVE=%s\n' "$ME" "$MCP/spool-mcp.sh" >"$CONF"
agent "$SH" dev; rc=$?
[[ $rc -eq 4 && ! -e "$T/served" ]] && grep -q 'refusing to start unseated' "$T/out" && pass "4. no agent id refuses (4)" || fail "4. no id: rc $rc $(cat "$T/out")"
agent MCP_BOT_AGENT_ID=CLE-07 "$SH" dev; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'ARGV mcp --as CLE-07' "$T/served" && pass "4. MCP_BOT_AGENT_ID seats the server" || fail "4. env id: rc $rc $(cat "$T/out")"
rm -f "$T/served"
agent SPOOL_AGENT_ID=CLE-07 "$SH" dev; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'ARGV mcp --as CLE-07' "$T/served" && pass "4. SPOOL_AGENT_ID seats the server" || fail "4. spool id: rc $rc $(cat "$T/out")"
rm -f "$T/served"
agent MCP_BOT_AGENT_ID=CLE-08 "$SH" dev; rc=$?
[[ $rc -eq 5 && ! -e "$T/served" ]] && pass "4. another agent's id finds no seat of its own (5)" || fail "4. other id: rc $rc $(cat "$T/out")"

# ── 5. the install action ───────────────────────────────────────────────────
AH="$T/agent-home"; mkdir -p "$AH/.local/bin"
printf '#!/bin/sh\necho old\n' >"$AH/.local/bin/spool-mcp"; chmod +x "$AH/.local/bin/spool-mcp"
cat >"$AH/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
# fake claude: `mcp add -s user <name> -- <cmd> <args...>` into ~/.claude.json
[ "$1 $2" = "mcp add" ] || exit 2
echo "claude $*" >>"$FAKE_LOG"
name="$5"; shift 6
python3 - "$FAKE_HOME/.claude.json" "$name" "$@" <<'PY'
import json, os, sys
p, name, cmd, *args = sys.argv[1:]
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("mcpServers", {})[name] = {"type": "stdio", "command": cmd, "args": args, "env": {}}
json.dump(d, open(p, "w"))
PY
EOF
cat >"$AH/.local/bin/grok" <<'EOF'
#!/usr/bin/env bash
# fake grok: `mcp list` prints what `mcp add -s user <name> <cmd> -- <arg>` stored
case "$1 $2" in
  "mcp list") cat "$FAKE_HOME/grok.list" 2>/dev/null ;;
  "mcp add")  echo "grok $*" >>"$FAKE_LOG"; echo "  $5: $6 $8" >>"$FAKE_HOME/grok.list" ;;
  *) exit 2 ;;
esac
EOF
cat >"$AH/.local/bin/qwen" <<'EOF'
#!/usr/bin/env bash
# fake qwen: `mcp add -s user --trust --description <d> <name> <cmd> <args...>` into ~/.qwen/settings.json
[ "$1 $2" = "mcp add" ] || exit 2
echo "qwen $*" >>"$FAKE_LOG"
shift 7; name="$1"; shift
mkdir -p "$FAKE_HOME/.qwen"
python3 - "$FAKE_HOME/.qwen/settings.json" "$name" "$@" <<'PY'
import json, os, sys
p, name, cmd, *args = sys.argv[1:]
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("mcpServers", {})[name] = {"command": cmd, "args": args, "trust": True}
json.dump(d, open(p, "w"))
PY
EOF
chmod +x "$AH/.local/bin/claude" "$AH/.local/bin/grok" "$AH/.local/bin/qwen"
cat >"$T/build.sh" <<'EOF'
#!/usr/bin/env bash
# fake build: a spool that refuses a bad --as, or with OLD_SPOOL one that ignores it
if [ -n "${OLD_SPOOL:-}" ]; then printf '#!/bin/sh\nexit 0\n' >"$1"
else printf '#!/bin/sh\n[ "$1 $2" = "mcp --as" ] && exit 1\nexit 0\n' >"$1"; fi
chmod +x "$1"; echo "built $1"
EOF
chmod +x "$T/build.sh"
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_AGENT_MCP_DIR="$T/inst/mcp" SPL_AGENT_MCP_HOME="$AH" \
    SPL_AGENT_MCP_BUILD="$T/build.sh" FAKE_HOME="$AH" FAKE_LOG="$T/cli.log" PATH="$AH/.local/bin:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_agent_mcp_install' >"$T/out" 2>&1
}
in_orc AGENT_USER="$ME" MCP_CLIS="claude grok"; rc=$?
[[ $rc -eq 0 && ! -e "$T/inst" && ! -e "$T/cli.log" ]] && grep -q 'OK DRY_RUN nothing was touched' "$T/out" &&
  grep -qx 'old' <("$AH/.local/bin/spool-mcp") && pass "5. the dry run touches nothing" || fail "5. dry run: rc $rc $(cat "$T/out")"
for bad in "AGENT_USER=" "AGENT_USER=Bad!User" "MCP_ENVS=stg" "MCP_CLIS=codex"; do
  in_orc AGENT_USER="$ME" DRY_RUN=0 $bad; rc=$?
  [[ $rc -ne 0 && ! -e "$T/inst" ]] && pass "5. '$bad' is refused" || fail "5. '$bad' accepted: $(cat "$T/out")"
done
in_orc AGENT_USER="$ME" MCP_CLIS="claude grok" OLD_SPOOL=1 DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'accepts an invalid --as' "$T/out" && [[ ! -e "$AH/.config/spool-mcp/env" ]] &&
  pass "5. a binary that ignores --as is refused before the agent side" || fail "5. old binary: rc $rc $(cat "$T/out")"
in_orc AGENT_USER="$ME" MCP_CLIS="claude grok qwen" DRY_RUN=0; rc=$?
if [[ $rc -eq 0 ]]; then
  cmp -s "$SH" "$T/inst/mcp/spool-mcp.sh" && cmp -s "$SH" "$AH/.local/bin/spool-mcp" && [[ -x "$AH/.local/bin/spool-mcp" ]] &&
    pass "5. both halves are this checkout's spool-mcp.sh" || fail "5. halves differ from $SH"
  ls "$AH/.local/bin/"spool-mcp.bak-* >/dev/null 2>&1 && pass "5. the replaced agent script is kept as .bak-<ts>" || fail "5. no backup"
  grep -qx "SPOOL_MCP_BOX_USER=$ME" "$AH/.config/spool-mcp/env" && grep -qx "SPOOL_MCP_SERVE=$T/inst/mcp/spool-mcp.sh" "$AH/.config/spool-mcp/env" &&
    pass "5. the agent config names the box user and the box half" || fail "5. conf: $(cat "$AH/.config/spool-mcp/env")"
  [[ "$(grep -c '^claude mcp add' "$T/cli.log")" == 2 && "$(grep -c '^grok mcp add' "$T/cli.log")" == 2 ]] &&
    pass "5. claude and grok each registered spool-dev and spool-prd" || fail "5. registrations: $(cat "$T/cli.log")"
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["mcpServers"]; assert s["spool-prd"]["command"]==sys.argv[2] and s["spool-prd"]["args"]==["prd"]' \
    "$AH/.claude.json" "$AH/.local/bin/spool-mcp" && pass "5. claude runs spool-mcp prd as spool-prd" || fail "5. claude json: $(cat "$AH/.claude.json")"
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["mcpServers"]; assert s["spool-dev"]["command"]==sys.argv[2] and s["spool-dev"]["args"]==["dev"]' \
    "$AH/.qwen/settings.json" "$AH/.local/bin/spool-mcp" && pass "5. qwen runs spool-mcp dev as spool-dev (specs/048)" || fail "5. qwen json: $(cat "$AH/.qwen/settings.json" "$T/cli.log")"
else
  fail "5. install: rc $rc $(cat "$T/out")"
fi
: >"$T/cli.log"
in_orc AGENT_USER="$ME" MCP_CLIS="claude grok agy qwen" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$T/cli.log" ]] && grep -q 'agy is not installed' "$T/out" &&
  pass "5. a re-run registers nothing twice and skips a missing CLI" || fail "5. re-run: rc $rc $(cat "$T/cli.log" "$T/out")"

# ── 6. the probe action: refusals, and a send is a dry run by default ───────
probe() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    python3() { echo "PYTHON-RAN" >>"'"$T"'/py.log"; }
    do_spl_agent_mcp_probe' >"$T/out" 2>&1
}
for bad in "ENV=stg" "MCP_AS=" "MCP_AS=CLE-07 MCP_CONTROL_AS=CLE-07" "MCP_N=51" "MCP_TO=EZA-1" "MCP_TO=nobody MCP_TO_BOX=box-x" "MCP_FILE=2"; do
  # shellcheck disable=SC2086
  probe ENV=dev AGENT_USER="$ME" MCP_AS=CLE-07 $bad; rc=$?
  [[ $rc -ne 0 && ! -e "$T/py.log" ]] && pass "6. '$bad' is refused before the probe runs" || fail "6. '$bad': rc $rc $(cat "$T/out")"
done
probe ENV=dev AGENT_USER="$ME" MCP_AS=CLE-07 MCP_TO=EZA-1 MCP_TO_BOX=box-e2e-a MCP_FILE=1; rc=$?
[[ $rc -eq 0 && ! -e "$T/py.log" ]] && grep -q 'OK DRY_RUN nothing was sent' "$T/out" &&
  pass "6. a probe that sends is a dry run unless DRY_RUN=0" || fail "6. send dry run: rc $rc $(cat "$T/out")"
probe ENV=dev AGENT_USER="$ME" MCP_AS=CLE-07 MCP_CONTROL_AS=CLE-08; rc=$?
[[ -s "$T/py.log" ]] && pass "6. the read-only probe runs with no DRY_RUN" || fail "6. read-only probe did not run: $(cat "$T/out")"

echo "agent-mcp: $fails failure(s)"
exit $(( fails > 0 ))
