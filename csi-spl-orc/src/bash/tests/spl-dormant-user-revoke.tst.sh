#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dormant_user_revoke (SPL-1960, security round 1 row 10) on a
#          sandbox /etc and scan tree, with stubs for id, ps, crontab, gpasswd
#          and visudo (their state in files). Placeholder user names only.
#   1. refusals: DRY_RUN=2, no DORMANT_USER, an unknown user, a uid < 1000,
#      the user running it, the spool agent user
#   2. DRY_RUN is the default: names groups, grant file, launchers 0; would
#      remove / gpasswd; nothing changed
#   3. each launcher kind refuses by name, nothing changed: a process, its
#      crontab, a cron.d line, a systemd unit, a script with sudo -u, and a
#      sudoers file shared with another user; a doc that mentions the user
#      and a script for a user with a longer name are NOT launchers; a dir in
#      DORMANT_SCAN_EXCLUDE is skipped and named, a .txt note is no launcher
#   4. DRY_RUN=0: the grant file gone (copy 600 in the undo dir), the
#      supplementary groups gone, the primary group and the home kept, the
#      other user's sudoers file untouched; a second run has nothing to do
#   5. visudo -c failing after the removal: the grant file is put back
#   6. CONTROL: a revoke that skips gpasswd fails the apply
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

E="$T/etc" S="$T/scan" F="$T/fake"
mkdir -p "$F" "$T/stub" "$S/opt/app" "$T/units" "$T/cronspool"
U=dormant1
reset() {
  rm -rf "$E"; mkdir -p "$E/sudoers.d" "$E/cron.d" "$E/systemd/system"
  printf 'root ALL=(ALL:ALL) ALL\n' >"$E/sudoers"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" >"$E/sudoers.d/90-$U-nopasswd"
  printf 'keeper1 ALL=(ALL) NOPASSWD:ALL\n' >"$E/sudoers.d/90-keeper1-nopasswd"
  printf '# MAILTO=x\n0 * * * * keeper1 /bin/true\n' >"$E/cron.d/job"
  printf '[Service]\nUser=keeper1\n' >"$E/systemd/system/a.service"
  printf 'grp1 docker keeper1 %s\n' "$U" >"$F/groups.$U"
  printf '%s\n' "$U" >"$F/prim.$U"
  : >"$F/ps.$U"; : >"$F/crontab.$U"
  rm -rf "$S" "$T/units"; mkdir -p "$S/opt/app" "$T/units"
  printf '# notes: %s is dormant, sudo -u %s was used once\n' "$U" "$U" >"$S/opt/app/notes.md"
  printf '#!/bin/sh\nsudo -u %s2 true\n' "$U" >"$S/opt/app/other.sh"
  rm -rf "$T/undo"
}
cat >"$T/stub/id" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -u) [[ -n "${2:-}" ]] || { echo "${FAKE_ME_UID:-5000}"; exit 0; }
      [[ -f "$FAKE/prim.$2" ]] || { [[ "$2" == sys1 ]] && { echo 100; exit 0; }; exit 1; }; echo 1500 ;;
  -un) echo "${FAKE_ME:-runner1}" ;;
  -gn) cat "$FAKE/prim.$2" ;;
  -Gn) echo "$(cat "$FAKE/prim.$2") $(cat "$FAKE/groups.$2")" ;;
esac
STUB
cat >"$T/stub/ps" <<'STUB'
#!/usr/bin/env bash
cat "$FAKE/ps.$2"
STUB
cat >"$T/stub/crontab" <<'STUB'
#!/usr/bin/env bash
cat "$FAKE/crontab.$3"
STUB
cat >"$T/stub/gpasswd" <<'STUB'
#!/usr/bin/env bash
echo "gpasswd $*" >>"$STUB_LOG"
g="$(cat "$FAKE/groups.$2" | tr ' ' '\n' | grep -vx "$3" | tr '\n' ' ')"; echo "${g% }" >"$FAKE/groups.$2"
STUB
printf '#!/usr/bin/env bash\necho "visudo $*" >>"$STUB_LOG"\nexit "${FAKE_VISUDO_RC:-0}"\n' >"$T/stub/visudo"
chmod +x "$T/stub/"*
du_() {
  SNIPPET="${SNIP:-do_spl_dormant_user_revoke}" in_orc FAKE="$F" DORMANT_SUDO="" DORMANT_ETC="$E" DORMANT_SCAN_DIRS="$S" \
    DORMANT_UNIT_DIRS="$T/units" DORMANT_CRON_SPOOL="$T/cronspool" DORMANT_UNDO="$T/undo" SPOOL_AGENT_USER=agent1 SPOOL_BOX_USER=box1 \
    "$@" >"$T/o" 2>&1
}
snap() { (cd "$T" && find etc scan -printf '%p %m\n' | sort; cat fake/groups.*); }

# --- 1. refusals -------------------------------------------------------------------------------
reset
du_ DORMANT_USER=$U DRY_RUN=2 && fail "accepts DRY_RUN=2" || pass "refuses DRY_RUN=2"
du_ && fail "runs with no DORMANT_USER" || { grep -q "FATAL DORMANT_USER must be a login name" "$T/o" && pass "refuses no DORMANT_USER" || fail "no user: $(cat "$T/o")"; }
du_ DORMANT_USER=nosuch1 && fail "runs for an unknown user" || { grep -q "FATAL no user nosuch1" "$T/o" && pass "refuses an unknown user" || fail "unknown: $(cat "$T/o")"; }
du_ DORMANT_USER=sys1 && fail "runs for a system user" || { grep -q "uid 100 (< 1000)" "$T/o" && pass "refuses a uid < 1000" || fail "sys: $(cat "$T/o")"; }
du_ DORMANT_USER=$U FAKE_ME=$U && fail "runs on itself" || { grep -q "is the user running this" "$T/o" && pass "refuses the user running it" || fail "self: $(cat "$T/o")"; }
printf 'agent1\n' >"$F/prim.agent1"; printf 'docker\n' >"$F/groups.agent1"
du_ DORMANT_USER=agent1 && fail "runs on the agent user" || { grep -q "spool's agent or box user" "$T/o" && pass "refuses the spool agent user" || fail "agent: $(cat "$T/o")"; }

# --- 2. DRY_RUN default ------------------------------------------------------------------------
before="$(snap)"; : >"$T/calls.log"
du_ DORMANT_USER=$U; rc=$?
[[ $rc -eq 0 && "$(snap)" == "$before" && ! -s $T/calls.log ]] && grep -q "OK DRY_RUN nothing was changed" "$T/o" &&
  pass "dry run by default: nothing changed, no gpasswd" || fail "dry run: rc=$rc $(cat "$T/o")"
grep -qx "user $U uid=1500 primary group=$U (kept) supplementary groups=grp1 docker keeper1" "$T/o" &&
  grep -qx "sudoers grant files: $E/sudoers.d/90-$U-nopasswd" "$T/o" && grep -q "^launchers: 0 " "$T/o" &&
  pass "dry run: groups, grant file, 0 launchers (a doc mention and a longer user name are not launchers)" || fail "dry run rows: $(cat "$T/o")"
grep -qx "would remove $E/sudoers.d/90-$U-nopasswd (1 rule line(s))" "$T/o" && grep -qx "would: gpasswd -d $U docker" "$T/o" &&
  pass "dry run: the exact removals" || fail "dry run would: $(cat "$T/o")"

# --- 3. each launcher kind refuses -------------------------------------------------------------
launcher() {
  local what="$1" want="$2"
  before="$(snap)"; : >"$T/calls.log"
  du_ DORMANT_USER=$U DRY_RUN=0 && fail "$what: revoked anyway" ||
    { grep -q "$want" "$T/o" && grep -q "FAIL $U: not revoked" "$T/o" && [[ "$(snap)" == "$before" && ! -s $T/calls.log ]] &&
      pass "$what: refused by name, nothing changed" || fail "$what: $(cat "$T/o")"; }
  reset
}
printf '123 ?\n' >"$F/ps.$U"; launcher "a running process" "launcher: processes: 1 running"
printf '0 * * * * /bin/true\n' >"$F/crontab.$U"; launcher "its crontab" "launcher: crontab: $U has its own crontab"
printf '5 * * * * %s /bin/true\n' "$U" >"$E/cron.d/dorm"; launcher "a cron.d line" "launcher: named in: $E/cron.d/dorm"
printf '[Service]\nUser=%s\n' "$U" >"$T/units/b.service"; launcher "a systemd unit" "launcher: named in: $T/units/b.service"
printf '#!/bin/sh\nsudo -n -u %s /bin/true\n' "$U" >"$S/opt/app/launch.sh"; launcher "a script with sudo -u" "launcher: script: $S/opt/app/launch.sh"
printf '#!/bin/sh\nsu - %s -c true\n' "$U" >"$S/opt/app/launch2.sh"; launcher "a script with su -" "launcher: script: $S/opt/app/launch2.sh"
printf '%s ALL=(ALL) ALL\nkeeper1 ALL=(ALL) ALL\n' "$U" >"$E/sudoers.d/50-shared"; launcher "a shared sudoers file" "REFUSED: sudoers files that grant $U AND others"

mkdir -p "$S/opt/archive"; printf '#!/bin/sh\nsu - %s -c true\n' "$U" >"$S/opt/archive/old.sh"
printf 'ran: sudo -u %s true\n' "$U" >"$S/opt/app/session-notes.txt"
du_ DORMANT_USER=$U DORMANT_SCAN_EXCLUDE="$S/opt/archive"
grep -q "^launchers: 0 " "$T/o" && grep -qx "not scanned (DORMANT_SCAN_EXCLUDE, reviewed by hand): $S/opt/archive" "$T/o" &&
  pass "an owner-excluded dir is not scanned and is named; a .txt note is not a launcher" || fail "exclude: $(cat "$T/o")"
du_ DORMANT_USER=$U
grep -qx "launcher: script: $S/opt/archive/old.sh" "$T/o" && pass "without the exclude the same dir is a launcher" || fail "no exclude: $(cat "$T/o")"
reset

# --- 4. DRY_RUN=0 ------------------------------------------------------------------------------
: >"$T/calls.log"
du_ DORMANT_USER=$U DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK $U revoked: no sudoers grant, no supplementary group" "$T/o" &&
  pass "applied: revoked" || fail "apply: rc=$rc $(cat "$T/o")"
[[ ! -e $E/sudoers.d/90-$U-nopasswd && "$(stat -c %a "$T/undo/90-$U-nopasswd")" == 600 ]] &&
  grep -qx "$U ALL=(ALL) NOPASSWD:ALL" "$T/undo/90-$U-nopasswd" &&
  pass "applied: grant file removed, its copy (600) in the undo dir" || fail "grant: $(ls -la "$E/sudoers.d" "$T/undo")"
[[ "$(cat "$F/groups.$U")" == "$U" && "$(cat "$F/prim.$U")" == "$U" ]] && [[ "$(grep -c '^gpasswd -d' "$T/calls.log")" == 3 ]] &&
  grep -qx "gpasswd -a $U docker" "$T/undo/groups.undo" &&
  pass "applied: 3 supplementary groups dropped (undo lines kept), primary group kept" || fail "groups: $(cat "$F/groups.$U") $(cat "$T/calls.log")"
[[ -f $E/sudoers.d/90-keeper1-nopasswd ]] && grep -q "^visudo -c" "$T/calls.log" &&
  pass "applied: the other user's sudoers file untouched; visudo -c ran" || fail "keeper/visudo"
du_ DORMANT_USER=$U DRY_RUN=0
grep -q "no sudoers grant and no supplementary group: nothing to do" "$T/o" && pass "second run: nothing to do" || fail "rerun: $(cat "$T/o")"

# --- 5. visudo -c fails ------------------------------------------------------------------------
reset
du_ DORMANT_USER=$U DRY_RUN=0 FAKE_VISUDO_RC=1 && fail "visudo failure passes" ||
  { grep -q "FATAL visudo -c fails without the grant files: put back" "$T/o" && [[ -f $E/sudoers.d/90-$U-nopasswd ]] &&
    [[ "$(cat "$F/groups.$U")" == "grp1 docker keeper1 $U" ]] &&
    pass "visudo -c failing: the grant file is put back, no group touched" || fail "visudo: $(cat "$T/o")"; }

# --- 6. CONTROL --------------------------------------------------------------------------------
reset
SNIP='gpasswd() { :; }; do_spl_dormant_user_revoke' du_ DORMANT_USER=$U DRY_RUN=0 &&
  fail "CONTROL: a revoke without gpasswd passes: $(cat "$T/o")" ||
  { grep -q "FAIL $U after the revoke: groups='grp1 docker keeper1'" "$T/o" &&
    pass "CONTROL: a revoke that keeps the groups fails the apply" || fail "CONTROL: $(cat "$T/o")"; }

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
