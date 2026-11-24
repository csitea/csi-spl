#!/bin/bash
#------------------------------------------------------------------------------
# @description The VM side of the web-UI sign-in relay (spec 181 row B11, gap
# @description G11; owner Q-5, Q-14 A; spec 159 4.3). The private VM's hub-run
# @description sidecar runs it per signin_relay frame (SPOOL_SIGNIN_RELAY_CMD),
# @description as the workspace's own OS user, with SIGNIN_RELAY_OP/KIND/ID set:
# @description   start  starts the UNMODIFIED CLI's own terminal login in a tmux
# @description          session on W's socket (do_spl_ws_claude_signin's
# @description          directory and argv) and reports the vendor URL it prints
# @description   input  reads ONE line from stdin (never argv or env), pastes it
# @description          into that login through a tmux buffer, presses Enter;
# @description          reports signed_in when the CLI holds a sign-in, else
# @description          delivered. The line is never printed or logged
# @description   end    ends the login session (a sign-in already made stays;
# @description          sign-out is do_spl_ws_claude_signin SIGNIN_CMD=out)
# @description One switch per vendor, default off: cnf env.box.signin_relay_kinds
# @description (absent = off) must name the kind, else start and input are
# @description refused rc 3; end runs with the switch off too. The hub has its
# @description own switch (SPOOL_HUB_SIGNIN_RELAY_KINDS). Only claude has a
# @description terminal login wired here. Its last stdout line is the report:
# @description `SIGNIN_RELAY state=<s> [url=<u>] [reason=<r>]`. Dry run unless DRY_RUN=0.
# @param TENANT_ID (required) - the workspace slug
# @param SIGNIN_RELAY_OP (optional) - start, input or end (default start)
# @param SIGNIN_RELAY_KIND (optional) - the vendor kind (default claude)
# @param SIGNIN_RELAY_ID (optional) - the hub's relay id, logged only
# @param SPL_SIGNIN_RELAY_KINDS (optional) - replaces the cnf switch (tests)
# @param SPL_SIGNIN_RELAY_WAIT (optional) - seconds to wait for the URL or the sign-in (default 30)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example TENANT_ID=acme SIGNIN_RELAY_OP=start ./run -a do_spl_ws_signin_relay
# @example printf '%s\n' "$CODE" | TENANT_ID=acme SIGNIN_RELAY_OP=input DRY_RUN=0 ./run -a do_spl_ws_signin_relay
#------------------------------------------------------------------------------

do_spl_ws_signin_relay() {
  local tenant="${TENANT_ID:-}" op="${SIGNIN_RELAY_OP:-start}" kind="${SIGNIN_RELAY_KIND:-claude}" dry=1 u rt d
  spl_require_tenant_slug "$tenant" || { spl_wsr_report failed bad_tenant; return 1; }
  [[ "$op" =~ ^(start|input|end)$ ]] || { do_log "FATAL SIGNIN_RELAY_OP must be start, input or end, got: '$op'"; spl_wsr_report failed bad_op; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  u="$(spl_box_ws_user "$tenant")" || { spl_wsr_report failed bad_user; return 1; }
  spl_wcs_caller_ok "$u" || { spl_wsr_report failed wrong_user; return 1; }
  rt="$(spl_wcs_runtime)" || { spl_wsr_report failed no_runtime; return 1; }
  d="$rt/$SPL_WCS_SUBDIR"
  do_log "INFO sign-in relay ${SIGNIN_RELAY_ID:-<no id>}: $op $kind for '$tenant'"
  if [[ "$op" == end ]]; then spl_wsr_end "$tenant" "$dry"; return; fi
  spl_wsr_switch_on "$kind" || { spl_wsr_report failed switch_off; return 3; }
  [[ "$kind" == claude ]] || { do_log "FATAL no terminal login is wired for '$kind' on this VM"; spl_wsr_report failed no_login; return 1; }
  case "$op" in
    start) spl_wsr_start "$tenant" "$d" "$dry" ;;
    input) spl_wsr_input "$tenant" "$d" "$dry" ;;
  esac
}

# spl_wsr_report <state> [reason] [url]: the report line the sidecar reads.
spl_wsr_report() {
  local line="SIGNIN_RELAY state=$1"
  [[ -n "${3:-}" ]] && line+=" url=$3"
  [[ -n "${2:-}" ]] && line+=" reason=$2"
  printf '%s\n' "$line"
}

# spl_wsr_switch_on <kind>: the VM's switch names the kind. Under
# SPOOL_TEST=1 the cnf is never read: only SPL_SIGNIN_RELAY_KINDS.
spl_wsr_switch_on() {
  local list=""
  if [[ -n "${SPL_SIGNIN_RELAY_KINDS+x}" ]]; then list="$SPL_SIGNIN_RELAY_KINDS"
  elif [[ "${SPOOL_TEST:-}" != 1 ]]; then list="$(spl_box_ws_cnf signin_relay_kinds)"
  fi
  [[ " ${list//,/ } " == *" $1 "* ]] && return 0
  do_log "FATAL the sign-in relay is off for '$1' on this VM: cnf env.box.signin_relay_kinds does not name it (spec 181 Q-14 A: on only after the vendor's written OK)"
  return 1
}

# spl_wsr_wait <seconds> <cmd...>: run cmd once a second until it succeeds.
spl_wsr_wait() {
  local n="$1" i; shift
  for ((i = 0; i <= n; i++)); do
    "$@" && return 0
    (( i < n )) && sleep 1
  done
  return 1
}

# spl_wsr_url <session>: the first https URL the login's pane shows.
spl_wsr_url() {
  tmux -L "$SPL_WCS_SOCKET" capture-pane -p -J -t "=$1" 2>/dev/null | tr -d '\r' |
    grep -oE 'https://[^[:space:]]+' | sed -n 1p
}

spl_wsr_start() {
  local t="$1" d="$2" dry="$3" s="signin-$1" url
  if (( dry )); then
    spl_wcs_in "$t" "$d" 1
    spl_wsr_report failed dry_run; return 0
  fi
  if ! tmux -L "$SPL_WCS_SOCKET" has-session -t "=$s" 2>/dev/null; then
    spl_wcs_in "$t" "$d" 0 >/dev/null || { spl_wsr_report failed login_not_started; return 1; }
  fi
  url=""
  spl_wsr_wait "${SPL_SIGNIN_RELAY_WAIT:-30}" spl_wsr_has_url "$s" && url="$(spl_wsr_url "$s")"
  if [[ -z "$url" ]]; then
    do_log "FATAL the login printed no https URL in ${SPL_SIGNIN_RELAY_WAIT:-30} s"
    spl_wsr_report failed no_url; return 1
  fi
  do_log "OK the login for '$t' shows its vendor URL; it is reported to the person, not logged"
  spl_wsr_report url "" "$url"
}

spl_wsr_has_url() { [[ -n "$(spl_wsr_url "$1")" ]]; }

# spl_wsr_input: stdin's first line into the login, through a tmux buffer
# (tmux reads it from stdin: never an argv), then Enter.
spl_wsr_input() {
  local t="$1" d="$2" dry="$3" s="signin-$1" b="spool-signin-$1" line=""
  IFS= read -r line || [[ -n "$line" ]] || { do_log "FATAL no input on stdin"; spl_wsr_report failed no_input; return 1; }
  if (( dry )); then
    line=""
    do_log "OK DRY_RUN would paste the input into tmux -L $SPL_WCS_SOCKET session $s and press Enter"
    spl_wsr_report failed dry_run; return 0
  fi
  tmux -L "$SPL_WCS_SOCKET" has-session -t "=$s" 2>/dev/null ||
    { line=""; do_log "FATAL no login session for '$t': start one first"; spl_wsr_report failed no_session; return 1; }
  printf '%s' "$line" | tmux -L "$SPL_WCS_SOCKET" load-buffer -b "$b" - &&
    tmux -L "$SPL_WCS_SOCKET" paste-buffer -d -b "$b" -t "=$s" &&
    tmux -L "$SPL_WCS_SOCKET" send-keys -t "=$s" Enter
  local rc=$?
  line=""
  (( rc == 0 )) || { do_log "FATAL the input did not reach the login session"; spl_wsr_report failed not_delivered; return 1; }
  if spl_wsr_wait "${SPL_SIGNIN_RELAY_WAIT:-30}" test -e "$d/.credentials.json"; then
    do_log "OK '$t' is signed in on this VM"; spl_wsr_report signed_in; return 0
  fi
  do_log "OK the input reached the login; no sign-in file yet"
  spl_wsr_report delivered
}

spl_wsr_end() {
  local t="$1" dry="$2" s="signin-$1"
  if (( dry )); then
    do_log "OK DRY_RUN would end tmux -L $SPL_WCS_SOCKET session $s"
    spl_wsr_report failed dry_run; return 0
  fi
  tmux -L "$SPL_WCS_SOCKET" kill-session -t "=$s" 2>/dev/null
  do_log "OK the login session for '$t' is ended"
  spl_wsr_report ended
}
