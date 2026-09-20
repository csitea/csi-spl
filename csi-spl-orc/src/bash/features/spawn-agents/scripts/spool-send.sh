#!/usr/bin/env bash
# spool-send.sh — deliver one message to a peer agent through the spool, then
# show it in the peer's tmux pane.
#
# The spool-native replacement for a box engine's inbox-send.sh:
#
#   inbox-send.sh (reference)               spool-send.sh (this)
#   ---------------------------------       -----------------------------------
#   writes <ts>--<from>--<slug>.md with     `spool send` writes ONE v:1 JSON
#   YAML frontmatter into the peer inbox    object into $SPOOL_ROOT/<to>/inbox/
#                                           and a copy in <from>/outbox/
#   free markdown body                      `body` string; kind task|result|
#                                           note|reject; task_id threads it
#   tmux poke = doorbell                    the line CARRIES the message
#                                           (specs/028, contracts/poke-line.md)
#
# The FILE is the source of truth; the pane line is the second leg (trust-modes
# §2: local mode = file + poll). Every non-zero exit below 10 therefore still
# means the message WAS delivered — only the pane was left alone. Local mode is
# unsigned: the written object carries no `sig`.
#
# Usage:
#   spool-send.sh --from <ID> --to <ID> --kind task|result|note|reject
#                 [--task <uuid>] (--body <text> | --body-file <path>)
#                 [--file-ref <path>]... [--file-id <id>]... [--no-poke]
#   spool-send.sh --poke-only --to <ID> [--from <ID>]   # ring, send nothing
#
# stdout: spool's JSON result {delivery, msg_id, task_id, ts}, then one
# `poke:` status line.
#
# Exit codes:
#   0   delivered and shown in the pane (or --no-poke)
#   5   delivered; no live window carries <to> — it reads its inbox on its own
#   6   delivered; REFUSED to poke: the pane holds unsent typed text
#   7   delivered; the pane runs only bare shells (the agent has exited)
#   2   usage error (nothing sent)
#   10+ `spool send` failed: 10 + its exit code (nothing delivered)
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/spool-notify.inc.sh
. "$_here/../lib/spool-notify.inc.sh"
spool_env_resolve

usage() {
  sed -n '/^# Usage:/,/^# stdout:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

FROM=""; TO=""; KIND=""; TASK=""; MSGID=""; BODY=""; BODY_SET=0; POKE=1; POKE_ONLY=0
EXTRA=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)      [ "$#" -ge 2 ] || usage; FROM="$2"; shift 2 ;;
    --to)        [ "$#" -ge 2 ] || usage; TO="$2"; shift 2 ;;
    --kind)      [ "$#" -ge 2 ] || usage; KIND="$2"; shift 2 ;;
    --task)      [ "$#" -ge 2 ] || usage; TASK="$2"; shift 2 ;;
    --body)      [ "$#" -ge 2 ] || usage; BODY="$2"; BODY_SET=1; shift 2 ;;
    --body-file) [ "$#" -ge 2 ] || usage
                 [ -r "$2" ] || { echo "ERROR: cannot read --body-file $2" >&2; exit 2; }
                 BODY="$(cat "$2")"; BODY_SET=1; shift 2 ;;
    --file-ref|--file-id|--dir-ref|--dir-blob)
                 [ "$#" -ge 2 ] || usage; EXTRA+=("$1" "$2"); shift 2 ;;
    --no-poke)   POKE=0; shift ;;
    --poke-only) POKE_ONLY=1; shift ;;
    -h|--help)   usage ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$TO" ] || { echo "ERROR: --to is required" >&2; usage; }
spool_valid_id "$TO" || exit 2
[ -z "$FROM" ] || spool_valid_id "$FROM" || exit 2

if [ "$POKE_ONLY" -eq 0 ]; then
  [ -n "$FROM" ] || { echo "ERROR: --from is required" >&2; usage; }
  case "$KIND" in task|result|note|reject) ;; *) echo "ERROR: --kind must be task|result|note|reject, got: '${KIND}'" >&2; exit 2 ;; esac
  [ "$BODY_SET" -eq 1 ] || { echo "ERROR: --body or --body-file is required" >&2; exit 2; }

  args=(send --from "$FROM" --to "$TO" --kind "$KIND" --body "$BODY")
  [ -n "$TASK" ] && args+=(--task "$TASK")
  args+=("${EXTRA[@]}")
  # specs/028 FR-008: the binary's own notify hook is OFF for this send. This
  # script rings the pane itself, below, so it can report the outcome as its
  # exit code; letting both fire would show the message twice.
  out="$(SPOOL_ROOT="$SPOOL_ROOT" SPOOL_NOTIFY_CMD=off "$SPOOL_BIN" "${args[@]}")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: '${SPOOL_BIN} send' failed (rc=${rc}); nothing was delivered" >&2
    exit $((10 + rc))
  fi
  printf '%s\n' "$out"
  TASK="$(printf '%s' "$out" | sed -n 's/.*"task_id" *: *"\([^"]*\)".*/\1/p')"
  MSGID="$(printf '%s' "$out" | sed -n 's/.*"msg_id" *: *"\([^"]*\)".*/\1/p')"
fi

[ "$POKE" -eq 1 ] || { echo "poke: skipped (--no-poke); ${TO} finds it on its next 'spool recv'"; exit 0; }

# ---- the pane leg (lib/spool-notify.inc.sh, contracts/poke-line.md) --------
spool_notify "$TO" "$KIND" "$FROM" "$TASK" "$MSGID" "$BODY"
exit $?
