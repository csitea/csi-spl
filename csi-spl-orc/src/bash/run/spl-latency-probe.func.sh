#!/bin/bash
#------------------------------------------------------------------------------
# @description Price every hop a WUI chat message crosses, on the LIVE path,
# @description so the 0.3 s budget can be spent where the time actually goes
# @description instead of where it is assumed to go (CLE-3435).
# @description
# @description It DMs a seated desk agent (do_spl_desk_up) from a scripted
# @description member session - the same login and socket m3-e2e.py uses - and
# @description subtracts stamps that the sidecar and the notifier wrote
# @description themselves into $SPOOL_TRACE. Probe, sidecar and notifier all
# @description run on THIS box, so every reading is one clock's arithmetic: no
# @description NTP skew, and the hub never has to agree about the time.
# @description
# @description Reported hops:
# @description   send -> hub ack            2 network legs + all of onSend
# @description   send -> frame on this box  the same, plus fan-out to the box
# @description   frame -> inbox file        verify + the mailbox write (002)
# @description   inbox file -> notifier     the handoff
# @description   notifier -> on screen      pane lookup + typing the line
# @description   DELIVERED AND VISIBLE      the owner's budget, end to end
# @description   visible -> notifier done   the TUI paste debounce, NOT
# @description                              visibility
# @description
# @description It also sends a burst with no gap between messages. That is the
# @description control for head-of-line blocking: while the terminal leg ran
# @description inside the sidecar's read loop, each message in a burst paid the
# @description previous one's poke before its own hop began, so the series rose
# @description with position. A flat series means it no longer does.
# @description
# @description The reply leg is NOT in this table. A reply is a model turn
# @description (~14 s), which is not a transport cost and must never be added
# @description to a delivery number.
# @description
# @description It sends real messages into the tenant, so it is a dry run
# @description unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param LAT_AGENT - required: the seated agent id to DM
# @param LAT_BOX (optional) - default box-desk, the value do_spl_desk_up used
# @param LAT_N (optional) - spaced single sends, default 12
# @param LAT_GAP (optional) - seconds between single sends, default 1.5
# @param LAT_BURST (optional) - back-to-back sends, default 4; 0 skips them
# @param LAT_HUMAN_EMAIL (optional) - the member that DMs; default the m3-e2e
# @param   member of this state dir. Its password file is 0600 and never printed
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 LAT_AGENT=CLE-00 DRY_RUN=0 ./run -a do_spl_latency_probe
#------------------------------------------------------------------------------
do_spl_latency_probe() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${LAT_BOX:-$(spl_desk_box_default)}" agent="${LAT_AGENT:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1

  local api_fqdn hub d
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  hub="https://$api_fqdn"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: sign a member in and DM $agent@$box on $hub ${LAT_N:-12} times, then price each hop from \$SPOOL_TRACE"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to measure."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  # The sidecar stamps the box-side hops, so it has to be the one running WITH
  # a trace. A desk seated without one cannot be measured by reading it: say
  # so and name the fix rather than reporting a table full of blanks.
  local trace="$d/spool/.hub/latency-trace.ndjson"
  spl_lat_sidecar_traces "$d" "$trace" || return 1

  local m3st="$SPL_STATE_DIR/m3-e2e/$tenant"
  mkdir -p "$m3st" && chmod 700 "$m3st" || return 1
  local orc="$APP_PATH/$SPL_ORG_APP-orc"
  local out="$d/latency-results.json" rc=0
  LAT_AGENT="$agent" LAT_BOX="$box" LAT_ROOT="$d/spool" LAT_TRACE="$trace" LAT_OUT="$out" \
  LAT_N="${LAT_N:-12}" LAT_GAP="${LAT_GAP:-1.5}" LAT_BURST="${LAT_BURST:-4}" \
  ENV="$ENV" TENANT_ID="$tenant" DRY_RUN=0 \
  M3_HUB_URL="$hub" M3_AUTH_URL="$hub" M3_TENANT="$tenant" M3_STATE="$m3st" M3_SPOOL="$SPL_SPOOL" \
  M3_HUMAN_EMAIL="${LAT_HUMAN_EMAIL:-m3-e2e-human@example.com}" \
    python3 "$orc/src/bash/scripts/latency-probe.py" || rc=$?
  (( rc == 0 )) || { do_log "FAIL the latency probe of $agent@$box in $tenant ($ENV) measured nothing: see $out"; return 1; }
  do_log "OK priced every hop of $agent@$box in $tenant ($ENV): $out"
}

# spl_lat_sidecar_traces <state dir> <trace file>: 0 when the desk's live
# `spool hub-run` is writing that trace file. A sidecar started without
# SPOOL_TRACE cannot be asked for its stamps after the fact - the env of a
# running process is fixed - so this refuses and names the one command that
# fixes it, rather than measuring a table of blanks.
spl_lat_sidecar_traces() {
  # NOT one `local`: a builtin's arguments are all expanded before it runs, so
  # `local d="$1" pidf="$d/..."` reads d BEFORE it is assigned - which under
  # `set -u` is an unbound-variable abort, not a quietly empty path.
  local d="$1" trace="$2"
  local pidf="$d/spool/.hub/hub-run.pid" pid seen
  pid="$(cat "$pidf" 2>/dev/null || true)"
  [[ -n "$pid" ]] && spl_desk_alive "$pidf" || {
    do_log "FATAL no live hub-run sidecar for this desk ($pidf): run do_spl_desk_up first"; return 1; }
  seen="$(spl_lat_proc_trace "$pid")"
  if [[ "$seen" != "$trace" ]]; then
    do_log "FATAL the live sidecar (pid $pid) traces to '${seen:-nowhere}', not $trace"
    do_log "FATAL a running process's environment cannot be changed. Restart the desk WITH the trace:"
    do_log "FATAL   ENV=${ENV:-dev} TENANT_ID=${TENANT_ID:-<tenant>} DESK_AGENT=${LAT_AGENT:-<agent>} DRY_RUN=0 ./run -a do_spl_desk_down"
    do_log "FATAL   SPOOL_TRACE=$trace ENV=${ENV:-dev} TENANT_ID=${TENANT_ID:-<tenant>} DESK_AGENT=${LAT_AGENT:-<agent>} DRY_RUN=0 ./run -a do_spl_desk_up"
    return 1
  fi
  : >"$trace" || { do_log "FATAL cannot truncate $trace"; return 1; }
  do_log "INFO the sidecar (pid $pid) is writing $trace"
}

# spl_lat_proc_trace <pid>: the $SPOOL_TRACE that running process was started
# with, or nothing. Its own function so a test can answer for it without a
# real sidecar - /proc is the only source of truth here and cannot be faked.
spl_lat_proc_trace() {  # PID
  local line
  line="$(tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null | grep -m1 '^SPOOL_TRACE=' || true)"
  printf '%s' "${line#SPOOL_TRACE=}"
}
