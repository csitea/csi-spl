#!/usr/bin/env bash
# spool-poke-retry.sh — keep offering the pokes a busy prompt refused.
#
# specs/028-spool-terminal-delivery, contracts/poke-line.md §3. spool-notify.sh
# refuses to type over unsent text (exit 6) and that rule stays. This daemon is
# what makes the refusal a DELAY instead of a loss: it re-offers each queued
# line, oldest first, until the prompt is clear or the deadline passes.
#
# It is started by spool-notify.sh (lib/spool-poke-queue.inc.sh), one per
# recipient, and can be run by hand to flush a queue:
#
#   spool-poke-retry.sh --to <ID> [--once]
#
# Env:
#   SPOOL_ROOT              the spool root holding <ID>/.pokes
#   SPOOL_POKE_RETRY_SECS   how long to keep offering, default 1800
#   SPOOL_POKE_RETRY_EVERY  seconds between sweeps, default 2
#   SPOOL_POKE_GAP          seconds between two accepted pokes, default 1
#   SPOOL_POKE_MAX_AGE      an entry older than this is DROPPED, not offered,
#                           default 300. A prompt that stays busy for half an
#                           hour otherwise collects a queue that all arrives at
#                           once the moment it clears - notices for messages
#                           answered long ago. Measured on this box 2026-09-21:
#                           24 entries waiting behind one busy prompt. The
#                           message is in the inbox either way; only the
#                           doorbell is dropped, and a doorbell for something
#                           half an hour old is noise, not news.
#   SPOOL_POKE              0 makes this daemon exit at once and clear the
#                           queue: the seat has said its prompt is off limits
#
# Exit codes:
#   0   the queue is empty, or the deadline passed with entries left (they stay
#       on disk, and the messages themselves are in the inbox either way)
#   2   usage
#   73  the queue dir is not usable
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/spool-notify.inc.sh
. "$_here/../lib/spool-notify.inc.sh"
# shellcheck source=../lib/spool-poke-queue.inc.sh
. "$_here/../lib/spool-poke-queue.inc.sh"
spool_env_resolve

TO="" ONCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)   [ "$#" -ge 2 ] || { echo "usage: spool-poke-retry.sh --to <ID> [--once]" >&2; exit 2; }; TO="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help) echo "usage: spool-poke-retry.sh --to <ID> [--once]" >&2; exit 2 ;;
    *) echo "spool-poke-retry: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TO" ] || { echo "spool-poke-retry: --to <ID> is required" >&2; exit 2; }
spool_valid_id "$TO" || exit 2

DIR="$(spool_poke_queue_dir "$TO")"
mkdir -p "$DIR" 2>/dev/null || { echo "spool-poke-retry: cannot create $DIR" >&2; exit 73; }

if [ "${SPOOL_POKE:-1}" = 0 ]; then
  rm -f "$DIR"/*.poke
  echo "spool-poke-retry: SPOOL_POKE=0 for ${TO}; queue cleared, nothing will be offered"
  exit 0
fi

# One daemon per recipient. A second one would race the first for the same
# entries and could type the same line twice.
exec 8>"$DIR/retry.lock" || exit 73
flock -n 8 || { echo "spool-poke-retry: another daemon holds ${TO}'s queue"; exit 0; }
echo "$$" >"$DIR/retry.pid"
trap 'rm -f "$DIR/retry.pid"' EXIT

now=0
every="${SPOOL_POKE_RETRY_EVERY:-2}"
gap="${SPOOL_POKE_GAP:-1}"
deadline=$(( $(date +%s) + ${SPOOL_POKE_RETRY_SECS:-1800} ))
echo "spool-poke-retry: watching ${TO}'s queue ($DIR) until $(date -u -d "@$deadline" +%Y-%m-%dT%H:%M:%SZ)"

while :; do
  entries=()
  while IFS= read -r f; do [ -n "$f" ] && entries+=("$f"); done < <(ls -1 "$DIR"/*.poke 2>/dev/null | sort)
  [ "${#entries[@]}" -eq 0 ] && { echo "spool-poke-retry: ${TO}'s queue is empty"; exit 0; }

  now="$(date +%s)"
  for f in "${entries[@]}"; do
    # Stale entries are dropped, never offered: see SPOOL_POKE_MAX_AGE above.
    age_of="$(stat -c %Y "$f" 2>/dev/null)" || age_of="$now"
    if [ "$(( now - age_of ))" -gt "${SPOOL_POKE_MAX_AGE:-300}" ]; then
      rm -f "$f"
      echo "spool-poke-retry: dropped a poke for ${TO} older than ${SPOOL_POKE_MAX_AGE:-300}s; the message is in its inbox"
      continue
    fi
    line="$(cat "$f" 2>/dev/null)" || continue
    [ -n "$line" ] || { rm -f "$f"; continue; }
    spool_notify_poke "$TO" "$line"; rc=$?
    case "$rc" in
      0) rm -f "$f"; sleep "$gap" ;;
      # 6 unsent text, 5 no window, 7 only shells: all "not now", not "never".
      *) break ;;
    esac
  done

  [ "$ONCE" = 1 ] && exit 0
  [ "$(date +%s)" -ge "$deadline" ] && {
    left="$(ls -1 "$DIR"/*.poke 2>/dev/null | wc -l)"
    echo "spool-poke-retry: deadline reached with $left entr$([ "$left" = 1 ] && echo y || echo ies) left for ${TO}; the messages are in ${SPOOL_ROOT}/${TO}/inbox/"
    exit 0
  }
  sleep "$every"
done
