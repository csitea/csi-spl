#!/usr/bin/env bash
# do_spl_lane_handover_agy: handover an agy agent's WIP and session to another box.

do_spl_lane_handover_agy() {
  local id="${ID:-}" box="${BOX:-}" dry="${DRY_RUN:-1}" wip_dir="${WIP_WORKTREE:-}"
  if [ -z "$id" ] || [ -z "$box" ]; then
    echo "ERROR: ID and BOX are required" >&2
    return 1
  fi

  local base_dir
  base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$base_dir/../features/spawn-agents/lib/spool-env.inc.sh" ]; then
    # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
    . "$base_dir/../features/spawn-agents/lib/spool-env.inc.sh" 2>/dev/null || true
    spool_env_resolve
  fi

  # 1. Call WIP lib to push the WIP branch
  local wip_out
  if ! wip_out="$(cd "$base_dir/../.." && sudo -n -u "${SPOOL_BOX_USER}" env ID="$id" WIP_WORKTREE="$wip_dir" DRY_RUN="$dry" "${SPAWN_ORC_RUN:-./run}" -a do_spl_lane_handover_wip 2>&1)"; then
    echo "$wip_out" >&2
    return 1
  fi
  echo "$wip_out"

  if [ "$dry" = 1 ]; then
    echo "PLAN handover session for $id to $box (agy-specific)"
    return 0
  fi

  # 2. Transfer agy session
  local agent_home
  agent_home="$(getent passwd "${SPOOL_AGENT_USER}" | cut -d: -f6)"
  local session_dir="${agent_home}/.gemini/antigravity-cli/brain/${id}"

  if [ ! -d "$session_dir" ]; then
    echo "ERROR: session directory $session_dir not found" >&2
    return 1
  fi

  echo "INFO: Syncing session $session_dir to $box over SSH..."
  if ! sudo -n -u "${SPOOL_BOX_USER}" ssh -q "$box" "mkdir -p ${session_dir%/*}"; then
    echo "WARN: could not reach $box or create directory. Handover fallback: agent must read wip branch." >&2
  elif ! sudo -n -u "${SPOOL_BOX_USER}" scp -q -r "$session_dir" "${box}:${session_dir%/*}/"; then
    echo "WARN: scp failed. Handover fallback: agent must read wip branch." >&2
  else
    echo "OK HANDOVER-AGY $id to $box"
  fi
}
