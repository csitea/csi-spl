#!/bin/bash
#------------------------------------------------------------------------------
# @description The hourly role rotation at a glance (spec 060 FR-063, FR-071):
# @description one row per role (orch, master, failover) with its id, live
# @description pid(s), process age, pane state (idle / busy / dialog / stalled)
# @description and the launch flags the session actually carries (from
# @description /proc/<pid>/cmdline, so anyone can see whether owner R4 is in
# @description force); then per role its last rotation id, phase and result,
# @description the last DONE, the last SKIP reason and the next cron slot; the
# @description age of rotate.hold and the switches. Read-only.
# @example ./run -a do_spl_rotate_status
#------------------------------------------------------------------------------
declare -F spl_rotate_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-rotate-lib.func.sh"

do_spl_rotate_status() {
  spl_rotate_conf || return 1
  local role id pids pid age pane state flags last ldone skip next h ht
  printf '%-9s %-14s %-16s %-7s %-9s %s\n' ROLE ID PID AGE PANE FLAGS
  for role in orch master failover; do
    id="$(spl_rotate_role_id "$role")"
    [[ -n "$id" ]] || { printf '%-9s %-14s %s\n' "$role" - "not in $LEASE_CONF"; continue; }
    pids="$(spl_rotate_pids "$id" | tr '\n' ' ' | sed 's/ $//')"
    pid="${pids%% *}"
    age="-" pane="-" state="-" flags="-"
    if [[ -n "$pid" ]]; then
      age="$(spl_rotate_age "$pid")"; age="$(( ${age:-0} / 60 ))m"
      pane="$(spl_rotate_pane_of_pid "$pid")"
      if [[ -n "$pane" ]]; then
        state="$(classify_screen "$(spl_rotate_screen "$pane")")"
        [[ -n "$(spl_rotate_stalled "$pane")" ]] && state=stalled
      fi
      flags="$(tr '\0' ' ' < "${LEASE_PROC_ROOT:-/proc}/$pid/cmdline" 2>/dev/null |
        grep -oE -- '--permission-mode [a-zA-Z]+|--dangerously-skip-permissions|--model [^ ]+' | tr '\n' ' ' || true)"
    fi
    printf '%-9s %-14s %-16s %-7s %-9s %s\n' "$role" "$id@$ROTATE_BOX" "${pids:-none}" "$age" "$state" "${flags:-none}"
  done
  echo
  printf '%-9s %-22s %-10s %-26s %-26s %s\n' ROLE LAST-RID LAST-PHASE LAST-DONE NEXT-SLOT LAST-SKIP
  for role in orch master failover; do
    last="$(awk -v r="-$role" 'substr($2, length($2) - length(r) + 1) == r && $4 != "SKIP" && $4 != "PLAN" {l = $2 " " $3 " " $4} END {print l}' "$ROTATE_LOG" 2>/dev/null || true)"
    ldone="$(awk -v r="-$role" 'substr($2, length($2) - length(r) + 1) == r && $3 == "DONE" {l = $1} END {print l}' "$ROTATE_LOG" 2>/dev/null || true)"
    skip="$(awk -v r="-$role" 'substr($2, length($2) - length(r) + 1) == r && $4 == "SKIP" {l = $0} END {print l}' "$ROTATE_LOG" 2>/dev/null |
      cut -d' ' -f1,5- | cut -c1-90 || true)"
    if [[ "$role" == orch ]]; then next="$(spl_rotate_status_slot 5)"; else next="$(spl_rotate_status_slot 15)"; fi
    printf '%-9s %-22s %-10s %-26s %-26s %s\n' "$role" "${last%% *}" "$(cut -d' ' -f2- <<<"${last:-- -}")" "${ldone:--}" "$next" "${skip:--}"
  done
  echo
  h="$LEASE_DIR/rotate.hold"
  if [[ -s "$h" ]]; then ht="$(stat -c %Y "$h" 2>/dev/null || echo 0)"; echo "rotate.hold: $(cat "$h") ($(( $(date +%s) - ht ))s old)"
  else echo "rotate.hold: none"; fi
  echo "switches: ROTATE=$ROTATE ROTATE_ORCH=$ROTATE_ORCH ROTATE_DISPATCH=$ROTATE_DISPATCH ($([[ -f "$ROTATE_CONF" ]] && echo "$ROTATE_CONF" || echo "no rotate.conf"))"
  echo "cron: $(crontab -l 2>/dev/null | grep -cE '# [a-z0-9-]+:(orch|dispatch)-rotate$' || true) rotation line(s) installed; log $ROTATE_LOG"
  return 0
}

# The next :MM slot (UTC), as an ISO time.
spl_rotate_status_slot() {
  local now m
  now="$(date -u +%s)"; m="$(date -u +%M)"; m=$((10#$m))
  if (( m < $1 )); then date -u -d "@$(( now - (now % 3600) + $1 * 60 ))" +%FT%TZ
  else date -u -d "@$(( now - (now % 3600) + 3600 + $1 * 60 ))" +%FT%TZ; fi
}
