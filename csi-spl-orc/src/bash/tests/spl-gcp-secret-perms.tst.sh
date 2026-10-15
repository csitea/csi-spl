#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_gcp_secret_perms (SPL-1924) closes the box owner's GCP key
#          dir to other users and keeps a named ACL entry's read, on a temp
#          dir built in the shapes found on a shared-ACL box. Placeholder
#          content only.
#   1. refusals: DRY_RUN=2, a dir that does not exist
#   2. CONTROL: spl_gsp_check fails on today's shapes: 674 (other::r--) and
#      a named entry's read cancelled by mask::---
#   3. DRY_RUN is the default: rows, nothing changed, no content or name
#   4. DRY_RUN=0: every file owner rw, other ---, the named entry reads r--
#      (mask r--), the group never wider; the dir and its default ACL closed
#      to other; subdirs and symlinks untouched
#   5. a second run changes nothing
# Needs setfacl and a temp fs with ACLs: else SKIP, with the reason.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

D="$T/keys"
mkdir -p "$D/sub"
if ! command -v setfacl >/dev/null || ! command -v getfacl >/dev/null || ! setfacl -m u:nobody:r-x "$D" 2>/dev/null; then
  echo "SKIP: setfacl/getfacl missing or the temp fs has no ACL support: the shapes cannot be built"
  echo "ALL PASS"; exit 0
fi
MARK="PLACEHOLDER-KEY-$RANDOM$RANDOM"
mk() { printf '%s %s\n' "$MARK" "$1" >"$D/$1"; }
# the dir: other r-x, a default ACL giving the named user and other r-x
setfacl -m d:u:nobody:r-x,d:o::r-x "$D"; chmod 755 "$D"
# today's prd key shape: 674, named r-x, mask rwx, other r--
mk key-a.json; setfacl -m u:nobody:r-x "$D/key-a.json"; chmod 674 "$D/key-a.json"
# the overlay shape: chmod 600 over a named entry -> mask::---
mk csi-spl-private.yaml; setfacl -m u:nobody:r-x "$D/csi-spl-private.yaml"; chmod 600 "$D/csi-spl-private.yaml"
# a plain file, no named entry, 744
mk key-b.json; setfacl -b "$D/key-b.json"; chmod 744 "$D/key-b.json"
# a subdir file and a symlink: not touched
printf '%s\n' "$MARK" >"$D/sub/inner"; chmod 644 "$D/sub/inner"
ln -s key-a.json "$D/link.json"

run_perms() { SNIPPET=do_spl_gcp_secret_perms in_orc GCP_KEY_DIR="$D" "$@" >"$T/o" 2>&1; }
snap() { (cd "$D" && getfacl -RpE . 2>/dev/null; stat -c '%n %a' . ./* ./sub/*); }
chk() { SNIPPET="spl_gsp_check \"$1\"" in_orc >/dev/null 2>&1; }
no_leak() { ! grep -qE "$MARK|key-a|key-b|csi-spl-private|inner|link\.json" "$T/o"; }

# --- 1. refusals ---------------------------------------------------------------------------
run_perms DRY_RUN=2 && fail "accepts DRY_RUN=2" || pass "refuses DRY_RUN=2"
SNIPPET=do_spl_gcp_secret_perms in_orc GCP_KEY_DIR="$T/none" >"$T/o" 2>&1 && fail "accepts a missing dir" ||
  { grep -q "FATAL GCP_KEY_DIR is not a dir" "$T/o" && pass "refuses a missing dir" || fail "missing dir: $(cat "$T/o")"; }

# --- 2. CONTROL: the check fails on today's shapes ---------------------------------------------
chk "$D/key-a.json" && fail "CONTROL: the check passes 674 (other::r--)" || pass "CONTROL: the check fails on 674"
chk "$D/csi-spl-private.yaml" && fail "CONTROL: the check passes a named read under mask::---" ||
  pass "CONTROL: the check fails on mask::--- over a named read"
chk "$D/key-b.json" && fail "CONTROL: the check passes 744" || pass "CONTROL: the check fails on 744"

# --- 3. DRY_RUN default ------------------------------------------------------------------------
before="$(snap)"
run_perms; rc=$?
[[ $rc -eq 0 && "$(snap)" == "$before" ]] && grep -q "OK DRY_RUN .*: 4 row(s) would change" "$T/o" &&
  pass "dry run by default: 4 rows would change, nothing changed" || fail "dry run: rc=$rc out=$(cat "$T/o")"
grep -q "^file [0-9] key mode=674 .* -> mode=640 acl=user::rw-,user:nobody:r--,group::r--,mask::r--,other::--- change=yes$" "$T/o" &&
  grep -q "^file [0-9] overlay mode=600 .* -> mode=640 acl=user::rw-,user:nobody:r--,group::---,mask::r--,other::--- change=yes$" "$T/o" &&
  grep -q "^skipped 2 " "$T/o" && pass "dry run rows: the targets by index and role" || fail "dry run rows: $(cat "$T/o")"
no_leak && pass "dry run: no content, no file name" || fail "dry run leaks: $(cat "$T/o")"

# --- 4. DRY_RUN=0 ------------------------------------------------------------------------------
run_perms DRY_RUN=0; rc=$?
ok=1
for f in key-a.json key-b.json csi-spl-private.yaml; do
  chk "$D/$f" || ok=0
  [[ "$(stat -c %a "$D/$f")" =~ ^6[04]0$ ]] || ok=0
done
[[ $rc -eq 0 && $ok == 1 ]] && grep -q "^OK .*: 4 row(s) changed" "$T/o" && pass "applied: every file owner rw, other ---, the check passes" ||
  fail "apply: rc=$rc out=$(cat "$T/o")"
getfacl -cp "$D/csi-spl-private.yaml" 2>/dev/null | grep -x 'user:nobody:r--' >/dev/null &&
  getfacl -cp "$D/csi-spl-private.yaml" 2>/dev/null | grep -x 'mask::r--' >/dev/null &&
  getfacl -cp "$D/csi-spl-private.yaml" 2>/dev/null | grep -x 'group::---' >/dev/null &&
  pass "the cancelled named entry reads again, read-only; the group stays closed" || fail "overlay acl: $(getfacl -cp "$D/csi-spl-private.yaml")"
[[ -z "$(getfacl -cpE "$D/key-a.json" 2>/dev/null | grep -E '^[a-z:]*:[a-z0-9-]*:.*[wx]' | grep -vx 'user::rw-')" ]] &&
  pass "674 shape: nothing but the owner writes, nobody executes" || fail "key-a acl: $(getfacl -cp "$D/key-a.json")"
[[ "$(stat -c %a "$D")" == 750 ]] && getfacl -cpd "$D" 2>/dev/null | grep -x 'other::---' >/dev/null &&
  pass "the dir and its default ACL are closed to other" || fail "dir: $(stat -c %a "$D") $(getfacl -cpd "$D")"
[[ "$(stat -c %a "$D/sub/inner")" == 644 && -L "$D/link.json" ]] && pass "subdir file and symlink untouched" || fail "subdir/symlink touched"
no_leak && pass "apply: no content, no file name" || fail "apply leaks: $(cat "$T/o")"

# --- 5. idempotent -----------------------------------------------------------------------------
run_perms DRY_RUN=0 && grep -q "^OK .*: 0 row(s) changed" "$T/o" && pass "second run: nothing to change" || fail "rerun: $(cat "$T/o")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
