#!/bin/bash
#------------------------------------------------------------------------------
# @description The box file follower of spec 160 (row B1, F1): follows the
# @description allow-listed files of this box (cnf env.box.file_streams.allow)
# @description with tail -F semantics, masks every line (spool_redact plus the
# @description PEM state) before it is queued, and pushes the queued lines as
# @description file_streams_push frames until the hub acks them. It runs
# @description src/bash/scripts/file-stream-follow.py as the box's agent user
# @description (spl_cost_agent_users, never root): one long-lived process per
# @description box under flock (a second start exits 0) that exits after run_s
# @description (1 h); the minute cron row file-streams starts it again. The
# @description deny list (spec 160 3.2) is in the follower and wins over the
# @description allow-list. Off while cnf env.box.file_streams.enabled is not
# @description true: one INFO line, nothing followed.
# @param FILE_STREAMS_ENABLED (optional) - true | false; default the cnf
# @param   env.box.file_streams.enabled (false until row B2 is on master)
# @param FILE_STREAMS_TICKS (optional) - run N ticks, then exit; default the
# @param   long-lived loop
# @param FILE_STREAMS_PUSH (optional) - 1 (default) push, 0 queue only
# @param FILE_STREAMS_PUSH_CMD (optional) - replaces
# @param   `spool file-streams push --json -` (tests, and until row B2 lands)
# @param FILE_STREAMS_AGENT_USER (optional) - default the first
# @param   spl_cost_agent_users user
# @param FILE_STREAMS_CNF (optional) - default csi-spl-cnf/csi-spl/all.env.yaml
# @param FILE_STREAMS_STATE_DIR (optional) - default the agent user's
# @param   $HOME/.local/state/csi-spl/file-streams
# @example ./run -a do_spl_file_stream_follow
# @example FILE_STREAMS_ENABLED=true FILE_STREAMS_TICKS=1 FILE_STREAMS_PUSH=0 ./run -a do_spl_file_stream_follow
#------------------------------------------------------------------------------

declare -F spl_cost_agent_users >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cost-tokens-read.func.sh"

do_spl_file_stream_follow() {
  local orc cnf on user py
  local -a envs=()
  orc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  cnf="${FILE_STREAMS_CNF:-$orc/../csi-spl-cnf/csi-spl/all.env.yaml}"
  py="$orc/src/bash/scripts/file-stream-follow.py"
  on="${FILE_STREAMS_ENABLED:-$(spl_file_stream_cnf "$cnf" enabled false)}"
  if [[ "$on" != true ]]; then
    echo "INFO file-streams: off (cnf env.box.file_streams.enabled is not true): nothing followed"
    return 0
  fi
  [[ -f "$py" ]] || { echo "FATAL file-streams: no follower at $py"; return 1; }
  spl_file_stream_env "$cnf" || return 1
  user="${FILE_STREAMS_AGENT_USER:-$(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}" | sed -n 1p)}"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "FATAL file-streams: bad agent user '$user'"; return 1; }
  [[ "$user" != root ]] || { echo "FATAL file-streams: the agent user is root: refused"; return 1; }
  local args=()
  [[ -n "${FILE_STREAMS_TICKS:-}" ]] && args=(--ticks "$FILE_STREAMS_TICKS")
  if [[ "$user" == "$(id -un)" ]]; then
    env "${envs[@]}" python3 "$py" "${args[@]}"
  else
    sudo -n -H -u "$user" env "${envs[@]}" python3 "$py" "${args[@]}"
  fi
}

# spl_file_stream_cnf <cnf> <key> <default>: one scalar of env.box.file_streams.
spl_file_stream_cnf() {
  local v
  v="$(yq -r ".env.box.file_streams.$2 // \"\"" "$1" 2>/dev/null)"
  printf '%s' "${v:-$3}"
}

# spl_file_stream_env <cnf>: fill the caller's envs array, the follower's
# FILE_STREAMS_* settings from the cnf (an env var of the same name wins).
spl_file_stream_env() {
  local cnf="$1" k v allow extra="" r
  local -A keys=([START_LINES]=start_lines [TICK_S]=tick_s [RUN_S]=run_s [PEM_MAX_LINES]=pem_max_lines
    [LINE_BYTES]=line_bytes [RATE_PER_MIN]=rate_per_min [QUEUE_MAX]=queue_max [MAX]=max_streams)
  for k in "${!keys[@]}"; do
    v="FILE_STREAMS_$k"; v="${!v:-$(spl_file_stream_cnf "$cnf" "${keys[$k]}" "")}"
    [[ -z "$v" ]] && continue
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "FATAL file-streams: $k must be a whole number, got: '$v'"; return 1; }
    envs+=("FILE_STREAMS_$k=$v")
  done
  allow="${FILE_STREAMS_ALLOW:-$(yq -o json -I0 '.env.box.file_streams.allow // []' "$cnf" 2>/dev/null)}"
  envs+=("FILE_STREAMS_ALLOW=${allow:-[]}")
  # The deny list's extra roots: the cnf spool root and workspace bases,
  # and the desk dir of SPL_STATE_DIR (spec 160 3.2).
  for k in spool_root workspace_base fleet_workspace_base; do
    r="$(yq -r ".env.box.$k // \"\"" "$cnf" 2>/dev/null)"
    [[ -n "$r" ]] && extra+="${extra:+:}$r"
  done
  [[ -n "${SPL_STATE_DIR:-}" ]] && extra+="${extra:+:}$SPL_STATE_DIR/desk"
  envs+=("FILE_STREAMS_DENY_EXTRA=$extra")
  [[ -n "${FILE_STREAMS_STATE_DIR:-}" ]] && envs+=("FILE_STREAMS_STATE_DIR=$FILE_STREAMS_STATE_DIR")
  [[ -n "${SPOOL_ROOT:-}" ]] && envs+=("SPOOL_ROOT=$SPOOL_ROOT")
  if [[ "${FILE_STREAMS_PUSH:-1}" == 0 ]]; then
    envs+=("FILE_STREAMS_PUSH_CMD=")
  else
    envs+=("FILE_STREAMS_PUSH_CMD=${FILE_STREAMS_PUSH_CMD:-timeout 20 spool file-streams push --json -}")
  fi
}
