#!/usr/bin/env bash
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

G=$(mktemp -d "${TMPDIR:-/tmp}/dtest-XXXXXX"); chmod 700 "$G"
export DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_LEDGER="$G/nonces" DIRECTIVE_BOX=bx1
PASS=testpass
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase "$PASS" \
    --quick-generate-key "test directive owner" ed25519 sign never >/dev/null 2>&1
FPR=$(gpg --homedir "$G" --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
export DIRECTIVE_FPR="$FPR"
echo "key: $FPR"; echo

# real signer, passphrase via loopback so the test is non-interactive
sign() { # target minutes text
  printf 'to: %s\nnonce: %s\nissued: %s\nexpires: %s\n---\n%s\n' \
    "$1" "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d "+$2 minutes" +%Y-%m-%dT%H:%M:%SZ)" "$3" \
  | gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase "$PASS" \
        --local-user "$FPR" --clearsign --armor 2>/dev/null
}

E="$(sign bx1 60 'rebuild the bx2 pack and report the sha256')"
printf '%s\n' "$E" | bash "$D/directive-verify.sh" >/dev/null 2>&1 && ok "valid directive verifies" || no "valid directive verifies"
printf '%s\n' "$E" | bash "$D/directive-verify.sh" >/dev/null 2>&1 && no "replay refused" || ok "replay refused (nonce ledger)"

E2="$(sign bx2 60 'something for another box')"
printf '%s\n' "$E2" | bash "$D/directive-verify.sh" >/dev/null 2>&1 && no "wrong box refused" || ok "wrong box refused"

E3="$(sign bx1 -5 'this one is stale')"
printf '%s\n' "$E3" | bash "$D/directive-verify.sh" >/dev/null 2>&1 && no "expired refused" || ok "expired refused"

E4="$(sign bx1 60 'tamper me')"
printf '%s\n' "$E4" | sed 's/tamper me/do something else entirely/' \
  | bash "$D/directive-verify.sh" >/dev/null 2>&1 && no "tampered body refused" || ok "tampered body refused"

# a DIFFERENT key signing the same shape must not pass the pin
gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase "$PASS" \
    --quick-generate-key "impostor" ed25519 sign never >/dev/null 2>&1
IMP=$(gpg --homedir "$G" --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/{print $10}' | sed -n 2p)
E5="$(printf 'to: bx1\nnonce: %s\nissued: %s\nexpires: %s\n---\nforged\n' \
      "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u -d '+60 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
    | gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase "$PASS" \
          --local-user "$IMP" --clearsign --armor 2>/dev/null)"
printf '%s\n' "$E5" | bash "$D/directive-verify.sh" >/dev/null 2>&1 && no "impostor key refused" || ok "impostor key refused (not the pinned fpr)"

# --check-key must ACCEPT a box holding a PASSPHRASE-PROTECTED secret half.
# Superseded requirement: it used to refuse any box holding the secret. That
# blocked signing from more than one box, which the owner needs. The control is
# not WHERE the key is, it is whether an agent can use it unattended — covered
# by the dedicated suite. Flush any cached passphrase first so this tests the
# key rather than the agent's recent memory.
# Kill the agent rather than clear one cache entry: on gpg-agent 2.2.27
# clear_passphrase leaves an unlocked key usable, so the flush this test relies on
# would silently not happen on exactly the box where it matters. Unguarded on
# purpose: a `[ -n "$KG" ] &&` guard here once swallowed the fix while bash -n passed.
gpgconf --homedir "$G" --kill gpg-agent >/dev/null 2>&1
bash "$D/directive-verify.sh" --check-key >/dev/null 2>&1 && ok "check-key accepts a signing box whose key has a passphrase" || no "check-key accepts a signing box whose key has a passphrase"

# and pass when only the public half is present
G2=$(mktemp -d "${TMPDIR:-/tmp}/dtest-pub-XXXXXX"); chmod 700 "$G2"
gpg --homedir "$G" --export --armor "$FPR" 2>/dev/null | gpg --homedir "$G2" --import >/dev/null 2>&1
DIRECTIVE_GNUPGHOME="$G2" bash "$D/directive-verify.sh" --check-key >/dev/null 2>&1 && ok "check-key passes with public half only" || no "check-key passes with public half only"

echo; echo "  == $pass passed, $fail failed =="
rm -rf "$G" "$G2"
[ "$fail" -eq 0 ]
