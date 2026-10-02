#!/usr/bin/env bash
# agent-id-map.sh — write THIS machine's legacy -> new agent id table ONCE
# (specs/061 §5, T060): $SPOOL_ROOT/agent-id-aliases.tsv, one row per id,
#   old<TAB>new<TAB>kind<TAB>box<TAB>mapped-utc
# the format cmd/spool (agentid.go aliasTable) and spl_agent_id_resolve read.
#
# Rows, in this order:
#   CLE-001 -> c-001, CLE-002 -> c-002, CLE-003 -> c-003 (the role ids; they
#   MOVE at the rotations, L6, but the alias exists from the start);
#   then every LIVE legacy agent of this machine, oldest spawn first, gets the
#   next number of the machine's line from next-agent-id.sh (the per-box
#   cursor, the 5 skip rules). Live = a tmux window carries the id AND its
#   identity record agents/<ID>.json says alive. Dead ids get no row; their
#   history keeps the old id as stored text.
# With --apply each new number is CLAIMED through next-agent-id.sh (its spool
# dir is created, the cursor moves), so no spawn can take it meanwhile; the
# rename (agent-id-rename.sh) then moves the old dir into it.
#
# Written once: when the table exists, a second run prints its rows and
# changes nothing (exit 0).
#
# Usage:
#   agent-id-map.sh [--apply] [--skip "ID ID ..."]
#     --skip   live legacy agents to leave out (a lane that is mid-push); they
#              get no row, so they keep their old id until they exit
#
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET, SPOOL_DESK_BOX (the box column; else
# box.env, else box-desk), SPOOL_NOW (the mapped-utc clock).
# Exit 0 written (or planned, or already written), 1 an allocation failed,
# 2 usage.
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=/dev/null
. "$_here/../../../../../lib/bash/funcs/spl-desk-box.func.sh"

APPLY=0; SKIP=" "
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --skip) [ "$#" -ge 2 ] || { echo "agent-id-map: --skip needs a list" >&2; exit 2; }; SKIP+="$2 "; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) echo "agent-id-map: unknown argument: $1" >&2; exit 2 ;;
  esac
done

R="$SPOOL_ROOT"
TABLE="$R/agent-id-aliases.tsv"
BOX="$(spl_desk_box_default)"
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "agent-id-map: '$BOX' is not a box id (SPOOL_DESK_BOX)" >&2; exit 2; }
LEGACY_RX='^(CLE|GRK|AGY|QWN)-[0-9]+$'

if [ -s "$TABLE" ]; then
  echo "agent-id-map: ${TABLE} is written once and already holds $(grep -c . "$TABLE") row(s); nothing changed:"
  cat "$TABLE"
  exit 0
fi

NOW=""; spl_now_var NOW

# ---- the live legacy agents, oldest spawn first -----------------------------
spool_tmux_argv
declare -A SEEN=()
live=()
while IFS= read -r wname; do
  id="$(spool_id_of_window "$wname" 2>/dev/null || true)"
  id="${id%%@*}"
  [[ "$id" =~ $LEGACY_RX ]] || continue
  n=$((10#${id#*-}))
  [ "$n" -ge 4 ] || continue                     # roles 001-003 (and 000, never an id)
  [ -z "${SEEN[$id]:-}" ] || continue; SEEN[$id]=1
  case "$SKIP" in *" $id "*) echo "SKIP     ${id}: --skip" >&2; continue ;; esac
  rec="$R/agents/${id}.json"
  if ! [ -r "$rec" ] || ! python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("alive") else 1)' "$rec" 2>/dev/null; then
    echo "SKIP     ${id}: a window carries it but its identity record is not alive (${rec})" >&2
    continue
  fi
  spawned="$(awk -F'\t' -v id="$id" '{ k = $1; sub(/@.*/, "", k) } k == id && $5 ~ /^[0-9]{8}T[0-9]{6}Z$/ { s = $5 } END { print s }' "$R/registry.tsv" 2>/dev/null || true)"
  [ -n "$spawned" ] || { [ -e "$R/$id" ] && spawned="$(date -u -r "$R/$id" +%Y%m%dT%H%M%SZ)"; }
  [ -n "$spawned" ] || spawned="$(date -u -r "$rec" +%Y%m%dT%H%M%SZ)"
  live+=("${spawned} ${id}")
done < <("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null || true)

rows=()
for r in 1 2 3; do rows+=("$(printf 'CLE-%03d\tc-%03d\tclaude\t%s\t%s' "$r" "$r" "$BOX" "$NOW")"); done

# A dry run asks the allocator without claiming; each planned number goes into
# a scratch registry the next ask holds (next-agent-id.sh --also-registry).
PLANREG="$(mktemp -d)"; trap 'rm -rf "$PLANREG"' EXIT
: >"$PLANREG/registry.tsv"
if [ "${#live[@]}" -gt 0 ]; then
  while read -r spawned id; do
    kind="$(spl_kind_of_agent_id "$id")"
    if [ "$APPLY" = 1 ]; then
      new="$(bash "$_here/next-agent-id.sh" --kind "$kind")" || { echo "agent-id-map: no number for ${id} (next-agent-id.sh failed); nothing written" >&2; exit 1; }
    else
      new="$(bash "$_here/next-agent-id.sh" --kind "$kind" --no-reserve --also-registry "$PLANREG")" || { echo "agent-id-map: no number for ${id}" >&2; exit 1; }
      printf '%s\n' "$new" >>"$PLANREG/registry.tsv"
    fi
    rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$new" "$kind" "$BOX" "$NOW")")
    printf '%s %-11s -> %s (%s, spawned %s)\n' "$([ "$APPLY" = 1 ] && echo DO || echo PLAN)" "$id" "$new" "$kind" "$spawned"
  done < <(printf '%s\n' "${live[@]}" | sort)
fi

if [ "$APPLY" = 0 ]; then
  echo "agent-id-map: dry run, ${#rows[@]} row(s) planned for ${TABLE} (box ${BOX}); --apply writes them once:"
  printf '%s\n' "${rows[@]}"
  exit 0
fi

(
  flock -w 30 9 || { echo "agent-id-map: ${TABLE}.lock stayed locked" >&2; exit 1; }
  [ ! -s "$TABLE" ] || { echo "agent-id-map: ${TABLE} was written meanwhile; left as it is" >&2; exit 1; }
  tmp="$(mktemp "$R/.agent-id-aliases.XXXXXX")"
  printf '%s\n' "${rows[@]}" >"$tmp"
  chmod 0664 "$tmp"
  mv "$tmp" "$TABLE"
) 9>>"$TABLE.lock"
echo "agent-id-map: wrote ${#rows[@]} row(s) to ${TABLE} (box ${BOX}):"
cat "$TABLE"
