#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 159 row T8 (4.3, leak path L23): the Claude self sign-in of a
#          workspace W on a fleet box, do_spl_ws_claude_signin, behind a
#          switch that ships OFF. All of it runs on fixtures under $T as the
#          current user standing in for W's OS user: no real sign-in, no real
#          token (a fake of the vendor's shape, built at run time), no hub.
#   1. (n=4) the switch ships off: cnf all/dev/prd name no workspace, and
#      SIGNIN_CMD=in DRY_RUN=0 with no switch, or a switch naming another
#      workspace, is refused rc 3 before any dir or tmux call
#   2. (n=4) the caller is W's user, not the fleet's agent user; the runtime
#      dir is tmpfs and outside $HOME, else refused rc 1
#   3. (n=3) switch on: the dry run touches nothing; DRY_RUN=0 makes the dir
#      0700 and starts the UNMODIFIED CLI's own `auth login --claudeai` with
#      CLAUDE_CONFIG_DIR = that dir in a tmux session, no settings file there
#   4. (n=3) signed in (a fake sign-in file): status says so with the modes and
#      prints no token; a second sign-in is refused
#   5. (n=4) L23 exclusion: the session export and the token-burn collector
#      read nothing of the sign-in dir. RED CONTROL: the same transcript in
#      $HOME/.claude is found by both, so the test can see a read
#   6. (n=3) sign-out with the switch OFF: the session ended, the CLI's own
#      logout run, the dir gone, no token printed
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ME=$(id -un)
RT=$(mktemp -d -p /dev/shm 2>/dev/null) || { echo "SKIP: no tmpfs /dev/shm"; exit 0; }
trap 'rm -rf "$T" "$RT"' EXIT
chmod 0700 "$RT"
[[ "$(stat -f -c %T "$RT")" == tmpfs ]] || { echo "SKIP: /dev/shm is not tmpfs"; exit 0; }
D="$RT/spool-claude" H="$T/home"
mkdir -p "$H"
FAKE="sk-ant-oat01-$(printf 'Zf0_%.0s' $(seq 1 22))AA"

orc_stub 0 tmux
# tmux: no session exists (has-session exits 1); every call is logged
printf '#!/bin/sh\necho "tmux $*" >>"$STUB_LOG"\ncase " $* " in *" has-session "*) exit 1;; esac\nexit 0\n' >"$T/stub/tmux"
cat >"$T/stub/claude" <<'EOF'
#!/bin/sh
echo "claude CCD=$CLAUDE_CONFIG_DIR KEY=${ANTHROPIC_API_KEY:-} $*" >>"$STUB_LOG"
EOF
chmod +x "$T/stub/claude"

# wcs <VAR=value>...: the action as W (= this user), on the fixture runtime.
wcs() {
  : >"$T/calls.log"
  SNIPPET=do_spl_ws_claude_signin in_orc HOME="$H" SPL_WS_USER="$ME" SPOOL_AGENT_USER=fleetusr TENANT_ID=wsa \
    SPL_CLAUDE_SIGNIN_RUNTIME="$RT" ANTHROPIC_API_KEY=sk-test-0000 "$@" >"$T/o" 2>&1
}
nocalls() { ! grep -qv "^tmux -L spool-claude-signin has-session" "$T/calls.log"; }

# ---- 1. the switch ships off ----------------------------------------------
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
for f in all.env.yaml dev.env.json prd.env.json; do
  v="$(yq -r '.env.box.claude_self_signin_tenants // "MISSING"' "$CNF/$f")"
  if [[ -z "$v" ]]; then pass "1 cnf $f ships the switch empty (off)"; else fail "1 cnf $f switch is '$v', want empty"; fi
done
wcs SIGNIN_CMD=in DRY_RUN=0; rc=$?
if (( rc == 3 )) && grep -q 'claude self sign-in is off' "$T/o" && nocalls && [[ ! -e "$D" ]]; then
  pass "1 no switch -> refused rc 3, no dir, no call"
else fail "1 no switch: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
wcs SIGNIN_CMD=in DRY_RUN=0 SPL_CLAUDE_SIGNIN_TENANTS="wsb wsab"; rc=$?
if (( rc == 3 )) && nocalls && [[ ! -e "$D" ]]; then pass "1 a switch naming other workspaces -> refused rc 3"
else fail "1 other workspaces: rc=$rc $(cat "$T/o")"; fi

# ---- 2. caller and runtime -------------------------------------------------
ON=(SPL_CLAUDE_SIGNIN_TENANTS="wsb wsa")
wcs "${ON[@]}" SIGNIN_CMD=in DRY_RUN=0 SPL_WS_USER=spl-wsa; rc=$?
if (( rc == 1 )) && grep -q "run this as the workspace's OS user" "$T/o" && nocalls; then pass "2 another caller -> refused"
else fail "2 another caller: rc=$rc $(cat "$T/o")"; fi
wcs "${ON[@]}" SIGNIN_CMD=in DRY_RUN=0 SPOOL_AGENT_USER="$ME"; rc=$?
if (( rc == 1 )) && grep -q "fleet's agent user" "$T/o" && nocalls; then pass "2 W = the fleet's agent user -> refused"
else fail "2 fleet user: rc=$rc $(cat "$T/o")"; fi
DISK=$(mktemp -d -p /var/tmp) && chmod 0700 "$DISK"
trap 'rm -rf "$T" "$RT" "$DISK"' EXIT
wcs "${ON[@]}" SIGNIN_CMD=in DRY_RUN=0 SPL_CLAUDE_SIGNIN_RUNTIME="$DISK"; rc=$?
if [[ "$(stat -f -c %T "$DISK")" == tmpfs ]]; then echo "SKIP: /var/tmp is tmpfs, no disk fixture"
elif (( rc == 1 )) && grep -q 'is not tmpfs' "$T/o" && nocalls; then pass "2 a disk runtime dir -> refused"
else fail "2 disk runtime: rc=$rc $(cat "$T/o")"; fi
wcs "${ON[@]}" SIGNIN_CMD=in DRY_RUN=0 HOME="$RT"; rc=$?
if (( rc == 1 )) && grep -q 'is inside \$HOME' "$T/o" && nocalls; then pass "2 a runtime dir inside \$HOME -> refused"
else fail "2 runtime in HOME: rc=$rc $(cat "$T/o")"; fi

# ---- 3. switch on: dry run, then the sign-in starts ------------------------
wcs "${ON[@]}" SIGNIN_CMD=in; rc=$?
if (( rc == 0 )) && grep -q 'DRY_RUN would make' "$T/o" && nocalls && [[ ! -e "$D" ]]; then pass "3 dry run touches nothing"
else fail "3 dry run: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
wcs "${ON[@]}" SIGNIN_CMD=in DRY_RUN=0; rc=$?
call="$(grep '^tmux ' "$T/calls.log" | grep new-session)"
if (( rc == 0 )) && [[ "$(stat -c %a "$D" 2>/dev/null)" == 700 && "$call" == *"-s signin-wsa "* &&
      "$call" == *"-u ANTHROPIC_API_KEY"* && "$call" == *"CLAUDE_CONFIG_DIR=$D "* && "$call" == *"/claude auth login --claudeai" ]]; then
  pass "3 DRY_RUN=0: dir 0700, the CLI's own login in tmux session signin-wsa, no API key passed"
else fail "3 sign-in start: rc=$rc $(cat "$T/o") call: $call mode: $(stat -c %a "$D" 2>&1)"; fi
if [[ -z "$(ls -A "$D" 2>/dev/null)" ]]; then pass "3 the sign-in dir holds no settings file (no mirror hook)"
else fail "3 the sign-in dir holds: $(ls -A "$D")"; fi

# ---- 4. signed in ----------------------------------------------------------
(umask 077; printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$FAKE" >"$D/.credentials.json")
mkdir -p "$D/projects/-w-x"
printf '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":2}},"content":"%s"}\n' "$FAKE" \
  >"$D/projects/-w-x/33333333-3333-3333-3333-333333333333.jsonl"
wcs SIGNIN_CMD=status; rc=$?
if (( rc == 0 )) && grep -q 'OK signed in: .* mode 700, its sign-in file mode 600' "$T/o"; then pass "4 status: signed in, modes 700 / 600"
else fail "4 status: rc=$rc $(cat "$T/o")"; fi
if grep -qF "${FAKE:13:20}" "$T/o"; then fail "4 status printed the token"; else pass "4 status prints no token"; fi
wcs "${ON[@]}" SIGNIN_CMD=in DRY_RUN=0; rc=$?
if (( rc == 1 )) && grep -q 'already signed in' "$T/o"; then pass "4 a second sign-in -> refused"
else fail "4 second sign-in: rc=$rc $(cat "$T/o")"; fi

# ---- 5. L23: the readers of the home never read the sign-in dir -----------
EXPORT="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spool-session-export.py"
tick() {
  env TOKEN_BURN_STATE_DIR="$1" TOKEN_BURN_HOMES="$H" TOKEN_BURN_LIVE_CMD=true TOKEN_BURN_PUSH=0 SPOOL_ROOT="$T/spool" \
    COLLECT_FUNC="$PROJ_ROOT/src/bash/run/spl-token-burn-collect.func.sh" \
    bash -c 'source "$COLLECT_FUNC"; do_spl_token_burn_collect' >/dev/null 2>&1
}
mkdir -p "$T/spool"
SPOOL_AGENT_HOME="$H" python3 "$EXPORT" c-101 "${FAKE:13:20}" - >"$T/x" 2>&1; rc=$?
if (( rc == 2 )) && ! grep -qF "${FAKE:13:20}" "$T/x"; then pass "5 the session export finds no transcript in the sign-in dir"
else fail "5 session export: rc=$rc $(head -c 300 "$T/x")"; fi
tick "$T/tb1"
if ! grep -rqF "$RT" "$T/tb1" && ! grep -rqF "${FAKE:13:20}" "$T/tb1"; then pass "5 the collector reads nothing of the sign-in dir"
else fail "5 collector state names the sign-in dir: $(grep -rlF "$RT" "$T/tb1")"; fi
# RED CONTROL: the same transcript where the readers look ($HOME/.claude)
mkdir -p "$H/.claude/projects/-w-x"
cp "$D/projects/-w-x/"*.jsonl "$H/.claude/projects/-w-x/"
SPOOL_AGENT_HOME="$H" python3 "$EXPORT" c-101 "${FAKE:13:20}" - >"$T/x" 2>&1; rc=$?
if (( rc == 0 )); then pass "5 RED CONTROL: in \$HOME/.claude the session export finds it"
else fail "5 RED CONTROL export: rc=$rc $(head -c 300 "$T/x")"; fi
tick "$T/tb2"
if grep -rqF "$H/.claude/projects/-w-x" "$T/tb2"; then pass "5 RED CONTROL: in \$HOME/.claude the collector reads it"
else fail "5 RED CONTROL collector: $(ls "$T/tb2")"; fi
rm -rf "$H/.claude"

# ---- 6. sign-out, switch off ----------------------------------------------
wcs SIGNIN_CMD=out; rc=$?
if (( rc == 0 )) && grep -q 'DRY_RUN would end' "$T/o" && nocalls && [[ -e "$D/.credentials.json" ]]; then pass "6 sign-out dry run touches nothing"
else fail "6 sign-out dry run: rc=$rc $(cat "$T/o")"; fi
wcs SIGNIN_CMD=out DRY_RUN=0; rc=$?
if (( rc == 0 )) && [[ ! -e "$D" ]] && grep -q "^tmux -L spool-claude-signin kill-session -t =signin-wsa" "$T/calls.log" &&
      grep -q "^claude CCD=$D KEY= auth logout" "$T/calls.log"; then
  pass "6 sign-out with the switch off: session ended, the CLI's logout run, dir gone"
else fail "6 sign-out: rc=$rc $(cat "$T/o") calls: $(cat "$T/calls.log")"; fi
if grep -qF "${FAKE:13:20}" "$T/o" "$T/calls.log"; then fail "6 sign-out printed the token"; else pass "6 sign-out prints no token"; fi

echo "-- ws-claude-signin.tst.sh: $fails failed"
(( fails == 0 ))
