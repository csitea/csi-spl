#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool_agent_models (spec 184 row A1, contract 7.1.6) reads each
#          CLI's live list from stub CLIs and fixture homes: claude's --help
#          aliases, grok's models cache, vibe's [[models]] names and aliases.
#          agy, qwen, codex and a vendor with no source exit 4, an unknown
#          vendor exits 2, "cli=<version>" goes to stderr. The read never
#          writes the cnf or the home and never runs `grok models`. A model
#          added to the stub's output is in the list (red control: plant a
#          reader that drops it). The hub report (7.1.5) is off unless its env
#          is set, and is tested against a stub hub only. No network.
#          AGENT_MODELS_LIB (optional) - the library under test, default the
#          tree's (a planted copy for the red control).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
# shellcheck source=wait-event.inc.sh
source "$TEST_DIR/wait-event.inc.sh"
LIB="${AGENT_MODELS_LIB:-$PROJ_ROOT/src/bash/features/spawn-agents/lib/agent-models.inc.sh}"
FUNC="$PROJ_ROOT/src/bash/run/spl-agent-models-list.func.sh"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
T=$(mktemp -d); HUB_PID=""
trap '[[ -n "$HUB_PID" ]] && kill "$HUB_PID" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: no jq"; exit 1; }

H="$T/home"
mkdir -p "$H/.local/bin" "$H/.grok" "$H/.vibe" "$T/empty"
cat >"$H/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >>"$STUB_LOG"
case "$1" in
  --version) echo "2.1.323 (Claude Code)" ;;
  --help) cat <<'HELP'
Options:
  --mcp-config <configs...>             Load MCP servers from JSON files or
                                        strings (space-separated)
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name.
  -n, --name <name>                     Set a display name (e.g. 'x')
HELP
  ;;
esac
EOF
cat >"$H/.local/bin/grok" <<'EOF'
#!/usr/bin/env bash
echo "grok $*" >>"$STUB_LOG"
[[ "$1" == --version ]] && echo "grok 1.0.92 (b06756fd6256) [stable]"
exit 0
EOF
cat >"$H/.local/bin/vibe" <<'EOF'
#!/usr/bin/env bash
echo "vibe $*" >>"$STUB_LOG"
[[ "$1" == --version ]] && echo "vibe 2.26.0"
exit 0
EOF
chmod +x "$H/.local/bin/"*
cat >"$H/.grok/models_cache.json" <<'EOF'
{"fetched_at": "2026-11-21T13:30:13Z", "grok_version": "1.0.92",
 "models": {"grok-4.7": {"info": {}}, "grok-4.7-build-fast": {"info": {}},
            "grok-4.6": {"info": {}}, "grok-4.5": {"info": {}}}}
EOF
cat >"$H/.vibe/config.toml" <<'EOF'
active_model = "mistral-large"

[[models]]
name = "mistral-large-latest"
provider = "mistral"
alias = "mistral-large"

[[models]]
name = "mistral-vibe-cli-latest"
alias = "mistral-medium-3.5"

[[mcp_servers]]
name = "spool-prd"
EOF

# lm VENDOR [ENV=...]... -> $T/out (stdout), $T/err (stderr), $rc
lm() {
  local v="$1"; shift
  : >"$T/calls.log"
  env -u CLAUDE_BIN -u GROK_BIN -u MISTRAL_BIN -u SPOOL_AGENT_USER \
    SPOOL_AGENT_HOME="$H" STUB_LOG="$T/calls.log" PATH="$T/empty:/usr/bin:/bin" "$@" \
    bash -c 'source "$1"; spool_agent_models "$2"' _ "$LIB" "$v" >"$T/out" 2>"$T/err"
  rc=$?
}
expect() {  # label vendor expected-lines...
  local label="$1" v="$2"; shift 2
  lm "$v"
  if [[ $rc -eq 0 && "$(cat "$T/out")" == "$(printf '%s\n' "$@")" ]]; then pass "$label"
  else fail "$label: rc=$rc out=[$(tr '\n' ' ' <"$T/out")] err=[$(cat "$T/err")]"; fi
}

bash -n "$LIB" && bash -n "$FUNC" && pass "0. library and action parse" || fail "0. syntax"
cnf_before="$(sha256sum "$CNF" 2>/dev/null)"
home_before="$(cd "$H" && find . -type f -exec sha256sum {} + | sort)"

# --- 1. the live list per vendor ---------------------------------------------
expect "1. claude: the --help aliases of --model" claude fable opus sonnet
grep -qx 'cli=2.1.323' "$T/err" && pass "1. claude: cli=<version> on stderr" || fail "1. claude cli: $(cat "$T/err")"
expect "1. grok: the keys of the CLI's models cache" grok grok-4.7 grok-4.7-build-fast grok-4.6 grok-4.5
grep -qx 'cli=1.0.92' "$T/err" && pass "1. grok: cli=<version> on stderr" || fail "1. grok cli: $(cat "$T/err")"
expect "1. mistral: [[models]] names and aliases, no mcp server" mistral \
  mistral-large-latest mistral-large mistral-vibe-cli-latest mistral-medium-3.5
grep -qx 'cli=2.26.0' "$T/err" && pass "1. mistral: cli=<version> on stderr" || fail "1. mistral cli: $(cat "$T/err")"

# --- 2. the done test: a model added to the stub's output is in the list ------
jq '.models["grok-9-new"] = {"info": {}}' "$H/.grok/models_cache.json" >"$T/c.json" && cp "$T/c.json" "$H/.grok/models_cache.json"
expect "2. grok: a model added to the cache is listed" grok grok-4.7 grok-4.7-build-fast grok-4.6 grok-4.5 grok-9-new
printf '\n[[models]]\nname = "devstral-new"\n' >>"$H/.vibe/config.toml"
expect "2. mistral: a model added to config.toml is listed" mistral \
  mistral-large-latest mistral-large mistral-vibe-cli-latest mistral-medium-3.5 devstral-new
sed -i "s/'sonnet')/'sonnet', or 'haiku')/" "$H/.local/bin/claude"
expect "2. claude: an alias added to --help is listed" claude fable opus sonnet haiku
home_before="$(cd "$H" && find . -type f -exec sha256sum {} + | sort)"

# --- 3. no source, unknown vendor ---------------------------------------------
for v in agy qwen codex; do
  lm "$v"; [[ $rc -eq 4 && ! -s "$T/out" ]] && pass "3. $v: no list source, exit 4" || fail "3. $v: rc=$rc"
done
lm gemini; [[ $rc -eq 2 && ! -s "$T/out" ]] && pass "3. unknown vendor: exit 2" || fail "3. unknown: rc=$rc"
lm ""; [[ $rc -eq 2 ]] && pass "3. empty vendor: exit 2" || fail "3. empty vendor: rc=$rc"
lm claude SPOOL_AGENT_HOME="$T/empty"; [[ $rc -eq 4 ]] && pass "3. claude not installed: exit 4" || fail "3. claude absent: rc=$rc"
mkdir -p "$T/h2/.local/bin" && cp "$H/.local/bin/grok" "$H/.local/bin/vibe" "$T/h2/.local/bin/"
lm grok SPOOL_AGENT_HOME="$T/h2"; [[ $rc -eq 4 ]] && pass "3. grok with no cache: exit 4" || fail "3. grok no cache: rc=$rc"
mkdir -p "$T/h2/.vibe" && echo 'models = [' >"$T/h2/.vibe/config.toml"
lm mistral SPOOL_AGENT_HOME="$T/h2"; [[ $rc -eq 4 ]] && pass "3. mistral with a broken config: exit 4" || fail "3. mistral broken: rc=$rc"
mkdir -p "$T/h2/.grok" && echo '{"models": {"bad name; rm": {}}}' >"$T/h2/.grok/models_cache.json"
lm grok SPOOL_AGENT_HOME="$T/h2"; [[ $rc -eq 4 && ! -s "$T/out" ]] && pass "3. a model failing the 7.1.2 syntax is dropped" || fail "3. bad syntax: rc=$rc $(cat "$T/out")"

# --- 4. never a paid call, never a write --------------------------------------
lm grok
others="$(grep -E '^grok' "$T/calls.log" | grep -vx 'grok --version')"
[[ -z "$others" ]] && pass "4. grok: only --version run, never \`grok models\`" || fail "4. grok was run with more than --version: $others"
[[ "$(sha256sum "$CNF" 2>/dev/null)" == "$cnf_before" ]] && pass "4. the cnf is unchanged" || fail "4. the cnf changed"
[[ "$(cd "$H" && find . -type f -exec sha256sum {} + | sort)" == "$home_before" ]] && pass "4. the agent home is unchanged" || fail "4. the home changed"

# --- 5. the action: a dry print ------------------------------------------------
env SPOOL_AGENT_HOME="$H" STUB_LOG="$T/calls.log" PATH="$T/empty:/usr/bin:/bin" PROJ_PATH="$PROJ_ROOT" \
  bash -c 'source "$1"; do_spl_agent_models_list' _ "$FUNC" >"$T/out" 2>&1; rc=$?
if [[ $rc -eq 0 ]] && grep -qx 'grok cli=1.0.92' "$T/out" && grep -qx '  grok-9-new' "$T/out" \
  && grep -qx 'agy no list source (exit 4)' "$T/out" && grep -qx '  devstral-new' "$T/out"; then
  pass "5. do_spl_agent_models_list prints every vendor"
else fail "5. action: rc=$rc $(cat "$T/out")"; fi
env AGENT_MODELS_VENDOR=qwen SPOOL_AGENT_HOME="$H" PROJ_PATH="$PROJ_ROOT" \
  bash -c 'source "$1"; do_spl_agent_models_list' _ "$FUNC" >"$T/out" 2>&1; rc=$?
[[ $rc -eq 4 ]] && pass "5. one vendor: the action exits with its code" || fail "5. one vendor: rc=$rc $(cat "$T/out")"

# --- 6. the hub report: off by default, against a stub hub --------------------
cat >"$T/hub.py" <<'EOF'
import http.server, json, os, sys
code, out = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(out, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"),
                                "tenant": self.headers.get("X-Spool-Tenant"),
                                "body": json.loads(body)}) + "\n")
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(out + ".port", "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
hub() {  # code -> HUB_PID, HUB_URL
  [[ -n "$HUB_PID" ]] && kill "$HUB_PID" 2>/dev/null
  rm -f "$T/hub.log" "$T/hub.log.port"
  python3 -I "$T/hub.py" "$1" "$T/hub.log" & HUB_PID=$!
  wait_event 10 test -s "$T/hub.log.port" || { fail "6. stub hub did not start"; return 1; }
  HUB_URL="http://127.0.0.1:$(cat "$T/hub.log.port")"
}
# A curl first on PATH that logs its argv, then runs the real one: the token
# must never be on it (/proc/<pid>/cmdline is world-readable).
mkdir -p "$T/curlstub"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$T/curl-argv.log" "$(command -v curl)" >"$T/curlstub/curl"
chmod +x "$T/curlstub/curl"
rep() {  # vendor [ENV=...]...
  local v="$1"; shift
  printf 'grok-4.7\nbad name\ngrok-4.6\n' | env -u SPOOL_HUB_URL -u SPOOL_AGENT_MODELS_HUB_TOKEN PATH="$T/curlstub:$PATH" "$@" \
    bash -c 'source "$1"; spool_agent_models_report "$2" 1.0.92' _ "$LIB" "$v"
  rc=$?
}
hub 200
rep grok SPOOL_BOX_ID=box-a SPOOL_TENANT=t1
[[ $rc -eq 3 && ! -s "$T/hub.log" ]] && pass "6. report off with no hub url or token: exit 3, no call" || fail "6. off: rc=$rc"
rep grok SPOOL_HUB_URL="$HUB_URL" SPOOL_BOX_ID=box-a SPOOL_TENANT=t1
[[ $rc -eq 3 && ! -s "$T/hub.log" ]] && pass "6. report off with no token: exit 3, no call" || fail "6. no token: rc=$rc"
ON=(SPOOL_HUB_URL="$HUB_URL" SPOOL_BOX_ID=box-a SPOOL_TENANT=t1 SPOOL_AGENT_MODELS_HUB_TOKEN=tok1)
rep grok "${ON[@]}"
if [[ $rc -eq 0 ]] && jq -e '.path == "/v1/boxes/box-a/agent-models/grok" and .auth == "Bearer tok1"
    and .tenant == "t1" and .body.cli_version == "1.0.92" and .body.models == ["grok-4.7", "grok-4.6"]
    and (.body.read_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' "$T/hub.log" >/dev/null; then
  pass "6. report: PUT /v1/boxes/{box}/agent-models/{vendor} with the 7.1.5 body"
else fail "6. report: rc=$rc $(cat "$T/hub.log" 2>/dev/null)"; fi
if [[ -s "$T/curl-argv.log" ]] && ! grep -q tok1 "$T/curl-argv.log"; then
  pass "6. the token is never on curl's argv"
else fail "6. the token is on curl's argv (or curl did not run): $(cat "$T/curl-argv.log" 2>/dev/null)"; fi
for unset_var in SPOOL_BOX_ID SPOOL_TENANT; do
  rm -f "$T/hub.log"
  rep grok "${ON[@]/$unset_var=*/$unset_var=}"
  [[ $rc -eq 3 && ! -s "$T/hub.log" ]] && pass "6. report off with $unset_var empty: exit 3, no call" || fail "6. $unset_var empty: rc=$rc"
done
hub 404; ON[0]="SPOOL_HUB_URL=$HUB_URL"
rep grok "${ON[@]}"; [[ $rc -eq 3 ]] && pass "6. a hub without the route (404): off, exit 3" || fail "6. 404: rc=$rc"
hub 405; ON[0]="SPOOL_HUB_URL=$HUB_URL"
rep grok "${ON[@]}"; [[ $rc -eq 3 ]] && pass "6. a hub without the method (405): off, exit 3" || fail "6. 405: rc=$rc"
hub 500; ON[0]="SPOOL_HUB_URL=$HUB_URL"
rep grok "${ON[@]}"; [[ $rc -eq 1 ]] && pass "6. a hub error (500): exit 1" || fail "6. 500: rc=$rc"
rm -f "$T/hub.log"
rep grok "${ON[@]/SPOOL_BOX_ID=box-a/SPOOL_BOX_ID=../x}"; [[ $rc -eq 1 && ! -s "$T/hub.log" ]] && pass "6. a bad box id is refused before any call" || fail "6. bad box: rc=$rc"

echo
[[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
