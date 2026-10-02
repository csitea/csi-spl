#!/bin/bash
#------------------------------------------------------------------------------
# @description After a reboot, bring the box's agents back AS THE AGENT USER
# @description (owner rule 2026-10-01: every programmatic Claude start runs as
# @description the agent user, never the box user). Run as the box user (the
# @description tmux owner), from @reboot (do_spl_agent_boot_restore_install_cron):
# @description   1. waits up to BOOT_RESTORE_WAIT_SEC for the box's tmux server
# @description      (a unit or another boot job may start it); creates session
# @description      BOOT_RESTORE_SESSION itself when none came
# @description   2. do_spl_agent_identity_restore: each agent the reboot killed,
# @description      its own session in its own worktree, as the agent user, a
# @description      box-user-only transcript copied across first
# @description   3. the owner's check: no agent CLI (claude, grok, agy, qwen)
# @description      runs as the box user; each one that does is an ALERT
# @description A failure leaves <SPOOL_ROOT>/agents/boot-FAILED (an @reboot
# @description exit code goes nowhere); a clean run removes it.
# @description Dry run unless DRY_RUN=0: the identity restore's plan, nothing started.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param BOOT_RESTORE_WAIT_SEC (optional) - seconds to wait for the tmux server, default 120
# @param BOOT_RESTORE_SESSION (optional) - the session to create when none exists, default main
# @param BOOT_RESTORE_PS (optional) - the ps to ask (tests only)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_boot_restore
# @example DRY_RUN=0 ./run -a do_spl_agent_boot_restore
#------------------------------------------------------------------------------
do_spl_agent_boot_restore() {
  local dry="${DRY_RUN:-1}" wait="${BOOT_RESTORE_WAIT_SEC:-120}" sess="${BOOT_RESTORE_SESSION:-main}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$wait" =~ ^[0-9]+$ ]] || { do_log "FATAL BOOT_RESTORE_WAIT_SEC must be seconds, got: '$wait'"; return 1; }
  local feat="$PROJ_PATH/src/bash/features/spawn-agents"
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$feat/lib/agent-identity.inc.sh" || return 1
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$feat/lib/spool-env.inc.sh" || return 1
  # shellcheck source=spl-agent-identity-restore.func.sh
  declare -F do_spl_agent_identity_restore >/dev/null || source "$PROJ_PATH/src/bash/run/spl-agent-identity-restore.func.sh" || return 1
  local box_user agent_user marker why="" rc=0 deadline sock
  read -r box_user agent_user < <(SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf '%s %s\n' "$SPOOL_BOX_USER" "$SPOOL_AGENT_USER")
  marker="$(ai_dir)/boot-FAILED"
  echo "boot-restore: box user ${box_user:-?}, agent user ${agent_user:-?}, DRY_RUN=$dry"
  if [[ -z "$agent_user" || "$agent_user" == "$box_user" ]]; then
    echo "WARN    the agent user is the box user (${box_user:-?}): set SPOOL_AGENT_USER in ${SPOOL_ROOT:-/var/spool-hub}/box.env"
  fi

  # 1. the tmux server
  deadline=$((SECONDS + wait))
  until ai_tmux has-session 2>/dev/null; do
    (( SECONDS >= deadline )) && break
    sleep 2
  done
  if ! ai_tmux has-session 2>/dev/null; then
    if [[ "$dry" == 1 ]]; then echo "PLAN    no tmux server after ${wait}s: would create session '$sess'"
    else
      sock="${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}"
      mkdir -p "${sock%/*}" 2>/dev/null && chmod 700 "${sock%/*}" 2>/dev/null
      if ai_tmux new-session -d -s "$sess" 2>/dev/null && ai_tmux has-session -t "=$sess" 2>/dev/null; then
        echo "CREATED tmux session '$sess'"
      else why="no tmux server, and session '$sess' could not be created"; fi
    fi
  fi

  # 2. the agents, as the agent user
  if [[ -z "$why" ]]; then
    DRY_RUN="$dry" do_spl_agent_identity_restore || { rc=$?; why="the identity restore exited rc=$rc"; }
  fi

  # 3. the owner's check: nothing agent-shaped runs as the box user
  if [[ "$dry" == 0 && -n "$box_user" && "$box_user" != "$agent_user" ]]; then
    local line n=0
    while IFS= read -r line; do
      echo "ALERT   runs as $box_user, not $agent_user: $line"; n=$((n + 1))
    done < <(${BOOT_RESTORE_PS:-ps} -u "$box_user" -o pid=,args= 2>/dev/null | awk '$2 ~ /(^|\/)(claude|grok|agy|qwen)$/')
    (( n == 0 )) || why="${why:+$why; }$n agent CLI(s) run as the box user $box_user"
  fi

  if [[ "$dry" == 1 ]]; then echo "boot-restore: dry run, nothing started"; [[ -z "$why" ]]; return; fi
  if [[ -n "$why" ]]; then
    printf '[%s] boot-restore FAILED: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$why" > "$marker" 2>/dev/null
    echo "FAILED  boot-restore: $why - marker: $marker"
    return 1
  fi
  rm -f "$marker" 2>/dev/null
  echo "boot-restore: OK"
}
