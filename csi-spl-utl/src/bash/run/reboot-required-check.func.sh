#!/usr/bin/env bash
# reboot-required-check.func.sh — advise when a box runs an outdated kernel or
# services on outdated libraries after Debian upgrades. Strictly advisory:
# it never reboots, restarts or kills anything.
#
# Part of Reliability Round Row 02 (feat(rel-02-reboot-required-check)).
# Tracked by SPL-2221 (Refs: SPL-2114).
#
# Inputs (each read-only):
# - /run/reboot-required and .pkgs: written on Debian by the kernel postinst
#   hook only, so a libc6 or systemd upgrade never sets them.
# - needrestart -b -k -l (batch mode, list only, restarts nothing):
#   NEEDRESTART-KSTA (0 unknown, 1 current, 2 ABI-compatible upgrade pending,
#   3 version upgrade pending) and NEEDRESTART-SVC (services on old libraries).
#   As a non-root user needrestart sees only that user's processes; run the
#   action as the user whose services you want checked.
# - Without needrestart: the running kernel (uname -r) against the newest
#   /boot/vmlinuz-*.
#
# Advice: with DRY_RUN=0, during the advisory window (default hour 04, local
# time), one spool note to the orchestrator per NEW pending state; the same
# state is not sent again until it changes or clears.
#
# Exit: 0 nothing pending, 1 a reboot or service restart is pending.
#
# Environment variables:
#   DRY_RUN: 1 (default) logs the plan only; 0 sends the note and keeps the stamp.
#   REBOOT_REQUIRED_FILE: flag file (default /run/reboot-required).
#   REBOOT_REQUIRED_PKGS_FILE: package list (default $REBOOT_REQUIRED_FILE.pkgs).
#   NEEDRESTART_BIN: needrestart binary (default needrestart on PATH, else /usr/sbin/needrestart).
#   REBOOT_CHECK_BOOT_DIR: kernel image dir for the fallback (default /boot).
#   REBOOT_CHECK_UNAME_R: running kernel release (default `uname -r`).
#   REBOOT_CHECK_WINDOW_HOURS: space-separated hours (00-23) a note may go out
#     in (default "04"); "*" = any hour.
#   REBOOT_CHECK_HOUR: current hour override (default `date +%H`).
#   REBOOT_CHECK_STATE_DIR: state dir (default $SPL_STATE_DIR or ~/.local/state/csi-spl).
#   REBOOT_CHECK_STAMP_FILE: last advised state (default $state_dir/reboot-required.stamp).
#   REBOOT_CHECK_ALERT_TO: spool recipient (default "orchestrator").
#   REBOOT_CHECK_ALERT_FROM: spool sender (default $SPOOL_AGENT_ID or reboot-required-check@<box>).
#   REBOOT_CHECK_ALERT_TASK: spool task id (default "reboot-required-check").
#   REBOOT_CHECK_ALERT_SEND_BIN: spool-send.sh or a compatible tool.
#
# @example ./run -a do_os_reboot_required_check
# @example DRY_RUN=0 ./run -a do_os_reboot_required_check
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# _rrc_needrestart <bin>: print needrestart's batch output, or nothing when
# the binary is missing. LC_ALL=C keeps perl's locale warnings out.
_rrc_needrestart() {
  local bin="$1"
  [[ -n "$bin" ]] || return 0
  LC_ALL=C "$bin" -b -k -l 2>/dev/null || true
}

# _rrc_newest_kernel <boot_dir>: the newest kernel release in the dir, by
# version sort of the vmlinuz-<release> names.
_rrc_newest_kernel() {
  local boot_dir="$1" f names=()
  for f in "$boot_dir"/vmlinuz-*; do
    [[ -e "$f" ]] && names+=("${f##*/vmlinuz-}")
  done
  (( ${#names[@]} )) || return 0
  printf '%s\n' "${names[@]}" | sort -V | tail -n 1
}

# _rrc_in_window <hour> <window_hours>: true when the hour is in the window.
_rrc_in_window() {
  local hour="$1" window="$2" h
  [[ "$window" == "*" ]] && return 0
  for h in $window; do
    [[ "$((10#$h))" == "$((10#$hour))" ]] && return 0
  done
  return 1
}

# _rrc_send <from> <to> <task> <body>: one spool note; 0 when delivered.
_rrc_send() {
  local from="$1" to="$2" task="$3" body="$4"
  local send_bin="${REBOOT_CHECK_ALERT_SEND_BIN:-}"
  local orc_send="${PROJ_PATH:-}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
  if [[ -z "$send_bin" ]]; then
    if [[ -n "${PROJ_PATH:-}" && -f "$orc_send" ]]; then
      send_bin="$orc_send"
    elif command -v spool-send.sh >/dev/null 2>&1; then
      send_bin="$(command -v spool-send.sh)"
    fi
  fi
  if [[ -z "$send_bin" || ! -f "$send_bin" ]]; then
    do_log "WARN no spool-send.sh found to send the reboot advice"
    return 1
  fi
  if ! SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send_bin" \
    --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1; then
    do_log "WARN failed to send spool note via $send_bin"
    return 1
  fi
}

# _rrc_nr_bin: the needrestart binary: NEEDRESTART_BIN, else on PATH, else
# /usr/sbin/needrestart; nothing when none is found.
_rrc_nr_bin() {
  local nr_bin="${NEEDRESTART_BIN:-}"
  if [[ -z "$nr_bin" ]]; then
    nr_bin="$(command -v needrestart 2>/dev/null || true)"
    [[ -z "$nr_bin" && -x /usr/sbin/needrestart ]] && nr_bin=/usr/sbin/needrestart
  fi
  echo "$nr_bin"
}

# The steps below read and set the locals of do_os_reboot_required_check by
# bash dynamic scope: flag, pkgs (_rrc_flag); kcur, kexp, ksta, svcs,
# nr_source (_rrc_kernel_services); _rrc_advise reads them all plus dry,
# box_name, to, from, task and stamp_file.

# _rrc_flag <flag_file> <pkgs_file>: 1. The kernel postinst flag.
_rrc_flag() {
  local flag_file="$1" pkgs_file="$2"
  if [[ -e "$flag_file" ]]; then
    flag=1
    [[ -f "$pkgs_file" ]] && pkgs="$(sort -u "$pkgs_file" | tr '\n' ' ' | sed 's/ *$//')"
  fi
  return 0
}

# _rrc_kernel_services <nr_bin>: 2. needrestart, or the boot-dir fallback for
# the kernel.
_rrc_kernel_services() {
  local nr_bin="$1" nr_out line
  nr_out="$(_rrc_needrestart "$nr_bin")"
  if [[ -z "$nr_out" ]]; then
    nr_source="boot-dir"
    do_log "INFO needrestart unavailable (${nr_bin:-not installed}); kernel compared with ${REBOOT_CHECK_BOOT_DIR:-/boot}, services not checked"
    kcur="${REBOOT_CHECK_UNAME_R:-$(uname -r)}"
    kexp="$(_rrc_newest_kernel "${REBOOT_CHECK_BOOT_DIR:-/boot}")"
    if [[ -z "$kexp" ]]; then
      ksta=0
    elif [[ "$kexp" == "$kcur" ]]; then
      ksta=1
    else
      ksta=3
    fi
  fi
  while IFS= read -r line; do
    case "$line" in
      NEEDRESTART-KCUR:*) kcur="${line#*: }" ;;
      NEEDRESTART-KEXP:*) kexp="${line#*: }" ;;
      NEEDRESTART-KSTA:*) ksta="${line#*: }" ;;
      NEEDRESTART-SVC:*) svcs+=("${line#*: }") ;;
    esac
  done <<< "$nr_out"
}

# _rrc_advise: print the advisory body, then send it once per new state in
# the window (DRY_RUN=0); always 1, a reboot or restart is pending.
_rrc_advise() {
  local state="flag=$flag ksta=$ksta kexp=$kexp pkgs=$pkgs svcs=${svcs[*]}"
  local svc_list="" s
  for s in "${svcs[@]}"; do svc_list+="  - $s"$'\n'; done
  [[ -n "$svc_list" ]] || svc_list="  (none)"$'\n'
  local body
  body=$(printf 'REBOOT ADVISORY (no action taken)\nBox: %s\nReboot flag: %s%s\nKernel: running %s, expected %s (KSTA=%s, source %s)\nServices on outdated libraries: %d\n%sAdvice: plan a reboot or service restart in a maintenance window; this check never reboots.\n' \
    "$box_name" "$flag" "${pkgs:+ (pkgs: $pkgs)}" "${kcur:-?}" "${kexp:-?}" "${ksta:-?}" "$nr_source" \
    "${#svcs[@]}" "$svc_list")
  do_log "WARN reboot or restart pending: flag=$flag ksta=${ksta:-?} services=${#svcs[@]}"
  printf '%s\n' "$body"

  local prev=""
  [[ -f "$stamp_file" ]] && prev="$(sed -n 's/^STATE=//p' "$stamp_file")"
  if [[ "$prev" == "$state" ]]; then
    do_log "INFO advice already sent for this state ($stamp_file)"
    return 1
  fi
  local hour="${REBOOT_CHECK_HOUR:-$(date +%H)}"
  local window="${REBOOT_CHECK_WINDOW_HOURS:-04}"
  if ! _rrc_in_window "$hour" "$window"; then
    do_log "INFO outside the advisory window (hour $hour, window $window): no note"
    return 1
  fi
  if [[ "$dry" == "1" ]]; then
    do_log "INFO PLAN note to $to (DRY_RUN=1, not sent)"
    return 1
  fi
  if _rrc_send "$from" "$to" "$task" "$body"; then
    mkdir -p "$(dirname "$stamp_file")"
    printf 'TIMESTAMP=%s\nSTATE=%s\n' "$(date +%s)" "$state" > "$stamp_file"
    do_log "INFO advice sent to $to"
  fi
  return 1
}

do_os_reboot_required_check() {
  local dry="${DRY_RUN:-1}"
  local flag_file="${REBOOT_REQUIRED_FILE:-/run/reboot-required}"
  local pkgs_file="${REBOOT_REQUIRED_PKGS_FILE:-$flag_file.pkgs}"
  local nr_bin
  nr_bin="$(_rrc_nr_bin)"
  local box_name="${DEV_BOX:-$(hostname -s 2>/dev/null || echo "PC")}"
  local to="${REBOOT_CHECK_ALERT_TO:-orchestrator}"
  local from="${REBOOT_CHECK_ALERT_FROM:-${SPOOL_AGENT_ID:-reboot-required-check@$box_name}}"
  local task="${REBOOT_CHECK_ALERT_TASK:-reboot-required-check}"
  local state_dir="${REBOOT_CHECK_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}}"
  local stamp_file="${REBOOT_CHECK_STAMP_FILE:-$state_dir/reboot-required.stamp}"

  local flag=0 pkgs=""
  _rrc_flag "$flag_file" "$pkgs_file"
  local kcur="" kexp="" ksta="" svcs=() nr_source="needrestart"
  _rrc_kernel_services "$nr_bin"

  local kernel_pending=0
  [[ "$ksta" == "2" || "$ksta" == "3" ]] && kernel_pending=1

  if [[ "$flag" == "0" && "$kernel_pending" == "0" && ${#svcs[@]} -eq 0 ]]; then
    do_log "INFO no reboot pending: flag=0 kernel=${kcur:-?} ksta=${ksta:-?} services=0 source=$nr_source"
    [[ "$dry" == "0" && -f "$stamp_file" ]] && rm -f "$stamp_file"
    return 0
  fi
  _rrc_advise
}

# Auto-register with run.sh's function map when sourced
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_os_reboot_required_check"]="${BASH_SOURCE[0]}"
fi
