#!/bin/bash
#------------------------------------------------------------------------------
# @description Make THIS Debian laptop a fleet worker box, in one line run by
# @description its owner, a member with sudo (SPL-6680, spec 037 "Laptop box";
# @description owner HUM-10, topic 87573eb9: "just oneliners, nothing else").
# @description As root it:
# @description   1. installs the base packages (git, tmux, curl, python3, jq,
# @description      libnotify-bin for the end-of-hours pop-up, ...);
# @description   2. makes the agents' own OS user (LAPTOP_AGENT_USER): no
# @description      sudo, a locked password. The member's account and any
# @description      Claude CLI of hers are never touched or used;
# @description   3. gives that user this checkout and the spool root (cnf
# @description      env.box.spool_root, group env.box.spool_root_group);
# @description   4. writes box.env (box tag, agent user, fleet env + tenant)
# @description      and dispatch/laptop-box.env (her hours, the agent cap).
# @description Then, as the agent user, spool-install (install.sh --cli claude
# @description --fleet): a current Claude Code from the vendor, the spool CLI,
# @description the fleet hooks, and the box seated with the join token. The
# @description token is read from SPOOL_JOIN_TOKEN or asked on the terminal
# @description without echo; it reaches install.sh through a 0600 file that is
# @description removed at once, never a command line. Dry run unless DRY_RUN=0.
# @description Exit 0 done, 2 usage, 3 not a Debian box, 1 a step failed.
# @param BOX_TAG (required) - the laptop's box tag, e.g. lap-a
# @param HOURS (required) - her working hours, "<days> <HH:MM>-<HH:MM>", e.g. "Mon-Fri 09:00-17:00"
# @param TENANT_ID (required) - the workspace the box serves
# @param LAPTOP_ENV (optional) - dev or prd, default prd
# @param AGENT_MAX (optional) - the most agents at once on this box, default 4
# @param LAPTOP_AGENT_USER (optional) - the agents' OS user, default the satellite's (cnf env.steps.060-gcp-vm-satellite.box_agent_user): the fleet's agent user
# @param SPOOL_JOIN_TOKEN (optional) - the join token; asked on the terminal when unset
# @param DRY_RUN (optional) - 1 (default) or 0
# @param LAPTOP_CHECKOUT / LAPTOP_OS_RELEASE / LAPTOP_ROOT_RUN / LAPTOP_AS_USER / LAPTOP_INSTALL_SH (tests) - the checkout root, the Debian marker file, the root runner, the run-as-user prefix, install.sh
# @example ./run -a do_spl_laptop_box_install --box-tag lap-a --hours "Mon-Fri 09:00-17:00" --tenant-id t1
# @example sudo ./run -a do_spl_laptop_box_install --box-tag lap-a --hours "Mon-Fri 09:00-17:00" --tenant-id t1 --dry-run 0
#------------------------------------------------------------------------------
do_spl_laptop_box_install() {
  local tag="${BOX_TAG:-}" hours="${HOURS:-}" ten="${TENANT_ID:-}" env="${LAPTOP_ENV:-prd}"
  local max="${AGENT_MAX:-4}" u="${LAPTOP_AGENT_USER:-}" co dry=1 sr g hub
  spl_laptop_install_args_ok "$tag" "$hours" "$ten" "$env" "$max" || return 2
  [[ -r "${LAPTOP_OS_RELEASE:-/etc/debian_version}" ]] || { do_log "FATAL not a Debian box (no /etc/debian_version): the laptop box is Debian only"; return 3; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 2; dry=0; fi
  co="${LAPTOP_CHECKOUT:-$(cd "$PROJ_PATH/.." && pwd)}"
  sr="$(spl_laptop_cnf_get "$co" "$env" env.box.spool_root)"; sr="${sr:-/var/spool-hub}"
  g="$(spl_laptop_cnf_get "$co" "$env" env.box.spool_root_group)"; g="${g:-spool-agents}"
  [[ -n "$u" ]] || u="$(spl_laptop_cnf_get "$co" "$env" env.steps.060-gcp-vm-satellite.box_agent_user)"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL no agents' OS user: set LAPTOP_AGENT_USER (the $env cnf names none), got '$u'"; return 2; }
  hub="$(spl_laptop_cnf_get "$co" "$env" env.dns.api_fqdn)"
  [[ -n "$hub" ]] || { do_log "FATAL env.dns.api_fqdn is not set in the $env cnf of $co: no hub URL"; return 1; }
  hub="https://$hub"
  local -a cmds=()
  mapfile -t cmds < <(spl_laptop_install_root_cmds "$u" "$co" "$sr" "$g" "$tag" "$env" "$ten" "$hours" "$max")
  if (( dry )); then
    do_log "INFO DRY_RUN would run as root:"; printf '    %s\n' "${cmds[@]}"
    do_log "INFO DRY_RUN then as $u: install.sh --cli claude --fleet --env $env --tenant $ten --box $tag (hub $hub, the join token from a 0600 file)"
    do_log "OK DRY_RUN nothing was touched. Re-run with --dry-run 0 (as root: sudo)."
    return 0
  fi
  local tok; tok="$(spl_laptop_read_token)"
  [[ -n "$tok" ]] || { do_log "FATAL no join token: set SPOOL_JOIN_TOKEN or type it when asked (the workspace admin mints it)"; return 2; }
  "${LAPTOP_ROOT_RUN:-_spool_root_run_as_root}" "${cmds[@]}" || return 1
  spl_laptop_install_as_user "$u" "$co" "$hub" "$env" "$ten" "$tag" "$sr" "$tok" || return 1
  do_log "OK this laptop is box $tag of $ten ($env): agents run as $u, up to $max at once, in $hours"
}

# spl_laptop_install_args_ok <tag> <hours> <tenant> <env> <max>: the one-liner's
# values, each refused with the reason (exit 2).
spl_laptop_install_args_ok() {
  spl_laptop_box_tag_ok "$1" || { do_log "FATAL BOX_TAG must be a box tag (^[a-z0-9][a-z0-9-]{0,31}\$), got '$1'"; return 2; }
  spl_laptop_hours_parse "$2" >/dev/null || { do_log "FATAL HOURS must be \"<days> <HH:MM>-<HH:MM>\" with start before end, e.g. \"Mon-Fri 09:00-17:00\", got '$2'"; return 2; }
  [[ "$3" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a workspace slug, got '$3'"; return 2; }
  [[ "$4" =~ ^(dev|prd)$ ]] || { do_log "FATAL LAPTOP_ENV must be dev or prd, got '$4'"; return 2; }
  [[ "$5" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL AGENT_MAX must be 1..99, got '$5'"; return 2; }
}

# spl_laptop_install_as_user <user> <checkout> <hub> <env> <tenant> <tag>
#   <spool root> <token>: spool-install as the agent user. The token goes in a
# 0600 file of that user, read and removed by the first line of its shell.
spl_laptop_install_as_user() {
  local u="$1" co="$2" hub="$3" env="$4" ten="$5" tag="$6" sr="$7" tok="$8" tf rc
  local sh="${LAPTOP_INSTALL_SH:-$co/csi-spl-orc/src/bash/features/spool-install/install.sh}"
  local -a as=(sudo -u "$u" -H)
  [[ -z "${LAPTOP_AS_USER:-}" ]] || read -ra as <<<"$LAPTOP_AS_USER"
  tf="$(umask 077 && mktemp)" || return 1
  printf '%s' "$tok" >"$tf"
  chown "$u" "$tf" 2>/dev/null || true
  "${as[@]}" env SPOOL_HUB_URL="$hub" SPOOL_ROOT="$sr" SPOOL_AGENT_USER="$u" TOKEN_FILE="$tf" \
    bash -c 'SPOOL_JOIN_TOKEN="$(cat "$TOKEN_FILE")"; rm -f "$TOKEN_FILE"; export SPOOL_JOIN_TOKEN; exec bash "$@"' \
    _ "$sh" --cli claude --fleet --env "$env" --tenant "$ten" --box "$tag"
  rc=$?
  rm -f "$tf"
  (( rc == 0 )) || { do_log "FATAL spool-install as $u failed (exit $rc): re-run the same line, it is idempotent"; return 1; }
}
