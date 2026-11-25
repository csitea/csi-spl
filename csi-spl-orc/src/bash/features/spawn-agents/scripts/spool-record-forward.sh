#!/usr/bin/env bash
# spool-record-forward.sh — the hub record of a same-box message (spec 058
# section 7, SPL-6513, latency action 3).
#
#   spool-record-forward.sh --from <ID> --to <ID> --kind <k> --msg-id <uuid>
#                           --body <text> [--task <task>]
#
# spool-send.sh starts it DETACHED once a message was delivered on this
# machine (delivery local): the inbox file and the poke are written already
# and never wait on it. It hands the hub a record-only copy of the message,
# under the same msg_id, through this machine's desk sidecar
# (spool-fleet-relay.sh --record-of). The hub stores the copy once and
# delivers it to no box: no second inbox file, no second poke, anywhere.
#
# Measured before (latency panel, 2026-11-25): 0 % of about 3,700 same-box
# messages a day reached the hub, so the owner saw none of them.
#
# A hub that is down does not lose it: the desk's `spool send --record-of`
# queues the signed copy in its .hub/pending-record/ and the sidecar flushes
# it on its next 10 s scan. No fleet desk on this machine, or a desk with no
# live sidecar: nothing is recorded, and the log says so.
#
# Log: one line per message in $SPOOL_ROOT/.record/forward.log (SPOOL_RECORD_LOG):
#   <ts> <msg_id> rc=<relay rc> ms=<elapsed> <delivery or why>
# Exit: the relay's code (0 handed to the hub), 2 usage, 3 no desk.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/spool-fleet.inc.sh
. "$_here/../lib/spool-fleet.inc.sh"
spool_env_resolve

FROM="" TO="" KIND="" MSGID="" BODY="" TASK="" BODY_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) [ "$#" -ge 2 ] || exit 2; FROM="$2"; shift 2 ;;
    --to) [ "$#" -ge 2 ] || exit 2; TO="$2"; shift 2 ;;
    --kind) [ "$#" -ge 2 ] || exit 2; KIND="$2"; shift 2 ;;
    --msg-id) [ "$#" -ge 2 ] || exit 2; MSGID="$2"; shift 2 ;;
    --body) [ "$#" -ge 2 ] || exit 2; BODY="$2"; BODY_SET=1; shift 2 ;;
    --task) [ "$#" -ge 2 ] || exit 2; TASK="$2"; shift 2 ;;
    *) echo "spool-record-forward: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$FROM" && -n "$TO" && -n "$KIND" && "$BODY_SET" = 1 &&
   "$MSGID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  { echo "spool-record-forward: usage: --from <ID> --to <ID> --kind <k> --msg-id <uuid> --body <text> [--task <task>]" >&2; exit 2; }

LOG="${SPOOL_RECORD_LOG:-$SPOOL_ROOT/.record/forward.log}"
log() {  # RC MS TEXT
  { mkdir -p "${LOG%/*}" && printf '%s %s rc=%s ms=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MSGID" "$1" "$2" "$3" >>"$LOG"; } 2>/dev/null || true
}

if ! spool_fleet_desk_configured; then
  log 3 0 "no fleet desk on this machine: not recorded"
  exit 3
fi
t0="$(date +%s%3N)"
args=(--from "$FROM" --to "$TO" --kind "$KIND" --body "$BODY" --record-of "$MSGID")
[ -n "$TASK" ] && args+=(--task "$TASK")
# timeout runs a command, not a function: the relay leg is a child bash that
# sources the same two libs, so it is capped and never outlives its budget.
# shellcheck disable=SC2016 # the child expands $1 $2 $@, not this shell
out="$(timeout "${SPOOL_RECORD_TIMEOUT:-60}" bash -c '. "$1"; . "$2"; spool_env_resolve; shift 2; spool_fleet_relay "$@"' _ \
  "$_here/../lib/spool-env.inc.sh" "$_here/../lib/spool-fleet.inc.sh" "${args[@]}" 2>&1)"
rc=$?
ms=$(( $(date +%s%3N) - t0 ))
d="$(printf '%s' "$out" | sed -n 's/.*"delivery" *: *"\([^"]*\)".*/\1/p' | tail -1)"
log "$rc" "$ms" "${d:-$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)}"
exit "$rc"
