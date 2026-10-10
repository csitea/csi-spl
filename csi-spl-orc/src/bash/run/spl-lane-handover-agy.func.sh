#!/usr/bin/env bash
# do_spl_lane_handover_agy: handover an agy agent's WIP and session to another box.

# Source shared handover logic
base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$base_dir/spl-lane-handover.func.sh" ]; then
  # shellcheck source=spl-lane-handover.func.sh
  . "$base_dir/spl-lane-handover.func.sh"
fi

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

  local sha
  sha="$(echo "$wip_out" | grep -oP 'sha=\K[0-9a-f]+' | head -n1 || true)"
  local ref="refs/heads/wip/handover/$id"

  # 2. Transfer agy session
  local agent_home
  agent_home="$(getent passwd "${SPOOL_AGENT_USER}" | cut -d: -f6)"
  
  local conv_id="${CONVERSATION_ID:-}"
  if [ -z "$conv_id" ]; then
    local harness_pids agy_pid=""
    harness_pids="$(pgrep -f "spool-harness.sh.*--as '$id'" || true)"
    if [ -n "$harness_pids" ]; then
      for hp in $harness_pids; do
        agy_pid="$(pgrep -P "$hp" -f "agy " | head -n1 || true)"
        [ -n "$agy_pid" ] && break
      done
    fi

    if [ -n "$agy_pid" ]; then
      conv_id="$(ps -p "$agy_pid" -o args= | grep -oP -- '--conversation \K[a-f0-9-]+' || true)"
      if [ -z "$conv_id" ]; then
        conv_id="$(sudo -n -u "${SPOOL_AGENT_USER}" lsof -p "$agy_pid" -Fn 2>/dev/null | grep -oP '\.gemini/antigravity-cli/conversations/\K[a-f0-9-]+' | head -n1 || true)"
      fi
    fi
  fi
  
  if [ -z "$conv_id" ]; then
    echo "ERROR: could not resolve conversation id for agent $id" >&2
    return 1
  fi

  local session_dir="${agent_home}/.gemini/antigravity-cli/brain/${conv_id}"
  local db_file="${agent_home}/.gemini/antigravity-cli/conversations/${conv_id}.db"

  if [ ! -d "$session_dir" ]; then
    echo "ERROR: session directory $session_dir not found" >&2
    return 1
  fi

  local dest
  dest="$(spl_handover_dest "$box")"
  
  local repo newwt
  repo="$(spl_handover_main_checkout "${APP_PATH:-$PWD}")" || { echo "FATAL not a repository: ${APP_PATH:-$PWD}" >&2; return 1; }
  newwt="$repo-wt/$id"

  # Probe and prep using shared logic
  spl_handover_probe "$dest" "$box" "$repo" "$newwt" || return 1
  
  local scripts
  scripts="$(spl_handover_scripts_dir "$repo")"

  echo "INFO: Preparing worktree $newwt on $box..."
  spl_handover_on "$dest" owner prep "$repo" "$newwt" "$ref" "$id-handover" "$scripts" </dev/null >/dev/null 2>&1 || { echo "FATAL prep failed on $box" >&2; return 1; }

  local rbrief="/var/spool-hub/dispatch/brief-${id}-handover.md"
  # spl_handover_brief FROM TO BOX HERE MODE WT NEWWT REF SHA
  # we use mode A
  spl_handover_brief "$id" "$id" "$box" "${SPOOL_BOX_TAG:-}" "A" "${wip_dir:-$newwt}" "$newwt" "$ref" "$sha" >"/tmp/brief-$id.md"
  spl_handover_on "$dest" owner brief "$rbrief" <"/tmp/brief-$id.md" >/dev/null 2>&1 || { echo "FATAL cannot write brief" >&2; return 1; }

  echo "INFO: Syncing session $session_dir to $box over SSH..."
  if ! sudo -n -u "${SPOOL_BOX_USER}" ssh -q "$dest" "mkdir -p ${session_dir%/*} ${agent_home}/.gemini/antigravity-cli/conversations"; then
    echo "WARN: could not reach $dest or create directory. Handover fallback: agent must read wip branch." >&2
  elif ! sudo -n -u "${SPOOL_BOX_USER}" scp -q -r "$session_dir" "${dest}:${session_dir%/*}/"; then
    echo "WARN: scp failed. Handover fallback: agent must read wip branch." >&2
  elif ! sudo -n -u "${SPOOL_BOX_USER}" scp -q "$db_file"* "${dest}:${agent_home}/.gemini/antigravity-cli/conversations/" 2>/dev/null; then
    echo "WARN: scp of DB failed. Handover fallback: agent must read wip branch." >&2
  else
    # 3. Ownership
    sudo -n -u "${SPOOL_BOX_USER}" ssh -q "$dest" "sudo -n -u root chown -R ${SPOOL_AGENT_USER}:${SPOOL_AGENT_USER} ${session_dir} ${agent_home}/.gemini/antigravity-cli/conversations/${conv_id}.db*"
    
    # 4. Resume step
    # Start the new agy agent on the target box via the spawn path (spawn-agy.sh, SPAWN_RESUME_FLAG=--conversation <conv-id>), worktree on wip/handover/<id>; as ai-usr, inside tmux, like every launcher.
    echo "INFO: Spawning agy agent on $box..."
    # We must run it as the OWNER or BOX user, not agent user, because spawn-window drops privileges
    sudo -n -u "${HO_OWNER:-$SPOOL_BOX_USER}" ssh -q "$dest" "bash $scripts/spawn-window.sh agy $id $newwt $rbrief handover --conversation $conv_id" >/dev/null 2>&1 || { echo "FATAL spawn failed" >&2; return 1; }

    echo "OK HANDOVER-AGY $id to $box"
  fi
}
