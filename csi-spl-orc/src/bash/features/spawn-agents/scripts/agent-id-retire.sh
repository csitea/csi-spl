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
#   pending     -> $SPOOL_ROOT/.retired/.pending.<ID> while --apply runs: the
#                  generation, the alias row and "registry" once the rows
#                  moved. A run stopped half-way leaves it, and the re-run
#                  finishes from it: the same generation stamp, no second
#                  quarantine row, the alias row (a --successor too) written
#   alias row   -> agent-id-aliases.tsv: <ID> -> --successor, else "retired"
#                  (old<TAB>new<TAB>kind<TAB>box<TAB>mapped-utc; every reader
#                  takes only a new-grammar new id, so "retired" maps nothing).
#                  A legacy id keeps a row the map already wrote.
#   desk seats  -> each hub desk of this box that seats <ID> moves the seat
#                  aside (desk-seat-drop.sh): its sidecar stops announcing it
#                  as a member / tag target (owner 2026-10-05, t1 dc6d5e3f),
#                  and a workspace agent cap (spec 147) counts the seat free
#                  on the next rescan. The desks are the BOX user's (its home,
#                  SPOOL_BOX_HOME), read as that user (sudo -n) when an agent
#                  user retires itself: from its own $HOME it saw no desk and
#                  the seat stayed announced (g-940, prd, 2026-10-14..20)
#   worktree    -> the lane's linked worktree (record's "worktree", else the
#                  registry rundir) and its branch: LISTED in the box's
#                  workdir table ($SPOOL_ROOT/workdirs.tsv, workdir-register.sh),
#                  not removed (owner, t1 37349c9b msg ec060ebc: work may need
#                  a fix after the push). The disk sweep (csi-spl-utl
#                  do_sweep_workdirs) removes it after 24 h when clean, never
#                  --force; the branch only by `branch -d`. A main checkout or
#                  a dir not named for the id is never listed
#   scratch     -> the lane's Claude Code scratch on the /tmp tmpfs
#                  (/tmp/claude-<uid>/<worktree slug>[-*]/, lane-scratch-reap.sh
#                  --list): listed the same way (c-232 left 20 GB there, sat
#                  2026-10-15: the sweep removes it once unheld and 24 h old)
#   var-tmp     -> top-level /var/tmp entries whose name carries the id
#                  (c-272-base, c272-gocache): listed the same way
#
# Refused: a role id (001-003, CLE-001..003), a desk service id
# (SPL_DESK_AGENT_IDS, spl-desk-agents.func.sh: the responder and the ops desk
# run with no tmux window, so a retire would drop the seat they send from and
# the hub refuses them, c-684 on sat-rsp / box-rsp 2026-10-20), and an id a
# tmux window still carries (the agent may still be running: closing the
# window comes first).
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
# set), DESK_STATE_ROOT / DESK_ENVS (desk-seat-drop.sh's; the root defaults
# to the box user's, SPOOL_BOX_HOME = its passwd home),
# RETIRE_WORKTREE=0|1 (default 1; 0 under SPOOL_TEST=1),
# RETIRE_SCRATCH=0|1, RETIRE_VARTMP=0|1 (default 1; 0 under SPOOL_TEST=1),
# RETIRE_VARTMP_ROOT (default /var/tmp), LANE_SCRATCH_* (its), WORKDIR_TABLE
# (workdir-register.sh's).
# Exit 0 retired (or planned), 2 usage / not an agent id / a role id / a desk
# service id (nothing is moved),
# 3 a window still carries the id, 4 nothing on this machine holds the id
# (no spool dir, registry row, record, desk seat or pending retirement).
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=/dev/null
. "$_here/../../../../../lib/bash/funcs/spl-desk-box.func.sh"
# shellcheck source=../../../../../lib/bash/funcs/spl-desk-agents.func.sh
. "$_here/../../../../../lib/bash/funcs/spl-desk-agents.func.sh"

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
case " $SPL_DESK_AGENT_IDS " in *" $ID "*)
  echo "agent-id-retire: ${ID} is a desk service id (SPL_DESK_AGENT_IDS); its desk seats stay, never retired" >&2; exit 2 ;; esac
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

# A retirement stopped half-way (SPL-2408) left its pending file: line 1 the
# generation, line 2 the alias row, then "registry" once the rows moved. The
# re-run keeps that generation (the dir and the rows that dated it are gone).
PEND="$R/.retired/.pending.${ID}"
P_ALIAS=""; P_REG=0
if [ -r "$PEND" ]; then
  held=1
  { IFS= read -r p_gen || true; IFS= read -r P_ALIAS || true; } <"$PEND"
  [[ "${p_gen:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && SPAWNED="$p_gen"
  grep -qx registry "$PEND" && P_REG=1
fi

# The alias row, made now: the pending file carries it from the first change on.
TABLE="$R/agent-id-aliases.tsv"
alias_row=""; alias_kept=0
if [[ "$ID" =~ $LEGACY_RX ]] && [ -r "$TABLE" ] \
    && awk -F'\t' -v id="$ID" -v b="$BOX" '$1 == id && $4 == b { f = 1 } END { exit !f }' "$TABLE"; then
  alias_kept=1
elif [ -n "$P_ALIAS" ] && [ -z "$SUCC" ]; then
  alias_row="$P_ALIAS"
else
  alias_row="$(printf '%s\t%s\t%s\t%s\t%s' "$ID" "${SUCC:-retired}" "$(spl_kind_of_agent_id "$ID" || true)" "$BOX" "$(date -u -d "$NOW" +%Y-%m-%dT%H:%M:%SZ)")"
fi
pend_open() {  # written once, before the first change
  [ "$APPLY" = 1 ] && [ ! -e "$PEND" ] || return 0
  mkdir -p "$R/.retired"
  chmod 2775 "$R/.retired" 2>/dev/null || true
  printf '%s\n%s\n' "$SPAWNED" "$alias_row" >"$PEND"
}

# ---- 1. the spool dir -------------------------------------------------------
if [ -n "$DIR" ] && [ -d "$DIR" ]; then
  held=1
  dst="$R/.retired/${ID}.${SPAWNED}"
  n=1; while [ -e "$dst" ]; do n=$((n + 1)); dst="$R/.retired/${ID}.${SPAWNED}.${n}"; done
  step move "${DIR} -> ${dst}"
  if [ "$APPLY" = 1 ]; then
    pend_open
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
elif [ "$P_REG" = 1 ]; then
  step registry "moved by the stopped run; no second quarantine row"
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
BOX_HOME="${SPOOL_BOX_HOME:-$(getent passwd "$SPOOL_BOX_USER" 2>/dev/null | cut -d: -f6)}"
DROP=(env DESK_STATE_ROOT="${DESK_STATE_ROOT:-${BOX_HOME:-$HOME}/.local/share/csi-spl/cloud}"
  DESK_ENVS="${DESK_ENVS:-dev prd}" ${DESK_TENANT:+DESK_TENANT="$DESK_TENANT"} SPOOL_NOW="$NOW"
  bash "$_here/desk-seat-drop.sh" --box "$BOX" "$ID")
[ "$(id -un)" = "$SPOOL_BOX_USER" ] || DROP=(sudo -n -u "$SPOOL_BOX_USER" "${DROP[@]}")
seated=0
if [ "$desks" = 1 ]; then
  plan="$("${DROP[@]}" 2>&1)" || echo "agent-id-retire: WARN desk seats not read (${plan##*$'\n'}); as the desk owner: $(printf '%q ' "${DROP[@]}")--apply" >&2
  seated="$(grep -c '^PLAN drop' <<<"$plan" || true)"
  [ "$seated" -gt 0 ] && held=1
fi

[ "$held" = 1 ] || { echo "agent-id-retire: nothing on this machine holds ${ID} (${R})" >&2; exit 4; }

# ---- 5. the alias row -------------------------------------------------------
if [ "$alias_kept" = 1 ]; then
  step alias "${ID}@${BOX} keeps its row in ${TABLE}"
else
  step alias "${ID} -> $(cut -f2 <<<"$alias_row") (${BOX}) -> ${TABLE}"
fi

if [ "$APPLY" = 1 ]; then
  pend_open
  # Rows the stopped run already moved are not quarantined twice.
  [ "$P_REG" = 1 ] && [ -z "$rows" ] || (
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
  grep -qx registry "$PEND" || echo registry >>"$PEND"
  if [ -e "$R/agents/${ID}.json" ]; then
    python3 "$_here/agent-identity.py" --dir "$R/agents" retire "$ID" "$SPAWNED" >/dev/null
  fi
  if [ -n "$alias_row" ]; then
    ( flock -w 30 9 || { echo "agent-id-retire: ${TABLE}.lock stayed locked" >&2; exit 1; }
      printf '%s\n' "$alias_row" >>"$TABLE"; chmod 0664 "$TABLE" 2>/dev/null || true
    ) 9>>"$TABLE.lock"
  fi
  rm -f "$PEND"
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
# ---- 7..9. the lane's working directories: listed, not removed --------------
# Owner HUM-10, t1 37349c9b msg ec060ebc (2026-10-16): a finished lane keeps its
# work for a while ("something might happen after the push, and the work needs
# to be fixed"). Its worktree (+ branch), /tmp scratch and /var/tmp leftovers
# go into the box's table (workdir-register.sh, $SPOOL_ROOT/workdirs.tsv); the
# disk guard (csi-spl-utl do_sweep_workdirs, from the box disk sweep) removes
# them after 24 h. The allocator holds the id while a row names it.
REGW=(bash "$_here/workdir-register.sh")
listed() {  # KIND PATH [BRANCH]
  step "$1" "list ${2}${3:+ (branch ${3})} in ${WORKDIR_TABLE:-${R}/workdirs.tsv} for the disk sweep (removed after 24 h)"
  [ "$APPLY" = 1 ] || return 0
  "${REGW[@]}" add --kind "$1" --agent "$ID" --box "$BOX" ${3:+--branch "$3"} "$2" >/dev/null \
    || echo "agent-id-retire: WARN ${2} was not listed in the workdir table (workdir-register.sh rc $?)" >&2
}
# Git runs as the tree's owner (the box user), as every lane's git does.
wt_git() {
  local d="$1" o; shift
  o="$(stat -c %U "$d" 2>/dev/null)" || return 1
  if [ "$o" = "$(id -un)" ]; then GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$d" "$@"
  else timeout 60 sudo -n -u "$o" env GIT_TERMINAL_PROMPT=0 git -C "$d" "$@"; fi
}
wt_keep() {
  echo "agent-id-retire: worktree ${WT} not listed: $*" >&2
}
wt_list() {
  local top gd cdir br
  [ -n "$WT" ] && [ -d "$WT" ] || return 0
  top="$(wt_git "$WT" rev-parse --show-toplevel 2>/dev/null)" || { wt_keep "not a git worktree"; return 0; }
  gd="$(wt_git "$WT" rev-parse --absolute-git-dir 2>/dev/null)"
  cdir="$(wt_git "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$gd" ] && [ -n "$cdir" ] && [ "$gd" != "$cdir" ] || { wt_keep "not a linked worktree (a main checkout is never removed)"; return 0; }
  [ "${top##*/}" = "$ID" ] || { wt_keep "its dir ${top##*/} is not named ${ID}"; return 0; }
  WT="$top"
  br="$(wt_git "$WT" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  listed worktree "$WT" "$br"
}
# off unless 1; default 1, 0 under SPOOL_TEST=1
on() { local v="${1:-}"; [ -n "$v" ] || { v=1; [ "${SPOOL_TEST:-}" = 1 ] && v=0; }; [ "$v" = 1 ]; }
# ---- 7. the lane's worktree + branch ----------------------------------------
on "${RETIRE_WORKTREE:-}" && wt_list
# ---- 8. the lane's /tmp scratch ---------------------------------------------
if on "${RETIRE_SCRATCH:-}" && [ -n "$WT" ]; then
  while IFS= read -r d; do [ -n "$d" ] && listed scratch "$d"; done \
    < <(bash "$_here/lane-scratch-reap.sh" --list "$WT" \
      || echo "agent-id-retire: WARN the /tmp scratch of ${WT} was not read (lane-scratch-reap.sh --list)" >&2)
fi
# ---- 9. the lane's /var/tmp leftovers ---------------------------------------
# A top-level entry whose name carries the id (c-272-base, c272-gocache), not
# a dot entry, a symlink or root's. Kept as live-lane by the vartmp step while
# the lane ran; listed now, so the 24 h clock starts at its finish.
if on "${RETIRE_VARTMP:-}"; then
  vt="${RETIRE_VARTMP_ROOT:-/var/tmp}" num="${ID#*-}" ltr="${ID%%-*}"
  for d in "$vt"/*"${ltr}"*"${num}"*; do
    n="${d##*/}"
    [ -e "$d" ] && [ ! -L "$d" ] && [[ "${n,,}" =~ (^|[^a-z0-9])${ltr,,}-?${num}([^0-9]|$) ]] || continue
    [ "$(stat -c %U -- "$d" 2>/dev/null)" != root ] && listed var-tmp "$d"
  done
fi

echo "agent-id-retire: ${ID} $([ "$APPLY" = 1 ] && echo retired || echo 'would be retired') at ${RETIRED_UTC} (generation ${SPAWNED}; reusable after ${SPOOL_ID_QUARANTINE_H:-24} h)"
