#!/bin/bash
#------------------------------------------------------------------------------
# @description The box side of the web-UI sign-in relay (spec 181 row B11;
# @description spec 192 row L3; owner Q-5, Q-14 A; spec 159 4.3). A desk's
# @description hub-run sidecar runs it per signin_relay frame
# @description (SPOOL_SIGNIN_RELAY_CMD, wired by do_spl_desk_up when cnf
# @description env.box.signin_relay_kinds is not empty) with SIGNIN_RELAY_OP/
# @description KIND/ID set. The OS user is the one the BOX binds to the
# @description workspace (spec 192 section 2), never one the hub frame names:
# @description   box claimed by W (dedicated, or W hosted on a fleet box): the
# @description     owner of <base>/<W>, never root or the fleet's agent user;
# @description     the login lives in W's runtime dir (do_spl_ws_claude_signin's)
# @description   box with no claim (operator box): the operator workspace
# @description     only (the desk's SPOOL_TENANT), as SPOOL_AGENT_USER, its main
# @description     login (slot 1); a workspace hosted on this box, or with an OS
# @description     user here, is a customer's and is refused
# @description Any other workspace, or a caller that is not that user, is
# @description refused (R7, R10). The ops:
# @description   start  the UNMODIFIED CLI's own terminal login in a tmux session
# @description          on the user's socket; reports the vendor URL it prints
# @description   input  ONE line from stdin (never argv or env) pasted into that
# @description          login through a tmux buffer, then Enter; signed_in once
# @description          the login file changed, else delivered. Never printed
# @description   end    ends the login session (a sign-in already made stays)
# @description   out    ends it, runs the CLI's own logout as that user and
# @description          removes that user's login files only; signed_out
# @description   renew  start, keeping the account label (acct-<8 hex>) of the
# @description          login before it; the input that signs in then reports
# @description          failed other_account when the new label differs
# @description   status one line: signed_in, account label, plan, expiry, weekly
# @description          %, reset. Never a token, a code or an email (R1)
# @description   copy   do_spl_ws_login_copy when loaded (row L8), else no_copy
# @description One switch per vendor, default off: cnf env.box.signin_relay_kinds
# @description (absent = off) must name the kind, else start, input and renew
# @description are refused rc 3; end, out, status and copy run with it off. The
# @description hub has its own switch. claude is wired here; another kind runs
# @description through row L4's kinds file (SPL_WSR_KINDS_FILE) when present, else
# @description no_login. Its last stdout line is the report:
# @description `SIGNIN_RELAY state=<s> [url=<u>] [reason=<r>] [k=v...]`. Dry run unless DRY_RUN=0.
# @param TENANT_ID (required) - the workspace slug
# @param SIGNIN_RELAY_OP (optional) - start, input, end, out, renew, status or copy (default start)
# @param SIGNIN_RELAY_KIND (optional) - the vendor kind (default claude)
# @param SIGNIN_RELAY_ID (optional) - the hub's relay id, logged only
# @param SPOOL_TENANT (optional) - the desk's own workspace; needed on a box with no claim
# @param SPOOL_AGENT_USER (optional) - the fleet's agent user (box.env); needed on a box with no claim
# @param SPL_SIGNIN_RELAY_KINDS (optional) - replaces the cnf switch (tests)
# @param SPL_SIGNIN_RELAY_WAIT (optional) - seconds to wait for the URL or the sign-in (default 30)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example TENANT_ID=acme SIGNIN_RELAY_OP=status ./run -a do_spl_ws_signin_relay
# @example printf '%s\n' "$CODE" | TENANT_ID=acme SIGNIN_RELAY_OP=input DRY_RUN=0 ./run -a do_spl_ws_signin_relay
#------------------------------------------------------------------------------

do_spl_ws_signin_relay() {
  local tenant="${TENANT_ID:-}" op="${SIGNIN_RELAY_OP:-start}" kind="${SIGNIN_RELAY_KIND:-claude}" dry=1
  spl_require_tenant_slug "$tenant" || { spl_wsr_report failed bad_tenant; return 1; }
  [[ "$op" =~ ^(start|input|end|out|renew|status|copy)$ ]] ||
    { do_log "FATAL SIGNIN_RELAY_OP must be start, input, end, out, renew, status or copy, got: '$op'"; spl_wsr_report failed bad_op; return 1; }
  [[ "$kind" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL SIGNIN_RELAY_KIND is no vendor kind: '$kind'"; spl_wsr_report failed bad_kind; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local WSR_USER="" WSR_MODE="" WSR_DIR="" WSR_JSON="" WSR_CFG=""
  spl_wsr_bind "$tenant" || return 1
  do_log "INFO sign-in relay ${SIGNIN_RELAY_ID:-<no id>}: $op $kind for '$tenant' ($WSR_MODE binding)"
  case "$op" in
    copy) spl_wsr_copy "$tenant" "$kind" "$dry"; return ;;
    end) spl_wsr_end "$tenant" "$dry"; return ;;
  esac
  if [[ "$op" =~ ^(start|input|renew)$ ]]; then
    spl_wsr_switch_on "$kind" || { spl_wsr_report failed switch_off; return 3; }
  fi
  if [[ "$kind" != claude ]]; then spl_wsr_kind "$op" "$tenant" "$kind" "$dry"; return; fi
  case "$op" in
    start|renew) spl_wsr_start "$tenant" "$dry" "$op" ;;
    input) spl_wsr_input "$tenant" "$kind" "$dry" ;;
    out) spl_wsr_out "$tenant" "$kind" "$dry" ;;
    status) spl_wsr_status ;;
  esac
}

# spl_wsr_report <state> [reason] [url] [k=v...]: the report line the sidecar reads.
spl_wsr_report() {
  local line="SIGNIN_RELAY state=$1"
  [[ -n "${3:-}" ]] && line+=" url=$3"
  [[ -n "${2:-}" ]] && line+=" reason=$2"
  (( $# > 3 )) && { shift 3; line+=" $*"; }
  printf '%s\n' "$line"
}

# spl_wsr_bind <tenant>: the OS user, login dir, .claude.json and config env
# of <tenant> on THIS box, from the box's own binding (spec 192 section 2).
# Sets WSR_USER, WSR_MODE (operator|workspace), WSR_DIR, WSR_JSON, WSR_CFG;
# reports and returns 1 on a refusal.
spl_wsr_bind() {
  local t="$1" claim rt want
  claim="$(spl_box_ws_claim)"
  if [[ -z "$claim" ]]; then spl_wsr_bind_operator "$t"; return; fi
  if [[ "$claim" != "$t" ]]; then
    do_log "FATAL this box belongs to workspace '$claim': a sign-in for '$t' is refused (spec 192 R7)"
    spl_wsr_report failed other_workspace; return 1
  fi
  WSR_USER="$(stat -c %U "$(spl_box_ws_base)/$t" 2>/dev/null)" ||
    { do_log "FATAL no binding of '$t' on this box (re-run its enrolment)"; spl_wsr_report failed no_binding; return 1; }
  want="$(spl_box_ws_user "$t")" || { spl_wsr_report failed bad_user; return 1; }
  if [[ "$WSR_USER" != "$want" ]]; then
    do_log "FATAL the binding of '$t' is owned by '$WSR_USER', not its workspace user '$want'"
    spl_wsr_report failed bad_user; return 1
  fi
  spl_wcs_caller_ok "$WSR_USER" || { spl_wsr_report failed wrong_user; return 1; }
  rt="$(spl_wcs_runtime)" || { spl_wsr_report failed no_runtime; return 1; }
  WSR_MODE=workspace WSR_DIR="$rt/$SPL_WCS_SUBDIR"
  WSR_JSON="$WSR_DIR/.claude.json" WSR_CFG="CLAUDE_CONFIG_DIR=$WSR_DIR"
}

# spl_wsr_bind_operator <tenant>: a box with no claim serves the operator
# workspace only, as the fleet's agent user and its main login.
spl_wsr_bind_operator() {
  local t="$1" me fb=""
  if [[ -z "${SPOOL_TENANT:-}" || "$t" != "$SPOOL_TENANT" ]]; then
    do_log "FATAL this desk serves workspace '${SPOOL_TENANT:-<none>}': a sign-in for '$t' is refused (spec 192 R7)"
    spl_wsr_report failed other_workspace; return 1
  fi
  if [[ -n "${SPL_FLEET_WS_BASE+x}" ]]; then fb="$SPL_FLEET_WS_BASE"
  elif [[ "${SPOOL_TEST:-}" != 1 ]]; then fb="$(spl_box_ws_cnf fleet_workspace_base)"
  fi
  if [[ -n "$fb" && -e "$fb/$t" ]] || getent passwd "$(spl_box_ws_prefix)$t" >/dev/null 2>&1; then
    do_log "FATAL '$t' is a customer workspace on this box: it signs in as its own OS user, never the fleet's (spec 192 R7)"
    spl_wsr_report failed customer_user; return 1
  fi
  me="$(id -un)"
  if [[ -z "${SPOOL_AGENT_USER:-}" || "$SPOOL_AGENT_USER" == root || "$me" != "$SPOOL_AGENT_USER" ]]; then
    do_log "FATAL the operator workspace signs in as the fleet's agent user '${SPOOL_AGENT_USER:-<unset>}', not '$me'"
    spl_wsr_report failed wrong_user; return 1
  fi
  WSR_USER="$me" WSR_MODE=operator WSR_DIR="$HOME/.claude" WSR_JSON="$HOME/.claude.json" WSR_CFG=""
}

# spl_wsr_switch_on <kind>: the box's switch names the kind. Under
# SPOOL_TEST=1 the cnf is never read: only SPL_SIGNIN_RELAY_KINDS.
spl_wsr_switch_on() {
  local list=""
  if [[ -n "${SPL_SIGNIN_RELAY_KINDS+x}" ]]; then list="$SPL_SIGNIN_RELAY_KINDS"
  elif [[ "${SPOOL_TEST:-}" != 1 ]]; then list="$(spl_box_ws_cnf signin_relay_kinds)"
  fi
  [[ " ${list//,/ } " == *" $1 "* ]] && return 0
  do_log "FATAL the sign-in relay is off for '$1' on this box: cnf env.box.signin_relay_kinds does not name it (spec 181 Q-14 A: on only after the vendor's written OK)"
  return 1
}

# spl_wsr_kind <op> <tenant> <kind> <dry>: seam 1 (row L4). A kind other than
# claude runs through spl_wsk_<kind> <op> <tenant> <user> <dry> from
# row L4's kinds file (SPL_WSR_KINDS_FILE, lib/bash/funcs).
spl_wsr_kind() {
  local f="${SPL_WSR_KINDS_FILE:-$PROJ_PATH/lib/bash/funcs/spl-ws-signin-kinds.func.sh}" fn="spl_wsk_${3//-/_}"
  # shellcheck source=/dev/null  # row L4's file, absent until it lands
  declare -F "$fn" >/dev/null || { [[ -r "$f" ]] && source "$f"; }
  if declare -F "$fn" >/dev/null; then "$fn" "$1" "$2" "$WSR_USER" "$4"; return; fi
  do_log "FATAL no terminal login is wired for '$3' on this box"
  spl_wsr_report failed no_login; return 1
}

# spl_wsr_after_switch <tenant> <kind> <dry>: seam 2 (row L5), run after a
# sign-in or a sign-out; a no-op unless do_spl_ws_vendor_restart is loaded.
# Its output goes to stderr: the report stays the last stdout line.
spl_wsr_after_switch() {
  declare -F do_spl_ws_vendor_restart >/dev/null || return 0
  TENANT_ID="$1" VENDOR_KIND="$2" DRY_RUN="$3" do_spl_ws_vendor_restart >&2 || true
}

# spl_wsr_copy <tenant> <kind> <dry>: seam 3 (row L8), into this user only.
spl_wsr_copy() {
  if declare -F do_spl_ws_login_copy >/dev/null; then
    TENANT_ID="$1" VENDOR_KIND="$2" WS_LOGIN_USER="$WSR_USER" DRY_RUN="$3" do_spl_ws_login_copy; return
  fi
  do_log "FATAL no login copy is wired on this box"
  spl_wsr_report failed no_copy; return 1
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

spl_wsr_has_url() { [[ -n "$(spl_wsr_url "$1")" ]]; }

# spl_wsr_label: the login's account label, "acct-<8 hex>" or "none".
spl_wsr_label() {
  local u
  u="$(jq -r '.oauthAccount.accountUuid // empty' "$WSR_JSON" 2>/dev/null)"
  if [[ -n "$u" ]]; then printf 'acct-%s\n' "$(printf '%s' "$u" | sha256sum | cut -c1-8)"; else echo none; fi
}

# spl_wsr_mark: the login file's sha12, or "none": a change is a new sign-in.
spl_wsr_mark() {
  [[ -e "$WSR_DIR/.credentials.json" ]] || { echo none; return; }
  sha256sum "$WSR_DIR/.credentials.json" 2>/dev/null | cut -c1-12
}

spl_wsr_changed() { local m; m="$(spl_wsr_mark)"; [[ "$m" != none && "$m" != "$1" ]]; }

# spl_wsr_login_argv <bin>: the login command, one word a line. The
# environment drops every other credential the CLI would take instead.
spl_wsr_login_argv() {
  printf '%s\n' env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN
  [[ -n "$WSR_CFG" ]] && printf '%s\n' "$WSR_CFG"
  printf '%s\n' DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 "$1" auth login --claudeai
}

# spl_wsr_open <session> <op>: a new login session; it keeps the login
# file's mark (@spl_mark) and, for a renew, the label before it (@spl_prior).
spl_wsr_open() {
  local s="$1" op="$2" b
  local -a argv=()
  b="$(spl_wcs_bin)" || return 1
  mapfile -t argv < <(spl_wsr_login_argv "$b")
  (umask 077 && mkdir -p -- "$WSR_DIR") && chmod 0700 -- "$WSR_DIR" || return 1
  tmux -L "$SPL_WCS_SOCKET" new-session -d -s "$s" "${argv[@]}" || return 1
  tmux -L "$SPL_WCS_SOCKET" set-option -t "=$s" @spl_mark "$(spl_wsr_mark)" >/dev/null 2>&1
  [[ "$op" == renew ]] && tmux -L "$SPL_WCS_SOCKET" set-option -t "=$s" @spl_prior "$(spl_wsr_label)" >/dev/null 2>&1
  return 0
}

# spl_wsr_start <tenant> <dry> <start|renew>
spl_wsr_start() {
  local t="$1" dry="$2" op="$3" s="signin-$1" url
  if (( dry )); then
    do_log "OK DRY_RUN would start the CLI's own login as $WSR_USER in tmux -L $SPL_WCS_SOCKET session $s ($op)"
    spl_wsr_report failed dry_run; return 0
  fi
  if ! tmux -L "$SPL_WCS_SOCKET" has-session -t "=$s" 2>/dev/null; then
    if [[ "$op" == start && -e "$WSR_DIR/.credentials.json" ]]; then
      do_log "FATAL '$t' is already signed in here: renew or sign out first"; spl_wsr_report failed signed_in_already; return 1
    fi
    spl_wsr_open "$s" "$op" || { do_log "FATAL the login session did not start"; spl_wsr_report failed login_not_started; return 1; }
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

# spl_wsr_opt <session> <option>: a session option, or nothing.
spl_wsr_opt() { tmux -L "$SPL_WCS_SOCKET" show-options -v -t "=$1" "$2" 2>/dev/null | tr -d '[:space:]'; }

# spl_wsr_input: stdin's first line into the login, through a tmux buffer
# (tmux reads it from stdin: never an argv), then Enter.
spl_wsr_input() {
  local t="$1" kind="$2" dry="$3" s="signin-$1" b="spool-signin-$1" line="" mark prior now
  IFS= read -r line || [[ -n "$line" ]] || { do_log "FATAL no input on stdin"; spl_wsr_report failed no_input; return 1; }
  if (( dry )); then
    line=""
    do_log "OK DRY_RUN would paste the input into tmux -L $SPL_WCS_SOCKET session $s and press Enter"
    spl_wsr_report failed dry_run; return 0
  fi
  tmux -L "$SPL_WCS_SOCKET" has-session -t "=$s" 2>/dev/null ||
    { line=""; do_log "FATAL no login session for '$t': start one first"; spl_wsr_report failed no_session; return 1; }
  mark="$(spl_wsr_opt "$s" @spl_mark)" prior="$(spl_wsr_opt "$s" @spl_prior)"
  printf '%s' "$line" | tmux -L "$SPL_WCS_SOCKET" load-buffer -b "$b" - &&
    tmux -L "$SPL_WCS_SOCKET" paste-buffer -d -b "$b" -t "=$s" &&
    tmux -L "$SPL_WCS_SOCKET" send-keys -t "=$s" Enter
  local rc=$?
  line=""
  (( rc == 0 )) || { do_log "FATAL the input did not reach the login session"; spl_wsr_report failed not_delivered; return 1; }
  if ! spl_wsr_wait "${SPL_SIGNIN_RELAY_WAIT:-30}" spl_wsr_changed "${mark:-none}"; then
    do_log "OK the input reached the login; no new sign-in yet"; spl_wsr_report delivered; return 0
  fi
  spl_wsr_after_switch "$t" "$kind" "$dry"
  now="$(spl_wsr_label)"
  if [[ -n "$prior" && "$prior" != none && "$now" != "$prior" ]]; then
    do_log "FATAL the renew signed '$t' in to another account ($now, was $prior)"
    spl_wsr_report failed other_account "" "account=$now"; return 1
  fi
  do_log "OK '$t' is signed in on this box ($now)"; spl_wsr_report signed_in "" "" "account=$now"
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

# spl_wsr_out <tenant> <kind> <dry>: the CLI's own logout as this user; then
# only this user's login files go: W's whole runtime login dir, or the
# operator's main login file (its ~/.claude keeps the sessions).
spl_wsr_out() {
  local t="$1" kind="$2" dry="$3" s="signin-$1" b
  if (( dry )); then
    do_log "OK DRY_RUN would end session $s, run the CLI's logout as $WSR_USER and remove its login files"
    spl_wsr_report failed dry_run; return 0
  fi
  tmux -L "$SPL_WCS_SOCKET" kill-session -t "=$s" 2>/dev/null
  if [[ -d "$WSR_DIR" ]] && b="$(spl_wcs_bin 2>/dev/null)"; then
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN ${WSR_CFG:+"$WSR_CFG"} "$b" auth logout >/dev/null 2>&1
  fi
  if [[ "$WSR_MODE" == workspace ]]; then rm -rf -- "$WSR_DIR"; else rm -f -- "$WSR_DIR/.credentials.json"; fi
  [[ ! -e "$WSR_DIR/.credentials.json" ]] || { do_log "FATAL the login file of '$t' is still there"; spl_wsr_report failed not_signed_out; return 1; }
  spl_wsr_after_switch "$t" "$kind" "$dry"
  do_log "OK '$t' is signed out on this box"
  spl_wsr_report signed_out
}

# spl_wsr_status: one non-secret line (R1): a yes/no, the label, the plan the
# CLI's own status names, the access expiry (epoch s), the weekly % and reset.
spl_wsr_status() {
  local in=no acct plan=unknown exp=unknown wk=unknown rs=unknown b c q=""
  if [[ -e "$WSR_DIR/.credentials.json" ]]; then
    in=yes
    c="$(jq -r '.claudeAiOauth.expiresAt // empty | numbers | floor' "$WSR_DIR/.credentials.json" 2>/dev/null)"
    if [[ "$c" =~ ^[0-9]+$ ]]; then exp=$(( c / 1000 )); (( exp <= $(date +%s) )) && in=expired; fi
  fi
  acct="$(spl_wsr_label)"
  if [[ "$in" != no ]] && b="$(spl_wcs_bin 2>/dev/null)"; then
    c="$(env ${WSR_CFG:+"$WSR_CFG"} "$b" auth status --json 2>/dev/null | jq -r '.subscriptionType // empty | strings' 2>/dev/null)"
    [[ "$c" =~ ^[a-z0-9_-]{1,20}$ ]] && plan="$c"
  fi
  [[ -r "$WSR_JSON" ]] && q="$(BOX_QUOTA_RESET=1 spl_box_quota_cache_read 2>/dev/null <"$WSR_JSON")"
  [[ "$q" =~ ^([0-9]{1,3})@([0-9]+)$ ]] && wk="${BASH_REMATCH[1]}" rs="${BASH_REMATCH[2]}"
  spl_wsr_report status "" "" "signed_in=$in account=$acct plan=$plan expires=$exp weekly=$wk reset=$rs"
}
