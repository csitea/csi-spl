#!/bin/bash
#------------------------------------------------------------------------------
# @description Claude self sign-in for ONE workspace's seats on this box (spec
# @description 159 4.3, row T8; owner HUM-10 Q-3 A, msg 36279386). It runs as
# @description the workspace's own OS user (W's desk calls it), never as the
# @description fleet's agent user or root. The sign-in directory is
# @description <runtime>/spool-claude, <runtime> = W's /run/user/<uid>: tmpfs,
# @description mode 0700 and outside every home, so the token-burn collector
# @description and the session export (both read <home>/.claude) never read it,
# @description and it holds no settings file, so no mirror hook runs in it.
# @description   SIGNIN_CMD=in     starts the UNMODIFIED CLI's own login
# @description                     (`claude auth login --claudeai`) with
# @description                     CLAUDE_CONFIG_DIR = that directory, in a tmux
# @description                     session on W's own socket: the person signs in
# @description                     through the vendor's flow; nothing here sees
# @description                     the token. Refused (exit 3) unless the switch,
# @description                     cnf env.box.claude_self_signin_tenants, names
# @description                     W. It ships empty (off everywhere) until
# @description                     Anthropic's written OK (spec 159 O1)
# @description   SIGNIN_CMD=out    sign-out: ends the sign-in session, runs the
# @description                     CLI's own logout, removes the directory. Runs
# @description                     with the switch off too: turning it off cleans
# @description                     up (spec 159 4.4)
# @description   SIGNIN_CMD=status signed in or not, and the modes; never a
# @description                     file's content
# @description It prints no file content and no token. Dry run unless DRY_RUN=0.
# @param TENANT_ID - required: the workspace slug
# @param SIGNIN_CMD (optional) - in, out or status (default)
# @param SPL_CLAUDE_BIN (optional) - the CLI, default `claude` on PATH
# @param SPL_CLAUDE_SIGNIN_TENANTS (optional) - replaces the cnf switch (tests)
# @param SPL_CLAUDE_SIGNIN_RUNTIME (optional) - replaces <runtime> (tests)
# @param SPL_WS_USER (optional) - W's OS user, default <workspace_user_prefix><tenant>
# @param DRY_RUN (optional) - 1 (default) or 0
# @example TENANT_ID=acme ./run -a do_spl_ws_claude_signin
# @example TENANT_ID=acme SIGNIN_CMD=in DRY_RUN=0 ./run -a do_spl_ws_claude_signin
# @example TENANT_ID=acme SIGNIN_CMD=out DRY_RUN=0 ./run -a do_spl_ws_claude_signin
#------------------------------------------------------------------------------
SPL_WCS_SUBDIR=spool-claude SPL_WCS_SOCKET=spool-claude-signin

do_spl_ws_claude_signin() {
  local tenant="${TENANT_ID:-}" cmd="${SIGNIN_CMD:-status}" dry=1 u rt
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$cmd" =~ ^(in|out|status)$ ]] || { do_log "FATAL SIGNIN_CMD must be in, out or status, got: '$cmd'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  u="$(spl_box_ws_user "$tenant")" || return 1
  spl_wcs_caller_ok "$u" || return 1
  rt="$(spl_wcs_runtime)" || return 1
  case "$cmd" in
    status) spl_wcs_status "$rt/$SPL_WCS_SUBDIR" ;;
    in) spl_wcs_switch_on "$tenant" || return 3
        spl_wcs_in "$tenant" "$rt/$SPL_WCS_SUBDIR" "$dry" ;;
    out) spl_wcs_out "$tenant" "$rt/$SPL_WCS_SUBDIR" "$dry" ;;
  esac
}

# spl_wcs_caller_ok <W's user>: this process is W's OS user, which is neither
# root nor the fleet's agent user.
spl_wcs_caller_ok() {
  local me; me="$(id -un)"
  if [[ "$1" == root || ( -n "${SPOOL_AGENT_USER:-}" && "$1" == "$SPOOL_AGENT_USER" ) ]]; then
    do_log "FATAL workspace OS user '$1' is root or the fleet's agent user: a sign-in lives with W's own user"
    return 1
  fi
  [[ "$me" == "$1" ]] && return 0
  do_log "FATAL run this as the workspace's OS user '$1' (W's desk runs it), not as '$me'"
  return 1
}

# spl_wcs_runtime: W's runtime dir, owned by W, on tmpfs, outside $HOME. Its
# FATALs go to stderr: the caller captures stdout.
spl_wcs_runtime() {
  local rt="${SPL_CLAUDE_SIGNIN_RUNTIME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}" real home
  [[ -d "$rt" && "$(stat -c %u "$rt" 2>/dev/null)" == "$(id -u)" ]] ||
    { do_log "FATAL runtime dir '$rt' is missing or not owned by $(id -un): is lingering on for this user?" >&2; return 1; }
  [[ "$(stat -f -c %T "$rt" 2>/dev/null)" == tmpfs ]] ||
    { do_log "FATAL runtime dir '$rt' is not tmpfs: the sign-in file never touches a disk (spec 159 4.4)" >&2; return 1; }
  real="$(realpath -e "$rt")" home="$(realpath -m "${HOME:-/nonexistent}")"
  [[ "$real/" != "$home/"* ]] ||
    { do_log "FATAL runtime dir '$rt' is inside \$HOME ($home): the collector and the session export read the home" >&2; return 1; }
  printf '%s' "$real"
}

# spl_wcs_switch_on <tenant>: the switch names the workspace. Under
# SPOOL_TEST=1 the cnf is never read: only SPL_CLAUDE_SIGNIN_TENANTS.
spl_wcs_switch_on() {
  local list
  if [[ -n "${SPL_CLAUDE_SIGNIN_TENANTS+x}" ]]; then list="$SPL_CLAUDE_SIGNIN_TENANTS"
  elif [[ "${SPOOL_TEST:-}" != 1 ]]; then list="$(spl_box_ws_cnf claude_self_signin_tenants)"
  fi
  [[ " ${list:-} " == *" $1 "* ]] && return 0
  do_log "FATAL claude self sign-in is off for '$1': cnf env.box.claude_self_signin_tenants does not name it (spec 159 4.3: off until Anthropic's written OK, O1)"
  return 1
}

# spl_wcs_bin: the CLI, resolved.
spl_wcs_bin() {
  local b; b="$(command -v "${SPL_CLAUDE_BIN:-claude}")" ||
    { do_log "FATAL no claude CLI '${SPL_CLAUDE_BIN:-claude}' on PATH: set SPL_CLAUDE_BIN" >&2; return 1; }
  printf '%s' "$b"
}

# spl_wcs_login_argv <dir> <bin>: the login command, one word a line. The
# environment drops every other credential the CLI would take instead.
spl_wcs_login_argv() {
  printf '%s\n' env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
    "CLAUDE_CONFIG_DIR=$1" DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 "$2" auth login --claudeai
}

spl_wcs_in() {
  local t="$1" d="$2" dry="$3" b s="signin-$1"
  local -a argv=()
  b="$(spl_wcs_bin)" || return 1
  mapfile -t argv < <(spl_wcs_login_argv "$d" "$b")
  if [[ -e "$d/.credentials.json" ]]; then
    do_log "FATAL '$t' is already signed in here: sign out first (SIGNIN_CMD=out)"; return 1
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would make $d (0700) and start: tmux -L $SPL_WCS_SOCKET new-session -d -s $s ${argv[*]}"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to start the sign-in."
    return 0
  fi
  if tmux -L "$SPL_WCS_SOCKET" has-session -t "=$s" 2>/dev/null; then
    do_log "FATAL a sign-in for '$t' is already running in tmux -L $SPL_WCS_SOCKET session $s"; return 1
  fi
  (umask 077 && mkdir -p -- "$d") && chmod 0700 -- "$d" || { do_log "FATAL could not make $d"; return 1; }
  tmux -L "$SPL_WCS_SOCKET" new-session -d -s "$s" "${argv[@]}" ||
    { do_log "FATAL the sign-in session did not start"; return 1; }
  do_log "OK the sign-in for '$t' runs in tmux -L $SPL_WCS_SOCKET session $s: the person follows the vendor's link shown there"
}

spl_wcs_out() {
  local t="$1" d="$2" dry="$3" s="signin-$1" b
  if (( dry )); then
    do_log "INFO DRY_RUN would end tmux -L $SPL_WCS_SOCKET session $s, run the CLI's logout and remove $d"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to sign '$t' out."
    return 0
  fi
  tmux -L "$SPL_WCS_SOCKET" kill-session -t "=$s" 2>/dev/null
  if [[ -d "$d" ]] && b="$(spl_wcs_bin 2>/dev/null)"; then
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$d" \
      "$b" auth logout >/dev/null 2>&1
  fi
  rm -rf -- "$d"
  [[ ! -e "$d" ]] || { do_log "FATAL $d is still there after the sign-out"; return 1; }
  do_log "OK '$t' is signed out on this box: $d removed. The person can also end the session on the vendor's side."
}

spl_wcs_status() {
  local d="$1"
  if [[ -e "$d/.credentials.json" ]]; then
    do_log "OK signed in: $d mode $(stat -c %a "$d"), its sign-in file mode $(stat -c %a "$d/.credentials.json")"
  else
    do_log "OK not signed in ($d has no sign-in file)"
  fi
}
