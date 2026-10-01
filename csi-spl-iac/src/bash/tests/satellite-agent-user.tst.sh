#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: satellite-agent-user.sh (do_satellite_agent_user, CLE-77911) against
#          stubbed system commands - no user, group or ACL of this box is touched.
#   1. the dry run plans every missing part and changes nothing
#   2. DRY_RUN=0 makes the group, the user (fixed uid, data-disk home), the
#      groups, linger and the spool root
#   3. a second run is all OK (idempotent)
#   4. a user with another uid, or a taken uid, is a FAIL, never a rewrite
#   5. the action sends the script over the satellite ssh with its env, and
#      refuses to run without SPOOL_AGENT_USER (no default user name)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_PATH=$(cd "$TEST_DIR/../../.." && pwd)
SCRIPT="$PROJ_PATH/src/bash/scripts/satellite-agent-user.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
F="$T/fake"; B="$T/bin"; mkdir -p "$F"/{groups,users,uids,members,linger} "$B" "$T/spool"
w() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$B/$1"; chmod +x "$B/$1"; }
w getent 'case "$1" in group) [ -e "$F/groups/$2" ] ;; passwd) [ -e "$F/uids/$2" ] && echo "$(cat "$F/uids/$2"):x:$2" ;; esac'
w id 'case "$1" in -un) echo debian ;; -u) cat "$F/users/$2" ;; -nG) cat "$F/members/$2" 2>/dev/null; [ -e "$F/members/$2" ] || [ -e "$F/users/$2" ] || [ "$2" = debian ] ;; *) [ -e "$F/users/$1" ] ;; esac'
w groupadd 'touch "$F/groups/$1"; echo "groupadd $*" >>"$F/calls"'
w useradd 'u="${@: -1}"; uid="$2"; echo "$uid" >"$F/users/$u"; echo "$u" >"$F/uids/$uid"; echo "useradd $*" >>"$F/calls"'
w usermod 'echo " $2" >>"$F/members/$3"; echo "usermod $*" >>"$F/calls"'
w loginctl 'touch "$F/linger/$2"; echo "loginctl $*" >>"$F/calls"'
w mountpoint 'exit 0'
w chown 'echo "$1" >"$F/owner"'
w setfacl 'touch "$F/acl"'
w getfacl '[ -e "$F/acl" ] && echo "default:group::rwx"'
w stat '[ -e "$F/owner" ] && echo "$(cat "$F/owner") $(command -p stat -c %a "${@: -1}")"'
run() { env PATH="$B:$PATH" F="$F" SUDO="" AGENT_USER=agentx LINGER_DIR="$F/linger" SPOOL_ROOT="$T/spool/root" "$@" bash "$SCRIPT" 2>&1; }

# --- 1. dry run -----------------------------------------------------------------
out=$(run DRY_RUN=1); rc=$?
[[ $rc -eq 0 && "$(grep -c ' PLAN ' <<<"$out")" == 7 && ! -e "$F/calls" && ! -e "$T/spool/root" ]] &&
  pass "1. the dry run plans group, user, 3 group memberships, linger, spool root and changes nothing" || fail "1. rc=$rc: $out"

# --- 2. apply -------------------------------------------------------------------
out=$(run DRY_RUN=0); rc=$?
[[ $rc -eq 0 && "$(grep -c ' CHANGED ' <<<"$out")" == 7 ]] &&
  grep -q 'useradd -u 1001 -m -d /mnt/data/home/agentx -s /bin/bash agentx' "$F/calls" &&
  [[ "$(cat "$F/owner")" == debian:spool-agents && "$(command -p stat -c %a "$T/spool/root")" == 2770 ]] &&
  pass "2. DRY_RUN=0 makes every part: uid 1001, data-disk home, spool root debian:spool-agents 2770" || fail "2. rc=$rc: $out $(cat "$F/calls" 2>&1)"

# --- 3. idempotent ----------------------------------------------------------------
: >"$F/calls"
out=$(run DRY_RUN=0); rc=$?
[[ $rc -eq 0 && "$(grep -c ' OK ' <<<"$out")" == 7 && ! -s "$F/calls" ]] &&
  pass "3. a second run is all OK and calls nothing" || fail "3. rc=$rc: $out"

# --- 4. refusals -----------------------------------------------------------------
echo 1500 >"$F/users/agentx"
out=$(run DRY_RUN=0); rc=$?
[[ $rc -ne 0 && "$out" == *"exists with uid 1500, not 1001"* ]] && pass "4. an agent user with another uid is a FAIL" || fail "4. rc=$rc: $out"
rm -f "$F/users/agentx"; echo someone >"$F/uids/1001"
out=$(run DRY_RUN=0); rc=$?
[[ $rc -ne 0 && "$out" == *"uid 1001 is taken by someone"* ]] && pass "4. a taken uid is a FAIL, never a second user" || fail "4. rc=$rc: $out"

# --- 5. the action ----------------------------------------------------------------
w ssh 'echo "ARGS $*"; cat >/dev/null'
out=$(env PATH="$B:$PATH" PROJ_PATH="$PROJ_PATH" DRY_RUN=1 SPOOL_AGENT_USER=agentx bash -c '
  do_log() { echo "$*"; }; do_satellite_ssh_opts() { SATELLITE_SSH=(satellite); }
  source "$PROJ_PATH/src/bash/run/satellite-agent-user.func.sh"; do_satellite_agent_user' 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"ARGS satellite DRY_RUN='1' AGENT_USER='agentx' AGENT_UID='1001' SPOOL_GROUP='spool-agents' bash -s"* && "$out" == *"DRY_RUN nothing was changed"* ]] &&
  pass "5. the action pipes the script over the satellite ssh, a dry run by default" || fail "5. rc=$rc: $out"

out=$(env PATH="$B:$PATH" PROJ_PATH="$PROJ_PATH" bash -c '
  do_log() { echo "$*"; }; do_satellite_ssh_opts() { SATELLITE_SSH=(satellite); }
  source "$PROJ_PATH/src/bash/run/satellite-agent-user.func.sh"; do_satellite_agent_user' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"SPOOL_AGENT_USER must be set"* && "$out" != *ARGS* ]] &&
  pass "5. without SPOOL_AGENT_USER the action refuses before any ssh" || fail "5. rc=$rc: $out"
out=$(env PATH="$B:$PATH" F="$F" SUDO="" bash "$SCRIPT" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"AGENT_USER / AGENT_UID malformed"* ]] && pass "5. the script refuses an empty AGENT_USER" || fail "5. rc=$rc: $out"

echo
(( fails == 0 )) && { echo "PASS: all satellite-agent-user.tst.sh assertions"; exit 0; }
echo "FAIL: $fails satellite-agent-user.tst.sh assertion(s)"; exit 1
