#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a desk issue list follows a desk that lives under another user's
# root (SPL-5465). sat's night crons (zombie-topics, reflection) run as the
# crontab user, whose t1 root has no seats; the seats are the agent user's.
# spl_desk_issue_run list then re-runs the page as that user
# (do_spl_issue_list with SPL_ISSUE_RAW_ARGS), so spl_issue_list_fetch pages
# through the hop.
#   1. the desk pinned only under the agent user's root: one hop per page, as
#      that user, carrying the flags; the hopped JSON line is the output.
#      RED CONTROL: before SPL-5465 the read said "FATAL no desk for"
#   2. two pages: two hops, the second carries --cursor
#   3. no root holds the desk: no hop, the "no desk" FATAL as before
#   4. the caller's own pinned desk: no hop, the read runs here
#   5. a get never hops: the "no desk" FATAL, as before
#   6. the hopped side: do_spl_issue_list with SPL_DESK_HOPPED and
#      SPL_ISSUE_RAW_ARGS reads one page with exactly those flags
# The agent user's home is 0700 to the caller, as on sat ($T/hidden, mode
# 000): only the agent user's sudo sees the desk. SPL_DESK_AS_CMD is a stub
# that runs a root's probe on the readable copy ($DH) and logs the hop
# instead of running it, printing AS_OUT<n> for hop n. Nothing outside $T is
# read.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ME="$(id -un)" DU=t-agent-user DH="$T/home-agent" HID="$T/hidden"
has() { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1 (missing '$2' in: $3)"; }
hasnt() { [[ "$3" != *"$2"* ]] && pass "$1" || fail "$1 (unexpected '$2' in: $3)"; }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2', got '$3')"; }

mkdir -p "$T/stub" "$DH" "$HID"
cat >"$T/stub/getent" <<EOF2
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in $DU) echo "$DU:x:5002:5002::$HID:/bin/sh" ;; *) exit 2 ;; esac
EOF2
cat >"$T/as" <<'EOF2'
#!/usr/bin/env bash
[ "$3" = env ] || { shift 2; exec "${@//$AS_HIDDEN/$AS_SEEN}"; }
shift 2
n=$(( $(cat "$AS_LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$AS_LOG.n"
printf 'HOP %s\n' "$*" >>"$AS_LOG"
echo "OK a log line of the hopped ./run"
v="AS_OUT$n"; printf '%s\n' "${!v:-}"
EOF2
chmod +x "$T/stub/getent" "$T/as"
printf 'SPOOL_AGENT_USER=%s\n' "$DU" >"$T/box.env"
ROOT="$DH/.local/share/t-app/cloud/dev" SELF="$T/state/dev"
# desk <root> <workspace> [pinned]: c-003's desk; a stub has no pinned
desk() {
  mkdir -p "$1/desk/$2/box-x/spool/c-003"
  [ -z "${3:-}" ] || echo key >"$1/desk/$2/box-x/pinned"
}
P1='{"env":"dev","result":{"issues":[{"key":"SPL-1"}],"next_cursor":"c2"}}'
P2='{"env":"dev","result":{"issues":[{"key":"SPL-2"}],"next_cursor":""}}'
# list <workspace> <snippet> [VAR=value]...: the snippet's output, then rc=<its rc>
list() {
  local ws="$1" sn="$2"; shift 2
  : >"$T/as.log"; rm -f "$T/as.log.n"
  SNIPPET="do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }; $sn; echo \"rc=\$?\"" \
    in_orc PATH="$T/stub:$PATH" TENANT_ID="$ws" DESK_BOX=box-x DESK_AGENT=c-003 SPOOL_DESK_USER= \
    SPOOL_BOX_ENV="$T/box.env" SPOOL_BOX_USER="$ME" SPL_ORG_APP=t-app SPL_DESK_AS_CMD="$T/as" AS_LOG="$T/as.log" \
    AS_HIDDEN="$HID" AS_SEEN="$DH" "$@" 2>&1
}
hops() { grep -c '^HOP ' "$T/as.log"; }
FETCH='spl_issue_list_fetch --status diss --sort updated --limit 200'

# 1. moved desk, one page
desk "$ROOT" t1 pinned
chmod 000 "$HID"; trap 'chmod 755 "$HID"; rm -rf "$T"' EXIT
out="$(list t1 "$FETCH" AS_OUT1="$P2")"; log="$(cat "$T/as.log")"
hasnt "1. moved: no FATAL in the caller (RED before SPL-5465: FATAL no desk for c-003)" "no desk for" "$out"
eq "1. moved: one page, one hop" "1" "$(hops)"
has "1. moved: the hop goes to the agent user with its HOME" "HOP env HOME=$HID " "$log"
has "1. moved: the hop runs do_spl_issue_list" "$PROJ_ROOT/run -a do_spl_issue_list" "$log"
for v in ENV=dev TENANT_ID=t1 DESK_BOX=box-x DESK_AGENT=c-003 DRY_RUN=0 "SPL_DESK_HOPPED=$ME"; do
  has "1. moved: the hop carries $v" " $v " "$log"
done
has "1. moved: the hop carries the flags, one per line" "SPL_ISSUE_RAW_ARGS=--status"$'\n'"diss"$'\n'"--sort"$'\n'"updated"$'\n'"--limit"$'\n'"200 " "$log"
has "1. moved: the output is the hopped JSON line" "$P2" "$out"
hasnt "1. moved: the hopped run's log line is not the output" "a log line of the hopped" "$(grep -v '^INFO' <<<"$out")"
has "1. moved: rc 0" "rc=0" "$out"

# 2. two pages
out="$(list t1 "$FETCH" AS_OUT1="$P1" AS_OUT2="$P2")"; log="$(cat "$T/as.log")"
eq "2. two pages: two hops" "2" "$(hops)"
has "2. two pages: the second hop carries --cursor c2" "--cursor"$'\n'"c2 " "$(sed -n 2p "$T/as.log"; sed -n '3,$p' "$T/as.log")"
has "2. two pages: both pages in the result" "SPL-2" "$out"
has "2. two pages: both pages in the result" "SPL-1" "$out"

# 3. no desk anywhere
out="$(list t-none "$FETCH")"
eq "3. no root holds it: no hop" "0" "$(hops)"
has "3. no root holds it: the FATAL as before" "FATAL no desk for c-003 on box-x in t-none" "$out"
has "3. no root holds it: rc 1" "rc=1" "$out"

# 4. the caller's own pinned desk
desk "$SELF" t-own pinned
out="$(list t-own "spl_host_spool() { :; }; spl_desk_spool() { echo '{\"issues\":[],\"next_cursor\":\"\"}'; }; $FETCH")"
eq "4. own desk: no hop" "0" "$(hops)"
has "4. own desk: the read runs here" '"agent": "c-003"' "$out"

# 5. a get never hops
out="$(list t1 'spl_desk_issue_run get --ref SPL-1')"
eq "5. get: no hop" "0" "$(hops)"
has "5. get: the no-desk FATAL, as before (a write or a get never hops from here)" "FATAL no desk for c-003" "$out"

# 6. the hopped side
out="$(list t1 'spl_desk_issue_run() { printf "%s|" "$@"; echo; }; do_spl_issue_list' SPL_DESK_HOPPED=other \
  SPL_ISSUE_RAW_ARGS=$'--status\ndiss\n--cursor\nc2' ISSUE_ASSIGNEE=me)"
has "6. hopped: one page with exactly the given flags" "list|--status|diss|--cursor|c2|" "$out"
out="$(list t1 'spl_desk_issue_run() { printf "%s|" "$@"; echo; }; do_spl_issue_list' SPL_ISSUE_RAW_ARGS=$'--status\ndiss' DRY_RUN=1)"
hasnt "6. not hopped: SPL_ISSUE_RAW_ARGS is ignored" "list|--status|diss|" "$out"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
