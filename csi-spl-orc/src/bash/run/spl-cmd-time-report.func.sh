#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only: where the fleet's agents WAIT. Parses every Claude
# @description Code transcript of the agent user and the box user
# @description (<home from passwd>/.claude/projects/*/*.jsonl) touched in the
# @description window, takes each Bash tool call's wall time (its result's
# @description timestamp minus the call's), normalises the command to its
# @description ACTION (the `./run -a do_X` name, a script's basename, or the
# @description first program plus the verb of git / gh / spool / make ...; a
# @description while / until / sleeping for loop is "poll-loop <action>"), and
# @description prints one markdown table ranked by TOTAL wait: calls, total s,
# @description share %, median, p90, max and the roles that paid it (orch,
# @description dispatcher from lease.conf; any other csi-spl-wt/<dir> a lane;
# @description any other cwd "other"). Prints action names only, never a
# @description command's arguments or output (they may hold secrets). Calls
# @description started with run_in_background are skipped (nobody waited);
# @description a call cut by the Bash tool's 600 s timeout counts 600 s.
# @description The parser is spl-cmd-time-report.py beside this file.
# @param SINCE (optional) - window start, ISO 8601 UTC; default UNTIL minus 24 h
# @param UNTIL (optional) - window end, ISO 8601 UTC; default now
# @param ROLE (optional) - orch | dispatcher | lane | other: only that role's calls
# @param CMD_TIME_TOP (optional) - rows before "(N more actions)", default 30
# @param CMD_TIME_USERS (optional) - the users whose transcripts are read, default the agent user and the box user (box.env)
# @param CMD_TIME_DIRS (optional) - projects dirs to read instead of the users' (tests)
# @param CMD_TIME_ROLES (optional) - "<rundir>=<role>,..." instead of lease.conf + registry.tsv
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_cmd_time_report
# @example SINCE=2026-10-07T00:00:00Z ROLE=orch ./run -a do_spl_cmd_time_report
#------------------------------------------------------------------------------
do_spl_cmd_time_report() {
  do_require_bin python3 || return 1
  local py feat until since roles u d top="${CMD_TIME_TOP:-30}" role="${ROLE:-}"
  py="$(dirname "${BASH_SOURCE[0]}")/spl-cmd-time-report.py"
  feat="$(cd "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents" && pwd)"
  declare -F spool_env_resolve >/dev/null || source "$feat/lib/spool-env.inc.sh"
  SPOOL_ENV_NO_BINS=1 spool_env_resolve
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  [[ "$top" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL CMD_TIME_TOP must be a positive integer (got '$top')"; return 2; }
  [[ "$role" =~ ^(|orch|dispatcher|lane|other)$ ]] || { do_log "FATAL ROLE must be orch, dispatcher, lane or other (got '$role')"; return 2; }
  until="$(date -u -d "${UNTIL:-now}" +%FT%TZ 2>/dev/null)" || { do_log "FATAL UNTIL is not a date: '${UNTIL:-}'"; return 2; }
  since="$(date -u -d "${SINCE:-$until -24 hours}" +%FT%TZ 2>/dev/null)" || { do_log "FATAL SINCE is not a date: '${SINCE:-}'"; return 2; }
  [[ "$since" < "$until" ]] || { do_log "FATAL SINCE $since is not before UNTIL $until"; return 2; }
  roles="${CMD_TIME_ROLES-$(spl_cmd_time_rolemap "$SPOOL_ROOT")}"
  local -a src=()
  if [[ -n "${CMD_TIME_DIRS:-}" ]]; then
    for d in $CMD_TIME_DIRS; do src+=("$(id -un):$d"); done
  else
    for u in $(tr ' ' '\n' <<<"${CMD_TIME_USERS:-${SPOOL_AGENT_USER:-} ${SPOOL_BOX_USER:-}}" | awk 'NF && !seen[$0]++'); do
      d="$(getent passwd "$u" | cut -d: -f6)"
      [[ -n "$d" ]] || { do_log "FATAL no passwd entry for '$u'"; return 2; }
      src+=("$u:$d/.claude/projects")
    done
  fi
  (( ${#src[@]} )) || { do_log "FATAL no user to read (CMD_TIME_USERS, or SPOOL_AGENT_USER / SPOOL_BOX_USER)"; return 2; }
  for d in "${src[@]}"; do
    u="${d%%:*}" d="${d#*:}"
    if [[ "$u" == "$(id -un)" ]]; then python3 "$py" scan "$since" "$until" "$roles" "$d"
    else sudo -n -u "$u" python3 "$py" scan "$since" "$until" "$roles" "$d" ||
      do_log "WARN cannot read $u's transcripts (sudo -n -u $u refused): left out"; fi
  done | python3 "$py" report "$since" "$until" "$top" "$role"
}

# spl_cmd_time_rolemap SPOOL_ROOT: "<rundir>=<role>,..." for the desk seats of
# lease.conf (LEASE_ORCH orch; LEASE_MASTER, LEASE_FAILOVER dispatcher), each
# seat under its id AND every rundir registry.tsv ever gave it. The roles are
# today's lease: a seat that changed role inside the window is read as today's.
spl_cmd_time_rolemap() {
  local root="$1" conf="$1/dispatch/lease.conf" k id r out=""
  [[ -r "$conf" ]] || return 0
  for k in LEASE_ORCH LEASE_MASTER LEASE_FAILOVER; do
    id="$(sed -n "s/^$k=\([A-Za-z0-9_-]*\)\$/\1/p" "$conf" | sed -n 1p)"
    [[ -n "$id" ]] || continue
    [[ "$k" == LEASE_ORCH ]] && r=orch || r=dispatcher
    out+="$id=$r,"
    while read -r d; do out+="$d=$r,"; done < <(awk -F'\t' -v id="$id" '$1 == id && $4 != "" { n = split($4, p, "/"); print p[n] }' "$root/registry.tsv" 2>/dev/null | sort -u)
  done
  echo "${out%,}"
}
