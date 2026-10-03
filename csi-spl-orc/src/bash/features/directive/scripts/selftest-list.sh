#!/usr/bin/env bash
# DIRECTIVE_FPR as an allow-list: the owner holds one key per box they sit at,
# so every verifier must pin more than one. These assert that widening the pin
# did not dissolve it.
#
# The accept-side assertions are the point. A first cut of the list support used
# `set -- $FPR`, which clobbered the script's own positional parameters so that
# --check-key and --show were never seen and EVERY path failed closed. All the
# "must refuse" assertions passed. Only the accept side caught it.
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$D/directive-verify.sh"
[ -r "$V" ] || { echo "ABORT: $V not readable — suite would pass vacuously"; exit 3; }
bash "$V" --help >/dev/null 2>&1; [ $? -ne 127 ] || { echo "ABORT: verifier exits 127"; exit 3; }

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

G=$(mktemp -d "${TMPDIR:-/tmp}/dtL-XXXXXX"); chmod 700 "$G"; trap 'rm -rf "$G"' EXIT
mk(){ gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase "$2" \
        --quick-generate-key "$1" ed25519 sign never >/dev/null 2>&1
      gpg --homedir "$G" --list-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}'; }
A=$(mk "owner A" pA); B=$(mk "owner B" pB); X=$(mk "impostor X" pX)
[ -n "$A" ] && [ -n "$B" ] && [ -n "$X" ] || { echo "ABORT: key generation failed"; exit 3; }

sign(){ printf 'to: bx3\nnonce: %s\nissued: %s\nexpires: %s\n---\n%s\n' \
    "$(head -c 16 /dev/urandom|od -An -tx1|tr -d ' \n')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(date -u -d '+30 min' +%Y-%m-%dT%H:%M:%SZ)" "$2" \
  | gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase "$3" \
        --local-user "$1" --clearsign --armor 2>/dev/null; }
p=0; f=0; ok(){ printf '  PASS  %s\n' "$1"; p=$((p+1)); }; no(){ printf '  FAIL  %s\n' "$1"; f=$((f+1)); }
V2(){ DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_FPR="$1" DIRECTIVE_BOX=bx3 \
      DIRECTIVE_LEDGER="$G/l$RANDOM$RANDOM" bash "$V" >/dev/null 2>&1; }

sign "$A" "from A" pA | V2 "$A $B" && ok "key A accepted when the list is 'A B'"  || no "key A accepted"
sign "$B" "from B" pB | V2 "$A $B" && ok "key B accepted when the list is 'A B'"  || no "key B accepted"
sign "$X" "from X" pX | V2 "$A $B" && no "impostor REFUSED against list 'A B'" \
                                   || ok "impostor REFUSED against list 'A B' (the pin still holds)"
sign "$B" "comma"  pB | V2 "$A,$B" && ok "comma-separated list is accepted"       || no "comma-separated list"

OUT="$(sign "$B" "hello there" pB | DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_FPR="$A $B" \
        DIRECTIVE_BOX=bx3 DIRECTIVE_LEDGER="$G/s$RANDOM" bash "$V" --show 2>/dev/null)"
[ "$OUT" = "hello there" ] && ok "--show still returns the instruction (positionals intact)" \
                           || no "--show still returns the instruction"

N=$(gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase '' \
      --quick-generate-key "no passphrase" ed25519 sign never >/dev/null 2>&1
    gpg --homedir "$G" --list-keys --with-colons "no passphrase" 2>/dev/null|awk -F: '/^fpr/{print $10;exit}')
DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_FPR="$A $N" bash "$V" --check-key >/dev/null 2>&1 \
  && no "check-key refuses a list containing a passphrase-less key" \
  || ok "check-key REFUSES the whole list when one sibling signs unattended"
DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_FPR="$A $B" bash "$V" --check-key >/dev/null 2>&1 \
  && ok "check-key ACCEPTS a list where every key is sound" || no "check-key accepts a sound list"

printf '\n  == %d passed, %d failed ==\n' "$p" "$f"
[ "$f" -eq 0 ]
