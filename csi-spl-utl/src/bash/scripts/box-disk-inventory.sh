#!/bin/bash
# box-disk-inventory.sh - what fills this box's disk OUTSIDE the repos (SPL-2235).
#
# Reads the rows file (cnf/disk-inventory.rows) and prints one markdown table:
# row, size, file count, oldest file date. Plain coded rules, no judgement:
# the rows and their paths are cnf, the numbers are du / find / docker /
# journalctl. Rows may overlap (home-cache holds browser-cache): never sum them.
# Home rows are sizes per DIRECTORY; no file name is ever printed.
#
# With DISK_INV_GROWTH=1 it also appends one line per row to the growth record
# (TSV: day box row bytes count), at most once per day per box, so
# disk-growers.sh can name what grows.
#
#   DISK_INV_ROWS        default <utl>/cnf/disk-inventory.rows
#   DISK_INV_GROWTH      0 (default) | 1  append to the growth record
#   DISK_INV_GROWTH_TSV  default /var/<org>/<org>-<app>/box-disk-sweep/growth.tsv
#   DISK_INV_REPORT      also write the table to this file (mode 0644)
#   DISK_INV_BOX         the box name in the table and the record, default hostname -s
#   DISK_INV_SUDO        auto (default: sudo -n when it works) | 0 | 1
#   DISK_INV_TIMEOUT     seconds per path, default 600 (a timed-out path reads "timeout")
#   DISK_INV_DAY         the record's day (tests), default today UTC
#   DISK_INV_DOCKER / DISK_INV_JOURNALCTL   the binaries (tests)
#
# Exit: 0 table printed; 2 usage.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UTL="$(cd "$SELF/../../.." && pwd)"
oa="$(basename "$UTL")"; oa="${oa%-utl}"

rows_file="${DISK_INV_ROWS:-$UTL/cnf/disk-inventory.rows}"
growth="${DISK_INV_GROWTH:-0}"
tsv="${DISK_INV_GROWTH_TSV:-/var/${oa%%-*}/$oa/box-disk-sweep/growth.tsv}"
box="${DISK_INV_BOX:-$(hostname -s 2>/dev/null)}"
tmo="${DISK_INV_TIMEOUT:-600}"
day="${DISK_INV_DAY:-$(date -u +%F)}"
docker_bin="${DISK_INV_DOCKER:-docker}"
jctl_bin="${DISK_INV_JOURNALCTL:-journalctl}"

[[ -r "$rows_file" ]] || { echo "FATAL the rows file $rows_file is not readable" >&2; exit 2; }
[[ "$growth" == 0 || "$growth" == 1 ]] || { echo "FATAL DISK_INV_GROWTH must be 0 or 1, got '$growth'" >&2; exit 2; }
[[ "$tmo" =~ ^[0-9]+$ ]] || { echo "FATAL DISK_INV_TIMEOUT must be seconds, got '$tmo'" >&2; exit 2; }

sudo_cmd=()
case "${DISK_INV_SUDO:-auto}" in
  1) sudo_cmd=(sudo -n) ;;
  auto) (( EUID != 0 )) && sudo -n true 2>/dev/null && sudo_cmd=(sudo -n) ;;
esac

# out: name<TAB>bytes<TAB>count<TAB>oldest<TAB>note, one per table row
out=()
add() { out+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"${5:-}"); }

# to_bytes <docker size, e.g. 116.3GB / 25.24MB / 0B>
to_bytes() {
  awk -v s="$1" 'BEGIN{ n=s+0; u=s; sub(/^[0-9.]+/,"",u)
    m=1; if(u=="kB"||u=="KB")m=1e3; else if(u=="MB")m=1e6; else if(u=="GB")m=1e9; else if(u=="TB")m=1e12
    printf "%.0f", n*m }'
}

# si_bytes <bytes>: 17kB / 1.5MB / 0B on every box. coreutils numfmt --to=si
# printed the kilo prefix as "K" up to 9.4 (Ubuntu 24.04) and as "k" from 9.5
# (Debian 13), so the same disk read "17KB" or "17kB" by box.
si_bytes() { numfmt --to=si --suffix=B "$1" | sed 's/K\(B\)$/k\1/'; }

# expand_paths <glob...> as the reader (sudo): a home this user cannot list is
# still matched. Prints one existing path per line.
expand_paths() {
  "${sudo_cmd[@]}" bash -c 'shopt -s nullglob; for g in "$@"; do for m in $g; do [ -e "$m" ] && printf "%s\n" "$m"; done; done' _ "$@"
}

row_dir() {
  local name="$1" p bytes=0 count=0 oldest="" n=0 note="" b r
  shift
  local found=()
  mapfile -t found < <(expand_paths "$@")
  for p in "${found[@]}"; do
    n=$((n + 1))
    b="$(timeout "$tmo" "${sudo_cmd[@]}" du -sx --block-size=1 "$p" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ "$b" =~ ^[0-9]+$ ]] || { note+=" timeout:$p"; continue; }
    bytes=$((bytes + b))
    # count + oldest mtime in one pass; only numbers leave find, never a name
    r="$(timeout "$tmo" "${sudo_cmd[@]}" find "$p" -xdev -type f -printf '%T@\n' 2>/dev/null |
      awk 'NR==1||$1<m{m=$1} END{printf "%d %d", NR, m}')"
    count=$((count + ${r%% *}))
    r="${r##* }"
    (( r > 0 )) && { [[ -z "$oldest" ]] || (( r < oldest )); } && oldest="$r"
  done
  (( n == 0 )) && { add "$name" 0 0 - absent; return; }
  [[ -n "$oldest" ]] && oldest="$(date -u -d "@$oldest" +%F)"
  add "$name" "$bytes" "$count" "${oldest:--}" "${note# }"
}

row_journald() {
  local s b
  command -v "$jctl_bin" >/dev/null 2>&1 || { add "$1" 0 0 - absent; return; }
  s="$("${sudo_cmd[@]}" "$jctl_bin" --disk-usage 2>/dev/null | grep -oE '[0-9][0-9.]*[KMGT]?' | tail -n 1)"
  [[ -n "$s" ]] || { add "$1" 0 0 - "journalctl gave no size"; return; }
  b="$(numfmt --from=iec "$s" 2>/dev/null || echo 0)"
  local oldest
  oldest="$("${sudo_cmd[@]}" "$jctl_bin" -q --no-pager -o short-iso 2>/dev/null | head -n 1 | cut -c1-10)"  # sigpipe-ok: the first line of a 500MB journal; only the output is read, never the status
  local files
  files="$("${sudo_cmd[@]}" find /var/log/journal /run/log/journal -name '*.journal*' 2>/dev/null | wc -l)"
  local cap
  cap="$("${sudo_cmd[@]}" bash -c 'grep -hE "^[[:space:]]*SystemMaxUse=" /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null' | tail -n 1 | tr -d ' ')"
  add "$1" "$b" "$files" "${oldest:--}" "${cap:-SystemMaxUse unset (journald default: 10% of the fs, at most 4G)}"
}

row_docker() {
  local t n s r line oldest=""
  command -v "$docker_bin" >/dev/null 2>&1 || { add "$1" 0 0 - absent; return; }
  local df
  df="$(timeout "$tmo" "$docker_bin" system df --format '{{.Type}}|{{.TotalCount}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)" ||
    { add "$1" 0 0 - "docker system df failed"; return; }
  while IFS='|' read -r t n s r; do
    [[ -n "$t" ]] || continue
    oldest=-
    case "$t" in
      Images) line=images
        oldest="$("$docker_bin" images --format '{{.CreatedAt}}' 2>/dev/null | cut -c1-10 | sort | sed -n 1p)" ;;
      Containers) line=containers
        oldest="$("$docker_bin" ps -a --format '{{.CreatedAt}}' 2>/dev/null | cut -c1-10 | sort | sed -n 1p)" ;;
      "Local Volumes") line=volumes ;;
      "Build Cache") line=build-cache ;;
      *) line="${t,,}"; line="${line// /-}" ;;
    esac
    add "$1-$line" "$(to_bytes "$s")" "$n" "${oldest:--}" "reclaimable $r"
  done <<<"$df"
}

row_snapshot() {
  local found=0 c lines
  if [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == btrfs ]] && command -v btrfs >/dev/null 2>&1; then
    found=1
    c="$("${sudo_cmd[@]}" btrfs subvolume list -s / 2>/dev/null | wc -l)"
    add "$1-btrfs" 0 "$c" - "size needs qgroups; count only"
  fi
  if command -v lvs >/dev/null 2>&1; then
    found=1
    lines="$("${sudo_cmd[@]}" lvs --noheadings --units b --nosuffix -o lv_size,origin 2>/dev/null | awk '$2!=""')"
    add "$1-lvm" "$(awk '{s+=$1} END{printf "%d", s}' <<<"$lines")" "$(grep -c . <<<"$lines")" -
  fi
  if command -v snapper >/dev/null 2>&1; then
    found=1
    add "$1-snapper" 0 "$("${sudo_cmd[@]}" snapper --no-headers list 2>/dev/null | grep -vc '^ *0 ')" - "size not reported by snapper"
  fi
  if [[ -d /timeshift/snapshots ]]; then
    found=1
    row_dir "$1-timeshift" /timeshift/snapshots
  fi
  (( found )) || add "$1" 0 0 - "none: fs $(findmnt -no FSTYPE / 2>/dev/null), no btrfs/lvm/snapper/timeshift"
}

while IFS='|' read -r name kind paths; do
  name="$(xargs <<<"$name")"; kind="$(xargs <<<"$kind")"
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "FATAL bad row name '$name' in $rows_file" >&2; exit 2; }
  case "$kind" in
    dir)
      # word split on purpose; the globs expand in row_dir, as the reader
      # shellcheck disable=SC2086
      set -f; row_dir "$name" $paths; set +f ;;
    journald) row_journald "$name" ;;
    docker) row_docker "$name" ;;
    snapshot) row_snapshot "$name" ;;
    *) echo "FATAL row '$name': unknown kind '$kind'" >&2; exit 2 ;;
  esac
done < <(grep -v '^[[:space:]]*#' "$rows_file")

table="$(
  printf '| row | size | files | oldest | note |\n|---|---:|---:|---|---|\n'
  for l in "${out[@]}"; do
    IFS=$'\t' read -r n b c o note <<<"$l"
    printf '| %s | %s | %s | %s | %s |\n' "$n" "$(si_bytes "$b")" "$c" "$o" "$note"
  done
)"
printf '%s\n' "$table"
printf '\nbox=%s day=%s rows=%d (rows overlap: never sum them)\n' "$box" "$day" "${#out[@]}"
if [[ -n "${DISK_INV_REPORT:-}" ]]; then
  { printf '# disk inventory %s, %s\n\n%s\n' "$box" "$day" "$table"; } >"$DISK_INV_REPORT" && chmod 0644 "$DISK_INV_REPORT"
fi

if [[ "$growth" == 1 ]]; then
  mkdir -p "$(dirname "$tsv")" || { echo "FATAL cannot create $(dirname "$tsv")" >&2; exit 1; }
  if [[ -r "$tsv" ]] && awk -F'\t' -v d="$day" -v b="$box" '$1==d && $2==b {f=1} END{exit !f}' "$tsv"; then
    echo "SKIP the growth record has $day for $box already: $tsv"
  else
    for l in "${out[@]}"; do
      IFS=$'\t' read -r n b c _ <<<"$l"
      printf '%s\t%s\t%s\t%s\t%s\n' "$day" "$box" "$n" "$b" "$c"
    done >>"$tsv"
    echo "OK appended ${#out[@]} rows for $day to $tsv"
  fi
fi
exit 0
