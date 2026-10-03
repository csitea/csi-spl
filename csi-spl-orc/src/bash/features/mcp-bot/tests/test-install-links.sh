#!/usr/bin/env bash
# The spool-install step y1_mcp_bot (spec 069 Y1) in a sandbox HOME seeded the
# way the box is today: mcp-start.sh and mcp-start-chrome.sh are symlinks into
# a stand-in for the frozen engine, the base configs are live.
#  - control: before the step, the links do NOT resolve into this feature
#  - DRY=1 prints the plan and changes nothing
#  - the step repoints all three entrypoints into this checkout, keeps the live
#    configs byte-for-byte, seeds a missing one, and a re-run changes nothing
#  - a regular file in the way is left alone and reported (rc 7)
#  - install.sh calls the step exactly once
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
STEP="$T_FEAT/../spool-install/steps/y1-mcp-bot.sh"
INSTALL="$T_FEAT/../spool-install/install.sh"
# shellcheck source=../../spool-install/steps/y1-mcp-bot.sh
. "$STEP"
unset MCP_BOT_HOME DRY SPOOL_INSTALL_MCP_BOT
T_TMP="$(mktemp -d)"; trap 'rm -rf "$T_TMP"' EXIT
export HOME="$T_TMP/home"
MB="$HOME/.local/mcp-bot" ENG="$T_TMP/engine/mcp-bot/scripts"
mkdir -p "$MB/run" "$ENG"
for n in mcp-start.sh mcp-start-chrome.sh; do
  printf '#!/bin/sh\n' >"$ENG/$n"; ln -s "$ENG/$n" "$MB/$n"
done
echo '{"live":"firefox"}' >"$MB/mcp-config.json"

# every entrypoint resolves to a file of this feature's scripts/ dir
into_feature() {
  local n
  for n in mcp-start.sh mcp-start-chrome.sh reap-profiles.sh; do
    [ "$(readlink -f "$MB/$n")" = "$(readlink -f "$T_SCRIPTS/$n")" ] && [ -x "$MB/$n" ] || return 1
  done
}
snap() { find "$HOME" -printf '%p %l %s\n' | sort; }

check "control: the seeded links do not resolve into csi-spl" eval '! into_feature'

before="$(snap)"
plan="$(DRY=1 y1_mcp_bot "$T_FEAT" 2>&1)"
eq "DRY=1 changes nothing" "$before" "$(snap)"
eq "DRY=1 plans three links and one seed" 4 "$(grep -c '^would: ' <<<"$plan")"

y1_mcp_bot "$T_FEAT" 2>"$T_TMP/err"; rc=$?
eq "the step exits 0" 0 "$rc"
check "all three entrypoints resolve into csi-spl" into_feature
eq "no link left into the engine stand-in" "" "$(find "$MB" -maxdepth 1 -lname "$T_TMP/engine/*")"
eq "the live firefox config is kept" '{"live":"firefox"}' "$(cat "$MB/mcp-config.json")"
has "the missing chrome config is seeded with this home" "$MB/cr-profile" "$(cat "$MB/mcp-config-chrome.json")"
has "the repoint is reported with the old target" "(was $ENG/mcp-start.sh)" "$(cat "$T_TMP/err")"

before="$(snap)"
y1_mcp_bot "$T_FEAT" 2>"$T_TMP/err2"; rc=$?
eq "a re-run exits 0" 0 "$rc"
eq "a re-run changes nothing" "$before" "$(snap)"
eq "a re-run reports nothing" "" "$(cat "$T_TMP/err2")"

rm "$MB/reap-profiles.sh"; echo 'mine' >"$MB/reap-profiles.sh"
y1_mcp_bot "$T_FEAT" 2>"$T_TMP/err3"; rc=$?
eq "a regular file in the way: rc 7" 7 "$rc"
eq "the regular file is left alone" mine "$(cat "$MB/reap-profiles.sh")"
has "and reported" "is not a symlink: left alone" "$(cat "$T_TMP/err3")"

eq "SPOOL_INSTALL_MCP_BOT=0 skips the step" 0 "$(SPOOL_INSTALL_MCP_BOT=0 y1_mcp_bot /nonexistent 2>/dev/null; echo $?)"
eq "install.sh calls the step exactly once" 1 "$(grep -c '^\. "\$_here/steps/y1-mcp-bot.sh" && y1_mcp_bot ' "$INSTALL")"
t_done
