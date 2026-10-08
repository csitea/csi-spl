#!/bin/bash
#------------------------------------------------------------------------------
# @description After a box restart, compare THIS box against the latest
# @description <SPOOL_ROOT>/dispatch/box-restart/<utc>.before written by
# @description do_spl_box_restart_prepare (the drill's steps 4.2 and 4.4 as
# @description one named action): btime changed, each id of the snapshot back
# @description with exactly one agent process, the count of claude processes
# @description started with --resume, the watchdog's last "BOOT ... done" line,
# @description and the ids missing. Prints a table; exit 1 when an id is
# @description missing or doubled (or there is no snapshot). Read-only.
# @param BOX_RESTART_BEFORE (optional) - the snapshot; default the latest .before
# @example ./run -a do_spl_box_restart_check
#------------------------------------------------------------------------------
declare -F spl_brs_agents >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-prepare.func.sh"

do_spl_box_restart_check() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" snap bt0 bt now_ids rc=0 id pid0 n verdict boot
  snap="${BOX_RESTART_BEFORE:-$(find "$root/dispatch/box-restart" -maxdepth 1 -name '*.before' 2>/dev/null | sort | tail -n 1)}"
  [[ -f "$snap" ]] || { do_log "ERROR no snapshot: run do_spl_box_restart_prepare before the restart"; return 1; }
  bt0="$(awk -F'\t' '$1 == "btime" {print $2}' "$snap")"
  bt="$(spl_brs_btime)"
  now_ids="$(spl_brs_agents "$root")"
  do_log "INFO snapshot $snap"
  if [[ -n "$bt" && "$bt" != "$bt0" ]]; then do_log "OK btime changed: $bt0 -> $bt"
  else do_log "WARN btime unchanged ($bt): this box has not rebooted since the snapshot"; fi
  printf '%-8s %-10s %-24s %s\n' id "pid before" "pids now" verdict
  while IFS=$'\t' read -r _ id pid0 _; do
    n="$(awk -F'\t' -v i="$id" '$1 == i' <<<"$now_ids" | grep -c . || true)"
    case "$n" in
      0) verdict="MISSING"; rc=1 ;;
      1) verdict="back" ;;
      *) verdict="DOUBLED ($n processes)"; rc=1 ;;
    esac
    printf '%-8s %-10s %-24s %s\n' "$id" "$pid0" \
      "$(awk -F'\t' -v i="$id" '$1 == i {printf "%s%s", s, $2; s = ","}' <<<"$now_ids")" "$verdict"
  done < <(awk -F'\t' '$1 == "agent"' "$snap")
  do_log "INFO --resume processes: $(spl_brs_ps | awk '$3 == "claude" && / --resume( |$)/' | grep -c . || true)"
  boot="$(grep -E ' BOOT .* done' "$root/dispatch/wd.log" 2>/dev/null | tail -n 1 || true)"
  do_log "INFO watchdog: ${boot:-no BOOT ... done line in $root/dispatch/wd.log}"
  if (( rc == 0 )); then do_log "OK every id of the snapshot is back with one process"
  else do_log "ERROR ids missing: $(spl_brs_check_missing "$snap" "$now_ids")"; fi
  return "$rc"
}

# The snapshot ids with no process now, space-separated ("none" when none).
spl_brs_check_missing() {
  awk -F'\t' -v now="$2" 'BEGIN { n = split(now, l, "\n"); for (k = 1; k <= n; k++) { split(l[k], f, "\t"); up[f[1]] = 1 } }
    $1 == "agent" && !($2 in up) { printf "%s%s", s, $2; s = " "; m = 1 } END { if (!m) printf "none" }' "$1"
}
