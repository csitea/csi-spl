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
spool_env_resolve

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

spool_notify "$TO" "$KIND" "$FROM" "$TASK" "$MSGID" "$BODY"
