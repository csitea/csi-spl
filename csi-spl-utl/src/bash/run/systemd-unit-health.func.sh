#!/usr/bin/env bash
# systemd-unit-health.func.sh — monitor systemd units, detect failures, extract crash logs,
# throttle duplicate alerts, and emit structured spool notes to orchestrator.
#
# Part of Reliability Round Row 01 (feat(rel-01-systemd-unit-health)).
# Tracked by SPL-2210 (Refs: SPL-2114).
#
# Rule bindings:
# - Read-only on live boxes: no state mutations, no package installs, alert-only.
# - Clean tree: no untracked artifacts, hermetic tests.
# - Distribution hygiene: PC token only, no box names.
#
# Usage:
#   do_os_systemd_unit_check
#   do_systemd_unit_health
#
# Environment variables:
#   DRY_RUN: 1 (default) to log plan only, 0 to emit spool notes and update stamp.
#   SYSTEMD_UNIT_STATE_DIR: state dir for stamp (default $SPL_STATE_DIR or ~/.local/state/csi-spl).
#   SYSTEMD_UNIT_STAMP_FILE: stamp file path (default $state_dir/systemd-unit-alert.stamp).
#   SYSTEMD_UNIT_IGNORE_FILE: path to ignore TSV (default cnf/systemd-unit-ignore.tsv).
#   SYSTEMD_UNIT_ALERT_THROTTLE_SECS: seconds to throttle duplicate alert (default 1800).
#   SYSTEMD_UNIT_ALERT_TO: spool recipient (default "orchestrator").
#   SYSTEMD_UNIT_ALERT_FROM: spool sender (default $SPOOL_AGENT_ID or systemd-unit-health@<box>).
#   SYSTEMD_UNIT_ALERT_TASK: spool task id/topic (default "systemd-unit-health").
#   SYSTEMD_UNIT_ALERT_SEND_BIN: path to spool-send.sh or alternative delivery tool.
#   SYSTEMCTL_BIN: path to systemctl binary (default "systemctl").
#   JOURNALCTL_BIN: path to journalctl binary (default "journalctl").
#
# @example ./run -a do_os_systemd_unit_check
# @example DRY_RUN=0 ./run -a do_os_systemd_unit_check
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# The helpers below run in the action's dynamic scope: they read and set the
# action's locals (ignore_file, ignore_map, sys_state, failed_units, body, ...).
# Call them plainly, never inside $(...), or their assignments are lost.

# spl_box_name: the box name from the config, never the hostname (SPL-4201)
declare -F spl_box_name >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"

# Resolve the ignore file into ignore_file and fill ignore_map from it.
_unit_health_ignore_load() {
  if [[ -z "$ignore_file" ]]; then
    if [[ -n "${PROJ_PATH:-}" && -f "$PROJ_PATH/cnf/systemd-unit-ignore.tsv" ]]; then
      ignore_file="$PROJ_PATH/cnf/systemd-unit-ignore.tsv"
    elif [[ -n "${PROJ_PATH:-}" && -f "$PROJ_PATH/../cnf/systemd-unit-ignore.tsv" ]]; then
      ignore_file="$PROJ_PATH/../cnf/systemd-unit-ignore.tsv"
    elif [[ -f "cnf/systemd-unit-ignore.tsv" ]]; then
      ignore_file="cnf/systemd-unit-ignore.tsv"
    fi
  fi

  if [[ -n "$ignore_file" && -f "$ignore_file" ]]; then
    while IFS=$'\t' read -r ign_unit _rest || [[ -n "$ign_unit" ]]; do
      ign_unit="$(echo "$ign_unit" | tr -d '[:space:]')"
      [[ -z "$ign_unit" || "$ign_unit" == \#* ]] && continue
      ignore_map["$ign_unit"]=1
    done < "$ignore_file"
  fi
}

# Query systemd: set sys_state, and failed_units / failed_details for every
# failed unit not in ignore_map.
_unit_health_failed_units() {
  sys_state="$("$systemctl_bin" is-system-running 2>&1 || true)"
  sys_state="$(echo "$sys_state" | tr -d '[:space:]')"

  local raw_failed=""
  raw_failed="$("$systemctl_bin" --failed --plain --no-legend 2>&1 || true)"

  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Normalize bullet points (systemctl outputs '● unit.service' on degraded states)
    line="$(echo "$line" | sed 's/^[[:space:]]*[●*][[:space:]]*//; s/^[[:space:]]*//')"
    [[ -z "$line" ]] && continue

    local unit_name
    unit_name="$(echo "$line" | awk '{print $1}')"
    [[ -z "$unit_name" ]] && continue

    if [[ -n "${ignore_map[$unit_name]:-}" ]]; then
      do_log "INFO ignoring failed unit $unit_name (present in $ignore_file)"
      continue
    fi

    failed_units+=("$unit_name")
    failed_details+=("$line")
  done <<< "$raw_failed"
}

# Build the alert into body: the failed units plus a crash log tail
# (last 5 lines) per failed unit.
_unit_health_alert_body() {
  local crash_logs=""
  for u in "${failed_units[@]}"; do
    crash_logs+="--- Log: $u ---"$'\n'
    local ulog=""
    ulog="$("$journalctl_bin" -u "$u" -n 5 --no-pager 2>&1 || true)"
    if [[ -z "$ulog" ]]; then
      ulog="(no journal entries available)"
    fi
    crash_logs+="$ulog"$'\n\n'
  done

  local now_iso
  now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"

  local formatted_units=""
  for d in "${failed_details[@]}"; do
    formatted_units+="  - $d"$'\n'
  done

  body=$(printf 'SYSTEMD UNIT FAILURE ALERT\nBox: %s\nState: %s\nFailed units count: %d\nTimestamp: %s\n\nFailed units:\n%s\nCrash logs:\n%s\n' \
    "$box_name" "$sys_state" "${#failed_units[@]}" "$now_iso" "$formatted_units" "$crash_logs")
}

# Return 0 when the stamp is younger than throttle_secs and names the same
# failed units, i.e. this alert was already sent.
_unit_health_throttled() {
  local throttled=0
  if [[ -f "$stamp_file" ]]; then
    local stamp_mtime
    stamp_mtime="$(stat -c %Y "$stamp_file" 2>/dev/null || stat -f %m "$stamp_file" 2>/dev/null || echo 0)"
    local now_epoch
    now_epoch="$(date +%s)"
    local age=$(( now_epoch - stamp_mtime ))

    local prev_units=""
    if grep -q "^UNITS=" "$stamp_file" 2>/dev/null; then
      prev_units="$(sed -n 's/^UNITS=//p' "$stamp_file" 2>/dev/null || true)"
    fi
    local current_units="${failed_units[*]}"

    if (( age >= 0 && age < throttle_secs )) && [[ "$prev_units" == "$current_units" ]]; then
      throttled=1
      do_log "INFO alert throttled by $stamp_file (age: ${age}s < ${throttle_secs}s, units: $current_units)"
    fi
  fi
  [[ "$throttled" == "1" ]]
}

# Pick the sender (SYSTEMD_UNIT_ALERT_SEND_BIN, spool-send.sh, else spool),
# send body as a note, and write the stamp only when the send succeeded.
_unit_health_send() {
  local send_bin="${SYSTEMD_UNIT_ALERT_SEND_BIN:-}"
  if [[ -z "$send_bin" ]]; then
    if [[ -n "${PROJ_PATH:-}" && -f "$PROJ_PATH/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" ]]; then
      send_bin="$PROJ_PATH/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
    elif command -v spool-send.sh >/dev/null 2>&1; then
      send_bin="$(command -v spool-send.sh)"
    fi
  fi

  local send_ok=0
  if [[ -n "$send_bin" && -x "$send_bin" ]]; then
    if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send_bin" \
      --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
      send_ok=1
    else
      do_log "WARN failed to send spool note via $send_bin"
    fi
  elif command -v spool >/dev/null 2>&1; then
    if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spool send \
      --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
      send_ok=1
    else
      do_log "WARN failed to send spool note via spool"
    fi
  else
    do_log "WARN no spool or spool-send.sh found to send alert"
  fi

  if [[ "$send_ok" == "1" ]]; then
    mkdir -p "$(dirname "$stamp_file")" 2>/dev/null || true
    printf 'TIMESTAMP=%s\nUNITS=%s\n' "$(date +%s)" "${failed_units[*]}" > "$stamp_file" 2>/dev/null || true
  fi
}

do_os_systemd_unit_check() {
  local dry="${DRY_RUN:-1}"
  local systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
  local journalctl_bin="${JOURNALCTL_BIN:-journalctl}"

  local box_name="${DEV_BOX:-$(spl_box_name)}"
  local to="${SYSTEMD_UNIT_ALERT_TO:-orchestrator}"
  local from="${SYSTEMD_UNIT_ALERT_FROM:-${SPOOL_AGENT_ID:-systemd-unit-health@$box_name}}"
  local task="${SYSTEMD_UNIT_ALERT_TASK:-systemd-unit-health}"

  local ignore_file="${SYSTEMD_UNIT_IGNORE_FILE:-}"
  declare -A ignore_map=()
  _unit_health_ignore_load

  # Resolve state dir & stamp file
  local state_dir="${SYSTEMD_UNIT_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}}"
  local stamp_file="${SYSTEMD_UNIT_STAMP_FILE:-$state_dir/systemd-unit-alert.stamp}"
  local throttle_secs="${SYSTEMD_UNIT_ALERT_THROTTLE_SECS:-1800}"

  local sys_state="unknown"
  local failed_units=()
  local failed_details=()
  _unit_health_failed_units

  # If no unignored units failed
  if [[ ${#failed_units[@]} -eq 0 ]]; then
    do_log "INFO systemd units healthy: state=$sys_state, failed=0"
    # Clean up alert stamp file if system has recovered
    if [[ -f "$stamp_file" && "$dry" == "0" ]]; then
      rm -f "$stamp_file" 2>/dev/null || true
    fi
    return 0
  fi

  local body
  _unit_health_alert_body

  if ! _unit_health_throttled; then
    if [[ "$dry" == "1" ]]; then
      do_log "WARN systemd unit check failed: ${#failed_units[@]} failed unit(s)"
      do_log "INFO PLAN note to $to: $body"
    else
      do_log "WARN systemd unit check failed: emitting alert to $to"
      _unit_health_send
    fi
  fi

  return 1
}

do_systemd_unit_health() {
  do_os_systemd_unit_check "$@"
}

# Auto-register with run.sh's function map when sourced
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_os_systemd_unit_check"]="${BASH_SOURCE[0]}"
  _func_to_file["do_systemd_unit_health"]="${BASH_SOURCE[0]}"
fi
