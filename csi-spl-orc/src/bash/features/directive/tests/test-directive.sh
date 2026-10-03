#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the directive feature (specs/069 Y5, moved out of the frozen box
#          engine), hermetic: a throwaway keyring, ledger and box config.
#   1. the four selftests (core, any-to-any, list, session) pass, isolated
#      from this box's config and window record
#   2. lib/directive-env.inc.sh reads DIRECTIVE_* and SPOOL_BOX_TAG from
#      $SPOOL_BOX_ENV, parse-only: a $(...) value is never run, other keys
#      are ignored, an already-set variable wins
#   3. the verifier takes the box tag from that config: an envelope for
#      another box is refused (78) naming both tags. CONTROL: with no tag
#      configured it refuses "cannot tell which box this is"
#------------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SPOOL_BOX_ENV="$T/no-box.env" TMPDIR="$T"
unset DIRECTIVE_FPR DIRECTIVE_BOX DIRECTIVE_LEDGER DIRECTIVE_GNUPGHOME SPOOL_BOX_TAG BOX_TAG

# --- 1. the selftests -------------------------------------------------------------------
for s in core anyany list session; do
  out="$(bash "$HERE/scripts/selftest-$s.sh" 2>&1)"; rc=$?
  sum="$(printf '%s\n' "$out" | grep -E '== [0-9]+ passed, [0-9]+ failed ==' | tail -1)"
  [ "$rc" = 0 ] && printf '%s' "$sum" | grep -q ', 0 failed' &&
    pass "1. selftest-$s:${sum//=/}" || fail "1. selftest-$s: rc $rc $(printf '%s\n' "$out" | grep -E 'FAIL|ABORT' | head -5)"
done

# --- 2. the loader --------------------------------------------------------------------
cat >"$T/box.env" <<EOF
SPOOL_AGENT_USER=someone
export DIRECTIVE_FPR="AAAA BBBB"
DIRECTIVE_LEDGER=\$(touch $T/ran)
SPOOL_BOX_TAG=bx1
OTHER=x
EOF
got="$(SPOOL_BOX_ENV="$T/box.env" bash -c '. "$1/lib/directive-env.inc.sh"; directive_env_load; printf "%s|%s|%s|%s|%s" "$DIRECTIVE_FPR" "$SPOOL_BOX_TAG" "${OTHER:-}" "${SPOOL_AGENT_USER:-}" "$DIRECTIVE_LEDGER"' _ "$HERE")"
[ "$got" = "AAAA BBBB|bx1|||\$(touch $T/ran)" ] && [ ! -e "$T/ran" ] &&
  pass "2. DIRECTIVE_* + SPOOL_BOX_TAG read, parse-only, other keys ignored" || fail "2. loader: '$got' ran=$([ -e "$T/ran" ] && echo yes)"
got="$(SPOOL_BOX_ENV="$T/box.env" DIRECTIVE_FPR=CLI bash -c '. "$1/lib/directive-env.inc.sh"; directive_env_load; printf %s "$DIRECTIVE_FPR"' _ "$HERE")"
[ "$got" = CLI ] && pass "2. an already-set DIRECTIVE_FPR wins" || fail "2. override: '$got'"

# --- 3. the verifier reads the box tag from the config --------------------------------------
G="$T/gpg"; mkdir -p "$G"; chmod 700 "$G"
gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase p --quick-gen-key 'directive test' ed25519 sign never >/dev/null 2>&1
FPR="$(gpg --homedir "$G" --batch --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
env_for() { printf 'DIRECTIVE_FPR=%s\nDIRECTIVE_GNUPGHOME=%s\nDIRECTIVE_LEDGER=%s\nDIRECTIVE_SESSION_STATE=%s\n%s\n' "$FPR" "$G" "$T/nonces" "$T/no-state" "$1" >"$T/box.env"; }
E="$(printf 'to: bx2\nnonce: %s\nissued: %s\nexpires: %s\n---\nhello\n' "$RANDOM$RANDOM" "$(date -u +%FT%TZ)" "$(date -u -d '+10 min' +%FT%TZ)" |
     gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase p --local-user "$FPR" --clearsign 2>/dev/null)"
[ -n "$FPR" ] && [ -n "$E" ] || fail "3. cannot make a test key/envelope (gpg)"
env_for "SPOOL_BOX_TAG=bx1"
out="$(printf '%s\n' "$E" | SPOOL_BOX_ENV="$T/box.env" bash "$HERE/scripts/directive-verify.sh" 2>&1)"; rc=$?
[ "$rc" = 78 ] && printf '%s' "$out" | grep -q "addressed to 'bx2', this box is 'bx1'" &&
  pass "3. an envelope for bx2 is refused on bx1 (tag from the box config)" || fail "3. routing: rc $rc $out"
env_for ""
out="$(printf '%s\n' "$E" | SPOOL_BOX_ENV="$T/box.env" bash "$HERE/scripts/directive-verify.sh" 2>&1)"; rc=$?
[ "$rc" = 78 ] && printf '%s' "$out" | grep -q 'cannot tell which box this is' &&
  pass "3. control: no tag configured -> refused, cannot tell which box" || fail "3. control: rc $rc $out"
env_for "SPOOL_BOX_TAG=bx2"
out="$(printf '%s\n' "$E" | SPOOL_BOX_ENV="$T/box.env" bash "$HERE/scripts/directive-verify.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "3. the same envelope is accepted on bx2" || fail "3. accept: rc $rc $out"
gpgconf --homedir "$G" --kill gpg-agent >/dev/null 2>&1

echo "-- directive: $((n - fails))/$n passed"
[ "$fails" -eq 0 ]
