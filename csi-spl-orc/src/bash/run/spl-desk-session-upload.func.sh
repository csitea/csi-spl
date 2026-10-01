#!/bin/bash
#------------------------------------------------------------------------------
# @description Upload ONE seated agent's session transcript, redacted, as a file
# @description in its DM with the human - the backfill of the terminal mirror
# @description (specs/036). The live mirror then keeps posting into the SAME
# @description topic, so the human reads the history and what follows in one
# @description conversation.
# @description   1. the transcript is found and rendered by
# @description      spool-session-export.py, run as the AGENT user (the CLI
# @description      transcripts are theirs, mode 0600), and redacted by
# @description      spool_redact.py before it is written anywhere
# @description   2. the topic: the one the mirror would post in (the human's
# @description      last DM to this agent, else the mirror's own topic); none
# @description      yet -> the hub mints one and the mirror adopts it
# @description   3. `spool send --put-file` from the agent's desk seat, to the
# @description      human on box-wui; the seat's sidecar flushes it
# @description Prints one JSON line (agent, human, task_id, msg_id, bytes,
# @description redaction counts). The markdown stays in the seat's .mirror/
# @description dir (0600). Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent id whose session is uploaded
# @param SESSION_TOKEN - required: a string only this agent's transcript holds
# @param   (its brief path, one of its own inbox message paths), or the
# @param   transcript's path
# @param DESK_BOX (optional) - default box-desk
# @param DESK_TO (optional) - the human; default: the mirror's human (the DM
# @param   peer, else <desk>/mirror-to, else SPOOL_MIRROR_TO). None -> FATAL:
# @param   a human id is per env, so nothing is guessed
# @param SESSION_AGENT_USER (optional) - the user the agent CLI runs as,
# @param   default $SPOOL_AGENT_USER, else the current user
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 SESSION_TOKEN=/var/tmp/claude/msgs/CLE-00/inbox/brief.md DRY_RUN=0 ./run -a do_spl_desk_session_upload
#------------------------------------------------------------------------------
do_spl_desk_session_upload() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local token="${SESSION_TOKEN:-}" to="${DESK_TO:-}" auser="${SESSION_AGENT_USER:-${SPOOL_AGENT_USER:-$(id -un)}}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ -n "$token" ]] || { do_log "FATAL SESSION_TOKEN must name a string only $agent's transcript holds, or its path"; return 1; }
  [[ -z "$to" || "$to" =~ ^HUM-[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL DESK_TO must be a human id (HUM-...), got: '$to'"; return 1; }
  [[ "$auser" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL SESSION_AGENT_USER is not a user name: '$auser'"; return 1; }

  local feat; feat="$(spl_desk_mirror_scripts)"
  local hub d adir
  hub="$SPL_HUB_URL"
  d="$SPL_STATE_DIR/desk/$tenant/$box"; adir="$d/spool/$agent"
  if (( dry )); then
    do_log "INFO DRY_RUN would: export $agent's transcript (the one holding '$token') as $auser, redacted"
    do_log "INFO DRY_RUN would: attach it in $agent's DM${to:+ with $to} from $box in $tenant at $hub"
    [[ -d "$adir" ]] || do_log "INFO DRY_RUN there is no desk seat for $agent ($adir): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was read or sent. Re-run with DRY_RUN=0 to upload."
    return 0
  fi
  [[ -d "$adir" ]] || { do_log "FATAL no desk seat for $agent on $box in $tenant: run do_spl_desk_up first ($adir)"; return 1; }
  spl_host_spool || return 1

  local md="$adir/.mirror/session-$agent-$(date -u +%Y%m%dT%H%M%SZ).md" counts rc=0
  mkdir -p "$adir/.mirror" && chmod 700 "$adir/.mirror" || return 1
  counts="$(spl_desk_session_export "$auser" "$agent" "$token" 2>&1 >"$md")" || rc=$?
  if (( rc != 0 )) || [[ ! -s "$md" ]]; then
    rm -f "$md"; do_log "FATAL cannot export $agent's transcript: $counts"; return 1
  fi
  chmod 600 "$md"

  local pick human task
  pick="$(python3 "$feat/spool-mirror.py" topic "$adir")" || { do_log "FATAL cannot read the mirror topic of $agent"; return 1; }
  IFS=$'\t' read -r human task <<<"$pick"
  if [[ -n "$to" && "$to" != "$human" ]]; then human="$to"; task=""; fi
  [[ -n "$human" ]] || { do_log "FATAL no human to send $agent's session to: pass DESK_TO=HUM-n, or name the desk's human in $d/mirror-to"; rm -f "$md"; return 1; }

  local sent
  local -a args=(send --from "$agent" --to "$human" --to-box box-wui --kind note
    --body "Session transcript of $agent ($(date -u +%Y-%m-%dT%H:%MZ)), secrets redacted - attached: ${md##*/}"
    --put-file "$md")
  [[ -n "$task" ]] && args+=(--task "$task")
  sent="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- "${args[@]}" 2>&1)" ||
    { do_log "FATAL send of $agent's transcript to $human: $sent"; return 1; }
  python3 - "$feat/spool-mirror.py" "$adir" "$ENV" "$tenant" "$box" "$agent" "$human" "$md" "$sent" "$counts" <<'EOF_PY'
import json, os, subprocess, sys
mirror, adir, env, tenant, box, agent, human, md, sent, counts = sys.argv[1:]
try:
    s = json.loads(sent.strip().splitlines()[-1])
except (ValueError, IndexError):
    s = {}
try:
    c = json.loads(counts.strip().splitlines()[-1]).get("redactions", {})
except (ValueError, IndexError, AttributeError):
    c = {}
task = str(s.get("task_id", ""))
subprocess.run([sys.executable, mirror, "remember", adir, human, task], check=False)
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "to": human,
                  "task_id": task, "msg_id": s.get("msg_id"), "file": os.path.basename(md),
                  "bytes": os.path.getsize(md), "redactions": c}, sort_keys=True))
EOF_PY
  do_log "OK $agent's session is attached in its DM with $human; the live mirror posts into the same topic"
}

# spl_desk_session_export <agent user> <agent> <token>: the redacted markdown on
# stdout, the redaction counts on stderr. Run as the agent user, because the
# CLI transcripts are theirs; the markdown never touches a shared tmp dir.
spl_desk_session_export() {
  local auser="$1" agent="$2" token="$3"
  local exp; exp="$(spl_desk_mirror_scripts)/spool-session-export.py"
  if [[ "$auser" == "$(id -un)" ]]; then
    python3 "$exp" "$agent" "$token" -
  else
    sudo -n -u "$auser" env SPOOL_AGENT_HOME="$(getent passwd "$auser" | cut -d: -f6)" python3 "$exp" "$agent" "$token" -
  fi
}

# spl_desk_mirror_scripts: the spawn-agents scripts dir of THIS checkout,
# found from this file rather than from ORG/APP, which a worktree misreads.
spl_desk_mirror_scripts() {
  readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/scripts"
}
