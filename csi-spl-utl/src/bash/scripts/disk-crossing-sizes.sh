#!/bin/bash
# disk-crossing-sizes.sh - size the top dirs of one mount, bounded in time, so
# a disk that swings 5-6 GB in 15 min gets a name (SPL-4629). The daily growth
# record (disk-growers.sh) cannot see a swing that comes and goes in a day.
#
# Each top dir of the mount gets one niced `du -x --max-depth=1` under its own
# timeout: an equal share of the budget still left, so one huge dir cannot
# starve the rest. du prints a child as it finishes, so a du that is cut still
# gives a lower bound, and the row says so. A row's state:
#   complete    du finished, bytes is the dir's size
#   partial     reason timeout: bytes is the sum of the children that finished
#               reason du-error: du finished but could not read part of the dir
#   unmeasured  reason budget: no time left; reason timeout: cut with no child
# Loose files directly in the mount are not sized, only its dirs.
#
# One line per top dir, biggest first, then one summary line. With DRY_RUN=0 the
# rows and each dir's biggest children also go to the record, tab separated:
#   utc  box  mount  trigger  level(top|child)  path  bytes  state  reason
#
#   DISK_CROSSING_MOUNT     required, the mount to size
#   DRY_RUN                 1 (default): print only; 0: also append to the record
#   DISK_CROSSING_BUDGET_S  the whole run's budget in seconds, default 60
#   DISK_CROSSING_CHILDREN  biggest children recorded per top dir, default 10
#   DISK_CROSSING_TRIGGER   what asked for it (the headroom key), default manual
#   DISK_CROSSING_TSV       default /var/<org>/<org>-<app>/disk-crossing-sizes/sizes.tsv
#   DISK_CROSSING_BOX       default the configured box name (spl_box_name)
#   DISK_CROSSING_DU        the du to run (tests), default du
#   DISK_CROSSING_STAT      the stat to run (tests), default stat
#
# Exit: 0 sized, even partly (a partial run is a result), or another run holds
# this mount's lock; 1 the mount or the record is unusable; 2 usage.
set -uo pipefail

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UTL="$(cd "$SELF/../../.." && pwd)"
oa="$(basename "$UTL")"; oa="${oa%-utl}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

dry="${DRY_RUN:-1}"
mount="${DISK_CROSSING_MOUNT:-}"
budget="${DISK_CROSSING_BUDGET_S:-60}"
children="${DISK_CROSSING_CHILDREN:-10}"
trigger="${DISK_CROSSING_TRIGGER:-manual}"
tsv="${DISK_CROSSING_TSV:-/var/${oa%%-*}/$oa/disk-crossing-sizes/sizes.tsv}"
du_bin="${DISK_CROSSING_DU:-du}"
stat_bin="${DISK_CROSSING_STAT:-stat}"

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FATAL DRY_RUN must be 0 or 1, got '$dry'" >&2; exit 2; }
[[ -n "$mount" ]] || { say "FATAL DISK_CROSSING_MOUNT must be set" >&2; exit 2; }
[[ "$budget" =~ ^[0-9]+$ && "$children" =~ ^[0-9]+$ ]] && (( budget >= 1 )) ||
  { say "FATAL DISK_CROSSING_BUDGET_S must be >= 1 and DISK_CROSSING_CHILDREN >= 0" >&2; exit 2; }
[[ "$mount" == / ]] || mount="${mount%/}"
[[ -d "$mount" ]] || { say "FATAL $mount is not a directory" >&2; exit 1; }

if [[ -n "${DISK_CROSSING_BOX:-}" ]]; then
  box="$DISK_CROSSING_BOX"
else
  # spl_box_name: the box name from the config, never the hostname (SPL-4201)
  # shellcheck source=/dev/null
  declare -F spl_box_name >/dev/null || source "$UTL/../${oa}-orc/lib/bash/funcs/spl-desk-box.func.sh"
  box="$(spl_box_name)"
fi

if [[ "$dry" == 0 ]]; then
  mkdir -p "$(dirname "$tsv")" 2>/dev/null && [[ -w "$(dirname "$tsv")" ]] ||
    { say "FATAL cannot write the record's dir $(dirname "$tsv")" >&2; exit 1; }
  # one run per mount: a WARN and a CRITICAL crossing can start together
  exec 8>>"$(dirname "$tsv")/lock.${mount//\//_}"
  flock -n 8 || { say "SKIP another run is sizing $mount"; exit 0; }
fi

prio=(nice -n 19)
command -v ionice >/dev/null 2>&1 && prio=(ionice -c 3 nice -n 19)

human() {
  awk -v b="$1" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }
    printf(i == 1 ? "%d%s" : "%.1f%s", b, u[i])
  }'
}

# find -xdev still lists a mountpoint at depth 1 (/proc, /sys): drop those
mapfile -t found < <(timeout 10 find "$mount" -xdev -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
dev="$("$stat_bin" -c %d -- "$mount")"
tops=()
for d in "${found[@]}"; do
  [[ "$("$stat_bin" -c %d -- "$d" 2>/dev/null)" == "$dev" ]] && tops+=("$d")
done

utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start="$(date +%s)"
deadline=$(( start + budget ))
rows="" record="" complete=0 i=0
for d in "${tops[@]}"; do
  left=$(( deadline - $(date +%s) ))
  dirs_left=$(( ${#tops[@]} - i ))
  i=$(( i + 1 ))
  out="" rc=0 bytes=0
  if (( left <= 0 )); then
    state=unmeasured reason=budget
  else
    cap=$(( left / dirs_left ))
    (( cap >= 1 )) || cap=1
    out="$(timeout -k 2 "$cap" "${prio[@]}" "$du_bin" -x -B1 --max-depth=1 -- "$d" 2>/dev/null)" || rc=$?
    bytes="$(awk -F'\t' -v top="$d" '$1 ~ /^[0-9]+$/ { if ($2 == top) { t = $1; got = 1 } else s += $1 }
      END { printf "%.0f", got ? t : s + 0 }' <<<"$out")"
    case "$rc" in
      0)       state=complete reason=- ;;
      124|137) reason=timeout; if [[ -n "$out" ]]; then state=partial; else state=unmeasured; fi ;;
      *)       state=partial reason=du-error ;;
    esac
  fi
  [[ "$state" == complete ]] && complete=$(( complete + 1 ))
  rows+="$bytes"$'\t'"$d"$'\t'"$state"$'\t'"$reason"$'\n'
  record+="$utc"$'\t'"$box"$'\t'"$mount"$'\t'"$trigger"$'\ttop\t'"$d"$'\t'"$bytes"$'\t'"$state"$'\t'"$reason"$'\n'
  if (( children > 0 )) && [[ -n "$out" ]]; then
    kids="$(awk -F'\t' -v top="$d" '$1 ~ /^[0-9]+$/ && $2 != top' <<<"$out" | sort -t$'\t' -k1,1nr | sed -n "1,${children}p" |
      awk -F'\t' -v OFS='\t' -v pre="$utc"$'\t'"$box"$'\t'"$mount"$'\t'"$trigger" '{ print pre, "child", $2, $1, "complete", "-" }')"
    [[ -z "$kids" ]] || record+="$kids"$'\n'
  fi
done

while IFS=$'\t' read -r bytes d state reason; do
  [[ -n "$d" ]] || continue
  printf '%s\t%s\t%s\t%s\n' "$(human "$bytes")" "$d" "$state" "$reason"
done < <(printf '%s' "$rows" | sort -t$'\t' -k1,1nr)

(( ${#tops[@]} == complete )) && verdict=complete || verdict=partial
summary="sizes $mount: $verdict, $complete of ${#tops[@]} dirs complete in $(( $(date +%s) - start ))s (budget ${budget}s)"
if [[ "$dry" == 0 ]]; then
  printf '%s' "$record" >>"$tsv" || { say "FATAL cannot append to $tsv" >&2; exit 1; }
  say "$summary; recorded in $tsv"
else
  say "$summary; dry run, nothing recorded"
fi
exit 0
