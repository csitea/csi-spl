#!/usr/bin/env bash
# spool-fleet-relay.sh — the box side of a send to an agent on ANOTHER machine
# of the fleet (specs/058 N1). spool-send.sh calls it, as the box user, when
# --to is not an agent of this machine's $SPOOL_ROOT.
#
#   spool-fleet-relay.sh [--spool-root <dir>] --from <ID> --to <ID> --kind <k>
#                        --body <text> [--task <uuid>] [--to-box <box>]
#
# It signs the message with THIS machine's desk box and hands it to the hub
# through that desk's live `spool hub-run` sidecar (its warm socket, the same
# settings spool-mcp.sh reads from /proc/<pid>/environ). The hub's roster says
# which box holds --to; that box's sidecar writes the message into the agent's
# desk inbox AND, through SPOOL_FLEET_ROOT, into the inbox the agent reads with
# `spool recv` on its own machine (internal/spool bridgeFleet), and rings it.
#
# The fleet desk, first match wins:
#   env     SPOOL_FLEET_ENV, box.env SPOOL_FLEET_ENV, lease.conf LEASE_ENV
#   tenant  SPOOL_FLEET_TENANT, box.env SPOOL_FLEET_TENANT, lease.conf LEASE_TENANT
#   box     SPOOL_DESK_BOX, box.env SPOOL_DESK_BOX, lease.conf LEASE_DESK_BOX, box-desk
#   state   SPOOL_FLEET_STATE_ROOT, else <box user home>/.local/share/csi-spl/cloud
# The desk is <state>/<env>/desk/<tenant>/<box>.
#
# stdout: the `spool send` JSON ({delivery: sent|queued|pending, ...}).
# A sender not seated on the desk but listed in this machine's registry.tsv
# (a lane agent) is sent under a seated id of the desk; every relayed body
# opens with "from_agent: <ID>@<box>", which the receiving box writes as from.
#
# Exit codes: 0 handed to the hub; 2 usage; 3 refused, nothing sent (no fleet
# desk configured, no live sidecar, the sender is neither seated on the desk
# nor in registry.tsv, or the hub knows no box for --to); 1 the send failed.
set -uo pipefail

say() { echo "spool-fleet-relay: $*" >&2; }
# shellcheck source=../lib/spool-env.inc.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/spool-env.inc.sh"

ROOT="${SPOOL_ROOT:-/var/spool-hub}" FROM="" TO="" KIND="" BODY="" TASK="" TOBOX="" BODY_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spool-root) [ "$#" -ge 2 ] || exit 2; ROOT="$2"; shift 2 ;;
    --from) [ "$#" -ge 2 ] || exit 2; FROM="$2"; shift 2 ;;
    --to)   [ "$#" -ge 2 ] || exit 2; TO="$2"; shift 2 ;;
    --kind) [ "$#" -ge 2 ] || exit 2; KIND="$2"; shift 2 ;;
    --body) [ "$#" -ge 2 ] || exit 2; BODY="$2"; BODY_SET=1; shift 2 ;;
    --task) [ "$#" -ge 2 ] || exit 2; TASK="$2"; shift 2 ;;
    --to-box) [ "$#" -ge 2 ] || exit 2; TOBOX="$2"; shift 2 ;;
    *) say "unknown argument: $1"; exit 2 ;;
  esac
done
spl_is_participant_id "$FROM" && spl_is_participant_id "$TO" && [[ -n "$KIND" && "$BODY_SET" = 1 ]] ||
  { say "usage: --from <ID> --to <ID> --kind <k> --body <text> [--task <uuid>]"; exit 2; }
[[ -z "$TOBOX" || "$TOBOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "bad --to-box '$TOBOX'"; exit 2; }

# KEY from a KEY=value file (read, never sourced: these files sit in dirs the
# agents may write).
kv() {  # FILE KEY
  [ -r "$1" ] || return 0
  sed -n "s/^$2=[\"']\{0,1\}\([A-Za-z0-9_-]*\)[\"']\{0,1\}\$/\1/p" "$1" | tail -1
}
BOXENV="${SPOOL_BOX_ENV:-$ROOT/box.env}" LCONF="$ROOT/dispatch/lease.conf"
ENVN="${SPOOL_FLEET_ENV:-$(kv "$BOXENV" SPOOL_FLEET_ENV)}"; ENVN="${ENVN:-$(kv "$LCONF" LEASE_ENV)}"
TENANT="${SPOOL_FLEET_TENANT:-$(kv "$BOXENV" SPOOL_FLEET_TENANT)}"; TENANT="${TENANT:-$(kv "$LCONF" LEASE_TENANT)}"
BOX="${SPOOL_DESK_BOX:-$(kv "$BOXENV" SPOOL_DESK_BOX)}"; BOX="${BOX:-$(kv "$LCONF" LEASE_DESK_BOX)}"; BOX="${BOX:-box-desk}"
[[ "$ENVN" =~ ^(dev|prd|self)$ && "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
  say "$TO is not an agent of this machine ($ROOT), and no fleet desk is configured to reach the other machine: set SPOOL_FLEET_ENV + SPOOL_FLEET_TENANT in $BOXENV (or LEASE_ENV + LEASE_TENANT in $LCONF). Nothing was sent."
  exit 3; }
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui ]] || { say "bad desk box '$BOX'"; exit 3; }
STATE="${SPOOL_FLEET_STATE_ROOT:-$(getent passwd "$(id -un)" | cut -d: -f6)/.local/share/csi-spl/cloud}"
d="$STATE/$ENVN/desk/$TENANT/$BOX"

pid="$(cat "$d/spool/.hub/hub-run.pid" 2>/dev/null)"
[[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' <"${SPOOL_FLEET_PROC_ROOT:-/proc}/$pid/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null || {
  say "no live hub-run sidecar for $BOX in $TENANT ($ENVN, $d): the message to $TO cannot leave this machine. Run do_spl_desk_up. Nothing was sent."
  exit 3; }
# The box is the trust unit, not the seat (HOWTO-satellite-work §4 gaps 1-3):
# a lane agent is never seated on the desk, and the hub refuses a sender the
# box does not announce. A sender in THIS machine's registry.tsv is relayed
# under a seated id of the box (the proxy) instead; an id the registry does
# not list either is refused.
SENDER="$FROM"
if [ ! -d "$d/spool/$FROM" ]; then
  awk -F'\t' -v id="$FROM" '$1 == id || index($1, id "@") == 1 { f = 1 } END { exit !f }' "$ROOT/registry.tsv" 2>/dev/null || {
    say "$FROM is neither seated on $BOX in $TENANT ($ENVN) nor in this machine's $ROOT/registry.tsv: the hub refuses a sender its box does not vouch for. Nothing was sent."
    exit 3; }
  SENDER=""
  for p in "${SPOOL_FLEET_PROXY:-$(kv "$BOXENV" SPOOL_FLEET_PROXY)}" "$(kv "$LCONF" LEASE_ORCH)" \
           "$d"/spool/*; do
    p="${p##*/}"
    spl_is_participant_id "$p" && [ -d "$d/spool/$p" ] && { SENDER="$p"; break; }
  done
  [ -n "$SENDER" ] || { say "no agent is seated on $BOX in $TENANT ($ENVN) to relay for $FROM. Nothing was sent."; exit 3; }
fi
declare -a envv=()
SIDEBOX=""
while IFS= read -r -d '' e; do
  case "${e%%=*}" in
    SPOOL_ROOT|SPOOL_KEYS_DIR|SPOOL_PINS_DIR|SPOOL_BOX_ID|SPOOL_HUB_URL|SPOOL_TENANT|SPOOL_MSG_VERSION|SPOOL_SUBMIT_SOCKET) envv+=("$e") ;;
  esac
  [ "${e%%=*}" = SPOOL_BOX_ID ] && SIDEBOX="${e#*=}"
done <"${SPOOL_FLEET_PROC_ROOT:-/proc}/$pid/environ"
[ "${#envv[@]}" -ge 5 ] || { say "cannot read the sidecar's settings (pid $pid)"; exit 3; }
# The real sender and its box ride as the first body line; the receiving box
# writes them as `from` (internal/spool WithFromAgent), bound to the box whose
# pin signs this envelope - the sidecar's SPOOL_BOX_ID.
BODY="from_agent: $FROM@${SIDEBOX:-$BOX}"$'\n'"$BODY"

# The desk actions build <state>/<env>/bin/spool for these sidecars; else the
# harness binary.
BIN="${SPOOL_FLEET_BIN:-$STATE/$ENVN/bin/spool}"
[ -x "$BIN" ] || BIN="${SPOOL_BIN:-spool}"
args=(send --from "$SENDER" --to "$TO" --kind "$KIND" --body "$BODY")
# The hub keys a topic on a uuid; a local task name ("dispatch-lease",
# "dispatch-gaps") made Postgres refuse the insert, the hub answered
# "internal (message not stored)", and the sidecar retried it for ever
# (2026-10-02, prd hub log). A name maps to ONE uuid (v5), so a topic stays one.
if [ -n "$TASK" ] && ! [[ "$TASK" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
  TASK="$(python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool-task:" + sys.argv[1]))' "$TASK")" ||
    { say "cannot map task '$TASK' to a uuid"; exit 2; }
fi
[ -n "$TASK" ] && args+=(--task "$TASK")
[ -n "$TOBOX" ] && args+=(--to-box "$TOBOX")
out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin USER="$(id -un)" SPOOL_LOG_LEVEL=error \
  SPOOL_NOTIFY_CMD=off "${envv[@]}" "$BIN" "${args[@]}" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  case "$out" in
    *"cannot resolve to_box"*|*ambiguous_to_box*|*unknown_agent*)
      say "the hub roster names no single box for $TO (not on this machine, not announced by another): $out. Nothing was sent."
      exit 3 ;;
  esac
  say "send via $BOX failed (rc=$rc): $out"
  exit 1
fi
printf '%s\n' "$out"
