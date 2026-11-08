#!/bin/bash
# disk-crossing-sizes.sh - size the top dirs of one mount, bounded in time, so
# a disk that swings 5-6 GB in 15 min gets a name (SPL-4629). The daily growth
# record (disk-growers.sh) cannot see a swing that comes and goes in a day.
#
# Each top dir of the mount gets one niced `du -x --max-depth=1` under its own
# timeout: an equal share of the budget still left, so one huge dir cannot
# starve the rest. Time the first pass leaves over goes to the dirs that were
# cut, each from the start again. du prints a child as it finishes, so a du that
# is cut still gives a lower bound, and the row says so. A row's state:
#   complete    du finished, bytes is the dir's size
#   partial     reason timeout: bytes is the sum of the children that finished
#               reason du-error: du finished but could not read part of the dir
#               (its child rows are lower bounds too)
#   unmeasured  reason budget: no time left; timeout: cut with no child;
#               du-not-run: du could not start; find-timeout or find-error: the
#               row is the mount itself, its top dirs could not be listed
# Loose files directly in the mount are not sized, only its dirs. A mountpoint
# inside the mount is skipped. The whole run ends within the budget + 2 s: a du
# that ignores TERM gets KILL 2 s after its cut.
#
# One line per top dir, biggest first, then one summary line. With DRY_RUN=0 the
# rows and each dir's biggest children also go to the record, tab separated:
#   utc  box  mount  trigger  level(top|child)  path  bytes  state  reason
#
#   DISK_CROSSING_MOUNT       required, the mount to size
#   DRY_RUN                   1 (default): print only; 0: also append to the record
#   DISK_CROSSING_BUDGET_S    the whole run's budget in seconds, default 60
#   DISK_CROSSING_CHILDREN    biggest children recorded per top dir, default 10
#   DISK_CROSSING_KEEP_LINES  the record keeps its newest lines, default 20000
#   DISK_CROSSING_TRIGGER     what asked for it (the headroom key), default manual
#   DISK_CROSSING_TSV         default /var/<org>/<org>-<app>/disk-crossing-sizes/sizes.tsv
#   DISK_CROSSING_BOX         default the configured box name (spl_box_name)
#   DISK_CROSSING_DU          the du to run (tests), default du
#   DISK_CROSSING_STAT        the stat to run (tests), default stat
#   DISK_CROSSING_FIND        the find to run (tests), default find
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
keep="${DISK_CROSSING_KEEP_LINES:-20000}"
trigger="${DISK_CROSSING_TRIGGER:-manual}"
tsv="${DISK_CROSSING_TSV:-/var/${oa%%-*}/$oa/disk-crossing-sizes/sizes.tsv}"
du_bin="${DISK_CROSSING_DU:-du}"
stat_bin="${DISK_CROSSING_STAT:-stat}"
find_bin="${DISK_CROSSING_FIND:-find}"

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FATAL DRY_RUN must be 0 or 1, got '$dry'" >&2; exit 2; }
[[ -n "$mount" ]] || { say "FATAL DISK_CROSSING_MOUNT must be set" >&2; exit 2; }
[[ "$budget" =~ ^[0-9]+$ && "$children" =~ ^[0-9]+$ && "$keep" =~ ^[0-9]+$ ]] && (( budget >= 1 && keep >= 1 )) ||
  { say "FATAL DISK_CROSSING_BUDGET_S and DISK_CROSSING_KEEP_LINES must be >= 1, DISK_CROSSING_CHILDREN >= 0" >&2; exit 2; }
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
  lock="$(dirname "$tsv")/lock.${mount//\//_}"
  { exec 8>>"$lock"; } 2>/dev/null || { say "FATAL cannot open the lock file $lock" >&2; exit 1; }
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

utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start="$(date +%s)"
deadline=$(( start + budget ))
pre="$utc"$'\t'"$box"$'\t'"$mount"$'\t'"$trigger"

# the top dirs, on the budget's clock
list_cap=$(( budget < 10 ? budget : 10 ))
listing="$(timeout -k 1 "$list_cap" "$find_bin" "$mount" -xdev -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)"
list_rc=$?
found=()
[[ -n "$listing" ]] && mapfile -t found < <(printf '%s\n' "$listing" | sort)
# find -xdev still lists a mountpoint at depth 1 (/proc, /sys): drop those.
# Past the deadline a dir is kept unchecked: it becomes an unmeasured row.
dev="$(timeout 2 "$stat_bin" -c %d -- "$mount" 2>/dev/null)"
tops=()
for d in "${found[@]+"${found[@]}"}"; do
  if (( $(date +%s) < deadline )); then
    if d_dev="$(timeout 2 "$stat_bin" -c %d -- "$d" 2>/dev/null)" && [[ -n "$dev" && "$d_dev" != "$dev" ]]; then continue; fi
  fi
  tops+=("$d")
done

# measure <dir> <dirs left, this one included>: sets bytes, state, reason, kids
measure() {
  local d="$1" left cap out="" rc=0 c_state=complete c_reason=-
  left=$(( deadline - $(date +%s) ))
  bytes=0 kids=""
  if (( left <= 0 )); then state=unmeasured reason=budget; return 0; fi
  cap=$(( left / $2 ))
  (( cap >= 1 )) || cap=1
  out="$(timeout -k 2 "$cap" "${prio[@]}" "$du_bin" -x -B1 --max-depth=1 -- "$d" 2>/dev/null)" || rc=$?
  bytes="$(awk -F'\t' -v top="$d" '$1 ~ /^[0-9]+$/ { if ($2 == top) { t = $1; got = 1 } else s += $1 }
    END { printf "%.0f", got ? t : s + 0 }' <<<"$out")"
  case "$rc" in
    0)           state=complete reason=- ;;
    124|137)     reason=timeout; if [[ -n "$out" ]]; then state=partial; else state=unmeasured; fi ;;
    125|126|127) state=unmeasured reason=du-not-run ;;
    *)           state=partial reason=du-error c_state=partial c_reason=du-error ;;
  esac
  if (( children > 0 )) && [[ -n "$out" ]]; then
    kids="$(awk -F'\t' -v top="$d" '$1 ~ /^[0-9]+$/ && $2 != top' <<<"$out" | sort -t$'\t' -k1,1nr | sed -n "1,${children}p" |
      awk -F'\t' -v OFS='\t' -v pre="$pre" -v s="$c_state" -v r="$c_reason" '{ print pre, "child", $2, $1, s, r }')"
  fi
}

declare -A row=() kid=()
n=${#tops[@]}
retry=()
for (( i = 0; i < n; i++ )); do
  d="${tops[i]}"
  measure "$d" $(( n - i ))
  row["$d"]="$bytes"$'\t'"$state"$'\t'"$reason"; kid["$d"]="$kids"
  [[ "$reason" == timeout || "$reason" == budget ]] && retry+=("$d")
done

# the time the first pass left over: the cut dirs again, keeping the better row
for (( i = 0; i < ${#retry[@]}; i++ )); do
  (( $(date +%s) < deadline )) || break
  d="${retry[i]}"
  old_bytes="${row[$d]%%$'\t'*}"
  measure "$d" $(( ${#retry[@]} - i ))
  if [[ "$state" == complete ]] || (( bytes > old_bytes )); then
    row["$d"]="$bytes"$'\t'"$state"$'\t'"$reason"; kid["$d"]="$kids"
  fi
done

rows="" record="" complete=0
if (( list_rc != 0 )); then
  (( list_rc == 124 || list_rc == 137 )) && list_reason=find-timeout || list_reason=find-error
  rows+="0"$'\t'"$mount"$'\tunmeasured\t'"$list_reason"$'\n'
  record+="$pre"$'\ttop\t'"$mount"$'\t0\tunmeasured\t'"$list_reason"$'\n'
fi
for d in "${tops[@]+"${tops[@]}"}"; do
  IFS=$'\t' read -r bytes state reason <<<"${row[$d]}"
  [[ "$state" == complete ]] && complete=$(( complete + 1 ))
  rows+="$bytes"$'\t'"$d"$'\t'"$state"$'\t'"$reason"$'\n'
  record+="$pre"$'\ttop\t'"$d"$'\t'"$bytes"$'\t'"$state"$'\t'"$reason"$'\n'
  [[ -z "${kid[$d]}" ]] || record+="${kid[$d]}"$'\n'
done

while IFS=$'\t' read -r bytes d state reason; do
  [[ -n "$d" ]] || continue
  printf '%s\t%s\t%s\t%s\n' "$(human "$bytes")" "$d" "$state" "$reason"
done < <(printf '%s' "$rows" | sort -t$'\t' -k1,1nr)

(( list_rc == 0 && n == complete )) && verdict=complete || verdict=partial
summary="sizes $mount: $verdict, $complete of $n dirs complete in $(( $(date +%s) - start ))s (budget ${budget}s)"
if [[ "$dry" == 0 ]]; then
  printf '%s' "$record" >>"$tsv" || { say "FATAL cannot append to $tsv" >&2; exit 1; }
  # the record lives on the disk it measures: keep its newest lines only
  if (( $(wc -l <"$tsv") > keep )); then
    if tail -n "$keep" "$tsv" >"$tsv.tmp" 2>/dev/null; then mv -f "$tsv.tmp" "$tsv"; else rm -f "$tsv.tmp"; fi
  fi
  say "$summary; recorded in $tsv"
else
  say "$summary; dry run, nothing recorded"
fi
exit 0
