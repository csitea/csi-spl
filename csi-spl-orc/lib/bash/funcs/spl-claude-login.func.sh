#!/bin/bash
#------------------------------------------------------------------------------
# The Claude login mode of this box, own or backup (SPL-5695, spec 060 add-on
# csi-spl-doc/specs/060-role-rotation/claude-account-failover.md section 4).
# do_spl_claude_login_mode writes one line to <login-check state>/login-mode:
#   <epoch> <own|backup> <own label> <backup label> <own pct> <own reset>
#   <backup pct> <second folder> <reason...>
# ("-" for an unknown value; a label is acct-<8 hex>, never an email or a
# token). The readers here use it only while it is LOGIN_MODE_MAX_AGE_S (180)
# old or younger: a mode action that stopped ticking means own, the safe side.
#   spl_claude_login_dir    the folder a new claude seat starts with (spawn,
#                           rotation): the second folder on backup, else ""
#   spl_claude_login_wk WK  WK (wk=<kind>:<pct>...) with claude's entry set to
#                           the ACTIVE login's %: the backup's on backup
#   spl_claude_login_scope  " acct=<own label>[ lm=backup]" for the BOX-0 row
#                           (its peer finds its backup's % by that label)
#------------------------------------------------------------------------------

spl_claude_login_state_dir() { echo "${LOGIN_STATE_DIR:-/var/csi/csi-spl/agent-login-check}"; }

# The login-mode line (epoch first) while fresh, else nothing.
spl_claude_login_mode_line() {
  local at line now max="${LOGIN_MODE_MAX_AGE_S:-180}"
  read -r at line 2>/dev/null <"$(spl_claude_login_state_dir)/login-mode" || return 0
  now="${LOGIN_NOW:-$(date +%s)}"
  [[ "$at" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] && (( now - at <= max )) && echo "$at $line"
  return 0
}

spl_claude_login_dir() {
  local mode dir
  read -r _ mode _ _ _ _ _ dir _ <<<"$(spl_claude_login_mode_line)"
  [[ "$mode" == backup && "$dir" == /* ]] && echo "$dir"
  return 0
}

spl_claude_login_wk() {
  local wk="$1" mode bpct
  read -r _ mode _ _ _ _ bpct _ <<<"$(spl_claude_login_mode_line)"
  [[ "$mode" == backup && "$bpct" =~ ^[0-9]{1,3}$ ]] || { echo "$wk"; return 0; }
  wk="$(tr ',' '\n' <<<"$wk" | grep -v '^claude:' | paste -sd, -)"
  echo "claude:$bpct${wk:+,$wk}"
}

spl_claude_login_scope() {
  local mode own
  read -r _ mode own _ <<<"$(spl_claude_login_mode_line)"
  [[ "$own" =~ ^acct-[0-9a-f]{8}$ ]] || return 0
  printf ' acct=%s%s' "$own" "$([[ "$mode" == backup ]] && echo ' lm=backup')"
}
