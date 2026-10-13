#!/bin/bash
#------------------------------------------------------------------------------
# @description The OD pool supervisor (spec 134 sections 4.2 and 4.3, step P3 /
# @description task T3): a shell action on every box, every 30 s from cron
# @description (do_spl_od_pool_supervise_install_cron). It is the ONLY thing
# @description that kills a pool seat, and only a seat it spawned on its own
# @description box (rule 6.5: agents never kill agents). Off unless
# @description OD_POOL_SUPERVISE=1; off, it retires the seats it spawned (the
# @description P3 rollback) and does nothing else. On, one tick:
# @description   POOL    - read the od_pool row (`spool ask pool`): the target
# @description             claude_n + grok_n, vendor_out, out_until
# @description   ABLE    - spl_lease_agent_able per seat of this box (the one
# @description             able function); consecutive failures counted in
# @description             <spool root>/od/<id>/fails. A first failure only
# @description             stops the seat locking (its own loop asks the same
# @description             function)
# @description   OUT     - every seat of one vendor failed two ticks and one
# @description             failure is a LEASE_STALL_RE banner (usage limit,
# @description             login): under the `fleet-config` mutex the pool row
# @description             becomes that vendor 0, the other 4, vendor_out, and
# @description             out_until = the banner's reset (none: OD_OUT_RETRY s
# @description             from now); that vendor's seats are retired
# @description   BACK    - out_until has passed: the row goes back to
# @description             OD_BACK_CLAUDE_N + OD_BACK_GROK_N (2 + 2)
# @description   REPLACE - a seat failed two ticks while its vendor is not out:
# @description             its jobs are released (gen + 1, `spool ask release
# @description             --by`), then do_spl_wd_takeover replaces it under the
# @description             same id. A refused takeover (a limit is S2, never
# @description             taken over; WD_TAKEOVER_MAX) leaves the seat and
# @description             sends ONE note an hour to the dispatch holder
# @description   SLOTS   - the target is slots <vendor>-1..n, each a fleet lease
# @description             `od-<vendor>-<k>` held by its seat <ID>@<box>. Slot k
# @description             is homed on box (k-1) mod nb of OD_BOXES (default
# @description             lease.conf LEASE_PRIORITY), so 2 + 2 spreads over two
# @description             boxes. A slot whose holder went silent OD_SLOT_TTL s
# @description             (a box gone), or that its home box never took within
# @description             OD_SLOT_TTL, is taken by any box: the compare-and-set
# @description             lets exactly one win. Held slots are renewed
# @description   FILL    - one change per tick: spawn the seat of a held slot
# @description             that has none, else retire one extra seat (a slot
# @description             past the target) once it holds no job; an extra
# @description             seat is marked retire first, so it takes no new job
# @description Kinds stay empty in P3 (P6 adds them), so the seats lock nothing.
# @param OD_POOL_SUPERVISE (optional) - 1 = on; default 0 (off: retire this box's seats, nothing else)
# @param OD_BOXES (optional) - the fleet's boxes, comma-separated, default lease.conf LEASE_PRIORITY, else this box
# @param OD_SLOT_TTL (optional) - seconds a slot holder may be silent before another box takes it, default 300
# @param OD_OUT_RETRY (optional) - seconds a vendor stays out when its banner gives no reset, default 3600
# @param OD_BACK_CLAUDE_N / OD_BACK_GROK_N (optional) - the target the BACK step restores, default 2 / 2
# @param OD_BY (optional) - the agent id this box's supervisor writes as (pool --set, notes), default c-001
# @param OD_WORKDIR (optional) - a new seat's workdir, default this checkout
# @param OD_FLEET / OD_BOX / OD_HUB_CMD / OD_SEND (optional) - as do_spl_od_seat
# @param OD_SPAWN (optional, tests) - replaces spawn-window.sh: gets <vendor> auto <workdir> <seed> <slug>, prints "<ID> <PANE>"
# @param OD_TAKEOVER_CMD (optional, tests) - replaces do_spl_wd_takeover: gets <id> <reason>
# @param OD_LOOP_START (optional, tests) - replaces the seat loop start: gets <id>
# @param OD_MUTEX_CMD (optional, tests) - replaces the fleet-config mutex: gets <role> <holder>
# @param OD_KILL (optional, tests) - replaces `sudo -n kill` for a retired seat's pid
# @example ./run -a do_spl_od_pool_supervise
# @example OD_POOL_SUPERVISE=1 ./run -a do_spl_od_pool_supervise
#------------------------------------------------------------------------------
declare -F spl_od_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-od-seat.func.sh"

OD_VENDORS="claude grok"

do_spl_od_pool_supervise() {
  spl_od_init || return 1
  : "${OD_SLOT_TTL:=300}" "${OD_OUT_RETRY:=3600}" "${OD_BACK_CLAUDE_N:=2}" "${OD_BACK_GROK_N:=2}" "${OD_BY:=c-001}"
  local k
  for k in OD_SLOT_TTL OD_OUT_RETRY OD_BACK_CLAUDE_N OD_BACK_GROK_N; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a number, got: '${!k}'"; return 1; }
  done
  [[ "${OD_POOL_SUPERVISE:-0}" =~ ^[01]$ ]] || { do_log "FATAL OD_POOL_SUPERVISE must be 0 or 1, got: '$OD_POOL_SUPERVISE'"; return 1; }
  exec 7>>"$OD_DIR/supervise.lock"
  flock -n 7 || { do_log "INFO another supervisor tick runs on this box: skipped"; return 0; }
  touch "$OD_DIR/seats.tsv"
  if [[ "${OD_POOL_SUPERVISE:-0}" != 1 ]]; then spl_od_sup_off; return 0; fi
  spl_od_sup_pool || return 0
  spl_od_sup_able
  spl_od_sup_out || spl_od_sup_back
  spl_od_sup_replace
  spl_od_sup_slots
  spl_od_sup_fill
  spl_od_sup_loops
  do_log "INFO od pool on $OD_BOX: target claude $OD_N_claude + grok $OD_N_grok${OD_OUT:+ ($OD_OUT out)}; slots held here:${OD_MINE:- none}; seats here: $(spl_od_sup_seats | awk -F'\t' '{printf "%s=%s ", $3, $1}')"
}

# ---- the registry: <spool root>/od/seats.tsv, "<id> TAB <vendor> TAB <slot>" ----

spl_od_sup_seats() { awk -F'\t' 'NF >= 3' "$OD_DIR/seats.tsv"; }

spl_od_sup_reg_add() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OD_DIR/seats.tsv"; }

spl_od_sup_reg_del() {
  awk -F'\t' -v i="$1" '$1 != i' "$OD_DIR/seats.tsv" > "$OD_DIR/seats.tsv.tmp.$$" && mv -f "$OD_DIR/seats.tsv.tmp.$$" "$OD_DIR/seats.tsv"
}

# spl_od_sup_fails ID: the seat's consecutive failed able checks.
spl_od_sup_fails() { local n=0; read -r n _ < "$OD_DIR/$1/fails" 2>/dev/null; [[ "$n" =~ ^[0-9]+$ ]] || n=0; echo "$n"; }

# ---- POOL ----------------------------------------------------------------------------

# Sets OD_N_claude, OD_N_grok, OD_OUT, OD_UNTIL (epoch or empty). Non-zero =
# no answer: the tick does nothing (the hub is the one thing that stays
# single, 4.1; the seats keep their locks until they run out).
spl_od_sup_pool() {
  local out line ut
  out="$(spl_od_hub ask pool --fleet "$OD_FLEET" 2>&1)" &&
    line="$(jq -r '.pool | [(.claude_n // 0), (.grok_n // 0), (.vendor_out // ""), (.out_until // "")] | map(tostring) | join("|")' <<<"$out" 2>/dev/null)" ||
    { do_log "WARN the hub did not answer the pool read: nothing changed this tick: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  IFS='|' read -r OD_N_claude OD_N_grok OD_OUT ut <<<"$line"
  OD_UNTIL=""
  [[ -n "$ut" ]] && OD_UNTIL="$(date -u -d "$ut" +%s 2>/dev/null)"
  return 0
}

# spl_od_sup_pool_set ARGS...: one write of the pool row under the
# fleet-config mutex (068 section 5), then the row is read again.
spl_od_sup_pool_set() {
  local out rc=0
  if [[ -n "${OD_MUTEX_CMD:-}" ]]; then "$OD_MUTEX_CMD" fleet-config "$OD_BY@$OD_BOX" || rc=$?
  else
    declare -F spl_peer_mutex >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-gate.func.sh"
    PEER_MUTEX_TTL="${PEER_MUTEX_TTL:-120}" PEER_MUTEX_WAIT="${PEER_MUTEX_WAIT:-0}" spl_peer_mutex fleet-config "$OD_BY@$OD_BOX" || rc=$?
  fi
  (( rc == 0 )) || { do_log "WARN the fleet-config mutex was not taken (exit $rc): the pool row is not written this tick"; return 1; }
  out="$(spl_od_hub ask pool --fleet "$OD_FLEET" --set --by "$OD_BY@$OD_BOX" "$@" 2>&1)" ||
    { do_log "WARN the pool write failed: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  spl_od_sup_pool
}

# ---- ABLE ----------------------------------------------------------------------------

spl_od_sup_able() {
  local id pid n why
  while IFS=$'\t' read -r id _ _; do
    mkdir -p "$OD_DIR/$id"
    pid="$(spl_lease_agent_able "$id")"
    if [[ -n "$pid" ]]; then echo 0 > "$OD_DIR/$id/fails"; continue; fi
    n="$(spl_od_sup_fails "$id")"; why="$(spl_od_why "$id")"
    printf '%s %s\n' "$((n + 1))" "$why" > "$OD_DIR/$id/fails"
    spl_od_log "$id" "ABLE-FAIL $((n + 1)): $why"
  done < <(spl_od_sup_seats)
}

# spl_od_sup_banner WHY: 0 when WHY is a usage-limit / login stall.
spl_od_sup_banner() { grep -qiE -- "${LEASE_STALL_RE:-$LEASE_STALL_RE_DEFAULT}" <<<"$1"; }

# ---- OUT / BACK (4.3) ----------------------------------------------------------------

# 0 when a vendor went out this tick (the row was written).
spl_od_sup_out() {
  local v other seats id n why all banner mins until now
  [[ -z "$OD_OUT" ]] || return 1
  now="$(spl_lease_now)"
  for v in $OD_VENDORS; do
    seats="$(spl_od_sup_seats | awk -F'\t' -v v="$v" '$2 == v {print $1}')"
    [[ -n "$seats" ]] || continue
    all=1 banner="" until=""
    for id in $seats; do
      n="$(spl_od_sup_fails "$id")"; read -r _ why < "$OD_DIR/$id/fails" 2>/dev/null || why=""
      (( n >= 2 )) || { all=0; break; }
      if spl_od_sup_banner "$why"; then
        banner="$why"
        mins="$(grep -oE 'resets in [0-9]+ min' <<<"$why" | grep -oE '[0-9]+')"
        [[ -n "$mins" ]] && until="$(( now + mins * 60 ))"
      fi
    done
    (( all )) && [[ -n "$banner" ]] || continue
    [[ "$v" == claude ]] && other=grok || other=claude
    [[ -n "$until" ]] || until=$(( now + OD_OUT_RETRY ))
    spl_od_log "$OD_BY" "VENDOR-OUT $v: every $v seat here failed two ticks ($banner); $other takes all seats until $(date -u -d "@$until" +%FT%TZ)"
    spl_od_sup_pool_set "--$v-n" 0 "--$other-n" "$(( OD_N_claude + OD_N_grok ))" --vendor-out "$v" \
      --out-until "$(date -u -d "@$until" +%FT%TZ)" || return 1
    for id in $seats; do spl_od_sup_retire "$id" "vendor $v out"; done
    return 0
  done
  return 1
}

spl_od_sup_back() {
  [[ -n "$OD_OUT" && -n "$OD_UNTIL" ]] || return 0
  (( $(spl_lease_now) >= OD_UNTIL )) || return 0
  spl_od_log "$OD_BY" "VENDOR-BACK $OD_OUT: its reset passed; target back to claude $OD_BACK_CLAUDE_N + grok $OD_BACK_GROK_N"
  spl_od_sup_pool_set --claude-n "$OD_BACK_CLAUDE_N" --grok-n "$OD_BACK_GROK_N" --vendor-out "" --out-until ""
}

# ---- REPLACE (4.2) -------------------------------------------------------------------

spl_od_sup_replace() {
  local id v rc out
  while IFS=$'\t' read -r id v _; do
    (( $(spl_od_sup_fails "$id") >= 2 )) || continue
    [[ "$v" == "$OD_OUT" ]] && continue
    out="$(spl_od_hub ask release --fleet "$OD_FLEET" --by "$id@$OD_BOX" 2>&1)" ||
      spl_od_log "$id" "WARN release of its jobs failed: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"
    rm -f "$OD_DIR/$id/job.json"
    rc=0
    if [[ -n "${OD_TAKEOVER_CMD:-}" ]]; then "$OD_TAKEOVER_CMD" "$id" "od pool: two failed able checks" || rc=$?
    else spl_od_sup_takeover "$id" || rc=$?
    fi
    echo 0 > "$OD_DIR/$id/fails"
    if (( rc == 0 )); then spl_od_log "$id" "REPLACED through do_spl_wd_takeover (jobs released, gen + 1)"; continue; fi
    spl_od_log "$id" "REPLACE-REFUSED: do_spl_wd_takeover exit $rc"
    spl_od_sup_note "replace-$id" "OD POOL (spec 134 4.2): seat $id@$OD_BOX failed two able checks ($(spl_od_why "$id")); its jobs were released, and do_spl_wd_takeover refused to replace it (exit $rc: 3 = no situation it repairs, e.g. a usage limit; 4 = a guard or WD_TAKEOVER_MAX). The seat stays; the pool runs on the other seats."
  done < <(spl_od_sup_seats)
}

spl_od_sup_takeover() {
  declare -F do_spl_wd_takeover >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-wd-takeover.func.sh"
  ( ID="$1" REASON="od pool: two failed able checks" REQ_FROM="" WD_EVIDENCE="" DRY_RUN=0 do_spl_wd_takeover ) 7>&-
}

# spl_od_sup_note KEY TEXT: one note an hour per KEY to the dispatch holder.
spl_od_sup_note() {
  local f="$OD_DIR/note.$1" now at=0 to send
  now="$(spl_lease_now)"
  read -r at < "$f" 2>/dev/null || at=0
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  (( now - at >= 3600 )) || return 0
  echo "$now" > "$f"
  to=""; [[ -s "$LEASE_DIR/lease" ]] && read -r to _ < "$LEASE_DIR/lease"
  [[ -n "$to" && "$to" != none* ]] || to=orchestrator
  send="${OD_SEND:-$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="$SPOOL_ROOT" bash "$send" --from "$OD_BY" --to "$to" --kind note --task od-pool --body "$2" >/dev/null 2>&1 7>&- 8>&- 9>&- || true
}

# ---- SLOTS ---------------------------------------------------------------------------

# Sets OD_MINE: the slots this box holds after the tick ("<vendor>-<k>"
# words), and OD_SLOTS_OK=0 when a slot did not read (then no seat is
# called extra this tick: a hub blip never retires a seat).
spl_od_sup_slots() {
  local v k n nb rank seat out FH FG FA FW take
  local -a boxes
  IFS=, read -ra boxes <<<"${OD_BOXES:-${LEASE_PRIORITY:-$OD_BOX}}"
  nb=${#boxes[@]} rank=-1
  for k in "${!boxes[@]}"; do [[ "${boxes[$k]}" == "$OD_BOX" ]] && rank=$k; done
  OD_MINE="" OD_SLOTS_OK=1
  for v in $OD_VENDORS; do
    n="OD_N_$v"; n="${!n}"
    for (( k = 1; k <= n; k++ )); do
      out="$(spl_od_hub lease --fleet "$OD_FLEET" --role "od-$v-$k" 2>&1)" && spl_fleet_read "$out" ||
        { do_log "WARN slot od-$v-$k: the hub did not answer"; OD_SLOTS_OK=0; continue; }
      seat="$(spl_od_sup_seats | awk -F'\t' -v s="$v-$k" '$3 == s {print $1; exit}')"
      take=0
      if [[ "${FH##*@}" == "$OD_BOX" && "$FG" != 0 ]]; then take=1
      elif (( FG > 0 && FA >= OD_SLOT_TTL )); then take=1
      elif (( FG == 0 )); then
        if (( rank >= 0 && (k - 1) % nb == rank )); then take=1
        elif spl_od_sup_free_since "od-$v-$k"; then take=1; fi
      fi
      (( take )) || continue
      out="$(spl_od_hub lease --fleet "$OD_FLEET" --role "od-$v-$k" --holder "${seat:-$OD_BY}@$OD_BOX" --if-gen "$FG" 2>&1)" &&
        spl_fleet_read "$out" && [[ "$FW" == true ]] ||
        { spl_od_log "$OD_BY" "SLOT od-$v-$k not won (held by ${FH:-nobody})"; continue; }
      rm -f "$OD_DIR/slot.od-$v-$k.free"
      OD_MINE+=" $v-$k"
    done
  done
}

# spl_od_sup_free_since ROLE: 0 once ROLE was seen with no holder for OD_SLOT_TTL.
spl_od_sup_free_since() {
  local f="$OD_DIR/slot.$1.free" at now
  now="$(spl_lease_now)"
  [[ -s "$f" ]] || { echo "$now" > "$f"; return 1; }
  read -r at < "$f"
  (( now - at >= OD_SLOT_TTL ))
}

# ---- FILL: one spawn or one retire per tick --------------------------------------------

spl_od_sup_fill() {
  local s id slot
  local -a extra=()
  if (( OD_SLOTS_OK )); then
    while IFS=$'\t' read -r id _ slot; do
      [[ " $OD_MINE " == *" $slot "* ]] && continue
      extra+=("$id")
      [[ -e "$OD_DIR/$id/retire" ]] && continue
      touch "$OD_DIR/$id/retire"
      spl_od_log "$id" "EXTRA (slot $slot is not this box's: past the target or held elsewhere): takes no new job"
    done < <(spl_od_sup_seats)
  fi
  for s in $OD_MINE; do
    spl_od_sup_seats | awk -F'\t' -v s="$s" '$3 == s {f = 1} END {exit !f}' && continue
    spl_od_sup_spawn "${s%-*}" "$s"
    return 0
  done
  for id in "${extra[@]}"; do
    [[ -s "$OD_DIR/$id/job.json" ]] && continue
    spl_od_sup_retire "$id" "extra seat, holds no job"
    return 0
  done
}

spl_od_sup_spawn() {
  local v="$1" slot="$2" seed out id spawn wd
  seed="$OD_DIR/seed-$slot.md"
  spawn="${OD_SPAWN:-$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/scripts/spawn-window.sh}"
  wd="${OD_WORKDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
  spl_od_sup_seed "$v" "$slot" > "$seed"
  out="$(bash "$spawn" "$v" auto "$wd" "$seed" "od-$slot" 2>&1 6>&- 7>&- 8>&- 9>&-)" || true
  id="$(grep -oE '^[cg]-[0-9]{3} ' <<<"$out" | tail -1 | tr -d ' ')"
  [[ -n "$id" ]] || { spl_od_log "$OD_BY" "SPAWN-FAIL $slot: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  mkdir -p "$OD_DIR/$id"
  rm -f "$OD_DIR/$id/retire" "$OD_DIR/$id/job.json"
  echo 0 > "$OD_DIR/$id/fails"
  spl_od_sup_reg_add "$id" "$v" "$slot"
  spl_od_log "$id" "SPAWNED for slot $slot ($v) on $OD_BOX"
  spl_od_sup_loop_start "$id"
}

spl_od_sup_seed() {
  echo "# Brief: you are an OD pool seat ($1, slot $2) on $OD_BOX (spec 134)"
  echo
  echo "Your shell loop (do_spl_od_seat) locks OD jobs for you and renews the lock while you are able;"
  echo "a locked job arrives in your inbox as a task (OD JOB <id>). Work it from its pointers (topic,"
  echo "issue card), then close it with the \`spool ask done\` line in that task. Do nothing else: no"
  echo "greeting, no post, no job you did not get from the loop. Until P6 lists a kind, you get none."
}

# ---- RETIRE + LOOPS ----------------------------------------------------------------------

# spl_od_sup_retire ID WHY: release the seat's jobs, stop its loop and its
# process (by pid, TERM then KILL), drop it from the registry.
spl_od_sup_retire() {
  local id="$1" why="$2" pid lp out t0
  out="$(spl_od_hub ask release --fleet "$OD_FLEET" --by "$id@$OD_BOX" 2>&1)" ||
    spl_od_log "$id" "WARN release of its jobs failed: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"
  read -r lp < "$OD_DIR/$id/loop.pid" 2>/dev/null || lp=""
  [[ "$lp" =~ ^[0-9]+$ ]] && kill -TERM "$lp" 2>/dev/null
  pid="$(spl_lease_agent_pid "$id")"
  if [[ -n "$pid" ]]; then
    ${OD_KILL:-sudo -n kill} -TERM "$pid" 2>/dev/null || true
    t0=$SECONDS
    while [[ -n "$(spl_lease_agent_pid "$id")" ]] && (( SECONDS - t0 < ${OD_TERM_WAIT:-10} )); do sleep 1; done
    [[ -n "$(spl_lease_agent_pid "$id")" ]] && { ${OD_KILL:-sudo -n kill} -KILL "$pid" 2>/dev/null || true; }
  fi
  spl_od_sup_reg_del "$id"
  rm -f "$OD_DIR/$id/job.json" "$OD_DIR/$id/retire" "$OD_DIR/$id/loop.pid"
  spl_od_log "$id" "RETIRED ($why)${pid:+: pid $pid}"
}

# Every registered seat has its loop: the loop's flock is free = not running.
spl_od_sup_loops() {
  local id
  while IFS=$'\t' read -r id _ _; do
    ( flock -n 9 ) 9>>"$OD_DIR/$id/loop.lock" || continue
    spl_od_sup_loop_start "$id"
  done < <(spl_od_sup_seats)
}

spl_od_sup_loop_start() {
  local id="$1" run
  if [[ -n "${OD_LOOP_START:-}" ]]; then "$OD_LOOP_START" "$id"; return 0; fi
  run="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/run"
  # the loop writes its own pid (od/<id>/loop.pid) once it holds its lock
  ( exec setsid nohup env OD_SEAT_ID="$id" OD_FLEET="$OD_FLEET" OD_BOX="$OD_BOX" SPOOL_ROOT="$SPOOL_ROOT" \
      bash "$run" -a do_spl_od_seat >> "$OD_DIR/$id/loop.log" 2>&1 < /dev/null 7>&- ) &
  spl_od_log "$id" "LOOP started"
}

# ---- OFF: the rollback ---------------------------------------------------------------

spl_od_sup_off() {
  local id n=0
  while IFS=$'\t' read -r id _ _; do
    spl_od_sup_retire "$id" "OD_POOL_SUPERVISE is off"; n=$((n + 1))
  done < <(spl_od_sup_seats)
  do_log "INFO OD_POOL_SUPERVISE is off: $n seat(s) of this box retired, nothing else done"
}
