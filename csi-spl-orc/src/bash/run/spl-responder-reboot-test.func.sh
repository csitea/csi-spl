#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1265 / epic SPL-1238, step 5: prove the non-AI responder is
# @description reboot-proof. The owner's question (9869051b): "what happens
# @description when I restart the agents box next time". This action answers it
# @description as a REPEATABLE check (run it after any reboot), read-only:
# @description   1. the desk-reconcile cron line is installed and the script it
# @description      names is executable - the thing that re-seats every desk and
# @description      runs the responder after a reboot, with no human;
# @description   2. that script carries the responder step (do_spl_responder
# @description      _sweep) - so the reconcile actually drives the responder;
# @description   3. every desk seated on this box has a LIVE hub-run sidecar
# @description      (spl_desk_alive) - what the reboot had to bring back;
# @description   4. do_spl_responder_sweep runs clean against what is seated.
# @description Each check is a PASS/FAIL line; a missing cron or a dead sidecar
# @description is a FAIL (non-zero exit), the states that leave a post unheard
# @description after a restart. It MUTATES nothing: the control for "did the
# @description reboot recover" is the live state, not a staged one. The active
# @description stop-and-reprove (kill a sidecar, post a test escalation, assert
# @description the "Seen" within 60 s) is REBOOT_TEST_LIVE=1 DRY_RUN=0, a prod
# @description leg the box operator runs; the default here is the safe audit.
# @param ENV - required: dev or prd
# @param DESK_BOX (optional) - the responder box to expect, default box-rsp
# @param RSP_REQUIRE_SEATED (optional) - 1 = a missing box-rsp desk is a FAIL
# @param   (after step 4 seats it); default 0 (its absence is a WARN while the
# @param   seating is still pending)
# @example ENV=prd ./run -a do_spl_responder_reboot_test
#------------------------------------------------------------------------------
do_spl_responder_reboot_test() {
  do_require_bin python3 crontab || return 1
  do_spl_cloud_cnf || return 1
  local box="${DESK_BOX:-box-rsp}" require_rsp="${RSP_REQUIRE_SEATED:-0}"
  local deskroot="$SPL_STATE_DIR/desk" fails=0 warns=0

  # 1. the reboot-proof driver: a desk-reconcile crontab line this box owns,
  #    whose script is executable. Match on the tag, env-scoped or not.
  local tag="${SPL_ORG_APP}:desk-reconcile" cronline script
  cronline="$(crontab -l 2>/dev/null | grep -F "# $tag" | head -1)"
  if [[ -z "$cronline" ]]; then
    do_log "FAIL no '$tag' crontab line: nothing re-seats the desks or runs the responder after a reboot"
    fails=$((fails + 1))
  else
    script="$(printf '%s' "$cronline" | grep -oE '[^ ]*desk-reconcile-cron\.sh' | head -1)"
    if [[ -n "$script" && -x "$script" ]]; then
      do_log "OK 1/4 reboot driver: desk-reconcile cron installed, script executable ($script)"
    else
      do_log "FAIL 1/4 desk-reconcile cron installed but its script is gone / not executable: ${script:-<none in the line>}"
      fails=$((fails + 1))
    fi
    # 2. does that script drive the responder? The cron checkout fetches trunk
    #    each tick, so after one tick past the responder commit it carries it.
    if [[ -n "$script" && -r "$script" ]] && grep -q "do_spl_responder_sweep" "$script"; then
      do_log "OK 2/4 the reconcile runs the responder sweep"
    else
      do_log "WARN 2/4 the installed reconcile script does not yet run do_spl_responder_sweep (its checkout trails trunk until the next tick)"
      warns=$((warns + 1))
    fi
  fi

  # 3. every seated desk has a live sidecar; the responder box gets its own say.
  local alive=0 dead=0 rsp_seated=0 pidf tdir bdir tenant bname
  if [[ -d "$deskroot" ]]; then
    for pidf in "$deskroot"/*/*/spool/.hub/hub-run.pid; do
      [[ -e "$pidf" ]] || continue
      bdir="${pidf%/spool/.hub/hub-run.pid}"; bname="$(basename "$bdir")"
      tenant="$(basename "$(dirname "$bdir")")"
      if spl_desk_alive "$pidf"; then
        alive=$((alive + 1))
        [[ "$bname" == "$box" ]] && rsp_seated=1
      else
        do_log "FAIL 3/4 a seated desk did not come back: $tenant/$bname sidecar is dead ($pidf)"
        dead=$((dead + 1)); fails=$((fails + 1))
      fi
    done
  fi
  (( dead == 0 )) && do_log "OK 3/4 all $alive seated desk sidecar(s) are live after the reboot"
  if (( rsp_seated )); then
    do_log "OK the responder desk $box is seated and live"
  elif (( require_rsp )); then
    do_log "FAIL the responder desk $box is NOT seated (RSP_REQUIRE_SEATED=1); seat it with do_spl_desk_up"
    fails=$((fails + 1))
  else
    do_log "WARN the responder desk $box is not seated yet (step 4 prod op pending); the responder will no-op until it is"
    warns=$((warns + 1))
  fi

  # 4. the responder sweep itself runs clean against what is seated (dry run).
  if do_spl_responder_sweep >/dev/null 2>&1; then
    do_log "OK 4/4 do_spl_responder_sweep runs clean"
  else
    do_log "FAIL 4/4 do_spl_responder_sweep errored"
    fails=$((fails + 1))
  fi

  if (( fails == 0 )); then
    do_log "OK reboot test ($ENV): the answering machinery is reboot-proof ($warns warning(s))"
    return 0
  fi
  do_log "FAIL reboot test ($ENV): $fails check(s) failed - a post could go unheard after a restart"
  return 1
}
