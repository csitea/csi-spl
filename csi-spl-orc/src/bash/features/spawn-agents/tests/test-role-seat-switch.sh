#!/usr/bin/env bash
# test-role-seat-switch.sh — SPL-1685: role-seat-switch.sh moves a role seat to
# the id of its new vendor and back (c-001 -> g-001 -> c-001). SPL-4031 (orch
# panel plan B2): the switch links no other letter of the seat any more; mail
# to ANY id of the seat (the old one, another letter, the legacy CLE-001) still
# lands in the one live inbox through the spool binary (liveRoleSeat), no
# orphan dir of the old letter appears, and the lease reads the live seat
# without a link (spl_fleet_seat_id). A desk dir moves the same way; a stale
# dir of another letter merges in, and a clash stops it.
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
t_spool_bin || { echo "FAIL: spool binary did not build"; exit 1; }
SW="$T_SCRIPTS/role-seat-switch.sh"
R="$SPOOL_ROOT"
DR="$T_TMP/desks"; D="$DR/prd/desk/t1/box-a/spool"
export DESK_STATE_ROOT="$DR" SPOOL_DESK_BOX=box-a

nope() { ! "$@" 2>/dev/null; }
sw() { bash "$SW" "$@" 2>&1; }
gone() { test ! -e "$R/$1" -a ! -L "$R/$1"; }
send() { SPOOL_ROOT="$R" SPOOL_NOTIFY_CMD=off "$SPOOL_BIN" send --from c-045 --to "$1" --kind note --body "$2" >/dev/null 2>&1; }
inbox() { ls "$R/$1/inbox" | wc -l | tr -d ' '; }
seat() { ( source "$T_REPO/csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh" >/dev/null 2>&1; SPOOL_ROOT="$R" spl_fleet_seat_id "$1" ); }

mkdir -p "$R/c-001"/{inbox,outbox,archive} "$R/c-045"/{inbox,outbox,archive} "$R/agents" "$D/c-001/inbox"
ln -s c-001 "$R/CLE-001"
echo '{"m":1}' > "$R/c-001/inbox/m1.json"
echo '{"d":1}' > "$D/c-001/inbox/d1.json"
printf 'c-001\tclaude\t%%1\t/x\t20261013T000000Z\nc-045\tclaude\t%%2\t/y\t20261013T000000Z\n' > "$R/registry.tsv"

# 0. usage
check "0. two different seats are refused" nope bash "$SW" c-001 g-002
check "0. a lane is refused" nope bash "$SW" c-045 g-045
check "0. the same id is refused" nope bash "$SW" c-001 c-001

# 1. the dry run touches nothing
out="$(sw c-001 g-001)"
has "1. dry run plans the move" "PLAN move" "$out"
check "1. dry run: c-001 is still the dir" test -d "$R/c-001" -a ! -L "$R/c-001"
check "1. dry run: no g-001" test ! -e "$R/g-001"

# 2. c-001 -> g-001
out="$(sw --apply --desk-envs prd c-001 g-001)"; rc=$?
eq "2. switch exits 0" 0 "$rc"
check "2. g-001 is the real dir" test -d "$R/g-001" -a ! -L "$R/g-001"
for id in a-001 c-001 m-001 q-001; do
  check "2. $id has no entry (no letter link)" gone "$id"
done
eq "2. the legacy CLE-001 alias points at g-001" g-001 "$(readlink "$R/CLE-001")"
send c-001 m2; send CLE-001 m3; send a-001 m4
eq "2. mail to c-001, CLE-001 and a-001 is in the live inbox" 4 "$(inbox g-001)"
check "2. no c-001 entry after the sends" gone c-001
check "2. no a-001 entry after the sends" gone a-001
got="$(SPOOL_ROOT="$R" "$SPOOL_BIN" recv --as c-001 2>/dev/null | grep -o '"msg_id"' | wc -l | tr -d ' ')"
eq "2. recv --as c-001 reads g-001's inbox" 3 "$got"
check "2. no c-001 entry after the recv" gone c-001
eq "2. the lease reads c-001 as g-001" g-001 "$(seat c-001)"
eq "2. the lease reads g-001 as g-001" g-001 "$(seat g-001)"
eq "2. registry row renamed" g-001 "$(awk -F'\t' '$4 == "/x" {print $1}' "$R/registry.tsv")"
eq "2. a lane's row untouched" c-045 "$(awk -F'\t' '$4 == "/y" {print $1}' "$R/registry.tsv")"
check "2. the desk dir is g-001" test -d "$D/g-001" -a ! -L "$D/g-001"
check "2. the desk keeps no c-001 entry" test ! -e "$D/c-001" -a ! -L "$D/c-001"
check "2. the desk mail moved with it" test -f "$D/g-001/inbox/d1.json"
out="$(sw --apply c-001 g-001)"; rc=$?
eq "2. a re-run exits 0" 0 "$rc"
hasnt "2. a re-run moves nothing" "DO move" "$out"

# 3. g-001 -> c-001 (back to claude)
out="$(sw --apply --desk-envs prd g-001 c-001)"; rc=$?
eq "3. switch back exits 0" 0 "$rc"
check "3. c-001 is the real dir again" test -d "$R/c-001" -a ! -L "$R/c-001"
check "3. g-001 has no entry" gone g-001
send g-001 m5
eq "3. mail to the Grok id reaches the claude seat" 5 "$(inbox c-001)"
check "3. no g-001 entry after the send" gone g-001
eq "3. CLE-001 still resolves" 5 "$(inbox CLE-001)"
eq "3. the lease reads g-001 as c-001" c-001 "$(seat g-001)"
eq "3. registry row back" c-001 "$(awk -F'\t' '$4 == "/x" {print $1}' "$R/registry.tsv")"
check "3. the desk is c-001 again" test -d "$D/c-001" -a ! -L "$D/c-001"

# 4. a stale real dir of another letter merges in; a clash stops it
mkdir -p "$R/m-001/inbox"; echo '{"s":1}' > "$R/m-001/inbox/stale.json"
eq "4. CONTROL: two live dirs of one seat: the lease keeps the id as given" g-001 "$(seat g-001)"
out="$(sw --apply c-001 g-001)"; rc=$?
eq "4. a stale m-001 merges: exit 0" 0 "$rc"
check "4. its mail is in the live inbox" test -f "$R/g-001/inbox/stale.json"
check "4. m-001 has no entry now" gone m-001
mkdir -p "$R/q-001/inbox"; echo '{"other":1}' > "$R/q-001/inbox/m1.json"
out="$(sw --apply g-001 c-001)"; rc=$?
check "4. CONTROL: a clashing file name fails" test "$rc" != 0
has "4. ...and names it" "also in" "$out"
check "4. ...and nothing moved" test -d "$R/g-001" -a ! -L "$R/g-001"
rm -rf "$R/q-001"

# 5. a box switched before SPL-4031 (letter links): the lease still follows a
# link, and the next switch removes every one
for id in a-001 c-001 m-001 q-001; do ln -s g-001 "$R/$id"; done
eq "5. a pre-SPL-4031 link: the lease follows it" g-001 "$(seat c-001)"
out="$(sw --apply g-001 c-001)"; rc=$?
eq "5. switch exits 0" 0 "$rc"
eq "5. no letter link of the seat is left" 0 "$(find "$R" -maxdepth 1 -type l -name '?-001' | wc -l | tr -d ' ')"
check "5. c-001 is the real dir" test -d "$R/c-001" -a ! -L "$R/c-001"
t_done
