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
#   5. a half-moved box (SPL-4560): no SPOOL_DESK_USER, the desk only under
#      the agent user's root (SPOOL_AGENT_USER of the box env): spawn-window's
#      issue hop (li_desk_hop with li_desk_where's env, workspace, desk box)
#      goes to the agent user, also when only `sudo -n -u <it> test -d` sees
#      the desk. RED CONTROL: before SPL-4560 the hop went to SPOOL_BOX_USER,
#      whose root has no such desk (do_spl_lane_issue "FATAL no desk for").
#      The desk nowhere, or SPOOL_DESK_USER set: the hop as before
#   6. do_spl_desk_reply on a half-moved box (SPL-4938): no SPOOL_DESK_USER and
#      the desk pinned under another root re-runs the action once as that
#      root's user, also over the caller's unpinned stub (sat 2026-11-07: two
#      workspaces), whose post no sidecar would ever flush. The
#      caller's pinned desk, the desk nowhere, an unpinned copy elsewhere,
#      SPOOL_DESK_USER set and a run already hopped: no hop. do_spl_take posts
#      through the reply, so it gets the same hop. RED CONTROL: before SPL-4938
#      the first case read "FATAL no desk" and the stub case hopped nowhere
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

# 5. a half-moved box: the desk under the agent user's root only (SPL-4560).
# LI_UNDER_TEST replaces the lib (the red control runs the one before the fix).
LIH="${LI_UNDER_TEST:-$LI}"
printf 'SPOOL_AGENT_USER=%s\n' "$DU" >"$T/box.env.agent"
DESK5="$DH/.local/share/t-app/cloud/prd/desk/ws-a/box-x"
mkdir -p "$DESK5"
hop5() {  # <box env file> <extra env...> -- <li code>
  local benv="$1"; shift
  local -a ex=()
  while [ "$1" != -- ]; do ex+=("$1"); shift; done; shift
  env -u SPOOL_DESK_USER -u ENV -u TENANT_ID -u DESK_BOX -u PROJ_PATH PATH="$T/stub:$PATH" SPOOL_TEST=1 \
    SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$benv" SPOOL_BOX_USER="$BU" SPL_ORG_APP=t-app HOME="$MH" "${ex[@]}" \
    bash -c '. "$1"; eval "$2"; [ ${#h[@]} -eq 0 ] || printf "%s|" "${h[@]}"' _ "$LIH" "$1" 2>/dev/null
}
eq "5. half-moved: the desk only under the agent user's root -> the hop names the agent user (RED before SPL-4560: $BU)" \
  "sudo|-n|-u|$DU|env|HOME=$DH|" "$(hop5 "$T/box.env.agent" -- 'li_desk_hop h prd ws-a box-x')"
eq "5. control: the desk under no root -> the hop as before, to SPOOL_BOX_USER" \
  "sudo|-n|-u|$BU|env|HOME=$BH|" "$(hop5 "$T/box.env.agent" -- 'li_desk_hop h prd ws-b box-x')"
eq "5. SPOOL_DESK_USER set: unchanged, the desk user wins over the found root" \
  "" "$(hop5 "$T/box.env.agent" SPOOL_DESK_USER="$ME" -- 'li_desk_hop h prd ws-a box-x')"
# li_desk_where: the brief's Workspace: row, else the lease's env and tenant
printf 'ws-a\tprd\trepo-a\t/abs/clone\t-\thttps://example.com\tc-002\tbox-x\n' >"$T/spool/workspace-repos.tsv"
printf 'Workspace: ws-a\nIssue: SPL-1\n' >"$T/brief-ws.md"
printf 'Issue: SPL-1\n' >"$T/brief-t1.md"
mkdir -p "$T/spool/dispatch"; printf 'LEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"
eq "5. li_desk_where: a Workspace: brief -> its map row's env, tenant, desk box" \
  "prd ws-a box-x|" "$(hop5 "$T/box.env.agent" -- 'h=("$(li_desk_where "'"$T/brief-ws.md"'")")')"
eq "5. li_desk_where: no Workspace: line -> the lease's env and tenant, DESK_BOX" \
  "dev t1 box-y|" "$(hop5 "$T/box.env.agent" DESK_BOX=box-y -- 'h=("$(li_desk_where "'"$T/brief-t1.md"'")")')"
eq "5. spawn-window's call: li_desk_hop on li_desk_where of a Workspace: brief -> the agent user" \
  "sudo|-n|-u|$DU|env|HOME=$DH|" "$(hop5 "$T/box.env.agent" -- 'li_desk_hop h $(li_desk_where "'"$T/brief-ws.md"'")')"
# the agent user's root the caller cannot enter: only its sudo test -d sees it
mkdir -p "$T/stub2"
cat >"$T/stub2/sudo" <<EOF2
#!/usr/bin/env bash
[ "\$4" = test ] && [ "\$6" = "$T/hidden/.local/share/t-app/cloud/prd/desk/ws-a/box-x" ] && exit 0
exit 99
EOF2
cat >"$T/stub2/getent" <<EOF2
#!/bin/sh
case "\$2" in $DU) echo "$DU:x:5002:5002::$T/hidden:/bin/sh" ;; *) exec "$T/stub/getent" "\$@" ;; esac
EOF2
chmod +x "$T/stub2/sudo" "$T/stub2/getent"
eq "5. the agent user's root not enterable: its sudo test -d finds the desk -> the agent user" \
  "sudo|-n|-u|$DU|env|HOME=$T/hidden|" "$(hop5 "$T/box.env.agent" PATH="$T/stub2:$T/stub:$PATH" -- 'li_desk_hop h prd ws-a box-x')"

# 6. do_spl_desk_reply follows a desk moved under another root (SPL-4938). The
# real action in in_orc; SPL_DESK_AS_CMD is a stub that runs a root's probe and
# logs the hop instead of running it.
AS6="$T/as6"
cat >"$AS6" <<'EOF2'
#!/usr/bin/env bash
[ "$3" = env ] || { shift 2; [ -z "${AS_HIDDEN:-}" ] || set -- "${@//$AS_HIDDEN/$AS_SEEN}"; exec "$@"; }
shift 2
printf 'HOP %s\n' "$*" >>"$AS_LOG"
exit "${AS_RC:-0}"
EOF2
chmod +x "$AS6"
ROOT6="$DH/.local/share/t-app/cloud/dev"
SELF6="$T/state/dev"
TOPIC6=b280b0e8-1111-4222-8333-444455556666
echo 'the answer' >"$T/body6"
# desk6 <root> <workspace> [pinned]: a desk with c-002's mailbox dir; a stub has no pinned
desk6() {
  mkdir -p "$1/desk/$2/box-x/spool/c-002"
  [ -z "${3:-}" ] || echo key >"$1/desk/$2/box-x/pinned"
}
# reply6 <workspace> [VAR=value]...: the action's output, then rc=<its rc>
reply6() {
  local ws="$1"; shift
  : >"$T/as.log"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }; do_spl_desk_reply; echo "rc=$?"' \
    in_orc TENANT_ID="$ws" DESK_BOX=box-x DESK_AGENT=c-002 DESK_TO=HUM-10 DESK_TASK="$TOPIC6" \
    DESK_BODY_FILE="$T/body6" DRY_RUN=0 SPOOL_DESK_USER= SPOOL_BOX_ENV="$T/box.env.agent" SPOOL_BOX_USER="$BU" \
    SPL_ORG_APP=t-app SPL_DESK_AS_CMD="$AS6" AS_LOG="$T/as.log" "$@" 2>&1
}
hop6() { grep -c '^HOP ' "$T/as.log"; }

desk6 "$ROOT6" hop-a pinned
out="$(reply6 hop-a)"; log="$(cat "$T/as.log")"
has "6. moved: the desk pinned only under the agent root -> one hop to the agent user, with its HOME" "HOP env HOME=$DH " "$log"
eq "6. moved: exactly one hop" "1" "$(hop6)"
for v in ENV=dev TENANT_ID=hop-a DESK_AGENT=c-002 DESK_BOX=box-x DESK_TO=HUM-10 "DESK_TASK=$TOPIC6" "DESK_BODY_FILE=$T/body6" DRY_RUN=0 SPOOL_ROOT= "SPL_DESK_HOPPED=$ME"; do
  has "6. moved: the hop carries $v" " $v" "$log"
done
has "6. moved: the hop runs this checkout's action" "$PROJ_ROOT/run -a do_spl_desk_reply" "$log"
hasnt "6. moved: the caller's SPL_STATE_DIR stays behind" "SPL_STATE_DIR" "$log"
hasnt "6. moved: no FATAL in the caller" "no desk for" "$out"
has "6. moved: the hopped run's rc is the action's rc" "rc=7" "$(reply6 hop-a AS_RC=7)"

# the live defect: the agent user's root is 0700, only its sudo sees the desk
mkdir -p "$T/stub6" "$T/hidden6"
cat >"$T/stub6/getent" <<EOF2
#!/bin/sh
case "\$2" in $DU) echo "$DU:x:5002:5002::$T/hidden6:/bin/sh" ;; *) exec "$T/stub/getent" "\$@" ;; esac
EOF2
chmod +x "$T/stub6/getent"
chmod 000 "$T/hidden6"
out="$(reply6 hop-a PATH="$T/stub6:$T/stub:$PATH" AS_HIDDEN="$T/hidden6" AS_SEEN="$DH")"; log="$(cat "$T/as.log")"
chmod 755 "$T/hidden6"
has "6. moved, the root not enterable: its sudo finds the desk, the hop goes there (RED before SPL-4938: FATAL no desk)" "HOP env HOME=$T/hidden6 " "$log"
hasnt "6. moved, the root not enterable: no FATAL in the caller" "no desk for" "$out"

desk6 "$SELF6" hop-b; desk6 "$ROOT6" hop-b pinned
reply6 hop-b >/dev/null
eq "6. the caller's unpinned stub, the desk pinned under the agent root (as measured on sat): one hop" "1" "$(hop6)"
reply6 hop-b DRY_RUN=1 >/dev/null
has "6. a dry run hops too, so it reads the real desk" "DRY_RUN=1" "$(cat "$T/as.log")"

desk6 "$SELF6" hop-c pinned; desk6 "$ROOT6" hop-c
out="$(reply6 hop-c DRY_RUN=1)"
eq "6. the desk under the caller's root: no hop" "0" "$(hop6)"
has "6. the desk under the caller's root: the dry run runs here" "OK DRY_RUN nothing was sent" "$out"

out="$(reply6 hop-none)"
eq "6. no root holds it: no hop" "0" "$(hop6)"
has "6. no root holds it: the FATAL as today" "FATAL no desk for c-002 on box-x in hop-none" "$out"

desk6 "$ROOT6" hop-d
reply6 hop-d DRY_RUN=1 >/dev/null
eq "6. only an unpinned copy under the other root: not a desk to hop to" "0" "$(hop6)"

desk6 "$ROOT6" hop-e pinned
reply6 hop-e DRY_RUN=1 SPOOL_DESK_USER="$DU" >/dev/null
eq "6. SPOOL_DESK_USER set: no hop, as before" "0" "$(hop6)"
reply6 hop-e DRY_RUN=1 SPL_DESK_HOPPED="$BU" >/dev/null
eq "6. a run that already hopped does not hop again" "0" "$(hop6)"
reply6 hop-e DRY_RUN=1 SPL_DESK_AS_CMD= >/dev/null
eq "6. SPOOL_TEST=1 with no SPL_DESK_AS_CMD never hops to a real user" "0" "$(hop6)"

# do_spl_take posts through do_spl_desk_reply: the same hop, the ledger written.
cat >"$T/reply6" <<'EOF2'
#!/usr/bin/env bash
do_log() { echo "$*"; }
do_require_bin() { return 0; }
for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
do_spl_desk_reply
EOF2
chmod +x "$T/reply6"
out="$(: >"$T/as.log"; SNIPPET='do_spl_take; echo "rc=$?"' in_orc TENANT_ID=hop-a DESK_BOX=box-x TAKE_BOX=box-x DESK_AGENT=c-002 DESK_TO=HUM-10 \
  DESK_TASK="$TOPIC6" TAKE_PLAN='I read the logs' DRY_RUN=0 SPOOL_ROOT="$T/spool" SPOOL_DESK_USER= SPOOL_BOX_ENV="$T/box.env.agent" \
  SPOOL_BOX_USER="$BU" SPL_ORG_APP=t-app SPL_DESK_AS_CMD="$AS6" AS_LOG="$T/as.log" TAKE_REPLY_CMD="$T/reply6" 2>&1)"
eq "6. do_spl_take: its reply hops once" "1" "$(hop6)"
has "6. do_spl_take: the hop carries the take line" "DESK_BODY=Taken by c-002@box-x: I read the logs" "$(cat "$T/as.log")"
has "6. do_spl_take: recorded as taken, rc 0" "rc=0" "$out"

# 7. do_spl_desk_post and do_spl_topic_archive follow a moved desk, half-moved
# box or switched (SPL-4985). RED on 48dc6c573: FATAL no desk, no hop.
# act7 <action snippet> <workspace> [VAR=value]...
act7() {
  local snip="$1" ws="$2"; shift 2
  : >"$T/as.log"
  SNIPPET="do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }; $snip; echo \"rc=\$?\"" \
    in_orc TENANT_ID="$ws" DESK_BOX=box-x DESK_AGENT=c-002 DESK_CHANNEL=alerts DESK_KIND=note DESK_BODY=hello \
    TOPIC="$TOPIC6" MODE=archive DRY_RUN=0 SPOOL_DESK_USER= SPOOL_BOX_ENV="$T/box.env.agent" SPOOL_BOX_USER="$BU" \
    SPL_ORG_APP=t-app SPL_DESK_AS_CMD="$AS6" AS_LOG="$T/as.log" "$@" 2>&1
}
desk6 "$ROOT6" hop-g pinned
out="$(act7 do_spl_desk_post hop-g)"; log="$(cat "$T/as.log")"
eq "7. post: one hop" "1" "$(hop6)"
has "7. post: the agent user's HOME" "HOP env HOME=$DH " "$log"
has "7. post: the hop carries the post" " DESK_CHANNEL=alerts" "$log"
has "7. post: the hop runs the post" "$PROJ_ROOT/run -a do_spl_desk_post" "$log"
hasnt "7. post: no FATAL in the caller" "no desk for" "$out"
has "7. post: the hopped run's rc" "rc=7" "$(act7 do_spl_desk_post hop-g AS_RC=7)"
out="$(act7 do_spl_desk_post hop-g SPOOL_DESK_USER="$DU")"
eq "7. post: a switched box hops too" "1" "$(hop6)"
hasnt "7. post: a switched box has no refusal" "FATAL" "$out"
act7 do_spl_desk_post hop-g SPL_DESK_HOPPED="$BU" >/dev/null
eq "7. post: one hop, never a loop" "0" "$(hop6)"
act7 do_spl_desk_post hop-g SPL_DESK_AS_CMD= >/dev/null
eq "7. post: SPOOL_TEST=1 with no SPL_DESK_AS_CMD never hops to a real user" "0" "$(hop6)"
desk6 "$SELF6" hop-h pinned
act7 do_spl_desk_post hop-h DRY_RUN=1 >/dev/null
eq "7. post: the caller's own pinned desk: no hop" "0" "$(hop6)"
# ./run's do_log sets these globals; the stub of in_orc does not, and a local of
# the same name in the hop was rewritten live (-a desk) with this suite green.
act7 'do_log() { type_of_msg=x action=desk rest_of_msg=x msg=x log_dir=x log_file=x; }; do_spl_desk_post' hop-g >/dev/null
has "7. post: do_log's globals leave the hop's action alone" "$PROJ_ROOT/run -a do_spl_desk_post" "$(cat "$T/as.log")"
out="$(act7 do_spl_topic_archive hop-g)"; log="$(cat "$T/as.log")"
eq "7. archive: one hop" "1" "$(hop6)"
has "7. archive: the hop carries the topic" " TOPIC=$TOPIC6" "$log"
has "7. archive: the hop carries the mode" " MODE=archive" "$log"
has "7. archive: the hop runs the archive" "$PROJ_ROOT/run -a do_spl_topic_archive" "$log"
hasnt "7. archive: no FATAL in the caller" "no desk for" "$out"

# 8. do_spl_desk_poll_ack scans as the owner once the fleet desk moved (SPL-4985).
# RED on 48dc6c573: no hop, the box user sees no moved workspace.
ack8() {
  local ws="$1"; shift
  act7 "_spl_poll_ack_holder() { echo c-002; }; spl_lease_init() { :; }; spl_lease_conf() { LEASE_TENANT=$ws; LEASE_DESK_BOX=box-x; LEASE_DIR='$T/pa8'; }; do_spl_desk_poll_ack" "$ws" DESK_BOX=box-x POLL_ACK_MAX_AGE=45 "$@"
}
mkdir -p "$T/pa8"
out="$(ack8 hop-g)"; log="$(cat "$T/as.log")"
eq "8. poll ack: the fleet desk moved: one hop" "1" "$(hop6)"
has "8. poll ack: the hop runs the scan" "$PROJ_ROOT/run -a do_spl_desk_poll_ack" "$log"
has "8. poll ack: the hop carries its inputs" " POLL_ACK_MAX_AGE=45" "$log"
has "8. poll ack: the hopped run's rc" "rc=7" "$(ack8 hop-g AS_RC=7)"
ack8 hop-h >/dev/null
eq "8. poll ack: the fleet desk is the caller's: no hop" "0" "$(hop6)"

# 9. do_spl_lane_issue re-runs as the owner of a moved desk (SPL-4985, R7 W2).
# The taught end line is `sudo -u <box user> env AGENT_ID=... LANE_ISSUE_OP=end`:
# no TENANT_ID and no DESK_AGENT, so the workspace comes from lease.conf, as here.
# RED on 0c2b65bc2: 13 FAILED, no hop. This sandbox's roots are enterable, so the
# refusal is not the one a real 0700 root gives; R7's control D read that one.
LI9="$T/li9"
mkdir -p "$LI9/dispatch" "$LI9/c-777/lifetime"
printf 'LEASE_ENV=dev\nLEASE_TENANT=hop-g\nLEASE_MASTER=c-002\n' >"$LI9/dispatch/lease.conf"
echo SPL-77 >"$LI9/c-777/lifetime/issue"
# li9 [VAR=value]...: the action as the taught line calls it
li9() {
  : >"$T/as.log"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }; spl_desk_box_default() { echo box-x; }; do_spl_lane_issue; echo "rc=$?"' \
    in_orc SPOOL_ROOT="$LI9" AGENT_ID=c-777 LANE_ISSUE_OP=end LANE_ISSUE_STATUS=diss LANE_ISSUE_REASON='gate dropped it' \
    DRY_RUN=0 SPOOL_DESK_USER= SPOOL_BOX_ENV="$T/box.env.agent" SPOOL_BOX_USER="$BU" \
    SPL_ORG_APP=t-app SPL_DESK_AS_CMD="$AS6" AS_LOG="$T/as.log" "$@" 2>&1
}
out="$(li9)"; log="$(cat "$T/as.log")"
eq "9. lane issue: the lease's desk moved: one hop" "1" "$(hop6)"
has "9. lane issue: the agent user's HOME" "HOP env HOME=$DH " "$log"
has "9. lane issue: the hop runs the action" "$PROJ_ROOT/run -a do_spl_lane_issue" "$log"
has "9. lane issue: the hop carries the lane" " AGENT_ID=c-777" "$log"
has "9. lane issue: the hop carries the op" " LANE_ISSUE_OP=end" "$log"
has "9. lane issue: the hop carries the reason" " LANE_ISSUE_REASON=gate dropped it" "$log"
has "9. lane issue: the workspace from lease.conf goes along" " TENANT_ID=hop-g" "$log"
has "9. lane issue: the spool root goes along" " SPOOL_ROOT=$LI9" "$log"
hasnt "9. lane issue: no FATAL in the caller" "FATAL" "$out"
has "9. lane issue: the hopped run's rc" "rc=7" "$(li9 AS_RC=7)"
out="$(li9 SPOOL_DESK_USER="$DU")"
eq "9. lane issue: a switched box hops too" "1" "$(hop6)"
hasnt "9. lane issue: a switched box has no refusal" "FATAL" "$out"
li9 BRIEF="$T/no-brief.md" LANE_ISSUE_OP=place >/dev/null
has "9. lane issue: a place carries its brief" " BRIEF=$T/no-brief.md" "$(cat "$T/as.log")"
li9 SPL_DESK_HOPPED="$BU" >/dev/null
eq "9. lane issue: one hop, never a loop" "0" "$(hop6)"
li9 SPL_DESK_AS_CMD= >/dev/null
eq "9. lane issue: SPOOL_TEST=1 with no SPL_DESK_AS_CMD never hops to a real user" "0" "$(hop6)"
li9 TENANT_ID=hop-h DESK_AGENT=c-002 DRY_RUN=1 >/dev/null
eq "9. lane issue: the caller's own pinned desk: no hop" "0" "$(hop6)"
li9 AGENT_ID=bad >/dev/null
eq "9. lane issue: a bad AGENT_ID is refused here, no hop" "0" "$(hop6)"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
