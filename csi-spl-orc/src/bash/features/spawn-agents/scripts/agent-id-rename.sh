#!/usr/bin/env bash
# agent-id-rename.sh — give a live legacy-id agent of THIS machine its new id
# from the alias table agent-id-mapped (specs/061 FR-011, T061). Per agent:
#   1. spool dir   $SPOOL_ROOT/<old> -> <new> (the empty dir the map claimed
#                  for <new> is replaced), and <old> stays as a link to <new>
#                  until L9, so a path built from the old id still lands
#                  (qualified layout: <old>@<box> -> <new>@<box>, both links)
#   2. registry    registry.tsv column 1 <old>[@box] -> <new>[@box]
#   3. identity    agents/<old>.json -> agents/<new>.json, id = <new>
#                  (agent-identity.py rename); from now on the record follows
#                  the new id although the process env keeps the old one
#   4. window      every tmux window carrying <old> is renamed to carry <new>
#   5. desks       each hub desk this agent is seated on (<desk-root>/<env>/
#                  desk/<tenant>/<box>/spool/<old>) moves to <new> with an
#                  <old> link: the box sidecar announces <new> on its next scan
#                  and drops <old> (a link is not an agent dir), so the agent
#                  is re-seated with its inbox, pokes and mute marker
#   6. note        ONE spool note to the agent: "your id is now <new>; use
#                  --from <new>"
# Role ids (001-003) are renamed only with --roles (spec 061 L6), and then
# only they: CLE-001/002/003 -> c-001/002/003. A stop-gap link <new> -> <old>
# (the orchestrator's 2026-10-02 bridge) is replaced by the real layout:
# <new> the dir, <old> the link. The role's process keeps its old env id until
# agent-name-resume.sh resumes it under the new one, and lease.conf
# (LEASE_ORCH / LEASE_MASTER / LEASE_FAILOVER) must name the new id at that
# same moment. An agent already renamed (<old> is a link) is skipped, so a
# re-run is safe.
#
# Usage:
#   agent-id-rename.sh [--apply] [--roles] [--desk-envs "dev prd"] [--note-from ID] [OLD ...]
#     OLD          the legacy ids to rename (default: every non-role row of
#                  the table whose old id this machine still holds)
#     --roles      rename the role rows (001-003) of the table instead
#     --desk-envs  the hub envs whose desks are re-seated (default: none;
#                  prd needs the owner's go)
#     --note-from  the id the FR-011 note is sent from (default SPOOL_AGENT_ID;
#                  none: no note, a WARN)
#
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET, SPOOL_DESK_BOX, DESK_STATE_ROOT (default
# $HOME/.local/share/csi-spl/cloud), RENAME_NOTE=0 (no note; default under
# SPOOL_TEST=1).
# Exit 0 every agent renamed (or planned, or already renamed), 1 one failed,
# 2 usage, 4 no alias table.
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=/dev/null
. "$_here/../../../../../lib/bash/funcs/spl-desk-box.func.sh"

APPLY=0; ROLES=0; DESK_ENVS=""; NOTE_FROM="${SPOOL_AGENT_ID:-}"; IDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --roles) ROLES=1; shift ;;
    --desk-envs) [ "$#" -ge 2 ] || exit 2; DESK_ENVS="$2"; shift 2 ;;
    --note-from) [ "$#" -ge 2 ] || exit 2; NOTE_FROM="$2"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    -*) echo "agent-id-rename: unknown argument: $1" >&2; exit 2 ;;
    *) IDS+=("$1"); shift ;;
  esac
done
for e in $DESK_ENVS; do
  [[ "$e" =~ ^(dev|prd)$ ]] || { echo "agent-id-rename: --desk-envs takes dev / prd, got: $e" >&2; exit 2; }
done

R="$SPOOL_ROOT"
TABLE="$R/agent-id-aliases.tsv"
BOX="$(spl_desk_box_default)"
DESK_ROOT="${DESK_STATE_ROOT:-$HOME/.local/share/csi-spl/cloud}"
NOTE="${RENAME_NOTE:-}"
[ -n "$NOTE" ] || { NOTE=1; [ "${SPOOL_TEST:-}" = 1 ] && NOTE=0; }
[ -s "$TABLE" ] || { echo "agent-id-rename: no alias table ${TABLE}; run agent-id-map.sh --apply first" >&2; exit 4; }

VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO
step() { printf '%s %-9s %-10s %s\n' "$VERB" "$1" "$2" "$3"; }
spool_tmux_argv

# The table's rows this run renames: OLD NEW, the roles only with --roles.
declare -A NEW_OF=()
while IFS=$'\t' read -r old new _kind b _t; do
  [[ "$old" =~ ^(CLE|GRK|AGY|QWN)-[0-9]+$ && "$new" =~ ^${SPOOL_AGENT_ID_NEW_RX}$ ]] || continue
  [ "$b" = "$BOX" ] || continue
  if [ "$ROLES" = 1 ]; then [ "$((10#${new#?-}))" -le 3 ] || continue
  else [ "$((10#${new#?-}))" -ge 4 ] || continue; fi
  NEW_OF[$old]="$new"
done <"$TABLE"
NAMED=1
if [ "${#IDS[@]}" -eq 0 ]; then
  NAMED=0
  for old in "${!NEW_OF[@]}"; do IDS+=("$old"); done
  mapfile -t IDS < <(printf '%s\n' "${IDS[@]}" | sort)
fi

# _skeleton DIR: 0 when DIR holds no mail to read: inbox and archive empty,
# and besides them only an outbox (the map's claim, or the sent copies a
# machine wrote under the new id before its role moved - the satellite,
# 2026-10-02: c-001/outbox held 8 lease and gap notes) or an empty .pokes.
# Such a dir may be replaced; _rm_skeleton keeps its outbox copies.
_skeleton() {
  local e
  for e in "$1"/* "$1"/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    case "${e##*/}" in
      inbox|archive|.pokes) [ -d "$e" ] && [ -z "$(ls -A "$e")" ] || return 1 ;;
      outbox) [ -d "$e" ] || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 0
}
# _rm_skeleton DIR [KEEP]: remove the claim; its outbox copies move to KEEP
# (a dir, made if missing) first, so the sent history survives the swap.
_rm_skeleton() {
  if [ -n "${2:-}" ] && [ -n "$(ls -A "$1/outbox" 2>/dev/null)" ]; then
    mkdir -p "$2" && find "$1/outbox" -maxdepth 1 -type f -exec mv -n -t "$2" {} +
  fi
  rmdir "$1/inbox" "$1/outbox" "$1/archive" "$1/.pokes" 2>/dev/null || true; rmdir "$1"
}

# _swap ROOT OLD NEW: ROOT/OLD -> ROOT/NEW, ROOT/OLD a link to NEW. Prints the
# reason and returns 1 when NEW is held by something other than a skeleton.
_swap() {
  local root="$1" old="$2" new="$3" tgt qb
  if [ -L "$root/$old" ]; then                 # qualified: OLD -> OLD@<box>
    tgt="$(readlink "$root/$old")"; qb="${tgt#"$old"@}"
    [ "$tgt" = "$old@$qb" ] && [ -d "$root/$tgt" ] || { echo "$root/$old links to '$tgt', not $old@<box>"; return 1; }
    # The map's claim of NEW is a skeleton in either layout (the allocator
    # follows SPOOL_DIR_LAYOUT, which need not match this agent's).
    if [ -L "$root/$new" ]; then
      [ "$(readlink "$root/$new")" = "$new@$qb" ] && _skeleton "$root/$new@$qb" || { echo "$root/$new is held"; return 1; }
      [ "$APPLY" = 1 ] && { rm -f "$root/$new"; _rm_skeleton "$root/$new@$qb" "$root/$tgt/outbox"; }
    elif [ -d "$root/$new" ]; then
      _skeleton "$root/$new" && [ ! -e "$root/$new@$qb" ] || { echo "$root/$new is held"; return 1; }
      [ "$APPLY" = 1 ] && _rm_skeleton "$root/$new" "$root/$tgt/outbox"
    elif [ -e "$root/$new" ] || [ -e "$root/$new@$qb" ]; then
      echo "$root/$new is held"; return 1
    fi
    [ "$APPLY" = 1 ] && { mv "$root/$tgt" "$root/$new@$qb"; ln -s "$new@$qb" "$root/$new"; ln -sfn "$new" "$root/$old"; }
    return 0
  fi
  # a stop-gap bridge <new> -> <old>: the move below replaces it
  if [ -L "$root/$new" ] && [ "$(readlink "$root/$new")" = "$old" ]; then
    [ "$APPLY" = 1 ] && rm -f "$root/$new"
  elif [ -e "$root/$new" ] || [ -L "$root/$new" ]; then
    [ ! -L "$root/$new" ] && [ -d "$root/$new" ] && _skeleton "$root/$new" || { echo "$root/$new is held"; return 1; }
    [ "$APPLY" = 1 ] && _rm_skeleton "$root/$new" "$root/$old/outbox"
  fi
  [ "$APPLY" = 1 ] && { mv "$root/$old" "$root/$new"; ln -s "$new" "$root/$old"; }
  return 0
}

rc=0; done_n=0
for old in "${IDS[@]}"; do
  new="${NEW_OF[$old]:-}"
  [ -n "$new" ] || { echo "SKIP     ${old}: no $([ "$ROLES" = 1 ] && echo role || echo non-role) row for it in ${TABLE} (box ${BOX})" >&2; rc=1; continue; }
  if [ -L "$R/$old" ] && [ "$(readlink "$R/$old")" = "$new" ]; then
    echo "SKIP     ${old}: already renamed to ${new}"; continue
  fi
  # a role row the map writes on every machine is no error where that role is not held
  [ -e "$R/$old" ] || { echo "SKIP     ${old}: no spool dir ${R}/${old} on this machine" >&2; [ "$NAMED$ROLES" = 01 ] || rc=1; continue; }
  all="$("${SPOOL_TM[@]}" list-windows -a -F '#{window_id}	#{window_name}' 2>/dev/null || true)"
  wins="$(awk -F'\t' -v id="$old" '{ n = $2; if (match(n, "(^|[^A-Za-z0-9])" id "([^0-9]|$)")) print }' <<<"$all")"
  # live = a window carries the old id, or already the new one (a reconcile
  # renamed it from a record while the process still runs as <old>: the
  # satellite's roles, 2026-10-02); only windows with the old id are renamed
  [ -n "$wins" ] || awk -F'\t' -v id="$new" '{ if (match($2, "(^|[^A-Za-z0-9])" id "([^0-9]|$)")) f = 1 } END { exit !f }' <<<"$all" ||
    { echo "SKIP     ${old}: no tmux window carries it (not live; L9 retires it)" >&2; continue; }

  # The reconcile cron would rename the window back from the env id while
  # this runs: hold its lock for the whole agent.
  exec 7>>"$R/agents/.reconcile.lock"
  flock -w 30 7 || { echo "agent-id-rename: ${R}/agents/.reconcile.lock stayed locked" >&2; exit 1; }

  # 1. the spool dir
  step spool "$old" "${R}/${old} -> ${R}/${new} (+ link ${old} -> ${new})"
  if ! why="$(_swap "$R" "$old" "$new")"; then
    echo "FAIL     ${old}: ${why}" >&2; rc=1; exec 7>&-; continue
  fi
  # 2. the registry rows
  if [ -r "$R/registry.tsv" ] && awk -F'\t' -v id="$old" '{ k = $1; sub(/@.*/, "", k) } k == id { f = 1 } END { exit !f }' "$R/registry.tsv"; then
    step registry "$old" "registry.tsv column 1 -> ${new}"
    if [ "$APPLY" = 1 ]; then
      (
        flock -w 30 9 || { echo "agent-id-rename: registry.tsv.lock stayed locked" >&2; exit 1; }
        # Rewritten in place (same inode): a spawner appending keeps writing into it.
        body="$(awk -F'\t' -v OFS='\t' -v id="$old" -v nw="$new" '{ k = $1; s = ""; if (k ~ /@/) { s = substr(k, index(k, "@")); sub(/@.*/, "", k) } if (k == id) $1 = nw s; print }' "$R/registry.tsv")"
        printf '%s\n' "$body" >"$R/registry.tsv"
      ) 9>>"$R/registry.tsv.lock"
    fi
  fi
  # 3. the identity record
  if [ -e "$R/agents/${old}.json" ]; then
    step identity "$old" "agents/${old}.json -> agents/${new}.json"
    [ "$APPLY" = 1 ] && { python3 "$_here/agent-identity.py" --dir "$R/agents" rename "$old" "$new" >/dev/null \
      || echo "WARN     ${old}: identity record not renamed (agent-identity.py rename)" >&2; }
  fi
  # 4. the windows
  while IFS=$'\t' read -r wid wname; do
    wnew="$(printf '%s' "$wname" | sed -E "s/(^|[^A-Za-z0-9])${old}([^0-9]|\$)/\\1${new}\\2/")"
    step window "$old" "${wid} '${wname}' -> '${wnew}'"
    if [ "$APPLY" = 1 ]; then
      "${SPOOL_TM[@]}" set-window-option -t "$wid" allow-rename off >/dev/null 2>&1 || true
      "${SPOOL_TM[@]}" set-window-option -t "$wid" automatic-rename off >/dev/null 2>&1 || true
      "${SPOOL_TM[@]}" rename-window -t "$wid" "$wnew" || { echo "WARN     ${old}: rename-window ${wid} failed" >&2; rc=1; }
    fi
  done < <(printf '%s' "$wins" | grep . || true)
  exec 7>&-
  # 5. the hub desks it is seated on
  for env in $DESK_ENVS; do
    for d in "$DESK_ROOT/$env"/desk/*/"$BOX"/spool; do
      [ -d "$d/$old" ] && [ ! -L "$d/$old" ] || continue
      t="${d%/"$BOX"/spool}"; t="${t##*/}"
      step desk "$old" "${env}/${t}: ${d}/${old} -> ${new} (+ link)"
      why="$(_swap "$d" "$old" "$new")" || { echo "FAIL     ${old}: desk ${env}/${t}: ${why}" >&2; rc=1; }
    done
  done
  # 6. the note
  body="your id is now ${new}; use --from ${new}"
  if [ "$NOTE" = 1 ] && [ -n "$NOTE_FROM" ]; then
    step note "$old" "${NOTE_FROM} -> ${new}: ${body}"
    [ "$APPLY" = 1 ] && { bash "$_here/spool-send.sh" --from "$NOTE_FROM" --to "$new" --kind note --body "$body" >/dev/null \
      || { echo "WARN     ${old}: the note to ${new} was not sent" >&2; rc=1; }; }
  elif [ "$NOTE" = 1 ]; then
    echo "WARN     ${old}: no --note-from / SPOOL_AGENT_ID, so no note; send it: ${body}" >&2
  fi
  done_n=$((done_n + 1))
done
echo "agent-id-rename: ${done_n} agent(s) $([ "$APPLY" = 1 ] && echo renamed || echo 'would be renamed') (desks: ${DESK_ENVS:-none})"
exit "$rc"
