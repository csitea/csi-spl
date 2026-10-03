#!/usr/bin/env bash
# directive-session.sh: the bounded signing window, and what --check-key does
# about it. The interesting assertions are the ones about a window that is open
# but should NOT excuse an unsound key.
set -u
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$D/directive-verify.sh"; S="$D/directive-session.sh"
for f in "$V" "$S"; do
  [ -r "$f" ] || { echo "ABORT: $f not readable — suite would pass vacuously"; exit 3; }
  bash "$f" --nonsense >/dev/null 2>&1; [ $? -ne 127 ] || { echo "ABORT: $f exits 127"; exit 3; }
done

G=$(mktemp -d "${TMPDIR:-/tmp}/dtS-XXXXXX"); chmod 700 "$G"; trap 'rm -rf "$G"' EXIT
export GNUPGHOME="$G"
mk(){ gpg --batch --pinentry-mode loopback --passphrase "$2" \
        --quick-generate-key "$1" ed25519 sign never >/dev/null 2>&1
      gpg --list-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}'; }
NOPASS=$(mk "no passphrase" ''); WITHPASS=$(mk "with passphrase" pw)
[ -n "$NOPASS" ] && [ -n "$WITHPASS" ] || { echo "ABORT: key generation failed"; exit 3; }

p=0; f=0; ok(){ printf '  PASS  %s\n' "$1"; p=$((p+1)); }; no(){ printf '  FAIL  %s\n' "$1"; f=$((f+1)); }
ST="$G/sess"
plant(){ printf 'fpr=%s\nopened=x\nexpires_epoch=%s\nexpires=%s\nagent_conf_backup=none\n' \
           "$1" "$2" "$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)" > "$ST"; }
CK(){ DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_SESSION_STATE="$ST" DIRECTIVE_FPR="$1" \
      bash "$V" --check-key "${@:2}" >/dev/null 2>&1; }

# 1. A key with no passphrase must never be granted a window. This is the only
#    place it CAN be caught: once a window is open --check-key stops re-proving.
script -qec "GNUPGHOME=$G DIRECTIVE_FPR=$NOPASS DIRECTIVE_SESSION_STATE=$ST bash $S --minutes 5" /dev/null 2>&1 \
  | grep -q 'signs UNATTENDED' && ok "passphrase-less key is REFUSED a window" \
                               || no "passphrase-less key is REFUSED a window"
[ -f "$ST" ] && no "refused open left no state behind" || ok "refused open left no state behind"

# 2. A record THIS USER could have written must never be trusted, however well
#    formed. Before the trust check, planting one in the group-writable ledger
#    directory certified a passphrase-less key as sound -- a control reporting
#    success without testing anything. bx3 found it; reproduced by writing the
#    forged record as the agent user into the real state directory.
plant "$NOPASS" "$(( $(date -u +%s) + 600 ))"
CK "$NOPASS" && no "a record the caller OWNS is refused (forgery)" \
             || ok "a record the caller OWNS is refused — an agent could have written it"

# 3. Group-writable is the same hole with more steps: the agent user is in the
#    box owner's group on these boxes, so 0664 is as forgeable as owning it.
#    This is not hypothetical -- the first version of the writer produced 0664
#    from the default umask, and this assertion is what caught it.
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  # NOT inside $G: that is GNUPGHOME, and chowning it away from this user makes
  # gpg refuse its own keyring -- which fails the assertion for a reason that
  # has nothing to do with the property under test. Cost one red run to learn.
  FD="$(mktemp -d "${TMPDIR:-/tmp}/dtF-XXXXXX")"; FOREIGN="$FD/foreign.state"
  plant "$NOPASS" "$(( $(date -u +%s) + 600 ))"; cp "$ST" "$FOREIGN"
  sudo chown root:root "$FOREIGN" 2>/dev/null && sudo chmod 0644 "$FOREIGN" 2>/dev/null
  sudo chown root:root "$FD" 2>/dev/null; sudo chmod 0755 "$FD" 2>/dev/null
  if [ "$(stat -c %u "$FOREIGN")" = 0 ]; then
    DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_SESSION_STATE="$FOREIGN" DIRECTIVE_FPR="$NOPASS" \
      bash "$V" --check-key >/dev/null 2>&1 \
      && ok "a FOREIGN 0644 record IS trusted (the feature still works)" \
      || no "a foreign 0644 record is trusted"
    sudo chmod 0664 "$FOREIGN"
    DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_SESSION_STATE="$FOREIGN" DIRECTIVE_FPR="$NOPASS" \
      bash "$V" --check-key >/dev/null 2>&1 \
      && no "the same record made GROUP-WRITABLE is refused" \
      || ok "the same record made GROUP-WRITABLE is refused"
    sudo rm -rf "$FD"
  else
    echo "  SKIP  foreign-owned record (chown failed) — POSITIVE SIDE UNTESTED"
    sudo rm -rf "$FD" 2>/dev/null
  fi
else
  echo "  SKIP  foreign-owned record (no passwordless sudo) — POSITIVE SIDE UNTESTED"
  echo "        Both remaining session assertions are negative. A suite whose"
  echo "        positive case is skipped can pass while the feature is dead."
fi

# 4. --prove ignores the record entirely, trusted or not.
plant "$NOPASS" "$(( $(date -u +%s) + 600 ))"
CK "$NOPASS" --prove && no "--prove REFUSES a passphrase-less key despite an open window" \
                     || ok "--prove REFUSES a passphrase-less key despite an open window"

# 4. An EXPIRED window must not excuse anything.
plant "$NOPASS" "$(( $(date -u +%s) - 60 ))"
CK "$NOPASS" && no "expired window REFUSES a passphrase-less key" \
             || ok "expired window REFUSES a passphrase-less key (no grace)"

# 5. No window at all: unchanged behaviour.
rm -f "$ST"
CK "$NOPASS" && no "no window: passphrase-less key REFUSED" \
             || ok "no window: passphrase-less key REFUSED (unchanged)"
CK "$WITHPASS" && ok "no window: key WITH a passphrase accepted (unchanged)" \
               || no "no window: key with a passphrase accepted"

# 6. --status reads the record rather than guessing.
DIRECTIVE_SESSION_STATE="$ST" DIRECTIVE_FPR="$WITHPASS" bash "$S" --status 2>&1 \
  | grep -q 'CLOSED' && ok "--status reports CLOSED with no record" || no "--status reports CLOSED"
plant "$WITHPASS" "$(( $(date -u +%s) + 600 ))"
DIRECTIVE_SESSION_STATE="$ST" DIRECTIVE_FPR="$WITHPASS" bash "$S" --status 2>&1 \
  | grep -q 'OPEN' && ok "--status reports OPEN from the record" || no "--status reports OPEN"

# 7. --close removes the record.
DIRECTIVE_GNUPGHOME="$G" DIRECTIVE_SESSION_STATE="$ST" DIRECTIVE_FPR="$WITHPASS" \
  bash "$S" --close >/dev/null 2>&1
[ -f "$ST" ] && no "--close removes the session record" || ok "--close removes the session record"

printf '\n  == %d passed, %d failed ==\n' "$p" "$f"
[ "$f" -eq 0 ]
