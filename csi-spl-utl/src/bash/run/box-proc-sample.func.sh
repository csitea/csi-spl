#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Per-process CPU and memory sampling of this box (SPL-5698, spec
# @description 175 task 5.9, Refs: SPL-2364). sar showed one box at load 97..150
# @description on 16 CPUs and swap 1 -> 21.7 GB, but sar keeps no per-process
# @description history, so the culprit was not known. Every run (a 5 min cron)
# @description reads /proc and appends to <BOX_PROC_DIR>:
# @description   box-<YYYYMMDD>.tsv  one row per sample: ts box interval_s ncpu
# @description     load1 load5 load15 busy_pct mem_avail_mb swap_used_mb procs
# @description     sampled_pct
# @description   proc-<YYYYMMDD>.tsv the top BOX_PROC_TOP_CPU by CPU and the top
# @description     BOX_PROC_TOP_MEM by RSS + swap: ts box interval_s pid user
# @description     lane own_pct child_pct rss_mb swap_mb comm args
# @description CPU is in core-percent (100 = one core busy for the interval):
# @description busy_pct is the whole box (/proc/stat), sampled_pct the sum of
# @description own_pct over every process alive at both ends; the gap is CPU of
# @description processes born and gone inside the interval. own_pct is the
# @description process's own CPU, child_pct the CPU of its children that ended
# @description inside the interval (their whole life: cutime + cstime). lane is
# @description the first word of the tmux window the process runs under (its
# @description ancestors are walked up to a pane), so an agent's builds and
# @description tests count against its window.
# @description BOX_PROC_CMD=report prints the last BOX_PROC_HOURS: load p50 /
# @description p95 / max and as % of the CPUs, busy, swap, and the top lanes by
# @description core-seconds and by peak RSS + swap. install | check | remove
# @description manage ONE tagged crontab line (`# <org>-<app>:box-proc-sample`).
# @description READ-ONLY on the box: it never kills, renices or changes a
# @description process. A sample writes only its own files (DRY_RUN=0) and
# @description removes its files older than BOX_PROC_KEEP_DAYS; the dry run
# @description prints the rows it would write. The first run only seeds state.
# @param BOX_PROC_CMD (optional) - sample (default) | report | install | check | remove
# @param BOX_PROC_DIR (optional) - default /var/<org>/<org>-<app>/box-proc
# @param BOX_PROC_HOURS (optional) - report window in hours, default 24
# @param BOX_PROC_TOP_CPU (optional) - proc rows kept by CPU per sample, default 25
# @param BOX_PROC_TOP_MEM (optional) - proc rows kept by RSS + swap, default 15
# @param BOX_PROC_KEEP_DAYS (optional) - days of files kept, default 14
# @param BOX_PROC_EVERY (optional) - cron minutes between samples, default 5
# @param BOX_PROC_ROOT (optional) - the proc root (tests), default /proc
# @param BOX_PROC_PANES_CMD (optional) - prints "<pane pid> <window name>" rows,
# @param   default tmux list-panes -a
# @param BOX_PROC_NOW (optional) - epoch seconds override (tests)
# @param BOX_PROC_CRONTAB (optional) - the crontab binary (tests), default crontab
# @param BOX_PROC_DESK_SRC (optional) - the self-updating checkout the cron
# @param   runs, default /opt/<org>/<org>-<app>-desk-cron
# @param DRY_RUN (optional) - 1 (default) prints only; 0 writes the files / crontab
# @example ./run -a do_box_proc_sample
# @example DRY_RUN=0 ./run -a do_box_proc_sample
# @example BOX_PROC_CMD=report BOX_PROC_HOURS=24 ./run -a do_box_proc_sample
# @example BOX_PROC_CMD=install DRY_RUN=0 ./run -a do_box_proc_sample
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# spl_box_name: the box name from the config, never the hostname (SPL-4201)
declare -F spl_box_name >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"

# box_proc_collect <proc root> - one row per process: pid ppid start own child
# rss_pages swap_kb uid comm (own and child in clock ticks)
box_proc_collect() {
  local root="$1" d st rest comm uid sw k v _ f
  for d in "$root"/[0-9]*; do
    { read -r st <"$d/stat"; } 2>/dev/null || continue
    comm="${st#*\(}"; comm="${comm%\)*}"; rest="${st##*\) }"
    read -r -a f <<<"$rest"
    ((${#f[@]} > 21)) || continue
    uid="-" sw=0
    { while read -r k v _; do
        case "$k" in Uid:) uid="$v" ;; VmSwap:) sw="$v"; break ;; esac
      done <"$d/status"; } 2>/dev/null
    comm="${comm//[[:space:]]/_}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${d##*/}" "${f[1]}" "${f[19]}" \
      $((f[11] + f[12])) $((f[13] + f[14])) "${f[21]}" "$sw" "$uid" "${comm:-?}"
  done
}

# box_proc_cpu_ticks <proc root> - "busy total ncpu" from <root>/stat
box_proc_cpu_ticks() {
  awk '$1 == "cpu" { t = 0; for (i = 2; i <= NF; i++) t += $i; b = t - $5 - $6 }
       $1 ~ /^cpu[0-9]+$/ { n++ }
       END { printf "%d %d %d\n", b, t, n }' "$1/stat"
}

# box_proc_lanes - "<pane pid> <first word of the window name>" rows
box_proc_lanes() {
  local cmd="${BOX_PROC_PANES_CMD:-tmux list-panes -a -F '#{pane_pid} #{window_name}'}"
  bash -c "$cmd" 2>/dev/null | awk 'NF >= 2 { print $1, $2 }' || true
}

# box_proc_delta <prev state> <rows> <lanes> <interval> <hz> <page kb> - per
# process: pid uid lane own_pct child_pct rss_mb swap_mb comm; then one line
# "#sum <own_pct sum>"
box_proc_delta() {
  awk -F'\t' -v iv="$4" -v hz="$5" -v pkb="$6" '
    FILENAME == ARGV[1] { if ($1 !~ /^#/) { po[$1 "/" $3] = $4; pc[$1 "/" $3] = $5 } next }
    FILENAME == ARGV[3] { split($0, a, " "); pane[a[1]] = a[2]; next }
    { n++; row[n] = $0; pp[$1] = $2 }
    END {
      for (i = 1; i <= n; i++) {
        split(row[i], r, "\t"); key = r[1] "/" r[3]
        if (key in po) { own = r[4] - po[key]; ch = r[5] - pc[key]; old = 1 } else { own = r[4]; ch = 0; old = 0 }
        if (own < 0) own = 0
        if (ch < 0) ch = 0
        lane = "-"; q = r[1]
        for (h = 0; h < 64 && q != "" && q != "0"; h++) { if (q in pane) { lane = pane[q]; break }; q = pp[q] }
        o = 100 * own / hz / iv; c = 100 * ch / hz / iv
        if (old) sum += o
        printf "%s\t%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%s\n", r[1], r[8], lane, o, c, r[6] * pkb / 1024, r[7] / 1024, r[9]
      }
      printf "#sum\t%.1f\n", sum
    }' "$1" "$2" "$3"
}

# box_proc_top <delta rows> <n cpu> <n mem> - the kept rows, each pid once
box_proc_top() {
  {
    awk -F'\t' '{ printf "%.1f\t%s\n", $4 + $5, $0 }' "$1" | sort -t$'\t' -k1,1gr -k2,2n | awk -v n="$2" 'NR <= n'
    awk -F'\t' '{ printf "%.1f\t%s\n", $6 + $7, $0 }' "$1" | sort -t$'\t' -k1,1gr -k2,2n | awk -v n="$3" 'NR <= n'
  } | cut -f2- | awk -F'\t' '!seen[$1]++'
}

# box_proc_args <proc root> <pid> - the command line, 160 chars, tab-free
box_proc_args() {
  local a
  a="$(tr '\0\t\n' '   ' <"$1/$2/cmdline" 2>/dev/null)"
  a="${a% }"
  printf '%s' "${a:0:160}"
}

# box_proc_user <uid> - the user name, else the uid
box_proc_user() {
  local n
  n="$(getent passwd "$1" 2>/dev/null)"
  n="${n%%:*}"
  printf '%s' "${n:-$1}"
}

# box_proc_box_row <root> <ts> <box> <iv> <busy_pct> <ncpu> <procs> <sum> - the box row
box_proc_box_row() {
  local root="$1" l1 l5 l15 _ mem
  read -r l1 l5 l15 _ <"$root/loadavg"
  mem="$(awk '$1 == "MemAvailable:" { a = $2 } $1 == "SwapTotal:" { t = $2 } $1 == "SwapFree:" { f = $2 }
              END { printf "%d\t%d", a / 1024, (t - f) / 1024 }' "$root/meminfo")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$6" "$l1" "$l5" "$l15" \
    "$5" "$mem" "$7" "$8"
}

# box_proc_state <state file> - "ts busy total" of the previous sample, or nothing
box_proc_state() {
  [[ -r "$1" ]] || return 0
  awk 'NR == 1 && $1 == "#ts" && $2 ~ /^[0-9]+$/ { print $2, $3, $4 } { exit }' "$1"
}

# box_proc_seed <dir> <tmp> <now> <busy> <total> - write the state only
box_proc_seed() {
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    do_log "INFO no previous sample in $1: DRY_RUN=0 would seed it; nothing printed"
    return 0
  fi
  { printf '#ts\t%s\t%s\t%s\n' "$3" "$4" "$5"; cat "$2/rows"; } >"$1/state.tsv.new" &&
    mv -f "$1/state.tsv.new" "$1/state.tsv" || { do_log "FATAL cannot write $1/state.tsv"; return 1; }
  do_log "INFO seeded $1/state.tsv: the next run writes the first sample"
}

# box_proc_rows <tmp> <root> <ts> <box> <iv> - the proc rows of the kept processes
box_proc_rows() {
  local pid uid lane own ch rss sw comm
  while IFS=$'\t' read -r pid uid lane own ch rss sw comm; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$pid" \
      "$(box_proc_user "$uid")" "$lane" "$own" "$ch" "$rss" "$sw" "$comm" "$(box_proc_args "$2" "$pid")"
  done <"$1/top"
}

# box_proc_write <dir> <tmp> <day> <now> <busy> <total> - append the sample,
# replace the state, drop old files
box_proc_write() {
  local dir="$1" tmp="$2"
  cat "$tmp/box" >>"$dir/box-$3.tsv" && cat "$tmp/proc" >>"$dir/proc-$3.tsv" ||
    { do_log "FATAL cannot append to $dir"; return 1; }
  { printf '#ts\t%s\t%s\t%s\n' "$4" "$5" "$6"; cat "$tmp/rows"; } >"$dir/state.tsv.new" &&
    mv -f "$dir/state.tsv.new" "$dir/state.tsv" || { do_log "FATAL cannot write $dir/state.tsv"; return 1; }
  find "$dir" -maxdepth 1 -type f \( -name 'box-*.tsv' -o -name 'proc-*.tsv' \) \
    -mtime "+${BOX_PROC_KEEP_DAYS:-14}" -delete 2>/dev/null || true
}

# box_proc_sample <dir> - one sample (see the header)
box_proc_sample() {
  local dir="$1" root="${BOX_PROC_ROOT:-/proc}" now hz pkb tmp prev busy total ncpu pts pb pt iv rc=0
  now="${BOX_PROC_NOW:-$(date +%s)}"
  hz="$(getconf CLK_TCK)"; pkb=$(($(getconf PAGESIZE) / 1024))
  [[ -r "$root/stat" ]] || { do_log "FATAL $root/stat is not readable"; return 1; }
  [[ "${DRY_RUN:-1}" == 1 ]] || mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
  tmp="$(mktemp -d)" || return 1
  box_proc_collect "$root" >"$tmp/rows"
  read -r busy total ncpu < <(box_proc_cpu_ticks "$root")
  prev="$(box_proc_state "$dir/state.tsv")"
  read -r pts pb pt <<<"$prev"
  iv=$((now - ${pts:-now}))
  if [[ -z "$prev" ]] || ((iv <= 0 || total <= pt)); then
    box_proc_seed "$dir" "$tmp" "$now" "$busy" "$total" || rc=1
    rm -rf "$tmp"; return "$rc"
  fi
  box_proc_lanes >"$tmp/lanes"
  box_proc_delta "$dir/state.tsv" "$tmp/rows" "$tmp/lanes" "$iv" "$hz" "$pkb" >"$tmp/delta"
  grep -v '^#sum' "$tmp/delta" >"$tmp/procs"
  box_proc_top "$tmp/procs" "${BOX_PROC_TOP_CPU:-25}" "${BOX_PROC_TOP_MEM:-15}" >"$tmp/top"
  local ts box day busy_pct sum
  ts="$(date -u -d "@$now" +%FT%TZ)"; day="$(date -u -d "@$now" +%Y%m%d)"; box="$(spl_box_name)"
  busy_pct="$(awk -v b=$((busy - pb)) -v t=$((total - pt)) -v n="$ncpu" 'BEGIN { printf "%.1f", 100 * n * b / t }')"
  sum="$(awk -F'\t' '$1 == "#sum" { print $2 }' "$tmp/delta")"
  box_proc_box_row "$root" "$ts" "$box" "$iv" "$busy_pct" "$ncpu" "$(wc -l <"$tmp/rows")" "${sum:-0}" >"$tmp/box"
  box_proc_rows "$tmp" "$root" "$ts" "$box" "$iv" >"$tmp/proc"
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    cat "$tmp/box" "$tmp/proc"
    do_log "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0."
  else
    box_proc_write "$dir" "$tmp" "$day" "$now" "$busy" "$total" || rc=1
  fi
  rm -rf "$tmp"; return "$rc"
}

# box_proc_pct <file> <column> - "p50 p95 max" of a numeric column
box_proc_pct() {
  cut -f"$2" "$1" | sort -g | awk '{ v[NR] = $1 }
    END { if (!NR) { print "- - -"; exit }
          i = int(NR * 0.5 + 0.5); j = int(NR * 0.95 + 0.5); if (i < 1) i = 1; if (j < 1) j = 1
          print v[i], v[j], v[NR] }'
}

# box_proc_report <dir> - the last BOX_PROC_HOURS (see the header)
box_proc_report() {
  local dir="$1" hours="${BOX_PROC_HOURS:-24}" now since tmp f
  [[ "$hours" =~ ^[0-9]+$ ]] && ((hours > 0)) || { do_log "FATAL BOX_PROC_HOURS must be a whole number > 0, got: '$hours'"; return 1; }
  now="${BOX_PROC_NOW:-$(date +%s)}"
  since="$(date -u -d "@$((now - hours * 3600))" +%FT%TZ)"
  tmp="$(mktemp -d)" || return 1
  for f in "$dir"/box-*.tsv; do [[ -e "$f" ]] && awk -F'\t' -v s="$since" '$1 >= s' "$f"; done >"$tmp/box"
  for f in "$dir"/proc-*.tsv; do [[ -e "$f" ]] && awk -F'\t' -v s="$since" '$1 >= s' "$f"; done >"$tmp/proc"
  if [[ ! -s "$tmp/box" ]]; then
    do_log "FAIL no sample in $dir since $since"; rm -rf "$tmp"; return 1
  fi
  box_proc_report_box "$tmp/box" "$hours"
  box_proc_report_lanes "$tmp/proc"
  rm -rf "$tmp"
}

# box_proc_report_box <box rows> <hours> - the box lines of the report
box_proc_report_box() {
  local n first last box ncpu l b
  read -r n first last box ncpu < <(awk -F'\t' 'NR == 1 || $1 < lo { lo = $1 } NR == 1 || $1 > hi { hi = $1 }
    { b = $2; c = $4 } END { print NR, lo, hi, b, c }' "$1")
  l="$(box_proc_pct "$1" 5)"; b="$(box_proc_pct "$1" 8)"
  echo "box-proc $box window=${2}h samples=$n first=$first last=$last ncpu=$ncpu"
  awk -v l="$l" -v n="$ncpu" 'BEGIN { split(l, a, " "); printf "load1 p50=%s p95=%s max=%s (p95 = %.0f%% of %s CPUs)\n", a[1], a[2], a[3], 100 * a[2] / n, n }'
  echo "busy_pct (100 = one core) p50/p95/max: $b"
  awk -F'\t' 'NR == 1 || $10 < lo { lo = $10 } NR == 1 || $10 > hi { hi = $10 } NR == 1 || $9 < ma { ma = $9 }
    { s += $12; bz += $8 } END { printf "swap_used_mb min=%d max=%d; mem_avail_mb min=%d; sampled/busy=%.0f%%\n", lo, hi, ma, (bz ? 100 * s / bz : 0) }' "$1"
}

# box_proc_report_lanes <proc rows> - the top lanes by core-seconds and by peak memory
box_proc_report_lanes() {
  echo "top by CPU (core-seconds over the kept rows, a lower bound; key = lane, else user/comm):"
  awk -F'\t' '{ k = ($6 != "-") ? $6 : $5 "/" $11; cs[k] += ($7 + $8) / 100 * $3; all += ($7 + $8) / 100 * $3 }
    END { for (k in cs) printf "%.0f\t%.1f\t%s\n", cs[k], (all ? 100 * cs[k] / all : 0), k }' "$1" |
    sort -t$'\t' -k1,1gr | awk -F'\t' 'NR <= 15 { printf "  %8s core-s  %5s%%  %s\n", $1, $2, $3 }'
  echo "top by peak RSS + swap in one sample (MB):"
  awk -F'\t' '{ k = ($6 != "-") ? $6 : $5 "/" $11; m[$1 SUBSEP k] += $9 + $10; key[$1 SUBSEP k] = k }
    END { for (x in m) if (m[x] > pk[key[x]]) pk[key[x]] = m[x]; for (k in pk) printf "%.0f\t%s\n", pk[k], k }' "$1" |
    sort -t$'\t' -k1,1gr | awk -F'\t' 'NR <= 10 { printf "  %8s MB  %s\n", $1, $2 }'
}

# box_proc_cron <act> <dir> <app> <org> - install | check | remove the tagged line
box_proc_cron() {
  local act="$1" dir="$2" app="$3" org="$4" cron="${BOX_PROC_CRONTAB:-crontab}" every="${BOX_PROC_EVERY:-5}"
  local desk tag line cur have next
  [[ "$every" =~ ^[0-9]+$ ]] && ((every >= 1 && every <= 59)) || { do_log "FATAL BOX_PROC_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  command -v "$cron" >/dev/null 2>&1 || { do_log "FATAL $cron is not on PATH"; return 1; }
  desk="${BOX_PROC_DESK_SRC:-/opt/$org/$app-desk-cron}"; tag="$app:box-proc-sample"
  line="*/$every * * * * cd $desk/$app-utl && flock -n $dir/cron.lock env DRY_RUN=0 ./run -a do_box_proc_sample >> $dir/cron.out 2>&1 # $tag"
  cur="$("$cron" -l 2>/dev/null || true)"
  have="$(awk -v t=" # $tag" 'length($0) >= length(t) && substr($0, length($0) - length(t) + 1) == t { print; exit }' <<<"$cur")"
  if [[ "$act" == check ]]; then
    [[ -z "$have" ]] && { do_log "FAIL the box-proc-sample cron is NOT installed (no line tagged $tag)"; return 1; }
    [[ "$have" == "$line" ]] || { do_log "FAIL the box-proc-sample line differs: have: $have want: $line"; return 1; }
    do_log "OK the box-proc-sample cron is installed: $have"; return 0
  fi
  next="$(awk -v t=" # $tag" '!(length($0) >= length(t) && substr($0, length($0) - length(t) + 1) == t)' <<<"$cur")"
  [[ "$act" == install ]] && next="${next:+$next$'\n'}$line"
  [[ "$next" == "$cur" ]] && { do_log "OK nothing to change: the crontab already reads as wanted ($act)"; return 0; }
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    diff <(printf '%s\n' "$cur") <(printf '%s\n' "$next") || true
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  if [[ "$act" == install ]]; then
    [[ -x "$desk/$app-utl/run" ]] || { do_log "FATAL $desk/$app-utl/run is missing: is the desk checkout ($desk) there?"; return 1; }
    mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
  fi
  printf '%s\n' "$next" | "$cron" - || { do_log "FATAL $cron refused the new crontab"; return 1; }
  do_log "OK the box-proc-sample cron is $([[ "$act" == install ]] && echo installed || echo removed)"
}

do_box_proc_sample() {
  local cmd="${BOX_PROC_CMD:-sample}" app org dir
  case "$cmd" in sample|report|install|check|remove) ;; *) do_log "FATAL BOX_PROC_CMD must be sample, report, install, check or remove, got: '$cmd'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  app="$(basename "$PROJ_PATH")"; app="${app%-utl}"; org="${app%%-*}"
  dir="${BOX_PROC_DIR:-/var/$org/$app/box-proc}"
  case "$cmd" in
    sample) box_proc_sample "$dir" ;;
    report) box_proc_report "$dir" ;;
    *) box_proc_cron "$cmd" "$dir" "$app" "$org" ;;
  esac
}
