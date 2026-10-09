#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y11 - the pkill / killall guard for the agent user.
#   1. the step installs pkill and killall into a sandbox bin, ahead of a stub
#      "real" bin on PATH (the stubs record their argv, exit 0)
#   2. pkill -f, --full, a cluster (-fx), -f after the pattern and every killall
#      are refused: exit 2, the one line, the stub never runs
#   3. a safe form (pkill -x <name>, pkill -u <user> <name>) reaches the stub
#      with its argv unchanged and its exit code
#   4. idempotent: a re-run says current; a file in the way that is not ours is
#      left alone (return 7)
#   5. skipped for a user that is not the agent user, without --fleet, and with
#      SPOOL_INSTALL_KILL_GUARD=0; the agent user is read from the box config
#   6. install.sh calls the step exactly once
# With the wrapper absent every refusal case FAILS: the stub answers exit 0.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
STEP="$FEAT/steps/y11-kill-guard.sh"
REFUSED="refused: pattern kills hit every agent seat; stop a process by its own pid or its ./run stop action"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ME="$(id -un)"

mkdir -p "$T/real" "$T/bin"
for b in pkill killall; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/%s.argv"\nexit 0\n' "$T" "$b" >"$T/real/$b"
  chmod 755 "$T/real/$b"
done

# 1. install
out="$(env -u SPOOL_INSTALL_KILL_GUARD SPOOL_AGENT_USER="$ME" bash -c '. "$1"; spool_install_kill_guard "$2" 0 1' _ "$STEP" "$T/bin" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -x "$T/bin/pkill" ] && [ -x "$T/bin/killall" ]; then pass "installs pkill and killall"
else fail "install rc=$rc: $out"; fi

# guard <name> <args...>: run it as an agent shell would, sandbox bin first.
guard() { local b="$1"; shift; PATH="$T/bin:$T/real:/usr/bin:/bin" "$b" "$@"; }

# 2. refusals
refused() {
  local label="$1"; shift
  rm -f "$T"/*.argv
  local o r
  o="$(guard "$@" 2>&1)"; r=$?
  if [ "$r" = 2 ] && [ "$o" = "$REFUSED" ] && ! ls "$T"/*.argv >/dev/null 2>&1; then pass "refused: $label"
  else fail "$label: rc=$r out='$o'"; fi
}
refused "pkill -f"                 pkill -f "git push"
refused "pkill --full"             pkill --full "git push"
refused "pkill --fu (prefix)"       pkill --fu "git push"
refused "pkill -fx cluster"        pkill -fx "git"
refused "pkill -9 -f"              pkill -9 -f spool
refused "pkill pattern then -f"    pkill spool -f
refused "killall bare name"        killall claude
refused "killall -9"               killall -9 bash

# 3. pass-through
passed() {
  local label="$1" want="$2"; shift 2
  rm -f "$T"/*.argv
  local o r
  o="$(guard "$@" 2>&1)"; r=$?
  if [ "$r" = 0 ] && [ "$(cat "$T/pkill.argv" 2>/dev/null)" = "$want" ]; then pass "passed through: $label"
  else fail "$label: rc=$r out='$o' argv='$(cat "$T/pkill.argv" 2>/dev/null)'"; fi
}
passed "pkill -x name"      "-x my-proc"        pkill -x my-proc
passed "pkill -u user name" "-u fred my-proc"   pkill -u fred my-proc
passed "pkill -ufoo (value, no -f)" "-ufoo bar"  pkill -ufoo bar
passed "pkill -- -f as pattern" "-- -f"         pkill -- -f

# 4. idempotent; a file not ours
out="$(SPOOL_AGENT_USER="$ME" bash -c '. "$1"; spool_install_kill_guard "$2" 0 1' _ "$STEP" "$T/bin" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c 'already current' <<<"$out")" = 2 ]; then pass "re-run: already current"
else fail "re-run rc=$rc: $out"; fi
mkdir -p "$T/other"; echo '#!/bin/sh' >"$T/other/pkill"
SPOOL_AGENT_USER="$ME" bash -c '. "$1"; spool_install_kill_guard "$2" 0 1' _ "$STEP" "$T/other" >/dev/null 2>&1; rc=$?
if [ "$rc" = 7 ] && [ "$(cat "$T/other/pkill")" = '#!/bin/sh' ]; then pass "a pkill not ours: left alone, rc 7"
else fail "not-ours rc=$rc"; fi

# 5. skips
skip_case() {
  local label="$1" dir="$T/skip-$2"; shift 2
  env "$@" bash -c '. "$1"; spool_install_kill_guard "$2" 0 "$3"' _ "$STEP" "$dir" "${FLEET_ARG:-1}" >/dev/null 2>&1
  if [ ! -e "$dir/pkill" ]; then pass "skipped: $label"; else fail "installed although $label"; fi
}
skip_case "not the agent user" a SPOOL_AGENT_USER="not-$ME"
FLEET_ARG=0 skip_case "no --fleet" b SPOOL_AGENT_USER="$ME"
skip_case "SPOOL_INSTALL_KILL_GUARD=0" c SPOOL_AGENT_USER="$ME" SPOOL_INSTALL_KILL_GUARD=0
skip_case "no agent user anywhere" d -u SPOOL_AGENT_USER SPOOL_BOX_ENV="$T/none.env"
printf 'SPOOL_AGENT_USER=not-%s\n' "$ME" >"$T/other.env"
skip_case "box config names another user" e -u SPOOL_AGENT_USER SPOOL_BOX_ENV="$T/other.env"
printf 'SPOOL_BOX_TAG=x\nSPOOL_AGENT_USER=%s\n' "$ME" >"$T/me.env"
env -u SPOOL_AGENT_USER SPOOL_BOX_ENV="$T/me.env" bash -c '. "$1"; spool_install_kill_guard "$2" 0 1' _ "$STEP" "$T/skip-f" >/dev/null 2>&1
if [ -x "$T/skip-f/pkill" ]; then pass "agent user read from the box config"; else fail "box config agent user not honoured"; fi

# 6. wired once
c="$(grep -c 'spool_install_kill_guard "$BIN" "$DRY" "$FLEET"' "$FEAT/install.sh")"
if [ "$c" = 1 ]; then pass "install.sh calls the step once"; else fail "install.sh calls the step $c times"; fi

echo "test-y11-kill-guard: $((n - fails))/$n passed"
[ "$fails" = 0 ]
