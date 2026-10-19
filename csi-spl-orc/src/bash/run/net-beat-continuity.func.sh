#!/bin/bash
#------------------------------------------------------------------------------
# @description Hub beat anti-fence guard on THIS box (networking round row 08,
# @description the networking round plan v1.0 section 4, spec 102 10.2). A box
# @description with no beat ack for box_down_min (120 s) fences itself; the
# @description watchdog beats once per WD_TICK (30 s), so an uplink switch is
# @description acked up to 30 s late. This action installs the NM dispatcher
# @description script shipped in features/net/assets:
# @description   <NET_ROOT>/etc/NetworkManager/dispatcher.d/no-wait.d/50-beat-poke.sh (0755)
# @description   <NET_ROOT>/etc/NetworkManager/dispatcher.d/50-beat-poke.sh -> no-wait.d/50-beat-poke.sh
# @description (NM runs a dispatcher.d entry that links into no-wait.d without
# @description waiting for it). On up, down and connectivity-change it touches
# @description /var/run/spl/watchdog.poke; nbc_nap (below), the watchdog's
# @description sleep between ticks, sees the newer mtime within WD_POKE_SLICE
# @description (1 s) and beats the hub at once. Then it probes: it runs the
# @description installed script once (lo connectivity-change) and reads the
# @description poke file's mtime advance.
# @description A poke only beats (spl_wd_beat): it never fences, unfences,
# @description restarts or kills. A burst of events is one beat: a poke newer
# @description than the last one seen beats at most once per WD_POKE_GAP (5) s;
# @description one that came during the gap beats once when it ends.
# @description It refuses, in a dry run too, when <NET_ROOT>/etc/NetworkManager
# @description is missing (no NetworkManager on this box).
# @description Dry run unless DRY_RUN=0: prints the state, the files and the
# @description commands, and writes nothing. Re-running is safe: an identical
# @description file and link are left as they are. Writing needs sudo (NET_SUDO).
# @description NET_BEAT_CMD=check is the round's measuring command, read only:
# @description the beat ack age, the poke age and the FENCED, HELD and BEAT
# @description POKE lines of wd.log since NET_BEAT_SINCE; rc 1 when the ack is
# @description NET_BEAT_MAX_AGE (90) s old or older, or any FENCED line.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param NET_BEAT_CMD (optional) - install (default) or check
# @param NET_BEAT_SINCE (optional, check) - ISO time, e.g. 2026-10-20T10:00:00Z; default the whole log
# @param NET_BEAT_MAX_AGE (optional, check) - seconds, default 90
# @param NET_WD_DIR (optional, check) - default $SPOOL_ROOT/dispatch/wd
# @param NET_WD_LOG (optional, check) - default $SPOOL_ROOT/dispatch/wd.log
# @param NET_ROOT (optional, tests) - the target root, default / (empty)
# @param NET_SYSTEMCTL (optional, tests) - default systemctl
# @param NET_SUDO (optional, tests) - default sudo; empty runs without it
# @param SPL_WD_POKE_FILE (optional, tests) - the poke file, default /var/run/spl/watchdog.poke
# @example ./run -a do_net_beat_continuity
# @example DRY_RUN=0 ./run -a do_net_beat_continuity
# @example NET_BEAT_CMD=check NET_BEAT_SINCE=2026-10-20T10:00:00Z ./run -a do_net_beat_continuity
#------------------------------------------------------------------------------

NBC_ASSET="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../features/net/assets/etc/NetworkManager/dispatcher.d/no-wait.d/50-beat-poke.sh"
NBC_REL=etc/NetworkManager/dispatcher.d
NBC_LINK_TO=no-wait.d/50-beat-poke.sh

# nbc_nap SECONDS - the watchdog's sleep between ticks, woken by the poke:
# sleeps in WD_POKE_SLICE (1) s slices and, when the poke file is newer than
# <WD_DIR>/beat.poke.seen, beats once (nbc_poke_beat). Plain sleep when
# WD_POKE=0, outside the watchdog (no WD_DIR or spl_wd_beat) or with no seen
# mark yet: the first call only records the poke file's mtime, so a poke
# older than the loop never beats.
nbc_nap() {
  local left="$1" f="${SPL_WD_POKE_FILE:-/var/run/spl/watchdog.poke}" seen end
  if [[ "${WD_POKE:-1}" == 0 || -z "${WD_DIR:-}" ]] || ! declare -F spl_wd_beat >/dev/null; then
    sleep "$left"; return 0
  fi
  seen="$WD_DIR/beat.poke.seen"
  [[ -e "$seen" ]] || { if [[ -e "$f" ]]; then touch -r "$f" "$seen"; else touch "$seen"; fi; } 2>/dev/null
  end=$(( EPOCHSECONDS + left ))
  while (( EPOCHSECONDS < end )); do
    sleep "${WD_POKE_SLICE:-1}"
    [[ -e "$f" && "$f" -nt "$seen" ]] && nbc_poke_beat "$f" "$seen"
  done
  return 0
}

# nbc_poke_beat POKE SEEN - one beat for every poke newer than SEEN, at most
# one per WD_POKE_GAP whole seconds (<WD_DIR>/beat.poke.last): a poke inside
# the gap stays newer than SEEN and beats once when the gap ends. SEEN takes the
# poke's mtime before the beat, so a poke during the beat counts again.
nbc_poke_beat() {
  local now="$EPOCHSECONDS" last="" ack
  { read -r last < "$WD_DIR/beat.poke.last"; } 2>/dev/null
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < ${WD_POKE_GAP:-5} )); then return 0; fi
  touch -r "$1" "$2" 2>/dev/null
  echo "$now" > "$WD_DIR/beat.poke.last"
  spl_wd_beat "$now"
  ack="$(spl_wd_beat_ack)"
  spl_wd_log "BEAT POKE${WD_INST:+ instance $WD_INST}: network change; beat ack age $(( now - ${ack:-0} ))s"
}

# nbc_file_state ROOT, nbc_link_state ROOT - SAME when the script (mode 0755)
# and the link are as shipped, else what is there
nbc_file_state() {
  local f="$1/$NBC_REL/no-wait.d/50-beat-poke.sh"
  if [[ ! -e "$f" ]]; then echo missing
  elif cmp -s "$NBC_ASSET" "$f" && [[ "$(stat -c %a "$f")" == 755 ]]; then echo SAME
  else echo "different (mode $(stat -c %a "$f"))"; fi
}
nbc_link_state() {
  local l="$1/$NBC_REL/50-beat-poke.sh"
  if [[ -L "$l" && "$(readlink "$l")" == "$NBC_LINK_TO" ]]; then echo SAME
  elif [[ -L "$l" ]]; then echo "a link to $(readlink "$l")"
  elif [[ -e "$l" ]]; then echo "not a link"
  else echo missing; fi
}

# nbc_mtime FILE - mtime with nanoseconds, or 0
nbc_mtime() { stat -c %.9Y "$1" 2>/dev/null || echo 0; }

# nbc_install DRY ROOT - the install path of the action
nbc_install() {
  local dry="$1" root="$2" dir fs ls poke before after
  dir="$root/$NBC_REL" poke="${SPL_WD_POKE_FILE:-/var/run/spl/watchdog.poke}"
  [[ -r "$NBC_ASSET" ]] || { do_log "FATAL the shipped script is missing: $NBC_ASSET"; return 1; }
  [[ -d "$root/etc/NetworkManager" ]] ||
    { do_log "FATAL $root/etc/NetworkManager is missing: no NetworkManager on this box, refusing; nothing was changed"; return 1; }
  fs="$(nbc_file_state "$root")" ls="$(nbc_link_state "$root")"
  echo "NOW $dir/no-wait.d/50-beat-poke.sh: $fs; $dir/50-beat-poke.sh: $ls; NetworkManager-dispatcher is-enabled=$($NBC_SYSTEMCTL is-enabled NetworkManager-dispatcher 2>/dev/null | sed -n 1p)"
  if [[ "$fs" == SAME ]]; then echo "SAME $dir/no-wait.d/50-beat-poke.sh"
  elif [[ "$dry" == 1 ]]; then echo "PLAN ${NBC_SUDO:+$NBC_SUDO }install -D -m 0755 $NBC_ASSET $dir/no-wait.d/50-beat-poke.sh"
  else
    $NBC_SUDO install -D -m 0755 "$NBC_ASSET" "$dir/no-wait.d/50-beat-poke.sh" ||
      { do_log "FATAL cannot write $dir/no-wait.d/50-beat-poke.sh"; return 1; }
    echo "WROTE $dir/no-wait.d/50-beat-poke.sh"
  fi
  if [[ "$ls" == SAME ]]; then echo "SAME $dir/50-beat-poke.sh -> $NBC_LINK_TO"
  elif [[ "$ls" == "not a link" ]]; then
    do_log "FATAL $dir/50-beat-poke.sh is a file, not the link: refusing to replace it"; return 1
  elif [[ "$dry" == 1 ]]; then echo "PLAN ${NBC_SUDO:+$NBC_SUDO }ln -sfn $NBC_LINK_TO $dir/50-beat-poke.sh"
  else
    $NBC_SUDO ln -sfn "$NBC_LINK_TO" "$dir/50-beat-poke.sh" || { do_log "FATAL cannot link $dir/50-beat-poke.sh"; return 1; }
    echo "LINKED $dir/50-beat-poke.sh -> $NBC_LINK_TO"
  fi
  if [[ "$dry" == 1 ]]; then
    echo "PLAN probe: ${NBC_SUDO:+$NBC_SUDO }$dir/50-beat-poke.sh lo connectivity-change; $poke mtime advances"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  [[ "$(nbc_file_state "$root")" == SAME && "$(nbc_link_state "$root")" == SAME ]] ||
    { do_log "FATAL read-back: script $(nbc_file_state "$root"), link $(nbc_link_state "$root")"; return 1; }
  before="$(nbc_mtime "$poke")"
  sleep 0.05
  $NBC_SUDO "$dir/50-beat-poke.sh" lo connectivity-change
  after="$(nbc_mtime "$poke")"
  [[ "$after" != 0 && "$after" != "$before" ]] ||
    { do_log "FATAL probe: $poke mtime did not advance ($before -> $after)"; return 1; }
  echo "PROBE $poke touched ($after)"
  do_log "OK NM dispatcher beat poke installed: $dir/50-beat-poke.sh -> $NBC_LINK_TO; the watchdog beats within WD_POKE_SLICE of a network change"
}

# nbc_check - the measuring command: beat ack age, poke age, wd.log counts
nbc_check() {
  local wd="${NET_WD_DIR:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/wd}" log="${NET_WD_LOG:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/wd.log}"
  local since="${NET_BEAT_SINCE:-}" max="${NET_BEAT_MAX_AGE:-90}" now ack age poke pm fenced held pokes rc=0
  [[ "$max" =~ ^[0-9]+$ ]] || { do_log "FATAL NET_BEAT_MAX_AGE must be seconds, got: '$max'"; return 1; }
  now="$(date +%s)" ack="$(cat "$wd/beat.ack" 2>/dev/null)"
  poke="${SPL_WD_POKE_FILE:-/var/run/spl/watchdog.poke}" pm="$(stat -c %Y "$poke" 2>/dev/null)"
  [[ "$ack" =~ ^[0-9]+$ ]] && age=$(( now - ack )) || age=""
  read -r fenced held pokes < <(awk -v s="$since" '$1 >= s {
      if ($2 ~ /^FENCED/) f++; else if ($2 ~ /^HELD/) h++; else if ($2 == "BEAT" && $3 ~ /^POKE/) p++ }
      END {print f+0, h+0, p+0}' "$log" 2>/dev/null || echo "0 0 0")
  echo "READ beat ack age ${age:-none}s (max $max); poke $([[ -n "$pm" ]] && echo "$(( now - pm ))s ago" || echo none); since ${since:-the start}: FENCED $fenced, HELD $held, BEAT POKE $pokes ($log)"
  [[ -n "$age" ]] && (( age < max )) || { do_log "FATAL beat ack age ${age:-none}s, not under ${max}s"; rc=1; }
  (( fenced == 0 )) || { do_log "FATAL $fenced FENCED line(s) in $log since ${since:-the start}"; rc=1; }
  (( rc == 0 )) && do_log "OK beat ack ${age}s old, 0 FENCED"
  return "$rc"
}

do_net_beat_continuity() {
  local dry="${DRY_RUN:-1}" root="${NET_ROOT:-}" cmd="${NET_BEAT_CMD:-install}"
  NBC_SYSTEMCTL="${NET_SYSTEMCTL:-systemctl}" NBC_SUDO="${NET_SUDO-sudo}"
  case "$cmd" in
    check) nbc_check; return ;;
    install) ;;
    *) do_log "FATAL NET_BEAT_CMD must be install or check, got: '$cmd'"; return 1 ;;
  esac
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -z "$root" || "$root" == /* ]] || { do_log "FATAL NET_ROOT must be an absolute path, got: '$root'"; return 1; }
  nbc_install "$dry" "${root%/}"
}
