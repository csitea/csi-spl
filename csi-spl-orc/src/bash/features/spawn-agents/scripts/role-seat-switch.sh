#!/usr/bin/env bash
# role-seat-switch.sh — move a role seat to the id of the vendor that now runs
# it (SPL-1685, owner t1 ee1e58d5: c-001 run by Grok is g-001), and back.
# Per seat:
#   1. spool dir   the seat's ONE real dir moves to $SPOOL_ROOT/<NEW>; no
#                  other id of the seat (a-/c-/g-/m-/q-00N, spl_role_seat_ids)
#                  keeps an entry: a letter link is removed (SPL-4031, orch
#                  panel plan B2). Mail written to any of them - a queued
#                  message, a script's ${X:-c-001} default, the hub sidecar -
#                  still lands in the live inbox: the spool resolves a role
#                  seat letter with no entry to its live sibling on send, recv
#                  and delivery (liveRoleSeat), the lease reads it the same
#                  way (spl_fleet_seat_id). A legacy alias link into the seat
#                  (CLE-00N) is pointed at <NEW>. A stale real dir of another
#                  letter is merged in first (a file name in both = FAIL,
#                  nothing moved).
#   2. registry    registry.tsv column 1 <OLD>[@box] -> <NEW>[@box]
#   3. identity    agents/<OLD>.json -> agents/<NEW>.json (agent-identity.py)
#   4. desks       each hub desk dir of the seat (<desk-root>/<env>/desk/
#                  <tenant>/<box>/spool/<id>) the same way: the sidecar
#                  announces <NEW> on its next scan (a link is no agent dir)
# Windows are the rotation's: it renames the old one -retiring and spawns the
# new one under <NEW>. lease.conf is the rotation's too.
# The reverse switch (g-001 -> c-001 while c-001 is a link) is the same call.
#
# Usage:
#   role-seat-switch.sh [--apply] [--desk-envs "dev prd"] OLD NEW
# Env: SPOOL_ROOT, SPOOL_DESK_BOX, DESK_STATE_ROOT (default
# spool_desk_root: the desk user's state root, else $HOME's).
# Exit 0 switched (or planned, or already switched), 1 failed, 2 usage.

set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=../lib/desk-root.inc.sh
. "$_here/../lib/desk-root.inc.sh"
# shellcheck source=/dev/null
. "$_here/../../../../../lib/bash/funcs/spl-desk-box.func.sh"

APPLY=0; DESK_ENVS=""; ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --desk-envs) [ "$#" -ge 2 ] || exit 2; DESK_ENVS="$2"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    -*) echo "role-seat-switch: unknown argument: $1" >&2; exit 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ "${#ARGS[@]}" -eq 2 ] || { echo "role-seat-switch: want OLD NEW" >&2; exit 2; }
OLD="${ARGS[0]}"; NEW="${ARGS[1]}"
spl_is_role_seat "$OLD" && spl_is_role_seat "$NEW" && [[ "$OLD" != *@* && "$NEW" != *@* ]] ||
  { echo "role-seat-switch: $OLD and $NEW must both be bare role seat ids (${SPL_ROLE_SEAT_RX})" >&2; exit 2; }
[ "$(spl_role_seat_num "$OLD")" = "$(spl_role_seat_num "$NEW")" ] && [ "$OLD" != "$NEW" ] ||
  { echo "role-seat-switch: $OLD -> $NEW is not one seat in another letter" >&2; exit 2; }

R="$SPOOL_ROOT"
BOX="$(spl_desk_box_default)"
DESK_ROOT="${DESK_STATE_ROOT:-$(spool_desk_root "$HOME")}"
VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO
step() { printf '%s %-9s %s\n' "$VERB" "$1" "$2"; }

# _merge FROM INTO: every file of FROM's inbox/outbox/archive/.pokes into the
# same sub-dir of INTO; a byte-identical copy is dropped, a .pokes log
# appended; any other name in both stops it (rc 1, nothing of FROM removed).
_merge() {
  local sub f
  for sub in inbox outbox archive .pokes; do
    for f in "$1/$sub"/* "$1/$sub"/.[!.]*; do
      [ -f "$f" ] || continue
      [ -e "$2/$sub/${f##*/}" ] || continue
      cmp -s "$f" "$2/$sub/${f##*/}" || [ "$sub" = .pokes ] || { echo "$f is also in $2/$sub"; return 1; }
    done
  done
  [ "$APPLY" = 1 ] || return 0
  for sub in inbox outbox archive .pokes; do
    [ -d "$1/$sub" ] || continue
    mkdir -p "$2/$sub"
    for f in "$1/$sub"/* "$1/$sub"/.[!.]*; do
      [ -f "$f" ] || continue
      if [ ! -e "$2/$sub/${f##*/}" ]; then mv -n "$f" "$2/$sub/"
      elif [ "$sub" = .pokes ] && ! cmp -s "$f" "$2/$sub/${f##*/}"; then cat "$f" >>"$2/$sub/${f##*/}"; rm -f "$f"
      else rm -f "$f"; fi
    done
  done
  rm -rf "$1"
}

# _switch ROOT: in ROOT (the spool root or one desk's spool dir) the seat's
# real dir becomes ROOT/NEW and no other id of the seat keeps an entry.
# Nothing of the seat in ROOT = nothing to do.
_switch() {
  local root="$1" live="" id real
  # the live dir: OLD's target (a link chain is followed), else NEW's
  for id in "$OLD" "$NEW"; do
    [ -e "$root/$id" ] || continue
    real="$(readlink -f "$root/$id")"
    [ -d "$real" ] && [ "$(dirname "$real")" = "$(readlink -f "$root")" ] && { live="${real##*/}"; break; }
  done
  [ -n "$live" ] || return 0
  # stale real dirs of the other letters merge into the live one
  for id in $(spl_role_seat_ids "$NEW"); do
    [ "$id" = "$live" ] && continue
    if [ -d "$root/$id" ] && [ ! -L "$root/$id" ]; then
      step merge "$root/$id -> $root/$live"
      _merge "$root/$id" "$root/$live" || return 1
    fi
  done
  if [ "$live" != "$NEW" ]; then
    step move "$root/$live -> $root/$NEW"
    if [ "$APPLY" = 1 ]; then
      [ -L "$root/$NEW" ] && rm -f "$root/$NEW"
      mv "$root/$live" "$root/$NEW"
    fi
  fi
  local seat l t
  seat=" $(spl_role_seat_ids "$NEW" | tr '\n' ' ') "
  for id in $(spl_role_seat_ids "$NEW"); do
    [ "$id" = "$NEW" ] || [ ! -L "$root/$id" ] && continue
    step unlink "$root/$id"
    [ "$APPLY" = 1 ] && rm -f "$root/$id"
  done
  # a legacy alias (CLE-00N -> c-00N) keeps resolving: it points at NEW
  for l in "$root"/*; do
    [ -L "$l" ] || continue
    [[ "$seat" == *" ${l##*/} "* ]] && continue
    t="$(readlink "$l")"
    [[ "$seat" == *" $t "* || "$t" == "$live" ]] && [ "$t" != "$NEW" ] || continue
    step relink "$l -> $NEW"
    [ "$APPLY" = 1 ] && ln -sfn "$NEW" "$l"
  done
  return 0
}

rc=0
why="$(_switch "$R")" || { echo "FAIL     spool: $why" >&2; exit 1; }
[ -n "$why" ] && printf '%s\n' "$why"

if [ -r "$R/registry.tsv" ] && awk -F'\t' -v id="$OLD" '{ k = $1; sub(/@.*/, "", k) } k == id { f = 1 } END { exit !f }' "$R/registry.tsv"; then
  step registry "registry.tsv column 1 $OLD -> $NEW"
  if [ "$APPLY" = 1 ]; then
    (
      flock -w 30 9 || { echo "role-seat-switch: registry.tsv.lock stayed locked" >&2; exit 1; }
      body="$(awk -F'\t' -v OFS='\t' -v id="$OLD" -v nw="$NEW" '{ k = $1; s = ""; if (k ~ /@/) { s = substr(k, index(k, "@")); sub(/@.*/, "", k) } if (k == id) $1 = nw s; print }' "$R/registry.tsv")"
      printf '%s\n' "$body" >"$R/registry.tsv"
    ) 9>>"$R/registry.tsv.lock" || rc=1
  fi
fi

if [ -e "$R/agents/$OLD.json" ] && [ ! -e "$R/agents/$NEW.json" ]; then
  step identity "agents/$OLD.json -> agents/$NEW.json"
  [ "$APPLY" = 1 ] && { python3 "$_here/agent-identity.py" --dir "$R/agents" rename "$OLD" "$NEW" >/dev/null ||
    { echo "WARN     identity record not renamed (agent-identity.py rename)" >&2; rc=1; }; }
fi

for env in $DESK_ENVS; do
  [[ "$env" =~ ^(dev|prd)$ ]] || { echo "role-seat-switch: --desk-envs takes dev / prd, got: $env" >&2; exit 2; }
  for d in "$DESK_ROOT/$env"/desk/*/"$BOX"/spool; do
    [ -d "$d" ] || continue
    why="$(_switch "$d")" || { echo "FAIL     desk $env $d: $why" >&2; rc=1; continue; }
    [ -n "$why" ] && printf '%s\n' "$why"
  done
done
what=planned; [ "$APPLY" = 1 ] && what=switched
echo "role-seat-switch: $OLD -> $NEW $what (desks: ${DESK_ENVS:-none})"
exit "$rc"
