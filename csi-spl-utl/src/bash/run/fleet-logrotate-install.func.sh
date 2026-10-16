#!/bin/bash
#------------------------------------------------------------------------------
# @description Bound the fleet's own cron logs (disk hygiene round row 01,
# @description SPL-2233). Writes two root-owned files: /etc/logrotate.d/csi-spl
# @description rotates the agent user's .cache/csi-spl/tmp-scratch-sweep.log and
# @description the owner's desk-reconcile/cron-prd.out and
# @description box-disk-sweep/box-disk-sweep.log under /var/csi/csi-spl once they
# @description pass 50M (copytruncate: the cron `>>` writers keep their fd; 7
# @description compressed copies; `su` to the user that owns each dir, which
# @description logrotate needs for a dir a non-root user controls), and
# @description /etc/tmpfiles.d/csi-spl.conf ages out the dated
# @description csi-spl-orc.<date>.log files after 14 days (logrotate cannot:
# @description `minage` counts from its own state, not the file's mtime, and
# @description removed a 1-day-old log in a planted test). Users come from cnf
# @description env.steps."060-gcp-vm-satellite".box_owner_user / box_agent_user,
# @description else $USER. Dry run unless DRY_RUN=0: prints each file it would
# @description write, its diff against the box and `logrotate -d` on it. The
# @description real write needs root.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param FLEET_LOGROTATE_ROOT (optional) - prefix for the two /etc files (tests), default none
# @param FLEET_LOGROTATE_OWNER_USER (optional) - default cnf box_owner_user, else $USER
# @param FLEET_LOGROTATE_AGENT_USER (optional) - default cnf box_agent_user, else $USER
# @param FLEET_LOGROTATE_AGENT_HOME (optional) - default the agent user's passwd home
# @param FLEET_LOGROTATE_VAR_DIR (optional) - default /var/csi
# @param FLEET_LOGROTATE_MAXSIZE (optional) - default 50M
# @param FLEET_LOGROTATE_MAX_AGE_D (optional) - dated log age in days, default 14
# @param FLEET_LOGROTATE_BIN (optional) - default logrotate on PATH, else /usr/sbin/logrotate
# @example ./run -a do_fleet_logrotate_install
# @example sudo DRY_RUN=0 ./run -a do_fleet_logrotate_install
#------------------------------------------------------------------------------
do_fleet_logrotate_install() {
  local dry="${DRY_RUN:-1}" root="${FLEET_LOGROTATE_ROOT:-}"
  local lr_conf="$root/etc/logrotate.d/csi-spl" tf_conf="$root/etc/tmpfiles.d/csi-spl.conf"
  local tmp rc=0
  _fleet_logrotate_resolve || return 1
  if [[ "$dry" == "0" && -z "$root" && "$(id -u)" != "0" ]]; then
    do_log "ERROR DRY_RUN=0 writes /etc: run it as root (sudo DRY_RUN=0 ./run -a do_fleet_logrotate_install)"
    return 1
  fi
  tmp=$(mktemp -d) || return 1
  _fleet_logrotate_render >"$tmp/csi-spl"
  _fleet_tmpfiles_render >"$tmp/csi-spl.conf"
  _fleet_logrotate_debug "$tmp" || rc=1
  _fleet_logrotate_put "$dry" "$tmp/csi-spl" "$lr_conf" || rc=1
  _fleet_logrotate_put "$dry" "$tmp/csi-spl.conf" "$tf_conf" || rc=1
  rm -rf "$tmp"
  return "$rc"
}

# _fleet_logrotate_cnf <key>: one env.steps."060-gcp-vm-satellite" value from
# the <ENV> (default prd) cnf, or nothing.
_fleet_logrotate_cnf() {
  local proj="${PROJ_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}" oa cnf
  oa="$(basename "$proj")"; oa="${oa%-utl}"
  cnf="${FLEET_LOGROTATE_CNF:-$proj/../$oa-cnf/$oa/${ENV:-prd}.env.yaml}"
  [[ -r "$cnf" ]] && command -v yq >/dev/null 2>&1 || return 0
  yq -r ".env.steps.\"060-gcp-vm-satellite\".$1 // \"\"" "$cnf" 2>/dev/null
}

# _fleet_logrotate_resolve: set FL_OWNER/FL_OWNER_GRP/FL_AGENT/FL_AGENT_GRP/
# FL_AGENT_HOME/FL_VAR/FL_MAX/FL_AGE, failing fast on an unknown user.
_fleet_logrotate_resolve() {
  FL_OWNER="${FLEET_LOGROTATE_OWNER_USER:-$(_fleet_logrotate_cnf box_owner_user)}"
  FL_AGENT="${FLEET_LOGROTATE_AGENT_USER:-$(_fleet_logrotate_cnf box_agent_user)}"
  FL_OWNER="${FL_OWNER:-$USER}"; FL_AGENT="${FL_AGENT:-$USER}"
  FL_OWNER_GRP=$(id -gn "$FL_OWNER" 2>/dev/null) || { do_log "ERROR no OS user $FL_OWNER (owner) on this box"; return 1; }
  FL_AGENT_GRP=$(id -gn "$FL_AGENT" 2>/dev/null) || { do_log "ERROR no OS user $FL_AGENT (agent) on this box"; return 1; }
  FL_AGENT_HOME="${FLEET_LOGROTATE_AGENT_HOME:-$(getent passwd "$FL_AGENT" | cut -d: -f6)}"
  [[ -n "$FL_AGENT_HOME" ]] || { do_log "ERROR no home for $FL_AGENT"; return 1; }
  FL_VAR="${FLEET_LOGROTATE_VAR_DIR:-/var/csi}"
  FL_MAX="${FLEET_LOGROTATE_MAXSIZE:-50M}"
  FL_AGE="${FLEET_LOGROTATE_MAX_AGE_D:-14}"
}

# _fleet_logrotate_stanza <su-user> <su-group> <path>...: one rotation block.
_fleet_logrotate_stanza() {
  local u=$1 g=$2
  shift 2
  printf '%s {\n' "$*"
  printf '    %s\n' "su $u $g" weekly "maxsize $FL_MAX" "rotate 7" copytruncate compress missingok notifempty
  printf '}\n'
}

_fleet_logrotate_render() {
  printf '%s\n' "# csi-spl fleet cron logs: rotate past $FL_MAX, keep 7 compressed copies." \
    "# Written by csi-spl-utl ./run -a do_fleet_logrotate_install; change it there."
  _fleet_logrotate_stanza "$FL_AGENT" "$FL_AGENT_GRP" "$FL_AGENT_HOME/.cache/csi-spl/tmp-scratch-sweep.log"
  _fleet_logrotate_stanza "$FL_OWNER" "$FL_OWNER_GRP" \
    "$FL_VAR/csi-spl/desk-reconcile/cron-prd.out" "$FL_VAR/csi-spl/box-disk-sweep/box-disk-sweep.log"
}

# The dir holds only csi-spl-orc.<date>.log; `e` ages every file in it by mtime.
_fleet_tmpfiles_render() {
  printf '%s\n' "# csi-spl-orc dated logs: remove after $FL_AGE days (file mtime)." \
    "# Written by csi-spl-utl ./run -a do_fleet_logrotate_install; change it there." \
    "e $FL_VAR/csi-spl-desk-cron/csi-spl-orc/dat/log/bash - - - m:${FL_AGE}d"
}

# _fleet_logrotate_debug <dir>: `logrotate -d` on the rendered file, with a
# throwaway state file so the box's state is never read or written. Only root
# may switch to another user, so a non-root run checks a copy without the
# `su` lines and says so.
_fleet_logrotate_debug() {
  local bin="${FLEET_LOGROTATE_BIN:-$(command -v logrotate || echo /usr/sbin/logrotate)}" out rc chk="$1/csi-spl" what=
  [[ -x "$bin" ]] || { do_log "WARN no logrotate binary ($bin): config not checked"; return 0; }
  if [[ "$(id -u)" != "0" ]]; then
    chk="$1/csi-spl.nosu"; what=" (su lines left out: not root)"
    grep -v '^    su ' "$1/csi-spl" >"$chk"
  fi
  out=$("$bin" -d -s "$1/state" "$chk" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(error|rotating pattern|considering log|  log )' | sed 's/^/  logrotate -d: /'
  do_log "INFO logrotate -d on the rendered config$what: rc=$rc"
  return "$rc"
}

# _fleet_logrotate_put <dry> <new> <target>: show the file and its diff
# against the box; on DRY_RUN=0 write it 0644 (root:root when root).
_fleet_logrotate_put() {
  local dry=$1 new=$2 dst=$3 cur=/dev/null
  [[ -f "$dst" ]] && cur="$dst"
  if cmp -s "$new" "$cur"; then
    do_log "INFO $dst unchanged"
    return 0
  fi
  do_log "INFO $([[ "$dry" == "0" ]] && echo WRITE || echo PLAN) $dst:"
  sed 's/^/  | /' "$new"
  diff -u --label "$dst (on box)" --label "$dst (new)" "$cur" "$new" | sed 's/^/  /'
  [[ "$dry" == "0" ]] || return 0
  mkdir -p "$(dirname "$dst")" || return 1
  if [[ "$(id -u)" == "0" ]]; then install -o root -g root -m 0644 "$new" "$dst"; else install -m 0644 "$new" "$dst"; fi
}
