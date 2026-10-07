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
#   alias row   -> agent-id-aliases.tsv: <ID> -> --successor, else "retired"
#                  (old<TAB>new<TAB>kind<TAB>box<TAB>mapped-utc; every reader
#                  takes only a new-grammar new id, so "retired" maps nothing).
#                  A legacy id keeps a row the map already wrote.
#   desk seats  -> each hub desk of this box that seats <ID> moves the seat
#                  aside (desk-seat-drop.sh): its sidecar stops announcing it
#                  as a member / tag target (owner 2026-10-05, t1 dc6d5e3f)
#   worktree    -> the lane's linked worktree (record's "worktree", else the
#                  registry rundir) and its branch: `worktree remove` +
#                  `branch -d`, ONLY when the tree is clean AND HEAD is an
#                  ancestor of origin/<trunk>; else both stay and one line
#                  says why. Never --force, never -D. The seed prompt's TEAR
#                  DOWN step is the model's to remember, and agy lanes skipped
#                  it (a-526, a-528, a-530 left clean, landed worktrees)
#
# Refused: a role id (001-003, CLE-001..003), and an id a tmux window still
# carries (the agent may still be running: closing the window comes first).
# Hub DM and channel history stays as it is.
#
# Usage:
#   agent-id-retire.sh [--apply] [--successor NEW] <ID>
#     without --apply: PLAN lines only
#     --successor  the new id that takes over (a legacy <ID> only: the alias
#                  table maps legacy -> new, spec 061 section 5)
#
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET (the box's), SPOOL_NOW (the clock),
# SPOOL_DESK_BOX, RETIRE_LANE=0|1 (default 1; 0 under SPOOL_TEST=1),
# RETIRE_DESKS=0|1 (default 1; 0 under SPOOL_TEST=1 unless DESK_STATE_ROOT is
# set), DESK_STATE_ROOT / DESK_ENVS (desk-seat-drop.sh's),
# RETIRE_WORKTREE=0|1 (default 1; 0 under SPOOL_TEST=1).
# Exit 0 retired (or planned), 2 usage / not an agent id / a role id,
# 3 a window still carries the id, 4 nothing on this machine holds the id
# (no spool dir, registry row, record or desk seat).
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=/dev/null
. "$_here/../../../../../lib/bash/funcs/spl-desk-box.func.sh"

APPLY=0; ID=""; SUCC=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --successor) [ "$#" -ge 2 ] || { echo "agent-id-retire: --successor needs an id" >&2; exit 2; }; SUCC="${2%%@*}"; shift 2 ;;
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
LEGACY_RX='^(CLE|GRK|AGY|QWN)-[0-9]+$'
if [ -n "$SUCC" ]; then
  [[ "$ID" =~ $LEGACY_RX ]] || { echo "agent-id-retire: --successor maps a legacy id only; ${ID} is retired with no alias" >&2; exit 2; }
  [[ "$SUCC" =~ ^${SPOOL_AGENT_ID_NEW_RX}$ ]] || { echo "agent-id-retire: --successor '${SUCC}' is not a new agent id (c-004)" >&2; exit 2; }
fi
BOX="$(spl_desk_box_default)"
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "agent-id-retire: '$BOX' is not a box id (SPOOL_DESK_BOX)" >&2; exit 2; }

R="$SPOOL_ROOT"
VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO
step() {
  printf '%s %-9s %s\n' "$VERB" "$1" "$2"
}

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

# The lane's worktree, read now: --apply moves the record aside below.
WT=""
[ -r "$R/agents/${ID}.json" ] && WT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("worktree") or "")' "$R/agents/${ID}.json" 2>/dev/null || true)"
[ -n "$WT" ] || WT="$(printf '%s\n' "$rows" | awk -F'\t' '$4 != "" { w = $4 } END { print w }')"

# ---- 4. the desk seats (counted here: a seat alone is a hold) ---------------
desks="${RETIRE_DESKS:-}"
[ -n "$desks" ] || { desks=1; [ "${SPOOL_TEST:-}" = 1 ] && [ -z "${DESK_STATE_ROOT:-}" ] && desks=0; }
DROP=(bash "$_here/desk-seat-drop.sh" --box "$BOX" "$ID")
seated=0
if [ "$desks" = 1 ]; then
  plan="$("${DROP[@]}" 2>&1)" || echo "agent-id-retire: WARN desk seats not read (${plan##*$'\n'}); as the desk owner: $(printf '%q ' "${DROP[@]}")--apply" >&2
  seated="$(grep -c '^PLAN drop' <<<"$plan" || true)"
  [ "$seated" -gt 0 ] && held=1
fi

[ "$held" = 1 ] || { echo "agent-id-retire: nothing on this machine holds ${ID} (${R})" >&2; exit 4; }

# ---- 5. the alias row -------------------------------------------------------
TABLE="$R/agent-id-aliases.tsv"
alias_row=""
if [[ "$ID" =~ $LEGACY_RX ]] && [ -r "$TABLE" ] \
    && awk -F'\t' -v id="$ID" -v b="$BOX" '$1 == id && $4 == b { f = 1 } END { exit !f }' "$TABLE"; then
  step alias "${ID}@${BOX} keeps its row in ${TABLE}"
else
  alias_row="$(printf '%s\t%s\t%s\t%s\t%s' "$ID" "${SUCC:-retired}" "$(spl_kind_of_agent_id "$ID" || true)" "$BOX" "$(date -u -d "$NOW" +%Y-%m-%dT%H:%M:%SZ)")"
  step alias "${ID} -> ${SUCC:-retired} (${BOX}) -> ${TABLE}"
fi

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
  if [ -n "$alias_row" ]; then
    ( flock -w 30 9 || { echo "agent-id-retire: ${TABLE}.lock stayed locked" >&2; exit 1; }
      printf '%s\n' "$alias_row" >>"$TABLE"; chmod 0664 "$TABLE" 2>/dev/null || true
    ) 9>>"$TABLE.lock"
  fi
fi
if [ "$seated" -gt 0 ]; then
  if [ "$APPLY" = 1 ]; then
    "${DROP[@]}" --apply | grep '^DO drop' || echo "agent-id-retire: WARN the desk seats of ${ID} were not dropped" >&2
  else
    grep '^PLAN drop' <<<"$plan"
  fi
fi

# ---- 6. the hub lane row ----------------------------------------------------
lane="${RETIRE_LANE:-}"
[ -n "$lane" ] || { lane=1; [ "${SPOOL_TEST:-}" = 1 ] && lane=0; }
if [ "$lane" = 1 ]; then
  step lane "lane-map.sh done --agent ${ID}"
  [ "$APPLY" = 1 ] && { timeout 60 bash "$_here/lane-map.sh" "done" --agent "$ID" >/dev/null 2>&1 \
    || echo "agent-id-retire: WARN the hub lane row of ${ID} was not closed (lane-map.sh done)" >&2; }
fi
# ---- 7. the lane's worktree + branch ----------------------------------------
# Git runs as the tree's owner (the box user), as every lane's git does.
wt_git() {
  local d="$1" o; shift
  o="$(stat -c %U "$d" 2>/dev/null)" || return 1
  if [ "$o" = "$(id -un)" ]; then GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$d" "$@"
  else timeout 60 sudo -n -u "$o" env GIT_TERMINAL_PROMPT=0 git -C "$d" "$@"; fi
}
wt_keep() {
  echo "agent-id-retire: worktree ${WT} kept: $*" >&2
}
wt_reap() {
  local top gd cdir repo br up
  [ -n "$WT" ] && [ -d "$WT" ] || return 0
  top="$(wt_git "$WT" rev-parse --show-toplevel 2>/dev/null)" || { wt_keep "not a git worktree"; return 0; }
  gd="$(wt_git "$WT" rev-parse --absolute-git-dir 2>/dev/null)"
  cdir="$(wt_git "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$gd" ] && [ -n "$cdir" ] && [ "$gd" != "$cdir" ] || { wt_keep "not a linked worktree (a main checkout is never removed)"; return 0; }
  [ "${top##*/}" = "$ID" ] || { wt_keep "its dir ${top##*/} is not named ${ID}"; return 0; }
  WT="$top"; repo="${cdir%/.git}"
  [ -z "$(wt_git "$WT" status --porcelain --untracked-files=all 2>/dev/null)" ] || { wt_keep "dirty (git status not empty)"; return 0; }
  br="$(wt_git "$WT" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  up="$(wt_git "$WT" rev-parse -q --abbrev-ref '@{u}' 2>/dev/null || true)"
  case "$up" in origin/?*) ;; *) up="$(wt_git "$WT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)" ;; esac
  [ "$APPLY" = 1 ] && { wt_git "$WT" fetch -q origin "${up#origin/}" >/dev/null 2>&1 \
    || echo "agent-id-retire: WARN fetch origin ${up#origin/} failed; checking against the local ${up}" >&2; }
  wt_git "$WT" merge-base --is-ancestor HEAD "$up" 2>/dev/null || { wt_keep "HEAD is not on ${up} (unlanded commits)"; return 0; }
  step worktree "git -C ${repo} worktree remove ${WT}${br:+; branch -d ${br}} (clean, HEAD on ${up})"
  [ "$APPLY" = 1 ] || return 0
  wt_git "$repo" worktree remove "$WT" >/dev/null 2>&1 || { wt_keep "git worktree remove refused"; return 0; }
  [ -z "$br" ] || wt_git "$repo" branch -d "$br" >/dev/null 2>&1 \
    || echo "agent-id-retire: branch ${br} kept: git branch -d refused (not merged into its upstream)" >&2
}
wtr="${RETIRE_WORKTREE:-}"
[ -n "$wtr" ] || { wtr=1; [ "${SPOOL_TEST:-}" = 1 ] && wtr=0; }
[ "$wtr" = 1 ] && wt_reap

echo "agent-id-retire: ${ID} $([ "$APPLY" = 1 ] && echo retired || echo 'would be retired') at ${RETIRED_UTC} (generation ${SPAWNED}; reusable after ${SPOOL_ID_QUARANTINE_H:-24} h)"
