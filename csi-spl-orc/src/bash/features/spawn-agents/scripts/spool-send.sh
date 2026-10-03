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
# Peers (spec 068 4.1, lane L4), behind a switch that is OFF until this
# machine has a seat: with a seat line in $SPOOL_ROOT/peer/seats (L3's gate,
# written by L7; SPOOL_TO_PEERS=1|0 forces it) `--to orchestrator` (and
# `--to peers`) is ONE message to the peers: handed to the hub as
# `to: peers`, where exactly one seat claims it (`spool claim --poll`). Hub
# or desk unreachable: it is written once into $SPOOL_ROOT/peers/inbox/,
# where the seats of this machine take it by the local lock (L3). No pane is
# rung: the seats' poll loop rings its own. Without a seat nothing changes.
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
#   spool-send.sh --from <ID> --to <ID|ID@box|orchestrator|peers> --kind task|result|note|reject|blocker|msg
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
#   3   refused (nothing sent): --kind task to a lane of this machine that
#       already owns another topic (its first task's task_id since spawn);
#       spawn a new lane. SPOOL_SECOND_TOPIC_OK=1 overrides, logged to
#       $SPOOL_ROOT/second-topic.log. Role seats (001-003, lease.conf) take
#       any topic. A body over 1200 chars only WARNs on stderr: send a path.
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

SEND_BODY_WARN=1200

# A role seat (001-003, or an id lease.conf names) takes every topic by design.
send_role_seat() {  # ID
  [[ "$1" =~ ^[A-Za-z]+-00[1-3]$ ]] && return 0
  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null
}

# The topic a live lane of this machine owns: the task_id of the first task it
# received since its registry row was written (a reused id starts clean).
# Read from the lane's own inbox + archive, not from the hub lane map: that is
# a ~15 s signed hub call per send, and its topic column was empty in 186 of
# 186 live rows on 2026-10-03. Prints nothing for a role seat, an id with no
# registry row, or a lane that has no task yet.
send_lane_topic() {  # ID
  local id="$1" since
  send_role_seat "$id" && return 0
  since="$(awk -F'\t' -v id="$id" '$1 == id { s = $5 } END { print s }' "$SPOOL_ROOT/registry.tsv" 2>/dev/null)"
  [[ "$since" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] || return 0
  since="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}T${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}Z"
  find "$SPOOL_ROOT/$id/inbox" "$SPOOL_ROOT/$id/archive" -maxdepth 1 -name '*.json' -print0 2>/dev/null |
    xargs -0r jq -r --arg s "$since" 'select(.kind == "task" and .ts >= $s and (.task_id // "") != "") | "\(.ts)\t\(.task_id)"' 2>/dev/null |
    sort | head -1 | cut -f2
}

# 0 when reports go to the peers (spec 068 L4): SPOOL_TO_PEERS=1|0, else a
# seat line in <root>/peer/seats, parsed as do_spl_peer_poll parses it.
send_to_peers_on() {
  case "${SPOOL_TO_PEERS:-}" in 1) return 0 ;; 0) return 1 ;; esac
  [ -r "$SPOOL_ROOT/peer/seats" ] &&
    sed 's/#.*//' "$SPOOL_ROOT/peer/seats" | awk '$1 ~ /^[acgq]-[0-9][0-9][0-9]$/ && $2 ~ /^[a-z]+$/ { f = 1 } END { exit !f }'
}

# The hub-down leg of a peers send: ONE v:1 object in <root>/peers/inbox (the
# seats' local lock reads it) and the sender's outbox copy; prints spool's
# result shape with delivery "peers-local".
send_peers_local() {
  local id task ts f
  id="$(cat /proc/sys/kernel/random/uuid)"; task="${TASK:-$(cat /proc/sys/kernel/random/uuid)}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  f="$(date -u +%Y%m%dT%H%M%SZ)--${FROM}--${id:0:8}.json"
  mkdir -p "$SPOOL_ROOT/peers/inbox" "$SPOOL_ROOT/$FROM/outbox" || return 1
  jq -n -c --arg id "$id" --arg t "$task" --arg ts "$ts" --arg f "$FROM" --arg k "$KIND" --arg b "$BODY" \
    '{v: 1, msg_id: $id, task_id: $t, ts: $ts, from: $f, to: "peers", kind: $k, body: $b, files: []}' \
    >"$SPOOL_ROOT/peers/inbox/.$f.tmp" || return 1
  cp "$SPOOL_ROOT/peers/inbox/.$f.tmp" "$SPOOL_ROOT/$FROM/outbox/$f" 2>/dev/null || true
  mv -f "$SPOOL_ROOT/peers/inbox/.$f.tmp" "$SPOOL_ROOT/peers/inbox/$f" || return 1
  printf '{"delivery":"peers-local","msg_id":"%s","task_id":"%s","ts":"%s"}\n' "$id" "$task" "$ts"
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
PEERS=0
if [ "$TO" = orchestrator ] || [ "$TO" = peers ]; then
  if send_to_peers_on; then
    PEERS=1
    [ "$TO" = orchestrator ] && echo "to: orchestrator = peers (a seat in ${SPOOL_ROOT}/peer/seats)" >&2
    TO=peers
  elif [ "$TO" = peers ]; then
    echo "ERROR: --to peers needs a seat in ${SPOOL_ROOT}/peer/seats (spec 068); none here. Nothing was sent." >&2; exit 2
  else
    TO="$(spool_fleet_orchestrator)"
    echo "to: orchestrator = ${TO}" >&2
  fi
fi
[ "$PEERS" -eq 0 ] || [ "$POKE_ONLY" -eq 0 ] || { echo "ERROR: --poke-only rings one agent, not the peers" >&2; exit 2; }
TO_BOX=""
case "$TO" in
  *@*) TO_BOX="${TO##*@}"; TO="${TO%@*}"
       [[ "$TO_BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "ERROR: bad box in --to: '${TO_BOX}'" >&2; exit 2; }
       [ "$TO_BOX" = "$(spool_fleet_box)" ] && TO_BOX="" ;;
esac
[ "$PEERS" -eq 1 ] || spool_valid_id "$TO" || exit 2
[ -z "$FROM" ] || spool_valid_id "$FROM" || exit 2

if [ "$POKE_ONLY" -eq 0 ]; then
  [ -n "$FROM" ] || { echo "ERROR: --from is required" >&2; usage; }
  case "$KIND" in task|result|note|reject|blocker|msg) ;; *) echo "ERROR: --kind must be task|result|note|reject|blocker|msg, got: '${KIND}'" >&2; exit 2 ;; esac
  [ "$BODY_SET" -eq 1 ] || { echo "ERROR: --body or --body-file is required" >&2; exit 2; }

  # ---- one topic per lane (token/focus practice 08) -------------------------
  # A task on a second topic makes one lane carry two contexts: it re-reads
  # both, and neither closes. Measured 2026-10-03 on the spool archive, n=35
  # worker lanes that got a task in 24 h: 8 got a second task topic.
  if [ "$KIND" = task ] && [ "$FROM" != "$TO" ] && [ -z "$TO_BOX" ] && [ "$PEERS" -eq 0 ]; then
    _lt="$(send_lane_topic "$TO")"
    if [ -n "$_lt" ] && [ "$_lt" != "$TASK" ]; then
      if [ "${SPOOL_SECOND_TOPIC_OK:-0}" = 1 ]; then
        echo "topic: WARN SPOOL_SECOND_TOPIC_OK=1: ${FROM} gives ${TO} a second topic (${TASK:-new}) beside ${_lt}" >&2
        printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FROM" "$TO" "$_lt" "${TASK:-new}" \
          >>"$SPOOL_ROOT/second-topic.log" 2>/dev/null || true
      else
        echo "ERROR: ${TO}: that lane owns topic ${_lt}; spawn a new lane (or send on --task ${_lt}; SPOOL_SECOND_TOPIC_OK=1 overrides, logged). Nothing was sent." >&2
        exit 3
      fi
    fi
  fi
  if [ "${#BODY}" -gt "$SEND_BODY_WARN" ]; then
    echo "body: WARN ${#BODY} chars > ${SEND_BODY_WARN}: put the detail in a file and send the path" >&2
  fi

  args=(send --from "$FROM" --to "$TO" --kind "$KIND" --body "$BODY")
  [ -n "$TASK" ] && args+=(--task "$TASK")
  args+=("${EXTRA[@]}")
  # specs/061 3.6: an id this machine retired inside its quarantine is not
  # relayed (the hub could hand it to another machine's holder of the same
  # number): the binary bounces it, a reject into the sender's inbox, exit 4.
  if [ "$PEERS" -eq 1 ]; then
    # spec 068 L4: one message to the peers, never a copy per seat. The hub
    # leg first (to: peers, claimed by exactly one seat of any machine); the
    # local peers inbox only when the hub leg fails, so no message is ever
    # both on the hub and in the local lock.
    [ "${#EXTRA[@]}" -eq 0 ] || { echo "ERROR: a message to the peers carries no --file-*/--dir-* attachment (send a path in the body). Nothing was sent." >&2; exit 2; }
    rargs=(--from "$FROM" --to peers --kind "$KIND" --body "$BODY")
    [ -n "$TASK" ] && rargs+=(--task "$TASK")
    if out="$(spool_fleet_relay "${rargs[@]}")"; then
      RELAY=1
    else
      rc=$?
      echo "peers: the hub leg failed (rc=${rc}); written to ${SPOOL_ROOT}/peers/inbox for this machine's seats (local lock)" >&2
      out="$(send_peers_local)" || { echo "ERROR: cannot write ${SPOOL_ROOT}/peers/inbox; nothing was delivered" >&2; exit 11; }
    fi
  elif [ -n "$TO_BOX" ] || { ! spool_fleet_local "$TO" && ! spool_fleet_retired "$TO"; }; then
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
    if [ "$rc" -eq 4 ]; then
      echo "ERROR: ${TO} was retired on this machine less than ${SPOOL_ID_QUARANTINE_H:-24} h ago; nothing was delivered, a reject is in ${FROM}'s inbox" >&2
      exit 14
    fi
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
  # Peers (spec 068 L4): a blocker or task to the peers is an ask too; the
  # book keeps its fields, the lock is the message's (asks.sh ack|done).
  _af="$ASK_KIND"
  [ "$PEERS" -eq 1 ] && [ -z "$_af" ] && case "$KIND" in blocker|task) _af="$KIND" ;; esac
  _ak="$(spool_ask_wanted "$TO" "$KIND" "$_af" "$NO_ASK")"
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

if [ "$PEERS" -eq 1 ]; then
  echo "poke: peers (the seat that claims it is rung by its poll loop)"
  exit 0
fi
if [ "$POKE_ONLY" -eq 0 ] && [ "$RELAY" -eq 1 ]; then
  echo "poke: remote (${TO} is on another machine; its sidecar rings the pane there)"
  exit 0
fi
[ "$POKE" -eq 1 ] || { echo "poke: skipped (--no-poke); ${TO} finds it on its next 'spool recv'"; exit 0; }

# ---- the pane leg (lib/spool-notify.inc.sh, contracts/poke-line.md) --------
spool_notify "$TO" "$KIND" "$FROM" "$TASK" "$MSGID" "$BODY"
exit $?
