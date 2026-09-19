#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 017 FR-SEC-001 -- the box spool root is closed to every OS
#          user outside its group (local mail is unsigned, so an outsider who
#          can write an inbox can forge a task to any agent).
#   1. CONTROL, the old model (2777, o::rwx): an outsider (`nobody`) READS
#      another agent's message and INJECTS a forged one -- the probe can see
#      the hole, so its failure in 2 means something
#   2. the new model (2770, group, o::---): the same read and inject FAIL;
#      the root is setgid, not sticky (an ack renames across users), and a
#      message a member writes later is rw for the group, nothing for other
#   3. do_repair_spool_root on an existing old-model tree: DRY_RUN=1 (the
#      default) prints the plan and changes nothing; DRY_RUN=0 migrates it --
#      mode, group, files lose x and other -- and the exploit then FAILS
#   4. a missing group: provision leaves an existing root untouched (exit 0,
#      WARN) and refuses a new one; the repair dry run plans groupadd +
#      usermod and creates nothing; a new group without members is refused;
#      closing other without a group is refused
# 1-3 need passwordless sudo, setfacl and a `nobody` user (SKIP otherwise).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }
T=$(mktemp -d)
trap 'sudo -n rm -rf "$T" 2>/dev/null || rm -rf "$T"' EXIT
# the outsider must be able to reach the spool root's parent, as on /var
chmod 711 "$T"

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" LDE_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

G=$(id -gn)
NOGROUP="spl-no-such-group-$$"
# a member writes a message the way an agent does (umask 022, plain write)
member_writes() { (umask 022; mkdir -p "$1/CLE-01/inbox" && echo '{"v":1,"body":"secret"}' >"$1/CLE-01/inbox/m.json"); }
outsider_reads() { sudo -n -u nobody cat "$1/CLE-01/inbox/m.json" >/dev/null 2>&1; }
outsider_injects() { sudo -n -u nobody sh -c "echo forged >'$1/CLE-01/inbox/evil.json'" 2>/dev/null; }

if sudo -n true 2>/dev/null && command -v setfacl >/dev/null && id nobody >/dev/null 2>&1 \
   && ! id -nG nobody | tr ' ' '\n' | grep -qx "$G"; then
  # --- 1. CONTROL: the old model is open -----------------------------------------
  d="$T/old"
  SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="" SPOOL_ROOT_OTHER=rwx >"$T/p1.out" 2>&1 \
    || fail "old-model provision: $(tail -2 "$T/p1.out")"
  member_writes "$d"
  [[ "$(stat -c %a "$d")" == 2777 ]] && pass "control: other=rwx still renders the old 2777 root" || fail "old model mode $(stat -c %a "$d")"
  outsider_reads "$d" && pass "control: under 2777/o::rwx an outsider READS another agent's message" \
    || fail "control: outsider read failed under the old model -- the probe cannot see the hole"
  outsider_injects "$d" && pass "control: under 2777/o::rwx an outsider INJECTS a forged message" \
    || fail "control: outsider inject failed under the old model -- the probe cannot see the hole"

  # --- 2. the new model is closed -------------------------------------------------
  d="$T/new"
  SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$G" >"$T/p2.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] && pass "provision with the cnf default model (group $G)" || fail "provision rc=$rc: $(tail -2 "$T/p2.out")"
  [[ "$(stat -c '%a %G' "$d")" == "2770 $G" ]] && pass "root is 2770, group $G" || fail "root is $(stat -c '%a %G' "$d")"
  [[ -g "$d" && ! -k "$d" ]] && pass "root is setgid and not sticky" || fail "setgid=$([[ -g $d ]] && echo y) sticky=$([[ -k $d ]] && echo y)"
  member_writes "$d"
  outsider_reads "$d" && fail "an outsider READS a message under 2770" || pass "an outsider cannot read another agent's message"
  outsider_injects "$d" && fail "an outsider INJECTS a message under 2770" || pass "an outsider cannot inject a message"
  sudo -n -u nobody ls "$d" >/dev/null 2>&1 && fail "an outsider lists the root" || pass "an outsider cannot list the root"
  # with an ACL the group bits in stat are the mask: 660 = group rw effective
  [[ "$(stat -c %a "$d/CLE-01/inbox/m.json")" == 660 ]] && pass "a later message is 0660: group rw, other nothing (default ACL)" \
    || fail "later message mode $(stat -c %a "$d/CLE-01/inbox/m.json")"
  [[ "$(stat -c %G "$d/CLE-01/inbox")" == "$G" ]] && pass "a later subdir inherits group $G (setgid)" || fail "subdir group $(stat -c %G "$d/CLE-01/inbox")"
  (mv "$d/CLE-01/inbox/m.json" "$d/CLE-01/m.acked") && pass "a member acks (renames) a message" || fail "member rename failed"

  # --- 3. repair an existing old-model tree ---------------------------------------
  d="$T/live"
  SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="" SPOOL_ROOT_OTHER=rwx >/dev/null 2>&1
  member_writes "$d"; chmod 0777 "$d/CLE-01/inbox/m.json"
  SNIPPET='do_repair_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$G" >"$T/r1.out" 2>&1; rc=$?
  [[ $rc -eq 0 && "$(stat -c %a "$d")" == 2777 ]] && grep -q "chmod 2770 '$d'" "$T/r1.out" && grep -q 'dry run: nothing changed' "$T/r1.out" \
    && pass "repair dry run (default): plan printed, nothing changed" || fail "repair dry run rc=$rc mode=$(stat -c %a "$d"): $(tail -3 "$T/r1.out")"
  outsider_injects "$d" && pass "control: the unmigrated tree is still injectable" || fail "control: unmigrated tree not injectable"
  SNIPPET='do_repair_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$G" DRY_RUN=0 >"$T/r2.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] && pass "repair DRY_RUN=0 migrates (its own outsider probe included)" || fail "repair rc=$rc: $(tail -3 "$T/r2.out")"
  [[ "$(stat -c '%a %G' "$d")" == "2770 $G" && "$(stat -c '%a %G' "$d/CLE-01/inbox")" == "2770 $G" ]] \
    && pass "migrated root and inbox are 2770 $G" || fail "migrated: $(stat -c '%a %G' "$d") / $(stat -c '%a %G' "$d/CLE-01/inbox")"
  [[ "$(stat -c %a "$d/CLE-01/inbox/m.json")" == 660 ]] && pass "an old 0777 message becomes 0660 (no x, no other)" \
    || fail "old message mode $(stat -c %a "$d/CLE-01/inbox/m.json")"
  outsider_reads "$d" && fail "an outsider still READS after the repair" || pass "after the repair an outsider cannot read"
  outsider_injects "$d" && fail "an outsider still INJECTS after the repair" || pass "after the repair an outsider cannot inject"
else
  skip "no passwordless sudo / setfacl / nobody (or nobody is in $G): sections 1-3"
fi

# --- 4. missing group, refusals (no root needed) ----------------------------------
d="$T/untouched"; mkdir -p "$d"; chmod 0755 "$d"
SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$NOGROUP" >"$T/g1.out" 2>&1; rc=$?
[[ $rc -eq 0 && "$(stat -c %a "$d")" == 755 ]] && grep -q "WARN group $NOGROUP does not exist" "$T/g1.out" \
  && pass "missing group: an existing root is left untouched (WARN, exit 0)" || fail "missing group, existing root: rc=$rc mode=$(stat -c %a "$d") $(tail -2 "$T/g1.out")"
SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$T/fresh" SPOOL_ROOT_GROUP="$NOGROUP" >"$T/g2.out" 2>&1; rc=$?
[[ $rc -ne 0 && ! -e "$T/fresh" ]] && pass "missing group: a new root is refused" || fail "missing group, new root: rc=$rc"
SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$T/fresh" SPOOL_ROOT_GROUP="" SPOOL_ROOT_OTHER=--- >"$T/g3.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'needs a spool_root_group' "$T/g3.out" && pass "other --- without a group is refused" || fail "other --- without group: rc=$rc"
SNIPPET='do_repair_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$NOGROUP" >"$T/g4.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'SPOOL_ROOT_MEMBERS' "$T/g4.out" && pass "repair: a new group without members is refused" || fail "repair without members: rc=$rc $(tail -2 "$T/g4.out")"
SNIPPET='do_repair_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$NOGROUP" SPOOL_ROOT_MEMBERS="$(id -un)" >"$T/g5.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "groupadd --system '$NOGROUP'" "$T/g5.out" && grep -q "usermod -aG '$NOGROUP' '$(id -un)'" "$T/g5.out" \
  && ! getent group "$NOGROUP" >/dev/null && [[ "$(stat -c %a "$d")" == 755 ]] \
  && pass "repair dry run plans groupadd + usermod and creates nothing" || fail "repair dry run with members: rc=$rc $(tail -3 "$T/g5.out")"
SNIPPET='do_repair_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$NOGROUP" SPOOL_ROOT_MEMBERS="spl-no-such-user-$$" >"$T/g6.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no such OS user' "$T/g6.out" && pass "repair: an unknown member is refused" || fail "unknown member: rc=$rc"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
