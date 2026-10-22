#!/usr/bin/env bash
# do_spl_agent_mcp_gcp_alerts_install (SPL-2887), hermetic: a fake agent home
# with a fake claude, a fake build that writes a fake spool, a fake iac dir.
#
# What must hold:
#   - the dry run touches nothing; a bad AGENT_USER, a missing iac run and a
#     lane worktree as the iac source are refused before anything is written
#   - a binary without the mcp-gcp-alerts verb is refused before the agent side
#   - the install writes the binary (0700 dir, .bak of a replaced one) and the
#     wrapper, which execs it with --iac <dir> --org --app
#   - claude gets user-scope gcp-alerts -> the wrapper once (a re-run adds
#     nothing), and a stale entry is replaced
# CONTROL: the wrapper is RUN against the fake spool and its argv is asserted,
# so a wrapper that dropped --iac fails here, not on the box.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ME="$(id -un)"

AH="$T/agent-home"; mkdir -p "$AH/.local/bin"
cat >"$AH/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
# fake claude: `mcp add -s user <name> -- <cmd> <args...>`, `mcp remove -s user <name>`
[ "$1 $2" = "mcp add" ] || [ "$1 $2" = "mcp remove" ] || exit 2
echo "claude $*" >>"$FAKE_LOG"
op="$2" name="$5"; shift 5; [ "$op" = add ] && shift
python3 - "$FAKE_HOME/.claude.json" "$op" "$name" "$@" <<'PY'
import json, os, sys
p, op, name, *rest = sys.argv[1:]
d = json.load(open(p)) if os.path.exists(p) else {}
s = d.setdefault("mcpServers", {})
if op == "add":
    s[name] = {"type": "stdio", "command": rest[0], "args": rest[1:], "env": {}}
elif name in s:
    del s[name]
else:
    sys.exit(1)
json.dump(d, open(p, "w"))
PY
EOF
chmod +x "$AH/.local/bin/claude"
cat >"$T/build.sh" <<EOF
#!/usr/bin/env bash
# fake build: a spool that knows mcp-gcp-alerts (refuses a missing iac run and
# records a served argv), or with OLD_SPOOL one that does not
if [ -n "\${OLD_SPOOL:-}" ]; then printf '#!/bin/sh\necho "unknown command \\\\"\$1\\\\""; exit 1\n' >"\$1"
else printf '#!/bin/sh\n[ -x "\$3/run" ] || { echo "spool: mcp-gcp-alerts: no executable \$3/run" >&2; exit 1; }\necho "ARGV \$*" >"$T/served"\n' >"\$1"; fi
chmod +x "\$1"; echo "built \$1"
EOF
chmod +x "$T/build.sh"
IAC="$T/iac"; mkdir -p "$IAC"; printf '#!/bin/sh\n' >"$IAC/run"; chmod +x "$IAC/run"
BIN="$AH/.local/share/csi-spl/gcp-alerts-mcp/spool" WRAP="$AH/.local/bin/gcp-alerts-mcp"

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/app" SPL_AGENT_MCP_HOME="$AH" GCP_ALERTS_IAC="$IAC" \
    SPL_AGENT_MCP_BUILD="$T/build.sh" FAKE_HOME="$AH" FAKE_LOG="$T/cli.log" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_agent_mcp_gcp_alerts_install' >"$T/out" 2>&1
}
registered() {  # the user-scope gcp-alerts entry as "<command> <args...>"
  python3 -c 'import json, sys
s = json.load(open(sys.argv[1])).get("mcpServers", {}).get("gcp-alerts", {})
print(" ".join([s.get("command", "")] + s.get("args", [])))' "$AH/.claude.json" 2>/dev/null
}

# ── 1. dry run and refusals ─────────────────────────────────────────────────
in_orc AGENT_USER="$ME"; rc=$?
[[ $rc -eq 0 && ! -e "$AH/.local/share" && ! -e "$WRAP" && ! -e "$T/cli.log" ]] && grep -q 'OK DRY_RUN nothing was touched' "$T/out" &&
  pass "1. the dry run touches nothing" || fail "1. dry run: rc $rc $(cat "$T/out")"
for bad in "AGENT_USER=" "AGENT_USER=Bad!User" "GCP_ALERTS_IAC=$T/none"; do
  in_orc AGENT_USER="$ME" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -e "$AH/.local/share" && ! -e "$WRAP" ]] && pass "1. '${bad#"$T"/}' is refused" || fail "1. '$bad' accepted: $(cat "$T/out")"
done
mkdir -p "$T/wt/csi-spl-iac"; cp "$IAC/run" "$T/wt/csi-spl-iac/run"; echo "gitdir: /x/.git/worktrees/wt" >"$T/wt/.git"
in_orc AGENT_USER="$ME" DRY_RUN=0 APP_PATH="$T/wt" GCP_ALERTS_IAC=; rc=$?
[[ $rc -ne 0 && ! -e "$WRAP" ]] && grep -q 'is a git worktree' "$T/out" && pass "1. a lane worktree as the iac source is refused" ||
  fail "1. worktree: rc $rc $(cat "$T/out")"
in_orc AGENT_USER="$ME" DRY_RUN=0 OLD_SPOOL=1; rc=$?
[[ $rc -ne 0 && ! -e "$WRAP" ]] && grep -q 'has no mcp-gcp-alerts verb' "$T/out" &&
  pass "1. a binary without the verb is refused before the agent side" || fail "1. old binary: rc $rc $(cat "$T/out")"

# ── 2. the install ──────────────────────────────────────────────────────────
in_orc AGENT_USER="$ME" DRY_RUN=0; rc=$?
if [[ $rc -eq 0 ]]; then
  [[ -x "$BIN" && "$(stat -c %a "$(dirname "$BIN")")" == 700 ]] && pass "2. the binary is installed in a 0700 dir" || fail "2. binary: $(ls -la "$(dirname "$BIN")" 2>&1)"
  rm -f "$T/served"; "$WRAP" </dev/null >/dev/null 2>&1
  [[ "$(cat "$T/served" 2>/dev/null)" == "ARGV mcp-gcp-alerts --iac $IAC --org csi --app spl" ]] &&
    pass "2. the wrapper execs spool mcp-gcp-alerts --iac --org --app" || fail "2. wrapper argv: $(cat "$T/served" 2>&1)"
  [[ "$(registered)" == "$WRAP" ]] && pass "2. claude: user-scope gcp-alerts -> the wrapper" || fail "2. registration: '$(registered)'"
else
  fail "2. install: rc $rc $(cat "$T/out")"
fi
n="$(grep -c 'mcp add' "$T/cli.log" 2>/dev/null)"
in_orc AGENT_USER="$ME" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(grep -c 'mcp add' "$T/cli.log")" == "$n" ]] && grep -q 'already runs' "$T/out" &&
  pass "2. a re-run registers nothing again" || fail "2. re-run: rc $rc $(cat "$T/out")"
python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["mcpServers"]["gcp-alerts"] = {"command": "/old", "args": ["x"]}; json.dump(d, open(p, "w"))' "$AH/.claude.json"
printf 'old\n' >"$BIN"
in_orc AGENT_USER="$ME" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(registered)" == "$WRAP" ]] && pass "2. a stale entry is replaced" || fail "2. stale: rc $rc '$(registered)' $(cat "$T/out")"
ls "$BIN".bak-* >/dev/null 2>&1 && pass "2. a replaced binary is kept as .bak-<ts>" || fail "2. no .bak of the replaced binary"

echo
[[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
