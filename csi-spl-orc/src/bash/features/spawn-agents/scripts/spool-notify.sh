#!/usr/bin/env bash
# spool-notify.sh — make a message that is ALREADY in an agent's inbox visible
# in that agent's terminal pane.
#
# specs/028-spool-terminal-delivery FR-001/FR-002. This is the command the
# spool binary runs (`SPOOL_NOTIFY_CMD`) straight after it writes a v:1 object
# into `$SPOOL_ROOT/<to>/inbox/`, whichever hop wrote it:
#
#   - `spool send` / the `spool_send` MCP tool, same box (002)
#   - `spool hub-run` draining the hub queue: another box (003), or a
#     signed-in human's `box-wui` task from the WUI (014)
#
# It sends nothing and writes nothing. The file is still the record (002); this
# is the second leg, and every failure mode below leaves the message delivered.
#
# Usage:
#   spool-notify.sh --to <ID> [--from <ID>] [--kind task|result|note|reject]
#                   [--task <uuid>] [--msg-id <uuid>]
#                   (--body <text> | --body-file <path> | --body-stdin)
#
# The rendered line and its bounds: specs/028-.../contracts/poke-line.md.
#
# Exit codes:
#   0   the line was typed into the recipient's pane
#   5   no live window carries <ID> — it reads its inbox on its own
#   6   REFUSED: the pane holds unsent typed text; nothing was typed over it
#   7   the pane runs only bare shells (the agent has exited)
#   2   usage error
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/spool-notify.inc.sh
. "$_here/../lib/spool-notify.inc.sh"
# shellcheck source=../lib/spool-poke-queue.inc.sh
. "$_here/../lib/spool-poke-queue.inc.sh"
# The notifier never launches a CLI, and it is the one caller on a latency
# budget: skip resolving the CLI paths (CLE-3435).
SPOOL_ENV_NO_BINS=1 spool_env_resolve

usage() {
  sed -n '/^# Usage:/,/^# The rendered/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

TO=""; FROM=""; KIND=""; TASK=""; MSGID=""; BODY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)        [ "$#" -ge 2 ] || usage; TO="$2"; shift 2 ;;
    --from)      [ "$#" -ge 2 ] || usage; FROM="$2"; shift 2 ;;
    --kind)      [ "$#" -ge 2 ] || usage; KIND="$2"; shift 2 ;;
    --task)      [ "$#" -ge 2 ] || usage; TASK="$2"; shift 2 ;;
    --msg-id)    [ "$#" -ge 2 ] || usage; MSGID="$2"; shift 2 ;;
    --body)      [ "$#" -ge 2 ] || usage; BODY="$2"; shift 2 ;;
    --body-file) [ "$#" -ge 2 ] || usage
                 [ -r "$2" ] || { echo "ERROR: cannot read --body-file $2" >&2; exit 2; }
                 BODY="$(cat "$2")"; shift 2 ;;
    --body-stdin) BODY="$(cat)"; shift ;;
    -h|--help)   usage ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$TO" ] || { echo "ERROR: --to is required" >&2; usage; }
spool_valid_id "$TO" || exit 2

# 1. SHOW it. tmux's status line for the agent's window (and its tty where no
#    TUI owns the screen) is a surface the prompt rule does not gate, so a busy
#    pane still DISPLAYS the message. It injects nothing.
spool_poke_show "$TO" "$KIND" "$FROM" "$TASK" "$MSGID" "$BODY"

# 2. OFFER it to the prompt, under the safe-poke rules, unchanged.
#
#    SPOOL_POKE=0 leaves the prompt alone entirely - no poke, and no queue
#    either, so nothing can be re-offered later. That is a real trade, not a
#    tidy-up: the poke line is how an AGENT learns it has mail, its prompt
#    being its only input, so with this off the notice reaches the pane and
#    nobody acts on it until a person reads it. Set it where a person watches
#    the pane and the prompt is theirs - the orchestrator's own seat, where a
#    queue that had waited out a long busy prompt delivered a batch of
#    already-answered notices in one burst (measured 2026-09-21).
if [ "${SPOOL_POKE:-1}" = 0 ]; then
  echo "poke: off (SPOOL_POKE=0) - ${TO} was SHOWN the message; its prompt was not touched"
  exit 0
fi
spool_notify_render _line "$TO" "$KIND" "$FROM" "$TASK" "$MSGID" "$BODY"
spool_notify_poke "$TO" "$_line"
rc=$?

# 3. A REFUSED line is queued, not dropped. The rule that a half-written line
#    is never typed over is right; one-shot delivery on top of it is what made
#    a refusal indistinguishable from a swallowed message for an agent whose
#    only input is its prompt. The daemon re-offers it until the prompt frees.
if [ "$rc" = 6 ]; then
  if entry="$(spool_poke_queue_add "$TO" "$_line")" && spool_poke_retry_ensure "$TO"; then
    echo "poke: queued for ${TO} (${entry##*/}); a retry daemon offers it again when the prompt is clear"
  else
    echo "poke: could NOT queue the refused line for ${TO}; it waits in ${SPOOL_ROOT}/${TO}/inbox/"
  fi
fi
exit "$rc"
