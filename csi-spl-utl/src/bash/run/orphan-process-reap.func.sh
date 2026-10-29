#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 06 (rel-06, SPL-2445, Refs: SPL-2364):
# @description Orphaned process & detached worker advisory.
# @description
# @description USER CONTEXT:
# @description   Run this action as the box user ($SPOOL_BOX_USER), not the agent
# @description   user ($SPOOL_AGENT_USER). Lane runner processes run as the box
# @description   user; when invoked as the agent user, /proc/<pid>/environ is
# @description   unreadable (EACCES) for other users' processes, preventing
# @description   positive AGENT_ID provenance inspection.
# @description   Example: cd csi-spl-utl && ./run -a do_fleet_orphan_process_reap
# @description
# @description Identifies detached runner processes using positive provenance:
# @description   1. Process environment contains AGENT_ID that is present in
# @description      registry.retired.tsv AND NOT currently active in registry.tsv
# @description      or live tmux window (agent ID reuse guard), OR
# @description   2. Process working directory (/proc/<pid>/cwd) points to a
# @description      removed worktree (/opt/csi/csi-spl-wt/* (deleted)), AND
# @description   3. Process is NOT on the explicit never-list:
# @description      - tmux (server daemon and client panes, matched on comm/argv0)
# @description      - systemd (system and user daemons, sd-pam)
# @description      - do_spl_watchdog (box watchdog daemon)
# @description      - runner listeners (GitHub Actions Runner.Listener / Runner.Worker)
# @description
# @description REPORT-ONLY ADVISORY (DRY_RUN=1 permanent):
# @description   It NEVER terminates, kills, signals, or reaps any process.
# @description   Leaves termination to lane lifecycle and harness exit traps.
# @description
# @description ALERTING:
# @description   DRY_RUN=1 (default) logs findings and prints the PLAN note.
# @description   DRY_RUN=0 sends one throttled spool note to orchestrator via
# @description   spool-send.sh (or ORPHAN_PROCESS_SEND_CMD when set).
# @description   Throttled by ORPHAN_PROCESS_STATE_DIR/alert.stamp (default 30 min).
# @description   Exit 0 when 0 orphans found; exit 1 when orphans detected;
# @description   exit 2 on usage / configuration error.
# @param ORPHAN_PROC_DIR (optional) - procfs root, default /proc
# @param ORPHAN_ACTIVE_REGISTRY (optional) - default $SPOOL_ROOT/registry.tsv
# @param ORPHAN_RETIRED_REGISTRY (optional) - default $SPOOL_ROOT/registry.retired.tsv
# @param ORPHAN_WT_ROOT (optional) - worktree root, default /opt/csi/csi-spl-wt
# @param ORPHAN_PROCESS_STATE_DIR (optional) - default <SPL_STATE_DIR or
# @param   $HOME/.local/state/csi-spl>/orphan-process
# @param ORPHAN_PROCESS_THROTTLE_S (optional) - default 1800
# @param ORPHAN_PROCESS_SEND_CMD (optional) - sender override for tests
# @param ORPHAN_PROCESS_SEND_TIMEOUT (optional) - default 20
# @param ORPHAN_PROCESS_ALERT_TO / _FROM / _TASK (optional) - alert routing
# @param DRY_RUN (optional) - 1 (default) plans the alert; 0 sends it
# @example cd csi-spl-utl && ./run -a do_fleet_orphan_process_reap
# @example cd csi-spl-utl && ./run -a do_orphan_process_reap
# @example DRY_RUN=0 cd csi-spl-utl && ./run -a do_fleet_orphan_process_reap
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

# spl_box_name: the box name from the config, never the hostname (SPL-4201)
declare -F spl_box_name >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"

orphan_process_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }

orphan_process_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

orphan_process_is_never_listed() {
  local comm="$1" cmdline="$2"
  local argv0="${cmdline%% *}"
  local base_argv0="${argv0##*/}"

  # 1. tmux server and client processes (match comm or argv0 basename, not full cmdline)
  if [[ "$comm" == tmux* || "$base_argv0" == tmux* ]]; then
    return 0
  fi

  # 2. systemd system and user daemons
  if [[ "$comm" == systemd* || "$comm" == "(sd-pam)" || "$base_argv0" == systemd* || "$base_argv0" == "(sd-pam)" ]]; then
    return 0
  fi

  # 3. do_spl_watchdog daemon
  if [[ "$comm" == *spl-watchdog* || "$cmdline" =~ (^|[[:space:]/])do_spl_watchdog([[:space:]]|$) || "$cmdline" == *spl-watchdog* ]]; then
    return 0
  fi

  # 4. GitHub Actions runner listeners and workers
  if [[ "$comm" == Runner.* || "$base_argv0" == Runner.* || "$cmdline" == *runsvc.sh* || "$cmdline" == *actions-runner* ]]; then
    return 0
  fi

  return 1
}

orphan_process_stamp() {
  local sdir="${ORPHAN_PROCESS_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}/orphan-process}"
  echo "$sdir/alert.stamp"
}

orphan_process_clear() {
  local stamp; stamp="$(orphan_process_stamp)"
  [[ "$1" == 0 && -f "$stamp" ]] && rm -f "$stamp"
  return 0
}

orphan_process_alert() {
  local orphan_count="$1" orphan_summary="$2" dry="$3"
  local stamp prev_count=0 prev_time=0 now box body from
  local to="${ORPHAN_PROCESS_ALERT_TO:-orchestrator}" task="${ORPHAN_PROCESS_ALERT_TASK:-orphan-process}"
  local throttle="${ORPHAN_PROCESS_THROTTLE_S:-1800}" send_tmo="${ORPHAN_PROCESS_SEND_TIMEOUT:-20}"
  local -a send

  box="${DEV_BOX:-$(spl_box_name)}"
  from="${ORPHAN_PROCESS_ALERT_FROM:-${SPOOL_AGENT_ID:-orphan-process-advisory@$box}}"
  stamp="$(orphan_process_stamp)"
  now="${EPOCHSECONDS:-$(date +%s)}"

  if [[ -f "$stamp" ]]; then
    read -r prev_count prev_time <"$stamp" 2>/dev/null || true
  fi
  [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
  [[ "$prev_time" =~ ^[0-9]+$ ]] || prev_time=0

  if ((prev_count == orphan_count && now - prev_time < throttle)); then
    do_log "INFO orphan-process advisory throttled by $stamp"
    return 0
  fi

  body="orphan-process ADVISORY on $box: $orphan_count orphaned runner process(es) detected: $orphan_summary. Advisory only (DRY_RUN=1 permanent): termination left to lane lifecycle and harness exit traps."

  if [[ "$dry" != 0 ]]; then
    do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi

  read -ra send <<<"${ORPHAN_PROCESS_SEND_CMD:-}"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: alert not sent"; return 0; }
  fi

  if timeout -k 2 "$send_tmo" "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" \
    --no-poke --body "$body" >/dev/null 2>&1; then
    { mkdir -p "$(dirname "$stamp")" && echo "$orphan_count $now" >"$stamp"; } 2>/dev/null ||
      do_log "WARN cannot write $stamp: the next run alerts again"
    do_log "INFO orphan-process advisory note sent to $to"
  else
    do_log "WARN orphan-process: the note to $to failed"
  fi
  return 0
}

# 1. Discover currently active agent IDs from registry.tsv and live tmux windows
# Fills the caller's active_agents set.
orphan_process_active_ids() {
  local active_tsv="$1"
  if [[ -f "$active_tsv" ]]; then
    local a_row_id
    while IFS=$'\t' read -r a_row_id _rest; do
      [[ -z "$a_row_id" || "$a_row_id" == \#* ]] && continue
      a_row_id="${a_row_id%@*}"
      active_agents["$a_row_id"]=1
    done < "$active_tsv"
  fi

  local tmux_sock="${SPOOL_TMUX_SOCKET:-}"
  if [[ -z "$tmux_sock" && -f "$active_tsv" ]]; then
    local reg_uid
    reg_uid="$(stat -c %u "$active_tsv" 2>/dev/null || true)"
    [[ -n "$reg_uid" && -S "/tmp/tmux-$reg_uid/default" ]] && tmux_sock="/tmp/tmux-$reg_uid/default"
  fi
  local -a tmux_cmd=()
  if [[ -n "$tmux_sock" ]]; then
    tmux_cmd=(tmux -S "$tmux_sock")
  elif command -v tmux &>/dev/null; then
    tmux_cmd=(tmux)
  fi
  if ((${#tmux_cmd[@]})); then
    local w_name
    while IFS= read -r w_name; do
      [[ -z "$w_name" ]] && continue
      if [[ "$w_name" =~ (^|[^a-zA-Z0-9_-])([acgmq]-[0-9]+) ]]; then
        active_agents["${BASH_REMATCH[2]}"]=1
      fi
    done < <("${tmux_cmd[@]}" list-windows -a -F '#{window_name}' 2>/dev/null || true)
  fi
}

# 2. Load retired agent IDs into hash set (excluding currently active lanes)
# Fills the caller's retired_agents set; reads active_agents.
orphan_process_retired_ids() {
  local retired_tsv="$1"
  if [[ -f "$retired_tsv" ]]; then
    local r_id
    while IFS=$'\t' read -r r_id _rest; do
      [[ -z "$r_id" || "$r_id" == \#* ]] && continue
      r_id="${r_id%@*}"
      # If this agent ID is currently active (reused id with live row/window), it is NOT retired
      [[ -n "${active_agents[$r_id]:-}" ]] && continue
      retired_agents["$r_id"]=1
    done < "$retired_tsv"
  fi
}

# Provenance 1: Process environ contains AGENT_ID in registry.retired.tsv (and not active)
# Reads the p_dirs of orphan_process_dirs; fills candidate_provenance / candidate_agent.
orphan_process_environ_candidates() {
  local env_line p_file p_pid a_id a_clean
  while IFS= read -r env_line; do
    [[ -z "$env_line" ]] && continue
    p_file="${env_line%%:AGENT_ID=*}"
    a_id="${env_line#*:AGENT_ID=}"
    a_id="${a_id%%$'\r'*}"
    a_id="${a_id%%$'\n'*}"
    p_pid="${p_file%/environ}"
    p_pid="${p_pid##*/}"
    [[ "$p_pid" =~ ^[0-9]+$ ]] || continue
    a_clean="${a_id%@*}"
    # Skip if this agent ID belongs to a currently active lane
    [[ -n "${active_agents[$a_clean]:-}" ]] && continue

    if [[ -n "${retired_agents[$a_clean]:-}" ]]; then
      candidate_provenance["$p_pid"]="retired-agent:$a_id"
      candidate_agent["$p_pid"]="$a_id"
    fi
  done < <(grep -s -z -H '^AGENT_ID=' "${p_dirs[@]/%//environ}" 2>/dev/null | tr '\0' '\n' | grep ':AGENT_ID=')
}

# Provenance 2: Process working directory points to a removed worktree ((deleted))
# Reads the p_dirs of orphan_process_dirs; fills candidate_cwd / candidate_provenance.
orphan_process_cwd_candidates() {
  local wt_root="$1"
  local cwd_line c_target link_path c_pid c_clean path_agent
  while IFS= read -r cwd_line; do
    [[ "$cwd_line" == *" (deleted)"* ]] || continue
    c_target="${cwd_line##*-> }"
    c_target="${c_target#\'}"; c_target="${c_target%\'}"
    c_target="${c_target#\"}"; c_target="${c_target%\"}"
    c_clean="${c_target% (deleted)}"

    # Must point to a worktree path (/opt/csi/csi-spl-wt/* or */csi-spl-wt/* or */wt/[acgmq]-[0-9]*)
    if [[ "$c_clean" != "$wt_root"/* && "$c_clean" != */csi-spl-wt/* && ! "$c_clean" =~ /wt/([acgmq]-[0-9]+|[^/]+) ]]; then
      continue
    fi

    link_path="${cwd_line% -> *}"
    link_path="${link_path##* }"
    c_pid="${link_path%/cwd}"
    c_pid="${c_pid##*/}"
    [[ "$c_pid" =~ ^[0-9]+$ ]] || continue

    # If the worktree path belongs to an active agent, do not flag
    path_agent=""
    if [[ "$c_clean" =~ /([acgmq]-[0-9]+) ]]; then
      path_agent="${BASH_REMATCH[1]}"
    fi
    if [[ -n "$path_agent" && -n "${active_agents[$path_agent]:-}" ]]; then
      continue
    fi

    candidate_cwd["$c_pid"]="$c_target"
    if [[ -n "${candidate_provenance[$c_pid]:-}" ]]; then
      candidate_provenance["$c_pid"]+=",deleted-worktree:$c_target"
    else
      candidate_provenance["$c_pid"]="deleted-worktree:$c_target"
    fi
  done < <(ls -l "${p_dirs[@]/%//cwd}" 2>/dev/null)
}

# 3. Gather process directories
# Sets the caller's scanned_pids; the two provenance scans fill the candidate_* maps.
orphan_process_dirs() {
  local proc_dir="$1" wt_root="$2"
  shopt -s nullglob
  local p_dirs=("$proc_dir"/[0-9]*)
  shopt -u nullglob
  scanned_pids=${#p_dirs[@]}

  if ((scanned_pids > 0)); then
    orphan_process_environ_candidates
    orphan_process_cwd_candidates "$wt_root"
  fi
}

# 4. Filter candidates through active agent preservation, never-list, and self protection
# Reads candidate_*; fills orphan_pids and the orphan_* maps.
orphan_process_filter() {
  local proc_dir="$1"
  local cand_pid p_comm p_cmdline stat_content post_comm _state p_ppid
  for cand_pid in "${!candidate_provenance[@]}"; do
    # Self-protection
    [[ "$cand_pid" == "$$" || "$cand_pid" == "${BASHPID:-$$}" ]] && continue

    p_comm=""
    if [[ -r "$proc_dir/$cand_pid/comm" ]]; then
      p_comm="$(<"$proc_dir/$cand_pid/comm")" 2>/dev/null || true
    fi

    p_cmdline=""
    if [[ -r "$proc_dir/$cand_pid/cmdline" ]]; then
      p_cmdline="$(tr '\0' ' ' < "$proc_dir/$cand_pid/cmdline" 2>/dev/null || true)"
    fi

    p_ppid=1
    if [[ -r "$proc_dir/$cand_pid/stat" ]]; then
      stat_content="$(<"$proc_dir/$cand_pid/stat")" 2>/dev/null || true
      if [[ -n "$stat_content" ]]; then
        [[ -z "$p_comm" ]] && { p_comm="${stat_content#*(}"; p_comm="${p_comm%)*}"; }
        post_comm="${stat_content##*)}"
        read -r _state p_ppid _rest <<< "$post_comm"
      fi
    fi
    [[ -z "$p_comm" ]] && p_comm="unknown"
    [[ "$p_ppid" =~ ^[0-9]+$ ]] || p_ppid=1

    # Check explicit never-list: tmux, systemd, do_spl_watchdog, runner listeners
    if orphan_process_is_never_listed "$p_comm" "$p_cmdline"; then
      continue
    fi

    # Fallback to extract agent ID from cwd path if environ lacked AGENT_ID
    if [[ -z "${candidate_agent[$cand_pid]:-}" ]]; then
      local raw_cwd="${candidate_cwd[$cand_pid]:-}"
      if [[ "$raw_cwd" =~ /(csi-spl-wt|wt)/([^/ ]+) ]]; then
        candidate_agent["$cand_pid"]="${BASH_REMATCH[2]}"
      fi
    fi

    # Extra active agent protection: if candidate agent is active, skip
    local check_agent="${candidate_agent[$cand_pid]:-}"
    check_agent="${check_agent%@*}"
    if [[ -n "$check_agent" && -n "${active_agents[$check_agent]:-}" ]]; then
      continue
    fi

    orphan_pids+=("$cand_pid")
    orphan_comm["$cand_pid"]="$p_comm"
    orphan_cmdline["$cand_pid"]="${p_cmdline:0:80}"
    orphan_ppid["$cand_pid"]="$p_ppid"
    orphan_prov["$cand_pid"]="${candidate_provenance[$cand_pid]}"
  done
}

# --json: print the orphans as one JSON array (reads orphan_pids and the maps)
orphan_process_json() {
  local -a json_items=()
  local opid e_agent e_comm e_prov e_cwd e_cmd
  for opid in "${orphan_pids[@]}"; do
    e_agent="$(orphan_process_json_escape "${candidate_agent[$opid]:-}")"
    e_comm="$(orphan_process_json_escape "${orphan_comm[$opid]}")"
    e_prov="$(orphan_process_json_escape "${orphan_prov[$opid]}")"
    e_cwd="$(orphan_process_json_escape "${candidate_cwd[$opid]:-}")"
    e_cmd="$(orphan_process_json_escape "${orphan_cmdline[$opid]}")"
    json_items+=("{\"pid\":$opid,\"ppid\":${orphan_ppid[$opid]},\"agent_id\":\"$e_agent\",\"comm\":\"$e_comm\",\"provenance\":\"$e_prov\",\"cwd\":\"$e_cwd\",\"cmdline\":\"$e_cmd\"}")
  done
  printf '[%s]\n' "$(IFS=,; echo "${json_items[*]}")"
}

# Report detected orphans
orphan_process_report() {
  local orphan_count="$1" scanned_pids="$2" ms="$3"
  local opid
  for opid in "${orphan_pids[@]}"; do
    do_log "WARN orphan pid=$opid ppid=${orphan_ppid[$opid]} agent=${candidate_agent[$opid]:--} comm=${orphan_comm[$opid]} provenance=${orphan_prov[$opid]} cwd=${candidate_cwd[$opid]:--} cmdline=${orphan_cmdline[$opid]}"
  done

  do_log "WARN orphan-process ADVISORY: $orphan_count orphan process(es) detected (scanned $scanned_pids pids in ${ms} ms)"
}

# Build concise summary for advisory note (up to 5 pids), then alert
orphan_process_summary_alert() {
  local orphan_count="$1" dry="$2"
  local opid summary_str="" count_in_summary=0
  for opid in "${orphan_pids[@]}"; do
    ((count_in_summary++))
    if ((count_in_summary <= 5)); then
      [[ -n "$summary_str" ]] && summary_str+=", "
      summary_str+="pid $opid (${orphan_comm[$opid]}, ${orphan_prov[$opid]})"
    fi
  done
  if ((orphan_count > 5)); then
    summary_str+=" and $((orphan_count - 5)) more"
  fi

  orphan_process_alert "$orphan_count" "$summary_str" "$dry"
}

# Print the result (--json, the OK line, or the report + alert).
# Exit 0 when 0 orphans found, 1 when orphans detected.
orphan_process_emit() {
  local json_mode="$1" dry="$2" scanned_pids="$3" ms="$4"
  local orphan_count=${#orphan_pids[@]}

  if ((json_mode)); then
    orphan_process_json
    if ((orphan_count == 0)); then return 0; else return 1; fi
  fi

  if ((orphan_count == 0)); then
    do_log "INFO orphan-process OK: 0 orphan processes found (scanned $scanned_pids pids in ${ms} ms)"
    orphan_process_clear "$dry"
    return 0
  fi

  orphan_process_report "$orphan_count" "$scanned_pids" "$ms"
  orphan_process_summary_alert "$orphan_count" "$dry"
  return 1
}

do_fleet_orphan_process_reap() {
  local proc_dir="${ORPHAN_PROC_DIR:-/proc}"
  local active_tsv="${ORPHAN_ACTIVE_REGISTRY:-${SPOOL_ROOT:-/var/spool-hub}/registry.tsv}"
  local retired_tsv="${ORPHAN_RETIRED_REGISTRY:-${SPOOL_ROOT:-/var/spool-hub}/registry.retired.tsv}"
  local wt_root="${ORPHAN_WT_ROOT:-${SPOOL_WT_ROOT:-/opt/csi/csi-spl-wt}}"
  local dry="${DRY_RUN:-1}"
  local t0 ms scanned_pids=0
  local json_mode=0

  for arg in "$@"; do
    case "$arg" in
      --json) json_mode=1 ;;
    esac
  done

  [[ -d "$proc_dir" ]] || { do_log "FATAL ORPHAN_PROC_DIR '$proc_dir' is not a directory"; return 2; }

  t0="$(orphan_process_ms)"

  # Shared state, filled by the orphan_process_* steps through bash dynamic scope:
  #   active_agents, retired_agents     agent id sets (steps 1, 2)
  #   candidate_provenance / _agent / _cwd   per-pid candidates (step 3, read by 4)
  #   orphan_pids, orphan_comm / _cmdline / _ppid / _prov   the kept orphans (step 4)
  #   scanned_pids                      the pid count (step 3)
  local -A active_agents=() retired_agents=()
  local -A candidate_provenance=() candidate_agent=() candidate_cwd=()
  local -a orphan_pids=()
  local -A orphan_comm=() orphan_cmdline=() orphan_ppid=() orphan_prov=()

  orphan_process_active_ids "$active_tsv"
  orphan_process_retired_ids "$retired_tsv"
  orphan_process_dirs "$proc_dir" "$wt_root"
  orphan_process_filter "$proc_dir"

  ms=$(($(orphan_process_ms) - t0))
  orphan_process_emit "$json_mode" "$dry" "$scanned_pids" "$ms"
}

# do_orphan_process_reap - the filename's own action name (same guard)
do_orphan_process_reap() { do_fleet_orphan_process_reap "$@"; }

# The file name gives do_orphan_process_reap; the plan's action name is
# do_fleet_orphan_process_reap, registered here when run.sh sources the file.
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_fleet_orphan_process_reap"]="${BASH_SOURCE[0]}"
fi
