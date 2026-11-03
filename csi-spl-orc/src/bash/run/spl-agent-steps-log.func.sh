#!/bin/bash
#------------------------------------------------------------------------------
# @description An agent's progress as a readable file (spec 160 section 3.9,
# @description SPL-4693): finds the agent's newest claude session jsonl from
# @description its worktree slug (<home>/.claude/projects/*-wt*-<id>/) and
# @description appends one line per step to <dir>/<id>.steps.log: UTC time,
# @description kind (prompt, tool + a short arg, result ok|error, text), every
# @description line redacted, never the content a tool read. Incremental: the
# @description byte offset is kept in <dir>/.<id>.steps.state.json, so a re-run
# @description appends only new steps. Runs src/bash/scripts/agent-steps-log.py
# @description as the caller (the box user, who owns the log dir), reading the
# @description jsonl as the agent user (it is 0600; --read-as, sudo -n); the
# @description log is 0644, read by the box file follower (cnf
# @description env.box.file_streams.allow). The
# @description minute cron row agent-steps-log runs it for the ids of
# @description spl_agent_steps_log_ids (box.env AGENT_STEPS_LOG_AGENTS, else
# @description cnf env.box.agent_steps_log.agents; empty = nothing runs).
# @param AGENT_ID (required) - one agent id ([acgmq]-NNN), or several,
# @param   space separated
# @param AGENT_STEPS_LOG_SESSION (optional) - the session jsonl, one AGENT_ID
# @param   only; default the newest *.jsonl of the agent's project dir
# @param AGENT_STEPS_LOG_DIR (optional) - default /var/csi/csi-spl/agent-logs
# @param AGENT_STEPS_LOG_USER (optional) - default the first
# @param   spl_cost_agent_users user (box.env SPOOL_AGENT_USER)
# @param AGENT_STEPS_LOG_PROJECTS (optional) - default
# @param   <agent user home>/.claude/projects
# @example AGENT_ID=c-141 ./run -a do_spl_agent_steps_log
# @example AGENT_ID=c-141 AGENT_STEPS_LOG_SESSION=/path/to/session.jsonl ./run -a do_spl_agent_steps_log
#------------------------------------------------------------------------------

declare -F spl_cost_agent_users >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cost-tokens-read.func.sh"

# Exit: 0 every id written, 1 a usage or setup refusal, 3 an id has no
# session file, 4 a session file is not readable (the last failing id's code).
do_spl_agent_steps_log() {
  local orc py dir user ids id rc=0 r
  orc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  py="$orc/src/bash/scripts/agent-steps-log.py"
  ids="${AGENT_ID:-}"
  [[ -n "${ids// /}" ]] || { echo "FATAL agent-steps-log: AGENT_ID must be set, e.g. AGENT_ID=c-141"; return 1; }
  for id in $ids; do
    [[ "$id" =~ ^[acgmq]-[0-9]{3}$ ]] || { echo "FATAL agent-steps-log: bad agent id '$id'"; return 1; }
  done
  if [[ -n "${AGENT_STEPS_LOG_SESSION:-}" && "$ids" == *" "* ]]; then
    echo "FATAL agent-steps-log: AGENT_STEPS_LOG_SESSION takes one AGENT_ID"; return 1
  fi
  user="${AGENT_STEPS_LOG_USER:-$(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}" | sed -n 1p)}"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$user" != root ]] || { echo "FATAL agent-steps-log: bad agent user '$user'"; return 1; }
  dir="${AGENT_STEPS_LOG_DIR:-/var/csi/csi-spl/agent-logs}"
  [[ -d "$dir" ]] || { mkdir -p "${dir%/*}" && mkdir -m 0755 "$dir"; } 2>/dev/null
  [[ -w "$dir" ]] || { echo "FATAL agent-steps-log: $(id -un) cannot write $dir"; return 1; }
  for id in $ids; do
    spl_agent_steps_log_one "$user" "$py" "$dir" "$id"; r=$?
    [[ "$r" == 0 ]] || rc="$r"
  done
  return "$rc"
}

# spl_agent_steps_log_one <user> <py> <dir> <id>: one agent's steps file.
spl_agent_steps_log_one() {
  local user="$1" py="$2" dir="$3" id="$4" s
  s="${AGENT_STEPS_LOG_SESSION:-$(spl_agent_steps_log_session "$user" "$id")}"
  [[ -n "$s" ]] || { echo "FATAL agent-steps-log: $id: no claude session jsonl under $(spl_agent_steps_log_projects "$user")/*-wt*-$id/"; return 3; }
  python3 "$py" --session "$s" --read-as "$user" --out "$dir/$id.steps.log" \
    --state "$dir/.$id.steps.state.json" | sed -u "s/^/$id /"
  return "${PIPESTATUS[0]}"
}

# spl_agent_steps_log_projects <user>: the agent user's claude projects dir.
spl_agent_steps_log_projects() {
  printf '%s' "${AGENT_STEPS_LOG_PROJECTS:-$(getent passwd "$1" | cut -d: -f6)/.claude/projects}"
}

# spl_agent_steps_log_session <user> <id>: the newest top-level *.jsonl of
# the project dirs of <id>'s worktree (slug ...-wt[N]-<id>), read as <user>;
# empty when there is none. A subagent's jsonl (<sid>/subagents/) is not one.
spl_agent_steps_log_session() {
  local user="$1" id="$2" p
  p="$(spl_agent_steps_log_projects "$user")"
  spl_cost_as "$user" find "$p" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null |
    awk -v id="$id" '{ d = $2; sub(/\/[^\/]*$/, "", d); sub(/.*\//, "", d) } d ~ ("-wt[0-9]*-" id "$")' |
    sort -n | tail -n 1 | cut -d' ' -f2-
}

# spl_agent_steps_log_ids [<cnf>]: the agent ids the cron row writes, space
# separated: box.env AGENT_STEPS_LOG_AGENTS wins (the per-box list), else cnf
# env.box.agent_steps_log.agents (default []). Empty = nothing to do.
spl_agent_steps_log_ids() {
  local cnf="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/../csi-spl-cnf/csi-spl/all.env.yaml}" f v=""
  f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  if [[ "${SPOOL_TEST:-}" != 1 || -n "${SPOOL_BOX_ENV:-}" ]] && [[ -r "$f" ]]; then
    v="$(sed -n 's/^AGENT_STEPS_LOG_AGENTS=//p' "$f" | tail -n 1 | tr -d "\"'\r")"
  fi
  [[ -n "${v// /}" ]] || v="$(yq -r '.env.box.agent_steps_log.agents // [] | join(" ")' "$cnf" 2>/dev/null)"
  printf '%s' "$v"
}
