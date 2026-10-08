#!/usr/bin/env bash
# asks.sh — the asks to the orchestrator from anywhere (CLE-77929, owner bug
# t1 #spool-hub-bugs 2f7996aa; SPEC-spool-fleet-roles.md 4.3). A thin front
# for the orc actions do_spl_asks_open / do_spl_ask_ack / do_spl_ask_close /
# do_spl_orch_inbox / do_spl_asks_sync / do_spl_asks_tick, so an agent pane
# names one command.
#
# Usage:
#   asks.sh [open] [--all] [--json]          the open asks, oldest first
#   asks.sh ack <id> [--by <ID>@<box>] [--gen <n>]   in progress, mine
#   asks.sh done <id> [--reason <text>] [--gen <n>]  closed
#   asks.sh decline <id> --reason <text>     closed, not done
#   asks.sh inbox [--archive]                the orchestrator's view: asks, untracked, FYI
#   asks.sh sync                             push this machine's journal to the hub
#   asks.sh tick                             the lease loop's timer, by hand
#
# <id> is the ask id or its first 8 hex digits. The action runs as
# $SPOOL_BOX_USER (the desk keys that sign the hub call are theirs). Exit
# codes: the action's own (0 ok, 1 refused, 3 already closed); 64 usage.
#
# Peers (spec 068 L4): with a seat in $SPOOL_ROOT/peer/seats (SPOOL_TO_PEERS
# =1|0 forces it) the lock of an ask is its message's, not the book's:
#   ack     = the fence, `spool claim --check`: 0 mine, 1 lost (another seat
#             is responsible), 2 the hub cannot say
#   done    = `spool claim --done <msg> --how answered`, then the book closes
#   decline = `spool claim --done <msg> --how no-reply:<reason>`, then the book
# The claim runs first: a seat that is not responsible is refused (exit 1)
# and the book is not touched. The seat is --by, else $SPOOL_AGENT_ID@<box>;
# the gen is --gen, else the responsible_gen of the copy in the seat's inbox
# or archive (the poll loop writes it), which also resolves an 8-hex id.
#
# ASKS_ORC (tests): the csi-spl-orc dir whose ./run is called.
# ASKS_CLAIM_CMD (tests): replaces `spool claim`.
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/spool-fleet.inc.sh
. "$_here/../lib/spool-fleet.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

usage() { sed -n '9,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }

# 0 when the lock of an ask is its message's (the send side's switch).
asks_peers_on() {
  case "${SPOOL_TO_PEERS:-}" in 1) return 0 ;; 0) return 1 ;; esac
  [ -r "$SPOOL_ROOT/peer/seats" ] &&
    sed 's/#.*//' "$SPOOL_ROOT/peer/seats" | awk '$1 ~ /^[acgmq]-[0-9][0-9][0-9]$/ && $2 ~ /^[a-z]+$/ { f = 1 } END { exit !f }'
}

# "<msg_id> <gen>" of the newest copy of <id> (full or 8-hex prefix) the
# seat <ID> holds in its inbox or archive; nothing when it has none.
asks_peer_msg() {  # ID MSG
  find "$SPOOL_ROOT/$1/inbox" "$SPOOL_ROOT/$1/archive" -maxdepth 1 -name '*.json' -print0 2>/dev/null |
    xargs -0r jq -r --arg m "$2" 'select((.msg_id // "") | startswith($m)) | "\(.ts)\t\(.msg_id) \(.responsible_gen // 0)"' 2>/dev/null |
    sort | tail -1 | cut -f2
}

asks_claim() {
  if [ -n "${ASKS_CLAIM_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $ASKS_CLAIM_CMD claim "$@"; return
  fi
  [ -n "${SPOOL_BIN:-}" ] || spool_env_resolve >/dev/null 2>&1 || return 90
  timeout "${ASKS_CLAIM_TIMEOUT:-15}" "$SPOOL_BIN" claim "$@"
}

# The message leg of ack|done|decline in peers mode. Returns the exit code
# asks.sh ends with for ack; for done|decline 0 lets the book close follow.
asks_peer_lock() {  # VERB ID BY GEN REASON
  local verb="$1" id="$2" by="$3" gen="$4" reason="$5" seat hit rc=0
  [ -n "$by" ] || by="${SPOOL_AGENT_ID:-}"
  case "$by" in *@*) ;; '') ;; *) by="$by@$(spool_fleet_box)" ;; esac
  seat="${by%@*}"
  [[ "$seat" =~ ^[acgmq]-[0-9]{3}$ ]] || { echo "asks.sh: peers mode: $verb needs the seat (--by <ID>@<box> or SPOOL_AGENT_ID), got '${by}'" >&2; return 64; }
  hit="$(asks_peer_msg "$seat" "$id")"
  [ -n "$hit" ] && id="${hit% *}" && [ -z "$gen" ] && gen="${hit#* }"
  [[ "$id" =~ ^[A-Za-z0-9-]{9,}$ ]] || { echo "asks.sh: $id is in none of ${seat}'s messages; give the full msg id" >&2; return 1; }
  ASK_MSG="$id" ASK_SEAT="$by"
  case "$verb" in
    ack)
      asks_claim --check --seat "$by" --msg "$id" --gen "${gen:-0}" >/dev/null 2>&1 || rc=$?
      case "$rc" in
        0) echo "ask ${id:0:8}: mine (${by}, gen ${gen:-0}) - the message's lock" ;;
        1) echo "asks.sh: ${id:0:8} is not ${by}'s: another seat is responsible (lost the lock)" >&2 ;;
        *) echo "asks.sh: ${id:0:8}: the hub cannot confirm ${by}'s lock (exit $rc): do not act" >&2; rc=2 ;;
      esac
      return "$rc" ;;
    done|decline)
      local how=answered out
      [ "$verb" = decline ] && { [ -n "$reason" ] || { echo "asks.sh: decline needs --reason" >&2; return 1; }; how="no-reply:$reason"; }
      local -a a=(--done "$id" --seat "$by" --how "$how")
      [ -n "$gen" ] && a+=(--gen "$gen")
      out="$(asks_claim "${a[@]}" 2>&1)" || { echo "asks.sh: ${id:0:8}: the close was refused: ${out}" >&2; return 1; }
      echo "message ${id:0:8} closed ($how) by ${by}"
      return 0 ;;
  esac
}

verb=open
case "${1:-}" in open|ack|done|decline|inbox|sync|tick) verb="$1"; shift ;; -h|--help) usage ;; esac
vars=()
ID="" BY="" GEN="" REASON=""
case "$verb" in
  ack|done|decline)
    [ -n "${1:-}" ] && [ "${1#-}" = "$1" ] || { echo "asks.sh: $verb needs the ask id" >&2; usage; }
    ID="$1"; shift ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --all)     vars+=("ASKS_ALL=1"); shift ;;
    --json)    vars+=("ASKS_FORMAT=json"); shift ;;
    --by)      BY="${2:-}"; vars+=("ASK_BY=${2:-}"); shift 2 ;;
    --reason)  REASON="${2:-}"; vars+=("ASK_REASON=${2:-}"); shift 2 ;;
    --gen)     [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "asks.sh: --gen needs a number" >&2; usage; }
               GEN="$2"; shift 2 ;;
    --archive) vars+=("ORCH_INBOX_ARCHIVE=1"); shift ;;
    *) echo "asks.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
if [ -n "$ID" ] && asks_peers_on; then
  ASK_MSG="$ID"
  asks_peer_lock "$verb" "$ID" "$BY" "$GEN" "$REASON"; rc=$?
  [ "$verb" = ack ] || [ "$rc" -ne 0 ] && exit "$rc"
  # the book keeps its fields: close the ask, if this message is one
  [ -f "${SPOOL_ASKS_DIR:-$SPOOL_ROOT/asks}/$ASK_MSG.json" ] || exit 0
  ID="$ASK_MSG"; vars+=("ASK_BY=$ASK_SEAT")
fi
[ -z "$ID" ] || vars+=("ASK_ID=$ID")
case "$verb" in
  open)    action=do_spl_asks_open ;;
  ack)     action=do_spl_ask_ack ;;
  done)    action=do_spl_ask_close; vars+=("ASK_STATE=done") ;;
  decline) action=do_spl_ask_close; vars+=("ASK_STATE=declined") ;;
  inbox)   action=do_spl_orch_inbox ;;
  sync)    action=do_spl_asks_sync ;;
  tick)    action=do_spl_asks_tick ;;
esac

orc="${ASKS_ORC:-$(cd "$_here/../../../../.." && pwd)}"
[ -x "$orc/run" ] || { echo "asks.sh: no orc ./run at $orc" >&2; exit 1; }
# The caller's settings, passed through the user hop.
for k in ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD ORCH_ID SPOOL_AGENT_ID SPOOL_DESK_BOX SPOOL_BOX_ENV; do
  [ -n "${!k:-}" ] && vars+=("$k=${!k}")
done
vars+=("SPOOL_ROOT=$SPOOL_ROOT")
if [ "$(id -un)" != "$SPOOL_BOX_USER" ] && [ -z "${ASKS_ORC:-}" ]; then
  home="$(getent passwd "$SPOOL_BOX_USER" | cut -d: -f6)"
  cd "$orc" && exec sudo -n -u "$SPOOL_BOX_USER" env HOME="$home" "${vars[@]}" ./run -a "$action"
fi
cd "$orc" && exec env "${vars[@]}" ./run -a "$action"
