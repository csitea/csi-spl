#!/bin/bash
#------------------------------------------------------------------------------
# @description Host ONE workspace on THIS fleet box (spec 159 5.2, row T3; owner
# @description HUM-10 Q-1 B, msg 2e9d03be): the workspace's seats run here as
# @description its own OS user, never as the fleet's agent user. It makes, as
# @description root (sudo -n), under <base> = cnf env.box.fleet_workspace_base:
# @description   1. <base>/<tenant>/ root-owned 0755, holding the claim (the one
# @description      workspace slug) and the marker fleet-hosted: the spec 108
# @description      shape, so `spool join` declares the desk dedicated and the
# @description      desk guard (spl_box_ws_guard) applies to it
# @description   2. the OS user <workspace_user_prefix><tenant>, a system user in
# @description      its own group ONLY: no -G, no sudoers entry, in none of sudo,
# @description      wheel, admin, docker, lxd, disk; home <base>/<tenant>/<tenant>
# @description      0700 with spool/ and state/; lingering on, so its tmpfs
# @description      /run/user/<uid> exists with no login
# @description   3. a check that the user holds no root path (`id -nG`, `sudo -l -U`)
# @description   4. the desk, started as that user with SPL_WS_BASE=<base>/<tenant>:
# @description      its seat dir <runtime>/spool-seat emptied (spec 127 5.4), then
# @description      do_spl_desk_up, whose guard runs the desk start checks (spec
# @description      127 5.3 with spec 159 5.2's one exception) and refuses the
# @description      desk when one fails. The FIRST start enrols with a join token
# @description      a workspace admin minted for this box and workspace (spec 073:
# @description      one use), read from a file and handed over on stdin only.
# @description A box enrolled into one workspace (spec 108 claim) is not a fleet
# @description box and is refused (exit 3). DRY_RUN=0 writes root files on this
# @description box: it needs the owner's go for this box (spec 159 12.2), named
# @description by OWNER_GO. Dry run unless DRY_RUN=0. Idempotent.
# @param TENANT_ID - required: the workspace slug to host here
# @param ENV - required for the desk: dev or prd
# @param DESK_BOX - required for the desk: the box id W's desk pins as
# @param DESK_AGENT - required for the desk: the agent id the desk seats
# @param SPOOL_JOIN_TOKEN_FILE (optional) - a file holding W's join token for
# @param   this box (spj1.<tenant>.<secret>); needed on the first desk start only
# @param OWNER_GO (optional) - required with DRY_RUN=0: the owner's msg id
# @param   (8+ hex) of the go for this box
# @param FLEET_WS_DESK (optional) - 1 (default) starts the desk; 0 only the user
# @param SPL_FLEET_WS_BASE (optional) - override cnf env.box.fleet_workspace_base
# @param SPL_WS_USER_PREFIX (optional) - override cnf env.box.workspace_user_prefix
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=acme DESK_BOX=acme-fleet1 DESK_AGENT=c-101 ./run -a do_spl_fleet_ws_host
# @example ENV=dev TENANT_ID=acme DESK_BOX=acme-fleet1 DESK_AGENT=c-101 SPOOL_JOIN_TOKEN_FILE=<file> OWNER_GO=<msg id> DRY_RUN=0 ./run -a do_spl_fleet_ws_host
#------------------------------------------------------------------------------
do_spl_fleet_ws_host() {
  local tenant="${TENANT_ID:-}" dry=1 fb b u desk="${FLEET_WS_DESK:-1}"
  spl_require_tenant_slug "$tenant" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "$desk" == 0 || "$desk" == 1 ]] || { do_log "FATAL FLEET_WS_DESK must be 0 or 1, got: '$desk'"; return 1; }
  if [[ -n "$(spl_box_ws_claim)" ]]; then
    do_log "FATAL this box is enrolled into workspace '$(spl_box_ws_claim)' (spec 108 claim): it is not a fleet box"
    return 3
  fi
  fb="$(spl_fws_base)" || return 1
  b="$fb/$tenant"
  u="$(spl_box_ws_user "$tenant")" || return 1
  spl_fws_user_ok "$u" || return 1
  (( desk == 0 )) || spl_fws_desk_args_ok "$tenant" || return 1
  if (( dry == 0 )); then
    [[ "${OWNER_GO:-}" =~ ^[0-9a-f]{8}([0-9a-f-]*)$ ]] ||
      { do_log "FATAL DRY_RUN=0 writes root files on this box: set OWNER_GO=<owner msg id> of the go for this box (spec 159 12.2)"; return 1; }
  fi

  local -a cmds=()
  mapfile -t cmds < <(spl_fws_setup_cmds "$fb" "$tenant" "$u")
  if (( dry )); then
    do_log "INFO DRY_RUN would run as root:"; printf '    %s\n' "${cmds[@]}"
    do_log "INFO DRY_RUN would check that $u is in its own group only and has no sudo grant"
    (( desk == 0 )) || do_log "INFO DRY_RUN would empty $u's seat dir, then start the desk: $(spl_fws_desk_line "$b" "$u")"
    do_log "OK DRY_RUN nothing was touched. Re-run with OWNER_GO=<msg id> DRY_RUN=0 to host '$tenant' on this box."
    return 0
  fi
  do_log "INFO hosting '$tenant' on this box as $u (owner go $OWNER_GO)"
  _spool_root_run_as_root "${cmds[@]}" || return 1
  spl_fws_verify "$b" "$tenant" "$u" || return 1
  do_log "OK workspace '$tenant' is hosted here: user $u, base $b"
  (( desk == 1 )) || return 0
  spl_fws_desk_start "$b" "$tenant" "$u"
}

# spl_fws_base: SPL_FLEET_WS_BASE > cnf env.box.fleet_workspace_base (never
# read under SPOOL_TEST=1); an absolute path, not /.
spl_fws_base() {
  local b="${SPL_FLEET_WS_BASE:-}"
  [[ -n "$b" || "${SPOOL_TEST:-}" == 1 ]] || b="$(spl_box_ws_cnf fleet_workspace_base)"
  [[ "$b" == /* && "$b" != / ]] || { do_log "FATAL the fleet workspace base must be an absolute path (cnf env.box.fleet_workspace_base or SPL_FLEET_WS_BASE), got: '$b'"; return 1; }
  printf '%s' "$b"
}

# spl_fws_user_ok <user>: never the fleet's agent user, never the caller.
spl_fws_user_ok() {
  local fleet="${SPOOL_AGENT_USER:-}"
  [[ "$1" != root && "$1" != "$(id -un)" && ( -z "$fleet" || "$1" != "$fleet" ) ]] && return 0
  do_log "FATAL workspace OS user '$1' is root, the caller or the fleet's agent user: a hosted workspace runs as its own user"
  return 1
}

spl_fws_desk_args_ok() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd for the desk, got: '${ENV:-}'"; return 1; }
  [[ "${DESK_BOX:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$DESK_BOX" != box-wui ]] ||
    { do_log "FATAL DESK_BOX '${DESK_BOX:-}' is not a box id: name the box W's desk pins as"; return 1; }
  [[ -n "${DESK_AGENT:-}" ]] || { do_log "FATAL DESK_AGENT is required for the desk (FLEET_WS_DESK=0 hosts the user only)"; return 1; }
  local f="${SPOOL_JOIN_TOKEN_FILE:-}"
  [[ -z "$f" ]] && return 0
  [[ -r "$f" ]] || { do_log "FATAL SPOOL_JOIN_TOKEN_FILE $f is not readable"; return 1; }
  local tok; tok="$(head -n 1 "$f" | tr -d '[:space:]')"
  [[ "$tok" == "spj1.$1."?* ]] ||
    { do_log "FATAL SPOOL_JOIN_TOKEN_FILE does not hold a join token of workspace '$1' (spj1.$1.<secret>): mint one for this box in Settings -> Agents"; return 1; }
}

# spl_fws_setup_cmds <fleet base> <tenant> <user>: the root commands, one a
# line. useradd gets no -G: the user is in its own group only.
spl_fws_setup_cmds() {
  local fb="$1" t="$2" u="$3" b="$1/$2" w="$1/$2/$2"
  echo "mkdir -p '$fb' '$b' && chown root:root '$fb' '$b' && chmod 0755 '$fb' '$b'"
  echo "getent passwd '$u' >/dev/null || useradd --system --user-group --home-dir '$w' --no-create-home --shell /bin/bash '$u'"
  echo "mkdir -p '$w/spool' '$w/state'"
  echo "[ -e '$w/spool/box.env' ] || printf 'SPOOL_AGENT_USER=%s\nSPOOL_FLEET_TENANT=%s\n' '$u' '$t' >'$w/spool/box.env'"
  echo "chown -R '$u:$u' '$w' && chmod 0700 '$w' '$w/spool' '$w/state'"
  echo "printf '%s\n' '$t' >'$b/claim.tmp' && chmod 0644 '$b/claim.tmp' && mv -f '$b/claim.tmp' '$b/claim'"
  echo "printf 'spec 159 T3\n' >'$b/fleet-hosted' && chmod 0644 '$b/fleet-hosted'"
  echo "loginctl enable-linger '$u'"
}

# spl_fws_verify <base> <tenant> <user>: the layout holds and the user has no
# root path: its own group only, and sudo lists nothing for it.
spl_fws_verify() {
  local b="$1" t="$2" u="$3" d got g sl
  local -a as_root=()
  (( EUID == 0 )) || as_root=(sudo -n)
  for d in "$b/$t" "$b/$t/spool" "$b/$t/state"; do
    got="$("${as_root[@]}" stat -c '%a %U' "$d" 2>/dev/null)"
    [[ "$got" == "700 $u" ]] || { do_log "FATAL $d is '$got', want '700 $u'"; return 1; }
  done
  [[ "$("${as_root[@]}" head -n 1 "$b/claim" 2>/dev/null)" == "$t" && -e "$b/fleet-hosted" ]] ||
    { do_log "FATAL $b lacks its claim or its fleet-hosted marker"; return 1; }
  g="$(id -nG "$u" 2>/dev/null)"
  [[ "$g" == "$u" ]] || { do_log "FATAL $u is in groups '$g', want its own group only"; return 1; }
  sl="$("${as_root[@]}" sudo -n -l -U "$u" 2>&1)"
  [[ "$sl" == *"not allowed to run sudo"* ]] || { do_log "FATAL $u has a sudo grant: ${sl%%$'\n'*}"; return 1; }
}

# spl_fws_desk_line <base> <user>: the desk start, as printed (no token).
spl_fws_desk_line() {
  printf 'sudo -n -u %s env SPL_WS_BASE=%s ENV=%s TENANT_ID=%s DESK_BOX=%s DESK_AGENT=%s DRY_RUN=0 ./run -a do_spl_desk_up%s' \
    "$2" "$1" "${ENV:-}" "${TENANT_ID:-}" "${DESK_BOX:-}" "${DESK_AGENT:-}" \
    "$([[ -n "${SPOOL_JOIN_TOKEN_FILE:-}" ]] && echo ' (join token on stdin)')"
}

# spl_fws_desk_start <base> <tenant> <user>: empty the seat dir, then
# do_spl_desk_up as the workspace user. The token goes on stdin, never argv.
spl_fws_desk_start() {
  local b="$1" t="$2" u="$3" uid rt tok="${SPOOL_JOIN_TOKEN_FILE:-/dev/null}"
  uid="$(id -u "$u")" || { do_log "FATAL no uid for $u"; return 1; }
  rt="/run/user/$uid"
  sudo -n -u "$u" bash -c 'umask 077; rm -rf -- "$1/spool-seat" && mkdir -m 0700 -- "$1/spool-seat"' _ "$rt" ||
    { do_log "FATAL could not empty $rt/spool-seat as $u"; return 1; }
  do_log "INFO starting the desk: $(spl_fws_desk_line "$b" "$u")"
  (cd "$PROJ_PATH" && sudo -n -u "$u" env SPL_WS_BASE="$b" ENV="$ENV" TENANT_ID="$t" DESK_BOX="$DESK_BOX" \
    DESK_AGENT="$DESK_AGENT" DRY_RUN=0 bash -c \
    'tok="$(cat)"; [[ -n "$tok" ]] && export SPOOL_JOIN_TOKEN="$tok"; unset tok; exec ./run -a do_spl_desk_up' <"$tok")
}
