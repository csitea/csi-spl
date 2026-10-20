#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 09 (rel-09, SPL-2659, Refs: SPL-2364):
# @description clock synchronization loss and NTP drift. A box whose clock
# @description drifts skews the hub beat (a false watchdog fence), invalidates
# @description auth tokens and breaks TLS validity checks, and nothing else
# @description watches it. This check reads, never sets:
# @description   timedatectl show -p NTPSynchronized -p NTP    (yes / no each)
# @description   timedatectl timesync-status                   (Offset, Poll interval, Server)
# @description and, when timesync-status gives no offset (chrony boxes):
# @description   chronyc tracking                              (System time, Update interval)
# @description It prints one line:
# @description   clock-sync <STATE> synced=<yes|no> ntp=<yes|no> offset_us=<n|?>
# @description     offset=<text> poll=<text> server=<s> source=<timesyncd|chrony|none>
# @description     unsynced_s=<n> ms=<n>
# @description   OK        synchronized and |offset| <= CLOCK_SYNC_MAX_OFFSET_MS
# @description   DRIFT     |offset| > CLOCK_SYNC_MAX_OFFSET_MS (default 1000 ms)
# @description   UNSYNCED  not synchronized for less than CLOCK_SYNC_LOST_MIN
# @description             (default 30 min): reported, no alert yet
# @description   LOST      not synchronized for CLOCK_SYNC_LOST_MIN or longer
# @description   ERROR     timedatectl gave no NTPSynchronized answer: sync unknown
# @description How long sync has been lost comes from a since-stamp: the first
# @description run that reads NTPSynchronized=no writes its time, a synchronized
# @description run removes it. With a */5 cron a loss is flagged within 35 min.
# @description The since-stamp is written in every mode (it is what the check
# @description has observed, not an action); the alert stamp only with DRY_RUN=0.
# @description
# @description ALERT OR REPORT ONLY: it never sets the time, restarts a daemon
# @description or changes NTP. DRIFT / LOST / ERROR send ONE spool note to the
# @description orchestrator, only with DRY_RUN=0 (default 1 prints the plan),
# @description throttled by a state stamp: again when the state changes or
# @description after CLOCK_SYNC_THROTTLE_S. OK clears both stamps.
# @description Exit 0 OK, 1 DRIFT / UNSYNCED / LOST / ERROR, 2 a usage error.
# @param CLOCK_SYNC_TIMEDATECTL_BIN (optional) - default timedatectl
# @param CLOCK_SYNC_CHRONYC_BIN (optional) - default chronyc
# @param CLOCK_SYNC_MAX_OFFSET_MS (optional) - default 1000
# @param CLOCK_SYNC_LOST_MIN (optional) - default 30
# @param CLOCK_SYNC_STATE_DIR (optional) - default <SPL_STATE_DIR or
# @param   $HOME/.local/state/csi-spl>/clock-sync
# @param CLOCK_SYNC_THROTTLE_S (optional) - default 3600
# @param CLOCK_SYNC_SEND_CMD (optional) - the sender, called with
# @param   --from <id> --to <id> --kind note --task <task> --no-poke --body <text>;
# @param   default bash <repo>/csi-spl-orc/.../spawn-agents/scripts/spool-send.sh
# @param CLOCK_SYNC_SEND_TIMEOUT (optional) - seconds for the sender, default 20
# @param CLOCK_SYNC_ALERT_TO / _FROM / _TASK (optional) - default orchestrator /
# @param   $SPOOL_AGENT_ID or clock-sync-check@<box> / clock-sync
# @param CLOCK_SYNC_NOW (optional) - epoch seconds override (tests)
# @param DRY_RUN (optional) - 1 (default) plans the alert; 0 sends it
# @example ./run -a do_os_clock_sync_check
# @example DRY_RUN=0 ./run -a do_os_clock_sync_check
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_os_clock_sync_check() {
  local dry="${DRY_RUN:-1}" max_ms="${CLOCK_SYNC_MAX_OFFSET_MS:-1000}" lost_min="${CLOCK_SYNC_LOST_MIN:-30}"
  local tdc="${CLOCK_SYNC_TIMEDATECTL_BIN:-timedatectl}" chr="${CLOCK_SYNC_CHRONYC_BIN:-chronyc}"
  local t0 ms now dir since_f since=0 unsynced_s=0 state detail="" k v
  local synced="" ntp="" off_txt="" off_us="" poll="" server="" source=none
  [[ "$max_ms" =~ ^[0-9]+$ && "$lost_min" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL CLOCK_SYNC_MAX_OFFSET_MS and CLOCK_SYNC_LOST_MIN must be whole numbers"; return 2; }
  t0="$(clock_sync_ms)"
  now="${CLOCK_SYNC_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  dir="$(clock_sync_dir)"
  since_f="$dir/unsynced-since"

  if command -v "$tdc" >/dev/null 2>&1; then
    while IFS='=' read -r k v; do
      case "$k" in NTPSynchronized) synced="$v" ;; NTP) ntp="$v" ;; esac
    done < <(LC_ALL=C "$tdc" show -p NTPSynchronized -p NTP 2>/dev/null)
    clock_sync_read_timesyncd "$tdc"
  fi
  [[ -z "$off_txt" ]] && command -v "$chr" >/dev/null 2>&1 && clock_sync_read_chrony "$chr"
  [[ -n "$off_txt" ]] && off_us="$(clock_sync_us "$off_txt")"

  if [[ "$synced" != yes && "$synced" != no ]]; then
    state=ERROR detail="no NTPSynchronized answer from $tdc"
  elif [[ "$synced" == no ]]; then
    [[ -f "$since_f" ]] && read -r since <"$since_f"
    if ! [[ "$since" =~ ^[0-9]+$ ]] || ((since == 0 || since > now)); then
      since="$now"
      { mkdir -p "$dir" && echo "$since" >"$since_f"; } 2>/dev/null ||
        do_log "WARN cannot write $since_f: the loss duration cannot be tracked"
    fi
    unsynced_s=$((now - since))
    if ((unsynced_s >= lost_min * 60)); then
      state=LOST detail="NTPSynchronized=no for $((unsynced_s / 60)) min (NTP=${ntp:-?})"
    else
      state=UNSYNCED detail="NTPSynchronized=no for $((unsynced_s / 60)) min, alert at $lost_min min"
    fi
  else
    rm -f "$since_f" 2>/dev/null
    state=OK
  fi
  if [[ -n "$off_us" ]] && ((${off_us#-} > max_ms * 1000)); then
    state=DRIFT detail="|offset| $off_txt > ${max_ms} ms${detail:+; $detail}"
  fi
  ms=$(($(clock_sync_ms) - t0))

  do_log "INFO clock-sync $state synced=${synced:-?} ntp=${ntp:-?} offset_us=${off_us:-?} offset=${off_txt:-?} poll=${poll:-?} server=${server:-?} source=$source unsynced_s=$unsynced_s ms=$ms${detail:+ ($detail)}"
  case "$state" in
    OK) clock_sync_clear "$dry"; return 0 ;;
    UNSYNCED) return 1 ;;
  esac
  clock_sync_alert "$state" "$detail" "$dry" "${off_txt:-?}" "${server:-?}"
  return 1
}

# do_clock_sync_check - the filename's own action name (same check)
do_clock_sync_check() { do_os_clock_sync_check "$@"; }

# clock_sync_read_timesyncd <timedatectl> - sets off_txt, poll, server, source
# from timesync-status (systemd-timesyncd); nothing when it gives no Offset.
clock_sync_read_timesyncd() {
  local line out
  out="$(LC_ALL=C "$1" timesync-status 2>/dev/null)" || return 0
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      Offset:*) off_txt="${line#Offset: }" ;;
      "Poll interval:"*) poll="${line#Poll interval: }"; poll="${poll%% (*}" ;;
      Server:*) server="${line#Server: }"; server="${server%% *}" ;;
    esac
  done <<<"$out"
  [[ -n "$off_txt" ]] && source=timesyncd
  return 0
}

# clock_sync_read_chrony <chronyc> - sets off_txt, poll, server, source from
# chronyc tracking: "System time : 0.000012 seconds slow of NTP time"
# (slow = behind = a negative offset), "Update interval : 64.2 seconds".
clock_sync_read_chrony() {
  local line out v
  out="$(LC_ALL=C "$1" tracking 2>/dev/null)" || return 0
  while IFS= read -r line; do
    v="${line#*: }"
    case "$line" in
      "System time"*)
        off_txt="${v%% *}s"
        [[ "$v" == *" slow "* ]] && off_txt="-$off_txt"
        ;;
      "Update interval"*) poll="${v%% *}s" ;;
      "Reference ID"*) server="$(sed -n 's/.*(\(.*\)).*/\1/p' <<<"$v")" ;;
    esac
  done <<<"$out"
  [[ -n "$off_txt" ]] && source=chrony
  return 0
}

# clock_sync_us <timespan> - a systemd timespan ("-34us", "+1.5ms",
# "-1min 2.5s") or a chrony "<seconds>s" as whole microseconds; nothing when
# a part holds no number with a known unit.
clock_sync_us() {
  LC_ALL=C awk -v t="$1" 'BEGIN {
    sign = 1; if (t ~ /^-/) sign = -1; sub(/^[-+]/, "", t)
    m["ns"] = 0.001; m["us"] = 1; m["ms"] = 1000; m["s"] = 1e6; m["min"] = 6e7; m["h"] = 3.6e9; m["d"] = 8.64e10
    n = split(t, p, " "); tot = 0
    if (n == 0) exit
    for (i = 1; i <= n; i++) {
      if (!match(p[i], /^[0-9]+(\.[0-9]+)?/)) exit
      num = substr(p[i], 1, RLENGTH); u = substr(p[i], RLENGTH + 1)
      if (u == "μs" || u == "µs") u = "us"
      if (!(u in m)) exit
      tot += num * m[u]
    }
    printf "%.0f\n", sign * tot
  }'
}

# clock_sync_dir - the state dir of the since-stamp and the alert stamp
clock_sync_dir() { echo "${CLOCK_SYNC_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}/clock-sync}"; }

# clock_sync_clear <dry> - an OK clock forgets its last alert (real run only)
clock_sync_clear() {
  local stamp; stamp="$(clock_sync_dir)/last-alert.stamp"
  [[ "$1" == 0 && -f "$stamp" ]] && rm -f "$stamp"
  return 0
}

# clock_sync_alert <state> <detail> <dry> <offset> <server> - one throttled note
clock_sync_alert() {
  local state="$1" detail="$2" dry="$3" off="$4" server="$5" stamp prev="" at=0 now box body from
  local to="${CLOCK_SYNC_ALERT_TO:-orchestrator}" task="${CLOCK_SYNC_ALERT_TASK:-clock-sync}"
  local throttle="${CLOCK_SYNC_THROTTLE_S:-3600}" send_tmo="${CLOCK_SYNC_SEND_TIMEOUT:-20}"
  local -a send
  box="$(hostname -s 2>/dev/null)"
  from="${CLOCK_SYNC_ALERT_FROM:-${SPOOL_AGENT_ID:-clock-sync-check@$box}}"
  stamp="$(clock_sync_dir)/last-alert.stamp"
  now="${CLOCK_SYNC_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  [[ -f "$stamp" ]] && read -r prev at <"$stamp"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  if [[ "$prev" == "$state" ]] && ((now - at < throttle)); then
    do_log "INFO clock-sync $state alert throttled by $stamp"
    return 0
  fi
  body="clock-sync $state on $box: $detail. Offset $off, server $server. A drifting clock skews the hub beat (false fences), auth tokens and TLS checks. Nothing was changed: check by hand with timedatectl timesync-status (or chronyc tracking)."
  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  read -ra send <<<"${CLOCK_SYNC_SEND_CMD:-}"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: alert not sent"; return 0; }
  fi
  if timeout -k 2 "$send_tmo" "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" \
    --no-poke --body "$body" >/dev/null 2>&1; then
    { mkdir -p "$(dirname "$stamp")" && echo "$state $now" >"$stamp"; } 2>/dev/null ||
      do_log "WARN cannot write $stamp: the next run alerts again"
    do_log "INFO clock-sync $state note sent to $to"
  else
    do_log "WARN clock-sync: the note to $to failed"
  fi
  return 0
}

# clock_sync_ms - a millisecond wall clock (no fork)
clock_sync_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }

# The file name gives do_clock_sync_check; the plan's action name is
# do_os_clock_sync_check, registered here when run.sh sources the file.
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_os_clock_sync_check"]="${BASH_SOURCE[0]}"
fi
