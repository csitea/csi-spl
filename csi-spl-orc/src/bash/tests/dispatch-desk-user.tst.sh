#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 069 row B8. The desk commands a dispatcher brief teaches
#          (spl_dispatch_reply_cmd, spl_dispatch_take_cmd) and the allow rules
#          its settings carry (spl_dispatch_settings_json) run as the DESK
#          user, not the box user. Sandbox box.env under SPOOL_TEST=1; nothing
#          live is read or written.
#   1. no desk user: today's commands and rules, `sudo -u <box user> env ...`
#   2. desk user B in the box config: `sudo -u B env ...`, the rules name B,
#      the taught reply and take match a rule; DISPATCH_DESK_USER names it too
#   3. desk user = the seat's own user: no sudo in the commands or the rules,
#      and the taught reply and take still match a rule
#   RED CONTROL: the pre-B8 functions (a planted copy, `sudo -u
#      $DISPATCH_BOX_USER`) fail case 2
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

SETUP="$PROJ_ROOT/src/bash/run/spl-dispatch-setup.func.sh"
printf 'SPOOL_AGENT_USER=agentu\n' >"$T/box-unset.env"
printf 'SPOOL_AGENT_USER=agentu\nSPOOL_DESK_USER=deskb\n' >"$T/box-deskb.env"
printf 'SPOOL_AGENT_USER=agentu\nSPOOL_DESK_USER=agentu\n' >"$T/box-agent.env"

# run <setup file> <box env> [VAR=val...]: prints reply, take, the two
# allow verdicts, then the settings
run() {
  local f="$1" be="$2"; shift 2
  env -i PATH="$PATH" PROJ_PATH="$PROJ_ROOT" SPOOL_TEST=1 SPOOL_BOX_ENV="$be" \
    DISPATCH_BOX_USER=boxuser SPOOL_AGENT_USER=agentu ENV=prd T="$T" F="$f" "$@" bash -c '
    source "$F"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-check.func.sh"
    spl_dispatch_settings_json c-002 >"$T/settings.json"
    r="$(spl_dispatch_reply_cmd c-002)"; k="$(spl_dispatch_take_cmd c-002)"
    echo "REPLY $r"; echo "TAKE $k"
    spl_dispatch_rule_allows "$T/settings.json" "$r" && echo "REPLY-ALLOWED"
    spl_dispatch_rule_allows "$T/settings.json" "$k" && echo "TAKE-ALLOWED"
    cat "$T/settings.json"' 2>&1
}

# case2 <setup file>: 0 when desk user deskb is what the commands and rules hop to
case2() {
  local o; o="$(run "$1" "$T/box-deskb.env")"
  [[ "$o" == *"REPLY sudo -u deskb env ENV=prd "*"./run -a do_spl_desk_reply"* ]] &&
    [[ "$o" == *"TAKE sudo -u deskb env ENV=prd "* ]] &&
    [[ "$o" == *REPLY-ALLOWED* && "$o" == *TAKE-ALLOWED* ]] &&
    [[ "$o" == *'"Bash(sudo -u deskb env ENV=prd * ./run -a do_spl_unanswered_sweep)"'* ]] &&
    [[ "$o" != *boxuser* ]]
}

# --- 1. no desk user ---------------------------------------------------------
o="$(run "$SETUP" "$T/box-unset.env")"
[[ "$o" == *"REPLY sudo -u boxuser env ENV=prd "* && "$o" == *"TAKE sudo -u boxuser env ENV=prd "* ]] &&
  [[ "$o" == *REPLY-ALLOWED* && "$o" == *TAKE-ALLOWED* ]] &&
  [[ "$o" == *'"Bash(sudo -u boxuser env ENV=prd TENANT_ID=* DESK_AGENT=c-002 * ./run -a do_spl_desk_reply)"'* ]] &&
  pass "1. no desk user: today's sudo -u <box user>, the rules match" || fail "1. unset: $o"

# --- 2. desk user B ----------------------------------------------------------
if case2 "$SETUP"; then pass "2. desk user in the box config: the commands and rules hop to it"
else fail "2. desk user deskb: $(run "$SETUP" "$T/box-deskb.env")"; fi
o="$(run "$SETUP" "$T/box-unset.env" DISPATCH_DESK_USER=deskc)"
[[ "$o" == *"REPLY sudo -u deskc env "* && "$o" == *REPLY-ALLOWED* ]] &&
  pass "2. DISPATCH_DESK_USER names the desk user" || fail "2. DISPATCH_DESK_USER: $o"

# --- 3. desk user = the seat's user -----------------------------------------
o="$(run "$SETUP" "$T/box-agent.env")"
[[ "$o" == *"REPLY env ENV=prd TENANT_ID="* && "$o" == *"TAKE env ENV=prd TENANT_ID="* ]] &&
  [[ "$o" == *REPLY-ALLOWED* && "$o" == *TAKE-ALLOWED* && "$o" != *sudo* ]] &&
  pass "3. desk user = seat user: no sudo, the rules still match" || fail "3. same user: $o"

# --- RED CONTROL: the pre-B8 functions ---------------------------------------
sed -e 's/\$(spl_dispatch_desk_hop)env /sudo -u $DISPATCH_BOX_USER env /' \
  -e 's/hop="\$(spl_dispatch_desk_hop)"/hop="sudo -u $DISPATCH_BOX_USER "/' "$SETUP" >"$T/planted.func.sh"
if cmp -s "$SETUP" "$T/planted.func.sh"; then fail "CONTROL: the plant changed nothing"
elif case2 "$T/planted.func.sh"; then fail "CONTROL: the pre-B8 copy passes case 2"
else pass "CONTROL: the pre-B8 copy (sudo -u \$DISPATCH_BOX_USER) fails case 2"; fi

echo "dispatch-desk-user: $fails failure(s)"
[[ $fails -eq 0 ]]
