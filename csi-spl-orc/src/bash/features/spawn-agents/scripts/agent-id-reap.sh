#!/usr/bin/env bash
# agent-id-reap.sh — the dead-agent reaper (specs/061 §3.6): an agent dead for
# longer than SPOOL_ID_REAP_H hours (default 6) is retired by agent-id-retire.sh,
# exactly as /exit-clean retires it, so a crashed or killed agent does not hold
# its number for ever. Run from cron (do_spl_agent_id_reap_install_cron) and by
# hand with ./run -a do_spl_agent_id_reap.
#
# The candidates are every id this machine holds: a spool dir, a registry.tsv
# row, an identity record (agents/<ID>.json). Role ids (001-003) never are.
#
#   alive   a tmux window carries the id, or its identity record proves a live
#           process (ai_alive_fast). Alive drops the id's dead-since stamp.
#   dead    neither. Dead since: the record's updated_at when the record says
#           alive=false (the pass that flipped it), else the first tick of THIS
#           reaper that saw it dead ($SPOOL_ROOT/.reap/dead-since.tsv).
#   reaped  dead for SPOOL_ID_REAP_H hours or more: agent-id-retire.sh <ID>
#           (with --apply only under --apply / DRY_RUN=0).
#   skipped an id the watchdog holds out (<spool root>/dispatch/wd/<ID>.heldout:
#           its restarts wait for the admin, spec 102 6.1), or whose id lock
#           (spec 102 4.2) another actor holds. The reaper holds each id lock
#           it retires under until it exits; a retire is one rotate.log line
#           (run id <ts>-reap-<ID>).
#
# Never on a blind view: when tmux cannot be asked, nothing is decided. When
# the previous tick is older than SPOOL_ID_REAP_GAP_MIN (default 60) minutes -
# the box was off, or cron was - every reaper stamp is dropped and the clock
# starts again, so a reboot whose restore is still running reaps nobody.
# The dry run retires nothing; it keeps only the reaper's own clock
# ($SPOOL_ROOT/.reap/), so a dry-run cron reports the same REAP lines a live
# one would act on.
#
# Usage:
#   agent-id-reap.sh [--apply]      # without --apply (and DRY_RUN unset/1): PLAN only
#
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET, SPOOL_NOW (the clock), SPOOL_ID_REAP_H,
# SPOOL_ID_REAP_GAP_MIN, DRY_RUN=0|1 (0 = --apply), RETIRE_LANE (passed on).
# One line per decision on stdout: PLAN|REAP / KEEP / SKIP, each with its reason.
# Exit 0 done (a refused retire is a SKIP line, not a failure), 1 tmux could
# not be asked or another reap holds the lock, 2 usage.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=../lib/agent-identity.inc.sh
. "$_here/../lib/agent-identity.inc.sh"
# shellcheck source=../../../run/spl-rotate-lib.func.sh
declare -F spl_agent_id_lock >/dev/null || . "$_here/../../../run/spl-rotate-lib.func.sh"

APPLY=0
[ "${DRY_RUN:-1}" = 0 ] && APPLY=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) echo "agent-id-reap: unknown argument: $1" >&2; exit 2 ;;
  esac
done
REAP_H="${SPOOL_ID_REAP_H:-6}"
GAP_MIN="${SPOOL_ID_REAP_GAP_MIN:-60}"
[[ "$REAP_H" =~ ^[0-9]+$ ]] && [ "$REAP_H" -ge 1 ] || { echo "agent-id-reap: SPOOL_ID_REAP_H must be whole hours >= 1, got '$REAP_H'" >&2; exit 2; }
[[ "$GAP_MIN" =~ ^[0-9]+$ ]] && [ "$GAP_MIN" -ge 1 ] || { echo "agent-id-reap: SPOOL_ID_REAP_GAP_MIN must be minutes >= 1, got '$GAP_MIN'" >&2; exit 2; }

R="$SPOOL_ROOT"
NOW=""; spl_now_var NOW
now_s="$(date -u -d "$NOW" +%s)"
say() { printf '%s %s\n' "$NOW" "$*"; }
mode="dry run"; VERB=PLAN
[ "$APPLY" = 1 ] && { mode=apply; VERB=REAP; }

mkdir -p "$R/.reap" 2>/dev/null || { echo "agent-id-reap: cannot create $R/.reap" >&2; exit 1; }
exec 8>>"$R/.reap/lock"
flock -n 8 || { say "SKIP another reap holds $R/.reap/lock"; exit 1; }

# ---- the view: every window name, or nothing is decided ----------------------
spool_tmux_argv
if ! wins="$("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null)"; then
  say "SKIP tmux on ${SPOOL_TMUX_SOCKET} could not be asked: nothing decided, no stamp written"
  exit 1
fi
# The allocator's and agent-id-retire.sh's loose token scan.
has_window() { grep -qE "(^|[^A-Za-z0-9])$1([^0-9]|\$)" <<<"$wins"; }

# ---- the reaper's own clock: a gap drops every stamp ----------------------------
STAMPS="$R/.reap/dead-since.tsv"; TICK="$R/.reap/last-tick"
last=""; [ -r "$TICK" ] && last="$(cat "$TICK")"
declare -A seen=()
if [[ "$last" =~ ^[0-9]+$ ]] && [ $((now_s - last)) -gt $((GAP_MIN * 60)) ]; then
  say "INFO the previous tick was $(( (now_s - last) / 60 )) min ago (> ${GAP_MIN}): every dead-since stamp starts again"
elif [ -r "$STAMPS" ]; then
  while IFS=$'\t' read -r k v; do [ -n "$k" ] && seen[$k]="$v"; done <"$STAMPS"
fi

# ---- the candidates ----------------------------------------------------------
declare -A cand=()
for p in "$R"/*; do
  [ -d "$p" ] || continue
  n="${p##*/}"; n="${n%%@*}"
  [[ "$n" =~ ^${SPOOL_AGENT_ID_RX}$ ]] && cand[$n]=1
done
if [ -r "$R/registry.tsv" ]; then
  while IFS= read -r n; do
    [[ "$n" =~ ^${SPOOL_AGENT_ID_RX}$ ]] && cand[$n]=1
  done < <(awk -F'\t' '{ k = $1; sub(/^.*: /, "", k); sub(/@.*/, "", k); print k }' "$R/registry.tsv")
fi
for p in "$(ai_dir)"/*.json; do
  [ -e "$p" ] || continue
  n="${p##*/}"; n="${n%.json}"
  [[ "$n" =~ ^${SPOOL_AGENT_ID_RX}$ ]] && cand[$n]=1
done

declare -A keep=()
nreap=0
HELD="${WD_STATE_DIR:-$R/dispatch/wd}"
say "START reap (${mode}): ${#cand[@]} id(s), reaped after ${REAP_H} h dead"
for id in $(printf '%s\n' "${!cand[@]}" | sort); do
  case "${id#*-}" in 1|01|001|2|02|002|3|03|003) continue ;; esac
  has_window "$id" && continue
  if ai_alive_fast "$id" >/dev/null 2>&1; then
    say "KEEP ${id}: no window, but its record proves a live process"
    continue
  fi
  since=""; src=""
  if ai_load "$id" 2>/dev/null && [ "${AI_REC[alive]:-}" = false ] && [ -n "${AI_REC[updated_at]:-}" ]; then
    since="$(date -u -d "${AI_REC[updated_at]}" +%s 2>/dev/null)"
    src="its record went alive=false at ${AI_REC[updated_at]}"
  fi
  if [ -z "$since" ]; then
    since="${seen[$id]:-$now_s}"
    src="first seen dead by the reaper at $(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ)"
  fi
  keep[$id]="$since"
  age=$((now_s - since))
  if [ "$age" -lt $((REAP_H * 3600)) ]; then
    say "KEEP ${id}: dead $((age / 60)) min (< ${REAP_H} h; ${src})"
    continue
  fi
  if [ -e "$HELD/$id.heldout" ]; then
    say "SKIP ${id}: dead $((age / 3600)) h, but the watchdog holds it out ($HELD/$id.heldout)"
    continue
  fi
  # the id lock: a dry run takes it only where a lifetime dir exists (any
  # holder made one), so it creates no spool dir for an id that has none
  rid="$(date -u -d "$NOW" +%Y%m%dT%H%M%SZ)-reap-$id"
  if { [ "$APPLY" = 1 ] || [ -d "$R/$id/lifetime" ]; } && ! spl_agent_id_lock "$id" do_spl_agent_id_reap "$rid"; then
    say "SKIP ${id}: dead $((age / 3600)) h, but ${SPL_ID_LOCK_WHY}"
    continue
  fi
  args=(); [ "$APPLY" = 1 ] && args=(--apply)
  out="$(bash "$_here/agent-id-retire.sh" "${args[@]}" "$id" 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then
    say "${VERB} ${id}: dead $((age / 3600)) h (>= ${REAP_H} h; ${src})"
    printf '%s\n' "$out" | sed "s/^/${NOW}   /"
    nreap=$((nreap + 1))
    [ "$APPLY" = 1 ] && echo "$(date -u +%FT%TZ) $rid DONE OK retired by the reaper: dead $((age / 3600)) h (${src})" 2>/dev/null >>"$R/dispatch/rotate.log"
    [ "$APPLY" = 1 ] && unset "keep[$id]"
  else
    say "SKIP ${id}: dead $((age / 3600)) h, but agent-id-retire refused (rc ${rc}): $(printf '%s' "$out" | tail -1)"
  fi
done

# The stamps: the ids still dead and held, written whole under the lock.
for id in "${!keep[@]}"; do printf '%s\t%s\n' "$id" "${keep[$id]}"; done | sort >"$STAMPS.tmp" && mv "$STAMPS.tmp" "$STAMPS"
printf '%s\n' "$now_s" >"$TICK"
say "STOP reap (${mode}): ${nreap} $([ "$APPLY" = 1 ] && echo retired || echo 'would be retired')"
exit 0
