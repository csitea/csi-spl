#!/usr/bin/env bash
# agent-send.sh — send a message to an agent through the mailbox it was
# SPAWNED with (specs/048 switch-over §3): the spool mailbox for an agent of
# this harness, the frozen engine's markdown inbox for one it spawned. During
# the switch-over both kinds of agent are alive at once; an orchestrator uses
# this one command for both and never has to know which is which.
#
# It takes the frozen engine's sender arguments, so it is a drop-in for it:
#
# Usage:
#   agent-send.sh [--from <ID>] <ID> <message text...>
#   agent-send.sh [--from <ID>] <ID> --file <path>
#     [--subject <slug>] [--kind task|result|note|reject|blocker|msg]
#     [--no-poke] [--via auto|spool|legacy]
#   Options may come before or after <ID>.
#
# Routing (--via auto, the default), first match wins:
#   1. <ID> is in $SPOOL_ROOT/registry.tsv    -> spool   (spawned by this harness)
#   2. $SPOOL_LEGACY_INBOX_ROOT/<ID>/inbox    -> legacy  (spawned by the frozen
#      engine; it may ALSO have a spool dir, because the desk seats every pane
#      agent, but its brief tells it to read the markdown inbox)
#   3. $SPOOL_ROOT/<ID>/inbox                 -> spool
#   4. none                                   -> exit 3, nothing delivered
#
# The legacy leg is NOT reimplemented: it runs $SPOOL_LEGACY_SEND (the frozen
# engine's sender) with the same arguments, so an old agent is reached exactly
# the way it is today - same file, same shell-inert poke, same exit codes.
# SPOOL_LEGACY_INBOX_ROOT must be the root that sender writes to.
#
# The spool leg is scripts/spool-send.sh (kind default note; the sender id
# defaults to $SPOOL_AGENT_ID, then $MCP_BOT_AGENT_ID).
#
# stdout: "via: <spool|legacy> (<reason>)", then the leg's own output.
# Exit codes: 2 usage; 3 no mailbox for <ID> (or a legacy target with no
# SPOOL_LEGACY_SEND); otherwise the leg's own code - spool-send.sh: 0 shown,
# 5/6/7 delivered but not poked, 10+ not delivered; the legacy sender: its
# codes (non-zero after the file is written still means delivered).
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

usage() { sed -n '/^# Usage:/,/^# Routing/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

FROM="${SPOOL_AGENT_ID:-${MCP_BOT_AGENT_ID:-}}" TO="" FILE="" SUBJECT="" KIND=note POKE=1 VIA=auto
TEXT=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)    [ "$#" -ge 2 ] || usage; FROM="$2"; shift 2 ;;
    --file)    [ "$#" -ge 2 ] || usage; FILE="$2"; shift 2 ;;
    --subject) [ "$#" -ge 2 ] || usage; SUBJECT="$2"; shift 2 ;;
    --kind)    [ "$#" -ge 2 ] || usage; KIND="$2"; shift 2 ;;
    --via)     [ "$#" -ge 2 ] || usage; VIA="$2"; shift 2 ;;
    --no-poke) POKE=0; shift ;;
    -h|--help) usage ;;
    -*) echo "agent-send: unknown option $1" >&2; usage ;;
    *) if [ -z "$TO" ]; then TO="$1"; else TEXT+=("$1"); fi; shift ;;
  esac
done
[ -n "$TO" ] || usage
# cle-7 -> CLE-07, the way the frozen engine's sender normalises it
if [[ "$TO" =~ ^([A-Za-z]{2,4})-?([0-9]+)$ ]]; then
  TO="$(printf '%s-%02d' "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')" "$((10#${BASH_REMATCH[2]}))")"
fi
spool_valid_id "$TO" || exit 2
if [ -n "$FILE" ]; then
  [ "${#TEXT[@]}" -eq 0 ] || { echo "agent-send: give the text OR --file, not both" >&2; exit 2; }
  [ -r "$FILE" ] || { echo "agent-send: cannot read --file $FILE" >&2; exit 2; }
else
  [ "${#TEXT[@]}" -gt 0 ] || { echo "agent-send: no message (text or --file)" >&2; exit 2; }
fi
case "$VIA" in auto|spool|legacy) ;; *) echo "agent-send: --via must be auto, spool or legacy" >&2; exit 2 ;; esac

LEGACY_ROOT="${SPOOL_LEGACY_INBOX_ROOT:-}"
in_spool_registry() { [ -r "$SPOOL_ROOT/registry.tsv" ] && cut -f1 "$SPOOL_ROOT/registry.tsv" | sed -E 's/^.*: //' | grep -qx "$TO"; }
route="" why=""
case "$VIA" in
  spool)  route=spool why="--via spool" ;;
  legacy) route=legacy why="--via legacy" ;;
  auto)
    if in_spool_registry; then route=spool why="$TO is in $SPOOL_ROOT/registry.tsv"
    elif [ -n "$LEGACY_ROOT" ] && [ -d "$LEGACY_ROOT/$TO/inbox" ]; then route=legacy why="$TO has a markdown inbox under $LEGACY_ROOT"
    elif [ -d "$SPOOL_ROOT/$TO/inbox" ]; then route=spool why="$TO has a spool mailbox under $SPOOL_ROOT"
    fi ;;
esac
[ -n "$route" ] || { echo "agent-send: no mailbox for $TO (not in $SPOOL_ROOT/registry.tsv, no $SPOOL_ROOT/$TO/inbox${LEGACY_ROOT:+, no $LEGACY_ROOT/$TO/inbox}); nothing delivered" >&2; exit 3; }
echo "via: $route ($why)"

if [ "$route" = legacy ]; then
  [ -n "${SPOOL_LEGACY_SEND:-}" ] || { echo "agent-send: $TO needs the legacy sender, but SPOOL_LEGACY_SEND is not set; nothing delivered" >&2; exit 3; }
  args=()
  [ -n "$FROM" ] && args+=(--from "$FROM")
  args+=("$TO")
  [ -n "$SUBJECT" ] && args+=(--subject "$SUBJECT")
  [ "$POKE" = 1 ] || args+=(--no-poke)
  if [ -n "$FILE" ]; then args+=(--file "$FILE"); else args+=("${TEXT[@]}"); fi
  exec bash "$SPOOL_LEGACY_SEND" "${args[@]}"
fi

[ -n "$FROM" ] || { echo "agent-send: the spool needs a sender id: --from <ID> (or SPOOL_AGENT_ID)" >&2; exit 2; }
args=(--from "$FROM" --to "$TO" --kind "$KIND")
[ "$POKE" = 1 ] || args+=(--no-poke)
if [ -n "$FILE" ]; then args+=(--body-file "$FILE"); else args+=(--body "${TEXT[*]}"); fi
exec bash "$_here/spool-send.sh" "${args[@]}"
