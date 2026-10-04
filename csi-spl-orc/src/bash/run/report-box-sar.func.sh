#!/bin/bash
#------------------------------------------------------------------------------
# @description Per-hour CPU / load / memory of THIS box over the last SINCE,
# @description read from the sysstat sa files do_setup_box_sysstat turned on.
# @description One row per UTC hour: the samples, then avg and peak of
# @description   cpu%  = 100 - %idle (all CPUs)       (sar -u)
# @description   load1 = the 1-minute load average    (sar -q)
# @description   mem%  = %memused                     (sar -r)
# @description Reads the saDD file (box-local day) of every day the window
# @description touches (sadf -d -U, epoch timestamps) and keeps the samples
# @description inside the window.
# @description Read-only. Exit 1 when the window holds no sample.
# @param SINCE (optional) - the window: <n>m, <n>h or <n>d, default 20h
# @param SAR_DIR (optional) - the sa files, default /var/log/sysstat
# @example ./run -a do_report_box_sar
# @example SINCE=3d ./run -a do_report_box_sar
#------------------------------------------------------------------------------
do_report_box_sar() {
  local since="${SINCE:-20h}" dir="${SAR_DIR:-/var/log/sysstat}" now="${SAR_NOW:-$(date +%s)}"
  local secs from t f files=() seen=" " rows
  [[ "$since" =~ ^([1-9][0-9]{0,5})([mhd])$ ]] \
    || { do_log "FATAL SINCE must be <n>m, <n>h or <n>d, got: '$since'"; return 1; }
  case "${BASH_REMATCH[2]}" in m) secs=60 ;; h) secs=3600 ;; d) secs=86400 ;; esac
  secs=$((BASH_REMATCH[1] * secs))
  command -v sadf >/dev/null || { do_log "FATAL sadf not found: run ./run -a do_setup_box_sysstat"; return 1; }
  from=$((now - secs))
  for t in $(seq "$from" 86400 "$now") "$now"; do
    f="$dir/sa$(date -d "@$t" +%d)"
    [[ -f "$f" && "$seen" != *" $f "* ]] && { files+=("$f"); seen+="$f "; }
  done
  [[ ${#files[@]} -gt 0 ]] || { do_log "FATAL no sa file in $dir for the last $since (is sysstat collecting?)"; return 1; }
  rows="$(for f in "${files[@]}"; do
      sadf -d -U -- -u "$f"; sadf -d -U -- -q "$f"; sadf -d -U -- -r "$f"
    done 2>/dev/null | awk -F';' -v from="$from" -v now="$now" '
    /^#/ { delete col; for (i = 1; i <= NF; i++) { h = $i; sub(/^# */, "", h); col[h] = i }; ncol = NF
           kind = ("%idle" in col) ? "cpu" : ("ldavg-1" in col) ? "load" : ("%memused" in col) ? "mem" : ""; next }
    kind == "" || NF != ncol || $2 < 0 || $3 < from || $3 > now { next }
    kind == "cpu" && ("CPU" in col) && $col["CPU"] != "-1" && $col["CPU"] != "all" { next }
    { v = (kind == "cpu") ? 100 - $col["%idle"] : (kind == "load") ? $col["ldavg-1"] : $col["%memused"]
      hr = $3 - $3 % 3600; key = hr SUBSEP kind
      if (seen[key SUBSEP $3]++) next
      hrs[hr] = 1; n[key]++; s[key] += v; if (!(key in p) || v > p[key]) p[key] = v }
    END {
      for (hr in hrs) {
        line = strftime("%Y-%m-%d %H:00", hr, 1) "\t" n[hr SUBSEP "cpu"] + 0
        split("cpu load mem", ks, " ")
        for (j = 1; j <= 3; j++) { key = hr SUBSEP ks[j]
          line = line ((key in n) ? sprintf("\t%.1f\t%.1f", s[key] / n[key], p[key]) : "\t-\t-") }
        print line }
    }' | sort)"
  [[ -n "$rows" ]] || { do_log "FATAL no sample in the last $since in ${files[*]}"; return 1; }
  echo "box $(hostname -s) - sysstat, last $since, per UTC hour (${files[*]})"
  { printf 'hour(UTC)\tn\tcpu%%avg\tcpu%%peak\tload1avg\tload1peak\tmem%%avg\tmem%%peak\n'; printf '%s\n' "$rows"; } \
    | column -t -s $'\t'
}
