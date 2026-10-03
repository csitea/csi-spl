#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description READ-ONLY gate + probe (specs/069 Y9): lists every dependency of
#   this box's spool on the frozen ysg-box engine - the populations of spec 069
#   sections 2.2..2.6 - one TSV row per dependency on stdout:
#     <kind> <user> <where> <detail>
#   kinds: cron (crontab lines of each user and root, /etc/cron*), link
#   (symlinks from the homes into the engine, live or BROKEN), home (home and
#   /etc shell files, ~/.local/bin, ~/.claude files, ~/.claude.json mcpServers
#   calling into it), tmux (global hooks/options of the box user's live
#   server), systemd (unit and env files), proc (running processes).
#   Exit 0 = nothing found; 1 = rows found; 2 = a population could not be
#   read (a skipped read is never a pass). It changes nothing.
#   Users and paths are never literals: the box user owns this checkout, the
#   agent users are the spool root group's members; another user's crontab
#   and home are read through sudo -n.
# @param YSG_BOX_DEPS_USERS (optional) - space-separated users; default the
#   box user (SPOOL_BOX_USER, else this checkout's owner) plus SPOOL_AGENT_USER
#   and the members of SPOOL_ROOT_GROUP (default spool-agents)
# @param YSG_BOX_DEPS_CRON_USERS (optional) - whose crontabs are read; default
#   the users above plus root
# @param YSG_BOX_DEPS_PATTERN (optional) - ERE of an engine path; default
#   'ysg-box(-[a-z]+)?/|/opt/<box user>/' - a PATH into the engine, its
#   worktrees or the box user's /opt dir (a file NAMED ysg-box-* is no row)
# @param YSG_BOX_DEPS_SYS_PATHS (optional) - system files/dirs swept for cron,
#   shell and systemd hits; default /etc/crontab /etc/cron.* /etc/profile
#   /etc/bash.bashrc /etc/profile.d /etc/systemd /lib/systemd/system
# @param YSG_BOX_DEPS_TMUX_SOCKET (optional) - default SPOOL_TMUX_SOCKET, else
#   /tmp/tmux-<box uid>/default; absent = no live server, nothing to read
# @example ./run -a do_check_ysg_box_deps
# @example YSG_BOX_DEPS_USERS="<box-user> <agent-user>" ./run -a do_check_ysg_box_deps
#------------------------------------------------------------------------------
do_check_ysg_box_deps() {
  local me box_user users pat sock rows errs=0 u h out
  me=$(id -un)
  box_user="${SPOOL_BOX_USER:-$(stat -c %U "$PROJ_PATH")}"
  users="${YSG_BOX_DEPS_USERS:-$(ysg_box_deps_users "$box_user")}"
  pat="${YSG_BOX_DEPS_PATTERN:-ysg-box(-[a-z]+)?/|/opt/$box_user/}"
  sock="${YSG_BOX_DEPS_TMUX_SOCKET:-${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$box_user" 2>/dev/null || echo x)/default}}"
  local -a sys
  if [[ -n "${YSG_BOX_DEPS_SYS_PATHS+x}" ]]; then
    read -r -a sys <<<"$YSG_BOX_DEPS_SYS_PATHS"
  else
    sys=(/etc/crontab /etc/cron.* /etc/profile /etc/bash.bashrc /etc/profile.d /etc/systemd /lib/systemd/system)
  fi
  out=$(mktemp) || return 2

  for u in ${YSG_BOX_DEPS_CRON_USERS:-$users root}; do ysg_box_deps_cron "$u" || ysg_box_deps_err "cannot read the crontab of $u"; done
  for u in $users; do
    h=$(ysg_box_deps_home "$u") || { ysg_box_deps_err "no home for user $u"; continue; }
    ysg_box_deps_as "$u" true 2>/dev/null || { ysg_box_deps_err "cannot read as $u (sudo -n -u $u refused)"; continue; }
    ysg_box_deps_links "$u" "$h" || ysg_box_deps_err "cannot list the symlinks under the home of $u"
    ysg_box_deps_homefiles "$u" "$h" || ysg_box_deps_err "cannot read the home files of $u"
    ysg_box_deps_sys "$u" systemd "$h/.config/systemd" || ysg_box_deps_err "cannot read the user units of $u"
  done
  ysg_box_deps_sys "$me" sys "${sys[@]}" || ysg_box_deps_err "cannot read the system paths"
  ysg_box_deps_tmux || ysg_box_deps_err "cannot read the tmux server at $sock"
  ysg_box_deps_procs || ysg_box_deps_err "cannot list the processes"

  sort -u "$out" >"$out.s"
  cat "$out.s"
  rows=$(grep -c . "$out.s")
  rm -f "$out" "$out.s"
  do_log "INFO users: $users; crontabs: ${YSG_BOX_DEPS_CRON_USERS:-$users root}; pattern: $pat"
  if (( errs )); then
    do_log "FAIL $errs population(s) could not be read; $rows dependency row(s) in what was read"; return 2
  fi
  if (( rows )); then
    do_log "FAIL $rows dependency row(s) on the ysg-box engine (one per row above)"; return 1
  fi
  do_log "OK no dependency on the ysg-box engine"
}

# ysg_box_deps_row <kind> <user> <where> <detail>: one dependency row
ysg_box_deps_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4//$'\t'/ }" >>"$out"; }
ysg_box_deps_err() { do_log "ERROR $*"; errs=$((errs + 1)); }

# ysg_box_deps_users <box user>: the box user, SPOOL_AGENT_USER and the spool
# root group's members, each once
ysg_box_deps_users() {
  local members
  members=$(getent group "${SPOOL_ROOT_GROUP:-spool-agents}" 2>/dev/null | cut -d: -f4)
  # shellcheck disable=SC2086 # split the user lists on purpose
  printf '%s\n' "$1" ${SPOOL_AGENT_USER:-} ${members//,/ } | awk 'NF && !s[$0]++' | paste -sd' '
}

# ysg_box_deps_as <user> <cmd...>: run as that user, through sudo -n unless it is us
ysg_box_deps_as() {
  local u="$1"; shift
  if [[ "$u" == "$me" ]]; then "$@"; else sudo -n -u "$u" -- "$@"; fi
}

ysg_box_deps_home() {
  if [[ "$1" == "$me" ]]; then echo "$HOME"; return; fi
  local h; h=$(getent passwd "$1" | cut -d: -f6)
  [[ -n "$h" ]] && echo "$h"
}

# ysg_box_deps_detail <text>: trimmed, at most 160 chars
ysg_box_deps_detail() { sed 's/^[[:space:]]*//' <<<"$1" | cut -c1-160; }

# ysg_box_deps_grep_rows <user> <kind>: grep -nH lines on stdin become rows
ysg_box_deps_grep_rows() {
  local u="$1" kind="$2" line f k
  while IFS= read -r line; do
    f=${line%%:*}; k=$kind
    if [[ "$kind" == sys ]]; then
      case "$f" in
        */cron*) k=cron ;;
        *systemd* | *.service | *.socket | *.timer | *.path | *.target) k=systemd ;;
        *) k=home ;;
      esac
    fi
    line=${line#*:}
    ysg_box_deps_row "$k" "$u" "$f:${line%%:*}" "$(ysg_box_deps_detail "${line#*:}")"
  done
}

ysg_box_deps_cron() {
  local u="$1" tab rc n=0 line
  if [[ "$u" == "$me" ]]; then tab=$(crontab -l 2>&1); rc=$?
  else tab=$(sudo -n crontab -u "$u" -l 2>&1); rc=$?
  fi
  if (( rc )); then [[ "$tab" == *"no crontab for"* ]]; return; fi
  while IFS= read -r line; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ $pat ]] && ysg_box_deps_row cron "$u" "crontab:$n" "$(ysg_box_deps_detail "$line")"
  done <<<"$tab"
  return 0
}

# symlinks whose target names the engine, with liveness; caches and session
# history pruned (spec 069 2.3)
ysg_box_deps_links() {
  local u="$1" h="$2" l t state
  ysg_box_deps_as "$u" test -d "$h" || return 1
  ysg_box_deps_as "$u" find "$h" \( -path "$h/.cache" -o -name node_modules -o -path "$h/go" \
    -o -path "$h/.claude/projects" \) -prune -o -type l -printf '%p\t%l\n' >"$out.l" 2>/dev/null
  while IFS=$'\t' read -r l t; do
    [[ "$t" =~ $pat ]] || continue
    if ysg_box_deps_as "$u" test -e "$l"; then state=live; else state=BROKEN; fi
    ysg_box_deps_row link "$u" "$l" "-> $t ($state)"
  done <"$out.l"
  rm -f "$out.l"
}

# home files that call into the engine (spec 069 2.4)
ysg_box_deps_homefiles() {
  local u="$1" h="$2" f t
  local -a files=()
  for f in "$h"/.bashrc "$h"/.profile "$h"/.bash_profile "$h"/.zshrc "$h"/.tmux.conf \
    "$h"/.claude/CLAUDE.md "$h"/.claude/settings.json; do
    ysg_box_deps_as "$u" test -f "$f" && files+=("$f")
  done
  mapfile -t -O "${#files[@]}" files < <(ysg_box_deps_as "$u" find "$h/.local/bin" "$h/.claude/commands" \
    "$h/.claude/skills" -maxdepth 2 \( -type f -o -type l \) -readable \( -path '*/.local/bin/*' -o -name '*.md' \) 2>/dev/null)
  if (( ${#files[@]} )); then
    ysg_box_deps_as "$u" grep -nIHE "$pat" "${files[@]}" | ysg_box_deps_grep_rows "$u" home
    (( PIPESTATUS[0] < 2 )) || return 1
  fi
  if ysg_box_deps_as "$u" test -f "$h/.claude.json"; then
    ysg_box_deps_as "$u" jq -r '.mcpServers // {} | to_entries[] | "\(.key)\t\(.value | tostring)"' "$h/.claude.json" 2>/dev/null \
      | while IFS=$'\t' read -r f t; do
        [[ "$t" =~ $pat ]] && ysg_box_deps_row home "$u" "$h/.claude.json:mcpServers.$f" "$(ysg_box_deps_detail "$t")"
      done
  fi
  return 0
}

# ysg_box_deps_sys <user> <kind> <path...>: files under those paths naming the
# engine; kind sys sorts each hit into cron, systemd or home by its path. An
# unreadable file under them (grep exit 2) fails the read
ysg_box_deps_sys() {
  local u="$1" kind="$2" f; shift 2
  local -a p=()
  for f in "$@"; do ysg_box_deps_as "$u" test -e "$f" && p+=("$f"); done
  (( ${#p[@]} )) || return 0
  ysg_box_deps_as "$u" grep -rnIHE "$pat" "${p[@]}" | ysg_box_deps_grep_rows "$u" "$kind"
  (( PIPESTATUS[0] < 2 ))
}

# the live tmux server: global hooks and options (spec 069 2.5)
ysg_box_deps_tmux() {
  [[ -S "$sock" ]] || { do_log "INFO no tmux server at $sock: no live hooks to read"; return 0; }
  local line
  { ysg_box_deps_as "$box_user" tmux -S "$sock" show-hooks -g && ysg_box_deps_as "$box_user" tmux -S "$sock" show-options -g; } >"$out.t" 2>/dev/null || return 1
  while IFS= read -r line; do
    [[ "$line" =~ $pat ]] && ysg_box_deps_row tmux "$box_user" "$sock" "$(ysg_box_deps_detail "$line")"
  done <"$out.t"
  rm -f "$out.t"
}

ysg_box_deps_procs() {
  local pu pid args
  ps -eo user=,pid=,args= >"$out.p" 2>/dev/null || return 1
  while read -r pu pid args; do
    [[ "$pid" == "$$" || "$pid" == "$BASHPID" ]] && continue
    [[ "$args" =~ $pat ]] && ysg_box_deps_row proc "$pu" "pid:$pid" "$(ysg_box_deps_detail "$args")"
  done <"$out.p"
  rm -f "$out.p"
}
