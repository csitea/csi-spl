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
#   - mistral vibe (specs/110 T008): one [[mcp_servers]] entry per env in a stub
#     ~/.vibe/config.toml, idempotent; the mirror reads a fixture session file
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
# The desk box defaults to this machine's (box.env SPOOL_DESK_BOX): pin it to a
# fixture file that does not exist, so the live box id never changes a verdict.
# Seat ids are the specs/061 form (c-007 seated, c-008 unseated). cle-07 is
# not an id; the refusal case below keeps it.
unset SPOOL_DESK_BOX; export SPOOL_BOX_ENV="$T/box.env"
MCP="$T/share/mcp"; D="$T/share/cloud/dev/desk/t1/box-desk"
mkdir -p "$MCP" "$D/spool/c-007/inbox" "$D/spool/.hub" "$D/keys"
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
box --as c-008 dev; rc=$?
[[ $rc -eq 5 ]] && grep -q 'c-008 has 0 seats' "$T/out" && pass "2. an unseated id refuses (5)" || fail "2. unseated: rc $rc $(cat "$T/out")"
box --as c-007 dev; rc=$?
[[ $rc -eq 6 && ! -e "$T/served" ]] && pass "2. no sidecar pid refuses (6)" || fail "2. no sidecar: rc $rc $(cat "$T/out")"
echo 1 >"$D/spool/.hub/hub-run.pid"   # pid 1 is alive but is not a hub-run
box --as c-007 dev; rc=$?
[[ $rc -eq 6 ]] && pass "2. a live pid that is not hub-run refuses (6)" || fail "2. foreign pid: rc $rc $(cat "$T/out")"

# ── 3. seated: the sidecar's spool settings, and --as ───────────────────────
env -i PATH=/usr/bin:/bin SPOOL_ROOT="$D/spool" SPOOL_KEYS_DIR="$D/keys" SPOOL_BOX_ID=box-desk \
  SPOOL_HUB_URL=https://hub.example.net SPOOL_TENANT=t1 SPOOL_NOTIFY_CMD=/bin/true SPOOL_POKE=1 \
  bash -c 'exec -a "spool hub-run" sleep 60' &
SIDE=$!
echo "$SIDE" >"$D/spool/.hub/hub-run.pid"
for _ in $(seq 50); do tr '\0' ' ' <"/proc/$SIDE/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null && break; sleep 0.1; done
box --as c-007 dev; rc=$?
if [[ $rc -eq 0 && -s "$T/served" ]]; then
  grep -qx 'ARGV mcp --as c-007' "$T/served" && pass "3. runs spool mcp --as c-007" || fail "3. argv: $(head -1 "$T/served")"
  want="SPOOL_BOX_ID=box-desk SPOOL_HUB_URL=https://hub.example.net SPOOL_KEYS_DIR=$D/keys SPOOL_LOG_LEVEL=error SPOOL_ROOT=$D/spool SPOOL_TENANT=t1"
  got="$(grep -v '^ARGV' "$T/served" | tr '\n' ' ' | sed 's/ $//')"
  [[ "$got" == "$want" ]] && pass "3. only the sidecar's spool settings (no notify hook, no caller env)" ||
    fail "3. env:\n got  $got\n want $want"
else
  fail "3. seated start: rc $rc $(cat "$T/out")"
fi
box --as c-007 dev t1 box-desk; rc=$?
[[ $rc -eq 0 ]] && pass "3. an explicit tenant + box works" || fail "3. explicit: rc $rc $(cat "$T/out")"

# ── 4. the agent half: config, id resolution, the hop ───────────────────────
CONF="$T/agent.env"
agent() { env -u MCP_BOT_AGENT_ID -u SPOOL_AGENT_ID -u TMUX_PANE -u CLE_TMUX_PANE SPOOL_MCP_CONF="$CONF" "$@" >"$T/out" 2>&1 </dev/null; }
rm -f "$T/served"
agent MCP_BOT_AGENT_ID=c-007 "$SH" dev; rc=$?
[[ $rc -eq 3 && ! -e "$T/served" ]] && pass "4. no config refuses (3)" || fail "4. no config: rc $rc $(cat "$T/out")"
printf 'SPOOL_MCP_BOX_USER=%s\nSPOOL_MCP_SERVE=%s\n' "$ME" "$MCP/spool-mcp.sh" >"$CONF"
agent "$SH" dev; rc=$?
[[ $rc -eq 4 && ! -e "$T/served" ]] && grep -q 'refusing to start unseated' "$T/out" && pass "4. no agent id refuses (4)" || fail "4. no id: rc $rc $(cat "$T/out")"
agent MCP_BOT_AGENT_ID=c-007 "$SH" dev; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'ARGV mcp --as c-007' "$T/served" && pass "4. MCP_BOT_AGENT_ID seats the server" || fail "4. env id: rc $rc $(cat "$T/out")"
rm -f "$T/served"
agent SPOOL_AGENT_ID=c-007 "$SH" dev; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'ARGV mcp --as c-007' "$T/served" && pass "4. SPOOL_AGENT_ID seats the server" || fail "4. spool id: rc $rc $(cat "$T/out")"
rm -f "$T/served"
agent MCP_BOT_AGENT_ID=c-008 "$SH" dev; rc=$?
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
for bad in "ENV=stg" "MCP_AS=" "MCP_AS=c-007 MCP_CONTROL_AS=c-007" "MCP_N=51" "MCP_TO=EZA-1" "MCP_TO=nobody MCP_TO_BOX=box-x" "MCP_FILE=2"; do
  # shellcheck disable=SC2086
  probe ENV=dev AGENT_USER="$ME" MCP_AS=c-007 $bad; rc=$?
  [[ $rc -ne 0 && ! -e "$T/py.log" ]] && pass "6. '$bad' is refused before the probe runs" || fail "6. '$bad': rc $rc $(cat "$T/out")"
done
# EZA-1 is a legacy participant: the write path refuses it after the cutoff.
# c-009 is a specs/061 id, so this dry run still proves a send stays a dry run.
probe ENV=dev AGENT_USER="$ME" MCP_AS=c-007 MCP_TO=c-009 MCP_TO_BOX=box-e2e-a MCP_FILE=1; rc=$?
[[ $rc -eq 0 && ! -e "$T/py.log" ]] && grep -q 'OK DRY_RUN nothing was sent' "$T/out" &&
  pass "6. a probe that sends is a dry run unless DRY_RUN=0" || fail "6. send dry run: rc $rc $(cat "$T/out")"
probe ENV=dev AGENT_USER="$ME" MCP_AS=c-007 MCP_CONTROL_AS=c-008; rc=$?
[[ -s "$T/py.log" ]] && pass "6. the read-only probe runs with no DRY_RUN" || fail "6. read-only probe did not run: $(cat "$T/out")"

# ── 7. mistral vibe (specs/110 T008): MCP entry, env shim, mirror ───────────
# vibe has no `mcp add`: the install writes a [[mcp_servers]] stdio table into
# ~/.vibe/config.toml itself. Done line: one entry per env, 2 runs = 1 entry.
SA_DIR="$PROJ_ROOT/src/bash/features/spawn-agents"
printf '#!/bin/sh\nexit 0\n' >"$AH/.local/bin/vibe"; chmod +x "$AH/.local/bin/vibe"
mkdir -p "$AH/.vibe"
cat >"$AH/.vibe/config.toml" <<'EOF'
active_model = "mistral-vibe-cli-latest"

[[mcp_servers]]
name = "other"
transport = "stdio"
command = "other-mcp"
EOF
vibe_count() {  # <name>: how many [[mcp_servers]] tables carry it
  python3 -c 'import sys, tomllib; print(sum(s.get("name") == sys.argv[2] for s in tomllib.load(open(sys.argv[1], "rb")).get("mcp_servers", [])))' \
    "$AH/.vibe/config.toml" "$1"
}
: >"$T/cli.log"
in_orc AGENT_USER="$ME" MCP_CLIS="mistral" DRY_RUN=0; rc1=$?
cp "$AH/.vibe/config.toml" "$T/vibe.run1"
in_orc AGENT_USER="$ME" MCP_CLIS="mistral" DRY_RUN=0; rc2=$?
[[ $rc1 -eq 0 && $rc2 -eq 0 && "$(vibe_count spool-dev)" == 1 && "$(vibe_count spool-prd)" == 1 ]] &&
  pass "7. two installs = one [[mcp_servers]] entry per env in ~/.vibe/config.toml" || fail "7. vibe entries: rc $rc1/$rc2 $(cat "$AH/.vibe/config.toml" "$T/out")"
cmp -s "$T/vibe.run1" "$AH/.vibe/config.toml" && grep -q 'mistral: spool-dev already runs' "$T/out" &&
  pass "7. the second run changes nothing (already registered)" || fail "7. re-run rewrote: $(diff "$T/vibe.run1" "$AH/.vibe/config.toml") $(cat "$T/out")"
[[ "$(vibe_count other)" == 1 ]] && grep -qx 'active_model = "mistral-vibe-cli-latest"' "$AH/.vibe/config.toml" &&
  [[ "$(stat -c %a "$AH/.vibe/config.toml")" == 600 ]] &&
  pass "7. the rest of config.toml is kept, mode 0600" || fail "7. kept: $(stat -c %a "$AH/.vibe/config.toml") $(cat "$AH/.vibe/config.toml")"
python3 - "$AH/.vibe/config.toml" "$AH/.local/bin/spool-mcp" <<'EOF' && pass "7. spool-prd is a stdio entry running spool-mcp prd" || fail "7. entry shape: $(cat "$AH/.vibe/config.toml")"
import sys, tomllib
s = [x for x in tomllib.load(open(sys.argv[1], "rb"))["mcp_servers"] if x["name"] == "spool-prd"][0]
assert s["transport"] == "stdio" and s["command"] == "/bin/sh" and s["args"][0] == "-c" and s["args"][-2:] == [sys.argv[2], "prd"], s
EOF
# A stale entry of the same name (another bin) is replaced, never doubled.
sed -i 's#"spool-mcp", "[^"]*", "dev"#"spool-mcp", "/stale/spool-mcp", "dev"#' "$AH/.vibe/config.toml"
in_orc AGENT_USER="$ME" MCP_CLIS="mistral" MCP_ENVS=dev DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(vibe_count spool-dev)" == 1 ]] && ! grep -q /stale/ "$AH/.vibe/config.toml" && grep -q 'mistral: registered spool-dev' "$T/out" &&
  pass "7. a stale spool-dev entry is replaced in place" || fail "7. stale: rc $rc $(cat "$AH/.vibe/config.toml" "$T/out")"

# The shim: vibe gives a stdio server a safe env only, so the id comes from
# the parent's environ. CONTROL: a parent without SPOOL_AGENT_ID seats nothing.
printf '#!/bin/sh\nprintf "%%s %%s" "${MCP_BOT_AGENT_ID:-none}" "$1"\n' >"$T/fake-mcp"; chmod +x "$T/fake-mcp"
shim_run() {  # <parent env...>: run the spool-dev entry as vibe would, with a safe env
  env -i PATH=/usr/bin:/bin "$@" python3 - "$AH/.vibe/config.toml" "$T/fake-mcp" <<'EOF'
import subprocess, sys, tomllib
s = [x for x in tomllib.load(open(sys.argv[1], "rb"))["mcp_servers"] if x["name"] == "spool-dev"][0]
args = s["args"][:-2] + [sys.argv[2], s["args"][-1]]
print(subprocess.run([s["command"]] + args, env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True).stdout)
EOF
}
got="$(shim_run SPOOL_AGENT_ID=m-004)"
[[ "$got" == "m-004 dev" ]] && pass "7. the shim hands the parent's SPOOL_AGENT_ID to spool-mcp" || fail "7. shim: '$got'"
got="$(shim_run)"
[[ "$got" == "none dev" ]] && pass "7. CONTROL: no id in the parent, none passed" || fail "7. shim control: '$got'"

# The mirror reads a fixture session: the unified journal (vibe's default
# harness) and the legacy messages.jsonl. Prompt then answer, in that order.
VH="$T/vibe-home"; SID="7fa9c871-4e64-e89c-22ca-f5ca47aeb917"; J="$VH/logs/session/unified/$SID/journal"
mkdir -p "$J"
python3 - "$J/0000000000000001.jsonl" "$SID" <<'EOF'
import json, sys
def ent(i, role, text, **kw):
    e = {"id": i, "role": role, "type": "message", "content": [{"type": "text", "text": text}]}
    e.update(kw)
    return {"type": "projection_delta", "payload": {"delta": [{"op": "append_entry", "entry": e}, {"op": "set_envelope", "state": {}}]}}
rows = [ent("u1", "user", "older prompt"), ent("a1", "assistant", "older answer"),
        ent("u2", "user", "say OK, please"), ent("a2", "assistant", "draft"),
        ent("a2", "assistant", "OK."), ent("u3", "user", "<injected/>", injected=True),
        {"type": "core_input", "payload": {}}]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
EOF
cat >"$T/rec" <<EOF
#!/usr/bin/env bash
{ printf 'POST %s\n' "\$*"; cat; echo; } >>"$T/posts"
EOF
chmod +x "$T/rec"
mirror() {  # <hook json>
  rm -f "$T/posts"
  printf '%s' "$1" | env SPOOL_ROOT="$T" SPOOL_AGENT_ID=m-004 VIBE_HOME="$VH" SPOOL_MIRROR_SYNC=1 SPOOL_MIRROR_POST="$T/rec" \
    python3 "$SA_DIR/scripts/spool-mirror.py" hook --vibe >"$T/hook.out" 2>&1
}
mirror '{"hook_event_name":"post_agent","session_id":"'"$SID"'","transcript_path":"","cwd":"/"}'; rc=$?
want="POST post --agent m-004 --event prompt --session $SID
say OK, please
POST post --agent m-004 --event answer --session $SID
OK."
[[ $rc -eq 0 && ! -s "$T/hook.out" && "$(cat "$T/posts" 2>/dev/null)" == "$want" ]] &&
  pass "7. mirror: unified journal fixture -> the prompt, then the newest answer (n=1)" || fail "7. mirror unified: rc $rc out=$(cat "$T/hook.out") posts=$(cat "$T/posts" 2>/dev/null)"
printf '%s\n' '{"role":"system","content":"sys"}' '{"role":"user","content":"hello vibe"}' \
  '{"role":"assistant","content":[{"type":"text","text":"hi there"}]}' >"$T/messages.jsonl"
mirror '{"hook_event_name":"post_agent","session_id":"s-legacy-1","transcript_path":"'"$T/messages.jsonl"'","cwd":"/"}'
grep -qx 'hello vibe' "$T/posts" 2>/dev/null && grep -qx 'hi there' "$T/posts" &&
  pass "7. mirror: legacy messages.jsonl fixture (transcript_path)" || fail "7. mirror legacy: $(cat "$T/posts" "$T/hook.out" 2>/dev/null)"
mirror '{"hook_event_name":"post_agent","session_id":"'"$SID"'","parent_session_id":"p1"}'
[[ ! -e "$T/posts" ]] && pass "7. CONTROL: a subagent turn posts nothing" || fail "7. subagent posted: $(cat "$T/posts")"
(unset SPOOL_AGENT_ID; printf '%s' '{"hook_event_name":"post_agent","session_id":"'"$SID"'"}' |
  env SPOOL_ROOT="$T" VIBE_HOME="$VH" SPOOL_MIRROR_SYNC=1 SPOOL_MIRROR_POST="$T/rec" python3 "$SA_DIR/scripts/spool-mirror.py" hook --vibe)
[[ ! -e "$T/posts" ]] && pass "7. CONTROL: no agent id in the env posts nothing" || fail "7. no-id posted"

# The hook entry: merged into ~/.vibe/hooks.toml once, another hook kept.
HT="$T/vibe-hooks/hooks.toml"; mkdir -p "${HT%/*}"
printf '[[hooks]]\nname = "hook-ping"\ntype = "post_tool"\ncommand = "true"\n' >"$HT"
for _ in 1 2; do
  env SPOOL_AGENT_VIBE_HOOKS="$HT" bash -c 'source "$1"; smh_install mistral m-004 /x/spool-mirror.py && echo "$SMH_WHERE"' _ "$SA_DIR/lib/spool-mirror-hooks.inc.sh" >"$T/out" 2>&1
done
python3 - "$HT" <<'EOF' && grep -qx "$HT" "$T/out" && pass "7. smh_install mistral: one post_agent spool-mirror hook, hook-ping kept" || fail "7. hooks.toml: $(cat "$HT" "$T/out")"
import sys, tomllib
h = tomllib.load(open(sys.argv[1], "rb"))["hooks"]
m = [x for x in h if x["name"] == "spool-mirror"]
assert len(m) == 1 and m[0]["type"] == "post_agent" and "hook --vibe" in m[0]["command"], h
assert [x["name"] for x in h].count("hook-ping") == 1, h
EOF

# agent-identity sees a vibe process (a pipx python entry point) as mistral,
# and agent-mirror-check finds its hook in ~/.vibe/hooks.toml.
python3 - "$SA_DIR/scripts" "$AH" <<'EOF' && pass "7. kind_of(python3 .../vibe) = mistral; m-004 is an id; the check reads ~/.vibe/hooks.toml" || fail "7. identity/check kind"
import importlib.util, os, sys
def load(name, f):
    spec = importlib.util.spec_from_file_location(name, os.path.join(sys.argv[1], f))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
ai = load("ai", "agent-identity.py")
assert ai.kind_of(["/venv/bin/python3.13", "/opt/agent/.local/bin/vibe", "--auto-approve"]) == "mistral"
assert ai.kind_of(["/usr/bin/python3", "/x/spool-mirror.py", "hook"]) == ""
assert ai.ID_RE.match("m-004") and not ai.ID_RE.match("x-004")
amc = load("amc", "agent-mirror-check.py")
os.makedirs(os.path.join(sys.argv[2], ".vibe"), exist_ok=True)
open(os.path.join(sys.argv[2], ".vibe", "hooks.toml"), "w").write('command = "exec python3 /x/spool-mirror.py hook --vibe"\n')
assert amc.hooks_of("mistral", [], sys.argv[2]) == (os.path.join(sys.argv[2], ".vibe", "hooks.toml"), "/x/spool-mirror.py")
EOF

echo "agent-mcp: $fails failure(s)"
exit $(( fails > 0 ))
