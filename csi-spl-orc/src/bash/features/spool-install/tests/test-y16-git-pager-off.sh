#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y16 - an agent's git never opens a pager
# (SPL-2432; agy lanes a-271 and a-235 hung in `git log`, 2026-10-17).
#   1. CONTROL: a sandbox HOME with no git config, on a pseudo-tty
#      (`script -qc`): `timeout 5 git log` is killed (rc 124) - git started
#      less and waited for a key, as on today's boxes
#   2. dry run: plans, writes nothing
#   3. install: core.pager=cat; the same `git log` on a tty returns rc 0,
#      also with PAGER=less in the environment
#   4. re-run: already current, the config file byte-identical
#   5. a core.pager set by hand is kept and named; ..._FORCE=1 replaces it;
#      SPOOL_INSTALL_GIT_PAGER=0 skips
#   6. install.sh calls the step once, only with --fleet
#   7. do_spl_git_pager_off_install, dry run, for this user: rc 0, the real
#      git config untouched
# Parts 1 and 3 need `script` (util-linux); without it they SKIP.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
STEP="$FEAT/steps/y16-git-pager-off.sh"
fails=0 n=0 skips=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { skips=$((skips + 1)); echo "SKIP: $1"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
H="$T/home"
mkdir -p "$H"
inst() { env -u GIT_CONFIG_GLOBAL bash -c '. "$1"; spool_install_git_pager_off "$2" "$3"' _ "$STEP" "$@" 2>&1; }
cfg() { env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$1" git config --global --get core.pager; }

# a repo whose log is longer than any screen
R="$T/repo"
git init -q "$R"
for i in $(seq 150); do git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "commit $i"; done

# git log on a pseudo-tty with HOME=$1, nothing else from our environment
tty_log() {
  (cd "$R" && env -i HOME="$1" PATH="$PATH" TERM=xterm ${2:+PAGER="$2"} \
    timeout 15 script -qec 'timeout 5 git log' /dev/null </dev/null >/dev/null 2>&1)
}
HAVE_SCRIPT=0
command -v script >/dev/null 2>&1 && HAVE_SCRIPT=1

# 1. control
if [ "$HAVE_SCRIPT" = 1 ]; then
  tty_log "$H"; rc=$?
  if [ "$rc" = 124 ]; then pass "control: no core.pager, git log on a tty hangs in the pager (rc 124)"
  else fail "control: expected rc 124 (hang), got $rc"; fi
else skip "control: no script(1)"; fi

# 2. dry run
out="$(inst "$H" 1)"
if [ ! -e "$H/.gitconfig" ] && [[ "$out" == *"would: git config --global core.pager cat"* ]]
then pass "dry run: plans, writes nothing"; else fail "dry run: $out"; fi

# 3. install
out="$(inst "$H" 0)"; rc=$?
if [ "$rc" = 0 ] && [ "$(cfg "$H")" = cat ]; then pass "install: core.pager=cat"; else fail "install rc=$rc: $out"; fi
if [ "$HAVE_SCRIPT" = 1 ]; then
  tty_log "$H"; rc=$?
  if [ "$rc" = 0 ]; then pass "git log on a tty returns (rc 0)"; else fail "git log on a tty after install: rc $rc"; fi
  tty_log "$H" less; rc=$?
  if [ "$rc" = 0 ]; then pass "git log on a tty returns with PAGER=less"; else fail "PAGER=less after install: rc $rc"; fi
else skip "tty after install: no script(1)"; fi

# 4. re-run
cp "$H/.gitconfig" "$T/before"
out="$(inst "$H" 0)"
if [[ "$out" == *"already current"* ]] && cmp -s "$H/.gitconfig" "$T/before"
then pass "re-run: already current, nothing changed"; else fail "re-run: $out"; fi

# 5. hand-set value, force, skip
H2="$T/home2"; mkdir -p "$H2"
env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$H2" git config --global core.pager "less -S"
out="$(inst "$H2" 0)"; rc=$?
if [ "$rc" = 0 ] && [ "$(cfg "$H2")" = "less -S" ] && [[ "$out" == *"keeps core.pager='less -S'"* ]]
then pass "hand-set core.pager: kept and named"; else fail "hand-set: rc=$rc $out"; fi
out="$(SPOOL_INSTALL_GIT_PAGER_FORCE=1 inst "$H2" 0)"
if [ "$(cfg "$H2")" = cat ] && [[ "$out" == *"(was 'less -S')"* ]]; then pass "FORCE=1 replaces it"; else fail "force: $out"; fi
H3="$T/home3"; mkdir -p "$H3"
out="$(SPOOL_INSTALL_GIT_PAGER=0 inst "$H3" 0)"
if [[ "$out" == *"skipped"* ]] && [ ! -e "$H3/.gitconfig" ]; then pass "SPOOL_INSTALL_GIT_PAGER=0 skips"; else fail "skip: $out"; fi

# 6. install.sh wiring
c="$(grep -c 'spool_install_git_pager_off "\$HOME" "\$DRY"' "$FEAT/install.sh")"
if [ "$c" = 1 ] && grep -q '^\[ "\$FLEET" = 1 \] && { \. "\$_here/steps/y16-git-pager-off.sh"' "$FEAT/install.sh"
then pass "install.sh calls the step once, only with --fleet"; else fail "install.sh wiring: $c call(s)"; fi

# 7. the two-user action, dry run, this user only
real="$(git config --global --list 2>/dev/null | cksum)"
out="$(env -u GIT_CONFIG_GLOBAL PROJ_PATH="$ORC" GIT_PAGER_OFF_USERS="$(id -un)" DRY_RUN=1 bash -c '
  do_log() { echo "$*"; }; do_require_bin() { command -v "$1" >/dev/null; }
  . "$1/src/bash/run/spl-git-pager-off-install.func.sh" && do_spl_git_pager_off_install' _ "$ORC" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"OK git pager off: $(id -un) (DRY_RUN=1)"* ]] && [ "$(git config --global --list 2>/dev/null | cksum)" = "$real" ]
then pass "action dry run: rc 0, the real git config untouched"; else fail "action: rc=$rc $out"; fi

echo "--- y16 git pager off: $((n - fails))/$n passed, $skips skipped"
[ "$fails" = 0 ]
