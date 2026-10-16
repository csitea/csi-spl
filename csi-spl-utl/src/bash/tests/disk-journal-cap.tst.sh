#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for hyg-02: journald size cap drop-in (SPL-2234, Refs: SPL-2111).
# Runs do_disk_journal_cap against a temp root; no real /etc is written, and
# sudo, systemctl and journalctl are stubs that log every call.
#   1. DRY_RUN=1 (default), no drop-in -> prints file + diff, writes nothing
#   2. DRY_RUN=0 under a temp root -> writes the drop-in, no sudo, no restart
#   3. Second apply -> already current, nothing written
#   4. A differing drop-in -> DRY_RUN=1 diff shows old and new, file untouched
#   5. Red control: planted invalid cap fails the check; valid drop-in passes
#   6. Drop-in missing a key -> check fails
#   7. Invalid JOURNAL_CAP_MAX_USE -> refused, exit 2, nothing written
#   8. No vacuum: journalctl never called with --vacuum*, source has none
#   9. Root / in DRY_RUN=1 -> plans the restart, calls no sudo or systemctl
#  10. Invocation via the csi-spl-utl ./run harness
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/disk-journal-cap.func.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

BIN_DIR="$T/bin"
CALLS="$T/calls.log"
mkdir -p "$BIN_DIR"
: > "$CALLS"
for b in sudo systemctl journalctl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n[[ "%s" == journalctl ]] && echo "Archived and active journals take up 40M in the file system."\nexit 0\n' \
    "$b" "$CALLS" "$b" > "$BIN_DIR/$b"
  chmod +x "$BIN_DIR/$b"
done
export PATH="$BIN_DIR:$PATH"

# shellcheck source=/dev/null
source "$FUNC_SH"

new_root() { local r="$T/root$1"; mkdir -p "$r"; echo "$r"; }
dropin() { echo "$1/etc/systemd/journald.conf.d/60-disk-hygiene.conf"; }

# Case 1: dry run with no drop-in
R=$(new_root 1)
out=$(unset DRY_RUN; JOURNAL_CAP_ROOT=$R do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"FILE $(dropin "$R")"* && "$out" == *"+SystemMaxUse=500M"* \
      && "$out" == *"+SystemMaxFileSize=100M"* && "$out" == *"PLAN would write"* && ! -e "$(dropin "$R")" ]]; then
  pass "1. DRY_RUN=1 prints the file and its diff, writes nothing"
else
  fail "1. dry run (rc=$rc, out=$out)"
fi

# Case 2: real apply under a temp root
R=$(new_root 2)
: > "$CALLS"
out=$(DRY_RUN=0 JOURNAL_CAP_ROOT=$R do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 0 && -f "$(dropin "$R")" && "$out" == *"WROTE"* && "$out" == *"SKIP restart"* \
      && "$out" == *"PASS drop-in"* ]] && grep -qx 'SystemMaxUse=500M' "$(dropin "$R")" \
      && grep -qx 'SystemMaxFileSize=100M' "$(dropin "$R")" && ! grep -qE '^(sudo|systemctl) ' "$CALLS"; then
  pass "2. DRY_RUN=0 under a temp root writes the drop-in, no sudo, no restart"
else
  fail "2. apply (rc=$rc, out=$out, calls=$(cat "$CALLS"))"
fi

# Case 3: idempotent
before=$(stat -c %Y "$(dropin "$R")")
out=$(DRY_RUN=0 JOURNAL_CAP_ROOT=$R do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"already current"* && "$out" != *"WROTE"* && "$(stat -c %Y "$(dropin "$R")")" == "$before" ]]; then
  pass "3. second apply finds the drop-in current, writes nothing"
else
  fail "3. idempotent (rc=$rc, out=$out)"
fi

# Case 4: differing drop-in, dry run shows the diff and keeps the file
R=$(new_root 4)
mkdir -p "$(dirname "$(dropin "$R")")"
printf '[Journal]\nSystemMaxUse=1G\nSystemMaxFileSize=100M\n' > "$(dropin "$R")"
cp "$(dropin "$R")" "$T/case4.orig"
out=$(DRY_RUN=1 JOURNAL_CAP_ROOT=$R do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"-SystemMaxUse=1G"* && "$out" == *"+SystemMaxUse=500M"* ]] && cmp -s "$(dropin "$R")" "$T/case4.orig"; then
  pass "4. diff against the box shows old and new, file untouched"
else
  fail "4. diff (rc=$rc, out=$out)"
fi

# Case 5: red control - planted invalid cap fails, valid passes
R=$(new_root 5)
mkdir -p "$(dirname "$(dropin "$R")")"
printf '[Journal]\nSystemMaxUse=lots\nSystemMaxFileSize=100M\n' > "$(dropin "$R")"
red=$(JOURNAL_CAP_OP=check JOURNAL_CAP_ROOT=$R do_disk_journal_cap 2>&1); red_rc=$?
printf '[Journal]\nSystemMaxUse=500M\nSystemMaxFileSize=100M\n' > "$(dropin "$R")"
green=$(JOURNAL_CAP_OP=check JOURNAL_CAP_ROOT=$R do_disk_journal_cap 2>&1); green_rc=$?
echo "  red  (rc=$red_rc): $(grep -E '^(FAIL|OK|PASS)' <<< "$red" | tr '\n' ' ')"
echo "  green(rc=$green_rc): $(grep -E '^(FAIL|OK|PASS)' <<< "$green" | tr '\n' ' ')"
if [[ $red_rc -eq 1 && "$red" == *"SystemMaxUse=lots is not a size"* && $green_rc -eq 0 && "$green" == *"PASS drop-in"* ]]; then
  pass "5. red control: invalid cap fails the check (rc=1), valid drop-in passes (rc=0)"
else
  fail "5. red control (red_rc=$red_rc, green_rc=$green_rc)"
fi

# Case 6: a key missing
printf '[Journal]\nSystemMaxUse=500M\n' > "$(dropin "$R")"
out=$(JOURNAL_CAP_OP=check JOURNAL_CAP_ROOT=$R do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 1 && "$out" == *"SystemMaxFileSize not set under [Journal]"* ]]; then
  pass "6. drop-in missing SystemMaxFileSize fails the check"
else
  fail "6. missing key (rc=$rc, out=$out)"
fi

# Case 7: invalid requested cap is refused
R=$(new_root 7)
out=$(DRY_RUN=0 JOURNAL_CAP_ROOT=$R JOURNAL_CAP_MAX_USE=lots do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 2 && "$out" == *"JOURNAL_CAP_MAX_USE must be a size"* && ! -e "$(dropin "$R")" ]]; then
  pass "7. invalid JOURNAL_CAP_MAX_USE refused (rc=2), nothing written"
else
  fail "7. invalid cap (rc=$rc, out=$out)"
fi

# Case 8: never vacuums
if ! grep -q -- '--vacuum' "$CALLS" && ! grep -vE '^[[:space:]]*#' "$FUNC_SH" | grep -- '--vacuum' >/dev/null; then
  pass "8. no vacuum: journalctl never called with --vacuum*, none in the action"
else
  fail "8. vacuum seen ($(cat "$CALLS"))"
fi

# Case 9: root / in a dry run plans the restart, calls nothing privileged
: > "$CALLS"
out=$(DRY_RUN=1 JOURNAL_CAP_ROOT=/ do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"FILE /etc/systemd/journald.conf.d/60-disk-hygiene.conf"* \
      && ( "$out" == *"PLAN would restart systemd-journald"* || "$out" == *"already current"* ) ]] \
      && ! grep -qE '^(sudo|systemctl) ' "$CALLS"; then
  pass "9. root / dry run plans the restart, calls no sudo or systemctl"
else
  fail "9. root / dry run (rc=$rc, out=$out, calls=$(cat "$CALLS"))"
fi

# Case 10: via the ./run harness
R=$(new_root 10)
out=$(cd "$UTL_ROOT" && DRY_RUN=1 JOURNAL_CAP_ROOT=$R ./run -a do_disk_journal_cap 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" == *"PLAN would write $(dropin "$R")"* && ! -e "$(dropin "$R")" ]]; then
  pass "10. ./run -a do_disk_journal_cap works end-to-end"
else
  fail "10. harness (rc=$rc, out=$out)"
fi

if [[ $fails -eq 0 ]]; then
  echo "OK disk-journal-cap.tst.sh: all 10 cases passed"
  exit 0
fi
echo "FAIL disk-journal-cap.tst.sh: $fails case(s) failed"
exit 1
