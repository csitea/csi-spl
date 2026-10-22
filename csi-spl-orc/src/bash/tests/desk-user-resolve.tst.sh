#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the desk user key and its resolvers (spec 069 section 8.3, row B1).
# SPOOL_DESK_USER names the OS user whose home holds the desks. Unset is
# today's behaviour, so the key lands with no change on any box.
#   1. scripts (spool-env.inc.sh): spool_desk_user / spool_desk_state
#      a. unset: the desk user is SPOOL_BOX_USER and the state root is under
#         that user's home. RED CONTROL: the same call, expected under the
#         desk user's home, FAILS while the key is unset
#      b. set in the environment, or in the box env file: the named user's home
#      c. SPOOL_DESK_USER is a box env key (box-config.sh accepts it)
#      d. a user with no passwd entry: non-zero, nothing printed
#   2. ./run (spl-cloud-cnf.func.sh): spl_desk_state_root
#      a. unset: $SPL_STATE_DIR when it is this ENV's, else
#         $HOME/.local/share/<org>-<app>/cloud/<env> (SPL_STATE_DIR's default).
#         RED CONTROL as in 1a
#      b. set in the environment, or in SPOOL_BOX_ENV: the named user's home
#      c. a user with no passwd entry: return 1
# getent is a stub over two sandbox users; nothing outside $T is read.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ENVINC="$PROJ_ROOT/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
CNFLIB="$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"

BU=t-box-user DU=t-desk-user
BH="$T/home-box" DH="$T/home-desk"
mkdir -p "$T/stub" "$T/spool" "$BH" "$DH"
cat >"$T/stub/getent" <<EOF
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $BU) echo "$BU:x:5001:5001::$BH:/bin/sh" ;;
  $DU) echo "$DU:x:5002:5002::$DH:/bin/sh" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/stub/getent"
: >"$T/box.env.none"
printf 'SPOOL_DESK_USER=%s\n' "$DU" >"$T/box.env.desk"

# sc <box env file> <cmd...>: run cmd with spool-env.inc.sh loaded the way a
# script loads it (spool_env_resolve, so the box env file is read).
sc() {
  local benv="$1"; shift
  env -u SPOOL_DESK_USER PATH="$T/stub:$PATH" SPOOL_TEST=1 SPOOL_ROOT="$T/spool" \
    SPOOL_BOX_ENV="$benv" SPOOL_BOX_USER="$BU" "${EXTRA[@]}" bash -c '
    . "$1"; shift; spool_env_resolve; "$@"' _ "$ENVINC" "$@" 2>/dev/null
}
# rn <box env file> <cmd...>: the same for a ./run action (no spool-env).
rn() {
  local benv="$1"; shift
  env -u SPOOL_DESK_USER -u SPL_STATE_DIR PATH="$T/stub:$PATH" SPOOL_TEST=1 HOME="$BH" \
    PROJ_PATH="$PROJ_ROOT" SPL_ORG_APP="$OA" ENV=dev SPOOL_BOX_ENV="$benv" "${EXTRA[@]}" bash -c '
    do_log() { echo "$*" >&2; }; . "$1"; shift; "$@"' _ "$CNFLIB" "$@" 2>/dev/null
}
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }

# --- 1. scripts ---------------------------------------------------------------
EXTRA=()
eq "1a. unset: the desk user is SPOOL_BOX_USER" "$BU" "$(sc "$T/box.env.none" spool_desk_user)"
eq "1a. unset: the state root is the box user's" "$BH/.local/share/$OA/cloud/dev" "$(sc "$T/box.env.none" spool_desk_state dev)"
got="$(sc "$T/box.env.none" spool_desk_state dev)"
[[ -n "$got" && "$got" != "$DH/.local/share/$OA/cloud/dev" ]] \
  && pass "1a. CONTROL expecting the desk user's home with the key unset fails (got $got)" \
  || fail "1a. CONTROL the unset key already gives the desk user's home"
EXTRA=(SPOOL_DESK_USER="$DU")
eq "1b. set in the env: the desk user" "$DU" "$(sc "$T/box.env.none" spool_desk_user)"
eq "1b. set in the env: the named user's home" "$DH/.local/share/$OA/cloud/prd" "$(sc "$T/box.env.none" spool_desk_state prd)"
EXTRA=()
eq "1b. set in the box env: the named user's home" "$DH/.local/share/$OA/cloud/dev" "$(sc "$T/box.env.desk" spool_desk_state dev)"
eq "1c. SPOOL_DESK_USER is a box env key" 1 "$(sc "$T/box.env.none" eval 'printf "%s\n" $SPOOL_BOX_ENV_KEYS' | grep -cx SPOOL_DESK_USER)"
EXTRA=(SPOOL_DESK_USER=t-no-such-user)
out="$(sc "$T/box.env.none" spool_desk_state dev)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && pass "1d. no passwd entry: refused, nothing printed" || fail "1d. no passwd entry: rc=$rc out='$out'"

# --- 2. ./run -----------------------------------------------------------------
EXTRA=()
eq "2a. unset: \$HOME's state root (SPL_STATE_DIR's default)" "$BH/.local/share/$OA/cloud/dev" "$(rn "$T/box.env.none" spl_desk_state_root dev)"
EXTRA=(SPL_STATE_DIR="$T/state-dev")
eq "2a. unset: SPL_STATE_DIR for this ENV" "$T/state-dev" "$(rn "$T/box.env.none" spl_desk_state_root)"
eq "2a. unset: another env is not SPL_STATE_DIR" "$BH/.local/share/$OA/cloud/prd" "$(rn "$T/box.env.none" spl_desk_state_root prd)"
EXTRA=()
got="$(rn "$T/box.env.none" spl_desk_state_root dev)"
[[ -n "$got" && "$got" != "$DH/.local/share/$OA/cloud/dev" ]] \
  && pass "2a. CONTROL expecting the desk user's home with the key unset fails (got $got)" \
  || fail "2a. CONTROL the unset key already gives the desk user's home"
EXTRA=(SPOOL_DESK_USER="$DU" SPL_STATE_DIR="$T/state-dev")
eq "2b. set in the env: the named user's home" "$DH/.local/share/$OA/cloud/dev" "$(rn "$T/box.env.none" spl_desk_state_root dev)"
EXTRA=()
eq "2b. set in SPOOL_BOX_ENV: the named user's home" "$DH/.local/share/$OA/cloud/prd" "$(rn "$T/box.env.desk" spl_desk_state_root prd)"
EXTRA=(SPOOL_DESK_USER=t-no-such-user)
out="$(rn "$T/box.env.none" spl_desk_state_root dev)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && pass "2c. no passwd entry: return 1, nothing printed" || fail "2c. no passwd entry: rc=$rc out='$out'"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
