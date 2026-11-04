#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_set_codex_key (spec 161 2.2.5, row B3), hermetic: a temp agent
#          home and a codex stub whose `login --with-api-key` reads stdin.
#   1. CODEX_KEY_STDIN=1: codex gets the key on stdin (the last
#      OPENAI_API_KEY= line wins), auth.json is 600 and the agent's, the
#      output names length and last 4 only
#   2. CODEX_KEY_FILE: the same from a file; a group-readable file is named
#   3. the key is in no output, no argv and no env of codex; an exported
#      OPENAI_API_KEY never reaches codex (CONTROL: the check catches a
#      planted echo)
#   4. CONTROLS: a non-tty stdin without a source, a short key and a box
#      with no codex are refused, and nothing is written
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ME="$(id -un)"
KEY="sk-canaryK3y${RANDOM}${RANDOM}Zq"
OLD="sk-oldK3y${RANDOM}${RANDOM}Zqq"
ENVKEY="sk-canaryEnv${RANDOM}${RANDOM}Z"
H="$T/agent-home"; mkdir -p "$H/.local/bin" "$T/spool"
: >"$T/calls.log"
# the codex stub: logs its argv and whether a key is in its env; `login
# --with-api-key` writes stdin into ~/.codex/auth.json, as the CLI does
cat >"$H/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex $* key-in-env=${OPENAI_API_KEY:+yes}${CODEX_API_KEY:+yes}" >>"$STUB_LOG"
if [ "$*" = "login --with-api-key" ]; then
  k="$(cat)"; mkdir -p "$HOME/.codex"; printf '{"OPENAI_API_KEY":"%s"}\n' "$k" >"$HOME/.codex/auth.json"; chmod 644 "$HOME/.codex/auth.json"
fi
EOF
chmod +x "$H/.local/bin/codex"
# sk [VAR=value]...: the action as the hermetic agent, stdin from $T/in;
# output in $T/o
sk() {
  PATH="/usr/local/bin:/usr/bin:/bin" in_orc SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$ME" CODEX_KEY_AGENT_HOME="$H" \
    SNIPPET=do_set_codex_key "$@" <"$T/in" >"$T/o" 2>&1
}
auth="$H/.codex/auth.json"

# --- 1. stdin -------------------------------------------------------------------------------------
printf 'OPENAI_API_KEY=%s\n# note\nexport OPENAI_API_KEY="%s"\n' "$OLD" "$KEY" >"$T/in"
sk CODEX_KEY_STDIN=1 OPENAI_API_KEY="$ENVKEY"; rc=$?
[[ $rc -eq 0 ]] && grep -q "\"$KEY\"" "$auth" && [[ "$(stat -c '%a %U' "$auth")" == "600 $ME" ]] &&
  grep -q "OK codex is logged in with an API key for $ME" "$T/o" &&
  pass "1: codex got the last OPENAI_API_KEY= line on stdin; auth.json 600, owned by the agent" || fail "1: stdin (rc=$rc): $(cat "$T/o")"
grep -q "key read: length=${#KEY} last4=${KEY: -4}" "$T/o" && pass "1: the output names length and last 4 only" || fail "1: mask: $(grep 'key read' "$T/o")"
cp "$T/o" "$T/o.1"

# --- 2. a file --------------------------------------------------------------------------------------
rm -rf "$H/.codex"; printf '%s\n' "$KEY" >"$T/key"; chmod 640 "$T/key"; : >"$T/in"
sk CODEX_KEY_FILE="$T/key"; rc=$?
[[ $rc -eq 0 ]] && grep -q "\"$KEY\"" "$auth" && grep -q "WARN $T/key is readable beyond its owner (mode 640)" "$T/o" &&
  pass "2: CODEX_KEY_FILE: the bare key logged in; a group-readable file is named" || fail "2: file (rc=$rc): $(cat "$T/o")"
cp "$T/o" "$T/o.2"

# --- 3. no leak ---------------------------------------------------------------------------------------
no_leak() { ! grep -qE "$KEY|$OLD|$ENVKEY" "$@"; }
no_leak "$T/o.1" "$T/o.2" "$T/calls.log" && pass "3: no key in the output or codex's argv log (n=2 runs)" ||
  fail "3: leaked: $(grep -lE "$KEY|$OLD|$ENVKEY" "$T/o.1" "$T/o.2" "$T/calls.log")"
[[ "$(grep -c '^codex login --with-api-key key-in-env=$' "$T/calls.log")" == 2 && "$(grep -c . "$T/calls.log")" == 2 ]] &&
  pass "3: codex ran twice, only 'login --with-api-key', never with a key in its env" || fail "3: calls: $(cat "$T/calls.log")"
{ cat "$T/o.1"; echo "key $KEY"; } >"$T/o.planted"
no_leak "$T/o.planted" && fail "3: CONTROL: the planted echo was NOT caught" || pass "3: CONTROL: the leak check catches a planted echo"

# --- 4. controls ---------------------------------------------------------------------------------------
rm -rf "$H/.codex"; n0="$(grep -c . "$T/calls.log")"
printf '%s\n' "$KEY" >"$T/in"; sk; rc=$?
[[ $rc -ne 0 && ! -e "$auth" ]] && grep -q 'stdin is not a terminal' "$T/o" &&
  pass "4: CONTROL: a non-tty stdin with no CODEX_KEY_FILE / CODEX_KEY_STDIN is refused" || fail "4: no tty (rc=$rc): $(cat "$T/o")"
printf 'short\n' >"$T/in"; sk CODEX_KEY_STDIN=1; rc=$?
[[ $rc -ne 0 && ! -e "$auth" ]] && grep -q 'is not 16..256 characters' "$T/o" &&
  pass "4: CONTROL: a 5-character key is refused, nothing written" || fail "4: short (rc=$rc): $(cat "$T/o")"
mv "$H/.local/bin/codex" "$T/codex.off"; printf '%s\n' "$KEY" >"$T/in"; sk CODEX_KEY_STDIN=1; rc=$?
[[ $rc -ne 0 && ! -e "$auth" ]] && grep -q 'no-codex-binary-run-do_install_openai_codex' "$T/o" && no_leak "$T/o" &&
  pass "4: CONTROL: no codex on the box: refused, named, nothing written" || fail "4: no codex (rc=$rc): $(cat "$T/o")"
[[ "$(grep -c . "$T/calls.log")" == "$n0" ]] && pass "4: no refused run called codex" || fail "4: codex ran: $(tail -n2 "$T/calls.log")"

echo "---"; [[ $fails -eq 0 ]] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
