#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 159 T2 (SPL-3706): measure fleet boxes against the desk
# @description start checks of spec 127 5.3 that spec 159 5.2 keeps for a
# @description workspace seat on a fleet box, and report which ones fail.
# @description READ ONLY: it reads /proc, /sys and the mount table as the
# @description calling user (no sudo) and changes nothing on any box; a fix
# @description is a separate owner go per box (spec 159 12.2).
# @description One row per box and check, then one verdict per box:
# @description   hidepid       /proc mounted hidepid=2 (or =invisible)
# @description   ptrace        kernel.yama.ptrace_scope >= 2
# @description   suid_dumpable fs.suid_dumpable = 0
# @description   core_pattern  a file path or systemd-coredump, no other pipe
# @description   swap          no swap, or only encrypted (dm-crypt) or zram
# @description   tmpfs         the runtime dir /run/user/<uid> is on tmpfs
# @description Spec 159 5.2's exemption: "no OS user is root-equivalent" is
# @description not measured (the fleet's agent user is). W's own user does
# @description not exist before T3, so its check is T3's.
# @param BOX_SEAT_CHECK_BOXES (optional) - boxes, space or comma separated; default "local" (this machine)
# @param BOX_SSH_<BOX> (optional) - the ssh destination of a box (<BOX>: upper case, - as _), default the box id
# @param SEAT_CHECK_SSH (optional) - the ssh command, default ssh
# @param SEAT_CHECK_ROOT (optional) - test only: a fake root to read under; {box} is replaced by the box id
# @param SEAT_CHECK_UID (optional) - test only: the uid whose runtime dir is checked; default the box user's
# @example ./run -a do_spl_box_seat_check
# @example BOX_SEAT_CHECK_BOXES="local,<BOX>" BOX_SSH_<BOX>=<ssh-alias> ./run -a do_spl_box_seat_check
#------------------------------------------------------------------------------
do_spl_box_seat_check() {
  local list="${BOX_SEAT_CHECK_BOXES:-local}" box out bad=0 n=0
  local -a boxes
  read -ra boxes <<<"$(tr ',' ' ' <<<"$list")"
  (( ${#boxes[@]} )) || { do_log "FATAL BOX_SEAT_CHECK_BOXES is empty"; return 1; }
  for box in "${boxes[@]}"; do
    [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL '$box' is not a box id"; return 1; }
  done
  for box in "${boxes[@]}"; do
    n=$((n + 1))
    out="$(spl_bsc_run_box "$box")" || {
      printf 'box=%s check=reach verdict=fail detail=unreachable\n' "$box"
      do_log "FAIL box $box: unreachable, nothing measured"
      bad=$((bad + 1)); continue
    }
    spl_bsc_report "$box" "$out" || bad=$((bad + 1))
  done
  if (( bad )); then
    do_log "FAIL $bad of $n box(es) fail a seat start check (spec 159 5.2); nothing was changed"
    return 1
  fi
  do_log "OK all $n box(es) pass every seat start check (spec 159 5.2); nothing was changed"
}

# spl_bsc_run_box <box> -> the probe's rows, run here for "local", else over ssh.
# ssh joins its words into one remote shell line, so the two args are quoted.
spl_bsc_run_box() {
  local box="$1" root="${SEAT_CHECK_ROOT:-}" uid="${SEAT_CHECK_UID:-}" k s dest
  root="${root//\{box\}/$box}"
  if [[ "$box" == local ]]; then
    spl_bsc_probe "$root" "$uid"
    return
  fi
  [[ "$root$uid" != *"'"* ]] || { do_log "FATAL SEAT_CHECK_ROOT / SEAT_CHECK_UID may not hold a quote"; return 1; }
  k="$(tr 'a-z-' 'A-Z_' <<<"$box")"; s="BOX_SSH_$k"
  dest="${!s:-$box}"
  local -a sshc
  read -ra sshc <<<"${SEAT_CHECK_SSH:-ssh}"
  "${sshc[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$dest" bash -s -- "'$root'" "'$uid'" \
    <<<"$(declare -f spl_bsc_probe spl_bsc_mount_of spl_bsc_swap_ok); spl_bsc_probe \"\$1\" \"\$2\""
}

# spl_bsc_report <box> <rows> -> prints the rows and the box verdict; 1 when a check fails.
spl_bsc_report() {
  local box="$1" rows="$2" failing
  [[ "$(grep -c ' verdict=' <<<"$rows")" -eq 6 ]] || {
    printf 'box=%s check=probe verdict=fail detail=incomplete\n' "$box"
    do_log "FAIL box $box: the probe did not report all 6 checks"
    return 1
  }
  sed "s/^/box=$box /" <<<"$rows"
  failing="$(awk '/ verdict=fail /{sub(/^check=/, "", $1); printf "%s%s", s, $1; s=","}' <<<"$rows")"
  [[ -z "$failing" ]] && { do_log "OK box $box: clean, 6 of 6 checks pass"; return 0; }
  do_log "FAIL box $box: failing $failing"
  return 1
}

# spl_bsc_probe <root> <uid> -> six rows "check=<c> verdict=pass|fail detail=<d>".
# Self-contained (shipped over ssh with declare -f); it only reads.
spl_bsc_probe() {
  local r="$1" uid="${2:-$(id -u)}" v ok opts d
  local mounts="$r/proc/mounts"
  opts="$(awk '$2 == "/proc" && $3 == "proc" {o=$4} END {print o}' "$mounts" 2>/dev/null)"
  v="$(tr ',' '\n' <<<"$opts" | sed -n 's/^hidepid=//p' | tail -n1)"
  ok=fail; [[ "$v" == 2 || "$v" == invisible ]] && ok=pass
  printf 'check=hidepid verdict=%s detail=hidepid=%s\n' "$ok" "${v:-unset}"

  v="$(cat "$r/proc/sys/kernel/yama/ptrace_scope" 2>/dev/null)"
  ok=fail; [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 2 )) && ok=pass
  printf 'check=ptrace verdict=%s detail=ptrace_scope=%s\n' "$ok" "${v:-absent}"

  v="$(cat "$r/proc/sys/fs/suid_dumpable" 2>/dev/null)"
  ok=fail; [[ "$v" == 0 ]] && ok=pass
  printf 'check=suid_dumpable verdict=%s detail=suid_dumpable=%s\n' "$ok" "${v:-absent}"

  v="$(head -n1 "$r/proc/sys/kernel/core_pattern" 2>/dev/null)"
  ok=fail
  if [[ -n "$v" && "$v" != "|"* ]]; then ok=pass; d="file"
  elif [[ "$v" == "|"*systemd-coredump* ]]; then ok=pass; d="systemd-coredump"
  elif [[ -z "$v" ]]; then d="absent"
  else d="pipe"
  fi
  printf 'check=core_pattern verdict=%s detail=core_pattern=%s\n' "$ok" "$d"

  if [[ -r "$r/proc/swaps" ]]; then
    d="$(spl_bsc_swap_ok "$r")"
    ok=pass; [[ "$d" == *:plain* ]] && ok=fail
  else
    ok=fail; d=unreadable
  fi
  printf 'check=swap verdict=%s detail=swap=%s\n' "$ok" "${d:-none}"

  v="$(spl_bsc_mount_of "$mounts" "/run/user/$uid")"
  ok=fail; [[ "$v" == tmpfs ]] && ok=pass
  printf 'check=tmpfs verdict=%s detail=/run/user/%s:%s\n' "$ok" "$uid" "${v:-unmounted}"
}

# spl_bsc_mount_of <mounts file> <path> -> the fs type of the longest mount covering <path>.
spl_bsc_mount_of() {
  awk -v p="$2" '{
      m = $2
      if (p == m || m == "/" || index(p, m "/") == 1) { if (length(m) > best) { best = length(m); t = $3 } }
    } END { print t }' "$1" 2>/dev/null
}

# spl_bsc_swap_ok <root> -> each active swap as <name>:zram|crypt|plain,
# comma separated; empty when there is no swap.
spl_bsc_swap_ok() {
  local r="$1" name kind base out="" uuid
  while read -r name _; do
    [[ -z "$name" || "$name" == Filename ]] && continue
    base="$(basename "$(readlink -f "$r$name" 2>/dev/null || echo "$name")")"
    kind=plain
    if [[ "$base" == zram* ]]; then
      kind=zram
    elif [[ "$base" == dm-* ]]; then
      uuid="$(cat "$r/sys/block/$base/dm/uuid" 2>/dev/null)"
      [[ "$uuid" == CRYPT-* ]] && kind=crypt
    fi
    out+="${out:+,}$base:$kind"
  done <"$r/proc/swaps"
  printf '%s\n' "$out"
}
