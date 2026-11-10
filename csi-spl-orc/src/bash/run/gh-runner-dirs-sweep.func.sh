#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the install dirs of self-hosted runners that were taken
# @description out of service. do_gh_runner_remove (and so
# @description do_gh_runner_retire_offline) uninstalls a runner's unit and
# @description deregisters it but keeps its dir for rollback; nothing removed
# @description those dirs (sat 2026-11-10, SPL-5086: sat-spl-01..06, 11.4 GB,
# @description 7.6 GB of it on /mnt/data, newest file 2026-10-16). An entry of
# @description GH_RUNNER_DIRS_ROOT (a dir, or a symlink to one: sat-spl-03 ->
# @description /mnt/data/gh-runner/sat-spl-03) is removed only when ALL hold:
# @description   1. it is a runner install: its run and config scripts and
# @description      bin/Runner.Listener (anything else is never touched);
# @description   2. it is deregistered: no .runner, no .credentials* file;
# @description   3. no systemd unit file actions.runner.*.<name>.service;
# @description   4. no file in it changed for GH_RUNNER_DIRS_AGE_D days (a
# @description      dir's own mtime is not read: the runner sweep bumps
# @description      _diag's when it removes old logs);
# @description   5. no process has its cwd in it or names it on its command
# @description      line (/proc read once per run, as root through sudo -n;
# @description      a failed read = every entry held).
# @description The target dir goes as its owner (sudo -n -u <owner> rm -rf),
# @description then the root's symlink to it. One PLAN|REMOVE / KEEP line per
# @description entry, then DONE with the count and MB. Rollback: the runner
# @description tarball in the root and do_gh_runner_add. Not a step of the
# @description box disk sweep: run it by hand. Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param GH_RUNNER_DIRS_ROOT (optional) - default /srv/gh-runner
# @param GH_RUNNER_DIRS_AGE_D (optional) - idle days before removal, default 14
# @example ./run -a do_gh_runner_dirs_sweep
# @example DRY_RUN=0 ./run -a do_gh_runner_dirs_sweep
#------------------------------------------------------------------------------

# ghrd_say <text> - one UTC-stamped line on stdout
ghrd_say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# ghrd_procs - "cwd <path>" and "cmd <line>" per process, read as root, then
# END; non-zero when the read fails
ghrd_procs() {
  sudo -n bash -c 'find /proc -mindepth 2 -maxdepth 2 -name cwd -printf "cwd %l\n" 2>/dev/null
    ps -ww -eo args= | sed "s/^/cmd /" && echo END'
}

# ghrd_held <procs> <dir>... - 0 when a process of <procs> (ghrd_procs) has
# its cwd under a dir or names one on its command line; a failed or cut-short
# /proc read (no END line) counts as held
ghrd_held() {
  local procs="$1" d; shift
  [[ "$procs" == *END ]] || return 0
  for d in "$@"; do
    awk -v d="$d" 'substr($0,1,4) == "cwd " { c = substr($0,5); if (c == d || index(c, d "/") == 1) f = 1 }
      substr($0,1,4) == "cmd " && index($0, d) { f = 1 } END { exit !f }' <<<"$procs" && return 0
  done
  return 1
}

# ghrd_why <name> <dir> <age_d> - prints the KEEP reason, empty when it may go
ghrd_why() {
  local name="$1" dir="$2" age_d="$3"
  [[ -f "$dir/run.sh" && -f "$dir/config.sh" && -e "$dir/bin/Runner.Listener" ]] || { echo "not-a-runner"; return 0; }
  sudo -n test -e "$dir/.runner" && { echo "registered"; return 0; }
  [[ -n "$(sudo -n find "$dir" -maxdepth 1 -name '.credentials*' -print -quit 2>/dev/null)" ]] && { echo "registered"; return 0; }
  systemctl list-unit-files --no-legend 'actions.runner.*' 2>/dev/null |
    awk -v s=".$name.service" '{ n = $1 } length(n) > length(s) && substr(n, length(n) - length(s) + 1) == s { f = 1 } END { exit !f }' &&
    { echo "unit"; return 0; }
  [[ -n "$(sudo -n find "$dir" -xdev ! -type d -newermt "-${age_d} days" -print -quit 2>/dev/null)" ]] && { echo "recent"; return 0; }
  return 0
}

# ghrd_remove <entry> <dir> - rm -rf the dir as its owner, then the link
ghrd_remove() {
  local entry="$1" dir="$2" owner
  owner="$(stat -c %U -- "$dir")" || return 1
  sudo -n -u "$owner" rm -rf -- "$dir" || return 1
  [[ ! -e "$dir" ]] || return 1
  if [[ -L "$entry" ]]; then sudo -n rm -f -- "$entry" || return 1; fi
  return 0
}

do_gh_runner_dirs_sweep() {
  local dry="${DRY_RUN:-1}" root="${GH_RUNNER_DIRS_ROOT:-/srv/gh-runner}" age_d="${GH_RUNNER_DIRS_AGE_D:-14}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ "$age_d" =~ ^[0-9]+$ ]] && (( age_d >= 1 )) || { do_log "FATAL GH_RUNNER_DIRS_AGE_D must be a whole number >= 1"; return 1; }
  root="$(readlink -f -- "$root" 2>/dev/null)"
  [[ -n "$root" && "$root" != / && -d "$root" ]] || { do_log "FATAL GH_RUNNER_DIRS_ROOT must be a dir other than /"; return 1; }
  local entry name dir why mb n=0 tot=0 fail=0 procs="" read_ps=0
  ghrd_say "START root=$root dry_run=$dry age_d=$age_d"
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"; dir="$(readlink -f -- "$entry" 2>/dev/null)"
    [[ -n "$dir" && -d "$dir" && "$dir" != / && "$dir" != "$root" ]] || continue
    why="$(ghrd_why "$name" "$dir" "$age_d")"
    if [[ -z "$why" ]]; then
      (( read_ps )) || { procs="$(ghrd_procs)" || procs=""; read_ps=1; }
      ghrd_held "$procs" "$entry" "$dir" && why="held"
    fi
    [[ -n "$why" ]] && { ghrd_say "KEEP $why $entry"; continue; }
    mb="$(sudo -n du -xsm -- "$dir" 2>/dev/null | cut -f1)"; mb="${mb:-0}"
    if [[ "$dry" == 1 ]]; then ghrd_say "PLAN remove ${mb}MB $entry -> $dir"
    elif ghrd_remove "$entry" "$dir"; then ghrd_say "REMOVE ${mb}MB $entry -> $dir"
    else ghrd_say "WARN could not remove $entry -> $dir"; fail=1; continue
    fi
    n=$((n + 1)); tot=$((tot + mb))
  done < <(find "$root" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 2>/dev/null | sort -z)
  ghrd_say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n (${tot} MB) dry_run=$dry"
  return "$fail"
}
