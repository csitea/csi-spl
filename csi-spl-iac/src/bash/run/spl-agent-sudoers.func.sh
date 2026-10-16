#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Restrict the box's AGENT user's sudo (SPL-2187): a doc seat
# @description apt-installed systemd-resolved as root on 2026-10-16 and took a
# @description box off DNS for 22 min, because the agent user had
# @description NOPASSWD: ALL. Rewrites /etc/sudoers.d/90-<agent>-nopasswd (the
# @description file the satellite playbook role 05_users writes) so the agent
# @description runs anything as any user BUT root (sudo -u <owner> git / ./run
# @description keep working) and, as root, only the read-only commands the
# @description fleet's scripts use (true, cat, test, readlink, ls, stat, du,
# @description find, grep, head, tail, wc, sha256sum, diff, id, kill,
# @description journalctl without its write flags), all NOEXEC (no find
# @description -exec, no pager shell). No package, service or /etc change.
# @description NOT stopped (say so, never claim more): a hop through the owner
# @description user (sudo -u <owner> sudo ...: the owner's own NOPASSWD rule),
# @description the docker group (a container with / mounted), find -delete.
# @description The pre-tool hook (force-push-guard.inc.sh) is the other layer.
# @description DRY_RUN=1 (default): prints the wanted file, its diff to the
# @description live one and what the agent may run as root TODAY; writes
# @description nothing. DRY_RUN=0: visudo-checks it, backs the live file up
# @description under /var/backups/csi-spl-sudoers, installs it 0440 root,
# @description checks the whole config (restores the backup if it fails),
# @description then probes again and fails unless every probe holds.
# @description A box system change: DRY_RUN=0 only with the owner's go.
# @param SPL_AGENT_SUDO_USER (optional) - the agent user, default AGENT_USER of the box env file
# @param SPL_AGENT_SUDO_OWNER (optional) - the owner user for the "-u owner" probe, default OWNER_USER of the box env file
# @param SPL_AGENT_SUDO_BOX_ENV (optional) - the box env file, default /etc/csi-spl-satellite.env
# @param SPL_AGENT_SUDO_MODE (optional) - restricted (default) or all (the revert: NOPASSWD: ALL again)
# @param SPL_AGENT_SUDOERS_DIR (optional, tests) - default /etc/sudoers.d
# @param SPL_AGENT_SUDO_BACKUP_DIR (optional, tests) - default /var/backups/csi-spl-sudoers
# @param SPL_AGENT_SUDO_PROBE (optional) - 1 (default) probes with sudo -l -U; 0 skips the probes
# @param SPL_AGENT_SUDO_AS_SELF (optional, tests) - 1 writes the dir as the caller, no sudo, no chown root
# @param SPL_AGENT_SUDO_CHECK_FILE (optional, tests) - non-empty: visudo -c checks the one file, not the whole config
# @param SPL_AGENT_SUDO_VISUDO (optional, tests) - the visudo binary
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_agent_sudoers
# @example SPL_AGENT_SUDO_USER=<agent-user> SPL_AGENT_SUDO_OWNER=<owner-user> ./run -a do_spl_agent_sudoers
# @example DRY_RUN=0 ./run -a do_spl_agent_sudoers
# @example SPL_AGENT_SUDO_MODE=all DRY_RUN=0 ./run -a do_spl_agent_sudoers
#------------------------------------------------------------------------------
do_spl_agent_sudoers() {
  local dry="${DRY_RUN:-1}" mode="${SPL_AGENT_SUDO_MODE:-restricted}"
  local dir="${SPL_AGENT_SUDOERS_DIR:-/etc/sudoers.d}" bak="${SPL_AGENT_SUDO_BACKUP_DIR:-/var/backups/csi-spl-sudoers}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$mode" == restricted || "$mode" == all ]] || { do_log "FATAL SPL_AGENT_SUDO_MODE must be restricted or all, got: $mode"; return 2; }
  local agent owner
  agent="${SPL_AGENT_SUDO_USER:-$(_sas_box_env AGENT_USER)}"
  owner="${SPL_AGENT_SUDO_OWNER:-$(_sas_box_env OWNER_USER)}"
  [[ "$agent" =~ ^[a-z_][a-z0-9_-]*$ ]] ||
    { do_log "FATAL no agent user: set SPL_AGENT_SUDO_USER=<agent-user> (no AGENT_USER in ${SPL_AGENT_SUDO_BOX_ENV:-/etc/csi-spl-satellite.env})"; return 1; }
  [[ -z "$owner" || "$owner" =~ ^[a-z_][a-z0-9_-]*$ ]] || { do_log "FATAL bad owner user name: $owner"; return 1; }
  [[ "$agent" != root && "$agent" != "$owner" ]] || { do_log "FATAL the agent user must be neither root nor the owner: $agent"; return 1; }
  local visudo; visudo="$(_sas_visudo)" || { do_log "FATAL visudo not found (apt package sudo)"; return 1; }
  local tmp rc; tmp="$(mktemp -d)" || return 1
  _sas_run "$agent" "$owner" "$mode" "$dry" "$dir/90-$agent-nopasswd" "$bak" "$visudo" "$tmp"; rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# <agent> <owner> <mode> <dry> <file> <backup dir> <visudo> <tmp>
_sas_run() {
  local agent="$1" owner="$2" mode="$3" dry="$4" file="$5" bak="$6" visudo="$7" tmp="$8"
  _sas_render "$agent" "$mode" >"$tmp/want"
  "$visudo" -cf "$tmp/want" >/dev/null 2>"$tmp/err" ||
    { do_log "FATAL the rendered sudoers does not parse: $(cat "$tmp/err")"; return 1; }
  do_log "INFO wanted $file (mode $mode):"
  cat "$tmp/want"
  _sas_root cat "$file" >"$tmp/live" 2>/dev/null || : >"$tmp/live"
  [[ "${SPL_AGENT_SUDO_PROBE:-1}" == 0 ]] || { do_log "INFO what $agent may run TODAY:"; _sas_probe "$agent" "$owner" all-report; }
  if cmp -s "$tmp/live" "$tmp/want"; then
    do_log "OK $file already holds mode $mode: no change"
    [[ "${SPL_AGENT_SUDO_PROBE:-1}" == 0 ]] || _sas_probe "$agent" "$owner" "$mode"
    return
  fi
  do_log "INFO diff live -> wanted:"
  diff "$tmp/live" "$tmp/want"
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would write $file (mode $mode). A box system change: re-run with DRY_RUN=0 only with the owner's go."
    return 0
  fi
  _sas_install "$file" "$tmp" "$bak" "$visudo" || return 1
  [[ "${SPL_AGENT_SUDO_PROBE:-1}" == 0 ]] || _sas_probe "$agent" "$owner" "$mode"
}

# <KEY> - its value in the box env file (written by the playbook role 05_users)
_sas_box_env() {
  local f="${SPL_AGENT_SUDO_BOX_ENV:-/etc/csi-spl-satellite.env}"
  [[ -r "$f" ]] || return 0
  sed -n "s/^$1=//p" "$f" | tail -1
}

_sas_visudo() {
  local v
  for v in "${SPL_AGENT_SUDO_VISUDO:-}" "$(command -v visudo 2>/dev/null)" /usr/sbin/visudo /sbin/visudo; do
    [[ -n "$v" && -x "$v" ]] && { printf '%s\n' "$v"; return 0; }
  done
  return 1
}

# CMD... - as root: directly when root or when the target dir is ours (tests), else sudo -n
_sas_root() {
  if [[ "$(id -u)" == 0 || "${SPL_AGENT_SUDO_AS_SELF:-0}" == 1 ]]; then "$@"; else sudo -n -- "$@"; fi
}

# <agent> <mode> - the sudoers file
_sas_render() {
  local u="$1"
  printf '%s\n' "# written by do_spl_agent_sudoers (csi-spl-iac, SPL-2187), mode $2; do not edit by hand"
  if [[ "$2" == all ]]; then
    printf '%s\n' "$u ALL=(ALL) NOPASSWD:ALL"
    return
  fi
  cat <<EOF
# The agent runs anything as any user but root, and as root only read-only
# commands, NOEXEC: no package, service or /etc change by an agent.
Cmnd_Alias SPL_AGENT_ROOT_RO = /usr/bin/true, /usr/bin/cat, /usr/bin/test, \\
  /usr/bin/readlink, /usr/bin/ls, /usr/bin/stat, /usr/bin/du, /usr/bin/find, \\
  /usr/bin/grep, /usr/bin/head, /usr/bin/tail, /usr/bin/wc, /usr/bin/sha256sum, \\
  /usr/bin/diff, /usr/bin/id, /usr/bin/kill, /usr/bin/journalctl
Cmnd_Alias SPL_AGENT_ROOT_WRITE = /usr/bin/journalctl *--vacuum*, \\
  /usr/bin/journalctl *--rotate*, /usr/bin/journalctl *--flush*, \\
  /usr/bin/journalctl *--relinquish-var*, /usr/bin/journalctl *--smart-relinquish-var*, \\
  /usr/bin/journalctl *--setup-keys*, /usr/bin/journalctl *--update-catalog*, \\
  /usr/bin/journalctl *--sync*
$u ALL=(ALL,!root) NOPASSWD: ALL
$u ALL=(root) NOPASSWD:NOEXEC: SPL_AGENT_ROOT_RO, !SPL_AGENT_ROOT_WRITE
EOF
}

# <file> <tmp> <backup dir> <visudo> - back up, install 0440 root, check the whole config, restore on failure
_sas_install() {
  local file="$1" tmp="$2" bak="$3" visudo="$4" ts saved=""
  ts="$(date -u +%Y%m%dT%H%M%S.%NZ)"
  _sas_root mkdir -p "$bak" || { do_log "ERROR cannot create $bak"; return 1; }
  if _sas_root test -e "$file"; then
    saved="$bak/$(basename "$file").$ts"
    _sas_root cp -pf "$file" "$saved" || { do_log "ERROR cannot back up $file"; return 1; }
    do_log "INFO backed up $file -> $saved"
  fi
  # a name with a dot is ignored by sudo's includedir: staged there, then moved
  local own=(-o root -g root)
  [[ "${SPL_AGENT_SUDO_AS_SELF:-0}" == 1 ]] && own=()
  if ! { _sas_root install -m 0440 "${own[@]}" "$tmp/want" "$file.spl-new" &&
    _sas_root mv -f "$file.spl-new" "$file"; }; then
    do_log "ERROR cannot write $file"; return 1
  fi
  if ! _sas_root "$visudo" -c ${SPL_AGENT_SUDO_CHECK_FILE:+-f "$file"} >"$tmp/check" 2>&1; then
    do_log "ERROR the sudo config does not parse with $file: $(tail -3 "$tmp/check")"
    if [[ -n "$saved" ]]; then _sas_root cp -pf "$saved" "$file"; else _sas_root rm -f "$file"; fi ||
      { do_log "FATAL could not restore $file from ${saved:-nothing}: fix it by hand NOW (visudo)"; return 1; }
    do_log "ERROR restored the previous $file"
    return 1
  fi
  do_log "OK wrote $file (0440); the sudo config parses"
}

# <agent> <owner> <restricted|all|all-report> - sudo -l -U probes; fails unless every one holds the mode
_sas_probe() {
  local u="$1" o="${2:-nobody}" mode="$3" bad=0 line want got
  while IFS='|' read -r want runas cmd; do
    [[ -n "$cmd" ]] || continue
    [[ "$mode" == all ]] && want=allowed
    [[ -x "${cmd%% *}" ]] || { echo "  SKIP ${cmd%% *} is not on this box"; continue; }
    local -a args=(-n -l -U "$u")
    [[ "$runas" == owner ]] && args+=(-u "$o")
    # shellcheck disable=SC2086  # the probe's words
    if _sas_root sudo "${args[@]}" $cmd >/dev/null 2>&1; then got=allowed; else got=refused; fi
    line="$got  ${runas:+(as $runas) }$cmd"
    if [[ "$mode" == all-report ]]; then echo "  $line"
    elif [[ "$got" == "$want" ]]; then echo "  OK $line"
    else echo "  WRONG $line (want $want)"; bad=$((bad + 1)); fi
  done <<'PROBES'
refused||/usr/bin/apt-get install -y systemd-resolved
refused||/usr/bin/apt update
refused||/usr/bin/dpkg -i /tmp/x.deb
refused||/usr/bin/systemctl stop systemd-resolved
refused||/usr/bin/tee /etc/resolv.conf
refused||/usr/bin/cp /tmp/x /etc/sudoers.d/x
refused||/usr/bin/bash -c true
refused||/usr/bin/journalctl --vacuum-size=1M
allowed|owner|/usr/bin/id -un
allowed||/usr/bin/true
allowed||/usr/bin/cat /etc/hostname
allowed||/usr/bin/find /proc -mindepth 2 -maxdepth 2 -path /proc/1/cwd
allowed||/usr/bin/du -sk /tmp
allowed||/usr/bin/readlink /proc/1/cwd
allowed||/usr/bin/kill -0 1
allowed||/usr/bin/journalctl -n 5 --no-pager
PROBES
  [[ "$mode" == all-report ]] && return 0
  ((bad == 0)) || { do_log "ERROR $bad sudo probe(s) do not hold mode $mode for $u"; return 1; }
  do_log "OK every sudo probe holds mode $mode for $u"
}
