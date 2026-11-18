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

declare -F spl_run_paths >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-run-paths.func.sh"

# The login-check state dir: LOGIN_STATE_DIR, else SPL_VAR_APP_DIR's
# agent-login-check (spl_run_paths); rc 1 and nothing when neither is known.
# Run from a watchdog code snapshot (<wd>/code/<sha>/, which holds .sha) it is
# the box's live dir, derived from the checkout the snapshot came from
# (DESK_CRON_SRC, else <wd>/starter.src), never one under the snapshot: the
# live probe is never there, so the SPL-5617 heal could not fire and every
# new sha failed its self-check on the missing probe (SPL-5919, 2026-11-18).
spl_claude_login_state_dir() {
  [[ -n "${LOGIN_STATE_DIR:-}" ]] && { echo "$LOGIN_STATE_DIR"; return 0; }
  local src
  src="$(_spl_claude_login_snapshot_src)"
  if [[ -n "$src" ]]; then
    (unset SPL_VAR_APP_DIR; APP_PATH="$src" spl_run_paths 2>/dev/null && echo "$SPL_VAR_APP_DIR/agent-login-check") && return 0
  fi
  spl_run_paths 2>/dev/null || return 1
  echo "$SPL_VAR_APP_DIR/agent-login-check"
}

# _spl_claude_login_snapshot_src: the checkout a watchdog code snapshot came
# from, when this tree is one (its main checkout holds a 40-hex .sha, as
# spl_rotate_seed_feat reads it); empty otherwise. The SPL_VAR_APP_DIR of the
# process is not used there: an earlier spl_run_paths keyed it by the snapshot.
_spl_claude_login_snapshot_src() {
  local main s src=""
  main="$(spl_main_checkout 2>/dev/null)" || return 0
  s="$(cat "$main/.sha" 2>/dev/null || true)"
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 0
  src="${DESK_CRON_SRC:-$(cat "${main%/code/*}/starter.src" 2>/dev/null || true)}"
  [[ -n "$src" && -d "$src" ]] && echo "$src"
  return 0
}

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
