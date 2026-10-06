#!/usr/bin/env bash
# check-disk-headroom.sh - warn BEFORE a disk or its inode table fills: for
# every real mount of THIS box, blocks >= DISK_HEADROOM_BLOCK_PCT (85) or
# inodes >= DISK_HEADROOM_INODE_PCT (80) is a crossing. A crossing logs a WARN
# and sends ONE spool note to the orchestrator; it is remembered in a state
# file, so the next ticks stay quiet while the mount stays high, and a mount
# that falls back below is logged CLEAR and may warn again on its next
# crossing. A note that could not be sent is not remembered: it is retried on
# the next tick.
#
# Real mounts: df's list without the pseudo filesystems
# (DISK_HEADROOM_SKIP_TYPES: tmpfs, devtmpfs, ramfs, overlay, squashfs,
# efivarfs, ...), one row per device (a bind mount counts once), but /tmp is
# ALWAYS checked when it is its own filesystem, tmpfs or not: the CI runners
# share it (the 2026-10-02 "no space left on device").
#
# A skip or a failure is loud, never silent: df failing, an unwritable state
# dir or a check already running is a WARN line, and the first two also a
# note (the same once-per-crossing rule, keyed on the failure).
#
# Installed by do_check_disk_headroom_install_cron as ONE line tagged
# `# <org>-<app>:disk-headroom`. One CHECK line per run (every mount, its
# blocks and inodes), plus a WARN / CLEAR / PLAN line per change.
#
#   DRY_RUN=1 (default) | 0       1: no note sent, no state written
#   DISK_HEADROOM_BLOCK_PCT       default 85
#   DISK_HEADROOM_INODE_PCT       default 80
#   DISK_HEADROOM_SKIP_TYPES      space separated fs types not checked
#   DISK_HEADROOM_STATE_DIR       default $SPL_STATE_DIR/disk-headroom, else
#                                 ~/.local/share/<org>-<app>/cloud/self/disk-headroom
#   DISK_HEADROOM_TO / _FROM      default orchestrator / c-001
#   DISK_HEADROOM_TASK            the spool topic, default disk-headroom
#   DISK_HEADROOM_DF              the df to run (tests)
#   DISK_HEADROOM_SEND            the sender script (tests), default spool-send.sh
#
# Exit: 0 all under the limits; 1 a mount is over a limit or a check failed;
# 2 usage.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
app="$(basename "$ORC")"; app="${app%-orc}"

dry="${DRY_RUN:-1}"
bpct="${DISK_HEADROOM_BLOCK_PCT:-85}"
ipct="${DISK_HEADROOM_INODE_PCT:-80}"
skip_types=" ${DISK_HEADROOM_SKIP_TYPES:-tmpfs devtmpfs ramfs overlay squashfs efivarfs autofs nsfs proc sysfs cgroup cgroup2} "
state_dir="${DISK_HEADROOM_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/share/$app/cloud/self}/disk-headroom}"
to="${DISK_HEADROOM_TO:-orchestrator}"
from="${DISK_HEADROOM_FROM:-c-001}"
task="${DISK_HEADROOM_TASK:-disk-headroom}"
df_bin="${DISK_HEADROOM_DF:-df}"
send="${DISK_HEADROOM_SEND:-$ORC/src/bash/features/spawn-agents/scripts/spool-send.sh}"
# The fleet box id (<DEV_BOX>), as spool-send.sh names this machine.
# shellcheck source=/dev/null
SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" source "$ORC/src/bash/features/spawn-agents/lib/spool-fleet.inc.sh" 2>/dev/null &&
  box="$(SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spool_fleet_box)"
box="${box:-$(hostname -s 2>/dev/null)}"
who="$(id -un)"

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FATAL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
for v in "$bpct" "$ipct"; do
  [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 100 )) ||
    { say "FATAL DISK_HEADROOM_BLOCK_PCT / DISK_HEADROOM_INODE_PCT must be 1..100, got '$v'"; exit 2; }
done

state="$state_dir/crossings"
declare -A was=() now=()
can_state=1
{ mkdir -p "$state_dir" && [[ -w "$state_dir" ]]; } 2>/dev/null || can_state=0
[[ -r "$state" ]] && while IFS= read -r k; do [[ -n "$k" ]] && was["$k"]=1; done <"$state"

# note <key> <text>: a WARN line, and a spool note on a NEW crossing only.
# The key stays in now[] either way; it is dropped again when the send fails,
# so the next tick retries it.
rc=0
note() {
  local key="$1" text="$2"
  rc=1; now["$key"]=1
  say "WARN $text"
  [[ -n "${was[$key]:-}" ]] && return 0
  if [[ "$dry" == 1 ]]; then say "PLAN note to $to: $text"; return 0; fi
  if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$from" --to "$to" --kind note --task "$task" \
      --body "DISK HEADROOM $box ($who): $text" >/dev/null 2>&1; then
    say "INFO told $to: $key"
  else
    say "WARN could not tell $to about $key: retried next tick"; unset 'now[$key]'
  fi
}

if (( can_state )); then
  exec 9>>"$state_dir/lock"
  flock -n 9 || { say "WARN SKIP another check holds $state_dir/lock: this tick checked nothing"; exit 1; }
else
  note "state:unwritable" "the state dir $state_dir is not writable: every tick re-sends its notes"
fi

if ! rows="$("$df_bin" --output=source,fstype,pcent,ipcent,target 2>&1)"; then
  note "df:failed" "df failed, nothing was measured: $(head -c 300 <<<"$rows" | tr '\n' ' ')"
  rows=""
fi

declare -A seen=()
line="" n=0 nskip=0
while read -r src typ pc ipc target; do
  [[ "$src" == Filesystem || -z "$target" ]] && continue
  if [[ "$target" != /tmp ]]; then
    [[ "$skip_types" == *" $typ "* ]] && { nskip=$((nskip + 1)); continue; }
    [[ -n "${seen[$src]:-}" ]] && { nskip=$((nskip + 1)); continue; }
  fi
  seen["$src"]=1; n=$((n + 1))
  pc="${pc%\%}" ipc="${ipc%\%}"
  line+=" $target=${pc}%b/${ipc}%i"
  if [[ "$pc" =~ ^[0-9]+$ ]] && (( pc >= bpct )); then
    note "blocks:$target" "$target ($typ, $src) blocks ${pc}% >= ${bpct}%"
  fi
  if [[ "$ipc" =~ ^[0-9]+$ ]] && (( ipc >= ipct )); then
    note "inodes:$target" "$target ($typ, $src) inodes ${ipc}% >= ${ipct}%"
  fi
done <<<"$rows"
(( n > 0 )) || note "mounts:none" "no mount was checked: df listed nothing this check measures"

for k in "${!was[@]}"; do [[ -n "${now[$k]:-}" ]] || say "CLEAR $k is back under its limit"; done
if [[ "$dry" == 0 ]] && (( can_state )); then
  { for k in "${!now[@]}"; do printf '%s\n' "$k"; done; } | sort >"$state.tmp" && mv -f "$state.tmp" "$state"
fi
say "CHECK box=$box user=$who dry_run=$dry limits=${bpct}%b/${ipct}%i mounts=$n skipped=$nskip high=${#now[@]}${line}"
exit "$rc"
