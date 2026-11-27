#!/bin/bash
#------------------------------------------------------------------------------
# @description One check of the laptop box (SPL-6680, spec 037 "Laptop box"),
# @description run every 5 min as the agents' user by the system timer
# @description spl-laptop-box-tick.timer that do_spl_laptop_box_install sets.
# @description It reads her hours and the cap (dispatch/laptop-box.env) and
# @description the markers her controls write (spl-laptop-box, the state dir
# @description dispatch/laptop-box), then does ONE of:
# @description   in her hours, not off, not stopped today: the box takes agents
# @description     (do_spl_box_join when the box.leave marker is there); any
# @description     question left from yesterday is cleared;
# @description   at the cap (AGENT_MAX lanes or more): the box.leave marker, so
# @description     spawn-window.sh takes no more lanes here (exit 6);
# @description   outside her hours (or off / stopped): the box.leave marker,
# @description     then with lanes still running:
# @description     - she asked to continue (continue-until in the future): wait;
# @description     - she clicked Stop, ran stop / off, or left the question 15
# @description       min (LAPTOP_ASK_WAIT_MIN) unanswered: every lane moves to
# @description       the fleet box LAPTOP_MOVE_BOX (do_spl_lane_handover, its
# @description       work pushed to a wip/handover ref, its session resumed
# @description       there), one line per lane in moves.log;
# @description     - else the question: ask-pending (the lanes, the two
# @description       choices) and asked-at; LAPTOP_ASK=wui (default) posts it
# @description       as a poll form in LAPTOP_ASK_CHANNEL tagging her and reads
# @description       her answer back each tick; dsk leaves it to her pop-up.
# @description Writes the live lanes to the state dir's lanes file (her status
# @description and remove read it). Prints one TICK line.
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param LAPTOP_ENV_FILE (optional) - her config, default /etc/spl-laptop-box/laptop-box.env (root's)
# @param LAPTOP_STATE_DIR (optional) - default <spool root>/dispatch/laptop-box
# @param LAPTOP_ASK_WAIT_MIN (optional) - minutes the question waits for her, default 15
# @param LAPTOP_NOW / LAPTOP_LANES_CMD / LAPTOP_JOIN_CMD / LAPTOP_HANDOVER_CMD / LAPTOP_SPOOL_CMD (tests) - the clock (epoch), the lane lister, the box join, the lane handover, the spool CLI
# @example ./run -a do_spl_laptop_box_tick
#------------------------------------------------------------------------------
do_spl_laptop_box_tick() {
  local sr="${SPOOL_ROOT:-/var/spool-hub}" d envf hours max to now lanes n mark
  envf="${LAPTOP_ENV_FILE:-/etc/spl-laptop-box/laptop-box.env}"; d="${LAPTOP_STATE_DIR:-$sr/dispatch/laptop-box}"; mark="$sr/dispatch/box.leave"
  [[ -r "$envf" ]] || { do_log "FATAL $envf is missing: not a laptop box (run do_spl_laptop_box_install)"; return 3; }
  hours="$(spl_laptop_env_get "$envf" LAPTOP_HOURS)"; max="$(spl_laptop_env_get "$envf" LAPTOP_AGENT_MAX)"
  to="$(spl_laptop_env_get "$envf" LAPTOP_MOVE_BOX)"
  spl_laptop_hours_parse "$hours" >/dev/null || { do_log "FATAL LAPTOP_HOURS in $envf is not a window: '$hours'"; return 3; }
  mkdir -p "$d" || return 1
  now="${LAPTOP_NOW:-$(date +%s)}"
  [[ "$(spl_laptop_env_get "$envf" LAPTOP_ASK)" == dsk ]] || spl_laptop_ask_wui_read "$d" "$now"
  spl_laptop_tick_answer "$d" "$now"
  lanes="$(${LAPTOP_LANES_CMD:-spl_laptop_tick_lanes})"; printf '%s' "${lanes:+$lanes$'\n'}" >"$d/lanes"
  n="$(grep -c . "$d/lanes")"
  if spl_laptop_tick_on "$d" "$hours" "$now"; then
    rm -f "$d/asked-at" "$d/ask-pending" "$d/ask-wui" "$d/continue-until" "$d/move-now"
    if (( n >= ${max:-4} )); then
      [[ -e "$mark" ]] || echo "laptop box: at its cap of ${max:-4} agents" >"$mark"
      echo "TICK in-hours lanes=$n cap=${max:-4}: full, no new lanes"; return 0
    fi
    [[ ! -e "$mark" ]] || ${LAPTOP_JOIN_CMD:-do_spl_box_join} >/dev/null || { do_log "FATAL do_spl_box_join failed"; return 1; }
    echo "TICK in-hours lanes=$n cap=${max:-4}: takes lanes"; return 0
  fi
  [[ -e "$mark" ]] || echo "laptop box: outside its hours ($hours)" >"$mark"
  spl_laptop_tick_out "$d" "$now" "$n" "$to" "$envf"
}

# spl_laptop_tick_on <state dir> <hours> <epoch>: the box works now.
spl_laptop_tick_on() {
  [[ ! -e "$1/off" ]] || return 1
  [[ "$(cat "$1/stopped" 2>/dev/null)" != "$(date -d "@$3" +%F)" ]] || return 1
  spl_laptop_in_hours "$2" "$3"
}

# spl_laptop_tick_answer <state dir> <epoch>: her pop-up click, once.
spl_laptop_tick_answer() {
  local a; a="$(awk '{print $1; exit}' "$1/answer" 2>/dev/null)"
  case "$a" in
    continue) echo "$(( $2 + 3600 ))" >"$1/continue-until"; rm -f "$1/asked-at" "$1/ask-pending" "$1/ask-wui" ;;
    stop) echo "$2" >"$1/move-now"; rm -f "$1/continue-until" ;;
  esac
  rm -f "$1/answer"
}

# spl_laptop_tick_out <state dir> <epoch> <lanes> <move box> <env file>:
# outside her hours.
spl_laptop_tick_out() {
  local d="$1" now="$2" n="$3" to="$4" envf="$5" at cu wait=$(( ${LAPTOP_ASK_WAIT_MIN:-15} * 60 ))
  if (( n == 0 )); then rm -f "$d/asked-at" "$d/ask-pending" "$d/ask-wui" "$d/move-now"; echo "TICK out lanes=0: idle"; return 0; fi
  cu="$(cat "$d/continue-until" 2>/dev/null)"; at="$(cat "$d/asked-at" 2>/dev/null)"
  if [[ ! -e "$d/move-now" && "$cu" =~ ^[0-9]+$ ]] && (( cu > now )); then
    echo "TICK out lanes=$n: she continues until $(date -d "@$cu" +%H:%M)"; return 0
  fi
  if [[ -e "$d/move-now" ]] || { [[ "$at" =~ ^[0-9]+$ ]] && (( now - at >= wait )); }; then
    spl_laptop_tick_move "$d" "$to"; return
  fi
  if [[ ! "$at" =~ ^[0-9]+$ ]]; then
    { echo "$n fleet agent(s) still work on this laptop:"; sed 's/^/  /' "$d/lanes"
      echo "Continue 1 h, or Stop: they move to the fleet with their work."
      echo "No answer in ${LAPTOP_ASK_WAIT_MIN:-15} min: they move."; } >"$d/ask-pending"
    echo "$now" >"$d/asked-at"; rm -f "$d/continue-until" "$d/ask-wui"
    local how=desktop
    if [[ "$(spl_laptop_env_get "$envf" LAPTOP_ASK)" != dsk ]]; then how=wui; spl_laptop_ask_wui_post "$d" "$envf" || how="wui NOT posted"; fi
    echo "TICK out lanes=$n: asked her ($how)"; return 0
  fi
  echo "TICK out lanes=$n: waiting for her answer"
}

# spl_laptop_tick_move <state dir> <move box>: every lane to the fleet box.
spl_laptop_tick_move() {
  local d="$1" to="$2" id bad=0
  spl_laptop_box_tag_ok "$to" || { do_log "FATAL LAPTOP_MOVE_BOX is not a box tag: '$to'"; return 3; }
  while read -r id; do
    [[ -n "$id" ]] || continue
    if FROM="$id" TO_BOX="$to" DRY_RUN=0 ${LAPTOP_HANDOVER_CMD:-do_spl_lane_handover} >>"$d/moves.log" 2>&1; then
      echo "$(date -u +%FT%TZ) moved $id -> $to" >>"$d/moves.log"
    else
      echo "$(date -u +%FT%TZ) FAILED $id -> $to" >>"$d/moves.log"; bad=$((bad + 1))
    fi
  done <"$d/lanes"
  rm -f "$d/asked-at" "$d/ask-pending" "$d/ask-wui" "$d/move-now"
  (( bad == 0 )) || { echo "TICK out: $bad lane(s) did not move to $to (moves.log); the next tick retries"; date +%s >"$d/move-now"; return 1; }
  echo "TICK out: lanes moved to $to"
}

# spl_laptop_tick_lanes: the live lane agents of this box (do_spl_box_leave's
# own lister: a live process, a registry row, its pane alive on this tmux).
spl_laptop_tick_lanes() {
  _spl_box_leave_deps 2>/dev/null || true
  spl_box_init >/dev/null 2>&1 || true
  spl_box_lanes
}

# The WUI way to ask her (5a = WUI, form 3d4ecf66; the switch LAPTOP_ASK in
# laptop-box.env: wui, the default, or dsk for the desktop pop-up). The box
# posts the question as a new topic in LAPTOP_ASK_CHANNEL, as its desk agent
# LAPTOP_ASK_FROM, tagging her (LAPTOP_ASK_HUM): a poll form, Continue 1 h
# (CON) or Stop (STP); how-to-post.md section 7. Her answer is a reply in
# that topic, "Poll: <msg id>" + "Answer: CON|STP", read back on each tick.

# spl_laptop_ask_spool <spool args>: `spool` as this box's desk, in hub mode
# (spl_desk_spool: the desk's keys, box id, tenant and the hub URL of the
# fleet env in box.env), as every desk-backed action calls it; a bare `spool`
# under the tick's SPOOL_ROOT has no hub and fails. The binary: the one
# install.sh put on PATH. LAPTOP_SPOOL_CMD (tests) replaces all of it.
spl_laptop_ask_spool() {
  if [[ -n "${LAPTOP_SPOOL_CMD:-}" ]]; then "$LAPTOP_SPOOL_CMD" "$@"; return; fi
  local be="${SPOOL_ROOT:-/var/spool-hub}/box.env" env ten box d SPL_SPOOL
  env="$(spl_laptop_env_get "$be" SPOOL_FLEET_ENV)"; ten="$(spl_laptop_env_get "$be" SPOOL_FLEET_TENANT)"
  box="$(spl_laptop_env_get "$be" SPOOL_DESK_BOX)"
  [[ -n "$env" && -n "$ten" && -n "$box" ]] || { echo "no SPOOL_FLEET_ENV / SPOOL_FLEET_TENANT / SPOOL_DESK_BOX in $be: no hub desk" >&2; return 1; }
  ENV="$env" TENANT_ID="$ten" do_spl_desk_cnf >&2 || return 1
  d="$(ENV="$env" spl_desk_dir "$ten" "$box" "$env")" && [[ -d "$d/spool" ]] || { echo "no desk $box of $ten seated on this box (do_spl_desk_up)" >&2; return 1; }
  # shellcheck disable=SC2034  # read by spl_desk_spool (bash dynamic scope)
  SPL_SPOOL="$(command -v spool || echo "$HOME/.local/bin/spool")"
  spl_desk_spool "$d" "$box" "$ten" "$SPL_HUB_URL" -- "$@"
}

# spl_laptop_ask_wui_post <state dir> <env file>: post the form, keep its ids.
spl_laptop_ask_wui_post() {
  local d="$1" envf="$2" ch from hum out mid tid body
  ch="$(spl_laptop_env_get "$envf" LAPTOP_ASK_CHANNEL)"; from="$(spl_laptop_env_get "$envf" LAPTOP_ASK_FROM)"
  hum="$(spl_laptop_env_get "$envf" LAPTOP_ASK_HUM)"
  [[ -n "$ch" && -n "$from" && "$hum" =~ ^HUM-[0-9]+$ ]] || { do_log "WARN LAPTOP_ASK=wui needs LAPTOP_ASK_CHANNEL, LAPTOP_ASK_FROM and LAPTOP_ASK_HUM in $envf: not asked; the lanes move after the wait"; return 1; }
  body="@$hum $(cat "$d/ask-pending")"$'\n\n```poll\nKeep the fleet agents on your laptop?\n(CON) Continue 1 h\n(STP) Stop\n```'
  out="$(spl_laptop_ask_spool send --channel "$ch" --from "$from" --kind question --body "$body" 2>&1)" || { do_log "WARN the WUI question was not posted: $out"; return 1; }
  mid="$(jq -r '.msg_id // empty' <<<"$out" 2>/dev/null)"; tid="$(jq -r '.task_id // empty' <<<"$out" 2>/dev/null)"
  [[ -n "$mid" && -n "$tid" ]] || { do_log "WARN the WUI question's ids are not in the send answer: $out"; return 1; }
  printf '%s %s %s\n' "$mid" "$tid" "$hum" >"$d/ask-wui"
}

# spl_laptop_ask_wui_read <state dir> <epoch>: her newest answer to the form
# in its topic (only HER replies count) -> the answer file the tick reads.
spl_laptop_ask_wui_read() {
  local d="$1" now="$2" mid tid hum k
  [[ -s "$d/ask-wui" && ! -e "$d/answer" ]] || return 0
  read -r mid tid hum <"$d/ask-wui"
  k="$(spl_laptop_ask_spool hub-tail --task "$tid" --json 2>/dev/null |
    jq -rs --arg m "$mid" --arg h "$hum" '[.[] | select(.from == $h) | .body // ""
      | select(test("(^|\\n)Poll: " + $m)) | capture("(^|\\n)Answer: (?<k>[A-Z]+)").k] | last // empty' 2>/dev/null)"
  case "$k" in
    CON) echo "continue $now" >"$d/answer" ;;
    STP) echo "stop $now" >"$d/answer" ;;
  esac
}
