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
#                                           note|reject; task_id topics it
#   tmux poke = doorbell                    the line CARRIES the message
#                                           (specs/028, contracts/poke-line.md)
#                                           and the sender's own notice STRIP
#                                           gains an outbound record, so the
#                                           column reads as a conversation
#
# Across machines (specs/058 N1): --to that is NOT an agent of this machine's
# $SPOOL_ROOT (no dir, no registry.tsv row) is relayed through the hub by THIS
# machine's desk sidecar (scripts/spool-fleet-relay.sh); the hub roster names
# the box that holds it, and that machine's sidecar writes it into the agent's
# inbox there and rings its pane. delivery is then the hub's (sent|queued|
# pending), never "local", and no orphan inbox is made here. An id the hub
# cannot place either is refused, exit 13, nothing written.
# `--to <ID>@<box>` names the machine: this machine's own desk box sends
# locally, any other box is relayed with that to_box (the role ids 001-003
# exist on every machine, so a bare id can be ambiguous on the hub).
# `--to orchestrator` is whoever holds the fleet lease's orch role
# (lib/spool-fleet.inc.sh), not a fixed id on this machine.
#
# The FILE is the source of truth; the pane line is the second leg (trust-modes
# §2: local mode = file + poll). Every non-zero exit below 10 therefore still
# means the message WAS delivered — only the pane was left alone. Local mode is
# unsigned: the written object carries no `sig`.
#
# Asks (CLE-77929, SPEC-spool-fleet-roles.md 4.3): a blocker or task sent to
# the orchestrator (--to orchestrator, or the orchestrator's id) is ALSO an
# ask: it is journaled under $SPOOL_ROOT/asks/<msg id>.json before this
# script returns and pushed to the hub (rdb 0097) in the background, so it
# stays OPEN until the acting orchestrator - or its successor on any machine -
# acks and closes it. Fire and forget: the sender never has to re-send.
# --ask <blocker|task|escalation> makes any send an ask; --no-ask (or
# SPOOL_ASKS=0) makes none; --ask-deadline <RFC 3339 UTC> sets when it is due.
#
# Usage:
#   spool-send.sh --from <ID> --to <ID|ID@box|orchestrator> --kind task|result|note|reject|blocker|msg
#                 [--task <uuid>] (--body <text> | --body-file <path>)
#                 [--file-ref <path>]... [--file-id <id>]... [--no-poke]
#                 [--ask <kind> | --no-ask] [--ask-deadline <ts>]
#   spool-send.sh --poke-only --to <ID> [--from <ID>]   # ring, send nothing
#
# stdout: spool's JSON result {delivery, msg_id, task_id, ts}, then one
# `poke:` status line.
#
# Exit codes:
#   0   delivered and shown in the pane (or --no-poke)
#   5   delivered; no live window carries <to> — it reads its inbox on its own
#       (a relay to another machine exits 0: that machine rings the pane)
#   6   delivered; REFUSED to poke: the pane holds unsent typed text
#   7   delivered; the pane runs only bare shells (the agent has exited)
#   2   usage error (nothing sent)
#   10+ `spool send` failed: 10 + its exit code (nothing delivered); 13 = <to>
#       is on neither this machine nor any box the hub knows (or no fleet desk)
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/spool-notify.inc.sh
. "$_here/../lib/spool-notify.inc.sh"
# shellcheck source=../lib/spool-poke-queue.inc.sh
. "$_here/../lib/spool-poke-queue.inc.sh"
# shellcheck source=../lib/spool-fleet.inc.sh
. "$_here/../lib/spool-fleet.inc.sh"
# shellcheck source=../lib/spool-asks.inc.sh
. "$_here/../lib/spool-asks.inc.sh"
spool_env_resolve

usage() {
  sed -n '/^# Usage:/,/^# stdout:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

FROM=""; TO=""; KIND=""; TASK=""; MSGID=""; BODY=""; BODY_SET=0; POKE=1; POKE_ONLY=0; RELAY=0
ASK_KIND=""; NO_ASK=0; ASK_DEADLINE=""
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
    --ask)       [ "$#" -ge 2 ] || usage; ASK_KIND="$2"; shift 2
                 case "$ASK_KIND" in blocker|task|escalation) ;; *) echo "ERROR: --ask must be blocker|task|escalation" >&2; exit 2 ;; esac ;;
    --no-ask)    NO_ASK=1; shift ;;
    --ask-deadline) [ "$#" -ge 2 ] || usage; ASK_DEADLINE="$2"; shift 2
                 [[ "$ASK_DEADLINE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { echo "ERROR: --ask-deadline must be RFC 3339 UTC, e.g. 2026-10-02T06:00:00Z" >&2; exit 2; } ;;
    --poke-only) POKE_ONLY=1; shift ;;
    -h|--help)   usage ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$TO" ] || { echo "ERROR: --to is required" >&2; usage; }
if [ "$TO" = orchestrator ]; then
  TO="$(spool_fleet_orchestrator)"
  echo "to: orchestrator = ${TO}" >&2
fi
TO_BOX=""
case "$TO" in
  *@*) TO_BOX="${TO##*@}"; TO="${TO%@*}"
       [[ "$TO_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "ERROR: bad box in --to: '${TO_BOX}'" >&2; exit 2; }
       [ "$TO_BOX" = "$(spool_fleet_box)" ] && TO_BOX="" ;;
esac
spool_valid_id "$TO" || exit 2
[ -z "$FROM" ] || spool_valid_id "$FROM" || exit 2

if [ "$POKE_ONLY" -eq 0 ]; then
  [ -n "$FROM" ] || { echo "ERROR: --from is required" >&2; usage; }
  case "$KIND" in task|result|note|reject|blocker|msg) ;; *) echo "ERROR: --kind must be task|result|note|reject|blocker|msg, got: '${KIND}'" >&2; exit 2 ;; esac
  [ "$BODY_SET" -eq 1 ] || { echo "ERROR: --body or --body-file is required" >&2; exit 2; }

  args=(send --from "$FROM" --to "$TO" --kind "$KIND" --body "$BODY")
  [ -n "$TASK" ] && args+=(--task "$TASK")
  args+=("${EXTRA[@]}")
  if [ -n "$TO_BOX" ] || ! spool_fleet_local "$TO"; then
    # specs/058 N1: not on this machine. Attachments are local paths/blobs this
    # machine holds, so a relay carries the body only.
    [ "${#EXTRA[@]}" -eq 0 ] || { echo "ERROR: ${TO} is on another machine; --file-*/--dir-* attachments do not cross machines (send a path in the body). Nothing was sent." >&2; exit 2; }
    rargs=(--from "$FROM" --to "$TO" --kind "$KIND" --body "$BODY")
    [ -n "$TASK" ] && rargs+=(--task "$TASK")
    [ -n "$TO_BOX" ] && rargs+=(--to-box "$TO_BOX")
    out="$(spool_fleet_relay "${rargs[@]}")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "ERROR: ${TO} is not an agent of this machine (${SPOOL_ROOT}) and the hub relay failed (rc=${rc}); nothing was delivered" >&2
      exit $((10 + rc))
    fi
    RELAY=1
  else
    # specs/028 FR-008: the binary's own notify hook is OFF for this send. This
    # script rings the pane itself, below, so it can report the outcome as its
    # exit code; letting both fire would show the message twice.
    out="$(SPOOL_ROOT="$SPOOL_ROOT" SPOOL_NOTIFY_CMD=off "$SPOOL_BIN" "${args[@]}")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "ERROR: '${SPOOL_BIN} send' failed (rc=${rc}); nothing was delivered" >&2
      exit $((10 + rc))
    fi
  fi
  printf '%s\n' "$out"
  TASK="$(printf '%s' "$out" | sed -n 's/.*"task_id" *: *"\([^"]*\)".*/\1/p')"
  MSGID="$(printf '%s' "$out" | sed -n 's/.*"msg_id" *: *"\([^"]*\)".*/\1/p')"
  DELIVERY="$(printf '%s' "$out" | sed -n 's/.*"delivery" *: *"\([^"]*\)".*/\1/p')"

  # ---- the NOTICE STRIP, both directions (lib/spool-poke-queue.inc.sh) -----
  #
  # The strip used to be INBOUND ONLY, and on THIS path it was not written at
  # all. Measured 2026-09-22 in the tests' own sandbox, n=1: one
  # `spool-send.sh --from CLE-90 --to CLE-91` left NEITHER agent with a
  # .pokes/notices.log. spool_poke_show is reached only through
  # scripts/spool-notify.sh, which the binary runs on delivery - and the send
  # above deliberately runs it with SPOOL_NOTIFY_CMD=off so this script can
  # ring the pane itself and report the outcome as its exit code. So a peer
  # message between two agents on one box rang a prompt and recorded nothing,
  # and the owner's "post and replies" column stayed empty.
  #
  # EXACTLY ONE writer per side, so nothing is painted twice:
  #   the SENDER's copy   - always; nothing else ever writes it
  #   the RECIPIENT's copy - only on a "local" delivery, which is precisely the
  #                          case where no notifier will run. A remote delivery
  #                          is logged by the RECEIVING box's own sidecar, on
  #                          its own log; writing it here as well would put the
  #                          message in two places and in one of them twice.
  #
  # This runs BEFORE the --no-poke check on purpose. --no-poke means "do not
  # type into the recipient's prompt"; the strip is the surface that injects
  # nothing and is the one the safe-poke rule deliberately does not gate, so
  # silencing it here would remove the record and keep none of the safety.
  _nb="$(spool_notify_shown_body "$BODY")"
  [ -n "$_nb" ] || _nb='(no body)'
  _nk="$(spool_notify_clean "$KIND")"; _nk="${_nk:-ping}"
  _nf="$(spool_notify_clean "$FROM")"; _nf="${_nf:-?}"
  spool_notice_record "$FROM" \
    "$(spool_notice_head_out "$TO" "$_nk" "$TASK" "$MSGID")" "$_nb" || true
  if [ "${DELIVERY:-}" = local ]; then
    spool_notice_record "$TO" \
      "$(spool_notice_head_in "$TO" "$_nk" "$_nf" "$TASK" "$MSGID")" "$_nb" || true
  fi

  # ---- the ask record (CLE-77929) -------------------------------------------
  # Journaled HERE, synchronously, so the ask exists on disk before this
  # script returns; the hub leg runs in the background and never delays or
  # fails the send. A missed hub leg is pushed by the next lease tick.
  _ak="$(spool_ask_wanted "$TO" "$KIND" "$ASK_KIND" "$NO_ASK")"
  if [ -n "$_ak" ] && [ -n "$MSGID" ] && [ "$FROM" != "$TO" ]; then
    _ato="$TO"; [ -n "$TO_BOX" ] && _ato="$TO@$TO_BOX"
    if spool_ask_journal_open "$MSGID" "$_ak" "$FROM@$(spool_fleet_box)" "$_ato" "$TASK" \
         "$(spool_ask_summary "$BODY")" "$ASK_DEADLINE"; then
      echo "ask: open ${MSGID:0:8} ($_ak) - tracked until the orchestrator closes it" >&2
      if [ -n "${SPOOL_ASKS_SYNC_CMD:-}" ]; then
        # shellcheck disable=SC2086 # a command line, split on purpose
        $SPOOL_ASKS_SYNC_CMD "$MSGID" >/dev/null 2>&1 || true
      elif [ "${SPOOL_TEST:-0}" != 1 ]; then
        ( timeout 90 bash "$_here/asks.sh" sync >>"$(spool_asks_dir)/sync.log" 2>&1 & ) 2>/dev/null
      fi
    else
      echo "ask: WARN ${MSGID:0:8} was delivered but not journaled as an ask" >&2
    fi
  fi
fi

if [ "$POKE_ONLY" -eq 0 ] && [ "$RELAY" -eq 1 ]; then
  echo "poke: remote (${TO} is on another machine; its sidecar rings the pane there)"
  exit 0
fi
[ "$POKE" -eq 1 ] || { echo "poke: skipped (--no-poke); ${TO} finds it on its next 'spool recv'"; exit 0; }

# ---- the pane leg (lib/spool-notify.inc.sh, contracts/poke-line.md) --------
spool_notify "$TO" "$KIND" "$FROM" "$TASK" "$MSGID" "$BODY"
exit $?
