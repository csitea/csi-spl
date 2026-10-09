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
# @description anything, but still starts the box's hub-run sidecar when it is
# @description down (_spl_desk_up_all_no_window): the box is reachable from the
# @description first tick after a boot, not from the first agent window. "tmux is not answering" and "this box has no agents"
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
# @param DESK_HUB_CHECK (optional) - 1 (default) or 0. After seating, ask the
# @param   HUB whether it has a session for the box, and restart a sidecar that
# @param   is alive while the hub says the box is offline (do_spl_desk_check's
# @param   `stranded`). Seating only ever looked at the local process and the
# @param   local roster cache, so on 2026-09-25 a tick reported "13 seated, none
# @param   failed" at 13:50:35Z while the box had been stranded since a hub
# @param   redeploy ~45 min earlier. Reads the roster like do_spl_desk_check
# @param   (DESK_ROSTER_JSON / PROBE_EMAIL / PROBE_PW_FILE); a roster read that
# @param   fails is logged as a WARN and repairs nothing
# @param DESK_SEATED_ONLY (optional) - 1 = seat only the live agents ALREADY
# @param   seated on this desk (an agent dir under its spool root), never a new
# @param   one. What do_spl_desk_up_tenants runs for a tenant other than the
# @param   box's main one: its desk holds agents someone chose for it, and this
# @param   brings its sidecar back after it died (SPL-1004), default 0
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
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}"
  local retire="${DESK_RETIRE:-1}" poke="${DESK_POKE:-1}"
  local hubcheck="${DESK_HUB_CHECK:-1}"
  _spl_desk_up_all_check_args "$tenant" "$box" "$retire" "$hubcheck" || return 1

  local d="$SPL_STATE_DIR/desk/$tenant/$box"
  local -a live=() seat=() seated=() failed=() retired=()
  mapfile -t live < <(spl_desk_live_agents)
  if [[ ${#live[@]} -eq 0 ]]; then
    do_log "FAIL no live agent window on the box user's tmux socket: nothing to seat, and nothing is retired either - a tmux server that is not answering is not the same fact as a box with no agents"
    _spl_desk_up_all_no_window "$d" "$tenant" "$box" "$dry"
    return 1
  fi
  do_log "INFO live agent windows: ${live[*]}"

  local a skip=" ${DESK_SKIP:-} " mute=" ${DESK_MUTE:-} " only="${DESK_SEATED_ONLY:-0}"
  [[ "$only" == 0 || "$only" == 1 ]] || { do_log "FATAL DESK_SEATED_ONLY must be 0 or 1, got: '$only'"; return 1; }
  for a in "${live[@]}"; do
    [[ "$skip" == *" $a "* ]] && { do_log "INFO skipping $a (DESK_SKIP)"; continue; }
    [[ "$only" == 1 && ! -d "$d/spool/$a" ]] && continue
    seat+=("$a")
  done
  if [[ "$only" == 1 && ${#seat[@]} -eq 0 ]]; then
    do_log "OK no live agent is seated on $box in $tenant: its sidecar has nobody to serve (DESK_SEATED_ONLY)"
    return 0
  fi

  local -a dead=()
  mapfile -t dead < <(spl_desk_dead_agents "$d" "${live[@]}")

  if (( dry )); then
    _spl_desk_up_all_dry_plan "$tenant" "$box" "$retire" "$hubcheck" "${#seat[@]}" "${seat[*]:-none}" "${#dead[@]}" "${dead[*]:-none}"
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
    # A seated-only pass never un-mutes: the seat was chosen by hand.
    [[ "$only" == 1 && -e "$d/spool/$a/.no-poke" ]] && apoke=0
    if TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="$a" DESK_POKE="$apoke" \
       DESK_WAIT_SECS="${DESK_WAIT_SECS:-30}" DRY_RUN=0 do_spl_desk_up; then
      seated+=("$a")
    else
      failed+=("$a"); do_log "FAIL could not seat $a on $box"
    fi
  done

  # SECOND PASS over the ones that failed (_spl_desk_up_all_recheck).
  _spl_desk_up_all_recheck "$d" "$box"

  if [[ "$retire" == 1 ]]; then
    for a in "${dead[@]}"; do
      spl_desk_retire "$d" "$a" && retired+=("$a")
    done
  fi

  local hub="skipped" hrc=0
  if [[ "$hubcheck" == 1 ]]; then _spl_desk_up_all_hub "$d" "$tenant" "$box" "$poke" "$mute"; fi

  flock -u 8; exec 8>&-
  _spl_desk_up_all_report "$tenant" "$box" "$d" "${#live[@]}" "${#seat[@]}" "$hub" "$hrc"
}

# _spl_desk_up_all_no_window <state dir> <tenant> <box> <dry>: with NO live
# agent window, still bring the box's hub-run sidecar up. Measured on sat
# 2026-10-09 (drill 3): the box booted at 03:44:43Z and its prd sidecar first
# started at 04:06:03Z, because seating waited for an agent window; for those
# 21 min no remote message reached the box. The sidecar serves the box, not a
# window, so it starts on the first cron tick after the box is up.
# Same set as do_spl_desk_up_boxes: a desk whose sidecar was started and not
# stopped (pid file; do_spl_desk_down removes it), with an agent dir, not moved
# away by do_spl_desk_rebox. A live sidecar on the current binary is left
# alone (no second one); a dead or stale one is restarted through
# spl_desk_box_restart, which seats the desk's first agent dir and keeps its
# hand mute. Nothing is retired: that still needs a live window to compare.
_spl_desk_up_all_no_window() {
  local d="$1" tenant="$2" box="$3" dry="$4" agent why
  [[ -e "$d/spool/.hub/hub-run.pid" ]] || { do_log "INFO no sidecar was started for $box in $tenant, or it was stopped: none is started"; return 0; }
  [[ -e "$d/rebox-seated.txt" || -d "$d/rebox-retired" ]] && return 0
  agent="$(spl_desk_box_agents "$d" | sed -n 1p)"
  [[ -n "$agent" ]] || { do_log "INFO $box in $tenant has no agent dir: its sidecar would announce nobody"; return 0; }
  why="$(spl_desk_box_state "$d")"
  if [[ "$why" == up ]]; then
    do_log "INFO the hub-run sidecar of $box in $tenant is already live with no agent window: no second one"
    return 0
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: start the hub-run sidecar of $box in $tenant ($why) with no agent window, by seating $agent"
    return 0
  fi
  if spl_desk_box_restart "$d" "$tenant" "$box" "$agent"; then
    do_log "INFO started the hub-run sidecar of $box in $tenant ($why) with no agent window, by seating $agent"
  else
    do_log "FAIL could not start the hub-run sidecar of $box in $tenant ($why): see $d/spool/.hub/hub-run.log"
  fi
  return 0
}

# _spl_desk_up_all_check_args <tenant> <box> <retire> <hubcheck>: 0 when the
# reconcile's inputs are sane, else the FATAL that names the bad one.
_spl_desk_up_all_check_args() {
  local tenant="$1" box="$2" retire="$3" hubcheck="$4"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ "$retire" == 0 || "$retire" == 1 ]] || { do_log "FATAL DESK_RETIRE must be 0 or 1, got: '$retire'"; return 1; }
  [[ "$hubcheck" == 0 || "$hubcheck" == 1 ]] || { do_log "FATAL DESK_HUB_CHECK must be 0 or 1, got: '$hubcheck'"; return 1; }
}
# _spl_desk_up_all_hub <state dir> <tenant> <box> <poke> <mute list>: the HUB's
# side of the seat. Everything before it is local: a live pid and the roster
# cache the sidecar wrote at its last welcome. A sidecar whose socket sits on a
# hub process that no longer serves (a redeploy) passes all of it. Sets the
# caller's hub (SPL_DESK_HUB) and hrc; reads its seated[]. No seat, no check.
_spl_desk_up_all_hub() {
  local d="$1" tenant="$2" box="$3" poke="$4" mute="$5" ha="" a2
  [[ ${#seated[@]} -gt 0 ]] || return 0
  # Measure with a seat that takes the poke, so the restart below does not
  # re-seat a DESK_MUTE agent with its prompt switched back on.
  for a2 in "${seated[@]}"; do [[ "$mute" == *" $a2 "* ]] || { ha="$a2"; break; }; done
  local hpoke="$poke"
  [[ -z "$ha" ]] && { ha="${seated[0]}"; hpoke=0; }
  SPL_DESK_HUB="skipped"
  spl_desk_heal_stranded "$d" "$tenant" "$box" "$ha" "$hpoke" || hrc=$?
  hub="$SPL_DESK_HUB"
}

# _spl_desk_up_all_dry_plan <tenant> <box> <retire> <hubcheck> <n seat>
# <seat list> <n dead> <dead list>: what a DRY_RUN=1 reconcile would do.
_spl_desk_up_all_dry_plan() {
  local tenant="$1" box="$2" retire="$3" hubcheck="$4" nseat="$5" seat_list="$6" ndead="$7" dead_list="$8"
  do_log "INFO DRY_RUN would: seat $nseat agent(s) on $box in $tenant: $seat_list"
  [[ -n "${DESK_MUTE:-}" ]] && do_log "INFO DRY_RUN would: seat these with the prompt left alone (DESK_MUTE): ${DESK_MUTE}"
  if [[ "$retire" == 1 ]]; then
    do_log "INFO DRY_RUN would: retire $ndead agent(s) whose window is gone: $dead_list"
  else
    do_log "INFO DRY_RUN would NOT retire (DESK_RETIRE=0); $ndead agent(s) have no window: $dead_list"
  fi
  [[ "$hubcheck" == 1 ]] && do_log "INFO DRY_RUN would: ask the hub whether $box has a session, and restart its sidecar if it is stranded"
  do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
}

# _spl_desk_up_all_recheck <state dir> <box>: the second roster read for the
# caller's failed[] agents; moves the ones now announced into its seated[]
# (both arrays are do_spl_desk_up_all's locals, read and written in place).
_spl_desk_up_all_recheck() {
  local d="$1" box="$2" a
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
}

# _spl_desk_up_all_report <tenant> <box> <state dir> <n live> <n seat> <hub>
# <hub rc>: the JSON summary line and the verdict over the caller's seated[],
# retired[] and failed[] (do_spl_desk_up_all's locals); 1 on any failure.
_spl_desk_up_all_report() {
  local tenant="$1" box="$2" d="$3" nlive="$4" nseat="$5" hub="$6" hrc="$7"
  python3 - "$ENV" "$tenant" "$box" "$d" "$nlive" "${seated[*]:-}" "${retired[*]:-}" "${failed[*]:-}" "$hub" <<'EOF_PY'
import json, sys
env, tenant, box, state, nlive, seated, retired, failed, hub = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "box": box, "state_dir": state,
                  "live_agents": int(nlive), "seated": seated.split(),
                  "retired": retired.split(), "failed": failed.split(),
                  "hub_session": hub}, sort_keys=True))
EOF_PY
  if [[ ${#failed[@]} -gt 0 ]]; then
    do_log "FAIL ${#failed[@]} of $nseat agent(s) were not seated on $box: ${failed[*]}"
    return 1
  fi
  if (( hrc )); then
    do_log "FAIL $box was stranded and the restart did not bring its hub session back: see $d/spool/.hub/hub-run.log"
    return 1
  fi
  if [[ ${#retired[@]} -gt 0 ]]; then
    do_log "OK ${#seated[@]} agent(s) seated on $box in $tenant ($ENV), ${#retired[@]} retired: ${retired[*]}"
  else
    do_log "OK ${#seated[@]} agent(s) seated on $box in $tenant ($ENV), none retired"
  fi
}

# spl_desk_heal_stranded <state dir> <tenant> <box> <agent> <agent poke>: read
# the hub's roster and, when the box's sidecar is alive but the hub says the box
# is OFFLINE (do_spl_desk_check's `stranded`), restart the sidecar: down, then
# do_spl_desk_up for <agent>, whose hello drains what the hub queued meanwhile.
# Sets SPL_DESK_HUB to online | stranded-repaired | stranded-repair-failed |
# skipped | <other verdict>. Returns 1 only when a repair was needed and failed.
#
# Only `stranded` is acted on: down is what seating just fixed, and unpinned or
# agent-missing are not things a restart fixes (spl_desk_repair says the same).
# A roster read that fails repairs NOTHING - restarting 13 seats because the
# member login hit a 429 would be a self-inflicted outage.
spl_desk_heal_stranded() {
  local d="$1" tenant="$2" box="$3" agent="$4" apoke="$5" roster rrc=0 verdict v
  SPL_DESK_HUB="skipped"
  spl_desk_alive "$d/spool/.hub/hub-run.pid" || { do_log "WARN hub-side check of $box skipped: no live sidecar after seating"; return 0; }
  roster="$(spl_desk_roster "$tenant" 2>&1)" || rrc=$?
  if (( rrc )); then
    do_log "WARN hub-side check of $box skipped: the roster read failed (exit $rrc): $(printf '%s' "${roster:-<nothing>}" | tail -n 1)"
    return 0
  fi
  verdict="$(spl_desk_verdict "$roster" "$box" "$agent" 1)" || { do_log "WARN hub-side check of $box skipped: the roster is not JSON"; return 0; }
  v="${verdict%%$'\t'*}"
  case "$v" in
    ok|muted) SPL_DESK_HUB="online"; do_log "INFO the hub has a session for $box in $tenant"; return 0 ;;
    stranded) ;;
    *) SPL_DESK_HUB="$v"; do_log "WARN hub-side check of $box: '$v' - not something a sidecar restart fixes"; return 0 ;;
  esac
  do_log "FAIL $box is STRANDED in $tenant ($ENV): its sidecar is alive and the hub says the box is OFFLINE, so messages the hub accepts reach nobody here. Restarting the sidecar."
  if TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="" DRY_RUN=0 do_spl_desk_down &&
     TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="$agent" DESK_POKE="$apoke" \
       DESK_WAIT_SECS="${DESK_WAIT_SECS:-30}" DRY_RUN=0 do_spl_desk_up; then
    SPL_DESK_HUB="stranded-repaired"
    do_log "OK repaired a stranded $box: a fresh sidecar re-helloed, and that hello drains what the hub queued for the box"
    return 0
  fi
  SPL_DESK_HUB="stranded-repair-failed"
  return 1
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
    # Plus every agent the identity map proves alive by its PROCESS: a window
    # whose name a sort or a restore moved onto a neighbour must not cost the
    # real agent its seat (2026-10-01 04:37Z: CLE-77798 retired while running,
    # its window labelled with another id).
    if [ -r "$feat/lib/agent-identity.inc.sh" ]; then
      # shellcheck disable=SC1091
      . "$feat/lib/agent-identity.inc.sh" && ai_live_ids
    fi
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
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for e in "$root"/*; do
    [[ -d "$e" ]] || continue
    a="$(basename "$e")"
    [[ "$a" =~ ^${SPOOL_PARTICIPANT_RX}$ && "${a%%-*}" != BOX ]] || continue
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
