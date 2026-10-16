#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Tests for do_fleet_logrotate_install (disk hygiene round row 01, SPL-2233).
# Everything runs in a temp root: no real /etc, no real log. The rotation and
# the age cleanup are done by the real logrotate and systemd-tmpfiles, as the
# current user (su to oneself needs no root).
#   1. Red control: a planted 60 MB log stays unrotated with no csi-spl config
#   2. DRY_RUN=1 (default) prints both files and their diff, writes nothing
#   3. DRY_RUN=0 writes both files 0644 with the plan's directives and su lines
#   4. Green: with the config the 60 MB log is copied, compressed, truncated;
#      a fresh small log is left alone
#   5. Dated logs: a 20-day-old csi-spl-orc.<date>.log is removed by the
#      tmpfiles rule, a 2-day-old one stays (red: both present before it)
#   6. A second DRY_RUN=0 is idempotent ("unchanged")
#   7. A drifted file on the box shows as a diff under DRY_RUN=1
#   8. Users from the cnf (box_owner_user / box_agent_user)
#   9. An unknown user fails fast and writes nothing
#  10. DRY_RUN=0 without root and without a test root is refused
#  11. ./run -a do_fleet_logrotate_install runs through the harness
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/fleet-logrotate-install.func.sh"
LOGROTATE=$(command -v logrotate || echo /usr/sbin/logrotate)
TMPFILES=$(command -v systemd-tmpfiles || true)

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ME=$(id -un)
VAR="$T/var/csi" HOMEDIR="$T/home"
SCRATCH="$HOMEDIR/.cache/csi-spl/tmp-scratch-sweep.log"
CRON="$VAR/csi-spl/desk-reconcile/cron-prd.out"
DISK="$VAR/csi-spl/box-disk-sweep/box-disk-sweep.log"
DATED="$VAR/csi-spl-desk-cron/csi-spl-orc/dat/log/bash"
mkdir -p "$(dirname "$SCRATCH")" "$(dirname "$CRON")" "$(dirname "$DISK")" "$DATED"
head -c 60M /dev/zero >"$SCRATCH"
echo fresh >"$DISK"
echo old >"$DATED/csi-spl-orc.20260901.log"; touch -d '20 days ago' "$DATED/csi-spl-orc.20260901.log"
echo new >"$DATED/csi-spl-orc.20260914.log"; touch -d '2 days ago' "$DATED/csi-spl-orc.20260914.log"

# run_it [VAR=val...]: the action in a subshell against the temp root.
run_it() {
  (
    export FLEET_LOGROTATE_ROOT="$T" FLEET_LOGROTATE_VAR_DIR="$VAR" FLEET_LOGROTATE_AGENT_HOME="$HOMEDIR"
    export FLEET_LOGROTATE_OWNER_USER="$ME" FLEET_LOGROTATE_AGENT_USER="$ME" FLEET_LOGROTATE_CNF=/nonexistent
    for kv in "$@"; do export "${kv?}"; done
    do_log() { echo "$*"; }
    # shellcheck source=/dev/null
    source "$FUNC_SH"
    do_fleet_logrotate_install
  )
}
LR="$T/etc/logrotate.d/csi-spl" TF="$T/etc/tmpfiles.d/csi-spl.conf"
size() { stat -c %s "$1" 2>/dev/null || echo missing; }
has_directives() {
  local d
  for d in copytruncate "maxsize 50M" "rotate 7" compress missingok; do
    [[ $(grep -cx "    $d" "$LR") -eq 2 ]] || return 1
  done
}

# 1. red control
mkdir -p "$T/etc/logrotate.d"
"$LOGROTATE" -s "$T/state" "$T/etc/logrotate.d" >/dev/null 2>&1
red="size=$(size "$SCRATCH") gz=$(ls "$SCRATCH".1.gz 2>/dev/null | wc -l)"
echo "  red control before install: $red"
[[ "$red" == "size=62914560 gz=0" ]] && pass "1. red: planted 60 MB log unrotated without the config ($red)" \
  || fail "1. red control: $red"

# 2. dry run
out=$(run_it 2>&1); rc=$?
if [[ $rc -eq 0 && ! -e "$LR" && ! -e "$TF" ]] && grep -q "PLAN $LR:" <<<"$out" && grep -q "PLAN $TF:" <<<"$out" \
  && grep -q "^  +++ $LR (new)" <<<"$out" && grep -q "rendered config.*rc=0" <<<"$out"; then
  pass "2. DRY_RUN=1 prints both files + diff, logrotate -d rc=0, writes nothing"
else
  fail "2. dry run (rc=$rc): $out"
fi

# 3. write
out=$(run_it DRY_RUN=0 2>&1); rc=$?
if [[ $rc -eq 0 && "$(stat -c %a "$LR" 2>/dev/null)" == 644 && "$(stat -c %a "$TF" 2>/dev/null)" == 644 ]] \
  && grep -qx "    su $ME $(id -gn)" "$LR" && [[ $(grep -c '^    su ' "$LR") -eq 2 ]] \
  && has_directives \
  && grep -qx "e $DATED - - - m:14d" "$TF"; then
  pass "3. DRY_RUN=0 writes both files 0644: copytruncate, maxsize 50M, rotate 7, compress, missingok, 2 su lines"
else
  fail "3. write (rc=$rc): $out $(cat "$LR" "$TF" 2>&1)"
fi

# 4. green
"$LOGROTATE" -s "$T/state" "$LR"; lrc=$?
green="rc=$lrc size=$(size "$SCRATCH") gz=$(ls "$SCRATCH".1.gz 2>/dev/null | wc -l) fresh=$(cat "$DISK")"
echo "  after install: $green"
[[ "$green" == "rc=0 size=0 gz=1 fresh=fresh" ]] && pass "4. green: 60 MB log rotated + truncated, fresh log kept ($green)" \
  || fail "4. green: $green"

# 5. dated logs
before=$(ls "$DATED" | tr '\n' ' ')
if [[ -z "$TMPFILES" ]]; then
  fail "5. no systemd-tmpfiles on this box"
else
  "$TMPFILES" --clean "$TF" >/dev/null 2>&1; trc=$?
  after=$(ls "$DATED" | tr '\n' ' ')
  echo "  dated before: $before| after: $after"
  [[ $trc -eq 0 && "$before" == "csi-spl-orc.20260901.log csi-spl-orc.20260914.log " && "$after" == "csi-spl-orc.20260914.log " ]] \
    && pass "5. tmpfiles removes the 20-day-old dated log, keeps the 2-day-old one" \
    || fail "5. dated logs (rc=$trc): before=$before after=$after"
fi

# 6. idempotent
out=$(run_it DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && $(grep -c ' unchanged$' <<<"$out") -eq 2 ]] && pass "6. second DRY_RUN=0 leaves both files unchanged" \
  || fail "6. idempotent (rc=$rc): $out"

# 7. drift
sed -i 's/rotate 7/rotate 3/' "$LR"
out=$(run_it 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q '^  -    rotate 3' <<<"$out" && grep -q '^  +    rotate 7' <<<"$out" && grep -q 'rotate 3' "$LR" \
  && pass "7. a drifted box file shows as a diff and stays untouched under DRY_RUN=1" || fail "7. drift (rc=$rc): $out"

# 8. cnf users
printf 'env:\n  steps:\n    "060-gcp-vm-satellite":\n      box_owner_user: %s\n      box_agent_user: %s\n' "$ME" "$ME" >"$T/cnf.yaml"
if command -v yq >/dev/null 2>&1; then
  out=$(run_it FLEET_LOGROTATE_OWNER_USER= FLEET_LOGROTATE_AGENT_USER= USER=nobody-here FLEET_LOGROTATE_CNF="$T/cnf.yaml" 2>&1); rc=$?
  [[ $rc -eq 0 && $(grep -c "^  |     su $ME " <<<"$out") -eq 2 ]] && pass "8. users come from cnf box_owner_user / box_agent_user" \
    || fail "8. cnf users (rc=$rc): $out"
else
  fail "8. no yq on this box"
fi

# 9. unknown user
rm -rf "${T:?}/etc"
out=$(run_it DRY_RUN=0 FLEET_LOGROTATE_AGENT_USER=no-such-user-x9 2>&1); rc=$?
[[ $rc -ne 0 && ! -e "$LR" ]] && grep -q "ERROR no OS user no-such-user-x9" <<<"$out" \
  && pass "9. unknown user fails fast, nothing written" || fail "9. unknown user (rc=$rc): $out"

# 10. root guard
if [[ "$(id -u)" == "0" ]]; then
  pass "10. skipped: running as root"
else
  out=$(run_it DRY_RUN=0 FLEET_LOGROTATE_ROOT= 2>&1); rc=$?
  [[ $rc -ne 0 ]] && grep -q "run it as root" <<<"$out" && pass "10. DRY_RUN=0 on the real /etc refused without root" \
    || fail "10. root guard (rc=$rc): $out"
fi

# 11. harness
out=$(cd "$UTL_ROOT" && FLEET_LOGROTATE_ROOT="$T" FLEET_LOGROTATE_VAR_DIR="$VAR" FLEET_LOGROTATE_AGENT_HOME="$HOMEDIR" \
  FLEET_LOGROTATE_OWNER_USER="$ME" FLEET_LOGROTATE_AGENT_USER="$ME" ./run -a do_fleet_logrotate_install 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "PLAN $LR:" <<<"$out" && pass "11. ./run -a do_fleet_logrotate_install (dry run) succeeds" \
  || fail "11. harness (rc=$rc): $out"

echo "fleet-logrotate: $fails failure(s)"
[[ "$fails" -eq 0 ]]
