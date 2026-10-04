#!/usr/bin/env bash
#
# directive-verify.sh — verify a signed owner directive.
#
# A directive is the owner's instruction travelling as DATA: typed on any box,
# signed there, carried here by anything (a relay agent, a paste, a USB stick),
# and still provably the owner's on arrival. The carrier cannot forge it, so a
# peer agent relaying an envelope is fine — it is carrying ciphertext it cannot
# alter.
#
# THE PASSPHRASE IS THE ENTIRE CONTROL. The agent user holds passwordless sudo
# to the box owner on these boxes, so any key a box owner can READ is a key an
# agent can read too. It cannot SIGN without the passphrase, which exists only
# in the owner's head. A key that signs unattended is worthless here and this
# script refuses to trust one — see --check-key.
#
# Usage:
#   directive-verify.sh < envelope.asc
#   directive-verify.sh --check-key            # is the pinned key sane to trust?
#   directive-verify.sh --show < envelope.asc  # verify, print the instruction only
#
# Exit: 0 verified · 78 refused (never a silent pass) · 2 usage
set -uo pipefail

# The pin and the box tag come from the spool's box config, parse-only, never
# clobbering a variable already set (lib/directive-env.inc.sh).
# shellcheck source=../lib/directive-env.inc.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)/directive-env.inc.sh" && directive_env_load
BOX_TAG_EXPECT="${DIRECTIVE_BOX:-${SPOOL_BOX_TAG:-${BOX_TAG:-}}}"
FPR="${DIRECTIVE_FPR:-}"
LEDGER="${DIRECTIVE_LEDGER:-${SPOOL_ROOT:-/var/spool-hub}/directives/used-nonces}"
GNUPGHOME_ARG=()
[ -n "${DIRECTIVE_GNUPGHOME:-}" ] && GNUPGHOME_ARG=(--homedir "$DIRECTIVE_GNUPGHOME")

say()    { printf '  %s\n' "$*"; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 78; }

[ -n "$FPR" ] || refuse "no DIRECTIVE_FPR pinned. Looked in: the environment, then this box's
         spool box config (\$SPOOL_ROOT/box.env). If the pin IS in box.env, this
         shell simply started before it existed -- open a new one rather than
         redoing setup you have already done.
         Verification without a pinned key verifies nothing: any key in the
         keyring would pass, including one an agent generated."

# DIRECTIVE_FPR is an ALLOW-LIST, not a single value. The owner sits at more
# than one box, and generating a key per box is better than copying one secret
# half around the fleet -- so "any peer to any peer" means a verifier must be
# able to pin every key the owner holds. Whitespace- or comma-separated.
#
# This does not weaken the pin. It is still an explicit list of named keys; the
# thing it refuses -- "any key present in the keyring" -- is refused exactly as
# before. Each entry must independently pass --check-key.
# NOT `set -- $FPR`: that clobbers the script's own positional parameters, and
# --check-key / --show then stop being seen. Everything failed closed, so only
# the "must refuse" assertions passed. Caught 2026-09-16 by the accept-side.
IFS=' ' read -r -a FPR_LIST <<< "$(printf '%s' "$FPR" | tr ',' ' ')"

# --check-key: the control that gives this script its meaning.
PROVE=0
if [ "${1:-}" = --check-key ] && [ "${2:-}" = --prove ]; then PROVE=1; fi
if [ "${1:-}" = --check-key ]; then
  printf '\n=== directive key check\n'
  # Every pinned key is checked. One sound key does not excuse an unsound
  # sibling: the verifier will accept a signature from ANY of them, so the
  # weakest entry sets the real security of the whole list.
  if [ "${#FPR_LIST[@]}" -gt 1 ]; then
    say "pinned          ${#FPR_LIST[@]} owner keys — each checked below"
    for _f in "${FPR_LIST[@]}"; do
      _pv=(); [ "$PROVE" -eq 1 ] && _pv=(--prove)
      DIRECTIVE_FPR="$_f" "$0" --check-key "${_pv[@]}" >/dev/null 2>&1 \
        || refuse "pinned key $_f did not pass --check-key.
         Re-run with DIRECTIVE_FPR=$_f alone to see why."
      say "  OK            $_f"
    done
    printf '\n  OK\n\n'; exit 0
  fi
  FPR="${FPR_LIST[0]}"
  gpg "${GNUPGHOME_ARG[@]}" --list-keys "$FPR" >/dev/null 2>&1 \
    || refuse "pinned key $FPR is not in the keyring"
  say "pinned key      $FPR present"
  if gpg "${GNUPGHOME_ARG[@]}" --list-secret-keys "$FPR" >/dev/null 2>&1; then
    say "secret half     present on this box"
    # Presence is NOT the danger. Directives must be signable from any box the
    # owner sits at, so the secret travels with the owner and will be on boxes
    # that also verify. The danger is a key an AGENT can use: these boxes give
    # the agent user passwordless sudo to the owner, so any key the owner can
    # read, an agent can read. What it must not be able to do is SIGN.
    #
    # So test the thing that matters rather than the thing that is easy to see:
    # attempt a signature with an EMPTY passphrase, unattended. If that works,
    # the key is worthless as an authority key and every directive it ever
    # produces is forgeable by anything on this box.
    _unattended() {
      local _o; _o="$(mktemp)"
      # NEVER -o /dev/null. gpg without --yes refuses to overwrite an existing
  # regular file, so if /dev/null is not a device the sign FAILS -- and a caller
  # reading failure as "passphrase required" gets a FALSE GREEN. That is not a
  # hypothetical: on bx2 /dev/null had become a regular 644 file, and it is the
  # measured mechanism behind a --keygen run that printed "passphrase VERIFIED"
  # for a key with no passphrase. A probe must fail for the reason it is testing
  # and for no other reason.
      printf 'probe\n' | gpg "${GNUPGHOME_ARG[@]}" --batch --yes \
        --pinentry-mode loopback --passphrase '' --local-user "$FPR" \
        --sign -o "$_o" >/dev/null 2>&1; local _rc=$?
      rm -f "$_o"; return $_rc
    }
    if _unattended; then
      # A cached passphrase can be an accident or a POLICY. directive-session.sh
      # opens a bounded window on purpose, and it could only open it by taking a
      # real passphrase on a real tty -- so inside that window "signs
      # unattended" is the feature working, and flushing would tear down what
      # the owner just paid for, silently, every time this check ran.
      #
      # This TRUSTS the window record rather than re-proving the passphrase. It
      # has to: the only way to tell "no passphrase" from "cached" is to flush,
      # and flushing is the thing we must not do here. The proof was taken when
      # the window opened. --prove forces the flush anyway, at the cost of
      # closing the window, for when the record itself is what you doubt.
      _SESS="${DIRECTIVE_SESSION_STATE:-/var/lib/spool-hub/directive-session.state}"
      # A record an agent COULD have written is a record an agent DID write.
      # Trusting any file that merely parses turned --check-key into a control
      # that reports success without testing: plant a session.state with a
      # future expiry and a passphrase-less key is certified sound. bx3 found
      # it; reproduced here by writing the forged record as the agent user into
      # the real state directory, 2026-09-16.
      #
      # Location cannot carry this alone. The obvious homes are both
      # agent-writable on this box: the ledger directory is group-writable
      # because the nonce ledger beside it MUST be (verification runs as the
      # agent and records spent nonces), and even $HOME of the box owner is
      # group-writable with the agent in that group. So check the property
      # directly instead of inferring it from a path.
      _unwritable_by_me() {  # PATH -> 0 when the CALLER could not have written it
        local q="$1" m o
        o="$(stat -c %u "$q" 2>/dev/null)" || return 1
        [ "$o" = "$(id -u)" ] && return 1          # I own it, so I could write it
        m="$(stat -c %a "$q" 2>/dev/null)" || return 1
        [ $(( 8#$m & 0022 )) -eq 0 ]               # group- or world-writable is the same hole
      }
      if [ "$PROVE" -eq 0 ] && [ -f "$_SESS" ] \
         && _unwritable_by_me "$_SESS" && _unwritable_by_me "$(dirname "$_SESS")"; then
        _exp="$(sed -n 's/^expires_epoch=//p' "$_SESS" | sed -n 1p)"
        if [ -n "$_exp" ] && [ "$(date -u +%s)" -lt "$_exp" ]; then
          say "unattended sign is EXPECTED — a directive session is open"
          say "                window closes $(sed -n 's/^expires=//p' "$_SESS" | sed -n 1p)"
          say "                Each directive is still signed over its own text; what the"
          say "                window removes is the prompt, not the signature."
          say "                Not re-proved here: telling a cached passphrase from an"
          say "                absent one requires a flush, which would close the window."
          say "                Force it with --check-key --prove (closes the window)."
          say "                Record accepted because neither it nor its directory is"
          say "                writable by this user: $_SESS"
          printf '\n  OK\n\n'; exit 0
        fi
      fi
      # Two very different problems look identical here, so separate them: flush
      # the agent cache and probe again. Still signs => the key genuinely has no
      # passphrase, which is fatal. Stops signing => it was merely CACHED, which
      # is a live exposure but a recoverable one.
      # KILL THE AGENT, do not merely clear one cache entry. bx2 measured on
      # gpg-agent 2.2.27 that a key generated moments earlier with a REAL
      # passphrase still signed with a wrong one AND with an empty one after
      # `clear_passphrase --mode=normal <keygrip>` and RELOADAGENT, with keyinfo
      # reporting it protected and uncached. Only `gpgconf --kill gpg-agent`
      # made it behave: wrong -> "Bad passphrase", empty -> "No passphrase
      # given".
      #
      # Two consequences, and the second is why this is not cosmetic:
      #   a false "NO PASSPHRASE" right after a good keygen, which sent the
      #     owner to regenerate a sound key twice today
      #   until that agent dies, anything with sudo can sign as the owner with
      #     the brand-new key
      if [ -n "${DIRECTIVE_GNUPGHOME:-}" ]; then
        GNUPGHOME="$DIRECTIVE_GNUPGHOME" gpgconf --kill gpg-agent >/dev/null 2>&1
      else
        gpgconf --kill gpg-agent >/dev/null 2>&1
      fi
      KG="$(gpg "${GNUPGHOME_ARG[@]}" --with-keygrip --list-secret-keys "$FPR" 2>/dev/null \
            | sed -n 's/.*Keygrip = //p' | sed -n 1p)"
      if [ -n "$KG" ]; then
        if [ -n "${DIRECTIVE_GNUPGHOME:-}" ]; then
          gpg-connect-agent --homedir "$DIRECTIVE_GNUPGHOME" \
            "clear_passphrase --mode=normal $KG" /bye >/dev/null 2>&1
        else
          gpg-connect-agent "clear_passphrase --mode=normal $KG" /bye >/dev/null 2>&1
        fi
      fi
      if _unattended; then
        refuse "this key has NO PASSPHRASE. It signs unattended, so any agent on
         this box can issue directives in the owner's name and a signature
         proves nothing at all. Regenerate it:
             directive-sign.sh --keygen"
      fi
      say "unattended sign was possible from a CACHED passphrase — cache flushed"
      say "WARNING         while cached, an agent here could have signed as the owner."
      say "                Shorten it: default-cache-ttl 0 in gpg-agent.conf, or"
      say "                accept the window knowingly and flush after signing:"
      say "                  echo RELOADAGENT | gpg-connect-agent /bye"
    fi
    say "unattended sign REFUSED by gpg — the passphrase is the control, and it holds"
    say "NOTE            this box can both sign and verify. That is expected for a"
    say "                box the owner types at; the passphrase is what separates"
    say "                the owner from the agents running on it."
    printf '\n  OK\n\n'; exit 0
  fi
  say "secret half     absent — this box can verify and cannot sign"
  printf '\n  OK\n\n'; exit 0
fi

SHOW=0; [ "${1:-}" = --show ] && { SHOW=1; shift; }
[ $# -eq 0 ] || { echo "usage: directive-verify.sh [--check-key [--prove]|--show] < envelope" >&2; exit 2; }
[ -n "$BOX_TAG_EXPECT" ] || refuse "cannot tell which box this is: set DIRECTIVE_BOX or SPOOL_BOX_TAG"

ENV_IN="$(cat)"
[ -n "$ENV_IN" ] || refuse "empty input"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$ENV_IN" > "$TMP/env.asc"

# 1. signature, against the PINNED key only.
if ! gpg "${GNUPGHOME_ARG[@]}" --status-fd 3 --verify "$TMP/env.asc" 3>"$TMP/status" >"$TMP/body" 2>"$TMP/err"; then
  sed 's/^/         /' "$TMP/err" >&2
  refuse "signature did not verify"
fi
SIGNER=""
for _f in "${FPR_LIST[@]}"; do
  if grep -q "^\[GNUPG:\] VALIDSIG $_f" "$TMP/status"; then SIGNER="$_f"; break; fi
done
[ -n "$SIGNER" ] \
  || refuse "signed by a key that is NOT a pinned owner key.
         Pinned:  ${FPR_LIST[*]}
         Got:     $(sed -n 's/^\[GNUPG:\] VALIDSIG \([0-9A-F]*\).*/\1/p' "$TMP/status" | sed -n 1p)"
FPR="$SIGNER"

# The body of a clearsigned message, with the gpg armour stripped by --verify.
BODY="$(gpg "${GNUPGHOME_ARG[@]}" --decrypt "$TMP/env.asc" 2>/dev/null)"

field() { printf '%s\n' "$BODY" | sed -n "s/^$1:[[:space:]]*//p" | sed -n 1p; }
TO="$(field to)"; NONCE="$(field nonce)"; EXPIRES="$(field expires)"
REPLY_TO="$(field reply-to)"

# 2. addressed to THIS box. A directive for another box is not mine to act on.
[ -n "$TO" ] || refuse "envelope has no 'to:' field"
[ "$TO" = "$BOX_TAG_EXPECT" ] \
  || refuse "addressed to '$TO', this box is '$BOX_TAG_EXPECT'"

# 3. not expired. Bounds the damage of a captured passphrase.
[ -n "$EXPIRES" ] || refuse "envelope has no 'expires:' field"
NOW_S=$(date -u +%s); EXP_S=$(date -u -d "$EXPIRES" +%s 2>/dev/null) \
  || refuse "unparseable expires: '$EXPIRES'"
[ "$NOW_S" -lt "$EXP_S" ] \
  || refuse "expired at $EXPIRES (now $(date -u +%Y-%m-%dT%H:%M:%SZ))"

# 4. nonce unused. Stops a valid envelope being replayed by anyone who saw it.
[ -n "$NONCE" ] || refuse "envelope has no 'nonce:' field"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
if [ -f "$LEDGER" ] && grep -qxF "$NONCE" "$LEDGER"; then
  refuse "nonce already used: $NONCE
         This envelope has been acted on before. Replay refused."
fi
printf '%s\n' "$NONCE" >> "$LEDGER"

if [ "$SHOW" -eq 1 ]; then
  printf '%s\n' "$BODY" | sed -n '/^---$/,$p' | tail -n +2
  exit 0
fi

printf '\n=== directive VERIFIED\n'
say "signer     $FPR (pinned)"
say "to         $TO"
[ -n "$REPLY_TO" ] && say "reply-to   $REPLY_TO  <- send the result HERE, not to whoever relayed it"
say "nonce      $NONCE  (recorded, cannot be replayed)"
say "expires    $EXPIRES"
printf '\n--- instruction ---\n'
printf '%s\n' "$BODY" | sed -n '/^---$/,$p' | tail -n +2
printf -- '--- end ---\n\n'
