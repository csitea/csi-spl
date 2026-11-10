#!/usr/bin/env bash
# spool-fleet-relay.sh — the box side of a send to an agent on ANOTHER machine
# of the fleet (specs/058 N1). spool-send.sh calls it, as the box user, when
# --to is not an agent of this machine's $SPOOL_ROOT.
#
#   spool-fleet-relay.sh [--spool-root <dir>] --from <ID> --to <ID> --kind <k>
#                        --body <text> [--task <uuid>] [--to-box <box>]
#                        [--accept <msg_id>] [--to-this-box]
#                        [--tenant <workspace>]
#
# --accept sets the v:1 key `accepts` (spec 130 section 4). --to-this-box
# sends to an agent of THIS machine through the hub, to the sidecar's own box
# (its SPOOL_BOX_ID): spool-send.sh uses it for an acceptance, which fires
# `ready` only when the hub stores the line. --tenant names the workspace of
# this one send, ahead of every source below (SPL-4880: the box link watcher
# keeps a topic's alert in that topic's workspace; sudo resets the
# environment, so SPOOL_FLEET_TENANT cannot carry it). Unset: unchanged.
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
#   tenant  --tenant, SPOOL_FLEET_TENANT, box.env SPOOL_FLEET_TENANT, lease.conf LEASE_TENANT
#   box     SPOOL_DESK_BOX, box.env SPOOL_DESK_BOX, lease.conf LEASE_DESK_BOX, box-desk
#   state   SPOOL_FLEET_STATE_ROOT, else spool_desk_root: the desk user's
#           (SPOOL_DESK_USER) state root, else this user's
# The desk is <state>/<env>/desk/<tenant>/<box>.
# A desk that MOVED to another user (do_spl_desk_move, spec 069 section 8.4;
# spl_desk_moved_to: that user's copy is pinned, this one is not and has no
# live sidecar) is reached by ONE hop: the relay re-runs as that user
# (SPL_DESK_AS_CMD, default `sudo -n -u`) with SPOOL_DESK_USER set. Why
# (SPL-5246): the move writes SPOOL_DESK_USER to box.env only once every desk
# moved, so on a half-moved box a box-user caller (the placer cron, via
# spool-send.sh) read its own stub and refused every cross-box send, rc 3.
# No hop with SPOOL_FLEET_STATE_ROOT set, after one hop (SPL_DESK_HOPPED), or
# under SPOOL_TEST=1 without SPL_DESK_AS_CMD.
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
# shellcheck source=../lib/desk-root.inc.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/../lib/desk-root.inc.sh"

ARGV=("$@")
ROOT="${SPOOL_ROOT:-/var/spool-hub}" FROM="" TO="" KIND="" BODY="" TASK="" TOBOX="" BODY_SET=0 ACCEPT="" THISBOX=0 ARG_TENANT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spool-root) [ "$#" -ge 2 ] || exit 2; ROOT="$2"; shift 2 ;;
    --from) [ "$#" -ge 2 ] || exit 2; FROM="$2"; shift 2 ;;
    --to)   [ "$#" -ge 2 ] || exit 2; TO="$2"; shift 2 ;;
    --kind) [ "$#" -ge 2 ] || exit 2; KIND="$2"; shift 2 ;;
    --body) [ "$#" -ge 2 ] || exit 2; BODY="$2"; BODY_SET=1; shift 2 ;;
    --task) [ "$#" -ge 2 ] || exit 2; TASK="$2"; shift 2 ;;
    --to-box) [ "$#" -ge 2 ] || exit 2; TOBOX="$2"; shift 2 ;;
    --accept) [ "$#" -ge 2 ] || exit 2; ACCEPT="$2"; shift 2 ;;
    --to-this-box) THISBOX=1; shift ;;
    --tenant) [ "$#" -ge 2 ] || exit 2; ARG_TENANT="$2"; shift 2 ;;
    *) say "unknown argument: $1"; exit 2 ;;
  esac
done
spl_is_participant_id "$FROM" && spl_is_participant_id "$TO" && [[ -n "$KIND" && "$BODY_SET" = 1 ]] ||
  { say "usage: --from <ID> --to <ID> --kind <k> --body <text> [--task <uuid>]"; exit 2; }
[[ -z "$TOBOX" || "$TOBOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "bad --to-box '$TOBOX'"; exit 2; }
[[ -z "$ACCEPT" || "$ACCEPT" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { say "bad --accept '$ACCEPT'"; exit 2; }
[[ "$THISBOX" = 0 || -z "$TOBOX" ]] || { say "--to-this-box and --to-box name two boxes"; exit 2; }

# KEY from a KEY=value file (read, never sourced: these files sit in dirs the
# agents may write).
kv() {  # FILE KEY
  [ -r "$1" ] || return 0
  sed -n "s/^$2=[\"']\{0,1\}\([A-Za-z0-9_-]*\)[\"']\{0,1\}\$/\1/p" "$1" | tail -1
}
BOXENV="${SPOOL_BOX_ENV:-$ROOT/box.env}" LCONF="$ROOT/dispatch/lease.conf"
ENVN="${SPOOL_FLEET_ENV:-$(kv "$BOXENV" SPOOL_FLEET_ENV)}"; ENVN="${ENVN:-$(kv "$LCONF" LEASE_ENV)}"
[[ -z "$ARG_TENANT" || "$ARG_TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "bad --tenant '$ARG_TENANT'"; exit 2; }
TENANT="${ARG_TENANT:-${SPOOL_FLEET_TENANT:-$(kv "$BOXENV" SPOOL_FLEET_TENANT)}}"; TENANT="${TENANT:-$(kv "$LCONF" LEASE_TENANT)}"
BOX="${SPOOL_DESK_BOX:-$(kv "$BOXENV" SPOOL_DESK_BOX)}"; BOX="${BOX:-$(kv "$LCONF" LEASE_DESK_BOX)}"; BOX="${BOX:-box-desk}"
[[ "$ENVN" =~ ^(dev|prd|self)$ && "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
  say "$TO is not an agent of this machine ($ROOT), and no fleet desk is configured to reach the other machine: set SPOOL_FLEET_ENV + SPOOL_FLEET_TENANT in $BOXENV (or LEASE_ENV + LEASE_TENANT in $LCONF). Nothing was sent."
  exit 3; }
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui ]] || { say "bad desk box '$BOX'"; exit 3; }
STATE="${SPOOL_FLEET_STATE_ROOT:-$(spool_desk_root "$(getent passwd "$(id -un)" | cut -d: -f6)" "$BOXENV")}" ||
  { say "no desk state root on this machine (SPOOL_DESK_USER has no home?). Nothing was sent."; exit 3; }
d="$STATE/$ENVN/desk/$TENANT/$BOX"

# desk_alive PIDFILE: 0 when it names a live `spool hub-run` (/proc cmdline).
desk_alive() {
  local p
  p="$(cat "$1" 2>/dev/null)"
  [[ "$p" =~ ^[0-9]+$ ]] && tr '\0' ' ' <"${SPOOL_FLEET_PROC_ROOT:-/proc}/$p/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null
}
# desk_moved_to: the user the desk moved to (spl_desk_moved_to, the ./run
# side's one answer, over this caller's root $STATE/$ENVN), 0; else 1.
desk_moved_to() {
  local orc mv me
  me="$(id -un)"
  [[ -z "${SPOOL_FLEET_STATE_ROOT:-}" && -z "${SPL_DESK_HOPPED:-}" ]] || return 1
  [[ "${SPOOL_TEST:-}" != 1 || -n "${SPL_DESK_AS_CMD:-}" ]] || return 1
  [[ -z "$(_spool_desk_root_key "$BOXENV")" || "$(_spool_desk_root_key "$BOXENV")" == "$me" ]] || return 1
  orc="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../../.." && pwd)"
  # shellcheck disable=SC2034,SC2317 # read and called by the sourced spl_desk_moved_to
  mv="$(
    PROJ_PATH="$orc" SPL_ORG_APP="$(basename "$orc" | sed 's/-orc$//')" ENV="$ENVN" SPL_STATE_DIR="$STATE/$ENVN" SPOOL_BOX_ENV="$BOXENV"
    do_log() { echo "spool-fleet-relay: $*"; }
    spl_desk_alive() { desk_alive "$1"; }
    # shellcheck source=../../../../../lib/bash/funcs/spl-cloud-cnf.func.sh
    . "$orc/lib/bash/funcs/spl-cloud-cnf.func.sh" && . "$orc/lib/bash/funcs/spl-desk-moved.func.sh" &&
      spl_desk_moved_to "$TENANT" "$BOX" "$ENVN"
  )" || return 1
  [[ "${mv%%$'\t'*}" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "${mv%%$'\t'*}" != "$me" ]] || return 1
  printf '%s' "${mv%%$'\t'*}"
}

pid="$(cat "$d/spool/.hub/hub-run.pid" 2>/dev/null)"
desk_alive "$d/spool/.hub/hub-run.pid" || {
  if mu="$(desk_moved_to)"; then
    say "INFO desk $BOX of $TENANT ($ENVN) lives under $mu's state root (do_spl_desk_move, spec 069 8.4), not $(id -un)'s ($d): relayed as $mu"
    read -r -a as <<<"${SPL_DESK_AS_CMD:-sudo -n -u}"
    declare -a hopenv=(HOME="$(getent passwd "$mu" | cut -d: -f6)" SPL_DESK_HOPPED="$(id -un)" SPOOL_DESK_USER="$mu"
      SPOOL_FLEET_ENV="$ENVN" SPOOL_FLEET_TENANT="$TENANT" SPOOL_DESK_BOX="$BOX" SPOOL_BOX_ENV="$BOXENV")
    for v in SPOOL_TEST SPOOL_FLEET_PROXY SPOOL_FLEET_BIN SPOOL_BIN SPOOL_FLEET_PROC_ROOT; do
      [ -n "${!v:-}" ] && hopenv+=("$v=${!v}")
    done
    exec "${as[@]}" "$mu" -- env "${hopenv[@]}" bash "$(readlink -f "${BASH_SOURCE[0]}")" --spool-root "$ROOT" "${ARGV[@]}"
  fi
  say "no live hub-run sidecar for $BOX in $TENANT ($ENVN, $d): the message to $TO cannot leave this machine. Run do_spl_desk_up. Nothing was sent."
  exit 3; }
declare -a envv=()
SIDEBOX=""
while IFS= read -r -d '' e; do
  case "${e%%=*}" in
    SPOOL_ROOT|SPOOL_KEYS_DIR|SPOOL_PINS_DIR|SPOOL_BOX_ID|SPOOL_HUB_URL|SPOOL_TENANT|SPOOL_MSG_VERSION|SPOOL_SUBMIT_SOCKET) envv+=("$e") ;;
  esac
  [ "${e%%=*}" = SPOOL_BOX_ID ] && SIDEBOX="${e#*=}"
done <"${SPOOL_FLEET_PROC_ROOT:-/proc}/$pid/environ"
[ "${#envv[@]}" -ge 5 ] || { say "cannot read the sidecar's settings (pid $pid)"; exit 3; }
# The box is the trust unit, not the seat (HOWTO-satellite-work §4 gaps 1-3):
# a lane agent is never seated on the desk, and the hub refuses a sender the
# box does not announce. A sender in THIS machine's registry.tsv is relayed
# under a seated id of the box (the proxy) instead; an id the registry does
# not list either is refused.
# The proxy, and a seated sender too, must be an id the hub ties to THIS box
# (SPL-3865): a seat dir outlives its announce. The orch lease moved to the
# other box, LEASE_ORCH stayed seated here, and every relay under it was
# refused from_not_announced. The sidecar's roster cache (.hub/roster.json,
# box -> ids) says what this box announces; with no cache yet, a role id is
# taken only while its lease mirror (dispatch/lease, lease.orch) names this box.
ME="${SIDEBOX:-$BOX}"
ANN="$(python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(" ".join(r[sys.argv[2]]))' \
  "$d/spool/.hub/roster.json" "$ME" 2>/dev/null)" && ANN=" $ANN " || ANN=""
announced() {  # ID
  [ -d "$d/spool/$1" ] || return 1
  [ -z "$ANN" ] || { [[ "$ANN" == *" $1 "* ]]; return; }
  local f h
  for f in "$ROOT/dispatch/lease" "$ROOT/dispatch/lease.orch"; do
    read -r h _ <"$f" 2>/dev/null || continue
    [[ "${h%@*}" == "$1" && "$h" == *@* && "${h#*@}" != "$ME" && "${h#*@}" != "$BOX" ]] && return 1
  done
  return 0
}
SENDER="$FROM"
if ! announced "$FROM"; then
  awk -F'\t' -v id="$FROM" '$1 == id || index($1, id "@") == 1 { f = 1 } END { exit !f }' "$ROOT/registry.tsv" 2>/dev/null || {
    say "$FROM is neither seated on $BOX in $TENANT ($ENVN) and announced by it, nor in this machine's $ROOT/registry.tsv: the hub refuses a sender its box does not vouch for. Nothing was sent."
    exit 3; }
  SENDER=""
  for p in "${SPOOL_FLEET_PROXY:-$(kv "$BOXENV" SPOOL_FLEET_PROXY)}" "$(kv "$LCONF" LEASE_ORCH)" \
           "$d"/spool/*; do
    p="${p##*/}"
    spl_is_participant_id "$p" && announced "$p" && { SENDER="$p"; break; }
  done
  [ -n "$SENDER" ] || { say "no agent seated on $BOX in $TENANT ($ENVN) is announced by $ME to relay for $FROM. Nothing was sent."; exit 3; }
fi
if [ "$THISBOX" = 1 ]; then
  TOBOX="$SIDEBOX"
  [[ "$TOBOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "the sidecar (pid $pid) names no box id for --to-this-box. Nothing was sent."; exit 3; }
fi
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
# A task of 6 to 31 hex digits is not a name: it is the short form of a real
# topic (the form posts carry). Hashed, it landed in a new empty topic nobody
# reads and the relay printed success (c-002 msg 4592d4c0, 2026-10-23), so it is
# refused before anything is sent. Local sends are not relayed and keep theirs.
if [[ "$TASK" =~ ^[0-9a-fA-F]{6,31}$ ]]; then
  say "task '$TASK' looks like a short topic id: pass the full uuid (or dispatch-<topic8> for an owner topic). Nothing was sent."
  exit 2
fi
if [ -n "$TASK" ] && ! [[ "$TASK" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
  TASK="$(python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool-task:" + sys.argv[1]))' "$TASK")" ||
    { say "cannot map task '$TASK' to a uuid"; exit 2; }
fi
[ -n "$TASK" ] && args+=(--task "$TASK")
[ -n "$TOBOX" ] && args+=(--to-box "$TOBOX")
[ -n "$ACCEPT" ] && args+=(--accept "$ACCEPT")
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
