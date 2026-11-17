#!/usr/bin/env bash
# disk-top-writers.sh - name the cgroups that wrote the most bytes since the
# last call, from the kernel's cgroup v2 io.stat (wbytes, every device).
# The box disk sweep calls it on every tick, so the delta is per 15 minutes.
#
# Why (SPL-5837, 2026-11-17): / went from 35% free at 20:41Z to 0 at 21:36Z
# and nobody could say who wrote it. The writer was a lane's ad hoc docker
# container: its scope logged "468.4G written to disk" only when it ended at
# 22:08:51Z. io.stat had that number all along.
#
# Usage: disk-top-writers.sh <state file>
#   prints "<MB written> <writer>" per line, the largest first, at most
#   DISK_WRITERS_TOP lines, only writers over DISK_WRITERS_MIN_MB; the state
#   file keeps this call's counters for the next one. The first call (no state)
#   prints nothing: a counter since boot is no rate.
#   A writer is the deepest cgroup that has an io.stat (user.slice holds every
#   login and agent session); docker-<id>.scope is shown as docker:<name>.
#
#   DISK_WRITERS_CGROUP_ROOT  default /sys/fs/cgroup (tests: a planted tree)
#   DISK_WRITERS_TOP          default 3
#   DISK_WRITERS_MIN_MB       default 1024
#   DISK_WRITERS_DOCKER       docker command for the names (default docker;
#                             a failed lookup keeps the short id)
# Exit: 0 (also when there is no cgroup v2 io.stat); 2 usage.
set -uo pipefail

state="${1:-}"
[[ -n "$state" ]] || { echo "usage: disk-top-writers.sh <state file>" >&2; exit 2; }
root="${DISK_WRITERS_CGROUP_ROOT:-/sys/fs/cgroup}"
top="${DISK_WRITERS_TOP:-3}" min_mb="${DISK_WRITERS_MIN_MB:-1024}"
[[ "$top" =~ ^[0-9]+$ && "$min_mb" =~ ^[0-9]+$ ]] || { echo "DISK_WRITERS_TOP and DISK_WRITERS_MIN_MB must be whole numbers" >&2; exit 2; }

# snapshot: "<wbytes> <cgroup path under root>" for each deepest io.stat cgroup
snapshot() {
  local rel
  find "$root" -name io.stat -printf '%h\n' 2>/dev/null | sort | awk -v r="$root" '
    { d[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (i < NR && index(d[i + 1], d[i] "/") == 1) continue
        rel = substr(d[i], length(r) + 2); if (rel == "") continue
        print rel
      }
    }' | while IFS= read -r rel; do
    awk -v c="$rel" '{ for (i = 2; i <= NF; i++) if ($i ~ /^wbytes=/) { sub(/^wbytes=/, "", $i); s += $i } }
      END { printf "%.0f %s\n", s, c }' "$root/$rel/io.stat" 2>/dev/null
  done
}

# label <cgroup path>: docker:<name> (<short id>) for a container scope, else the path
label() {
  local rel="$1" id name
  local -a dk
  if [[ "$rel" =~ docker-([0-9a-f]{12})[0-9a-f]*\.scope$ ]]; then
    id="${BASH_REMATCH[1]}"
    read -ra dk <<<"${DISK_WRITERS_DOCKER:-docker}"
    name="$(timeout 5 "${dk[@]}" inspect --format '{{.Name}}' "$id" 2>/dev/null)"
    name="${name#/}"
    echo "docker:${name:-?} ($id)"; return
  fi
  echo "$rel"
}

now="$(snapshot)"
prev=""
[[ -r "$state" ]] && prev="$(cat "$state")"
{ printf '%s\n' "$now" >"$state.new" && mv -f "$state.new" "$state"; } 2>/dev/null || true
[[ -n "$prev" && -n "$now" ]] || exit 0

# a cgroup new since the last call counts from 0; a counter that went down
# (the cgroup was recreated) counts from 0 too
awk -v min="$min_mb" 'NR == FNR { p[$2] = $1; next }
  { d = $1 - (($2 in p && p[$2] <= $1) ? p[$2] : 0); mb = int(d / 1048576); if (mb >= min) print mb, $2 }' \
  <(printf '%s\n' "$prev") <(printf '%s\n' "$now") | sort -rn | awk -v n="$top" 'NR <= n' | while read -r mb rel; do
  echo "$mb $(label "$rel")"
done
exit 0
