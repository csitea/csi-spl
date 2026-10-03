#!/bin/bash
#------------------------------------------------------------------------------
# @description The GLOBAL drain of THIS machine, one line (spec 064 L9, owner
# @description Q8: "We need cmd for the drain yes, but global drain oneliner,
# @description and a oneliner for starting as well"). Before a machine is
# @description switched off:
# @description   1. it stops taking agents: <spool root>/dispatch/box.leave is
# @description      written, and spawn-window.sh (so spawn-remote.sh --serve
# @description      too) refuses every spawn here while it exists (exit 6);
# @description   2. the roles prefer the other boxes: this machine moves to the
# @description      END of every LEASE_PRIORITY* line of its lease.conf (the
# @description      original is kept for do_spl_box_join) and the lease loop is
# @description      replaced on the new ranking (LEASE_CMD=ensure);
# @description   3. every role lease held here (fleet orch / dispatch) is handed
# @description      to the next box in rank at once, with a compare-and-set on
# @description      the hub - no wait for the LEASE_STALE timeout;
# @description   4. every lane agent here (a live agent in registry.tsv that is
# @description      not a role seat) gets ONE spool note "drain: push your work,
# @description      write your hold note, report, exit" and up to DRAIN_MIN
# @description      minutes to do it;
# @description   5. a table: agent, pushed (its branch vs origin), exited, hold
# @description      note; then "SAFE TO SWITCH OFF" (exit 0) or "NOT SAFE: <n>
# @description      agents still running" (exit 3). A lane still running is
# @description      listed with its hold dir, so the other box can respawn it.
# @description Idempotent: a second run sends no second note and keeps the
# @description first lease.conf original. DRY_RUN=1 changes nothing, prints
# @description what it WOULD do and the table as it stands now, and exits 0.
# @description The way back is do_spl_box_join (spl-box-join.func.sh).
# @param DRAIN_MIN (optional) - minutes the lanes get to exit, default 10
# @param DRY_RUN (optional) - 1 = print what it would do, change nothing; default 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param ROTATE_HOLD_DIR (optional) - the hold notes root, default /var/tmp/CLE-parent-level/dispatch/hold
# @param LEASE_MACHINE (optional) - this machine's box (else lease.conf, else its desk box id)
# @param BOX_LEAVE_SEND / BOX_LEAVE_ENSURE_CMD / DRAIN_SECS / DRAIN_POLL (tests) - the note sender, the lease-loop restart, the wait in seconds, the poll period
# @example ./run -a do_spl_box_leave
# @example DRY_RUN=1 ./run -a do_spl_box_leave
#------------------------------------------------------------------------------
declare -F spl_lease_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

do_spl_box_leave() {
  spl_box_init || return 1
  local dry="${DRY_RUN:-0}" min="${DRAIN_MIN:-10}"
  [[ "$min" =~ ^[0-9]+$ ]] || { do_log "FATAL DRAIN_MIN must be whole minutes, got '$min'"; return 1; }
  [[ "$dry" =~ ^[01]$ ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got '$dry'"; return 1; }
  local secs="${DRAIN_SECS:-$((min * 60))}" w="WOULD " now
  [[ "$dry" == 0 ]] && w=""
  now="$(date -u +%FT%TZ)"
  echo "box-leave: $SPL_BOX_ME$([[ "$dry" == 1 ]] && echo " (DRY_RUN=1, nothing changes)")"

  # 1. no new agents here
  if [[ -e "$SPL_BOX_MARK" ]]; then
    echo "1. spawns: already refused here since $(cut -d' ' -f2 "$SPL_BOX_MARK" 2>/dev/null)"
  else
    echo "1. spawns: ${w}refuse every spawn here ($SPL_BOX_MARK)"
    [[ "$dry" == 0 ]] && { printf '%s %s by %s\n' "$(date +%s)" "$now" "${SPOOL_AGENT_ID:-$USER}" > "$SPL_BOX_MARK" ||
      { do_log "FATAL cannot write $SPL_BOX_MARK"; return 1; }; }
  fi

  # 2. the roles prefer the other boxes, 3. hand over what is held here
  spl_box_rank leave "$dry" || return 1
  spl_box_handover "$dry"

  # 4. the lanes
  local -a lanes=() live=()
  local -a all=()
  local id
  mapfile -t all < <(spl_box_lanes_all)
  for id in "${all[@]}"; do
    if [[ "$id" == "stale "* ]]; then echo "4. stale row, no note: ${id#stale }"; else lanes+=("$id"); fi
  done
  echo "4. lanes on $SPL_BOX_ME: ${#lanes[@]}${lanes[*]:+ (${lanes[*]})}"
  for id in "${lanes[@]}"; do
    if [[ -e "$SPL_BOX_STATE/noted.$id" ]]; then echo "   $id: drain note already sent"; continue; fi
    echo "   $id: ${w}send the drain note"
    [[ "$dry" == 0 ]] && spl_box_note "$id" && touch "$SPL_BOX_STATE/noted.$id"
  done
  if [[ "$dry" == 0 && ${#lanes[@]} -gt 0 ]]; then
    local end=$(( $(date +%s) + secs ))
    while :; do
      mapfile -t live < <(spl_box_still "${lanes[@]}")
      (( ${#live[@]} == 0 )) && break
      (( $(date +%s) >= end )) && break
      echo "   waiting: ${#live[@]} still running (${live[*]}), $(( end - $(date +%s) ))s left"
      sleep "${DRAIN_POLL:-20}"
    done
  fi

  # 5. the table and the verdict
  mapfile -t live < <(spl_box_still "${lanes[@]}")
  spl_box_table "${lanes[@]}"
  local verdict="SAFE TO SWITCH OFF" rc=0
  (( ${#live[@]} > 0 )) && { verdict="NOT SAFE: ${#live[@]} agents still running"; rc=3; }
  if [[ "$dry" == 1 ]]; then
    echo "DRY_RUN=1: nothing changed; right now: $verdict"
    return 0
  fi
  (( rc == 0 )) || echo "respawn each one still running on another box from its hold dir; or wait and run this again"
  echo "$verdict"
  return "$rc"
}

# The settings both actions use. SPL_BOX_ME is this machine's box (the <box> of
# <ID>@<box>), as the lease loop names it.
spl_box_init() {
  spl_lease_init ro || return 1
  SPL_BOX_MARK="$LEASE_DIR/box.leave"
  SPL_BOX_STATE="$LEASE_DIR/box-leave"
  SPL_BOX_HOLD="${ROTATE_HOLD_DIR:-/var/tmp/CLE-parent-level/dispatch/hold}"
  SPL_BOX_ME="$(spl_box_conf_get LEASE_MACHINE)"
  SPL_BOX_ME="${LEASE_MACHINE:-${SPL_BOX_ME:-$(spl_desk_box_default)}}"
  [[ "$SPL_BOX_ME" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL this machine's box id is not valid: '$SPL_BOX_ME'"; return 1; }
  [[ "${DRY_RUN:-0}" == 1 ]] && return 0
  mkdir -p "$SPL_BOX_STATE" || { do_log "FATAL cannot create $SPL_BOX_STATE"; return 1; }
}

# The value of KEY in lease.conf (first line wins, as spl_lease_conf reads it).
spl_box_conf_get() { sed -n "s/^$1=//p" "$LEASE_CONF" 2>/dev/null | head -1; }

# <list> with <box> moved to the end ("a,me,b" -> "a,b,me").
spl_box_last() {
  local out="" m
  IFS=, read -ra _bl <<<"$1"
  for m in "${_bl[@]}"; do [[ "$m" == "$2" ]] || out+="${out:+,}$m"; done
  [[ ",$1," == *",$2,"* ]] && out+="${out:+,}$2"
  echo "$out"
}

# spl_box_rank leave|join <dry>: rewrite the LEASE_PRIORITY* lines of
# lease.conf (leave: this machine last, the original saved once; join: the
# saved lines back), then let ensure replace the loop (it hashes lease.conf).
spl_box_rank() {
  local verb="$1" dry="$2" k v nv tmp changed=0 saved="$SPL_BOX_STATE/lease.conf.before" w="WOULD "
  [[ "$dry" == 0 ]] && w=""
  if [[ ! -f "$LEASE_CONF" ]]; then
    echo "2. lease: no $LEASE_CONF - this machine holds no role lease, nothing to rank"
    return 0
  fi
  if [[ "$verb" == join && ! -f "$saved" ]]; then
    echo "2. lease: lease.conf was not changed by a leave - ranking kept as it is"
    return 0
  fi
  tmp="$(mktemp)" || return 1
  cp "$LEASE_CONF" "$tmp"
  for k in LEASE_PRIORITY LEASE_PRIORITY_ORCH LEASE_PRIORITY_DISPATCH; do
    v="$(sed -n "s/^$k=//p" "$tmp" | head -1)"
    if [[ "$verb" == leave ]]; then
      [[ -n "$v" ]] || continue
      nv="$(spl_box_last "$v" "$SPL_BOX_ME")"
    else
      nv="$(sed -n "s/^$k=//p" "$saved" | head -1)"
      [[ -n "$nv" ]] || continue
    fi
    [[ "$nv" == "$v" ]] && continue
    echo "2. lease: ${w}$k=$v -> $nv"
    if [[ -n "$v" ]]; then sed -i "0,/^$k=/s|^$k=.*|$k=$nv|" "$tmp"; else echo "$k=$nv" >> "$tmp"; fi
    changed=1
  done
  if (( changed == 0 )); then
    echo "2. lease: ranking already $([[ "$verb" == leave ]] && echo "puts $SPL_BOX_ME last" || echo "as before the leave")"
  fi
  if [[ "$dry" == 1 ]]; then rm -f "$tmp"; [[ "$changed" == 1 ]] && echo "2. lease: WOULD restart the lease loop on it (LEASE_CMD=ensure)"; return 0; fi
  if (( changed )); then
    [[ "$verb" == leave && ! -f "$saved" ]] && cp -p "$LEASE_CONF" "$saved"
    # in place (cat >, not mv): keep the file's owner and mode for every reader
    cat "$tmp" > "$LEASE_CONF" || { rm -f "$tmp"; do_log "FATAL cannot write $LEASE_CONF"; return 1; }
  fi
  rm -f "$tmp"
  [[ "$verb" == join ]] && rm -f "$saved"
  spl_box_ensure
}

# Replace the lease loop on the current lease.conf. A loop that cannot be
# restarted (ensure refused) is stopped on leave: left on the old ranking it
# would take the roles straight back.
spl_box_ensure() {
  local out rc=0
  if [[ -n "${BOX_LEAVE_ENSURE_CMD:-}" ]]; then
    out="$($BOX_LEAVE_ENSURE_CMD 2>&1)" || rc=$?
  else
    # a clean environment: the ids read from lease.conf here must not pin the loop
    out="$(env -u LEASE_PRIORITY -u LEASE_PRIORITY_ORCH -u LEASE_PRIORITY_DISPATCH LEASE_CMD=ensure \
      "${LEASE_RUN:-$PROJ_PATH/run}" -a do_spl_dispatch_lease 2>&1)" || rc=$?
  fi
  if (( rc == 0 )); then echo "2. lease: loop on the current ranking (ensure ok)"; return 0; fi
  echo "2. lease: WARN ensure failed (rc=$rc): $(tail -1 <<<"$out")"
  if [[ -e "$SPL_BOX_MARK" ]]; then
    ( unset LEASE_PRIORITY LEASE_PRIORITY_ORCH LEASE_PRIORITY_DISPATCH; spl_lease_init ro && spl_lease_stop ) >/dev/null 2>&1
    echo "2. lease: stopped this machine's lease loop instead (an old loop would take the roles back)"
  fi
  return 0
}

# 3. Each role whose hub holder is this machine goes to the next box in its
# (new) ranking that is ALIVE, as "<the role's id>@<box>" (ids 001-003 exist on
# every box). The hub keeps no heartbeat for a box that holds nothing, so the
# proof is the hand-over itself: a box whose lease loop runs renews a role it
# holds on its next tick (gen moves on, holder still @box), within
# BOX_LEAVE_RENEW_WAIT s (default LEASE_PERIOD + 30). A box that does not
# renew is skipped (PC dry run 2026-10-03: the next in rank was box-desk, dead
# since 22:45Z) and the next one is tried; when none renews the role is written
# back here, so the other loops take it after LEASE_STALE as they would anyway.
spl_box_handover() (
  local dry="$1" role
  unset LEASE_PRIORITY LEASE_PRIORITY_ORCH LEASE_PRIORITY_DISPATCH
  if [[ -z "${LEASE_FLEET:-}" && -z "$(spl_box_conf_get LEASE_FLEET)" ]]; then
    echo "3. roles: no LEASE_FLEET - no fleet lease to hand over"; return 0
  fi
  LEASE_MACHINE="$SPL_BOX_ME"
  { spl_lease_ids master failover orch && spl_fleet_ids && spl_fleet_hub_init; } >/dev/null 2>&1 ||
    { echo "3. roles: WARN cannot reach the fleet lease (lease.conf or desk) - the roles go stale ${LEASE_STALE}s after the switch-off"; return 0; }
  for role in orch dispatch; do spl_box_hand_role "$role" "$dry"; done
)

# spl_box_read <role>: FH FG FA FW and hm (the holder's box) from the hub; 1 = unreachable.
spl_box_read() {
  local out
  if ! out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$1" 2>&1)" || ! spl_fleet_read "$out"; then
    echo "3. roles: $1: WARN hub unreachable: $(tr '\n' ' ' <<<"$out" | cut -c1-160)"; return 1
  fi
  hm=""; [[ "$FH" == *@* ]] && hm="${FH##*@}"
  return 0
}

# spl_box_cas <role> <holder>: one compare-and-set on the gen last read; 0 = won.
spl_box_cas() {
  local out
  out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$1" --holder "$2" --if-gen "$FG" 2>&1)" &&
    spl_fleet_read "$out" && [[ "$FW" == true ]]
}

spl_box_hand_role() {
  # shellcheck disable=SC2034 # FA is set by spl_fleet_read with the others
  local role="$1" dry="$2" id next g end FH FG FA FW hm tried=""
  spl_box_read "$role" || return 0
  [[ "$hm" == "$SPL_BOX_ME" ]] || { echo "3. roles: $role held by ${FH:-nobody} - nothing to hand"; return 0; }
  [[ "$role" == orch ]] && id="$LEASE_ORCH" || id="$LEASE_MASTER"
  local -a nexts=()
  mapfile -t nexts < <(spl_box_others "$role")
  (( ${#nexts[@]} )) || { echo "3. roles: $role: WARN no other box in the ranking - it stays here and goes stale ${LEASE_STALE}s after the switch-off"; return 0; }
  if [[ "$dry" == 1 ]]; then
    echo "3. roles: $role: WOULD hand $FH -> $id@${nexts[0]}, kept only if ${nexts[0]}'s lease loop renews it within $(spl_box_renew_wait)s, else the next of: ${nexts[*]}"
    return 0
  fi
  for next in "${nexts[@]}"; do
    spl_box_read "$role" || return 0
    # still here, or still on the box just skipped (written there by this run)
    [[ "$hm" == "$SPL_BOX_ME" || ( -n "$tried" && "$hm" == "${tried##* }" ) ]] ||
      { echo "3. roles: $role is now ${FH:-nobody} - left there"; return 0; }
    spl_box_cas "$role" "$id@$next" || { spl_box_read "$role" && spl_box_cas "$role" "$id@$next"; } ||
      { echo "3. roles: $role: WARN compare-and-set lost twice - holder now ${FH:-unknown}"; return 0; }
    g="$FG"; end=$(( $(date +%s) + $(spl_box_renew_wait) ))
    while :; do
      spl_box_read "$role" >/dev/null || break
      if [[ "$hm" == "$next" ]] && (( FG > g )); then
        spl_lease_log "BOX-LEAVE $role: $SPL_BOX_ME handed $role to $next ($FH renewed it)${tried:+, skipped$tried}"
        echo "3. roles: $role handed to $next: $FH renewed it${tried:+ (skipped, no renewal:$tried)}"
        return 0
      fi
      [[ "$hm" == "$next" ]] || { echo "3. roles: $role: taken by ${FH:-nobody} meanwhile - left there"; return 0; }
      (( $(date +%s) >= end )) && break
      sleep "${BOX_LEAVE_RENEW_POLL:-5}"
    done
    echo "3. roles: $role: $next did not renew it within $(spl_box_renew_wait)s (no live lease loop there) - skipped"
    tried+=" $next"
  done
  # nobody renewed: back here, so it is not parked on a dead box
  spl_box_read "$role" && [[ "$hm" != "$SPL_BOX_ME" ]] && spl_box_cas "$role" "$id@$SPL_BOX_ME" >/dev/null
  spl_lease_log "BOX-LEAVE $role: no box renewed it (tried$tried) - kept on $SPL_BOX_ME"
  echo "3. roles: $role: WARN no other box renewed it (tried$tried) - kept on $SPL_BOX_ME; it goes stale ${LEASE_STALE}s after the switch-off"
}

spl_box_renew_wait() { echo "${BOX_LEAVE_RENEW_WAIT:-$(( LEASE_PERIOD + 30 ))}"; }

# The other boxes of the role's ranking, in rank order.
spl_box_others() {
  local k="LEASE_PRIORITY_${1^^}" m
  [[ -n "${!k:-}" ]] || k=LEASE_PRIORITY
  IFS=, read -ra _bn <<<"${!k}"
  for m in "${_bn[@]}"; do [[ "$m" != "$SPL_BOX_ME" ]] && echo "$m"; done
  return 0
}

# A role seat: 001-003 (every box), or an id lease.conf names (as lane-map.sh).
spl_box_role_seat() {
  [[ "$1" =~ ^[A-Za-z]+-00[1-3]$ ]] && return 0
  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "$LEASE_CONF" 2>/dev/null
}

# The lane agents on this machine. An id is a lane only when ALL hold: a
# process carries its SPOOL_AGENT_ID, it is not a role seat or the caller,
# its LATEST registry.tsv row names a pane, that pane is alive on THIS box's
# tmux server, and the pane's window carries the id. Anything else is a stale
# row and gets no note: on the PC (2026-10-03) a gone pane, finished agents
# and three panes of an older numbering (other sessions) all carried ids.
# Prints "<id>" per lane and "stale <id> <why>" per dropped id.
spl_box_lanes_all() {
  local reg="${SPOOL_ROOT:-/var/spool-hub}/registry.tsv" id pane win panes
  [[ -s "$reg" ]] || return 0
  panes="$(spl_box_panes)"
  while read -r id; do
    grep -q "^$id"$'\t' "$reg" || continue
    spl_box_role_seat "$id" && continue
    [[ "$id" == "${SPOOL_AGENT_ID:-}" ]] && continue
    pane="$(awk -F'\t' -v id="$id" '$1 == id {p = $3} END {print p}' "$reg")"
    [[ "$pane" =~ ^%[0-9]+$ ]] || { echo "stale $id: its registry row names no pane"; continue; }
    win="$(awk -v p="$pane" '$1 == p {sub(/^[^ ]+ /, ""); print; exit}' <<<"$panes")"
    [[ -n "$win" ]] || { echo "stale $id: its pane $pane is gone from this box's tmux"; continue; }
    spl_box_win_has "$win" "$id" || { echo "stale $id: pane $pane is window '$win', not this lane"; continue; }
    echo "$id"
  done < <(spl_lease_live_ids)
}

spl_box_lanes() { spl_box_lanes_all | grep -v '^stale '; }

# 0 when a window name carries <id> (as spool_id_of_window reads it: an
# optional "<tag>: " prefix, then the id, then "@<box>" or " <title>").
spl_box_win_has() {
  local n="$1"
  case "$n" in *": "*) [[ "${n%%: *}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && n="${n#*: }" ;; esac
  n="${n%% *}"; n="${n%%@*}"
  [[ "$n" == "$2" ]]
}

# "<pane id> <window name>" for every pane of this box's tmux server.
# BOX_LEAVE_PANES_CMD replaces it in the tests.
spl_box_panes() {
  if [[ -n "${BOX_LEAVE_PANES_CMD:-}" ]]; then $BOX_LEAVE_PANES_CMD; return 0; fi
  (
    # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
    . "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" &&
      SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1 && spool_tmux_argv &&
      "${SPOOL_TM[@]}" list-panes -a -F '#{pane_id} #{window_name}' 2>/dev/null
  )
  return 0
}

# Those of the given lanes that still run: still a lane by every rule above.
spl_box_still() {
  (( $# )) || return 0
  local now id
  now=" $(spl_box_lanes | tr '\n' ' ') "
  for id in "$@"; do [[ "$now" == *" $id "* ]] && echo "$id"; done
  return 0
}

spl_box_hold() { echo "$SPL_BOX_HOLD/drain-$SPL_BOX_ME/$1.md"; }

# The latest registry row's run dir (its worktree) of <id>.
spl_box_rundir() {
  awk -F'\t' -v id="$1" '$1 == id {d = $4} END {print d}' "${SPOOL_ROOT:-/var/spool-hub}/registry.tsv" 2>/dev/null
}

spl_box_note() {
  local id="$1" send="${BOX_LEAVE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}" rc=0
  local from="${SPOOL_AGENT_ID:-}"
  [[ -n "$from" ]] || from="$(spl_box_conf_get LEASE_ORCH)"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "${from:-c-001}" --to "$id" --kind note \
    --task "box-leave-$SPL_BOX_ME" --body "drain: push your work, write your hold note, report, exit. $SPL_BOX_ME is being switched off: you have ${DRAIN_MIN:-10} min. Hold note: $(spl_box_hold "$id") (branch, unpushed commits, the open question, NEXT lines) so another box can respawn you; then /exit-clean." \
    >/dev/null 2>&1 8>&- || rc=$?
  # spool-send.sh: 1-9 = delivered, only the poke did not ring; 10+ = nothing delivered
  if (( rc >= 10 || rc == 2 )); then echo "   $id: WARN the note was not delivered (spool-send exit $rc)"; return 1; fi
  return 0
}

# spl_box_pushed <dir> <exited yes|no>: yes / no (<n> unpushed, <m> dirty) /
# n/a (no own worktree). A worktree gone after its agent exited was removed by
# exit-clean, which removes it only once HEAD is on trunk. An agent with no
# worktree of its own (an agy agent works in the main checkout) is n/a and is
# never counted as unpushed.
spl_box_pushed() {
  local d="$1" ahead dirty
  if [[ -z "$d" || ! -d "$d" ]]; then
    [[ -n "$d" && "$2" == yes ]] && echo "yes (worktree removed)" || echo "n/a (no own worktree)"
    return
  fi
  [[ "$(git -C "$d" rev-parse --git-dir 2>/dev/null)" == *"/worktrees/"* ]] || { echo "n/a (no own worktree)"; return; }
  ahead="$(git -C "$d" rev-list --count HEAD --not --remotes=origin 2>/dev/null)" || ahead="?"
  dirty="$(git -C "$d" status --porcelain 2>/dev/null | grep -c .)"
  [[ "$ahead" == 0 && "$dirty" == 0 ]] && { echo yes; return; }
  echo "no ($ahead unpushed, $dirty dirty)"
}

spl_box_table() {
  local live id ex hold
  live=" $(spl_box_lanes | tr '\n' ' ') "
  echo "5. agent | pushed | exited | hold note"
  for id in "$@"; do
    ex=yes; [[ "$live" == *" $id "* ]] && ex=no
    hold="$(spl_box_hold "$id")"
    [[ -s "$hold" ]] && hold="$hold (written)" || hold="$hold (none)"
    echo "   $id | $(spl_box_pushed "$(spl_box_rundir "$id")" "$ex") | $ex | $hold"
  done
  (( $# )) || echo "   (no lane agents on $SPL_BOX_ME)"
}
