#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_mail_verify_token + mail-verify-token.py, offline (SPL-2411).
#   1. refused before any secret read: another env, a relative token file, an
#      address outside the relay mailbox (or the bare mailbox)
#   2. the action: the IMAP env reaches the script, the relay password file is
#      gone after the run, a failed read is FAIL
#   3. the script (m3's IMAP reader faked in-process): the token lands in the
#      file 0600 and on no stdout line; CONTROL: no mail -> exit 1, no file,
#      a reason that names no address
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FN="$PROJ_ROOT/src/bash/run/spl-mail-verify-token.func.sh"
PY="$PROJ_ROOT/src/bash/scripts/mail-verify-token.py"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf 'env:\n  mail:\n    env:\n      SPOOL_HUB_MAIL_SMTP_USER: Relay@example.net\n      SPOOL_HUB_MAIL_SMTP_HOST: smtp.example.net\n' >"$T/cnf.yaml"
cat >"$T/fake.sh" <<'EOF'
#!/usr/bin/env bash
echo "$M3_IMAP_USER $M3_IMAP_HOST $(cat "$M3_IMAP_PASS_FILE") $MAIL_TOKEN_EMAIL" >"$FAKE_LOG"
echo "$M3_IMAP_PASS_FILE" >"$FAKE_LOG.pass"
[[ -e "$FAKE_FAIL" ]] && { echo '{"ok": false, "error": "no verify mail within 1s"}'; exit 1; }
echo '{"ok": true}'
EOF
chmod +x "$T/fake.sh"

act() {
  env ENV=dev MAIL_TOKEN_EMAIL=relay+wui-1@example.net MAIL_TOKEN_FILE="$T/token" MAIL_TOKEN_CMD_PY="$T/fake.sh" \
    FAKE_LOG="$T/log" FAKE_FAIL="$T/fail" "$@" bash -c "
    do_log() { echo \"\$*\"; }; do_require_bin() { :; }
    source '$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh'
    do_spl_cloud_cnf() { SPL_CNF='$T/cnf.yaml'; }
    spl_m3_imap_pass() { echo SECRET-READ; ( umask 077; echo app-pw >\"\$1\" ); }
    source '$FN'; do_spl_mail_verify_token" 2>&1
}

out="$(act ENV=lde)"; [[ $? -ne 0 ]] && grep -q 'ENV must be dev or prd' <<<"$out" && pass "1. another env is refused" || fail "1. env: $out"
out="$(act MAIL_TOKEN_FILE=token)"; [[ $? -ne 0 ]] && grep -q 'MAIL_TOKEN_FILE must be an absolute path' <<<"$out" && pass "1. a relative token file is refused" || fail "1. file: $out"
for a in someone+x@example.com relay@example.net relay+@example.net; do
  out="$(act MAIL_TOKEN_EMAIL="$a")"
  [[ $? -ne 0 ]] && grep -q 'is no plus-address of the relay mailbox' <<<"$out" && ! grep -q SECRET-READ <<<"$out" &&
    pass "1. $a refused before any secret read" || fail "1. $a: $out"
done

out="$(act)"; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'relay@example.net imap.example.net app-pw relay+wui-1@example.net' "$T/log" && grep -q '^OK the verify token' <<<"$out" &&
  pass "2. the IMAP env reaches the script (mailbox, host from SMTP, password file)" || fail "2. env: rc=$rc $out $(cat "$T/log" 2>&1)"
[[ ! -e "$(cat "$T/log.pass")" ]] && pass "2. the relay password file is removed after the run" || fail "2. password file left: $(cat "$T/log.pass")"
grep -q app-pw <<<"$out" && fail "2. the relay password printed" || pass "2. the relay password is in no output"
touch "$T/fail"; out="$(act)"; rc=$?
[[ $rc -ne 0 ]] && grep -q '^FAIL no verify token for relay+wui-1@example.net' <<<"$out" && [[ ! -e "$(cat "$T/log.pass")" ]] &&
  pass "2. a failed read is FAIL, the password file still removed" || fail "2. fail: rc=$rc $out"

run_py() {
  MAIL_TOKEN_EMAIL=relay+wui-1@example.net MAIL_TOKEN_FILE="$T/tok" M3_IMAP_USER=relay@example.net M3_IMAP_TIMEOUT=1 FAKE_TOK="$1" \
    python3 -B - "$PY" <<'PYI' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mvt", sys.argv[1]); mvt = importlib.util.module_from_spec(spec); spec.loader.exec_module(mvt)
def fake(rcpt, seen):
    assert seen == set() and rcpt == "relay+wui-1@example.net"
    t = os.environ["FAKE_TOK"]
    return (t, {"mail_from": "noreply@example.net", "mail_subject": "Confirm", "mail_after_s": 1.0, "link_page": "https://x/verify-email"}) if t else ("", {"mail": "no verify mail to %s within 1s" % rcpt})
mvt.m3.imap_verify_token = fake
sys.exit(mvt.main())
PYI
}
TOK=$(printf 'c%.0s' $(seq 64))
out="$(run_py "$TOK")"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/tok")" == "$TOK" && "$(stat -c %a "$T/tok")" == 600 ]] && pass "3. the token lands in the file, 0600" || fail "3. token file: rc=$rc $out"
grep -q "$TOK" <<<"$out" && fail "3. the token printed" || pass "3. the token is on no stdout line"
grep -q 'relay+wui' <<<"$out" && fail "3. the address printed" || pass "3. the evidence names no address"
rm -f "$T/tok"; out="$(run_py "")"; rc=$?
[[ $rc -eq 1 && ! -e "$T/tok" ]] && grep -q '"error": "no verify mail within 1s"' <<<"$out" && ! grep -q 'relay+wui' <<<"$out" &&
  pass "3. CONTROL: no mail -> exit 1, no file, no address" || fail "3. control: rc=$rc $out"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
