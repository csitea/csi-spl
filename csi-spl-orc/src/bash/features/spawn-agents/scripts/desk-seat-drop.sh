#!/usr/bin/env bash
# desk-seat-drop.sh — take agent ids off the hub desks of THIS machine, so no
# desk announces them as members / tag targets any more (owner 2026-10-05, t1
# dc6d5e3f: "I should be able to tag only currently active agents").
#
# A desk's box sidecar announces every agent DIR under its spool root
# (<desk-root>/<env>/desk/<tenant>/<box>/spool/<ID>[@<box>], spool.ScanAgents,
# every 10 s). A seat dir moved to that root's .retired/<ID>.<utc>/ (unread
# mail kept) drops out of the next announce; a link is never announced and is
# left alone. Run by agent-id-retire.sh for the id it retires, and by
# ./run -a do_spl_desk_legacy_drop for every legacy id (CLE-/GRK-/AGY-/QWN-)
# a desk still announces after the spec 061 cutoff.
#
# Usage:
#   desk-seat-drop.sh [--apply] [--box BOX] (--legacy | ID ...)
#     --legacy  every legacy agent id seated (instead of the named ids)
#     --box     only the desks of that box (default: every box dir)
#
# Env: DESK_STATE_ROOT (default $HOME/.local/share/csi-spl/cloud), DESK_ENVS
# (default "dev prd"), DESK_TENANT (default every tenant), SPOOL_NOW.
# Prints one SEATED line per desk with its matching ids (none: "-"), then one
# PLAN / DO drop line per seat.
# Exit 0 done (or planned), 1 a move failed, 2 usage, 5 a desk root is not
# readable.
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"

APPLY=0; LEGACY=0; BOX="*"; IDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --legacy) LEGACY=1; shift ;;
    --box) [ "$#" -ge 2 ] || { echo "desk-seat-drop: --box needs a box id" >&2; exit 2; }; BOX="$2"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    -*) echo "desk-seat-drop: unknown argument: $1" >&2; exit 2 ;;
    *) IDS+=("${1%%@*}"); shift ;;
  esac
done
LEGACY_RX='^(CLE|GRK|AGY|QWN)-[0-9]+$'
[ "$LEGACY" = 1 ] && [ "${#IDS[@]}" -gt 0 ] && { echo "desk-seat-drop: --legacy or ids, not both" >&2; exit 2; }
[ "$LEGACY" = 1 ] || [ "${#IDS[@]}" -gt 0 ] || { echo "desk-seat-drop: name the ids, or --legacy" >&2; exit 2; }
for id in "${IDS[@]}"; do
  [[ "$id" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || { echo "desk-seat-drop: '${id}' is not an agent id" >&2; exit 2; }
done
[ "$BOX" = "*" ] || [[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "desk-seat-drop: '${BOX}' is not a box id" >&2; exit 2; }
for e in ${DESK_ENVS:-dev prd}; do
  [[ "$e" =~ ^(dev|prd)$ ]] || { echo "desk-seat-drop: DESK_ENVS takes dev / prd, got: $e" >&2; exit 2; }
done
[ -z "${DESK_TENANT:-}" ] || [[ "$DESK_TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
  || { echo "desk-seat-drop: '${DESK_TENANT}' is not a tenant id" >&2; exit 2; }

ROOT="${DESK_STATE_ROOT:-$HOME/.local/share/csi-spl/cloud}"
VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO
NOW=""; spl_now_var NOW
STAMP="$(date -u -d "$NOW" +%Y%m%dT%H%M%SZ)"

# _match NAME: 0 when the seat dir NAME (<ID> or <ID>@<box>) is one to drop.
_match() {
  local id="${1%%@*}" want
  if [ "$LEGACY" = 1 ]; then [[ "$id" =~ $LEGACY_RX ]]; return; fi
  for want in "${IDS[@]}"; do [ "$id" = "$want" ] && return 0; done
  return 1
}

rc=0; desks=0; seats=0
for env in ${DESK_ENVS:-dev prd}; do
  [ -e "$ROOT/$env/desk" ] || continue
  if [ ! -r "$ROOT/$env/desk" ] || [ ! -x "$ROOT/$env/desk" ]; then
    echo "desk-seat-drop: WARN ${ROOT}/${env}/desk is not readable as $(id -un): run this as its owner" >&2
    rc=5; continue
  fi
  for d in "$ROOT/$env"/desk/${DESK_TENANT:-*}/$BOX/spool; do
    [ -d "$d" ] || continue
    b="${d%/spool}"; t="${b%/*}"; b="${b##*/}"; t="${t##*/}"
    desks=$((desks + 1))
    hits=()
    for s in "$d"/*; do
      n="${s##*/}"
      [ -d "$s" ] && [ ! -L "$s" ] || continue
      [[ "${n%%@*}" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || continue
      _match "$n" && hits+=("$n")
    done
    echo "SEATED ${env}/${t}/${b} ${hits[*]:--}"
    for n in "${hits[@]}"; do
      dst="$d/.retired/${n}.${STAMP}"
      k=1; while [ -e "$dst" ]; do k=$((k + 1)); dst="$d/.retired/${n}.${STAMP}.${k}"; done
      printf '%s drop      %s/%s/%s %s -> %s\n' "$VERB" "$env" "$t" "$b" "$n" "$dst"
      seats=$((seats + 1))
      [ "$APPLY" = 1 ] || continue
      mkdir -p "$d/.retired" && mv "$d/$n" "$dst" || { echo "desk-seat-drop: FAIL ${env}/${t}/${b} ${n}" >&2; rc=1; }
    done
  done
done
echo "desk-seat-drop: ${seats} seat(s) on ${desks} desk(s) $([ "$APPLY" = 1 ] && echo dropped || echo 'would be dropped') (${ROOT})"
exit "$rc"
