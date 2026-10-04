#!/usr/bin/env bash
# directive-session.sh — open a bounded window in which the owner's directive
# key signs without re-prompting, so one passphrase entry covers a whole
# session's worth of directives.
#
#   directive-session.sh [--minutes N]   open a window (default 60)
#   directive-session.sh --status        is one open, and for how much longer
#   directive-session.sh --close         shut it now
#
# WHY THIS AND NOT A "TRUSTED SESSION TOKEN"
#
# The obvious cheaper design is to sign ONE envelope saying "this session is
# mine" and then trust plain prose from it. That signature covers the sentence
# "this session is mine" and says nothing about any instruction that follows, so
# the receiving box ends up acting on the relaying AGENT'S RENDITION of what the
# owner said. Paraphrase, re-scoping and confidently relaying a conclusion are
# what an agent does all day -- on 2026-09-16 a peer asserted in good faith that
# the owner was not in a session they had typed into twice in the preceding
# minutes. A session token trusts exactly that layer.
#
# This window costs the owner the same single passphrase entry, but every
# directive is still signed over ITS OWN TEXT. What survives is: the text the
# receiving box acts on is the text that was signed on the owner's box inside a
# window they opened. Drift cannot get through. An agent here deliberately signing
# something they did not write still can -- that is the price of typing the
# passphrase once instead of every time, it is identical under a session token,
# and it is the honest limit of both.
set -uo pipefail

# The pin and the box tag come from the spool's box config, parse-only, never
# clobbering a variable already set (lib/directive-env.inc.sh).
# shellcheck source=../lib/directive-env.inc.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)/directive-env.inc.sh" && directive_env_load

# NOT beside the nonce ledger. That directory must stay agent-writable -- the
# verifier runs as the agent and records spent nonces there -- and a record an
# agent can write is a record --check-key must not trust.
STATE="${DIRECTIVE_SESSION_STATE:-/var/lib/spool-hub/directive-session.state}"
# Do not require HOME. Under set -u a bare $HOME is a crash, and HOME is
# genuinely unset in a pane inherited from a tmux server started with a bare
# environment -- which is what today's boot/restore path does for root on bx2:
# `tmux show-environment -g HOME` answers "unknown variable" and every pane
# inherits that. The owner hit this trying to open a window, 2026-09-16.
_dh_home() { printf '%s' "${HOME:-$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)}"; }
GNUPGHOME_DIR="${DIRECTIVE_GNUPGHOME:-${GNUPGHOME:-$(_dh_home)/.gnupg}}"
AGENT_CONF="$GNUPGHOME_DIR/gpg-agent.conf"
MINUTES=60
ACTION=open

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
say() { printf '  %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) MINUTES="${2:?}"; shift 2 ;;
    --status)  ACTION=status; shift ;;
    --close)   ACTION=close;  shift ;;
    -*) die "unknown flag $1" ;;
    *)  die "usage: directive-session.sh [--minutes N|--status|--close]" ;;
  esac
done

# The one key this box can actually sign with. Same resolution the signer uses:
# DIRECTIVE_FPR is an allow-list of keys to OBEY, and only one of them is ours.
resolve_signing_fpr() {
  local f held=()
  IFS=' ' read -r -a _all <<< "$(printf '%s' "${DIRECTIVE_FPR:-}" | tr ',' ' ')"
  [ "${#_all[@]}" -gt 0 ] || die "no DIRECTIVE_FPR pinned"
  for f in "${_all[@]}"; do
    [ -n "$f" ] || continue
    gpg --list-secret-keys "$f" >/dev/null 2>&1 && held+=("$f")
  done
  case "${#held[@]}" in
    0) die "this box holds the secret half of none of the pinned keys — it can verify but not issue" ;;
    1) printf '%s\n' "${held[0]}" ;;
    *) die "this box holds ${#held[@]} pinned secret halves: ${held[*]}
         Name one: DIRECTIVE_FPR=<fingerprint> $0 ..." ;;
  esac
}

keygrip_of() {
  gpg --with-keygrip --list-secret-keys "$1" 2>/dev/null | sed -n 's/.*Keygrip = //p' | sed -n 1p
}

window_open() {
  [ -f "$STATE" ] || return 1
  local exp; exp="$(sed -n 's/^expires_epoch=//p' "$STATE" | sed -n 1p)"
  [ -n "$exp" ] || return 1
  [ "$(date -u +%s)" -lt "$exp" ]
}

case "$ACTION" in
status)
  if window_open; then
    exp="$(sed -n 's/^expires_epoch=//p' "$STATE" | sed -n 1p)"
    printf '\n=== directive session OPEN\n'
    say "signer    $(sed -n 's/^fpr=//p' "$STATE" | sed -n 1p)"
    say "closes    $(date -u -d "@$exp" +%Y-%m-%dT%H:%M:%SZ)  ($(( (exp - $(date -u +%s) + 59) / 60 )) min left)"
    printf '\n  OK\n\n'; exit 0
  fi
  printf '\n=== directive session CLOSED\n'
  say "Every directive will prompt for the passphrase, on the terminal."
  say "Open one:  directive-session.sh --minutes 60"
  printf '\n'; exit 0
  ;;
close)
  FPR="$(resolve_signing_fpr)" || exit 2
  KG="$(keygrip_of "$FPR")"
  [ -n "$KG" ] && gpg-connect-agent "clear_passphrase --mode=normal $KG" /bye >/dev/null 2>&1
  if [ -f "$STATE" ]; then
    BAK="$(sed -n 's/^agent_conf_backup=//p' "$STATE" | sed -n 1p)"
    if [ -n "$BAK" ] && [ "$BAK" != none ] && [ -f "$BAK" ]; then
      cp "$BAK" "$AGENT_CONF" && rm -f "$BAK"
    elif [ "$BAK" = none ]; then
      rm -f "$AGENT_CONF"
    fi
    rm -f "$STATE"
  fi
  # --close is the REVOCATION, so it must end the ability to sign, not just the
  # record that a window is open. On gpg-agent 2.2.27 (measured on bx2,
  # 2026-09-16) clear_passphrase and reloadagent both left an unlocked key
  # usable: it still signed with a WRONG passphrase and with an EMPTY one, while
  # keyinfo reported it uncached. Only killing the agent evicted it. Kill it
  # AFTER the conf restore so the agent that restarts on demand reads the
  # restored policy. Same primitive as directive-sign.sh and directive-verify.sh.
  GNUPGHOME="$GNUPGHOME_DIR" gpgconf --kill gpg-agent >/dev/null 2>&1
  printf '\n=== directive session CLOSED\n'
  say "gpg-agent killed; the next directive will prompt again"
  printf '\n  OK\n\n'
  ;;
open)
  case "$MINUTES" in ''|*[!0-9]*) die "--minutes takes a whole number of minutes" ;; esac
  [ "$MINUTES" -ge 1 ] && [ "$MINUTES" -le 480 ] || die "--minutes must be between 1 and 480"
  [ -t 0 ] || die "no terminal. The passphrase prompt is drawn on the tty, so this
         must be run from YOUR shell -- an agent cannot open the window for you,
         and that is the point."
  FPR="$(resolve_signing_fpr)" || exit 2

  # Prove the key needs a passphrase BEFORE opening a window, because once one
  # is open --check-key stops re-proving it (telling "cached" from "absent"
  # requires a flush, which would close the window). Without this a
  # passphrase-less key could ride an open window to a green self-audit. Cheap
  # to check here, impossible to check later.
  _SO="$(mktemp)"
  # NEVER -o /dev/null. gpg without --yes refuses to overwrite an existing
  # regular file, so if /dev/null is not a device the sign FAILS -- and a caller
  # reading failure as "passphrase required" gets a FALSE GREEN. That is not a
  # hypothetical: on bx2 /dev/null had become a regular 644 file, and it is the
  # measured mechanism behind a --keygen run that printed "passphrase VERIFIED"
  # for a key with no passphrase. A probe must fail for the reason it is testing
  # and for no other reason.
  #
  # Kill the agent FIRST. A still-running gpg-agent can hold the key unlocked
  # from an earlier signature or window; on gpg-agent 2.2.27 neither
  # clear_passphrase nor reloadagent evicts it. The probe below then signs with
  # an EMPTY passphrase and this check blames a sound key. Measured on bx2,
  # 2026-09-16: the same key signed with '' through the running agent and was
  # refused (rc=2) through a fresh one; the owner was told to regenerate a good
  # key twice. Same primitive as --close, directive-sign.sh and directive-verify.sh.
  GNUPGHOME="$GNUPGHOME_DIR" gpgconf --kill gpg-agent >/dev/null 2>&1
  if printf 'probe\n' | gpg --batch --yes \
       --pinentry-mode loopback --passphrase '' --local-user "$FPR" \
       --sign -o "$_SO" >/dev/null 2>&1; then
    rm -f "$_SO"
    die "that key signs UNATTENDED with no window open — it has no passphrase,
         so it grants no authority and a session would be meaningless.
         Regenerate it:  directive-sign.sh --keygen"
  fi

  SECS=$(( MINUTES * 60 ))
  _SD="$(dirname "$STATE")"
  mkdir -p "$_SD" 2>/dev/null
  # Opening a window that --check-key will refuse to trust is worse than not
  # opening one: it looks like it worked. Fail here, where the message can say
  # what to do about it.
  _m="$(stat -c %a "$_SD" 2>/dev/null)" || die "cannot stat $_SD"
  [ $(( 8#$_m & 0022 )) -eq 0 ] || die "$_SD is group- or world-writable (mode $_m), so an
         agent could forge the session record and --check-key will not trust it.
         Fix it once:  sudo install -d -o \$USER -g \$USER -m 0755 $_SD"

  # Back up whatever agent policy exists, then set one bounded to this window.
  BAK=none
  if [ -f "$AGENT_CONF" ]; then
    BAK="$AGENT_CONF.pre-directive-$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$AGENT_CONF" "$BAK"
    sed -i '/^default-cache-ttl\b/d; /^max-cache-ttl\b/d' "$AGENT_CONF"
  fi
  printf 'default-cache-ttl %s\nmax-cache-ttl %s\n' "$SECS" "$SECS" >> "$AGENT_CONF"
  gpg-connect-agent reloadagent /bye >/dev/null 2>&1

  # Populate the cache with ONE real signature. This is the passphrase prompt,
  # and it doubles as proof the key works before anything depends on it.
  printf 'directive-session liveness %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | gpg --pinentry-mode loopback --local-user "$FPR" --clearsign --armor >/dev/null
  rv=${PIPESTATUS[1]}
  if [ "$rv" -ne 0 ]; then
    [ "$BAK" != none ] && cp "$BAK" "$AGENT_CONF" && rm -f "$BAK" || rm -f "$AGENT_CONF"
    gpg-connect-agent reloadagent /bye >/dev/null 2>&1
    die "signing failed (rv=$rv) — no window was opened, and the agent policy was put back"
  fi

  EXP=$(( $(date -u +%s) + SECS ))
  { printf 'fpr=%s\n' "$FPR"
    printf 'opened=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'expires_epoch=%s\n' "$EXP"
    printf 'expires=%s\n' "$(date -u -d "@$EXP" +%Y-%m-%dT%H:%M:%SZ)"
    printf 'agent_conf_backup=%s\n' "$BAK"
  } > "$STATE"
  # 0644, not the umask default. A 664 record is group-writable, and the agent
  # user is in the owner's group on this box -- so the default umask produced a
  # record --check-key correctly refused to trust. Readable by the agent is
  # required (it must see that a window is open); writable by the agent is the
  # whole vulnerability.
  chmod 0644 "$STATE" || die "could not set mode 0644 on $STATE"

  printf '\n=== directive session OPEN\n'
  say "signer    $FPR"
  say "closes    $(date -u -d "@$EXP" +%Y-%m-%dT%H:%M:%SZ)  ($MINUTES min)"
  say ""
  say "Until then every directive signs without prompting, each one still"
  say "signed over its own text. An agent on THIS box can also sign in your"
  say "name during the window -- that is the price of typing it once, and it"
  say "is the same price a session token would charge."
  say ""
  say "Shut it early:  directive-session.sh --close"
  printf '\n  OK\n\n'
  ;;
esac
