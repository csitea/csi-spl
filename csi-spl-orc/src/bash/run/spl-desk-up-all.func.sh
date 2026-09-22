#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat EVERY agent that is actually live in a terminal pane on this
# @description machine, and retire the ones that are not. One action for what
# @description was a hand-written loop: on 2026-09-22 the tmux server restarted,
# @description every desk died with it, and the orchestrator re-seated four
# @description agents by hand while the owner watched them read OFFLINE on
# @description dev.spool-hub. That was the second time.
# @description What "live" means here is the same fact the notifier uses: a tmux
# @description window whose name carries an agent id (identity-routing section
# @description 2), on the box user's own socket. Nothing else is a desk.
# @description Per live agent it runs do_spl_desk_up, which is idempotent: the
# @description box key and its hub pin are reused, ONE shared hub-run sidecar
# @description serves the whole box, and an agent whose notice strip is already
# @description a right-hand strip keeps the pane it has - no second pane, and
# @description no resize of a terminal that is already the right shape.
# @description Agents with NO live window are RETIRED: their spool dir is moved
# @description out of $SPOOL_ROOT, which is the dir scan the box announces from
# @description (hubclient scanAgents), so the hub stops listing an agent whose
# @description window is gone. Moved, never deleted - the inbox is the record.
# @description Prints one JSON line (seated, retired, failed) and a per-agent
# @description log. Dry run unless DRY_RUN=0.
# @description SAFETY: with no live agent at all this refuses to retire
# @description anything. "tmux is not answering" and "this box has no agents"
# @description are different facts and only one of them means retire.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desks are seated in
# @param DESK_BOX (optional) - default box-desk
# @param DESK_POKE (optional) - 1 (default) or 0. An AGENT's only input is its
# @param   prompt, so 0 means every DM is shown in the strip and the agent is
# @param   never told: measured 2026-09-22, two owner messages sat unread in
# @param   CLE-3444's desk inbox while its sidecar ran SPOOL_POKE=0. Set 0 only
# @param   for a seat a PERSON watches, where the prompt is theirs
# @param DESK_RETIRE (optional) - 1 (default) retire agents with no live window,
# @param   0 leave them announced
# @param DESK_SKIP (optional) - space-separated agent ids never to seat
# @param DESK_MUTE (optional) - space-separated agent ids seated with their
# @param   PROMPT left alone (DESK_POKE=0 for those seats only). Use it for a
# @param   pane a PERSON is talking in, where a poke line interrupts them - the
# @param   orchestrator seat is the worked example. Every other agent still
# @param   takes the poke, which is the whole point of making it per agent
# @param DESK_WAIT_SECS (optional) - roster wait per agent, default 30
# @param DESK_RECHECK_SECS (optional) - the SECOND roster read for an agent that
# @param   missed its own wait, default 20. The sidecar rescans every ~10s, so a
# @param   tick that creates several dirs can push one agent announce past its
# @param   window; re-reading the roster costs nothing and keeps a race out of
# @param   the failure list, where it would teach everyone to ignore it
# @param ROOT_KEY_JSON (optional) - only for the FIRST run of a desk box
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_desk_up_all
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_desk_up_all
#------------------------------------------------------------------------------
do_spl_desk_up_all() {
  do_require_bin python3 yq flock || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}"
  local retire="${DESK_RETIRE:-1}" poke="${DESK_POKE:-1}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ "$retire" == 0 || "$retire" == 1 ]] || { do_log "FATAL DESK_RETIRE must be 0 or 1, got: '$retire'"; return 1; }

  local d="$SPL_STATE_DIR/desk/$tenant/$box"
  local -a live=() seat=() seated=() failed=() retired=()
  mapfile -t live < <(spl_desk_live_agents)
  if [[ ${#live[@]} -eq 0 ]]; then
    do_log "FAIL no live agent window on the box user's tmux socket: nothing to seat, and nothing is retired either - a tmux server that is not answering is not the same fact as a box with no agents"
    return 1
  fi
  do_log "INFO live agent windows: ${live[*]}"

  local a skip=" ${DESK_SKIP:-} " mute=" ${DESK_MUTE:-} "
  for a in "${live[@]}"; do
    [[ "$skip" == *" $a "* ]] && { do_log "INFO skipping $a (DESK_SKIP)"; continue; }
    seat+=("$a")
  done

  local -a dead=()
  mapfile -t dead < <(spl_desk_dead_agents "$d" "${live[@]}")

  if (( dry )); then
    do_log "INFO DRY_RUN would: seat ${#seat[@]} agent(s) on $box in $tenant: ${seat[*]:-none}"
    [[ -n "${DESK_MUTE:-}" ]] && do_log "INFO DRY_RUN would: seat these with the prompt left alone (DESK_MUTE): ${DESK_MUTE}"
    if [[ "$retire" == 1 ]]; then
      do_log "INFO DRY_RUN would: retire ${#dead[@]} agent(s) whose window is gone: ${dead[*]:-none}"
    else
      do_log "INFO DRY_RUN would NOT retire (DESK_RETIRE=0); ${#dead[@]} agent(s) have no window: ${dead[*]:-none}"
    fi
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi

  # One reconcile at a time. The cron tick and a human running this by hand
  # would otherwise both drive do_spl_desk_up against the same state dir, and
  # the sidecar lock only protects the sidecar.
  mkdir -p "$d" || { do_log "FATAL cannot create $d"; return 1; }
  exec 8>"$d/up-all.lock" || { do_log "FATAL cannot open $d/up-all.lock"; return 1; }
  if ! flock -n 8; then
    do_log "OK another do_spl_desk_up_all holds $d/up-all.lock: leaving it to that one"
    exec 8>&-; return 0
  fi

  local apoke
  for a in "${seat[@]}"; do
    apoke="$poke"
    [[ "$mute" == *" $a "* ]] && apoke=0
    if TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="$a" DESK_POKE="$apoke" \
       DESK_WAIT_SECS="${DESK_WAIT_SECS:-30}" DRY_RUN=0 do_spl_desk_up; then
      seated+=("$a")
    else
      failed+=("$a"); do_log "FAIL could not seat $a on $box"
    fi
  done

  # SECOND PASS over the ones that failed. The only failure this reconcile sees
  # in practice is the roster-announce wait timing out: the sidecar rescans its
  # dir list every ~10s, and a tick that creates two new agent dirs makes the
  # announce for a THIRD agent land after its own 30s window. Measured
  # 2026-09-22: CLE-3447 failed the wait inside the tick and seated by hand a
  # minute later with the roster answering in about a second.
  #
  # Re-reading the roster is the whole retry - not another do_spl_desk_up, which
  # would rebuild and re-pin for nothing. An agent still absent on the second
  # read stays FAILED, so a real fault is not swallowed; and this matters
  # because a reconcile that exits 1 on every tick for a race teaches everyone
  # to ignore the one tick that exits 1 for a reason.
  if [[ ${#failed[@]} -gt 0 ]]; then
    local -a still=()
    for a in "${failed[@]}"; do
      if spl_desk_wait_roster "$d" "$box" "$a" "${DESK_RECHECK_SECS:-20}" >/dev/null 2>&1; then
        do_log "INFO $a WAS announced on the second read: its announce landed after its own wait, not a fault"
        seated+=("$a")
      else
        still+=("$a")
      fi
    done
    failed=("${still[@]}")
  fi

  if [[ "$retire" == 1 ]]; then
    for a in "${dead[@]}"; do
      spl_desk_retire "$d" "$a" && retired+=("$a")
    done
  fi

  flock -u 8; exec 8>&-
  python3 - "$ENV" "$tenant" "$box" "$d" "${#live[@]}" "${seated[*]:-}" "${retired[*]:-}" "${failed[*]:-}" <<'EOF_PY'
import json, sys
env, tenant, box, state, nlive, seated, retired, failed = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "box": box, "state_dir": state,
                  "live_agents": int(nlive), "seated": seated.split(),
                  "retired": retired.split(), "failed": failed.split()}, sort_keys=True))
EOF_PY
  if [[ ${#failed[@]} -gt 0 ]]; then
    do_log "FAIL ${#failed[@]} of ${#seat[@]} agent(s) were not seated on $box: ${failed[*]}"
    return 1
  fi
  if [[ ${#retired[@]} -gt 0 ]]; then
    do_log "OK ${#seated[@]} agent(s) seated on $box in $tenant ($ENV), ${#retired[@]} retired: ${retired[*]}"
  else
    do_log "OK ${#seated[@]} agent(s) seated on $box in $tenant ($ENV), none retired"
  fi
}

# spl_desk_live_agents: every agent id a live tmux window on this box carries,
# one per line, sorted and unique.
#
# The SAME fact the notifier routes on (spool_id_of_window, identity-routing
# section 2), read through the same library, so a window this cannot see is a
# window a message could not have reached either. Anything else - a registry
# file, a list in a config - drifts, and a roster that drifts is how the hub
# ends up announcing an agent whose window is gone.
spl_desk_live_agents() {
  local feat="$APP_PATH/$SPL_ORG_APP-orc/src/bash/features/spawn-agents"
  [[ -r "$feat/lib/spool-env.inc.sh" ]] || return 0
  (
    # shellcheck disable=SC1091
    . "$feat/lib/spool-env.inc.sh" || exit 0
    SPOOL_ENV_NO_BINS=1 spool_env_resolve
    spool_tmux_argv
    local w id
    while IFS= read -r w; do
      spool_id_of_window_var id "$w"
      [ -n "$id" ] && printf '%s\n' "$id"
    done < <("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null)
  ) 2>/dev/null | sort -u
}

# spl_desk_dead_agents <state dir> <live...>: every agent dir under the desk's
# SPOOL_ROOT that no live window carries. That dir scan is exactly what the box
# announces from (hubclient scanAgents), so this is the list the hub is
# currently lying about.
spl_desk_dead_agents() {
  local d="$1"; shift
  local -a live=("$@")
  local root="$d/spool" e a l hit
  [[ -d "$root" ]] || return 0
  for e in "$root"/*; do
    [[ -d "$e" ]] || continue
    a="$(basename "$e")"
    [[ "$a" =~ ^[A-Z]{2,4}-[0-9]+$ && "${a%%-*}" != BOX ]] || continue
    hit=0
    for l in "${live[@]}"; do [[ "$l" == "$a" ]] && { hit=1; break; }; done
    (( hit )) || printf '%s\n' "$a"
  done
}

# spl_desk_retire <state dir> <agent>: take AGENT out of the dir scan the box
# announces from, so the hub stops listing it within one rescan (~10s).
#
# MOVED, never deleted. The inbox is the record (spec 002) and an agent that
# died holding unread messages is exactly the case where that matters; a
# retired dir can be moved back and the agent re-seated. The destination is
# timestamped so retiring the same id twice never clobbers the first record.
spl_desk_retire() {
  local d="$1" a="$2" src="$1/spool/$2" dst
  [[ -d "$src" ]] || return 1
  dst="$d/retired/$a.$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$d/retired" || { do_log "FAIL cannot create $d/retired"; return 1; }
  if mv "$src" "$dst" 2>/dev/null; then
    do_log "INFO retired $a: no live window carries it; its spool dir is at $dst and the hub stops listing it on the next rescan"
    return 0
  fi
  do_log "FAIL could not retire $a (mv $src $dst)"
  return 1
}
