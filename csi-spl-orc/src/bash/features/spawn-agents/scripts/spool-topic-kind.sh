#!/usr/bin/env bash
# spool-topic-kind.sh — is a topic uuid an OWNER topic? spool-send.sh asks it,
# as the box user, before an agent message goes out on a --task uuid.
#
#   spool-topic-kind.sh [--spool-root <dir>] <task uuid>
#
# stdout: "owner" when the hub holds a message of the topic from a human seat
# (HUM-*) or posted to the channel (to ALL-0): a topic the owner reads in the
# WUI. "agent" otherwise, also for a topic the hub does not hold.
# Measured 2026-10-10 on sat's prd desk, n=1313 task uuids of the local spool:
# 156 owner (148 with a HUM-* post, 8 channel-only), 936 agent, 221 not on
# the hub; 0.108 s per lookup. The uuid shape cannot tell them apart: all 156
# owner topics and 913 of the agent ones are v4.
#
# It reads the topic through this machine's desk sidecar, with the desk
# lookup spool-fleet-relay.sh makes (keep the two in step).
#
# Exit codes: 0 answered; 2 usage; 3 cannot tell (no desk, no live sidecar,
# no hub answer within SPOOL_TOPIC_KIND_TIMEOUT s, default 1).
set -uo pipefail

ROOT="${SPOOL_ROOT:-/var/spool-hub}" TASK=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spool-root) [ "$#" -ge 2 ] || exit 2; ROOT="$2"; shift 2 ;;
    *) [ -z "$TASK" ] || exit 2; TASK="$1"; shift ;;
  esac
done
[[ "$TASK" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || exit 2

# KEY from a KEY=value file (read, never sourced).
kv() {  # FILE KEY
  [ -r "$1" ] || return 0
  sed -n "s/^$2=[\"']\{0,1\}\([A-Za-z0-9_-]*\)[\"']\{0,1\}\$/\1/p" "$1" | tail -1
}
BOXENV="${SPOOL_BOX_ENV:-$ROOT/box.env}" LCONF="$ROOT/dispatch/lease.conf"
ENVN="${SPOOL_FLEET_ENV:-$(kv "$BOXENV" SPOOL_FLEET_ENV)}"; ENVN="${ENVN:-$(kv "$LCONF" LEASE_ENV)}"
TENANT="${SPOOL_FLEET_TENANT:-$(kv "$BOXENV" SPOOL_FLEET_TENANT)}"; TENANT="${TENANT:-$(kv "$LCONF" LEASE_TENANT)}"
BOX="${SPOOL_DESK_BOX:-$(kv "$BOXENV" SPOOL_DESK_BOX)}"; BOX="${BOX:-$(kv "$LCONF" LEASE_DESK_BOX)}"; BOX="${BOX:-box-desk}"
[[ "$ENVN" =~ ^(dev|prd|self)$ && "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || exit 3
STATE="${SPOOL_FLEET_STATE_ROOT:-$(getent passwd "$(id -un)" | cut -d: -f6)/.local/share/csi-spl/cloud}"
d="$STATE/$ENVN/desk/$TENANT/$BOX"
pid="$(cat "$d/spool/.hub/hub-run.pid" 2>/dev/null)"
[[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | grep ' hub-run' >/dev/null || exit 3
declare -a envv=()
while IFS= read -r -d '' e; do
  case "${e%%=*}" in
    SPOOL_ROOT|SPOOL_KEYS_DIR|SPOOL_PINS_DIR|SPOOL_BOX_ID|SPOOL_HUB_URL|SPOOL_TENANT|SPOOL_MSG_VERSION) envv+=("$e") ;;
  esac
done <"/proc/$pid/environ"
[ "${#envv[@]}" -ge 5 ] || exit 3
BIN="${SPOOL_FLEET_BIN:-$STATE/$ENVN/bin/spool}"
[ -x "$BIN" ] || BIN="${SPOOL_BIN:-spool}"
out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin SPOOL_LOG_LEVEL=error "${envv[@]}" \
  timeout "${SPOOL_TOPIC_KIND_TIMEOUT:-1}" "$BIN" hub-tail --task "$TASK" --json 2>/dev/null)" || exit 3
if grep '^{' <<<"$out" | jq -e -s 'any(.[]; ((.from // "") | tostring | startswith("HUM-")) or .to == "ALL-0")' >/dev/null 2>&1; then
  echo owner
else
  echo agent
fi
