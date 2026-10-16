#!/bin/bash
# disk-growers.sh - the top growers of this box's disk over the last N days,
# from the growth record box-disk-inventory.sh appends daily (SPL-2235).
#
# Plain arithmetic, no judgement: per row, (newest bytes - oldest bytes) /
# days between them, inside the window; the top K rows that grew. One line:
#   top growers 7d: docker-build-cache +12.0GB/d, var-tmp +1.1GB/d, tmp +200MB/d
# or "no growth record (<path>)" / "no row grew in 7d (<n> days recorded)".
# The headroom alert (csi-spl-orc check-disk-headroom.sh) appends this line.
#
#   DISK_GROWERS_TSV   default /var/<org>/<org>-<app>/box-disk-sweep/growth.tsv
#   DISK_GROWERS_BOX   default hostname -s
#   DISK_GROWERS_DAYS  the window, default 7
#   DISK_GROWERS_TOP   how many, default 3
#   DISK_GROWERS_TODAY the window's end day (tests), default today UTC
#
# Exit: 0 always (a missing record is a line, not a failure); 2 usage.
set -uo pipefail

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UTL="$(cd "$SELF/../../.." && pwd)"
oa="$(basename "$UTL")"; oa="${oa%-utl}"

tsv="${DISK_GROWERS_TSV:-/var/${oa%%-*}/$oa/box-disk-sweep/growth.tsv}"
box="${DISK_GROWERS_BOX:-$(hostname -s 2>/dev/null)}"
days="${DISK_GROWERS_DAYS:-7}"
top="${DISK_GROWERS_TOP:-3}"
today="${DISK_GROWERS_TODAY:-$(date -u +%F)}"
[[ "$days" =~ ^[0-9]+$ && "$top" =~ ^[0-9]+$ ]] && (( days >= 1 && top >= 1 )) ||
  { echo "FATAL DISK_GROWERS_DAYS and DISK_GROWERS_TOP must be >= 1" >&2; exit 2; }

[[ -s "$tsv" ]] || { echo "no growth record ($tsv)"; exit 0; }
from="$(date -u -d "$today - $days days" +%F 2>/dev/null)" || { echo "FATAL bad DISK_GROWERS_TODAY '$today'" >&2; exit 2; }

awk -F'\t' -v box="$box" -v from="$from" -v to="$today" -v days="$days" -v top="$top" '
  # days since 1970-01-01 of a YYYY-MM-DD (days_from_civil): no mktime, no TZ
  function dayno(d,   y, m, a, era, yoe, doy) {
    split(d, a, "-"); y = a[1] + 0; m = a[2] + 0; if (m <= 2) y--
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + a[3] - 1
    return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468
  }
  $2 == box && $1 >= from && $1 <= to && $4 ~ /^[0-9]+$/ {
    seen[$1] = 1
    if (!($3 in d0) || $1 < d0[$3]) { d0[$3] = $1; b0[$3] = $4 }
    if (!($3 in d1) || $1 > d1[$3]) { d1[$3] = $1; b1[$3] = $4 }
  }
  function human(b,   u, i) {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1000 && i < 5) { b /= 1000; i++ }
    return sprintf(i == 1 ? "%d%s" : "%.1f%s", b, u[i])
  }
  END {
    ndays = 0; for (k in seen) ndays++
    n = 0
    for (r in d0) {
      span = dayno(d1[r]) - dayno(d0[r])
      if (span < 1) continue
      g = (b1[r] - b0[r]) / span
      if (g > 0) { n++; name[n] = r; rate[n] = g }
    }
    if (ndays == 0) { printf "no growth record for %s in %sd\n", box, days; exit }
    if (n == 0) { printf "no row grew in %sd (%d days recorded)\n", days, ndays; exit }
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
      if (rate[j] > rate[i] || (rate[j] == rate[i] && name[j] < name[i])) {
        t = rate[i]; rate[i] = rate[j]; rate[j] = t; t = name[i]; name[i] = name[j]; name[j] = t }
    line = ""
    for (i = 1; i <= n && i <= top; i++) line = line (i > 1 ? ", " : "") name[i] " +" human(rate[i]) "/d"
    printf "top growers %sd: %s\n", days, line
  }' "$tsv"
