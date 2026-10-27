#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y19 - no clear-text git credential store
# (SPL-3761; a global credential.helper=store left a GitHub token in
# ~/.git-credentials on one box, 2026-10-26). Sandbox homes only: every run
# sets HOME and SPOOL_INSTALL_GIT_CRED_HOMES, so no real home is ever read.
#   1. CONTROL: the sandbox git config resolves credential.helper=store, as on
#      the box (the fixture is the defect)
#   2. dry run: plans both changes, writes nothing
#   3. install: every store helper gone (global and per-url), the other helper
#      kept, the backup holds the old file, ~/.git-credentials is 0 bytes and
#      its content never reaches the output
#   4. re-run: nothing to do, the config byte-identical, no new backup
#   5. the other users' homes are fixed too; a file this user cannot write is
#      named (WARN) and left as it is
#   6. SPOOL_INSTALL_GIT_CRED=0 skips
#   7. the users: $HOME, then the agent and box users of the box config, this
#      user and an unknown user not looked up; a sandbox HOME (not this user's
#      passwd home) resolves no other home (print only, nothing written)
#   8. install.sh calls the step once, only with --fleet
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
STEP="$FEAT/steps/y19-git-credential-store.sh"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
FAKE="fake-cred-$$-not-a-token"
seed() {  # HOME: a gitconfig with the defect, and a filled store
  mkdir -p "$1"
  printf '[user]\n\tname = t\n[credential]\n\thelper = store\n[credential "https://example.com"]\n\thelper = store --file x\n\thelper = cache\n' >"$1/.gitconfig"
  printf 'https://u:%s@example.com\n' "$FAKE" >"$1/.git-credentials"
}
helpers() { git config --file "$1/.gitconfig" --get-regexp '^credential\.(.*\.)?helper$' | sort | tr '\n' ';'; }
inst() {  # HOME OTHER-HOMES DRY
  env -u SPOOL_AGENT_USER -u SPOOL_BOX_USER HOME="$1" SPOOL_INSTALL_GIT_CRED_HOMES="$2" \
    bash -c '[ -r "$1" ] || { echo "no step $1"; exit 9; }; . "$1"; spool_install_git_credential_store "$2"' _ "$STEP" "$3" 2>&1
}
H="$T/agent"; O="$T/human"
seed "$H"; seed "$O"

# 1. control
if [ "$(env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$H" git config --global --get credential.helper)" = store ]
then pass "control: the sandbox global git config has credential.helper=store"; else fail "control: fixture"; fi

# 2. dry run
sum="$(cat "$H/.gitconfig" "$H/.git-credentials" | cksum)"
out="$(inst "$H" "$H" 1)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"would: back up $H/.gitconfig and remove its credential.helper=store"* ]] &&
  [[ "$out" == *"would: truncate $H/.git-credentials to 0 bytes"* ]] && [ "$(cat "$H/.gitconfig" "$H/.git-credentials" | cksum)" = "$sum" ] &&
  ! ls "$H"/.gitconfig.bak-spool-install.* >/dev/null 2>&1
then pass "dry run: plans both, writes nothing"; else fail "dry run rc=$rc: $out"; fi

# 3. install
cp "$H/.gitconfig" "$T/orig"
out="$(inst "$H" "$H" 0)"; rc=$?
bak="$(ls "$H"/.gitconfig.bak-spool-install.* 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$(helpers "$H")" = "credential.https://example.com.helper cache;" ]
then pass "install: both store helpers gone, the cache helper kept"; else fail "install rc=$rc helpers=$(helpers "$H"): $out"; fi
if [ -n "$bak" ] && cmp -s "$bak" "$T/orig" && [[ "$out" == *"removed credential.helper=store from $H/.gitconfig (backup $bak)"* ]]
then pass "install: backup first, one line naming it"; else fail "backup: $bak $out"; fi
if [ -e "$H/.git-credentials" ] && [ ! -s "$H/.git-credentials" ] && [[ "$out" == *"truncated $H/.git-credentials to 0 bytes"* ]] && [[ "$out" != *"$FAKE"* ]]
then pass "install: ~/.git-credentials truncated to 0 bytes, said so, content never printed"; else fail "store: $out"; fi
if [ "$(env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$H" git config --global --get-all credential.helper)" = "" ]
then pass "install: git resolves no global credential.helper any more"; else fail "still a global helper"; fi

# 4. re-run
cp "$H/.gitconfig" "$T/after"
out="$(inst "$H" "$H" 0)"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ] && cmp -s "$H/.gitconfig" "$T/after" && [ "$(ls "$H"/.gitconfig.bak-spool-install.* | wc -l)" = 1 ]
then pass "re-run: nothing to do, nothing changed"; else fail "re-run rc=$rc: $out"; fi

# 5. the other users' homes; a file this user cannot write
R="$T/ro"; seed "$R"; chmod a-w "$R/.gitconfig" "$R/.git-credentials"
out="$(inst "$T/none" "$O $R" 0)"; rc=$?
if [ "$rc" = 0 ] && [ "$(helpers "$O")" = "credential.https://example.com.helper cache;" ] && [ ! -s "$O/.git-credentials" ]
then pass "other home: fixed as well"; else fail "other home rc=$rc: $out"; fi
if [ "$(id -u)" = 0 ]; then pass "read-only file: SKIP as root (root writes it)"
elif [[ "$out" == *"WARN $R/.gitconfig sets credential.helper=store and $(id -un) cannot write it"* ]] &&
  [[ "$out" == *"WARN $R/.git-credentials is not empty"* ]] && [ -s "$R/.git-credentials" ] && [[ "$(helpers "$R")" == *" store;"* ]]
then pass "read-only file: named (WARN), left as it is"; else fail "read-only: $out"; fi

# 6. skip
S="$T/skip"; seed "$S"
out="$(SPOOL_INSTALL_GIT_CRED=0 inst "$S" "$S" 0)"
if [[ "$out" == *"skipped (SPOOL_INSTALL_GIT_CRED=0)"* ]] && [ -s "$S/.git-credentials" ]; then pass "SPOOL_INSTALL_GIT_CRED=0 skips"; else fail "skip: $out"; fi

# 7. the users (print only)
printf 'SPOOL_AGENT_USER=%s\nSPOOL_BOX_USER=nosuchuser-%s\n' "$(id -un)" "$$" >"$T/box.env"
RH="$(getent passwd "$(id -un)" | cut -d: -f6)"
homes() { env -u SPOOL_AGENT_USER -u SPOOL_BOX_USER -u SPOOL_INSTALL_GIT_CRED_HOMES SPOOL_BOX_ENV="$T/box.env" "$@" bash -c '. "$1"; _y19_homes' _ "$STEP" 2>&1; }
out="$(homes HOME="$RH")"
if [ "$out" = "$RH" ]; then pass "users: \$HOME; this user is not looked up again, an unknown user has no home"; else fail "users: $out"; fi
out="$(homes HOME="$RH" SPOOL_BOX_USER=root)"
if [ "$out" = "$RH"$'\n'"$(getent passwd root | cut -d: -f6)" ]; then pass "users: SPOOL_BOX_USER from the environment wins, home from passwd"; else fail "users env: $out"; fi
out="$(homes HOME="$T/me" SPOOL_BOX_USER=root)"
if [[ "$out" == "$T/me"$'\n'*"the other users' homes are left alone" ]]; then pass "users: a sandbox HOME resolves no other home"; else fail "users sandbox: $out"; fi

# 8. install.sh wiring
c="$(grep -c 'spool_install_git_credential_store "\$DRY"' "$FEAT/install.sh")"
if [ "$c" = 1 ] && grep -q '^\[ "\$FLEET" = 1 \] && { \. "\$_here/steps/y19-git-credential-store.sh"' "$FEAT/install.sh"
then pass "install.sh calls the step once, only with --fleet"; else fail "install.sh wiring: $c call(s)"; fi

echo "--- y19 git credential store: $((n - fails))/$n passed"
[ "$fails" = 0 ]
