#!/bin/bash
#------------------------------------------------------------------------------
# @description Keep a laptop box awake on AC power while lid close still
# @description suspends (SPL-2269, owner HUM-10 poll 40d40bd0 answer A):
# @description   1. a systemd-logind drop-in <root>/etc/systemd/logind.conf.d/
# @description      50-csi-spl-sleep-policy.conf: IdleAction=ignore,
# @description      HandleLidSwitch=suspend, HandleLidSwitchExternalPower=suspend
# @description      (docked lid handling stays the box's default)
# @description   2. GNOME (gsd-power) idle suspend on AC off for the user who
# @description      runs it: sleep-inactive-ac-type 'nothing'; the battery keys
# @description      are not touched. Skipped when no gsettings or no schema.
# @description   3. logind picks the drop-in up by `systemctl reload
# @description      systemd-logind` (SIGHUP), never a restart: a restart can
# @description      end the graphical session
# @description Idempotent: an equal file or key is left alone, no reload.
# @description SLEEP_POLICY_CMD=show prints the effective setting: logind's
# @description live properties, the drop-in, the gsettings keys, AC online,
# @description the battery and UPower's CriticalPowerAction (read only: a
# @description battery that drains on AC still hits that action, see
# @description csi-spl-doc/doc/md/box-sleep-policy.md).
# @param SLEEP_POLICY_CMD (optional) - apply (default) or show
# @param SLEEP_POLICY_ROOT (optional) - a prefix for /etc, default empty (tests)
# @param SLEEP_POLICY_SYS (optional) - the power_supply dir, default /sys/class/power_supply
# @param SLEEP_POLICY_SUDO (optional) - the prefix for /etc writes and systemctl, default "sudo -n" unless root or SLEEP_POLICY_ROOT is set
# @param DRY_RUN (optional) - 1 (default) prints the plan, 0 writes it
# @example ./run -a do_box_sleep_policy
# @example DRY_RUN=0 ./run -a do_box_sleep_policy
# @example SLEEP_POLICY_CMD=show ./run -a do_box_sleep_policy
#------------------------------------------------------------------------------
do_box_sleep_policy() {
  local cmd="${SLEEP_POLICY_CMD:-apply}" dry=1
  case "$cmd" in
    show) spl_bsp_show; return ;;
    apply) ;;
    *) do_log "FATAL SLEEP_POLICY_CMD must be apply or show, got: '$cmd'"; return 1 ;;
  esac
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_bsp_logind "$dry" || return 1
  spl_bsp_gnome "$dry" || return 1
  if (( dry )); then do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to apply."; return 0; fi
  do_log "OK sleep policy applied; read it back with SLEEP_POLICY_CMD=show"
}

SPL_BSP_GS_SCHEMA=org.gnome.settings-daemon.plugins.power

spl_bsp_dropin() { echo "${SLEEP_POLICY_ROOT:-}/etc/systemd/logind.conf.d/50-csi-spl-sleep-policy.conf"; }

# spl_bsp_sudo: the prefix for /etc writes and systemctl.
spl_bsp_sudo() {
  if [[ -n "${SLEEP_POLICY_SUDO+x}" ]]; then echo "$SLEEP_POLICY_SUDO"
  elif [[ -n "${SLEEP_POLICY_ROOT:-}" || "$(id -u)" == 0 ]]; then echo ""
  else echo "sudo -n"; fi
}

spl_bsp_content() {
  cat <<'EOF'
# csi-spl box sleep policy (SPL-2269): no idle suspend on AC, lid close
# still suspends. Written by ./run -a do_box_sleep_policy; edits are replaced.
[Login]
IdleAction=ignore
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
EOF
}

spl_bsp_in_place() { local f; f="$(spl_bsp_dropin)"; [[ -f "$f" && "$(cat "$f")" == "$(spl_bsp_content)" ]]; }

# spl_bsp_logind <dry>: write the drop-in when it differs, then reload logind.
spl_bsp_logind() {
  local dry="$1" f su
  f="$(spl_bsp_dropin)"; su="$(spl_bsp_sudo)"
  if spl_bsp_in_place; then
    do_log "INFO logind drop-in $f is already in place: unchanged, no reload"
    return 0
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would write $f:"
    spl_bsp_content
    do_log "INFO DRY_RUN would run: ${su:+$su }systemctl reload systemd-logind (SIGHUP, not a restart)"
    return 0
  fi
  # shellcheck disable=SC2086 # $su is a command prefix: empty or "sudo -n"
  { $su mkdir -p "$(dirname "$f")" && spl_bsp_content | $su tee "$f" >/dev/null; } ||
    { do_log "FATAL cannot write $f"; return 1; }
  do_log "INFO wrote $f"
  # shellcheck disable=SC2086
  $su systemctl reload systemd-logind || { do_log "FATAL systemctl reload systemd-logind failed"; return 1; }
  do_log "INFO reloaded systemd-logind (SIGHUP, the session keeps running)"
}

# spl_bsp_gs <args>: gsettings on the caller's session bus when none is set.
spl_bsp_gs() {
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}" gsettings "$@"
}

# spl_bsp_gnome <dry>: the gsd-power idle action on AC -> 'nothing'.
spl_bsp_gnome() {
  local dry="$1" cur
  command -v gsettings >/dev/null || { do_log "INFO no gsettings: no GNOME idle policy to set"; return 0; }
  cur="$(spl_bsp_gs get "$SPL_BSP_GS_SCHEMA" sleep-inactive-ac-type 2>/dev/null)" ||
    { do_log "INFO no $SPL_BSP_GS_SCHEMA for $(id -un): no GNOME idle policy to set"; return 0; }
  if [[ "$cur" == "'nothing'" ]]; then
    do_log "INFO gsettings sleep-inactive-ac-type is already 'nothing': unchanged"
    return 0
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would run: gsettings set $SPL_BSP_GS_SCHEMA sleep-inactive-ac-type nothing (now $cur)"
    return 0
  fi
  spl_bsp_gs set "$SPL_BSP_GS_SCHEMA" sleep-inactive-ac-type nothing ||
    { do_log "FATAL gsettings set sleep-inactive-ac-type failed"; return 1; }
  do_log "INFO gsettings sleep-inactive-ac-type: $cur -> 'nothing'"
}

# spl_bsp_prop <name>: one live logind Manager property, or "?".
spl_bsp_prop() {
  local v
  v="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$1" 2>/dev/null)" || v="?"
  v="${v#s }"; echo "${v//\"/}"
}

spl_bsp_show() {
  local sys="${SLEEP_POLICY_SYS:-/sys/class/power_supply}" k p up in_place=no
  spl_bsp_in_place && in_place=yes
  echo "logind dropin=$(spl_bsp_dropin) in_place=$in_place"
  for k in IdleAction HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
    echo "logind $k=$(spl_bsp_prop "$k")"
  done
  if command -v gsettings >/dev/null; then
    for k in sleep-inactive-ac-type sleep-inactive-ac-timeout sleep-inactive-battery-type sleep-inactive-battery-timeout; do
      echo "gsettings $k=$(spl_bsp_gs get "$SPL_BSP_GS_SCHEMA" "$k" 2>/dev/null || echo '?')"
    done
  else
    echo "gsettings none"
  fi
  for p in "$sys"/*; do
    [[ -r "$p/type" ]] || continue
    case "$(cat "$p/type")" in
      Mains) echo "power ac=${p##*/} online=$(cat "$p/online" 2>/dev/null || echo '?')" ;;
      Battery) echo "power battery=${p##*/} status=$(cat "$p/status" 2>/dev/null || echo '?') capacity=$(cat "$p/capacity" 2>/dev/null || echo '?')%" ;;
    esac
  done
  up="$(sed -n 's/^CriticalPowerAction=//p' "${SLEEP_POLICY_ROOT:-}/etc/UPower/UPower.conf" 2>/dev/null | tail -n1)"
  echo "upower CriticalPowerAction=${up:-?} (fires on a low battery, on AC too when the battery drains)"
}
