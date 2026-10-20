#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 12 (rel-12, SPL-2669, Refs: SPL-2364):
# @description box beat and watchdog fence early-warning telemetry. The
# @description watchdog (csi-spl-orc spl-watchdog.func.sh, spec 102 10.2)
# @description beats the hub every tick and keeps the epoch of the last ack
# @description in <WD_DIR>/beat.ack; with no ack for box_down_min (2 min) it
# @description fences the box. On 2026-10-16 03:41Z a box fenced after 2m48s
# @description of silence, and nothing counted the silences that came close.
# @description This check reads beat.ack (and beat.down_min, fenced, held),
# @description never writes the watchdog's files, and prints one line:
# @description   box-beat <STATE> ack_age_s=<n> ack=<epoch> step_s=<n|?>
# @description     near_s=<n> fence_s=<n> wd=<fenced|held|ok> near_today=<n>
# @description     fenced_today=<n> ms=<n>
# @description   OK         ack age < near_s
# @description   NEAR       ack age >= near_s (default 50% of fence_s: 60 s)
# @description   FENCE      ack age >= fence_s (box_down_min * 60)
# @description   RECONNECT  an ack again after a NEAR / FENCE silence
# @description   NOBEAT     no beat.ack: this box does not beat a hub
# @description   ERROR      beat.ack holds no epoch
# @description step_s is the time between the ack the previous recorded run
# @description saw and this one's (the beat cycle as the check sees it). The
# @description watchdog keeps no round-trip time of its beat call, so the
# @description ack age is the latency this check can measure.
# @description A silence is counted once (near_today, fenced_today, UTC day)
# @description when a run first sees it; the RECONNECT run sends ONE spool
# @description note to the orchestrator with the silence bounds: at least the
# @description largest age a run saw, at most new ack - last ack before it.
# @description No note while the box is silent: the hub cannot be reached
# @description then, and the watchdog's own fence note covers a fence.
# @description Sampling: from a 1 min cron every silence >= near_s + 60 s is
# @description seen; a shorter one is seen only when a run falls inside it.
# @description
# @description TELEMETRY ONLY: it never commits, pushes, kills, restarts or
# @description edits the watchdog. With DRY_RUN=1 (default) it reads and
# @description prints only (the note is a PLAN line); DRY_RUN=0 keeps its own
# @description state (<state dir>/state, events.tsv, samples.tsv) and sends.
# @description A failed send keeps pending-note, so the next run retries.
# @description Exit 0 OK / NOBEAT, 1 NEAR / FENCE / RECONNECT / ERROR, 2 usage.
# @param BOX_BEAT_WD_DIR (optional) - the watchdog dir; default WD_STATE_DIR,
# @param   else ${SPOOL_ROOT:-/var/spool-hub}/dispatch/wd (as the watchdog)
# @param BOX_BEAT_DOWN_MIN (optional) - fence minutes; default WD_BOX_DOWN_MIN,
# @param   else <WD_DIR>/beat.down_min (the hub's), else 2 (as the watchdog)
# @param BOX_BEAT_NEAR_S (optional) - near-fence age; default fence_s / 2
# @param BOX_BEAT_STATE_DIR (optional) - default <SPL_STATE_DIR or
# @param   $HOME/.local/state/csi-spl>/box-beat
# @param BOX_BEAT_KEEP_SAMPLES (optional) - samples.tsv lines kept, default 1440
# @param BOX_BEAT_SEND_CMD (optional) - the sender, called with
# @param   --from <id> --to <id> --kind note --task <task> --no-poke --body <text>;
# @param   default bash <repo>/csi-spl-orc/.../spawn-agents/scripts/spool-send.sh
# @param BOX_BEAT_SEND_TIMEOUT (optional) - seconds for the sender, default 20
# @param BOX_BEAT_ALERT_TO / _FROM / _TASK (optional) - default orchestrator /
# @param   $SPOOL_AGENT_ID or box-beat-telemetry@<box> / box-beat
# @param BOX_BEAT_NOW (optional) - epoch seconds override (tests)
# @param DRY_RUN (optional) - 1 (default) reads and prints; 0 records and sends
# @example ./run -a do_box_beat_telemetry_check
# @example DRY_RUN=0 ./run -a do_box_beat_telemetry_check
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

do_box_beat_telemetry_check() {
  local dry="${DRY_RUN:-1}" t0 ms now wd ack="" age=0 step="?" down near fence state wdst=ok
  local dir last_ack="" open_ack="" open_max=0 open_kind="" ev="" body="" lo hi
  local near_today=0 fenced_today=0
  t0="$(box_beat_ms)"
  now="${BOX_BEAT_NOW:-${EPOCHSECONDS:-$(date +%s)}}"
  wd="$(box_beat_wd_dir)"
  dir="$(box_beat_dir)"
  down="${BOX_BEAT_DOWN_MIN:-${WD_BOX_DOWN_MIN:-}}"
  [[ -z "$down" && -f "$wd/beat.down_min" ]] && read -r down <"$wd/beat.down_min"
  if ! [[ "$down" =~ ^[0-9]+$ ]] || ((down < 1)); then down=2; fi
  fence=$((down * 60))
  near="${BOX_BEAT_NEAR_S:-$((fence / 2))}"
  if ! [[ "$near" =~ ^[0-9]+$ ]] || ((near < 1)); then
    do_log "FATAL BOX_BEAT_NEAR_S must be a whole number >= 1, got: '$near'"
    return 2
  fi

  if [[ ! -e "$wd/beat.ack" ]]; then
    do_log "INFO box-beat NOBEAT no $wd/beat.ack: this box does not beat a hub (or its watchdog has not run) ms=$(($(box_beat_ms) - t0))"
    return 0
  fi
  read -r ack <"$wd/beat.ack" 2>/dev/null
  if ! [[ "$ack" =~ ^[0-9]+$ ]]; then
    do_log "INFO box-beat ERROR $wd/beat.ack holds no epoch ('${ack:0:40}') ms=$(($(box_beat_ms) - t0))"
    return 1
  fi
  age=$((now - ack))
  ((age < 0)) && age=0
  [[ -e "$wd/held" ]] && wdst=held
  [[ -e "$wd/fenced" ]] && wdst=fenced

  [[ -f "$dir/state" ]] && read -r last_ack open_ack open_max open_kind <"$dir/state"
  [[ "$last_ack" =~ ^[0-9]+$ ]] && ((ack > last_ack)) && step=$((ack - last_ack))
  [[ "$open_ack" =~ ^[0-9]+$ ]] || open_ack="" open_kind=""
  [[ "$open_max" =~ ^[0-9]+$ ]] || open_max=0

  if ((age >= near)); then
    state=NEAR
    ((age >= fence)) && state=FENCE
    if [[ "$open_ack" != "$ack" ]]; then
      # an ack between two runs ended the last silence unseen: its note
      # still goes (queued, sent when the hub answers), and a new one opens
      if [[ -n "$open_ack" ]]; then
        hi=$((ack - open_ack))
        ((hi < open_max)) && hi="$open_max"
        ev+="$now reconnect $open_ack $hi"$'\n'
        body="$(box_beat_body "$open_kind" "$open_max" "$hi" "$open_ack" "$ack" "$near" "$fence")"
      fi
      open_ack="$ack" open_max=0 open_kind=""
    fi
    if [[ -z "$open_kind" ]]; then ev+="$now near $ack $age"$'\n'; open_kind=NEAR; fi
    if [[ "$state" == FENCE && "$open_kind" != FENCE ]]; then ev+="$now fence $ack $age"$'\n'; open_kind=FENCE; fi
    ((age > open_max)) && open_max="$age"
  elif [[ -n "$open_ack" ]]; then
    state=RECONNECT
    lo="$open_max" hi=$((ack - open_ack))
    ((hi < lo)) && hi="$lo"
    ev+="$now reconnect $open_ack $hi"$'\n'
    body="$(box_beat_body "$open_kind" "$lo" "$hi" "$open_ack" "$ack" "$near" "$fence")"
    open_ack="" open_max=0 open_kind=""
  else
    state=OK
  fi

  read -r near_today fenced_today < <(box_beat_today "$now" "$dir/events.tsv" "$ev")
  [[ -n "$body" ]] && body+=" Near-fences today (UTC): $near_today, fences: $fenced_today."
  ms=$(($(box_beat_ms) - t0))

  do_log "INFO box-beat $state ack_age_s=$age ack=$ack step_s=$step near_s=$near fence_s=$fence wd=$wdst near_today=$near_today fenced_today=$fenced_today ms=$ms"
  [[ "$state" == NEAR || "$state" == FENCE ]] &&
    do_log "WARN box-beat $state: no beat ack for ${age}s (near-fence at ${near}s, the watchdog fences at ${fence}s)"
  if [[ "$dry" == 0 ]]; then
    box_beat_record "$now" "$ack" "$age" "$step" "$open_ack" "$open_max" "$open_kind" "$ev" "$body"
  fi
  box_beat_send "$dry" "$body"
  [[ "$state" == OK ]] && return 0
  return 1
}

# box_beat_today <now> <events.tsv> <this run's events> - "<near> <fence>":
# the silences counted on the UTC day of <now>
box_beat_today() {
  local day d k n=0 f=0
  TZ=UTC printf -v day '%(%F)T' "$1"
  while read -r d k _; do
    [[ "$d" =~ ^[0-9]+$ ]] || continue
    TZ=UTC printf -v d '%(%F)T' "$d"
    [[ "$d" == "$day" ]] || continue
    case "$k" in near) n=$((n + 1)) ;; fence) f=$((f + 1)) ;; esac
  done < <({ [[ -f "$2" ]] && cat "$2"; printf '%s' "$3"; } 2>/dev/null)
  echo "$n $f"
}

# box_beat_body <kind> <lo> <hi> <last ack> <new ack> <near> <fence> - the note
box_beat_body() {
  local box a b
  box="$(hostname -s 2>/dev/null)"
  TZ=UTC printf -v a '%(%FT%TZ)T' "$4"
  TZ=UTC printf -v b '%(%FT%TZ)T' "$5"
  printf 'box-beat RECONNECT on %s after a %s silence: no beat ack for %s..%s s (last ack %s, acked again by %s; near-fence at %s s, the watchdog fences at %s s).' \
    "${box:-?}" "${1:-NEAR}" "$2" "$3" "$a" "$b" "$6" "$7"
  printf ' Telemetry only: nothing was changed; a fence is handled by the watchdog itself (spec 102 10.2). Re-read: cd csi-spl-utl && ./run -a do_box_beat_telemetry_check'
}

# box_beat_record <now> <ack> <age> <step> <open ack> <open max> <open kind>
# <events> <body> - this check's own state, never the watchdog's (DRY_RUN=0)
box_beat_record() {
  local dir keep="${BOX_BEAT_KEEP_SAMPLES:-1440}" n=0
  dir="$(box_beat_dir)"
  mkdir -p "$dir" 2>/dev/null || { do_log "WARN cannot create $dir: nothing recorded"; return 0; }
  {
    echo "$2 ${5:--} ${6:-0} ${7:--}" >"$dir/state.$$" && mv -f "$dir/state.$$" "$dir/state"
    [[ -z "$8" ]] || printf '%s' "$8" >>"$dir/events.tsv"
    [[ -z "$9" ]] || printf '%s\n' "$9" >"$dir/pending-note"
    echo "$1 $2 $3 $4" >>"$dir/samples.tsv"
  } 2>/dev/null || do_log "WARN cannot write $dir: the telemetry state is not kept"
  # trimmed once an hour, so a 1 min cron forks nothing on the other runs
  if (($1 / 60 % 60 == 0)) && [[ "$keep" =~ ^[0-9]+$ ]]; then
    n="$(wc -l <"$dir/samples.tsv" 2>/dev/null)"
    if ((n > keep)); then
      tail -n "$keep" "$dir/samples.tsv" >"$dir/samples.tsv.$$" 2>/dev/null &&
        mv -f "$dir/samples.tsv.$$" "$dir/samples.tsv"
    fi
  fi
  return 0
}

# box_beat_send <dry> <this run's body> - a PLAN line (dry), else ONE send of
# the pending note (this run's, or one a failed send kept)
box_beat_send() {
  local dry="$1" body="$2" pending box from send_tmo="${BOX_BEAT_SEND_TIMEOUT:-20}"
  local to="${BOX_BEAT_ALERT_TO:-orchestrator}" task="${BOX_BEAT_ALERT_TASK:-box-beat}"
  local -a send
  pending="$(box_beat_dir)/pending-note"
  if [[ "$dry" != 0 ]]; then
    [[ -z "$body" && -s "$pending" ]] && body="$(<"$pending")"
    [[ -n "$body" ]] && do_log "INFO PLAN note to $to on task $task: $body"
    return 0
  fi
  [[ -s "$pending" ]] || return 0
  body="$(<"$pending")"
  box="$(hostname -s 2>/dev/null)"
  from="${BOX_BEAT_ALERT_FROM:-${SPOOL_AGENT_ID:-box-beat-telemetry@$box}}"
  read -ra send <<<"${BOX_BEAT_SEND_CMD:-}"
  if ! ((${#send[@]})); then
    send=(bash "${PROJ_PATH:-.}/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh")
    [[ -f "${send[1]}" ]] || { do_log "WARN no spool-send.sh at ${send[1]}: note kept in $pending"; return 0; }
  fi
  if timeout -k 2 "$send_tmo" "${send[@]}" --from "$from" --to "$to" --kind note --task "$task" \
    --no-poke --body "$body" >/dev/null 2>&1; then
    rm -f "$pending"
    do_log "INFO box-beat RECONNECT note sent to $to"
  else
    do_log "WARN box-beat: the note to $to failed; kept in $pending, the next run retries"
  fi
  return 0
}

# box_beat_wd_dir - the watchdog's dir, resolved as spl_wd_init does
box_beat_wd_dir() { echo "${BOX_BEAT_WD_DIR:-${WD_STATE_DIR:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/wd}}"; }

# box_beat_dir - this check's own state dir
box_beat_dir() { echo "${BOX_BEAT_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl}/box-beat}"; }

# box_beat_ms - a millisecond wall clock (no fork)
box_beat_ms() { local t="${EPOCHREALTIME/[.,]/}"; printf '%s' "$((10#$t / 1000))"; }

# do_box_beat_telemetry - the filename's own action name (same check)
do_box_beat_telemetry() { do_box_beat_telemetry_check "$@"; }

# The plan's action name is do_box_beat_telemetry_check, registered here when
# run.sh sources the file.
if declare -p _func_to_file &>/dev/null; then
  _func_to_file["do_box_beat_telemetry_check"]="${BASH_SOURCE[0]}"
fi
