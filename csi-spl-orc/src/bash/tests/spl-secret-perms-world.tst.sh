#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_secret_perms_world (SPL-1957) closes the gcp key, ssh key
#          and qwen state files of every home to other users, on a sandbox
#          tree of two fake homes. Placeholder content only.
#   1. refusals: DRY_RUN=2
#   2. CONTROL: spl_spw_open says a planted 644 key is open, a 600 one not
#   3. DRY_RUN is the default: rows by class/index/age, nothing changed, no
#      content, name or path printed
#   4. DRY_RUN=0: the world-readable gcp/ssh/qwen files lose other; a
#      foreign group loses its bits, the owner's own group keeps them; an
#      owner-only file, a non-secret file, a symlink and the dirs untouched;
#      a missing dir is no error; the undo file holds the old modes, 600
#   5. a second run changes nothing
#   6. CONTROL: the step with the o-rwx put back fails the apply
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

MARK="PLACEHOLDER-SECRET-$RANDOM$RANDOM"
H1="$T/home/one" H2="$T/home/two"
mkdir -p "$H1/.gcp/.org" "$H1/.ssh" "$H1/.qwen/sub" "$H2/.gcp"
gcp() { printf '{"type": "service_account", "%s": "%s"}\n' private_key "$MARK" >"$1"; chmod "$2" "$1"; }
mkssh() { printf -- '-----BEGIN OPENSSH %s KEY-----\n%s\n' PRIVATE "$MARK" >"$1"; chmod "$2" "$1"; }
gcp "$H1/.gcp/.org/key-open.json" 644
gcp "$H1/.gcp/.org/key-closed.json" 600
printf '{"note": "%s"}\n' "$MARK" >"$H1/.gcp/.org/not-a-key.json"; chmod 644 "$H1/.gcp/.org/not-a-key.json"
mkssh "$H1/.ssh/id_open" 644
mkssh "$H1/.ssh/id_closed" 600
printf 'ssh-ed25519 AAAA %s\n' "$MARK" >"$H1/.ssh/id_open.pub"; chmod 644 "$H1/.ssh/id_open.pub"
printf '%s\n' "$MARK" >"$H1/.qwen/settings.json"; chmod 664 "$H1/.qwen/settings.json"
printf '%s\n' "$MARK" >"$H1/.qwen/sub/state"; chmod 644 "$H1/.qwen/sub/state"
ln -s key-open.json "$H1/.gcp/.org/link.json"
gcp "$H2/.gcp/key-grp.json" 664
# a group of ours that is not our own-name group, for the foreign-group case
FG="$(id -Gn | tr ' ' '\n' | grep -vx "$(id -un)" | sed -n 1p)"
[[ -n "$FG" ]] && chgrp "$FG" "$H2/.gcp/key-grp.json"
chmod 755 "$H1/.gcp" "$H1/.ssh" "$H1/.qwen"

run_w() { SNIPPET=do_spl_secret_perms_world in_orc SECRET_PERMS_NO_SUDO=1 SECRET_PERMS_HOMES="$H1 $H2 $T/home/none" "$@" >"$T/o" 2>&1; }
snap() { (cd "$T/home" && find . -printf '%p %m %g\n' | sort); }
mode() { stat -c %a "$1"; }
no_leak() { ! grep -qE "$MARK|key-|id_|settings|state|link|not-a-key" "$T/o" && ! grep -qF "$T" "$T/o"; }

# --- 1. refusals ---------------------------------------------------------------------------
run_w DRY_RUN=2 && fail "accepts DRY_RUN=2" || pass "refuses DRY_RUN=2"

# --- 2. CONTROL: the open check ----------------------------------------------------------------
SNIPPET="spl_spw_open \"$H1/.gcp/.org/key-open.json\"" in_orc >/dev/null 2>&1 &&
  pass "CONTROL: a 644 key reads as open" || fail "CONTROL: a 644 key reads as closed"
SNIPPET="spl_spw_open \"$H1/.gcp/.org/key-closed.json\"" in_orc >/dev/null 2>&1 &&
  fail "CONTROL: a 600 key reads as open" || pass "CONTROL: a 600 key reads as closed"

# --- 3. DRY_RUN default ------------------------------------------------------------------------
before="$(snap)"
run_w; rc=$?
want=5
[[ $rc -eq 0 && "$(snap)" == "$before" ]] && grep -q "OK DRY_RUN the secret files: $want would change" "$T/o" &&
  pass "dry run by default: $want would change, nothing changed" || fail "dry run: rc=$rc out=$(cat "$T/o")"
grep -qx "summary gcp files=3 open=2 changed=2" "$T/o" && grep -qx "summary ssh files=2 open=1 changed=1" "$T/o" &&
  grep -qx "summary qwen files=2 open=2 changed=2" "$T/o" && grep -qE "^gcp [0-9] age=[0-9]+d mode=644 -> mode=640 change=yes$" "$T/o" &&
  pass "dry run rows: by class, index and age; summary per class" || fail "dry run rows: $(cat "$T/o")"
no_leak && pass "dry run: no content, no file name, no path" || fail "dry run leaks: $(cat "$T/o")"

# --- 4. DRY_RUN=0 ------------------------------------------------------------------------------
U="$T/undo-dir/undo"; mkdir -p "$T/undo-dir"
# a default ACL that hands the group rw beats the umask: the file is still 600
setfacl -d -m g::rw- "$T/undo-dir" 2>/dev/null || echo "SKIP-PART: no ACL on the temp fs, the undo dir is plain"
run_w DRY_RUN=0 SECRET_PERMS_UNDO="$U"; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK the secret files: 5 changed, none open to other" "$T/o" &&
  [[ "$(mode "$H1/.gcp/.org/key-open.json")" == 640 && "$(mode "$H1/.ssh/id_open")" == 640 &&
     "$(mode "$H1/.qwen/settings.json")" == 660 && "$(mode "$H1/.qwen/sub/state")" == 640 ]] &&
  pass "applied: world-readable gcp/ssh/qwen files lose other, the own group keeps its bits" || fail "apply: rc=$rc out=$(cat "$T/o")"
if [[ -n "$FG" ]]; then
  [[ "$(mode "$H2/.gcp/key-grp.json")" == 600 ]] && pass "a foreign group loses its bits (664 -> 600)" ||
    fail "foreign group: $(mode "$H2/.gcp/key-grp.json")"
else
  echo "SKIP: the test user is in no group but its own: the foreign-group case is not built"
fi
[[ "$(mode "$H1/.gcp/.org/key-closed.json")" == 600 && "$(mode "$H1/.ssh/id_closed")" == 600 ]] &&
  pass "owner-only files untouched" || fail "owner-only touched"
[[ "$(mode "$H1/.gcp/.org/not-a-key.json")" == 644 && "$(mode "$H1/.ssh/id_open.pub")" == 644 && -L "$H1/.gcp/.org/link.json" ]] &&
  pass "a non-secret json, a public key and a symlink untouched" || fail "non-secret touched"
[[ "$(mode "$H1/.gcp")" == 755 && "$(mode "$H1/.ssh")" == 755 && "$(mode "$H1/.qwen")" == 755 ]] &&
  pass "no dir changed" || fail "a dir changed"
! grep -q 'home/none' "$T/o" && pass "a missing home is no error" || fail "missing home: $(cat "$T/o")"
[[ "$(mode "$U")" == 600 && "$(wc -l <"$U")" == 5 ]] && grep -q "^644 $H1/.gcp/.org/key-open.json$" "$U" &&
  pass "undo file: 5 old modes, mode 600" || fail "undo: $(mode "$U") $(cat "$U")"
no_leak && pass "apply: no content, no file name, no path" || fail "apply leaks: $(cat "$T/o")"

# --- 5. idempotent -----------------------------------------------------------------------------
run_w DRY_RUN=0 && grep -q "^OK the secret files: 0 changed" "$T/o" && pass "second run: nothing to change" || fail "rerun: $(cat "$T/o")"

# --- 6. CONTROL: the step without the o-rwx fails the apply -----------------------------------
gcp "$H1/.gcp/.org/key-open.json" 644
SNIPPET='eval "$(declare -f spl_spw_scan | sed "s/chmod \"\$after\"/chmod 644/")"; do_spl_secret_perms_world' \
  in_orc SECRET_PERMS_NO_SUDO=1 SECRET_PERMS_HOMES="$H1" DRY_RUN=0 >"$T/o" 2>&1 &&
  fail "CONTROL: the step that leaves other a read passes: $(cat "$T/o")" ||
  { grep -q "^FAIL gcp 1 age=0d is still open after the fix" "$T/o" && [[ "$(mode "$H1/.gcp/.org/key-open.json")" == 644 ]] &&
    pass "CONTROL: the step that leaves other a read fails the apply" || fail "CONTROL: $(cat "$T/o")"; }

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
