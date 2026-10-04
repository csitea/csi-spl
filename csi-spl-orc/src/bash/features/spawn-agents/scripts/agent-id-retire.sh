#!/usr/bin/env bash
# agent-id-retire.sh — retire an agent id on THIS machine, so the allocator
# (next-agent-id.sh) may hand its number out again after the quarantine
# (specs/061 §3.6). Run by the deferred window close of /exit-clean
# (tmux-close-window.sh --retire) and by ./run -a do_spl_agent_id_retire.
#
#   spool dir $SPOOL_ROOT/<ID> (or <ID>@<box> + its link)
#       -> $SPOOL_ROOT/.retired/<ID>.<spawned-utc>/, moved whole. Unread
#          inbox mail stays there; the next holder never sees it.
#   registry.tsv rows of <ID>
#       -> appended to registry.retired.tsv with retired-utc as column 6
#          (the allocator's quarantine reads it). A requester column on the
#          live row is kept after that timestamp, then the row is removed
#          from registry.tsv
#   identity record agents/<ID>.json
#       -> agents/retired/<ID>.<spawned-utc>.json; index.json re-hashed
#   hub lane row -> state done (lane-map.sh done), best effort
#
# Refused: a role id (001-003, CLE-001..003), and an id a tmux window still
# carries (the agent may still be running: closing the window comes first).
# Hub DM and channel history stays as it is.
#
# Usage:
#   agent-id-retire.sh [--apply] <ID>    # without --apply: PLAN lines only
#
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET (the box's), SPOOL_NOW (the clock),
# RETIRE_LANE=0|1 (default 1; 0 under SPOOL_TEST=1).
# Exit 0 retired (or planned), 2 usage / not an agent id / a role id,
# 3 a window still carries the id, 4 nothing on this machine holds the id.
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

APPLY=0; ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    -*) echo "agent-id-retire: unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$ID" ] || { echo "agent-id-retire: one id only" >&2; exit 2; }; ID="$1"; shift ;;
  esac
done
ID="${ID%%@*}"
# The shape, not the write-path rule: a legacy id is retired after the cutoff too.
[[ "$ID" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || { echo "agent-id-retire: '${ID}' is not an agent id" >&2; exit 2; }
case "${ID#*-}" in 1|01|001|2|02|002|3|03|003)
  echo "agent-id-retire: ${ID} is a role id; roles are rotated, never retired" >&2; exit 2 ;; esac

R="$SPOOL_ROOT"
VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO
step() { printf '%s %-9s %s\n' "$VERB" "$1" "$2"; }

# A window that still carries the id: the agent may be alive. Loose token scan,
# as the allocator's rule 4 (a tag before, a badge or title after).
spool_tmux_argv
if "${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null \
    | grep -E "(^|[^A-Za-z0-9])${ID}([^0-9]|\$)" >/dev/null; then
  echo "agent-id-retire: a tmux window still carries ${ID}; close it first (tmux-close-window.sh --agent ${ID} --retire)" >&2
  exit 3
fi

NOW=""; spl_now_var NOW
RETIRED_UTC="$(date -u -d "$NOW" +%Y%m%dT%H%M%SZ)"

# The generation: the spawned-utc of the id's last registry row, else the
# spool dir's mtime, else now.
REG="$R/registry.tsv"
SPAWNED=""
[ -r "$REG" ] && SPAWNED="$(awk -F'\t' -v id="$ID" '{ k = $1; sub(/@.*/, "", k) } k == id && $5 ~ /^[0-9]{8}T[0-9]{6}Z$/ { s = $5 } END { print s }' "$REG")"
DIR=""
if [ -L "$R/$ID" ]; then DIR="$(readlink -f "$R/$ID" 2>/dev/null || true)"
elif [ -d "$R/$ID" ]; then DIR="$R/$ID"; fi
[ -n "$DIR" ] || DIR="$(compgen -G "$R/$ID@*" | head -1 || true)"
[ -z "$SPAWNED" ] && [ -n "$DIR" ] && [ -d "$DIR" ] && SPAWNED="$(date -u -r "$DIR" +%Y%m%dT%H%M%SZ)"
[ -n "$SPAWNED" ] || SPAWNED="$RETIRED_UTC"

held=0

# ---- 1. the spool dir -------------------------------------------------------
if [ -n "$DIR" ] && [ -d "$DIR" ]; then
  held=1
  dst="$R/.retired/${ID}.${SPAWNED}"
  n=1; while [ -e "$dst" ]; do n=$((n + 1)); dst="$R/.retired/${ID}.${SPAWNED}.${n}"; done
  step move "${DIR} -> ${dst}"
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$R/.retired"
    chmod 2775 "$R/.retired" 2>/dev/null || true
    mv "$DIR" "$dst"
  fi
fi
if [ -L "$R/$ID" ]; then
  held=1
  step unlink "$R/$ID"
  [ "$APPLY" = 1 ] && rm -f "$R/$ID"
fi

# ---- 2. the registry rows ---------------------------------------------------
rows=""
[ -r "$REG" ] && rows="$(awk -F'\t' -v id="$ID" '{ k = $1; sub(/@.*/, "", k) } k == id' "$REG")"
if [ -n "$rows" ]; then
  held=1
  step registry "$(printf '%s\n' "$rows" | wc -l) row(s) -> ${R}/registry.retired.tsv, retired ${RETIRED_UTC}"
else
  # No row: one is synthesized, so the quarantine still holds the number.
  rows="$(printf '%s\t%s\t\t\t%s' "$ID" "$(spl_kind_of_agent_id "$ID" || true)" "$SPAWNED")"
  [ "$held" = 1 ] && step registry "no row; a synthesized one -> ${R}/registry.retired.tsv"
fi

# ---- 3. the identity record -------------------------------------------------
if [ -e "$R/agents/${ID}.json" ]; then
  held=1
  step identity "$R/agents/${ID}.json -> $R/agents/retired/${ID}.${SPAWNED}.json, index.json re-hashed"
fi

[ "$held" = 1 ] || { echo "agent-id-retire: nothing on this machine holds ${ID} (${R})" >&2; exit 4; }

if [ "$APPLY" = 1 ]; then
  (
    flock -w 30 9 || { echo "agent-id-retire: ${REG}.lock stayed locked" >&2; exit 1; }
    # retired-utc stays column 6 (next-agent-id.sh and RetiredInQuarantine
    # read that column). A requester on the live row (its column 6) is kept
    # after the timestamp, so the timestamp is not overwritten by it.
    printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' -v t="$RETIRED_UTC" '{
      extra = ""
      if (NF >= 6 && $6 !~ /^[0-9]{8}T[0-9]{6}Z$/) extra = $6
      $6 = t
      if (extra != "") $7 = extra
      print
    }' >>"$R/registry.retired.tsv"
    chmod 0664 "$R/registry.retired.tsv" 2>/dev/null || true
    if [ -r "$REG" ]; then
      # Rewritten in place (same inode): a spawner appending with >> keeps
      # writing into the live file.
      keep="$(awk -F'\t' -v id="$ID" '{ k = $1; sub(/@.*/, "", k) } k != id' "$REG")"
      if [ -n "$keep" ]; then printf '%s\n' "$keep" >"$REG"; else : >"$REG"; fi
    fi
  ) 9>>"$REG.lock"
  if [ -e "$R/agents/${ID}.json" ]; then
    python3 "$_here/agent-identity.py" --dir "$R/agents" retire "$ID" "$SPAWNED" >/dev/null
  fi
fi

# ---- 4. the hub lane row ----------------------------------------------------
lane="${RETIRE_LANE:-}"
[ -n "$lane" ] || { lane=1; [ "${SPOOL_TEST:-}" = 1 ] && lane=0; }
if [ "$lane" = 1 ]; then
  step lane "lane-map.sh done --agent ${ID}"
  [ "$APPLY" = 1 ] && { timeout 60 bash "$_here/lane-map.sh" "done" --agent "$ID" >/dev/null 2>&1 \
    || echo "agent-id-retire: WARN the hub lane row of ${ID} was not closed (lane-map.sh done)" >&2; }
fi
echo "agent-id-retire: ${ID} $([ "$APPLY" = 1 ] && echo retired || echo 'would be retired') at ${RETIRED_UTC} (generation ${SPAWNED}; reusable after ${SPOOL_ID_QUARANTINE_H:-24} h)"
