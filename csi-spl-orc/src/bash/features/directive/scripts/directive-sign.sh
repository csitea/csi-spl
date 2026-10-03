#!/usr/bin/env bash
#
# directive-sign.sh — sign one owner directive, on whatever box the owner is at.
#
# Prints a clearsigned envelope on stdout. Hand it to anything: paste it into a
# relay message, drop it on a USB stick, email it. The carrier cannot forge or
# alter it, which is the whole point — a relay agent becomes a courier rather
# than an authority.
#
#   directive-sign.sh <target-box> "<the instruction>"
#   directive-sign.sh --keygen                 # make the owner key, once
#   directive-sign.sh --minutes 30 bx1 "..."   # default 60
#
# gpg will PROMPT FOR THE PASSPHRASE. That prompt is the security boundary and
# the reason this is worth anything: the key file can be read by anything with
# sudo on this box, but it cannot sign without what is in your head.
set -uo pipefail

# The pin and the box tag come from the spool's box config, parse-only, never
# clobbering a variable already set (lib/directive-env.inc.sh).
# shellcheck source=../lib/directive-env.inc.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)/directive-env.inc.sh" && directive_env_load
FPR="${DIRECTIVE_FPR:-}"
MINUTES=60
# Where the ANSWER goes. "to:" fixes who must act; it says nothing about who
# should see the result, and an instruction like "report the output verbatim"
# fixes completeness and is silent on audience. On 2026-09-16 that gap sent a
# directive's output to a session the owner was not reading, while they waited in
# another -- with both the executing box and the relay behaving correctly.
# Optional: an envelope without it verifies exactly as before.
REPLY_TO="${DIRECTIVE_REPLY_TO:-}"
GNUPGHOME_ARG=()
[ -n "${DIRECTIVE_GNUPGHOME:-}" ] && GNUPGHOME_ARG=(--homedir "$DIRECTIVE_GNUPGHOME")

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

if [ "${1:-}" = --keygen ]; then
  cat <<'EOT'

=== generating the owner directive key

  You will be asked for a PASSPHRASE. Choose one you will actually type, and do
  NOT store it on any box. It is the only thing standing between an agent with
  sudo and the ability to issue directives in your name.

  An empty passphrase makes this whole mechanism worthless and the key will be
  refused by directive-verify.sh --check-key.

EOT
  # The UID must not name a box or a person: the generic engine carries no
  # estate identity, and a key UID travels into every keyring that imports it.
  # DIRECTIVE_UID overrides for anyone who wants a recognisable label locally.
  # loopback keeps the passphrase prompt on THIS TERMINAL. Without it gpg hands
  # the prompt to a pinentry program: a GUI one on a box that has a desktop, and
  # nothing at all on a box that does not -- where keygen then dies with
  # "No pinentry" having asked for nothing. Found on bx3, 2026-09-16.
  #
  # Take the new fingerprint from gpg's OWN status output, never by looking the
  # UID up afterwards: --list-keys matches on SUBSTRING, so "directive owner"
  # also matches an older "<user> directive owner" key and `exit` takes the first
  # hit -- the OLD one. The passphrase probe below would then test the wrong key
  # and print a confident green. The UID change in d5fa3f9 is what creates that
  # collision, so this has to travel with it. bx3 reproduced it with a planted
  # decoy: KEY_CREATED gave 556865C0..., the lookup gave the decoy 290B873C...
  # ASK FOR THE PASSPHRASE OURSELVES rather than trusting gpg to prompt.
  # --pinentry-mode loopback is documented to prompt on the terminal, and on at
  # least one box it DOES NOT: measured on bx2, two --keygen runs produced no
  # "Enter passphrase" line at all and silently created keys with an EMPTY
  # passphrase. The operator sees a key appear, is told nothing was asked, and
  # has no way to know the result is worthless.
  #
  # read -rs needs a tty, so an agent still cannot run this -- which is the same
  # property the window opener relies on, and is deliberate.
  [ -t 0 ] || die "no terminal. --keygen must be run from YOUR shell: the
         passphrase is typed here, and an agent must not be able to supply it."
  _pw1=""; _pw2=""
  printf 'Passphrase for the new directive key: ' >&2; IFS= read -rs _pw1; printf '\n' >&2
  printf 'Again: ' >&2;                              IFS= read -rs _pw2; printf '\n' >&2
  [ "$_pw1" = "$_pw2" ] || die "the two entries differ - nothing was created"
  # An empty passphrase is the one case this whole feature exists to prevent, so
  # refuse it HERE rather than generating a key and catching it in the probe.
  [ -n "$_pw1" ] || die "an empty passphrase gives no authority: any agent on
         this box could then sign in your name, and a signature would prove
         nothing. Nothing was created."

  KEYSTATUS="$(mktemp)"
  printf '%s' "$_pw1" | gpg "${GNUPGHOME_ARG[@]}" --batch --pinentry-mode loopback \
      --passphrase-fd 0 --status-fd 3 \
      --quick-generate-key "${DIRECTIVE_UID:-directive owner}" ed25519 sign never 3>"$KEYSTATUS"
  rv=$?
  _pw1=""; _pw2=""
  if [ $rv -ne 0 ]; then rm -f "$KEYSTATUS"; die "key generation FAILED (rv=$rv) - no key was created, and nothing below applies"; fi

  NEWFPR="$(awk '/^\[GNUPG:\] KEY_CREATED/{print $4; exit}' "$KEYSTATUS")"
  rm -f "$KEYSTATUS"
  [ -n "$NEWFPR" ] || die "key reported as created but gpg emitted no KEY_CREATED fingerprint"

  # A prompt happening is not the same as a passphrase existing. An empty one is
  # the exact case the whole design exists to prevent, so prove it by trying.
  # THE SAME PROBE --check-key USES, byte for byte. It used to be
  # `--pinentry-mode error`, which asks a DIFFERENT question: "can this sign
  # with no passphrase source at all". A key protected with an EMPTY passphrase
  # answers no to that (the agent must unlock, error mode forbids asking) and
  # yes to "can this sign with an empty passphrase" -- so keygen printed
  # "passphrase VERIFIED" for a key anything with sudo could sign with.
  # Measured on bx2 2026-09-16: keygen said VERIFIED, --check-key refused the
  # same key minutes later, and a hand probe signed it with ''. The agent
  # keyinfo flag was P (protected) while the passphrase was empty, which is the
  # state that splits the two probes; on a box where the flag is '-' they agree
  # and the bug is invisible.
  #
  # Two controls testing "the same" property by different mechanisms will
  # disagree eventually, and the weaker one is the one that grants assurance.
  # So there is one probe now, not two. If you change it, change it in
  # directive-verify.sh's _unattended too, or this comment is a lie.
  _PO="$(mktemp)"
  # NEVER -o /dev/null. gpg without --yes refuses to overwrite an existing
  # regular file, so if /dev/null is not a device the sign FAILS -- and a caller
  # reading failure as "passphrase required" gets a FALSE GREEN. That is not a
  # hypothetical: on bx2 /dev/null had become a regular 644 file, and it is the
  # measured mechanism behind a --keygen run that printed "passphrase VERIFIED"
  # for a key with no passphrase. A probe must fail for the reason it is testing
  # and for no other reason.
  if printf 'probe\n' | gpg "${GNUPGHOME_ARG[@]}" --batch --yes \
       --pinentry-mode loopback --passphrase '' --local-user "$NEWFPR" \
       --sign -o "$_PO" >/dev/null 2>&1; then
    rm -f "$_PO"
    echo "DANGER: that key signs UNATTENDED - it has no passphrase, and it is worthless."
    echo "        gpg --delete-secret-and-public-key $NEWFPR"
    die "refusing to report success for a key that provides no authority"
  fi
  # The agent has the fresh key's passphrase cached from generation, and on
  # gpg-agent 2.2.27 that cache survives clear_passphrase and RELOADAGENT. Until
  # it dies, anything with sudo on this box can sign with the key just made --
  # which is the exact exposure the passphrase exists to prevent, at the moment
  # the owner is being told the key is safe. Measured by bx2, 2026-09-16.
  if [ -n "${DIRECTIVE_GNUPGHOME:-}" ]; then
    GNUPGHOME="$DIRECTIVE_GNUPGHOME" gpgconf --kill gpg-agent >/dev/null 2>&1
  else
    gpgconf --kill gpg-agent >/dev/null 2>&1
  fi
  echo "OK: key created and its passphrase VERIFIED (an unattended sign was refused)."
  echo "    the gpg agent was killed, so the passphrase you just typed is not cached."
  echo "    fingerprint: $NEWFPR"
  echo
  echo "Now pin the fingerprint on every VERIFYING box (public half only):"
  echo "  gpg --export --armor <fpr>   ->  import there, then set DIRECTIVE_FPR=<fpr>"
  echo
  echo "Copy the SECRET half only to a box YOU sit at and type the passphrase on."
  echo "The control is that it cannot sign unattended, not where the file lives."
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) MINUTES="${2:?}"; shift 2 ;;
    --reply-to) REPLY_TO="${2:?}"; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown flag $1" ;;
    *) break ;;
  esac
done

TARGET="${1:-}"; shift || true
TEXT="${*:-}"
[ -n "$TARGET" ] || die "usage: directive-sign.sh [--minutes N] [--reply-to <box>] <target-box> \"<instruction>\""
[ -n "$TEXT" ]   || die "refusing to sign an empty instruction"
[ -n "$FPR" ]    || die "no DIRECTIVE_FPR pinned. Looked in: the environment, then this
         box's spool box config (\$SPOOL_ROOT/box.env). If the pin IS in box.env,
         this shell started before it existed -- open a new one rather than
         redoing setup you have already done."

# DIRECTIVE_FPR is an allow-list on the VERIFY side: every owner key a box will
# obey. Signing is the opposite -- exactly one key, and only one this box can
# possibly use. So resolve the list down to the entry whose SECRET half is here
# rather than handing gpg a list as --local-user, which fails with a confusing
# "No secret key" naming a fingerprint the operator never typed.
IFS=' ' read -r -a _FPRS <<< "$(printf '%s' "$FPR" | tr ',' ' ')"
if [ "${#_FPRS[@]}" -gt 1 ]; then
  _HELD=()
  for _f in "${_FPRS[@]}"; do
    gpg "${GNUPGHOME_ARG[@]}" --list-secret-keys "$_f" >/dev/null 2>&1 && _HELD+=("$_f")
  done
  case "${#_HELD[@]}" in
    0) die "DIRECTIVE_FPR pins ${#_FPRS[@]} keys and this box holds the secret half of none.
         This box can verify directives but cannot issue them." ;;
    1) FPR="${_HELD[0]}" ;;
    *) die "this box holds the secret half of ${#_HELD[@]} pinned keys: ${_HELD[*]}
         Name one explicitly: DIRECTIVE_FPR=<fingerprint> $0 ..." ;;
  esac
fi

NONCE="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
ISSUED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRES="$(date -u -d "+${MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"

{
  printf 'to: %s\n'      "$TARGET"
  [ -n "$REPLY_TO" ] && printf 'reply-to: %s\n' "$REPLY_TO"
  printf 'nonce: %s\n'   "$NONCE"
  printf 'issued: %s\n'  "$ISSUED"
  printf 'expires: %s\n' "$EXPIRES"
  printf -- '---\n'
  printf '%s\n' "$TEXT"
} | gpg "${GNUPGHOME_ARG[@]}" --pinentry-mode loopback \
      --local-user "$FPR" --clearsign --armor
# Without this a failed sign prints the header and no signature and says nothing
# -- a truncated block that reads like output. The owner hit exactly that.
rv=${PIPESTATUS[1]}
[ $rv -eq 0 ] || { printf 'ERROR: signing FAILED (rv=%s) - no envelope was produced\n' "$rv" >&2; exit 2; }
