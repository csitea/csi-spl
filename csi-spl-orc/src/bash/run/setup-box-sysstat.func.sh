#!/bin/bash
#------------------------------------------------------------------------------
# @description Turn on sysstat on THIS box: a CPU / memory / load sample every
# @description 10 minutes, kept 28 days, at no cost (it covers a box no cloud
# @description monitoring can see). Idempotent, one step per line:
# @description   1. apt-get install sysstat when dpkg says it is not installed
# @description   2. ENABLED="true" in /etc/default/sysstat (debian-sa1 reads it)
# @description   3. HISTORY=28 in /etc/sysstat/sysstat (the days of sa files kept)
# @description   4. a sysstat-collect.timer drop-in pinning OnCalendar=*:00/10
# @description      (the packaged default today; the drop-in keeps it 10 min)
# @description   5. enable --now sysstat.service and its collect / summary /
# @description      rotate timers
# @description A step already in place prints OK and is skipped. Debian /
# @description Ubuntu only (apt-get + systemd): both boxes run Debian 13.
# @description Dry run unless DRY_RUN=0 (prints PLAN lines, touches nothing).
# @description Read the samples back with do_report_box_sar.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SYSSTAT_HISTORY (optional) - days of sa files kept, default 28
# @param SYSSTAT_ONCALENDAR (optional) - the collect timer, default *:00/10
# @example ./run -a do_setup_box_sysstat
# @example DRY_RUN=0 ./run -a do_setup_box_sysstat
#------------------------------------------------------------------------------
do_setup_box_sysstat() {
  local dry="${DRY_RUN:-1}" hist="${SYSSTAT_HISTORY:-28}" cal="${SYSSTAT_ONCALENDAR:-*:00/10}"
  local sudo="${SYSSTAT_SUDO-sudo}" etc="${SYSSTAT_ETC:-/etc}"
  local def="$etc/default/sysstat" conf="$etc/sysstat/sysstat"
  local dropin="$etc/systemd/system/sysstat-collect.timer.d/csi-spl.conf"
  local units="sysstat.service sysstat-collect.timer sysstat-summary.timer sysstat-rotate.timer"
  local verb u st want
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$hist" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL SYSSTAT_HISTORY must be a positive integer, got: '$hist'"; return 1; }
  command -v apt-get >/dev/null && command -v systemctl >/dev/null \
    || { do_log "FATAL apt-get and systemctl are required (Debian / Ubuntu box)"; return 1; }
  verb=$([[ "$dry" == 1 ]] && echo PLAN || echo DO)

  st="$(dpkg-query -W -f='${Status}' sysstat 2>/dev/null)"
  if [[ "$st" == "install ok installed" ]]; then
    echo "OK install: sysstat is installed"
  else
    echo "$verb install: apt-get install -y sysstat"
    if [[ "$dry" == 0 ]]; then
      $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat >/dev/null \
        || { do_log "FATAL apt-get install sysstat failed"; return 1; }
    fi
  fi

  _sysstat_set_key "$dry" "$verb" "$sudo" "$def" ENABLED '"true"' || return 1
  _sysstat_set_key "$dry" "$verb" "$sudo" "$conf" HISTORY "$hist" || return 1

  want="$(printf '%s\n' '# csi-spl:setup-box-sysstat - a sample every 10 min (do_setup_box_sysstat)' \
    '[Timer]' 'OnCalendar=' "OnCalendar=$cal")"
  if [[ -f "$dropin" && "$(cat "$dropin")" == "$want" ]]; then
    echo "OK timer: $dropin has OnCalendar=$cal"
  else
    echo "$verb timer: write $dropin (OnCalendar=$cal), daemon-reload"
    if [[ "$dry" == 0 ]]; then
      { $sudo mkdir -p "${dropin%/*}" && printf '%s\n' "$want" | $sudo tee "$dropin" >/dev/null \
        && $sudo systemctl daemon-reload; } || { do_log "FATAL cannot write $dropin"; return 1; }
    fi
  fi

  for u in $units; do
    if [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == enabled && "$(systemctl is-active "$u" 2>/dev/null)" == active ]]; then
      echo "OK unit: $u enabled and active"
    else
      echo "$verb unit: systemctl enable --now $u"
      if [[ "$dry" == 0 ]]; then
        $sudo systemctl enable --now "$u" || { do_log "FATAL systemctl enable --now $u failed"; return 1; }
      fi
    fi
  done
  [[ "$dry" == 1 ]] && { do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; }
  do_log "OK sysstat collects (OnCalendar=$cal), kept $hist days - read it with ./run -a do_report_box_sar"
}

# _sysstat_set_key <dry> <verb> <sudo> <file> <KEY> <value>: make <file> carry
# exactly KEY=value (the first KEY= line replaced, else appended); every other
# line kept. A file that is not there yet (the dry run before the install)
# is planned, not read.
_sysstat_set_key() {
  local dry="$1" verb="$2" sudo="$3" f="$4" k="$5" v="$6" new
  if [[ -f "$f" ]] && grep -qx "$k=$v" "$f"; then
    echo "OK conf: $f has $k=$v"; return 0
  fi
  echo "$verb conf: $f $(grep -m1 "^$k=" "$f" 2>/dev/null || echo "(no $k)") -> $k=$v"
  [[ "$dry" == 1 ]] && return 0
  [[ -f "$f" ]] || { do_log "FATAL $f is missing (is sysstat installed?)"; return 1; }
  new="$(awk -v k="$k" -v v="$v" 'index($0, k "=") == 1 && !done { print k "=" v; done = 1; next }
    { print } END { if (!done) print k "=" v }' "$f")"
  printf '%s\n' "$new" | $sudo tee "$f" >/dev/null || { do_log "FATAL cannot write $f"; return 1; }
}
