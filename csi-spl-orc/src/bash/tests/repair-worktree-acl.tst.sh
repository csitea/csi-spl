#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_repair_worktree_acl gives the named agent user write on a
#          worktree whose default ACL is user:<name>:r-x (that entry beats
#          the group, so the user cannot create the pre-push log).
#   1. CONTROL, before the action: a fresh subdir inherits r-x and the named
#      user cannot write it. If this write succeeds, the probe cannot see
#      the hole and the test fails (it would stay green with no action).
#   2. DRY_RUN=1 (the default) prints the path count and changes nothing.
#   3. DRY_RUN=0 sets u:rwx + default u:rwx on the root and on every
#      */dat/log/bash, and u:rw on the .log files there. A fresh subdir is
#      then writable. A file that is not a log is left alone. A second run
#      is a no-op success.
#   4. The root defaults to <checkout>-wt when WORKTREE_DIR is unset, and
#      the user defaults to SPOOL_AGENT_USER in the box env.
#   5. Refusals: bad DRY_RUN, unknown user, empty user, relative root,
#      missing root, root /.
# Skip (exit 0) where setfacl is missing. The write probe needs sudo -n and
# a user who is not the owner; without that, the ACL text is the proof and
# the control still fails the test if the fixture is not restrictive.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }
if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
  skip "no setfacl: do_repair_worktree_acl not exercised"
  echo "--- 0 failure(s)"
  exit 0
fi

T=$(mktemp -d)
trap 'sudo -n rm -rf "$T" 2>/dev/null || rm -rf "$T"' EXIT
chmod 711 "$T"
U="$(id -un)"
if id nobody >/dev/null 2>&1 && [[ "$U" != nobody ]]; then
  NAMED=nobody
else
  NAMED="$(getent passwd | awk -F: -v me="$(id -u)" '$3 >= 1 && $3 != me && $1 != "root" { print $1; exit }')"
fi
[[ -n "${NAMED:-}" ]] || { skip "no second OS user to name in the ACL"; echo "--- 0 failure(s)"; exit 0; }
if sudo -n true >/dev/null 2>&1 && [[ "$NAMED" != "$U" ]] && sudo -n -u "$NAMED" true >/dev/null 2>&1; then
  if ! sudo -n -u "$NAMED" test -x "$T" 2>/dev/null; then
    rm -rf "$T"
    T=$(mktemp -d /tmp/repair-worktree-acl.XXXXXX)
    chmod 711 "$T"
  fi
  CAN_SUDO=1
else
  CAN_SUDO=0
fi

in_orc() {
  env -u DRY_RUN -u WORKTREE_DIR -u SPOOL_AGENT_USER -u SPOOL_ROOT -u SPOOL_BOX_ENV \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" LDE_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    # shellcheck disable=SC1091
    source "$PROJ_PATH/src/bash/run/repair-worktree-acl.func.sh"
    eval "$SNIPPET"'
}

acl_has() {
  local text
  text="$(getfacl -p "$1" 2>/dev/null | sed 's/[[:space:]]*#effective:.*//')"
  grep -qx "$2" <<<"$text"
}
named_can_write() { sudo -n -u "$NAMED" touch "$1/wrote-$$" 2>/dev/null; }

# A tree whose default ACL is the bug: named user r-x, inherited by a
# nested */dat/log/bash and by a file that is not a log.
plant() {
  local root="$1"
  mkdir -p "$root"
  setfacl -m "u:${NAMED}:r-x" -m "d:u:${NAMED}:r-x" "$root"
  mkdir -p "$root/lane/mod/dat/log/bash"
  echo old >"$root/lane/mod/dat/log/bash/run.log"
  echo keep >"$root/lane/mod/keep.txt"
}

# --- 1. CONTROL ---------------------------------------------------------------
ROOT="$T/wt"
plant "$ROOT"
mkdir -p "$ROOT/ctl"
if acl_has "$ROOT/ctl" "user:${NAMED}:r-x" && ! acl_has "$ROOT/ctl" "user:${NAMED}:rwx"; then
  pass "control: a fresh subdir inherits user:${NAMED}:r-x, not rwx"
else
  fail "control: fixture ACL is not the restrictive named entry -- the probe cannot see the hole"
fi
if [[ "$CAN_SUDO" == 1 ]]; then
  if named_can_write "$ROOT/ctl"; then
    fail "control: ${NAMED} could write before the action -- the probe cannot see the hole"
  else
    pass "control: ${NAMED} cannot write a fresh subdir, so a later success is the action"
  fi
else
  skip "no sudo -n to ${NAMED}: write probe skipped, ACL text is the proof"
fi

# --- 2. dry run changes nothing ----------------------------------------------
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="$ROOT" SPOOL_AGENT_USER="$NAMED" >"$T/dry.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && grep -q 'would set 3 path(s)' "$T/dry.out" && grep -q 'nothing changed' "$T/dry.out" \
  && pass "dry run (default): would set 3 path(s), nothing changed" \
  || fail "dry run rc=$rc: $(tail -3 "$T/dry.out")"
acl_has "$ROOT/lane/mod/dat/log/bash" "user:${NAMED}:r-x" && ! acl_has "$ROOT/lane/mod/dat/log/bash" "user:${NAMED}:rwx" \
  && pass "dry run left the log dir at r-x" || fail "dry run changed the log dir ACL"

# --- 3. apply -----------------------------------------------------------------
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="$ROOT" SPOOL_AGENT_USER="$NAMED" DRY_RUN=0 >"$T/apply.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && grep -q 'set 3 path(s)' "$T/apply.out" && pass "DRY_RUN=0 sets 3 path(s)" \
  || fail "apply rc=$rc: $(tail -3 "$T/apply.out")"
acl_has "$ROOT" "user:${NAMED}:rwx" && acl_has "$ROOT" "default:user:${NAMED}:rwx" \
  && pass "worktree root has u:rwx and default u:rwx" || fail "root ACL: $(getfacl -p "$ROOT" | grep "$NAMED")"
acl_has "$ROOT/lane/mod/dat/log/bash" "user:${NAMED}:rwx" && acl_has "$ROOT/lane/mod/dat/log/bash" "default:user:${NAMED}:rwx" \
  && pass "nested dat/log/bash has u:rwx and default u:rwx" \
  || fail "log dir ACL: $(getfacl -p "$ROOT/lane/mod/dat/log/bash" | grep "$NAMED")"
acl_has "$ROOT/lane/mod/dat/log/bash/run.log" "user:${NAMED}:rw-" \
  && pass "the .log file is u:rw" || fail "log file ACL: $(getfacl -p "$ROOT/lane/mod/dat/log/bash/run.log" | grep "$NAMED")"
acl_has "$ROOT/lane/mod/keep.txt" "user:${NAMED}:r-x" && ! acl_has "$ROOT/lane/mod/keep.txt" "user:${NAMED}:rw-" \
  && pass "a file that is not a log is left at r-x" || fail "keep.txt ACL changed: $(getfacl -p "$ROOT/lane/mod/keep.txt" | grep "$NAMED")"
mkdir -p "$ROOT/fresh"
acl_has "$ROOT/fresh" "user:${NAMED}:rwx" && pass "a fresh subdir inherits u:rwx" \
  || fail "fresh subdir ACL: $(getfacl -p "$ROOT/fresh" | grep "$NAMED")"
if [[ "$CAN_SUDO" == 1 ]]; then
  if named_can_write "$ROOT/fresh"; then
    pass "a fresh subdir is writable for ${NAMED}"
  else
    fail "a fresh subdir is still not writable for ${NAMED}"
  fi
  if sudo -n -u "$NAMED" sh -c "echo more >>'$ROOT/lane/mod/dat/log/bash/run.log'" 2>/dev/null \
     && sudo -n -u "$NAMED" touch "$ROOT/lane/mod/dat/log/bash/new.log" 2>/dev/null; then
    pass "${NAMED} can append the old log and create a new one"
  else
    fail "${NAMED} still cannot write in the log dir"
  fi
fi
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="$ROOT" SPOOL_AGENT_USER="$NAMED" DRY_RUN=0 >"$T/again.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && acl_has "$ROOT/lane/mod/dat/log/bash/run.log" "user:${NAMED}:rw-" \
  && pass "a second apply is idempotent" || fail "second apply rc=$rc: $(tail -2 "$T/again.out")"

# --- 4. defaults: <checkout>-wt and the box env ------------------------------
APP="$T/checkout"
DEF="$T/checkout-wt"
plant "$DEF"
printf 'SPOOL_AGENT_USER=%s\n' "$NAMED" >"$T/box.env"
SNIPPET='do_repair_worktree_acl' in_orc APP_PATH="$APP" SPOOL_BOX_ENV="$T/box.env" DRY_RUN=0 >"$T/def.out" 2>&1
rc=$?
[[ $rc -eq 0 ]] && acl_has "$DEF/lane/mod/dat/log/bash" "user:${NAMED}:rwx" \
  && grep -q "under $DEF" "$T/def.out" \
  && pass "unset WORKTREE_DIR uses <checkout>-wt and the box env names the user" \
  || fail "defaults rc=$rc: $(tail -3 "$T/def.out")"

# --- 5. refusals --------------------------------------------------------------
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="$ROOT" SPOOL_AGENT_USER="$NAMED" DRY_RUN=2 >"$T/bad-dry.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q 'DRY_RUN must be 0 or 1' "$T/bad-dry.out" && pass "DRY_RUN other than 0 or 1 is refused" \
  || fail "bad DRY_RUN rc=$rc: $(tail -1 "$T/bad-dry.out")"
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="$ROOT" SPOOL_AGENT_USER="no-such-user-$$" DRY_RUN=1 >"$T/bad-user.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q 'no such OS user' "$T/bad-user.out" && pass "an unknown user is refused" \
  || fail "unknown user rc=$rc: $(tail -1 "$T/bad-user.out")"
: >"$T/empty.env"
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="$ROOT" SPOOL_BOX_ENV="$T/empty.env" DRY_RUN=1 >"$T/no-user.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q 'SPOOL_AGENT_USER is empty' "$T/no-user.out" && pass "an empty user is refused" \
  || fail "empty user rc=$rc: $(tail -1 "$T/no-user.out")"
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="relative/wt" SPOOL_AGENT_USER="$NAMED" DRY_RUN=1 >"$T/rel.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q 'absolute path' "$T/rel.out" && pass "a relative root is refused" \
  || fail "relative root rc=$rc: $(tail -1 "$T/rel.out")"
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR="$T/missing-wt" SPOOL_AGENT_USER="$NAMED" DRY_RUN=1 >"$T/miss.out" 2>&1
rc=$?
[[ $rc -ne 0 && ! -e "$T/missing-wt" ]] && grep -q 'does not exist' "$T/miss.out" && pass "a missing root is refused and not created" \
  || fail "missing root rc=$rc"
SNIPPET='do_repair_worktree_acl' in_orc WORKTREE_DIR=/ SPOOL_AGENT_USER="$NAMED" DRY_RUN=1 >"$T/slash.out" 2>&1
rc=$?
[[ $rc -ne 0 ]] && grep -q 'absolute path' "$T/slash.out" && pass "the filesystem root is refused" \
  || fail "root / rc=$rc: $(tail -1 "$T/slash.out")"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
