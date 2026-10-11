#!/bin/bash
#------------------------------------------------------------------------------
# @description The login proof of spec 132 section 3 (fleet login self-heal on
# @description 3 boxes): do two boxes, each signed in on its own to the same
# @description Claude account, renew their logins without breaking each other?
# @description Read-only, on the box it runs on. It reads that box's
# @description agent-login-check cron log (one summary line per tick) and its
# @description credential samples (<state>/cred.log, written by
# @description do_spl_agent_login_check from agent-login-cred.sh stat), over
# @description the window that starts at the proof start
# @description (do_spl_agent_login_proof_start) and lasts LOGIN_PROOF_HOURS.
# @description The marks, each PASS or FAIL:
# @description   wall    LOGIN_PROOF_HOURS (48) of wall clock since the start
# @description   peers   SPOOL_LOGIN_PEERS empty all through the window
# @description   renew   >= LOGIN_PROOF_RENEWALS (5) renewals: the sha prefix
# @description           changed and expiresAt moved on between two samples
# @description   expired 0 ticks with probe=expired
# @description   stuck   0 ticks with stuck_login > 0
# @description   ticks   the cron ticked in >= LOGIN_PROOF_TICK_PCT (95) % of
# @description           the window's minutes (2880 in 48 h)
# @description A FAIL names the first failing sample's UTC time. It also prints
# @description the renewal interval: the delta between successive expiresAt
# @description at each sha change, in minutes. Prints sha prefixes (12) and
# @description times only, never credential content.
# @param LOGIN_STATE_DIR (optional) - default /var/csi/csi-spl/agent-login-check
# @param LOGIN_PROOF_LOG (optional) - the cron log, default <state>/cron.log
# @param LOGIN_PROOF_SAMPLES (optional) - the samples, default <state>/cred.log
# @param LOGIN_PROOF_START (optional) - the start, UTC (YYYY-MM-DDTHH:MM:SSZ) or epoch; default <state>/proof.start
# @param LOGIN_PROOF_HOURS (optional) - default 48
# @param LOGIN_PROOF_RENEWALS (optional) - default 5
# @param LOGIN_PROOF_TICK_PCT (optional) - default 95
# @param LOGIN_NOW (optional) - the clock, epoch (tests)
# @example ./run -a do_spl_agent_login_proof
# @example LOGIN_PROOF_START=2026-10-12T08:00:00Z ./run -a do_spl_agent_login_proof
#------------------------------------------------------------------------------
do_spl_agent_login_proof() {
  local state="${LOGIN_STATE_DIR:-/var/csi/csi-spl/agent-login-check}"
  local log="${LOGIN_PROOF_LOG:-$state/cron.log}" samples="${LOGIN_PROOF_SAMPLES:-$state/cred.log}"
  local hours="${LOGIN_PROOF_HOURS:-48}" want="${LOGIN_PROOF_RENEWALS:-5}" pct="${LOGIN_PROOF_TICK_PCT:-95}"
  local now="${LOGIN_NOW:-$(date +%s)}" start s0 end e0 s e
  [[ "$hours$want$pct$now" =~ ^[0-9]+$ ]] || { echo "login-proof: FATAL LOGIN_PROOF_HOURS, _RENEWALS, _TICK_PCT and LOGIN_NOW must be whole numbers" >&2; return 2; }
  start="${LOGIN_PROOF_START:-$(cut -d' ' -f1 "$state/proof.start" 2>/dev/null)}"
  s0="$(_lp_epoch "$start")" || { echo "login-proof: FAIL no proof start (LOGIN_PROOF_START or $state/proof.start; do_spl_agent_login_proof_start records it)"; return 1; }
  [[ -r "$log" ]] || { echo "login-proof: FAIL no cron log $log"; return 1; }
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" || return 1
  e0=$((s0 + hours * 3600)); (( now < e0 )) && end="$now" || end="$e0"
  s="$(_lp_utc "$s0")"; e="$(_lp_utc "$end")"
  echo "login-proof@$(ai_tag): window $s .. $(_lp_utc "$e0") (${hours} h), read up to $e"

  local n last xp sl
  read -r n last xp sl < <(awk -v s="$s" -v e="$e" '
    $1 >= s && $1 <= e && $2 ~ /^login-check@/ {
      n++; last = $1
      if (xp == "" && $3 == "probe=expired") xp = $1
      if (sl == "" && $0 ~ / stuck_login=[1-9]/) sl = $1
    }
    END { printf "%d %s %s %s\n", n, (last == "" ? "-" : last), (xp == "" ? "-" : xp), (sl == "" ? "-" : sl) }' "$log")
  local pstart pfail r rt deltas
  # the samples: the state at the start is the last one at or before it
  IFS='|' read -r pstart pfail r rt deltas < <(awk -v s="$s" -v e="$e" -v want="$want" '
    { p = $4; sub(/^peers=/, "", p) }
    $1 <= s { psha = $2; pexp = $3; pp = p; if ($1 < s) next }
    $1 > e { exit }
    {
      if (pf == "" && p + 0 > 0) pf = $1
      if (psha != "" && $2 != psha && $3 + 0 > pexp + 0) {
        r++; if (r == want) rt = $1
        if (pexp + 0 > 0) { d = d sep int(($3 - pexp) / 60000); sep = " " }
      }
      psha = $2; pexp = $3
    }
    END { printf "%s|%s|%d|%s|%s\n", (pp == "" ? "-" : pp), (pf == "" ? "-" : pf), r, (rt == "" ? "-" : rt), d }' "$samples" 2>/dev/null)

  local fails=() at mins=$(( (end - s0) / 60 ))
  [[ "$last" == - ]] && at="$s" || at="$last"
  if (( now >= e0 )); then echo "  wall    PASS ${hours} h since $s"
  else echo "  wall    FAIL $(( (now - s0) / 60 )) of $((hours * 60)) min so far (last tick $at)"; fails+=("$at wall"); fi
  if [[ "${pstart:--}" != - && "$pstart" -gt 0 ]]; then echo "  peers   FAIL $pstart peer(s) named at the start $s"; fails+=("$s peers")
  elif [[ "${pfail:--}" != - ]]; then echo "  peers   FAIL a peer named at $pfail"; fails+=("$pfail peers")
  else echo "  peers   PASS SPOOL_LOGIN_PEERS empty in every sample"; fi
  if (( ${r:-0} >= want )); then echo "  renew   PASS ${r} renewals (the ${want}th at $rt)"
  else echo "  renew   FAIL ${r:-0} of $want renewals by $e"; fails+=("$e renew"); fi
  if [[ "$xp" == - ]]; then echo "  expired PASS 0 of $n ticks with probe=expired"
  else echo "  expired FAIL the first tick with probe=expired at $xp"; fails+=("$xp expired"); fi
  if [[ "$sl" == - ]]; then echo "  stuck   PASS 0 of $n ticks with stuck_login > 0"
  else echo "  stuck   FAIL the first tick with stuck_login > 0 at $sl"; fails+=("$sl stuck"); fi
  if (( mins > 0 && n * 100 >= mins * pct )) || (( mins == 0 )); then echo "  ticks   PASS $n ticks in $mins min"
  else echo "  ticks   FAIL $n ticks in $mins min (< ${pct} %; last tick $at)"; fails+=("$at ticks"); fi
  echo "  renewal interval (min, delta of expiresAt at each sha change): ${deltas:-none measured}"
  if (( ${#fails[@]} == 0 )); then echo "login-proof: PASS"; return 0; fi
  local first_fail
  first_fail="$(printf '%s\n' "${fails[@]}" | sort | sed -n 1p)"
  echo "login-proof: FAIL first failing sample ${first_fail% *} (${first_fail##* })"
  return 1
}

# epoch from "<epoch>" or a UTC time; non-zero when it is neither.
_lp_epoch() {
  [[ "$1" =~ ^[0-9]+$ ]] && { echo "$1"; return 0; }
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  date -u -d "$1" +%s
}

_lp_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
