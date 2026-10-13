#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_local_hub_owner_add seats the local hub's owner with a
# password read ONLY from the terminal (owner rule: passphrases on the tty).
#   1. a non-tty stdin is refused before anything runs: /dev/null, a pipe
#   2. on a pty, DRY_RUN (default) asks nothing and calls no compose
#   3. on a pty, DRY_RUN=0: the password reaches the hub CLI on STDIN only
#      (never argv), as biz_owner with --password-stdin; the OK line names
#      neither the tenant nor the email
#      a re-run (the human existed) says the old password was KEPT
#   4. two different passwords, or a short one: refused, no compose call
#   5. no LOCAL_HUB_OWNER_EMAIL: refused; not the hub user: re-run as it
# Hermetic: every spl_local_hub_* / lde_compose call is a stub; no docker.
# The pty comes from util-linux `script` (SKIP without it).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

PW='a-throwaway-pass-123'
# the stubs, sourced by the runner after the orc funcs
cat >"$T/stubs.sh" <<'EOF'
spl_local_hub_cnf() { echo CNF-REACHED >>"$T/calls"; }
spl_local_hub_is_user() { [[ "${STUB_NOT_USER:-0}" == 0 ]]; }
spl_local_hub_reexec() { echo "REEXEC $1" >>"$T/calls"; }
spl_local_hub_env() { LOCAL_HUB_TENANT=ws-throwaway LOCAL_HUB_OWNER_EMAIL="${STUB_EMAIL-owner@example.com}" LOCAL_HUB_CONFIG=/x/local-hub.env LOCAL_HUB_WUI_PORT=3180; }
lde_compose() { printf "%s\n" "$*" >"$T/compose.args"; cat >"$T/compose.stdin"; echo '{"created_human":'"${STUB_CREATED:-true}"',"human_id":"HUM-1","status":"provisioned","tenant":"ws-throwaway","email":"owner@example.com"}'; }
EOF

# the runner: source every orc func, then the stubs, then the action
cat >"$T/run.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" T="$T"
do_log() { echo "\$*"; }
for f in "$PROJ_ROOT"/lib/bash/funcs/*.func.sh "$PROJ_ROOT"/src/bash/run/*.func.sh; do source "\$f"; done
source "$T/stubs.sh"
do_spl_local_hub_owner_add
echo "RC=\$?"
EOF
chmod +x "$T/run.sh"
export T

reset() { rm -f "$T/calls" "$T/compose.args" "$T/compose.stdin"; }

# --- 1. non-tty stdin refused ---------------------------------------------------
reset
DRY_RUN=0 "$T/run.sh" </dev/null >"$T/s1.out" 2>&1
grep -q 'RC=1' "$T/s1.out" && grep -q 'terminal only' "$T/s1.out" && [[ ! -e "$T/calls" ]] \
  && pass "stdin </dev/null: refused before any step" || fail "/dev/null: $(tail -2 "$T/s1.out"), calls: $(cat "$T/calls" 2>/dev/null)"
reset
printf '%s\n%s\n%s\n' Name "$PW" "$PW" | DRY_RUN=0 "$T/run.sh" >"$T/s1b.out" 2>&1
grep -q 'RC=1' "$T/s1b.out" && grep -q 'terminal only' "$T/s1b.out" && [[ ! -e "$T/calls" && ! -e "$T/compose.args" ]] \
  && pass "a piped password: refused, nothing reaches compose" || fail "pipe: $(tail -2 "$T/s1b.out")"

if ! command -v script >/dev/null 2>&1; then
  skip "no util-linux script: the pty checks 2-5 need one"
  echo "fails=$fails"; exit $((fails > 0))
fi

# on_pty <input> <env...> -- run the action on a fresh pty, typing <input>
# line k only once prompt k is on the screen, as a person would: input
# buffered before `read -s` turns echo off would be echoed by the pty, which
# no typist does. A prompt that never comes (a refusal) ends the typing.
PROMPTS=('display name' 'type the password here' 'type it again')
on_pty() {
  local input="$1" out="$T/pty.out"; shift
  : >"$out"
  { local k=0 line i
    while IFS= read -r line; do
      for ((i = 0; i < 100; i++)); do grep -qF -- "${PROMPTS[k]:-}" "$out" && break; sleep 0.1; done
      sleep 0.2; printf '%s\n' "$line"; k=$((k + 1))
    done <<<"$input"
    sleep 0.5; } |
    env "$@" script -qfec "$T/run.sh" /dev/null >"$out" 2>&1
  tr -d '\r' <"$out"
}

# --- 2. DRY_RUN on a pty --------------------------------------------------------
reset
on_pty '' >"$T/s2.out"
grep -q 'OK DRY_RUN would ask' "$T/s2.out" && grep -q 'RC=0' "$T/s2.out" && [[ ! -e "$T/compose.args" ]] \
  && pass "DRY_RUN (default): asks nothing, no compose call" || fail "dry run: $(tail -3 "$T/s2.out")"

# --- 3. the real path: password on STDIN only ------------------------------------
reset
on_pty "FirstName LastName
$PW
$PW
" DRY_RUN=0 >"$T/s3.out"
if grep -q 'RC=0' "$T/s3.out" && [[ -e "$T/compose.args" ]]; then
  pass "DRY_RUN=0 on a pty: the hub CLI is called"
  [[ "$(cat "$T/compose.stdin")" == "$PW" ]] && pass "the password reaches the CLI on STDIN" || fail "CLI stdin: '$(cat "$T/compose.stdin")'"
  grep -qF -- "$PW" "$T/compose.args" && fail "the password is in the CLI argv" || pass "the password is not in argv"
  a="$(cat "$T/compose.args")"
  [[ "$a" == "exec -T hub /usr/local/bin/spool hub-provision-member --tenant ws-throwaway --email owner@example.com --name FirstName LastName --role biz_owner "*"--password-stdin" ]] \
    && pass "exec in the hub container: biz_owner, --password-stdin" || fail "CLI args: $a"
  ok="$(grep '^OK owner seated' "$T/s3.out")"
  [[ -n "$ok" && "$ok" != *ws-throwaway* && "$ok" != *owner@example.com* && "$ok" == *HUM-1* ]] \
    && pass "the OK line names neither tenant nor email" || fail "OK line: '$ok'"
  grep -qF -- "$PW" "$T/s3.out" && fail "the password was echoed to the terminal output" || pass "the password is never echoed"
else
  fail "real path: $(tail -4 "$T/s3.out")"
fi

# --- 3b. a re-run: the CLI keeps the old password; the action must say so ----------
reset
on_pty "N
$PW
$PW
" DRY_RUN=0 STUB_CREATED=false >"$T/s3b.out"
grep -q 'existing password was KEPT' "$T/s3b.out" && ! grep -q '^OK owner seated' "$T/s3b.out" && grep -q 'RC=0' "$T/s3b.out" \
  && pass "an owner that already existed: no claim the password changed" || fail "re-run: $(tail -3 "$T/s3b.out")"

# --- 4. mismatch / short -------------------------------------------------------------
reset
on_pty "N
$PW
${PW}x
" DRY_RUN=0 >"$T/s4.out"
grep -q 'passwords differ' "$T/s4.out" && [[ ! -e "$T/compose.args" ]] && pass "two different passwords: refused, no compose call" || fail "mismatch: $(tail -3 "$T/s4.out")"
reset
on_pty "N
short
short
" DRY_RUN=0 >"$T/s4b.out"
grep -q 'at least 12 characters' "$T/s4b.out" && [[ ! -e "$T/compose.args" ]] && pass "a short password: refused" || fail "short: $(tail -3 "$T/s4b.out")"

# --- 5. no owner email; not the hub user ---------------------------------------------
reset
on_pty '' DRY_RUN=0 STUB_EMAIL= >"$T/s5.out"
grep -q 'no LOCAL_HUB_OWNER_EMAIL' "$T/s5.out" && [[ ! -e "$T/compose.args" ]] && pass "no owner email: refused" || fail "no email: $(tail -3 "$T/s5.out")"
reset
on_pty '' STUB_NOT_USER=1 >"$T/s5b.out"
grep -q 'REEXEC do_spl_local_hub_owner_add' "$T/calls" && [[ ! -e "$T/compose.args" ]] && pass "not the hub user: re-runs as it" || fail "reexec: $(cat "$T/calls" 2>/dev/null)"

echo "fails=$fails"
exit $((fails > 0))
