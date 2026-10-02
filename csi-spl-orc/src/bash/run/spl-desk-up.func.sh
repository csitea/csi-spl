#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat an agent that ALREADY runs in a terminal pane on this
# @description machine at a cloud tenant, so a signed-in human can DM it from
# @description the WUI and the message lands in that pane. The "desk" is the
# @description box the pane's agent answers from:
# @description   1. the desk box (DESK_BOX) gets its own SPOOL_ROOT + key under
# @description      the state dir; the FIRST run mints the key and pins it with
# @description      the tenant root key (`spool hub-pin`, POST /v1/pins: the
# @description      documented pin path); later runs reuse key and pin
# @description   2. the desk agent (DESK_AGENT) gets its inbox/outbox/archive
# @description   3. a `spool hub-run` sidecar for that root, carrying
# @description      SPOOL_NOTIFY_CMD (specs/028): every message the hub
# @description      dispatches to DESK_AGENT is written into its inbox AND
# @description      typed into the pane whose window name carries the id, under
# @description      the safe-poke rules (never over unsent text)
# @description   4. the wait for the hub roster to announce DESK_AGENT under
# @description      DESK_BOX - which is also what makes the agent show ONLINE
# @description      in the WUI roster and on its DM page
# @description Prints one JSON line (box, agent, hub, pin, sidecar pid, the DM
# @description URL a human opens, and the exact `do_spl_desk_reply` line the
# @description agent answers with) and nothing secret: the root key is copied
# @description into a 0600 scratch file and removed.
# @description The sidecar is a plain background process: it dies with the box.
# @description Stop it with do_spl_desk_down; re-run this action to restart it.
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd, or self for a self-hosted hub (SPOOL_HUB_URL,
# @param   no cnf: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant slug the agent is seated in
# @param DESK_AGENT - required: the agent id of the pane (spl_is_agent_id)
# @param ROOT_KEY_JSON - required on the FIRST run of a desk (the 0600 JSON
# @param   do_spl_tenant_create wrote, field root_private_key); later runs reuse
# @param   the pin and need no key
# @param DESK_BOX (optional) - default box-desk. The box this machine's panes answer from
# @param DESK_NOTIFY_CMD (optional) - the terminal-leg renderer (specs/028),
# @param   default <org>-<app>-orc/src/bash/features/spawn-agents/scripts/spool-notify.sh.
# @param   `off` seats the agent with NO terminal leg (inbox only)
# @param DESK_POKE (optional) - 1 (default) types the poke line into THIS
# @param   AGENT's prompt under the safe-poke rules; 0 leaves that one prompt
# @param   alone and shows the message only. Use 0 where a person watches the
# @param   pane and the prompt is theirs: an agent with 0 is told nothing it can
# @param   act on. PER AGENT since 2026-09-22 - it writes the marker file
# @param   <spool root>/<agent>/.no-poke, because one sidecar serves the whole
# @param   box and muting it muted every seat
# @param DESK_BOX_POKE (optional) - 1 (default) or 0 for the WHOLE box: the
# @param   sidecar's SPOOL_POKE. 0 silences every agent on this box, which is
# @param   almost never what you want - mute the one seat with DESK_POKE=0.
# @param   A live sidecar carrying a different value is RESTARTED, because that
# @param   flag is only read at exec
# @param DESK_WAIT_SECS (optional) - roster wait, default 30 (hub-run rescans every 10s)
# @param DESK_WUI_URL (optional) - the WUI origin for the printed DM URL,
# @param   default https://<env.dns.fqdn> (ENV=self: the hub URL, the compose stack's one origin)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ROOT_KEY_JSON=/var/csi/csi-spl/tenants/dev/t1.<ts>.json DRY_RUN=0 ./run -a do_spl_desk_up
#------------------------------------------------------------------------------
do_spl_desk_up() {
  do_require_bin python3 yq flock || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  local rkj="${ROOT_KEY_JSON:-}" wait="${DESK_WAIT_SECS:-30}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$wait" =~ ^[0-9]+$ ]] || { do_log "FATAL DESK_WAIT_SECS must be a whole number, got: '$wait'"; return 1; }

  local hub d
  hub="$SPL_HUB_URL"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  local notify="${DESK_NOTIFY_CMD-$APP_PATH/$SPL_ORG_APP-orc/src/bash/features/spawn-agents/scripts/spool-notify.sh}"
  [[ "$notify" == off || -x "$notify" ]] || { do_log "FATAL DESK_NOTIFY_CMD '$notify' is not executable (use 'off' for no terminal leg)"; return 1; }
  local poke="${DESK_POKE:-1}" boxpoke="${DESK_BOX_POKE:-1}"
  [[ "$poke" == 0 || "$poke" == 1 ]] || { do_log "FATAL DESK_POKE must be 0 or 1, got: '$poke'"; return 1; }
  [[ "$boxpoke" == 0 || "$boxpoke" == 1 ]] || { do_log "FATAL DESK_BOX_POKE must be 0 or 1, got: '$boxpoke'"; return 1; }

  local wui="${DESK_WUI_URL:-$SPL_WUI_URL}"
  if (( dry )); then
    do_log "INFO DRY_RUN would: keygen + hub-pin $box under $tenant at $hub (first run only; state $d)"
    do_log "INFO DRY_RUN would: seat $agent on $box and start a spool hub-run sidecar with SPOOL_NOTIFY_CMD=$notify"
    do_log "INFO DRY_RUN would: print the DM URL $wui/dm/$agent@$box and the reply line"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to seat $agent."
    return 0
  fi
  do_require_bin curl setsid || return 1
  spl_host_spool || return 1
  mkdir -p "$d/spool/$agent/inbox" "$d/spool/$agent/outbox" "$d/spool/$agent/archive" "$d/spool/.hub" "$d/keys" ||
    { do_log "FATAL cannot create the desk state under $d"; return 1; }
  chmod -R go-rwx "$d" || return 1

  local pub
  pub="$(spl_desk_pin "$d" "$box" "$tenant" "$hub" "$rkj")" || return 1
  spl_desk_mute "$d" "$agent" "$poke"
  spl_desk_purge_pokes "$d" "$agent" "$poke"
  spl_desk_sidecar "$d" "$box" "$tenant" "$hub" "$notify" "$boxpoke" || return 1
  local pid="$SPL_DESK_PID"
  local announced=0
  spl_desk_wait_roster "$d" "$box" "$agent" "$wait" && announced=1
  local notice_pane
  notice_pane="$(spl_desk_show_pane "$d" "$agent" "$notify")"
  [[ -n "$notice_pane" ]] && do_log "INFO the notice pane of $agent is $notice_pane (its window's own split; blue, newest first)"

  local reply="ENV=$ENV TENANT_ID=$tenant DESK_AGENT=$agent${DESK_BOX:+ DESK_BOX=$box} DRY_RUN=0 DESK_BODY='<your answer>' ./run -a do_spl_desk_reply"
  python3 - "$ENV" "$tenant" "$hub" "$box" "$agent" "$pub" "$d" "$pid" "$announced" "$notify" "$wui/dm/$agent@$box" "$reply" "${notice_pane:-}" <<'EOF_PY'
import json, sys
env, tenant, hub, box, agent, pub, state, pid, announced, notify, dm_url, reply, notice = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "hub": hub, "box": box, "agent": agent,
                  "box_pubkey": pub, "state_dir": state, "sidecar_pid": int(pid),
                  "roster_announced": announced == "1", "notify_cmd": notify,
                  "notice_pane": notice or None,
                  "dm_url": dm_url, "reply_cmd": reply}, sort_keys=True))
EOF_PY
  (( announced )) || {
    do_log "FAIL $agent is not announced on $box within ${wait}s: see $d/spool/.hub/hub-run.log"; return 1; }
  do_log "OK $agent is seated on $box in $tenant ($ENV): a human DMs it at $wui/dm/$agent@$box"
  do_log "OK the terminal leg is $notify (prompt poke for $agent: $poke, box-wide: $boxpoke); the agent answers with: $reply"
}

# spl_desk_show_pane <state dir> <agent> <notify cmd>: re-attach the agent's
# notice pane, so ONE command brings a desk back. Prints its pane id.
#
# Neither the sidecar nor the pane survives a reboot - the sidecar is a
# detached process and the pane belongs to a tmux server that also died. After
# the box came back on 2026-09-21 the desk was reachable again in one action
# while the notices still rendered NOWHERE, which is the failure the owner
# complained about wearing a different hat. So the pane is part of "up".
#
# Only for a pane that paints a TUI: on the normal screen the notifier writes
# to the tty and a split would be noise. Never fatal - a desk with no window
# is still a desk, and the inbox is still the record.
spl_desk_show_pane() {
  local d="$1" agent="$2" notify="$3" feat
  [[ "$notify" == off ]] && return 0
  feat="$APP_PATH/$SPL_ORG_APP-orc/src/bash/features/spawn-agents"
  [[ -r "$feat/lib/spool-poke-queue.inc.sh" ]] || return 0
  (
    export SPOOL_ROOT="$d/spool"
    # shellcheck disable=SC1091
    . "$feat/lib/spool-env.inc.sh" && . "$feat/lib/spool-notify.inc.sh" && . "$feat/lib/spool-poke-queue.inc.sh" || exit 0
    spool_env_resolve
    local pane
    pane="$(spool_pane_of "$agent")"
    [ -n "$pane" ] || exit 0
    spool_tmux_argv
    spool_strip_wanted "$pane" "$agent" || exit 0
    spool_show_notice_pane "$agent" "$pane"
  ) 2>/dev/null
}

# spl_desk_validate <tenant> <box> <agent>: the shared id rules of the desk
# actions. box-wui is the hub's own signing box and is never a desk.
# An action that names no agent passes the agent as none.
spl_desk_validate() {
  local tenant="$1" box="$2" agent="$3"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  [[ "$agent" == none ]] || spl_is_agent_id "$agent" || { do_log "FATAL DESK_AGENT '$agent' is not an agent id (e.g. CLE-00)"; return 1; }
}

# spl_desk_spool <state dir> <box> <tenant> <hub> -- <spool args>: the desk
# box's `spool`. SPOOL_MIRROR_LOCAL stays unset: a desk answers humans on
# box-wui, never itself.
spl_desk_spool() {
  local d="$1" box="$2" tenant="$3" hub="$4"; shift 4; [[ "${1:-}" == -- ]] && shift
  SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" \
    SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" "$SPL_SPOOL" "$@"
}

# spl_desk_pin <state dir> <box> <tenant> <hub> <root key json>: the box key and
# its hub pin, once per desk. Prints the box public key.
spl_desk_pin() {
  local d="$1" box="$2" tenant="$3" hub="$4" rkj="$5" pub key out rc=0
  if [[ -s "$d/pinned" ]]; then cat "$d/pinned"; return 0; fi
  [[ -s "$rkj" ]] || { do_log "FATAL the first run of desk $box needs ROOT_KEY_JSON (the tenant's saved create JSON)"; return 1; }
  [[ "$(stat -c %a "$rkj")" == 600 ]] || { do_log "FATAL $rkj must be mode 0600"; return 1; }
  pub="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- keygen 2>&1)" || { do_log "FATAL keygen for $box: $pub"; return 1; }
  key="$(umask 077 && mktemp)" || return 1
  spl_root_key_to_file "$rkj" "$key" ||
    { rm -f "$key"; do_log "FATAL $rkj holds no tenant root key (a create JSON with root_private_key, or a bare base64 key)"; return 1; }
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-pin --box "$box" --pubkey "$pub" --root-key "$key" 2>&1)" || rc=$?
  rm -f "$key"
  (( rc == 0 )) || { do_log "FATAL hub-pin $box under $tenant: $out"; return 1; }
  printf '%s\n' "$pub" >"$d/pinned"
  do_log "INFO pinned $box ($pub) under $tenant at $hub"
  cat "$d/pinned"
}

# spl_desk_mute <state dir> <agent> <poke>: the PER-AGENT prompt leg, as the
# marker file the notifier reads.
#
# A file rather than a variable, and per agent rather than per box, because the
# box-wide SPOOL_POKE is the one sidecar's environment: it is read once at exec
# and it is shared by every seat. On 2026-09-22 the orchestrator seat wanted a
# quiet prompt, the only knob available muted the whole box, and two owner DMs
# reached nobody while every check read green.
spl_desk_mute() {
  local d="$1" agent="$2" poke="$3" m="$1/spool/$2/.no-poke"
  if [[ "$poke" == 0 ]]; then
    : >"$m" 2>/dev/null || { do_log "FAIL cannot write $m; $agent will still be poked"; return 1; }
    do_log "INFO $agent is MUTED (DESK_POKE=0): its prompt is never typed into, and only that one seat is affected"
  elif [[ -e "$m" ]]; then
    rm -f "$m" 2>/dev/null
    do_log "INFO $agent is no longer muted: its prompt takes the poke line again"
  fi
  return 0
}

# spl_desk_purge_pokes <state dir> <agent> <poke>: with the prompt leg OFF,
# leave nothing behind that could still ring it. A queue and its daemon outlive
# the sidecar that made them, so a desk restarted with DESK_POKE=0 would
# otherwise still be storming its own prompt from the PREVIOUS run - which is
# exactly what happened here on 2026-09-21: 24 entries and a live daemon
# survived a restart meant to stop them.
spl_desk_purge_pokes() {
  local d="$1" agent="$2" poke="$3" q="$1/spool/$2/.pokes" pid n
  [[ "$poke" == 0 ]] || return 0
  pid="$(cat "$q/retry.pid" 2>/dev/null)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; do_log "INFO stopped the poke-retry daemon of $agent (pid $pid): DESK_POKE=0"
  fi
  n="$(ls -1 "$q"/*.poke 2>/dev/null | wc -l)"
  rm -f "$q"/*.poke "$q/retry.pid" 2>/dev/null
  (( n > 0 )) && do_log "INFO dropped $n queued poke(s) for $agent: DESK_POKE=0, and every one of those messages is in its inbox"
  return 0
}

# spl_desk_alive <pid file>: 0 when that pid is a live `spool hub-run`.
spl_desk_alive() {
  local pid
  pid="$(cat "$1" 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q ' hub-run'
}

# spl_desk_sidecar <state dir> <box> <tenant> <hub> <notify cmd>: ONE live
# `spool hub-run` for this root, under a lock (two would both drain the queue).
# Sets SPL_DESK_PID to its pid. It carries SPOOL_NOTIFY_CMD: the sidecar is the
# process that writes a human's WUI message into the local inbox, so it is the
# one that has to ring the pane (specs/028 FR-001).
#
# It is started through spl_desk_detach, NOT a plain `setsid ... &`: run.sh
# pipes its own output through a reader process, and a daemon that inherits
# those pipe fds holds them open for ever - the reader never sees EOF and
# `./run` never returns. Measured on this box 2026-09-21: the sidecar held
# run.sh's fd 61/62/63 and the action hung after every step had passed.
spl_desk_sidecar() {
  local d="$1" box="$2" tenant="$3" hub="$4" notify="$5" poke="${6:-1}"
  # $poke here is the BOX-wide SPOOL_POKE, not one agent's: this process serves
  # every seat on the box. A single agent is spared with spl_desk_mute.
  local hubd="$d/spool/.hub" pidf livepoke
  pidf="$hubd/hub-run.pid"
  SPL_DESK_PID=""
  exec 9>"$hubd/hub-run.lock" || { do_log "FATAL cannot open $hubd/hub-run.lock"; return 1; }
  flock 9
  # SPOOL_POKE is read by the sidecar ONCE, at exec. A live sidecar carrying a
  # different value than this call asks for is not a desk that can be fixed by
  # asking again: re-running with DESK_POKE=1 against a SPOOL_POKE=0 process
  # changed nothing and reported success, which is how two owner messages sat
  # unread in an agent inbox on 2026-09-22 while every check read green. So the
  # mismatch RESTARTS it rather than being accepted.
  if spl_desk_alive "$pidf"; then
    livepoke="$(spl_desk_sidecar_poke "$(cat "$pidf")")"
    # SPL-952: a sidecar still running a spool binary that has since been
    # rebuilt validates with the OLD code. Measured on prd 2026-09-26: a 15 h
    # old hub-run moved a DESK_KIND=blocker line to .hub/rejected/ because its
    # binary predated the kind, while the rebuilt file on disk accepted it.
    local stale=0
    spl_desk_sidecar_stale "$(cat "$pidf")" && stale=1
    if [[ "$stale" == 1 || ( -n "$livepoke" && "$livepoke" != "$poke" ) ]]; then
      if [[ "$stale" == 1 ]]; then
        do_log "INFO the live sidecar of $box runs a spool binary that has been rebuilt since it started; restarting it on the new one"
      else
        do_log "INFO the live sidecar of $box runs SPOOL_POKE=$livepoke but this call asks for $poke; restarting it, because that flag is only read at exec"
      fi
      kill "$(cat "$pidf")" 2>/dev/null || true
      local w
      for ((w = 0; w < 75; w++)); do spl_desk_alive "$pidf" || break; sleep 0.2; done
      spl_desk_alive "$pidf" && { do_log "FATAL the sidecar of $box will not stop, so SPOOL_POKE cannot be changed"; flock -u 9; exec 9>&-; return 1; }
      rm -f "$pidf"
    fi
  fi
  if spl_desk_alive "$pidf"; then
    SPL_DESK_PID="$(cat "$pidf")"
    do_log "INFO the hub-run sidecar of $box is already live (pid $SPL_DESK_PID, log $hubd/hub-run.log)"
  else
    # SPOOL_TRACE is passed THROUGH, never defaulted (CLE-3435). Unset - which
    # is every ordinary desk - the spool binary's stopwatch stays off and costs
    # nothing; do_spl_latency_probe sets it to time the hops this sidecar
    # crosses.
    #
    # SPOOL_FLEET_ROOT (specs/058 N1): an agent-to-agent DM from another
    # machine is also written into <fleet root>/<agent>/inbox, the inbox a
    # harness agent reads with `spool recv` - the receiving half of
    # spool-send.sh's hub relay. Default the harness root when it exists;
    # SPOOL_FLEET_ROOT= (empty) turns the copy off.
    local fleet="${SPOOL_FLEET_ROOT-/var/spool-hub}"
    [[ -n "$fleet" && -d "$fleet" ]] || fleet=""
    SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" \
    SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" SPOOL_NOTIFY_CMD="$notify" SPOOL_POKE="$poke" \
    SPOOL_TRACE="${SPOOL_TRACE:-}" SPOOL_FLEET_ROOT="$fleet" \
      spl_desk_detach "$hubd/hub-run.log" "$SPL_SPOOL" hub-run
    SPL_DESK_PID=$!
    printf '%s\n' "$SPL_DESK_PID" >"$pidf"
    do_log "INFO started the hub-run sidecar of $box (pid $SPL_DESK_PID, log $hubd/hub-run.log)"
  fi
  flock -u 9; exec 9>&-
  [[ -n "$SPL_DESK_PID" ]]
}

# spl_desk_sidecar_stale <pid>: true when that process runs a binary whose file
# has been replaced since it started. A rebuild writes a new file, so the
# kernel shows the running image as "<path> (deleted)".
spl_desk_sidecar_stale() {
  local pid="$1" exe
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || return 1
  [[ "$exe" == *" (deleted)" ]]
}

# spl_desk_sidecar_poke <pid>: the SPOOL_POKE that process was started with, or
# nothing when it cannot be read.
#
# From /proc/<pid>/environ, which is the value the process actually runs under -
# not what a config file or this action would set now. That distinction is the
# whole point: the flag is read at exec, so only the process itself knows it.
spl_desk_sidecar_poke() {
  local pid="$1" v
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/environ" ]] || return 0
  v="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^SPOOL_POKE=//p' | tail -n 1)"
  [[ "$v" == 0 || "$v" == 1 ]] && printf '%s' "$v"
  return 0
}

# spl_desk_detach <log file> <cmd> [args]: start CMD as a session leader whose
# ONLY open descriptors are /dev/null and LOG. Every descriptor above fd 2 -
# run.sh's logging pipes, the flock fd, a caller's command substitution - is
# closed in the child before the exec, so nothing upstream ever waits on this
# daemon. The pid of the started job is $! in the caller.
spl_desk_detach() {
  local log="$1"; shift
  setsid bash -c '
    log="$1"; shift
    exec </dev/null >>"$log" 2>&1
    for f in /proc/$$/fd/*; do
      n="${f##*/}"
      case "$n" in 0|1|2) continue ;; esac
      eval "exec $n>&-" 2>/dev/null || true
    done
    exec "$@"' _ "$log" "$@" &
}

# spl_desk_wait_roster <state dir> <box> <agent> <secs>: 0 once the sidecar's
# roster cache announces AGENT under BOX - the same fact that turns the agent
# ONLINE in the WUI roster.
spl_desk_wait_roster() {
  local d="$1" box="$2" agent="$3" secs="$4" roster="$d/spool/.hub/roster.json" i
  for ((i = 0; i < secs * 5; i++)); do
    if [[ -r "$roster" ]] && grep -oE "\"$box\":\[[^]]*\]" "$roster" 2>/dev/null | grep -q "\"$agent\""; then
      do_log "INFO the hub announces $agent on $box (roster $roster)"; return 0
    fi
    spl_desk_alive "$d/spool/.hub/hub-run.pid" || { do_log "FATAL the hub-run sidecar of $box died: $(tail -n 3 "$d/spool/.hub/hub-run.log" 2>/dev/null)"; return 1; }
    sleep 0.2
  done
  return 1
}
