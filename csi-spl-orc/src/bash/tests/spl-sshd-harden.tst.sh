#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_sshd_harden (SPL-1960, security round 1 row 2) on a sandbox
#          sshd config checked by the REAL sshd binary (sshd -t / sshd -T with
#          a throwaway host key), a fake passwd file and fake homes.
#   1. refusals: DRY_RUN=2; no non-root user with a key
#   2. DRY_RUN is the default: the effective settings now, who keeps key
#      login (keys counted, never printed), the drop-in it would write;
#      nothing written, no reload
#   3. DRY_RUN=0: the drop-in is written, sshd -t passes on the rendered
#      config, sshd -T says no passwords / no root login globally and per
#      user, the reload ran; a second run is unchanged, no reload
#   4. a Match block that turns passwords back on: the apply refuses, the
#      file is removed again, no reload
#   5. CONTROL: with the drop-in body emptied the apply fails (the sandbox
#      main file says yes), so the checks see the fix
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SSHD="$(command -v sshd || echo /usr/sbin/sshd)"
if [[ ! -x "$SSHD" ]] || ! command -v ssh-keygen >/dev/null; then
  echo "SKIP: no sshd / ssh-keygen on this box"; exit 0
fi
E="$T/etc"; mkdir -p "$E/sshd_config.d" "$T/h/alice/.ssh" "$T/h/bob" "$T/h/root/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey" -C test
MARK="PLACEHOLDER-KEY-$RANDOM$RANDOM"
printf 'ssh-ed25519 AAAA%s alice@x\n# a comment\n\nssh-ed25519 AAAB%s alice@y\n' "$MARK" "$MARK" >"$T/h/alice/.ssh/authorized_keys"
printf 'ssh-ed25519 AAAC%s root@x\n' "$MARK" >"$T/h/root/.ssh/authorized_keys"
cat >"$T/passwd" <<EOF
root:x:0:0:root:$T/h/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1000:1000::$T/h/alice:/bin/bash
bob:x:1001:1001::$T/h/bob:/bin/bash
EOF
printf 'Include %s/sshd_config.d/*.conf\nPasswordAuthentication yes\nPermitRootLogin without-password\nKbdInteractiveAuthentication no\nUsePAM yes\nAuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2\n' "$E" >"$E/sshd_config"
printf 'X11Forwarding no\n' >"$E/sshd_config.d/50-other.conf"
DROP="$E/sshd_config.d/05-spl-sshd-harden.conf"
sh_() {
  SNIPPET="$1" in_orc SSHD_SUDO="" SSHD_CONF="$E/sshd_config" SSHD_BIN="$SSHD" SSHD_ARGS="-h $T/hostkey" \
    SSHD_RELOAD_CMD="touch $T/reloaded" SSHD_PASSWD_FILE="$T/passwd" "${@:2}" >"$T/o" 2>&1
}
hd() { sh_ do_spl_sshd_harden "$@"; }
eff() { "$SSHD" -T -f "$E/sshd_config" -h "$T/hostkey" "$@" 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication) '; }

# --- 1. refusals -------------------------------------------------------------------------------
hd DRY_RUN=2 && fail "accepts DRY_RUN=2" || pass "refuses DRY_RUN=2"
grep -v '^alice' "$T/passwd" >"$T/passwd-nokey"
hd DRY_RUN=0 SSHD_PASSWD_FILE="$T/passwd-nokey" && fail "applies with no key user: $(cat "$T/o")" ||
  { grep -q "FATAL no non-root user keeps key login" "$T/o" && [[ ! -e $DROP ]] &&
    pass "refused: no non-root user would keep key login, nothing written" || fail "no-key refusal: $(cat "$T/o")"; }

# --- 2. DRY_RUN default ------------------------------------------------------------------------
hd; rc=$?
[[ $rc -eq 0 && ! -e $DROP && ! -e $T/reloaded ]] && grep -q "OK DRY_RUN nothing was changed" "$T/o" &&
  pass "dry run by default: nothing written, no reload" || fail "dry run: rc=$rc $(cat "$T/o")"
# OpenSSH 10.2 (ubuntu 26.04) prints the canonical prohibit-password for without-password.
grep -qE "sshd now: kbdinteractiveauthentication=no passwordauthentication=yes permitrootlogin=(without|prohibit)-password" "$T/o" &&
  pass "dry run: the effective settings now (from sshd -T)" || fail "dry run now-line: $(cat "$T/o")"
grep -qx "key login kept: user=alice keys=2" "$T/o" && grep -qx "no key: user=bob (no ssh after the fix)" "$T/o" &&
  grep -qx "login refused after: root (keys=1)" "$T/o" && ! grep -q daemon "$T/o" &&
  pass "dry run: who keeps key login (comments/blank lines not counted), who loses ssh; no nologin user" || fail "dry run users: $(cat "$T/o")"
grep -q "would write $DROP" "$T/o" && grep -qx "  PasswordAuthentication no" "$T/o" && grep -qx "  PermitRootLogin no" "$T/o" &&
  pass "dry run: names the drop-in and its lines" || fail "dry run body: $(cat "$T/o")"
! grep -q "$MARK" "$T/o" && pass "dry run: no key material printed" || fail "dry run leaks a key"

# --- 3. DRY_RUN=0 ------------------------------------------------------------------------------
hd DRY_RUN=0; rc=$?
[[ $rc -eq 0 && -f $DROP && -e $T/reloaded ]] && grep -q "^OK $DROP installed and sshd reloaded" "$T/o" &&
  pass "applied: drop-in written, reload ran" || fail "apply: rc=$rc $(cat "$T/o")"
"$SSHD" -t -f "$E/sshd_config" -h "$T/hostkey" && pass "sshd -t passes on the rendered config" || fail "sshd -t refuses the rendered config"
[[ "$(eff | sort | tr '\n' ' ')" == "kbdinteractiveauthentication no passwordauthentication no permitrootlogin no " ]] &&
  pass "sshd -T global: no passwords, no keyboard-interactive, no root login" || fail "sshd -T global: $(eff)"
[[ "$(eff -C user=bob,host=h,addr=192.0.2.9 | sort | tr '\n' ' ')" == "kbdinteractiveauthentication no passwordauthentication no permitrootlogin no " ]] &&
  pass "sshd -T per user: the same" || fail "sshd -T bob: $(eff -C user=bob,host=h,addr=192.0.2.9)"
rm -f "$T/reloaded"; hd DRY_RUN=0
grep -q "already in place and in force: unchanged" "$T/o" && [[ ! -e $T/reloaded ]] &&
  pass "second run: unchanged, no reload" || fail "rerun: $(cat "$T/o")"

# --- 4. a Match block turns passwords back on -------------------------------------------------
rm -f "$DROP" "$T/reloaded"
printf 'Match User bob\n  PasswordAuthentication yes\n' >"$E/sshd_config.d/60-match.conf"
hd
grep -q "^match-reenable $E/sshd_config.d/60-match.conf:2: " "$T/o" && grep -q "WARN a Match block" "$T/o" &&
  pass "dry run names the Match line that re-enables passwords" || fail "dry run match: $(cat "$T/o")"
hd DRY_RUN=0 && fail "applies over a Match re-enable: $(cat "$T/o")" ||
  { grep -q "sshd -T bob: .*passwordauthentication=yes" "$T/o" && [[ ! -e $DROP && ! -e $T/reloaded ]] &&
    pass "Match re-enable: the apply refuses, file removed again, no reload" || fail "match apply: $(cat "$T/o")"; }
rm -f "$E/sshd_config.d/60-match.conf"

# --- 5. CONTROL: the fix removed -> the apply fails --------------------------------------------
sh_ 'spl_sshd_harden_body() { echo "# empty"; }; do_spl_sshd_harden' DRY_RUN=0 &&
  fail "CONTROL: an empty drop-in passes the checks: $(cat "$T/o")" ||
  { grep -q "sshd -T (global): .*passwordauthentication=yes" "$T/o" && [[ ! -e $DROP && ! -e $T/reloaded ]] &&
    pass "CONTROL: an empty drop-in fails the checks, removed again, no reload" || fail "CONTROL: $(cat "$T/o")"; }

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
