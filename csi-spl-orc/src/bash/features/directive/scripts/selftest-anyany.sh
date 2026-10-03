#!/usr/bin/env bash
# any-to-any additions: the unattended-signing gate, both directions.
set -u
# Resolve the scripts under test RELATIVE TO THIS FILE. A hardcoded install
# path makes this suite report green on any box that does not have it, because
# a missing interpreter target exits non-zero and EVERY "should refuse"
# assertion reads a non-zero exit as success. Found by the bx3 box running it
# from an unpacked tarball: 5 passed, 3 failed, with nothing executed at all.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PRECONDITION, and it is the real fix. Relative resolution corrects the symptom;
# this makes the whole class impossible. A suite that cannot run what it tests
# must ABORT LOUDLY, never grade.
for _req in directive-verify.sh directive-sign.sh; do
  [ -r "$D/$_req" ] || { printf 'ABORT: %s not found under %s — refusing to grade a suite that cannot run\n' "$_req" "$D" >&2; exit 3; }
done
printf 'probe\n' | bash "$D/directive-verify.sh" >/dev/null 2>&1
case $? in
  78|2) : ;;  # refused or usage: it ran
  127)  printf 'ABORT: %s/directive-verify.sh is not runnable (127)\n' "$D" >&2; exit 3 ;;
esac
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# A: key WITH a passphrase, secret present -> must be ACCEPTED (any-to-any needs this)
# ISOLATE THE WINDOW RECORD. Without this the suite reads the BOX'S LIVE
# session.state, and with a window open --check-key reports a cached passphrase
# as expected and stops re-proving -- so the security-critical negatives flip.
# Measured: as a user foreign to the record, any-to-any went 5/0 -> 4/1 and list
# 7/0 -> 6/1, and the two that flipped were "passphrase-less key REFUSED" and
# "check-key refuses a list containing a passphrase-less key".
#
# The trap this closes is in how a GREEN run reads: 8/0 5/0 7/0 is not evidence
# the isolation works, it is evidence no window happened to be open. bx3 found
# it, and only because it ran the suites while the owner had one open.
export DIRECTIVE_SESSION_STATE="${DIRECTIVE_SESSION_STATE:-/nonexistent/no-session-during-tests}"

GA=$(mktemp -d "${TMPDIR:-/tmp}/dtA-XXXXXX"); chmod 700 "$GA"
gpg --homedir "$GA" --batch --pinentry-mode loopback --passphrase 'realpass' \
    --quick-generate-key "owner with passphrase" ed25519 sign never >/dev/null 2>&1
FA=$(gpg --homedir "$GA" --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
if DIRECTIVE_GNUPGHOME="$GA" DIRECTIVE_FPR="$FA" bash "$D/directive-verify.sh" --check-key >/dev/null 2>&1; then
  ok "signing box WITH passphrase is accepted (any-to-any works)"
else
  no "signing box WITH passphrase is accepted"
fi

# B: key with NO passphrase -> must be REFUSED, this is the whole point
GB=$(mktemp -d "${TMPDIR:-/tmp}/dtB-XXXXXX"); chmod 700 "$GB"
gpg --homedir "$GB" --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "owner no passphrase" ed25519 sign never >/dev/null 2>&1
FB=$(gpg --homedir "$GB" --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
if DIRECTIVE_GNUPGHOME="$GB" DIRECTIVE_FPR="$FB" bash "$D/directive-verify.sh" --check-key >/dev/null 2>&1; then
  no "passphrase-less key REFUSED"
else
  ok "passphrase-less key REFUSED (signs unattended)"
fi

# C: verify-only box, public half only -> accepted
GC=$(mktemp -d "${TMPDIR:-/tmp}/dtC-XXXXXX"); chmod 700 "$GC"
gpg --homedir "$GA" --export --armor "$FA" 2>/dev/null | gpg --homedir "$GC" --import >/dev/null 2>&1
if DIRECTIVE_GNUPGHOME="$GC" DIRECTIVE_FPR="$FA" bash "$D/directive-verify.sh" --check-key >/dev/null 2>&1; then
  ok "verify-only box (public half) accepted"
else
  no "verify-only box (public half) accepted"
fi

# D: any-to-any routing — an envelope for bx2 must be refused on bx1 and accepted on bx2
sign_for() {
  printf 'to: %s\nnonce: %s\nissued: %s\nexpires: %s\n---\n%s\n' \
    "$1" "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%SZ)" "$2" \
  | gpg --homedir "$GA" --batch --pinentry-mode loopback --passphrase 'realpass' \
        --local-user "$FA" --clearsign --armor 2>/dev/null
}
E="$(sign_for bx2 'install the pack')"
if printf '%s\n' "$E" | DIRECTIVE_GNUPGHOME="$GC" DIRECTIVE_FPR="$FA" DIRECTIVE_BOX=bx1 \
     DIRECTIVE_LEDGER="$GC/n1" bash "$D/directive-verify.sh" >/dev/null 2>&1; then
  no "envelope for bx2 refused on bx1"
else
  ok "envelope for bx2 refused on bx1 (routing holds)"
fi
if printf '%s\n' "$E" | DIRECTIVE_GNUPGHOME="$GC" DIRECTIVE_FPR="$FA" DIRECTIVE_BOX=bx2 \
     DIRECTIVE_LEDGER="$GC/n2" bash "$D/directive-verify.sh" >/dev/null 2>&1; then
  ok "same envelope ACCEPTED on bx2 (any-to-any routing)"
else
  no "same envelope ACCEPTED on bx2"
fi

echo; echo "  == $pass passed, $fail failed =="
rm -rf "$GA" "$GB" "$GC"
[ "$fail" -eq 0 ]
