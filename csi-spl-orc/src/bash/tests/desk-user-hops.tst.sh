#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the ./run hops of the agent scripts follow the desk user (spec 069
# section 8.5, row B3). asks.sh, lane-map.sh, lane-issue.inc.sh (li_hub_read,
# li_desk_hop, the printed end commands) and spawn-window.sh's issue hop run
# their ./run action as spool_desk_user (SPOOL_DESK_USER, else
# SPOOL_BOX_USER), with that user's HOME, whose state dir holds the desks.
#   1. unset: the hop is today's, to SPOOL_BOX_USER with its HOME (nothing
#      changes on a box without the key)
#   2. SPOOL_DESK_USER = the caller: no sudo at all, the action runs as the
#      caller. RED CONTROL: the code before B3 still hops to SPOOL_BOX_USER
#      (the stub sudo is called)
#   3. SPOOL_DESK_USER = another user (env, or the box env file): the hop goes
#      to that user with THAT user's HOME, not the box user's
#   4. lane-issue.inc.sh in a ./run action (no spool-env): spl_desk_user's box
#      env read decides; the printed end/landed commands name the desk user
# The scripts run from a sandbox copy of the feature tree, so their default
# orc (<copy>/run, a stub that logs its user and HOME) is the one called and
# the hop is the real one. sudo is a stub that logs its arguments and exits 99;
# getent is a stub over two sandbox users. Nothing outside $T is read.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FEAT="$PROJ_ROOT/src/bash/features/spawn-agents"
CNFLIB="$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
ME="$(id -un)"
BU=t-box-user DU=t-desk-user
BH="$T/home-box" DH="$T/home-desk" MH="$T/home-me"

# The sandbox orc: <O>/run and the feature tree at its real depth below it.
O="$T/orc"
mkdir -p "$O/src/bash/features/spawn-agents/scripts" "$O/src/bash/scripts" "$T/stub" "$T/spool" "$BH" "$DH" "$MH"
cp -r "$FEAT/lib" "$O/src/bash/features/spawn-agents/"
cp "$FEAT/scripts/asks.sh" "$FEAT/scripts/lane-map.sh" "$O/src/bash/features/spawn-agents/scripts/"
[ -d "$PROJ_ROOT/lib" ] && cp -r "$PROJ_ROOT/lib" "$O/"
cat >"$O/run" <<EOF2
#!/usr/bin/env bash
echo "RUN user=\$(id -un) HOME=\$HOME \$*" >>"$T/calls"
EOF2
cat >"$T/stub/sudo" <<EOF2
#!/usr/bin/env bash
echo "SUDO \$*" >>"$T/calls"
exit 99
EOF2
cat >"$T/stub/getent" <<EOF2
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $BU) echo "$BU:x:5001:5001::$BH:/bin/sh" ;;
  $DU) echo "$DU:x:5002:5002::$DH:/bin/sh" ;;
  $ME) echo "$ME:x:5003:5003::$MH:/bin/sh" ;;
  *) exit 2 ;;
esac
EOF2
chmod +x "$O/run" "$T/stub/sudo" "$T/stub/getent"
: >"$T/box.env.none"
printf 'SPOOL_DESK_USER=%s\n' "$DU" >"$T/box.env.desk"
printf 'SPOOL_DESK_USER=%s\n' "$ME" >"$T/box.env.me"

SC="$O/src/bash/features/spawn-agents/scripts"
LI="$O/src/bash/features/spawn-agents/lib/lane-issue.inc.sh"
# run_as <box env file> <cmd...>: the box user is BU; EXTRA adds env. Prints
# the calls log (the stub sudo's and the stub run's lines).
run_as() {
  local benv="$1"; shift
  : >"$T/calls"
  env -u SPOOL_DESK_USER -u ASKS_ORC -u LANE_MAP_ORC -u LI_HUB_STATUS_CMD PATH="$T/stub:$PATH" \
    SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$benv" SPOOL_BOX_USER="$BU" HOME="$MH" "${EXTRA[@]}" "$@" >/dev/null 2>&1
  cat "$T/calls"
}
# li <box env file> <code>: lane-issue.inc.sh sourced the way spawn-window.sh
# and the ./run actions source it (SPOOL_TEST unset: li_hub_read needs it so).
li() {
  local benv="$1"; shift
  EXTRA+=(SPOOL_TEST=0); run_as "$benv" bash -c '. "$1"; shift; eval "$1"' _ "$LI" "$@"
}
has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: $3)"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: $3)"; }

hop_box="SUDO -n -u $BU env HOME=$BH "
hop_desk="SUDO -n -u $DU env HOME=$DH "
for s in asks lane-map; do
  case "$s" in asks) args=(open) ;; lane-map) args=(list) ;; esac
  # 1. unset
  EXTRA=(SPOOL_TEST=1)
  out="$(run_as "$T/box.env.none" bash "$SC/$s.sh" "${args[@]}")"
  has "1. $s.sh unset: the hop is today's, to SPOOL_BOX_USER with its HOME" "$hop_box" "$out"
  hasnt "1. $s.sh unset: ... and not to the desk user" "-u $DU" "$out"
  # 2. desk user = the caller
  EXTRA=(SPOOL_TEST=1 SPOOL_DESK_USER="$ME")
  out="$(run_as "$T/box.env.none" bash "$SC/$s.sh" "${args[@]}")"
  hasnt "2. $s.sh desk user = caller: no sudo" "SUDO" "$out"
  has "2. $s.sh desk user = caller: the action runs as the caller" "RUN user=$ME HOME=$MH -a do_spl_" "$out"
  EXTRA=(SPOOL_TEST=1)
  out="$(run_as "$T/box.env.me" bash "$SC/$s.sh" "${args[@]}")"
  hasnt "2. $s.sh desk user = caller in the box env file: no sudo" "SUDO" "$out"
  # 3. another desk user
  EXTRA=(SPOOL_TEST=1 SPOOL_DESK_USER="$DU")
  out="$(run_as "$T/box.env.none" bash "$SC/$s.sh" "${args[@]}")"
  has "3. $s.sh desk user set: the hop goes to the desk user with ITS HOME" "$hop_desk" "$out"
  EXTRA=(SPOOL_TEST=1)
  out="$(run_as "$T/box.env.desk" bash "$SC/$s.sh" "${args[@]}")"
  has "3. $s.sh desk user in the box env file: the same hop" "$hop_desk" "$out"
done

# lane-issue.inc.sh
EXTRA=()
out="$(li "$T/box.env.none" 'li_hub_read SPL-1')"
has "1. li_hub_read unset: the hop is today's" "${hop_box}env ISSUE_REF=SPL-1" "$out"
EXTRA=(SPOOL_DESK_USER="$ME")
out="$(li "$T/box.env.none" 'li_hub_read SPL-1')"
hasnt "2. li_hub_read desk user = caller: no sudo" "SUDO" "$out"
has "2. li_hub_read desk user = caller: the read runs as the caller" "RUN user=$ME HOME=$MH -a do_spl_issue_status" "$out"
EXTRA=(SPOOL_DESK_USER="$DU")
out="$(li "$T/box.env.none" 'li_hub_read SPL-1')"
has "3. li_hub_read desk user set: the hop goes to the desk user" "${hop_desk}env ISSUE_REF=SPL-1" "$out"
# li_desk_hop is spawn-window.sh's issue hop: the array itself, checked direct.
got="$(env -u SPOOL_DESK_USER PATH="$T/stub:$PATH" SPOOL_BOX_USER="$BU" SPOOL_DESK_USER="$DU" bash -c '. "$1"; li_desk_hop h; printf "%s|" "${h[@]}"' _ "$LI")"
[[ "$got" == "sudo|-n|-u|$DU|env|HOME=$DH|" ]] && pass "3. li_desk_hop (spawn-window's issue hop): sudo -n -u <desk user> env HOME=<its home>" || fail "3. li_desk_hop: got '$got'"
got="$(env -u SPOOL_DESK_USER PATH="$T/stub:$PATH" SPOOL_BOX_USER="$BU" bash -c '. "$1"; li_desk_hop h; printf "%s|" "${h[@]}"' _ "$LI")"
[[ "$got" == "sudo|-n|-u|$BU|env|HOME=$BH|" ]] && pass "1. li_desk_hop unset: today's hop to SPOOL_BOX_USER" || fail "1. li_desk_hop unset: got '$got'"
got="$(env -u SPOOL_DESK_USER PATH="$T/stub:$PATH" SPOOL_BOX_USER="$BU" SPOOL_DESK_USER="$ME" bash -c '. "$1"; li_desk_hop h; printf "%s" "${#h[@]}"' _ "$LI")"
[[ "$got" == 0 ]] && pass "2. li_desk_hop desk user = caller: no hop" || fail "2. li_desk_hop desk user = caller: ${got} words"

# 4. a ./run action: spl-cloud-cnf.func.sh loaded, the key only in the box env.
rn() {  # <box env file> <code>
  env -u SPOOL_DESK_USER PATH="$T/stub:$PATH" SPOOL_TEST=1 SPOOL_BOX_ENV="$1" SPOOL_BOX_USER="$BU" bash -c '
    do_log() { echo "$*" >&2; }; . "$1"; . "$2"; eval "$3"' _ "$CNFLIB" "$LI" "$2" 2>/dev/null
}
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }
eq "4. ./run, key in the box env: li_desk_user is the desk user" "$DU" "$(rn "$T/box.env.desk" li_desk_user)"
eq "4. ./run, no key: li_desk_user is SPOOL_BOX_USER" "$BU" "$(rn "$T/box.env.none" li_desk_user)"
has "4. the printed end command names the desk user" "sudo -u $DU env AGENT_ID=c-1 LANE_ISSUE_OP=end" "$(rn "$T/box.env.desk" 'li_end_cmd c-1')"
has "4. the printed landed command names the desk user" "sudo -u $DU env AGENT_ID=c-1 LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done" "$(rn "$T/box.env.desk" 'li_landed_cmd c-1')"
has "1. the printed end command, no key: SPOOL_BOX_USER as before" "sudo -u $BU env AGENT_ID=c-1" "$(rn "$T/box.env.none" 'li_end_cmd c-1')"
has "1. no user known: the placeholder as before" "sudo -u <box user> env" "$(env -u SPOOL_DESK_USER -u SPOOL_BOX_USER bash -c '. "$1"; li_end_cmd c-1' _ "$LI")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
