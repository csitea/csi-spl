#!/bin/bash
#------------------------------------------------------------------------------
# @description The dispatcher heartbeat lease (SPEC-spool-fleet-roles.md
# @description section 4): exactly one dispatcher holds the lease and
# @description dispatches. LEASE_CMD picks the verb:
# @description   show   - print "<holder> <age-seconds>"
# @description   renew  - loop: every LEASE_PERIOD s, while a live (and not
# @description            stalled: usage-limit/login pane, CLE-77935, or a
# @description            dismissable modal such as "Teach auto mode about
# @description            your environment?") claude process carries
# @description            SPOOL_AGENT_ID=<master>, write
# @description            "<master> <epoch>". It follows the master BY ID,
# @description            so a relaunched master is picked up with no manual
# @description            step; no live master process = no renewal
# @description   watch  - loop: promote the failover once the lease is older
# @description            than LEASE_STALE s (never a failover with no live
# @description            process), keep it fresh in the failover's name, and
# @description            send STANDBY once the master renews again
# @description   ensure - start renew + watch when they are not running
# @description            (idempotent; the desk reconcile cron calls it every
# @description            tick, which is what brings them back after a reboot)
# @description   stop   - stop the loops this action started
# @description   fleet  - loop (FLEET MODE, CLE-77911): ONE lease per role across
# @description            every machine of a fleet, held on the hub (spool lease,
# @description            compare-and-set). Each tick, for role orch and dispatch:
# @description            this machine's candidate (orch: LEASE_ORCH; dispatch:
# @description            LEASE_MASTER, else LEASE_FAILOVER - the local order) renews
# @description            when this machine holds it, takes it when the holder is
# @description            silent > LEASE_STALE s on the hub's clock, and takes it
# @description            back from a machine later in LEASE_PRIORITY (handback; it
# @description            names itself locally, and tells its seat ACTIVE, one
# @description            LEASE_PERIOD later, once the old holder's box has read it).
# @description            The result is mirrored into <dir>/lease (dispatch) and
# @description            <dir>/lease.orch as "<ID>@<box> <epoch>" (ids 001-003
# @description            exist on every box, so the box is always there); every holder
# @description            change is logged once and told to the agents it moves.
# @description            ensure runs fleet INSTEAD of renew + watch when lease.conf
# @description            sets LEASE_FLEET. The holder machine also copies each
# @description            won write into every other tenant its desk box is
# @description            pinned in (spec 059 S5: the hub routes a role's post
# @description            from the post's own tenant's row).
# @description Every transition is written ONCE to <dir>/lease.log and sent
# @description as a spool note to the failover and the orchestrator.
# @description The ids come from LEASE_MASTER / LEASE_FAILOVER / LEASE_ORCH,
# @description else from <dir>/lease.conf (KEY=value lines, never sourced).
# @description ensure does nothing while lease.conf is absent: that file is
# @description the opt-in, so a box without dispatchers starts no loop.
# @param LEASE_CMD - required: show, renew, watch, ensure or stop
# @param SPOOL_ROOT (optional) - default /var/spool-hub; the lease dir is <root>/dispatch
# @param LEASE_MASTER (optional) - the master's agent id (else lease.conf)
# @param LEASE_FAILOVER (optional) - the failover's agent id (else lease.conf)
# @param LEASE_ORCH (optional) - the orchestrator told of every transition (else lease.conf)
# @param LEASE_PERIOD (optional) - seconds between ticks, default 60
# @param LEASE_STALE (optional) - seconds of silence before a failover, default 180
# @param LEASE_UNREACHABLE_RETRY (optional) - fleet mode: seconds between ticks while a hub call fails, default 10 (at most LEASE_PERIOD)
# @param LEASE_HUB_TIMEOUT (optional) - fleet mode: seconds one hub lease call may take, default 12; LEASE_HUB_TRIES (default 2) tries a "hub unreachable" or timed-out call, LEASE_HUB_RETRY_SLEEP (default 2 s) apart; every try is a line in <spool root>/dispatch/dial.log (SPL-2246)
# @param LEASE_FLEET (optional) - fleet mode: the fleet's name on the hub (else lease.conf)
# @param LEASE_MACHINE (optional) - fleet mode: this machine's box, default its desk box id (spl_desk_box_default)
# @param LEASE_PRIORITY (optional) - fleet mode: machines, comma-separated, preferred first
# @param LEASE_PRIORITY_ORCH / LEASE_PRIORITY_DISPATCH (optional) - fleet mode: that role's own machine ranking, same form as LEASE_PRIORITY (env or lease.conf); unset = LEASE_PRIORITY
# @param LEASE_UNREAD_MAX (optional) - fleet mode: an orchestrator idle while an inbox message newer than its last transcript write is older than this many s is stuck, no candidate (take-over condition 2), default 600, 0 = off
# @param LEASE_OWNER_CMD (optional) - fleet mode: replaces the one ops-channel notice per orch take-over (do_spl_fleet_notice; never a DM to the owner, SPL-2584)
# @param LEASE_MIRROR_TENANTS (optional) - fleet mode: the tenants the holder copies the lease into, space-separated (default: every tenant this machine's desk box is pinned in, minus LEASE_TENANT and the test workspaces); LEASE_MIRROR_TIMEOUT (default 10 s) bounds each copy call
# @param LEASE_ORCH_FALLBACK / LEASE_DISPATCH_FALLBACK (optional) - fleet mode (SPL-2544): the VENDORS, comma-separated, the role's seat (LEASE_ORCH / LEASE_MASTER) switches to IN PLACE when no seat of the role can act (do_spl_role_failover); default LEASE_VENDOR_ORDER; a legacy id list (g-001,a-001) reads as its letters' vendors; none = off (env or lease.conf)
# @param LEASE_VENDOR_ORDER (optional) - fleet mode: the vendors, best first, default claude,grok,agy,claude2 (owner: "the order is claude -> grok -> agy"; claude2 = claude under the second login, SPL-2943); a holder of a better vendor outranks any machine rank (env or lease.conf)
# @param LEASE_FALLBACK_WAIT (optional) - fleet mode: a seat switches to the next vendor (and a seat of a worse vendor takes a role) only when the holder has been silent LEASE_STALE + this many s per step down the vendor order (grok 1x, agy 2x), so an able claude seat on any box takes it first; default 60 (env or lease.conf)
# @param LEASE_ROLE_SWITCH (optional) - fleet mode: 0 turns the in-place vendor switch off; LEASE_SWITCH_RETRY (default 120 s) between two launches for one seat; LEASE_SWITCH_RUN (tests) replaces ./run, LEASE_SWITCH_SYNC=1 runs it in the foreground; off under SPOOL_TEST=1 or a fake LEASE_PROC_ROOT unless LEASE_SWITCH_RUN is set
# @param LEASE_HOLDDOWN (optional) - fleet mode: a rank handback waits until this machine's candidate has been able this many s without a break (spec 092), default 300, 0 = at once
# @param LEASE_INTERMITTENT (optional) - fleet mode: boxes, comma-separated, that lose power routinely (a laptop): a listed box never hands back by rank, it takes a role only when empty or stale (env or lease.conf)
# @param LEASE_DESK_GATE / LEASE_DESK_DIR (optional) - fleet mode: 0 turns off the desk gate of the dispatch role (spec 092 FR-002); LEASE_DESK_DIR replaces the desk dir it reads (default <state>/desk/LEASE_TENANT/LEASE_DESK_BOX)
# @param LEASE_HEALTH (optional) - fleet mode: 0 turns off the beat-health demotion (t1 3cfc236e): a box whose hub beats are degraded, or were within the hold-down (cnf env.box.health, lib/bash/funcs/spl-box-health.func.sh), ranks last for both roles; LEASE_HEALTH_TTL (default 60 s) is how often the beats are read; LEASE_BEATS_CMD (tests) replaces the read (with the LEASE_HUB_CMD stub and no LEASE_BEATS_CMD there is none)
# @param LEASE_ALERT (optional) - fleet mode: 0 turns off the bench alert (t1 3cfc236e): one line in LEASE_TENANT's #alerts when a box is benched (beats degraded) or back (healthy for the hold-down), posted by one box only (the first healthy box of the orch order that is not the box itself); LEASE_ALERT_CMD (tests) replaces the post, the text on stdin
# @param LEASE_ENV / LEASE_TENANT / LEASE_DESK_BOX (optional) - fleet mode: the hub env, the tenant holding the lease, the pinned desk box whose key signs the calls (default spl_desk_box_default: SPOOL_DESK_BOX, else box-desk)
# @example LEASE_CMD=show ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=watch LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003 ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease
#------------------------------------------------------------------------------
# this machine's desk box id (specs/058), also when sourced on its own
declare -F spl_desk_box_default >/dev/null ||
  source "${BASH_SOURCE[0]%/*}/../../../lib/bash/funcs/spl-desk-box.func.sh"
# the role seat list (SPL_ROLE_SEAT_RX), its one home
[[ -n "${SPL_ROLE_SEAT_RX:-}" ]] ||
  source "${BASH_SOURCE[0]%/*}/../features/spawn-agents/lib/spool-env.inc.sh"
SPL_BOX_HEALTH_SRC="${BASH_SOURCE[0]%/*}/../../../lib/bash/funcs/spl-box-health.func.sh"
declare -F spl_box_health_verdicts >/dev/null ||
  source "${BASH_SOURCE[0]%/*}/../../../lib/bash/funcs/spl-box-health.func.sh"

do_spl_dispatch_lease() {
  spl_lease_init || return 1
  case "${LEASE_CMD:-}" in
    show)   spl_lease_show ;;
    renew)  spl_lease_ids master || return 1; spl_lease_loop renew ;;
    watch)  spl_lease_ids master failover orch || return 1; spl_lease_loop watch ;;
    ensure) spl_lease_ensure ;;
    stop)   spl_lease_stop ;;
    fleet)  spl_lease_ids master failover orch && spl_fleet_ids || return 1; spl_fleet_hub_init || return 1; spl_lease_loop fleet ;;
    fleet-show) spl_fleet_ids || return 1; spl_fleet_hub_init || return 1; spl_fleet_show ;;
    *) do_log "FATAL LEASE_CMD must be show, renew, watch, fleet, fleet-show, ensure or stop, got: '${LEASE_CMD:-}'"; return 1 ;;
  esac
}

# The lease dir and its files ("ro": do not create the dir); LEASE_NOW (an epoch) and LEASE_PROC_ROOT (a
# fake /proc) exist for the tests only.
spl_lease_init() {
  LEASE_DIR="${SPOOL_ROOT:-/var/spool-hub}/dispatch"
  LEASE_FILE="$LEASE_DIR/lease"
  LEASE_LOG="$LEASE_DIR/lease.log"
  LEASE_CONF="$LEASE_DIR/lease.conf"
  LEASE_PERIOD="${LEASE_PERIOD:-60}"
  LEASE_STALE="${LEASE_STALE:-180}"
  [[ "$LEASE_PERIOD" =~ ^[1-9][0-9]*$ && "$LEASE_STALE" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL LEASE_PERIOD and LEASE_STALE must be positive integers"; return 1; }
  [[ "${1:-}" == ro ]] && return 0
  mkdir -p "$LEASE_DIR" || { do_log "FATAL cannot create $LEASE_DIR"; return 1; }
}

# The test workspaces nobody dispatches to or sweeps: ONE list, shared by
# do_spl_unanswered_sweep and the dispatch actions. The ids in
# SWEEP_SKIP_TENANTS (default e2e) plus <spool root>/dispatch/test-workspaces
# (one id per line, # comments), printed space-separated.
spl_test_workspaces() {
  local f="${SPOOL_ROOT:-/var/spool-hub}/dispatch/test-workspaces"
  # shellcheck disable=SC2086 # a space-separated list, split on purpose
  { printf '%s\n' ${SWEEP_SKIP_TENANTS-e2e}; [[ -f "$f" ]] && sed 's/#.*//' "$f"; } |
    tr -s ' \t' '\n\n' | grep -E '^[A-Za-z0-9_-]+$' | sort -u | tr '\n' ' '
}

# 0 when workspace <id> is a test one: on that list, or its id matches
# SWEEP_SKIP_RE (the sweep's default).
spl_test_workspace() {
  local re="${SWEEP_SKIP_RE-(^|[-_ ])(e2e|test|proof)([-_ ]|$)}"
  [[ " $(spl_test_workspaces) " == *" $1 "* ]] && return 0
  [[ -n "$re" ]] && grep -qiE -- "$re" <<<"$1"
}

# KEY=value from lease.conf for the ids not already in the environment. Read,
# never sourced: the file sits in a dir every agent on the box may write.
spl_lease_conf() {
  local k v
  [[ -f "$LEASE_CONF" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      LEASE_MASTER|LEASE_FAILOVER|LEASE_ORCH|LEASE_FLEET|LEASE_MACHINE|LEASE_PRIORITY|LEASE_PRIORITY_ORCH|LEASE_PRIORITY_DISPATCH|LEASE_ENV|LEASE_TENANT|LEASE_DESK_BOX|LEASE_INTERMITTENT|LEASE_HOLDDOWN|LEASE_ORCH_FALLBACK|LEASE_DISPATCH_FALLBACK|LEASE_VENDOR_ORDER|LEASE_FALLBACK_WAIT|LEASE_PIN_TTL)
        [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v" ;;
    esac
  done < <(grep -E '^LEASE_(MASTER|FAILOVER|ORCH)=[A-Za-z0-9_-]+$|^LEASE_(FLEET|MACHINE|ENV|TENANT|DESK_BOX)=[a-z0-9][a-z0-9-]*$|^LEASE_PRIORITY(_ORCH|_DISPATCH)?=[a-z0-9][a-z0-9,-]*$|^LEASE_INTERMITTENT=[a-z0-9][a-z0-9,-]*$|^LEASE_HOLDDOWN=[0-9]+$|^LEASE_(ORCH|DISPATCH)_FALLBACK=[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$|^LEASE_VENDOR_ORDER=[a-z0-9]+(,[a-z0-9]+)*$|^LEASE_(FALLBACK_WAIT|PIN_TTL)=[0-9]+$' "$LEASE_CONF")
  return 0
}

# Require the named ids (master failover orch); each must be a plain agent id.
spl_lease_ids() {
  spl_lease_conf
  local n var
  for n in "$@"; do
    var="LEASE_${n^^}"
    [[ "${!var:-}" =~ ^[A-Za-z0-9_-]+$ ]] ||
      { do_log "FATAL $var is not set (env or $LEASE_CONF)"; return 1; }
  done
}

spl_lease_now() { echo "${LEASE_NOW:-$(date +%s)}"; }

# Monotonic seconds since boot (/proc/uptime), which a wall-clock step never
# moves. LEASE_MONO fakes it in tests; a test that sets only LEASE_NOW gets
# that fake clock for both.
spl_lease_mono() {
  local up=""
  [[ -n "${LEASE_MONO:-}" ]] && { echo "$LEASE_MONO"; return 0; }
  [[ -n "${LEASE_NOW:-}" ]] && { echo "$LEASE_NOW"; return 0; }
  read -r up _ < /proc/uptime 2>/dev/null || true
  echo "${up%.*}"
}

# The local-mode lease age in s, for the watch (after spl_lease_read). LT is a
# wall-clock epoch, so a clock step made the plain "now - LT" lie: +300 s
# promoted a renewing master's failover, -600 s delayed a real failover 600 s
# (SPL-2139 drill, SPL-2704). The watch keeps the age on the monotonic clock
# in <lease dir>/watch.seen: "<holder> <epoch> <mono at age 0> <mono of the
# look> <btime>". The same lease as at the last look ages by the monotonic
# time since it; a lease written since the last look is at most that old, so
# its wall age is cut to that (and a negative one to 0). No usable last look
# (the first tick, a reboot, no monotonic clock): the wall age, never below 0.
spl_lease_local_age() {
  local f="$LEASE_DIR/watch.seen" mono bt age sh="" st="" sb="" sl="" sbt=""
  age=$(( $(spl_lease_now) - LT )); (( age < 0 )) && age=0
  mono="$(spl_lease_mono)"
  [[ "$mono" =~ ^[0-9]+$ ]] || { echo "$age"; return 0; }
  bt="$(awk '$1 == "btime" {print $2}' "${LEASE_PROC_ROOT:-/proc}/stat" 2>/dev/null)"
  [[ -s "$f" ]] && read -r sh st sb sl sbt < "$f"
  if [[ "$sb" =~ ^-?[0-9]+$ && "$sl" =~ ^[0-9]+$ && "$sbt" == "${bt:-0}" ]] && (( sl <= mono )); then
    if [[ "$sh $st" == "$LH $LT" ]]; then age=$(( mono - sb ))
    elif (( age > mono - sl )); then age=$(( mono - sl ))
    fi
  fi
  printf '%s %s %s %s %s\n' "$LH" "$LT" "$(( mono - age ))" "$mono" "${bt:-0}" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  echo "$age"
}

# Sets LH (holder) and LT (epoch); no lease reads as "none 0".
spl_lease_read() {
  LH=none LT=0
  [[ -s "$LEASE_FILE" ]] && read -r LH LT < "$LEASE_FILE"
  [[ "$LT" =~ ^[0-9]+$ ]] || LT=0
  return 0
}

# 0 when the dispatch lease is held on ANOTHER machine. Fleet mode mirrors
# every holder as <ID>@<box> (an unreachable hub as none@unreachable); this
# machine's box is LEASE_MACHINE, else its desk box id. The sweep and the gap
# notes then stay silent - the holder's own machine sends them. Needs
# spl_lease_read (and spl_lease_conf) first.
spl_lease_remote() {
  [[ "$LH" == *@* && "${LH##*@}" != "${LEASE_MACHINE:-$(spl_desk_box_default)}" ]]
}

# The holder's bare agent id (<ID>@<box> -> <ID>; a bare id is itself).
spl_lease_holder_id() { echo "${LH%@*}"; }

spl_lease_write() {
  printf '%s %s\n' "$1" "$(spl_lease_now)" > "$LEASE_FILE.tmp.$$" && mv -f "$LEASE_FILE.tmp.$$" "$LEASE_FILE"
}

spl_lease_log() { echo "$(date -u +%FT%TZ) $*" >> "$LEASE_LOG"; }

# A spool note on task dispatch-lease. LEASE_SEND replaces the sender in tests.
spl_lease_tell() {
  local to="$1"; shift
  local send="${LEASE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  local rc=0
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$LEASE_ORCH" --to "$to" \
    --kind note --task dispatch-lease --body "$*" >/dev/null 2>&1 8>&- || rc=$?
  # spool-send.sh: 1-9 = delivered, only the poke did not ring (e.g. 6, the
  # pane holds unsent text); 10+ = nothing delivered
  (( rc >= 10 || rc == 2 )) && spl_lease_log "WARN could not tell $to (spool-send exit $rc)"
  return 0
}

# The owner hop for an agent that runs as another user (lib/proc-owner.inc.sh,
# CLE-77907): its environ is unreadable to the box user. Missing lib (a copied
# tree) = no hop, the readable processes still count.
# shellcheck source=../features/spawn-agents/lib/proc-owner.inc.sh
. "${BASH_SOURCE[0]%/*}/../features/spawn-agents/lib/proc-owner.inc.sh" 2>/dev/null || true

# The pid of a live agent process (claude, grok, agy or vibe, spec 134 P0;
# agy since SPL-2521, the last step of the vendor fallback) whose
# environment carries SPOOL_AGENT_ID=<id>; empty when there is none. vibe
# renames itself "Vibe CLI" (setproctitle). The lowest pid wins, so two reads
# in a row agree. An agent of another user (the agent user) is read through
# its owner, one hop for all of them.
spl_lease_agent_pid() {
  local id="$1" root="${LEASE_PROC_ROOT:-/proc}" d pid comm
  local -a other=()
  {
    for d in "$root"/[0-9]*; do
      pid="${d##*/}"
      # `read`, not $(cat): a builtin, so the walk forks only for the few
      # agent processes (measured 2026-10-01: one fork per pid made a tick 26 s)
      comm=""; { read -r comm < "$d/comm"; } 2>/dev/null
      case "$comm" in claude|grok|agy|vibe|"Vibe CLI") ;; *) continue ;; esac
      if [[ -r "$d/environ" ]]; then
        grep -qzx "SPOOL_AGENT_ID=$id" "$d/environ" 2>/dev/null && echo "$pid"
      else
        other+=("$pid")
      fi
    done
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" | awk -v id="$id" '$2 == id {print $1}'
    fi
  } | sort -n | sed -n 1p
}

# The SPOOL_AGENT_ID of every live process on this box that carries one,
# one per line - any agent kind (an agy or grok agent is not a claude process).
# For the dead-subscription REPORT; the lease itself counts claude, grok and vibe.
# mapfile, not tr/grep: a builtin, so the walk does not fork per process.
# Another user's process: only its agent CLIs (comm claude/grok/agy/qwen/vibe/node,
# and "Vibe CLI": vibe renames itself with setproctitle, spawn-mistral.sh)
# go through the owner hop.
spl_lease_live_ids() {
  local root="${LEASE_PROC_ROOT:-/proc}" d e comm
  local -a env other=()
  {
    for d in "$root"/[0-9]*; do
      env=()
      if [[ ! -r "$d/environ" ]]; then
        comm=""; { read -r comm < "$d/comm"; } 2>/dev/null
        case "$comm" in claude|grok|agy|qwen|vibe|node|bun|"Vibe CLI") other+=("${d##*/}") ;; esac
        continue
      fi
      { mapfile -d '' -t env < "$d/environ"; } 2>/dev/null || continue
      for e in "${env[@]}"; do
        [[ "$e" == SPOOL_AGENT_ID=* ]] && { echo "${e#SPOOL_AGENT_ID=}"; break; }
      done
    done
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" | awk '{print $2}'
    fi
  } | sort -u
}

# A live process is not enough (CLE-77935): on 2026-10-02 the master sat on
# "Usage limit reached ... Continuing automatically at 7:20am" with an owner
# post in its prompt while the lease stayed fresh every minute, so the 180 s
# failover never fired. The agent must also be ABLE to act, read from the
# footer of its tmux pane (the last LEASE_PANE_TAIL non-blank lines of the
# visible screen). Three tiers:
# - a DISMISSABLE modal (the list in spl_lease_modal_res) blocks the seat
#   on sight. The able check presses Escape once (cancel: nothing chosen),
#   waits LEASE_MODAL_WAIT seconds (default 3) and reads the pane again.
#   Still matching: not able, so the lease can fail over, and the
#   orchestrator (LEASE_ORCH) is told once. An entry is a title regex and,
#   after a tab, an optional option-line regex. The title and the option
#   must each be their own line (the rest of the line has no letters), within
#   16 lines of each other. A line above a trailing idle prompt is the
#   transcript, not the dialog: on 2026-10-04 a mention of the title in an
#   agent's own text matched, and Escape interrupted that turn. The default
#   entry is the offer "Teach auto mode about your environment?" with the
#   picker lines "Not now" and "Don't show again" (Claude Code 2.1.287).
#   Append a line to recognise another. The offer and the
#   command are turned off by skillOverrides "auto-mode-setup" = "off"
#   (Claude Code docs, auto-mode-config, section "Turn off
#   /auto-mode-setup", read 2026-10-04,
#   https://code.claude.com/docs/en/auto-mode-config). disableBundledSkills
#   does not turn this command off. That page documents no environment
#   variable for the offer.
# - a MODAL screen (LEASE_BLOCK_RE: trust, onboarding, login picker) blocks
#   every key, so it is a stall on sight; Escape is not sent (it can
#   choose "No, exit");
# - a BANNER (LEASE_STALL_RE: usage limit, /login, invalid key) is only a
#   hint: claude leaves it under the prompt after it resumes (a false positive
#   at 04:09Z, the master working under it). It counts only while a turn is in
#   progress (the spinner "<verb>… (12s · ↓ 214 tokens)") whose text has not
#   changed for LEASE_STALL_FROZEN s: a working turn's timer moves every
#   second; at 03:54Z it read "(12s" 26 min into the stall. Idle under the
#   banner (a "<verb>ed for 16s" line, no spinner) is able ...
# - ... UNLESS the banner's reset time still lies ahead (owner t1 865b7a05):
#   on 2026-10-03 every seat of the satellite sat idle on "Usage limit
#   reached · resets 10:50am" from ~05:5xZ to 07:50Z, each poke answered by
#   the banner and no spinner, so both roles stayed there ~30 min until a human
#   moved the ranks. An idle seat whose reset has not passed is a stall on
#   sight (spl_lease_limit_until); a reset already passed is the stale banner.
# - ... and a banner with NO reset time is a stall with no spinner too (spec
#   093 FR-000): on 2026-10-05 a seat's login expired and it answered every
#   poke with "Login expired · Please run /login" for ~6 h, idle, no spinner,
#   no reset, so it stayed able. The tie-breaker against a stale banner is the
#   transcript's last assistant entry (spl_lease_last_turn): a real reply
#   after the banner = able; an isApiErrorMessage one, or none readable = stall.
# Prints the matched text when stalled, nothing otherwise. Fails OPEN: no
# pane found (no tmux, an agent outside tmux) keeps the process-only rule, so
# a missing tmux never drops a master.
LEASE_BLOCK_RE_DEFAULT='select login method|do you trust the files|choose the text style'
# "You've hit your session limit · resets 8:20pm (Europe/Helsinki)" is claude's
# wording since 2026-10-10 (every seat of one box at ~15:09Z): the watchdog's
# WD_STALL_RE alternative, so both read the same banner.
LEASE_STALL_RE_DEFAULT='usage limit reached|limit reached[[:space:]]*·|limit resets|(you[^[:space:]]* )?hit your ([a-z]+ )?limit|please run /login|invalid api key|oauth token (has )?expired'

# One entry per line from the modal list. Blank lines and '#' lines are
# skipped. An entry is a title regex, then an optional tab and an option-line
# regex. Unset LEASE_MODAL_RES uses the here-doc; set it (even to empty) to
# replace the list.
spl_lease_modal_res() {
  local src line
  if [[ -n "${LEASE_MODAL_RES+x}" ]]; then
    src="$LEASE_MODAL_RES"
  else
    src="$(cat <<'EOF'
teach auto mode about your environment	not now|don't show again
EOF
)"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    printf '%s\n' "$line"
  done <<<"$src"
}

# 0 when <line> contains <re> and the rest of the line has no letters:
# a dialog line, not a sentence that mentions the same words. Prints the match.
spl_lease_modal_line() {
  local re="$1" line="$2" shown rest
  shown="$(grep -oiE -m1 -- "$re" <<<"$line" | sed -n 1p)" || true
  [[ -n "$shown" ]] || return 1
  rest="${line/"$shown"/}"
  if grep -q '[[:alpha:]]' <<<"$rest"; then
    return 1
  fi
  printf '%s\n' "$shown"
  return 0
}

# 0 when <line> is a composer prompt. A numbered option cursor ("1. Yes")
# is not the composer. The glyph is matched as text, so the locale cannot
# split it into bytes.
spl_lease_modal_composer() {
  local s="$1" trim rest num='^[0-9]+[.)]([[:space:]]|$)'
  trim="${s#"${s%%[![:space:]]*}"}"
  trim="${trim%"${trim##*[![:space:]]}"}"
  rest=""
  case "$trim" in
    $'\u276f'|$'\u203a'|'>') ;;
    $'\u276f'\ *) rest="${trim#$'\u276f' }" ;;
    $'\u203a'\ *) rest="${trim#$'\u203a' }" ;;
    '> '*) rest="${trim#'> '}" ;;
    *) return 1 ;;
  esac
  [[ -n "$rest" && "$rest" =~ $num ]] && return 1
  return 0
}

# Index of a trailing idle prompt, or -1. It counts only in the last 8
# non-blank lines: that is the composer at the bottom of an idle pane.
spl_lease_modal_floor() {
  local -a lines=("$@")
  local i n=${#lines[@]} nb=0 s
  for ((i = n - 1; i >= 0; i--)); do
    s="${lines[i]}"
    [[ "$s" =~ [^[:space:]] ]] || continue
    nb=$((nb + 1))
    if spl_lease_modal_composer "$s"; then
      if (( nb <= 8 )); then
        printf '%s\n' "$i"
        return 0
      fi
      break
    fi
    if (( nb >= 8 )); then
      break
    fi
  done
  printf '%s\n' "-1"
  return 0
}

# 0 when an option line of <opt> sits within 16 lines of <idx>, and below
# a trailing idle prompt (<floor>).
spl_lease_modal_near() {
  local opt="$1" idx="$2" floor="$3"
  shift 3
  local -a lines=("$@")
  local j lo hi n=${#lines[@]}
  lo=$((idx - 16))
  (( lo < 0 )) && lo=0
  if (( floor >= 0 && lo <= floor )); then
    lo=$((floor + 1))
  fi
  hi=$((idx + 16))
  (( hi >= n )) && hi=$((n - 1))
  (( lo > hi )) && return 1
  for ((j = lo; j <= hi; j++)); do
    spl_lease_modal_line "$opt" "${lines[j]}" >/dev/null && return 0
  done
  return 1
}

# The first dismissable-modal match in <text>; nothing when none match.
# A transcript mention of the title is not a match.
spl_lease_modal_hit() {
  local text="$1" entry title opt floor i n shown
  local -a lines=()
  mapfile -t lines <<<"$text"
  n=${#lines[@]}
  floor="$(spl_lease_modal_floor "${lines[@]}")"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    title="${entry%%$'\t'*}"
    opt=""
    [[ "$entry" == *$'\t'* ]] && opt="${entry#*$'\t'}"
    for ((i = 0; i < n; i++)); do
      if (( floor >= 0 && i <= floor )); then
        continue
      fi
      if ! shown="$(spl_lease_modal_line "$title" "${lines[i]}")"; then
        continue
      fi
      if [[ -n "$opt" ]] && ! spl_lease_modal_near "$opt" "$i" "$floor" "${lines[@]}"; then
        continue
      fi
      printf '%s\n' "$shown"
      return 0
    done
  done < <(spl_lease_modal_res)
  return 0
}

# Escape once on a dismissable modal, then re-read. A pane that still matches
# stays marked so a later tick does not press again, and the orchestrator is
# told once. A cleared pane drops the mark. LEASE_KEYS_CMD "<pid>" replaces
# tmux in tests, so a test never presses a live pane.
spl_lease_dismiss_modal() {
  local id="$1" pid="$2" pause="${LEASE_MODAL_WAIT:-3}"
  [[ "$pause" =~ ^[0-9]+$ ]] || pause=3
  (
    flock -w "$((pause + 5))" 9 || exit 0
    local foot hit hit2 marker="$LEASE_DIR/modal.$pid"
    foot="$(spl_lease_pane_text "$pid" 2>/dev/null)" || { rm -f "$marker"; exit 0; }
    hit="$(spl_lease_modal_hit "$foot")"
    if [[ -z "$hit" ]]; then rm -f "$marker"; exit 0; fi
    if [[ -f "$marker" ]] && [[ "$(cat "$marker" 2>/dev/null)" == "$hit" ]]; then exit 0; fi
    spl_lease_send_esc "$pid"
    printf '%s\n' "$hit" > "$marker"
    sleep "$pause"
    foot="$(spl_lease_pane_text "$pid" 2>/dev/null)" || exit 0
    hit2="$(spl_lease_modal_hit "$foot")"
    if [[ -z "$hit2" ]]; then rm -f "$marker"; exit 0; fi
    printf '%s\n' "$hit2" > "$marker"
    spl_lease_log "MODAL $id pid=$pid still blocked after one Esc: $hit2"
    [[ -n "${LEASE_ORCH:-}" ]] || exit 0
    spl_lease_tell "$LEASE_ORCH" "DISPATCH LEASE: $id pid=$pid is blocked by a modal ($hit2). Escape was sent once (cancel, nothing chosen) and the dialog is still there, so the seat is not able and the lease can fail over."
  ) 9>"$LEASE_DIR/modal.lock"
}

spl_lease_stall() {
  local pid="$1" text foot hit spin f st="" sat=0 now until
  text="$(spl_lease_pane_text "$pid" 2>/dev/null)" || return 0
  hit="$(spl_lease_modal_hit "$text")"
  [[ -n "$hit" ]] && { printf '%s\n' "$hit"; return 0; }
  foot="$(grep -v '^[[:space:]]*$' <<<"$text" | tail -n "${LEASE_PANE_TAIL:-12}")"
  hit="$(grep -oiE -m1 -- "${LEASE_BLOCK_RE:-$LEASE_BLOCK_RE_DEFAULT}" <<<"$foot" | sed -n 1p)"
  [[ -n "$hit" ]] && { echo "$hit"; return 0; }
  hit="$(grep -oiE -m1 -- "${LEASE_STALL_RE:-$LEASE_STALL_RE_DEFAULT}" <<<"$foot" | sed -n 1p)"
  f="$LEASE_DIR/spin.$pid"
  # the spinner's "(...)" only: its glyph and verb cycle while frozen
  spin="$(grep -oE -- '…[[:space:]]*\([0-9][^)]*\)' <<<"$foot" | tail -1 | grep -oE '\(.*\)')"
  if [[ -n "$hit" && -z "$spin" ]]; then
    rm -f "$f"; until="$(spl_lease_limit_until "$foot")"
    [[ -n "$until" ]] && { echo "$hit, resets in $(( (until - $(spl_lease_now) + 59) / 60 )) min"; return 0; }
    # a reset time already passed: the stale usage-limit banner, able as before
    grep -iE -- 'limit|continuing automatically' <<<"$foot" |
      grep -iE -- '(resets|automatically)([[:space:]]+at)?[[:space:]]+[^·[:space:]]' >/dev/null && return 0
    # no reset time (spec 093 FR-000: the 2026-10-05 login screen): a stall,
    # unless the transcript's last turn is a good one (a stale banner)
    [[ "$(spl_lease_last_turn "$pid")" == ok ]] && return 0
    echo "$hit, no spinner"
    return 0
  fi
  [[ -n "$hit" && -n "$spin" ]] || { rm -f "$f"; return 0; }
  now="$(spl_lease_now)"
  [[ -f "$f" ]] && IFS=$'\t' read -r sat st < "$f"
  # unchanged since <sat>: keep the first sighting's time (the able check
  # runs several times per tick, so "same as last call" is no proof)
  [[ "$st" == "$spin" && "$sat" =~ ^[0-9]+$ ]] || { printf '%s\t%s\n' "$now" "$spin" > "$f"; return 0; }
  (( now - sat >= ${LEASE_STALL_FROZEN:-45} )) && echo "$hit, turn frozen $((now - sat))s at $spin"
  return 0
}

# The epoch the usage limit in <footer> resets at, when that is still ahead;
# nothing for a reset already passed (a stale banner) or one it cannot read.
# The CLI prints the reset in the agent's local time ("resets 10:50am",
# "resets at 7pm (Europe/Helsinki)", "resets Oct 6, 10am", "Continuing
# automatically at 7:20am"); the zone is the one in parentheses, else
# LEASE_LIMIT_TZ, else this box's. A time with no date is today's, else
# tomorrow's, and counts only within LEASE_LIMIT_WINDOW s (5 h 5 min, the
# session window): 10:50am read at 10:51 is the passed one, not tomorrow's.
spl_lease_limit_until() {
  local s tz now t win="${LEASE_LIMIT_WINDOW:-18300}"
  local -a dt=(date)
  s="$(grep -iE -- 'limit|continuing automatically' <<<"$1" |
    grep -oiE -- '(resets|automatically)([[:space:]]+at)?[[:space:]]+[^·]+' | sed -n 1p)"
  s="$(sed -E 's/^[A-Za-z]+([[:space:]]+at)?[[:space:]]+//' <<<"$s")"
  tz="$(grep -oE '\([A-Za-z_]+(/[A-Za-z_+-]+)*\)' <<<"$s" | tr -d '()')"
  s="$(sed -E 's/\([^)]*\)//g; s/,/ /g; s/[[:space:]]+at[[:space:]]+/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//' <<<"$s")"
  [[ -n "$s" ]] || return 0
  tz="${tz:-${LEASE_LIMIT_TZ:-}}"
  [[ -n "$tz" ]] && dt=(env TZ="$tz" date)
  now="$(spl_lease_now)"
  if grep -qiE '^[0-9]{1,2}(:[0-9]{2})? ?([ap]m)?$' <<<"$s"; then
    t="$("${dt[@]}" -d "$("${dt[@]}" -d "@$now" +%F) $s" +%s 2>/dev/null)" || return 0
    (( t <= now )) && t=$((t + 86400))
    (( t - now <= win )) && echo "$t"
  else
    t="$("${dt[@]}" -d "$s" +%s 2>/dev/null)" || return 0
    (( t > now )) && echo "$t"
  fi
  return 0
}

# tmux for this lease. LEASE_TMUX_SOCKET keeps it off the shared config.
spl_lease_tmux() {
  if [[ -n "${LEASE_TMUX_SOCKET:-}" ]]; then
    tmux -S "$LEASE_TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

# The pane id whose pane_pid is <pid> or one of its ancestors. Non-zero = none.
spl_lease_pane_id() {
  local root="${LEASE_PROC_ROOT:-/proc}" panes pane="" p="$1" stat i
  command -v tmux >/dev/null || return 1
  panes="$(spl_lease_tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)" || return 1
  for ((i = 0; i < 8; i++)); do
    pane="$(awk -v p="$p" '$1 == p {print $2; exit}' <<<"$panes")"
    [[ -n "$pane" ]] && { printf '%s\n' "$pane"; return 0; }
    # /proc/<pid>/stat: "pid (comm) state ppid ..."; comm may hold spaces
    stat=""; { read -r stat < "$root/$p/stat"; } 2>/dev/null
    stat="${stat##*) }"; read -r _ p _ <<<"$stat"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || return 1
  done
  return 1
}

# The visible screen of the tmux pane that runs <pid>: the pane whose
# pane_pid is <pid> or one of its ancestors (two panes may carry an agent's
# name; only the one it runs in counts). LEASE_PANE_CMD (called with the pid)
# replaces it in the tests. Non-zero = no pane.
spl_lease_pane_text() {
  local pane
  # shellcheck disable=SC2086 # a command line, split on purpose
  [[ -n "${LEASE_PANE_CMD:-}" ]] && { $LEASE_PANE_CMD "$1"; return; }
  pane="$(spl_lease_pane_id "$1")" || return 1
  spl_lease_tmux capture-pane -p -t "$pane" 2>/dev/null
}

# Escape to the pane of <pid>. LEASE_KEYS_CMD "<pid>" replaces tmux in tests.
# A stubbed screen (LEASE_PANE_CMD) with no keys command presses nothing, so
# a test cannot hit a live pane.
spl_lease_send_esc() {
  local pid="$1" pane
  if [[ -n "${LEASE_KEYS_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $LEASE_KEYS_CMD "$pid"
    return 0
  fi
  [[ -n "${LEASE_PANE_CMD:-}" ]] && return 0
  pane="$(spl_lease_pane_id "$pid" 2>/dev/null)" || return 0
  [[ -n "$pane" ]] || return 0
  spl_lease_tmux send-keys -t "$pane" Escape
}

# The pid of <id> when it is live AND able to act (spl_lease_stall); empty
# otherwise. A dismissable modal is Escape once, then re-checked, before
# that verdict. Why not is left in $LEASE_DIR/able.<id> for the loggers.
# Spec 093 P1 (section 9): the watchdog's verdict $LEASE_DIR/wd.<id>
# ("HIT <code> <epoch>" or "OK <epoch>") is read too; a HIT at most
# WD_FRESH s (default 90) old is "wd <code>"; an older one, an OK or no file
# changes nothing. With "fleet" (spl_fleet_try) a live able seat is also
# tested for stuck (spl_fleet_stuck), and a change of the verdict is logged.
spl_lease_agent_able() {
  local id="$1" pid why
  pid="$(spl_lease_agent_pid "$id")"
  if [[ -z "$pid" ]]; then why="no live process"
  else why="$(spl_lease_agent_why "$id" "$pid" dismiss)"
    [[ -z "$why" && "${2:-}" == fleet ]] && why="$(spl_fleet_stuck "$id" "$pid")" && [[ -n "$why" ]] && why="stuck pid=$pid: $why"
  fi
  if [[ "${2:-}" == fleet ]]; then spl_lease_able_write "$id" "${why:-able}"
  else printf '%s\n' "${why:-able}" > "$LEASE_DIR/able.$id" 2>/dev/null
  fi
  [[ -z "$why" ]] && echo "$pid"
  return 0
}

# spl_lease_able_write <id> <why>: able.<id> holds the latest verdict, each
# tick overwrites it; a change of verdict, its digits aside (a growing age is
# no change), is logged once (SPL-3069: on 2026-10-23 the why of the 13:32Z
# and 13:35Z not-able ticks was gone a tick later). A first "able" is no news.
spl_lease_able_write() {
  local f="$LEASE_DIR/able.$1" old=""
  read -r old 2>/dev/null < "$f" || true
  printf '%s\n' "$2" > "$f" 2>/dev/null
  [[ "${old//[0-9]/}" == "${2//[0-9]/}" || ( -z "$old" && "$2" == able ) ]] ||
    spl_lease_log "ABLE $1: $2 (was: ${old:-unknown})"
}

# Why the live <pid> of <id> cannot act; nothing when it can: a rotation
# hold, a fresh watchdog HIT, else its pane (spl_lease_stall). With "dismiss"
# a dismissable modal is Escaped once first (the lease); without it no key is
# ever pressed (the agent run report).
spl_lease_agent_why() {
  local id="$1" pid="$2" dismiss="${3:-}" why wd=() wd_age=-1
  read -r -a wd 2>/dev/null < "$LEASE_DIR/wd.$id" || true
  [[ "${wd[0]:-}" == HIT && "${wd[2]:-}" =~ ^[0-9]+$ ]] && wd_age=$(( $(spl_lease_now) - wd[2] ))
  if why="$(spl_lease_held "$id")" && [[ -n "$why" ]]; then :
  elif (( wd_age >= 0 && wd_age <= ${WD_FRESH:-90} )); then why="wd ${wd[1]:-?}: HIT ${wd_age}s ago"
  else
    [[ "$dismiss" == dismiss ]] && spl_lease_dismiss_modal "$id" "$pid"
    why="$(spl_lease_stall "$pid")"
    [[ -n "$why" ]] && why="stalled pid=$pid: $why"
  fi
  printf '%s' "$why"
}

# The agent run report (t1 bc1a43e1, fix A): which agents on this machine
# really run, so the hub stops showing an agent green just because its box's
# desk socket is up. One line per SPOOL_AGENT_ID that has a live process
# (spl_lease_live_ids, any agent kind): "<id> TAB run", or "<id> TAB stop TAB
# <why>" when its claude process cannot act (spl_lease_agent_why, the lease's
# own test, never pressing a key). An id with no line has no process. Written
# whole (tmp + mv) to $LEASE_DIR/agent-run.tsv; every desk sidecar reads it
# through SPOOL_FLEET_ROOT (hubclient/agent_run.go) and sends it on its hello
# and announce; a report older than 5 min is ignored there.
#
# Each report also appends "<epoch> <id> run|stop" per line to the UTC day
# log agent-run-<day>.log beside it (spec 123 4.3, do_spl_cost_agent_hours_read).
spl_lease_agent_run_report() {
  local out="$LEASE_DIR/agent-run.tsv" id pid why now
  now="$(spl_lease_now)"
  {
    echo "# agent-run v1 $now"
    while IFS= read -r id; do
      [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
      pid="$(spl_lease_agent_pid "$id")"
      why=""
      [[ -n "$pid" ]] && why="$(spl_lease_agent_why "$id" "$pid")"
      if [[ -z "$why" ]]; then printf '%s\trun\n' "$id"; else printf '%s\tstop\t%s\n' "$id" "${why//$'\t'/ }"; fi
    done < <(spl_lease_live_ids)
  } > "$out.$$" && mv -f "$out.$$" "$out" &&
    awk -v ts="$now" '!/^#/ {print ts, $1, $2}' "$out" >> "$LEASE_DIR/agent-run-$(date -u -d "@$now" +%F).log"
}

# The report on every watch / fleet tick, in its own process (one at a time,
# a slow pane read never delays the lease) with the loop's lock fds closed.
# LEASE_AGENT_RUN=0 turns it off (the tests' default, under SPOOL_TEST=1).
spl_lease_agent_run_tick() {
  local on="${LEASE_AGENT_RUN:-1}"
  [[ "${SPOOL_TEST:-0}" == 1 ]] && on="${LEASE_AGENT_RUN:-0}"
  [[ "$on" == 1 ]] || return 0
  ( ( flock -n 9 || exit 0; spl_lease_agent_run_report ) 9>"$LEASE_DIR/agent-run.lock" 7>&- 8>&- & ) 2>/dev/null
  return 0
}

# "held: rotation ..." while <dir>/rotate.hold ("<id> <epoch> [rid] [pid]") names <id> and is younger than
# ROTATE_HOLD_MAX s (default 1800): do_spl_dispatch_rotate is replacing that
# session by a fresh one, so every process of the id is off the lease and the
# failover acts (SPEC-spool-fleet-roles.md 4.4). An older hold is ignored,
# logged once: a crashed rotation never keeps a master off for good. A hold
# whose rotation is provably dead (spl_lease_hold_dead) is removed at once
# (20261008T1815Z-master: a reboot mid-rotation held c-002 for 30 min).
spl_lease_held() {
  local f="$LEASE_DIR/rotate.hold" hid ht hpid age line="" dead
  [[ -s "$f" ]] || return 0
  read -r line < "$f" 2>/dev/null || true
  read -r hid ht _ hpid _ <<< "$line"
  [[ "$hid" == "$1" && "$ht" =~ ^[0-9]+$ ]] || return 0
  if dead="$(spl_lease_hold_dead "$ht" "${hpid:-}")"; then
    [[ "$(cat "$f" 2>/dev/null)" == "$line" ]] && rm -f "$f" "$f.stale" &&
      spl_lease_log "WARN rotate.hold on $1 removed: $dead"
    return 0
  fi
  age=$(( $(spl_lease_now) - ht ))
  if (( age > ${ROTATE_HOLD_MAX:-1800} )); then
    [[ -f "$f.stale" ]] || { touch "$f.stale"; spl_lease_log "WARN rotate.hold on $1 is ${age}s old - ignored"; }
    return 0
  fi
  rm -f "$f.stale"
  echo "held: rotation since ${age}s"
}

# 0 + why when the rotation behind a hold written at <epoch> by <pid> cannot
# still run: the box booted after it (<proc>/stat btime), or <pid> (a real
# process: /proc, never the fake LEASE_PROC_ROOT) is gone. An old 3-field
# hold has no pid, so only the boot test applies to it.
spl_lease_hold_dead() {
  local ht="$1" pid="$2" bt
  bt="$(awk '$1 == "btime" {print $2}' "${LEASE_PROC_ROOT:-/proc}/stat" 2>/dev/null)"
  [[ "$bt" =~ ^[0-9]+$ ]] && (( bt > ht )) && { echo "the box booted after it (btime $bt > $ht)"; return 0; }
  [[ "$pid" =~ ^[0-9]+$ && ! -d "/proc/$pid" ]] && { echo "its rotation pid $pid is gone"; return 0; }
  return 1
}

# One renew tick. The bound pid lives in renew.<id>.pid so a rebind, a loss or
# a stall is logged once, not every tick. A stalled master is not renewed.
spl_lease_renew_tick() {
  local id="$LEASE_MASTER" state="$LEASE_DIR/renew.$LEASE_MASTER.pid" pid last="" why st
  [[ -f "$state" ]] && last="$(cat "$state")"
  pid="$(spl_lease_agent_able "$id")"
  if [[ -n "$pid" ]]; then
    spl_lease_locked spl_lease_write "$id"
    [[ "$pid" != "$last" ]] && { echo "$pid" > "$state"; spl_lease_log "renew bind $id pid=$pid"; }
  else
    why="$(cat "$LEASE_DIR/able.$id" 2>/dev/null)"
    st=gone; [[ "$why" == stalled* ]] && st=stalled; [[ "$why" == held* ]] && st=held
    if [[ "$st" != "$last" ]]; then
      echo "$st" > "$state"; spl_lease_log "renew stop $id (${why:-no live process})"
    fi
  fi
  return 0
}

# Runs "$@" holding the lease lock, so the watcher's read-then-refresh of the
# failover's lease can never overwrite a master renewal that lands between.
spl_lease_locked() {
  ( flock -w 10 9 || exit 1; "$@" ) 9> "$LEASE_DIR/lease.lock"
}

# One watch tick. Markers: lease.failover (the failover holds it, a handback
# is due when the master renews) and lease.nofailover (the master is silent and
# the failover has no live process either; logged once).
spl_lease_watch_tick() {
  local m="$LEASE_MASTER" f="$LEASE_FAILOVER" age fpid
  spl_lease_asks_tick
  spl_lease_agent_run_tick
  spl_lease_read
  age="$(spl_lease_local_age)"
  # a fresh lease ends a "nobody dispatches" episode, so the next one is logged
  (( age <= LEASE_STALE )) && rm -f "$LEASE_FILE.nofailover"
  if [[ "$LH" == "$m" ]]; then
    if [[ -f "$LEASE_FILE.failover" ]]; then
      rm -f "$LEASE_FILE.failover"; spl_lease_log "handback to $m"
      spl_lease_tell "$f" "DISPATCH LEASE: STANDBY - master $m is back and holds the lease. Finish the message in hand, then stop dispatching."
      spl_lease_tell "$LEASE_ORCH" "DISPATCH LEASE: master $m is back; $f is standby."
    fi
  fi
  if [[ "$LH" != "$f" && "$age" -gt "$LEASE_STALE" ]]; then
    fpid="$(spl_lease_agent_able "$f")"
    if [[ -n "$fpid" ]]; then
      spl_lease_locked spl_lease_promote "$m" "$f" "$age" || return 0
      rm -f "$LEASE_FILE.nofailover"
    elif [[ ! -f "$LEASE_FILE.nofailover" ]]; then
      touch "$LEASE_FILE.nofailover"
      spl_lease_log "NO-FAILOVER: $LH silent ${age}s and $f is not able to act ($(cat "$LEASE_DIR/able.$f" 2>/dev/null))"
      spl_lease_tell "$LEASE_ORCH" "DISPATCH LEASE: nobody dispatches - master $m silent ${age}s and failover $f is not able to act ($(cat "$LEASE_DIR/able.$f" 2>/dev/null))."
    fi
  elif [[ "$LH" == "$f" ]]; then
    # keep it fresh while the failover lives; a dead failover lets it go stale
    [[ -n "$(spl_lease_agent_able "$f")" ]] && spl_lease_locked spl_lease_refresh "$f"
  fi
  return 0
}

# Under the lock: re-read, and promote only if the lease is still stale.
spl_lease_promote() {
  local m="$1" f="$2" age
  spl_lease_read
  age="$(spl_lease_local_age)"
  [[ "$LH" != "$f" && "$age" -gt "$LEASE_STALE" ]] || return 1
  spl_lease_write "$f"; touch "$LEASE_FILE.failover"
  spl_lease_log "FAILOVER: $LH silent ${age}s -> $f active"
  spl_lease_tell "$f" "DISPATCH LEASE: you are now ACTIVE (master $m silent ${age}s). Dispatch, including $m's unread inbox (spool recv --as $m), until told STANDBY."
  spl_lease_tell "$LEASE_ORCH" "DISPATCH LEASE: failover $f took over; master $m silent ${age}s."
}

# Under the lock: refresh only while the failover still holds it.
spl_lease_refresh() {
  spl_lease_read
  [[ "$LH" == "$1" ]] && spl_lease_write "$1"
  return 0
}

spl_lease_show() {
  spl_lease_read
  local age=$(( $(spl_lease_now) - LT ))
  [[ "$LH" == none ]] && age=-1
  echo "$LH $age"
}

# The loop holds <verb>.run with flock for its whole life: that lock IS the
# "is it running" answer ensure reads, so a stale pid file cannot lie and a
# second copy exits at once. <verb>.ver records the code it runs, so ensure
# can replace a loop whose code trunk has since changed.
spl_lease_loop() {
  local verb="$1"
  exec 8> "$LEASE_DIR/$verb.run"
  # -w, not -n: a "is it running?" probe (spl_lease_running) holds the lock
  # for an instant, and a loop starting in that instant must not give up
  flock -w 2 8 || { do_log "INFO a $verb loop already runs - nothing to do"; return 0; }
  echo "$$" > "$LEASE_DIR/$verb.pid"
  spl_lease_code_ver > "$LEASE_DIR/$verb.ver"
  spl_lease_log "$verb start master=$LEASE_MASTER${LEASE_FAILOVER:+ failover=$LEASE_FAILOVER} pid=$$"
  while :; do
    "spl_lease_${verb}_tick"
    [[ -n "${LEASE_TICKS:-}" ]] && { LEASE_TICKS=$((LEASE_TICKS - 1)); (( LEASE_TICKS > 0 )) || break; }
    sleep "$(spl_lease_pause "$verb")"
  done
}

# Seconds to the next tick: LEASE_PERIOD, but LEASE_UNREACHABLE_RETRY (default
# 10, never above LEASE_PERIOD) while a fleet role's last hub call failed (its
# fleet.<role>.unreachable marker, cleared by the first good tick). A box back
# online renews within seconds, not a full period: a box on 2026-10-09 came back at
# 14:30:20Z, renewed at 14:31:28Z, and the standby had taken over at 14:30:50Z.
spl_lease_pause() {
  local retry="${LEASE_UNREACHABLE_RETRY:-10}"
  [[ "$retry" =~ ^[1-9][0-9]*$ ]] || retry=10
  (( retry > LEASE_PERIOD )) && retry="$LEASE_PERIOD"
  if [[ "$1" == fleet ]] && compgen -G "$LEASE_DIR/fleet.*.unreachable" >/dev/null; then echo "$retry"; else echo "$LEASE_PERIOD"; fi
}

# This file and the box health rule, as the loops run them; their hash is the code version. It also
# hashes lease.conf and this machine's desk box id: a loop reads them once at
# its start, so a changed priority, fleet or box name (the box-desk -> <box>
# rename of spec 058) makes ensure replace it on the next tick, with no manual
# restart and no loop left acting on the old settings.
SPL_LEASE_SRC="${BASH_SOURCE[0]}"
spl_lease_code_ver() {
  { cat "$SPL_LEASE_SRC" "$SPL_BOX_HEALTH_SRC"; cat "${LEASE_CONF:-/dev/null}" 2>/dev/null; spl_desk_box_default; } | sha1sum | cut -c1-12
}

# 0 when a <verb> loop holds its run lock.
spl_lease_running() {
  [[ -f "$LEASE_DIR/$1.run" ]] || return 1
  ! flock -n "$LEASE_DIR/$1.run" true
}

# Refuse to start loops from a tree whose lease code is not trunk's: a stale
# checkout would otherwise run old code for as long as nobody looks (the desk
# cron's checkout ran 27 commits behind for ~18 h on 2026-09-30). A tree that
# is not a git checkout, or has no LEASE_TRUNK_REF, is not judged.
# LEASE_ALLOW_STALE=1 overrides, for a deliberate test of unmerged code.
spl_lease_trunk_check() {
  local ref="${LEASE_TRUNK_REF:-origin/master}" dir rel mine theirs
  [[ "${LEASE_ALLOW_STALE:-0}" == 1 ]] && return 0
  dir="$(cd "$(dirname "$SPL_LEASE_SRC")" && pwd)"
  git -C "$dir" rev-parse --verify -q "$ref" >/dev/null 2>&1 || return 0
  rel="$(git -C "$dir" ls-files --full-name -- "$(basename "$SPL_LEASE_SRC")" 2>/dev/null)"
  [[ -n "$rel" ]] || return 0
  mine="$(git hash-object "$SPL_LEASE_SRC")"
  theirs="$(git -C "$dir" rev-parse -q --verify "$ref:$rel" 2>/dev/null)"
  [[ "$mine" == "$theirs" ]] && return 0
  do_log "FATAL $SPL_LEASE_SRC is not $ref's version - this tree is stale or edited; update it (or LEASE_ALLOW_STALE=1 for a deliberate test)"
  spl_lease_log "REFUSED ensure from a stale tree ($SPL_LEASE_SRC != $ref)"
  return 1
}

# Start "$@" fully detached: its own session, stdin/stdout/stderr to the log,
# and EVERY other inherited fd closed. Without the closing, a caller that
# pipes this action (`... | grep`) never sees EOF: run.sh's output tee holds
# the pipe and the loop holds the tee's input through a process-substitution fd.
spl_lease_detach() {
  local out="$1"; shift
  (
    for fd in /proc/$BASHPID/fd/*; do
      fd="${fd##*/}"
      [[ "$fd" =~ ^[0-9]+$ ]] && (( fd > 2 )) && eval "exec $fd>&-" 2>/dev/null
    done
    exec setsid nohup "$@" >> "$out" 2>&1 < /dev/null
  ) >> "$out" 2>&1 < /dev/null &
}

spl_lease_ensure() {
  [[ -f "$LEASE_CONF" ]] || { do_log "INFO no $LEASE_CONF - this box runs no dispatch lease"; return 0; }
  spl_lease_ids master failover orch || return 1
  spl_lease_trunk_check || return 1
  local verb out ver verbs=(renew watch)
  ver="$(spl_lease_code_ver)"
  if [[ -n "${LEASE_FLEET:-}" ]]; then
    spl_fleet_ids || return 1
    # fleet mode owns the local lease files: the local-only loops would
    # overwrite the mirror with a holder the fleet never chose
    for verb in renew watch; do
      spl_lease_running "$verb" && { spl_lease_log "ensure stops $verb (fleet mode)"; spl_lease_stop_one "$verb" || return 1; }
    done
    verbs=(fleet)
  elif spl_lease_running fleet; then
    spl_lease_conf_lost_fleet && return 1
    spl_lease_log "ensure stops fleet (no LEASE_FLEET)"; spl_lease_stop_one fleet || return 1
  fi
  for verb in "${verbs[@]}"; do
    if spl_lease_running "$verb"; then
      # a loop that took its lock a moment ago writes its version just after
      [[ "$(cat "$LEASE_DIR/$verb.ver" 2>/dev/null)" == "$ver" ]] || sleep 1
      if [[ "$(cat "$LEASE_DIR/$verb.ver" 2>/dev/null)" == "$ver" ]]; then
        do_log "INFO lease $verb loop running (pid $(cat "$LEASE_DIR/$verb.pid" 2>/dev/null))"
        continue
      fi
      # an old loop: replace it. The lease survives a few seconds without a
      # renewal or a watcher, so this leaves no gap.
      spl_lease_log "ensure replaces $verb (code $(cat "$LEASE_DIR/$verb.ver" 2>/dev/null || echo unknown) -> $ver)"
      spl_lease_stop_one "$verb" || return 1
    fi
    out="$LEASE_DIR/$verb.out"
    LEASE_CMD="$verb" LEASE_MASTER="$LEASE_MASTER" LEASE_FAILOVER="$LEASE_FAILOVER" LEASE_ORCH="$LEASE_ORCH" \
      LEASE_FLEET="${LEASE_FLEET:-}" LEASE_MACHINE="${LEASE_MACHINE:-}" LEASE_PRIORITY="${LEASE_PRIORITY:-}" \
      LEASE_PRIORITY_ORCH="${LEASE_PRIORITY_ORCH:-}" LEASE_PRIORITY_DISPATCH="${LEASE_PRIORITY_DISPATCH:-}" \
      LEASE_ENV="${LEASE_ENV:-}" LEASE_TENANT="${LEASE_TENANT:-}" LEASE_DESK_BOX="${LEASE_DESK_BOX:-}" \
      spl_lease_detach "$out" "${LEASE_RUN:-$PROJ_PATH/run}" -a do_spl_dispatch_lease
    do_log "INFO lease $verb loop started (log $out)"
    spl_lease_log "ensure started $verb"
  done
  return 0
}

# 0 (and a loud refusal) when lease.conf has no LEASE_FLEET but its newest
# backup has: a writer cut the file without leaving a backup (every action
# writes through spl_lease_conf_write, which leaves one), as on 2026-10-13
# (SPL-1713: three lines, then the file gone). Leaving fleet mode on such a
# file would turn the fleet loop off; ensure keeps it and says what to restore.
# A deliberate exit from fleet mode drops LEASE_FLEET by hand: then remove the
# newer backups too, or stop the loop with LEASE_CMD=stop.
spl_lease_conf_lost_fleet() {
  local bak
  bak="$(ls -t "$LEASE_CONF".bak-* 2>/dev/null | sed -n 1p)"
  [[ -n "$bak" ]] && grep -qE '^LEASE_FLEET=' "$bak" 2>/dev/null || return 1
  spl_lease_log "ensure REFUSED: $LEASE_CONF has no LEASE_FLEET but its newest backup $bak has; the fleet loop keeps running"
  do_log "FATAL $LEASE_CONF lost LEASE_FLEET (its newest backup $bak has it) and no action rewrote it with a backup: restore it from $bak, then LEASE_CMD=ensure. The fleet loop keeps running."
  return 0
}

# Stop one loop by its pid file (never by a command-line pattern: `pkill -f`
# also matches the shell that runs it) and wait for its lock to free.
spl_lease_stop_one() {
  local verb="$1" pid i
  spl_lease_running "$verb" || return 0
  pid="$(cat "$LEASE_DIR/$verb.pid" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { do_log "FATAL $verb runs but $LEASE_DIR/$verb.pid holds no pid"; return 1; }
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
  for i in $(seq 1 50); do spl_lease_running "$verb" || break; sleep 0.1; done
  spl_lease_running "$verb" && { do_log "FATAL $verb loop pid $pid did not stop"; return 1; }
  spl_lease_log "stop $verb pid=$pid"
}

spl_lease_stop() {
  spl_lease_stop_one renew && spl_lease_stop_one watch && spl_lease_stop_one fleet
}

# ---- fleet mode (CLE-77911, owner decision "a", t1 5fe56859) ------------------
# ONE orchestrator and ONE master dispatcher act at a time across every
# machine of a fleet. The lease row lives on the hub (rdb 0094, `spool lease`:
# read, or compare-and-set on gen); the hub's clock ages it, so the machines'
# clocks never have to agree. The priority rule lives HERE, not in the hub.

# The fleet-mode settings; LEASE_MACHINE defaults to the box tag.
spl_fleet_ids() {
  spl_lease_conf
  # the machine = its desk box id, the <box> of <ID>@<box> (fleet naming, t1 2efb3e78)
  LEASE_MACHINE="${LEASE_MACHINE:-$(spl_desk_box_default)}"
  local k
  for k in LEASE_FLEET LEASE_MACHINE; do
    [[ "${!k:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL $k is not set (env or $LEASE_CONF)"; return 1; }
  done
  for k in LEASE_PRIORITY LEASE_PRIORITY_ORCH LEASE_PRIORITY_DISPATCH; do
    # the per-role rankings are optional: unset = LEASE_PRIORITY
    [[ "$k" != LEASE_PRIORITY && -z "${!k:-}" ]] && continue
    [[ "${!k:-}" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] ||
      { do_log "FATAL $k must list the machines, preferred first (e.g. pc,sat)"; return 1; }
    [[ ",${!k}," == *",$LEASE_MACHINE,"* ]] ||
      { do_log "FATAL this machine ($LEASE_MACHINE) is not in $k (${!k})"; return 1; }
  done
  [[ -z "${LEASE_INTERMITTENT:-}" || "$LEASE_INTERMITTENT" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] ||
    { do_log "FATAL LEASE_INTERMITTENT must list boxes, comma-separated"; return 1; }
  [[ "${LEASE_HOLDDOWN:-300}" =~ ^[0-9]+$ ]] || { do_log "FATAL LEASE_HOLDDOWN must be seconds, got: '$LEASE_HOLDDOWN'"; return 1; }
}

# Resolve how this machine calls the hub. LEASE_HUB_CMD (tests) replaces the
# whole call: it gets `lease <args>` and prints the hub's answer.
spl_fleet_hub_init() {
  [[ -n "${LEASE_HUB_CMD:-}" ]] && return 0
  [[ "${LEASE_TENANT:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL LEASE_TENANT is not set (env or $LEASE_CONF)"; return 1; }
  [[ "${LEASE_ENV:-}" =~ ^(dev|prd|self)$ ]] || { do_log "FATAL LEASE_ENV must be dev, prd or self"; return 1; }
  LEASE_DESK_BOX="${LEASE_DESK_BOX:-$(spl_desk_box_default)}"
  ENV="$LEASE_ENV" do_spl_desk_cnf || return 1
  spl_host_spool || return 1
  local d="$SPL_STATE_DIR/desk/$LEASE_TENANT/$LEASE_DESK_BOX"
  [[ -s "$d/pinned" ]] ||
    { do_log "FATAL $LEASE_DESK_BOX is not pinned in $LEASE_TENANT ($d): seat a desk there first (do_spl_desk_up)"; return 1; }
}

# ---- one hung dial is not "unreachable" (SPL-2246, 2026-10-16) ----------------
# 17:14-18:40Z sat logged HUB-UNREACHABLE 21 times, every one "failed to send
# handshake request ... terminated signal received": the /v1/ws upgrade got no
# answer and the 30 s timeout killed the call, while the next dial (fleet-show
# 2.1 s, a curl upgrade 0.03 s) was answered. A fresh dial is a new request, so
# a try now gets LEASE_HUB_TIMEOUT (12 s; a good one takes ~1 s), and a "hub
# unreachable" or timed-out try is retried LEASE_HUB_TRIES - 1 more times after
# LEASE_HUB_RETRY_SLEEP (2 s): 26 s worst case, under the old 30 s. A retried
# compare-and-set is safe: had the lost try landed, the retry's --if-gen loses
# and its answer names this holder. Every try is one line in <LEASE_DIR>/dial.log.

# The call goes to LEASE_TENANT, or to LEASE_AT_TENANT (the copies below)
# through this machine's desk pinned THERE; the stub gets it as LEASE_HUB_TENANT.
spl_fleet_hub() {
  local tries="${LEASE_HUB_TRIES:-2}" n=1 out rc t0
  [[ "$tries" =~ ^[1-9]$ ]] || tries=2
  while :; do
    t0="$(date +%s%N)"
    out="$(spl_fleet_hub_once "$@" 2>&1)"; rc=$?
    spl_fleet_dial_log "$t0" "$rc" "$n" "$out" "$@"
    if (( rc != 0 && n < tries )) && [[ $rc == 124 || "$out" == *"hub unreachable"* ]]; then
      n=$((n + 1)); sleep "${LEASE_HUB_RETRY_SLEEP:-2}"; continue
    fi
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return "$rc"
  done
}

spl_fleet_hub_once() {
  local t="${LEASE_AT_TENANT:-${LEASE_TENANT:-}}"
  if [[ -n "${LEASE_HUB_CMD:-}" ]]; then LEASE_HUB_TENANT="${LEASE_AT_TENANT:-}" "$LEASE_HUB_CMD" lease "$@"; return; fi
  local d="$SPL_STATE_DIR/desk/$t/$LEASE_DESK_BOX"
  # spl_desk_spool's environment, under a timeout: a hung dial must not stall the tick
  SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$LEASE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$t" timeout "${LEASE_HUB_TIMEOUT:-12}" "$SPL_SPOOL" lease "$@"
}

# spl_fleet_dial_log <start ns> <rc> <try> <output> <args...>: one line per try
# (start, ms, rc, try, tenant, the call, the error); past 2 MB it keeps the
# newest 5000 lines. No LEASE_DIR (a caller outside the loop), no log.
spl_fleet_dial_log() {
  [[ -n "${LEASE_DIR:-}" && -d "$LEASE_DIR" ]] || return 0
  local t0="$1" rc="$2" n="$3" out="$4" f="$LEASE_DIR/dial.log" ms err=ok; shift 4
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  (( rc == 0 )) || err="$(tr '\n' ' ' <<<"$out" | cut -c1-240)"
  printf '%s ms=%s rc=%s try=%s tenant=%s %s :: %s\n' "$(date -u -d "@$((t0 / 1000000000))" +%FT%TZ)" "$ms" "$rc" "$n" \
    "${LEASE_AT_TENANT:-${LEASE_TENANT:-}}" "$*" "$err" >>"$f" 2>/dev/null || return 0
  if (( $(stat -c %s "$f" 2>/dev/null || echo 0) > 2097152 )); then
    tail -n 5000 "$f" >"$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f"
  fi
  return 0
}

# ---- the lease in every served tenant (spec 059 S5 gap, c-043) ----------------
# The hub routes a role's channel post (S5) from the lease rows of the post's
# OWN tenant, and the lease lived in LEASE_TENANT only, so every other tenant
# fanned a post out to every dispatcher box (prd 2026-10-02: csitea 4/4 posts
# to both boxes). The lease stays fleet-wide - ONE decision, made in
# LEASE_TENANT - and the machine that holds it copies the holder into the same
# (fleet, role) row of every other tenant it serves, right after each won
# write. Only the holder copies, so a dead holder's copies go stale with it
# (180 s) and the hub fans out as before; the next holder overwrites them. The
# hub needs no cross-tenant read: each copy is written by this machine's own
# desk key pinned in that tenant.

# The tenants copied to: LEASE_MIRROR_TENANTS (space-separated; set = exact
# list), else every tenant where this machine's desk box is pinned, minus
# LEASE_TENANT and the test workspaces.
spl_fleet_mirror_tenants() {
  if [[ -n "${LEASE_MIRROR_TENANTS+x}" ]]; then echo "$LEASE_MIRROR_TENANTS"; return 0; fi
  [[ -n "${SPL_STATE_DIR:-}" && -n "${LEASE_DESK_BOX:-}" ]] || return 0
  local p t
  for p in "$SPL_STATE_DIR"/desk/*/"$LEASE_DESK_BOX"/pinned; do
    [[ -s "$p" ]] || continue
    t="${p%/"$LEASE_DESK_BOX"/pinned}"; t="${t##*/}"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$t" != "${LEASE_TENANT:-}" ]] || continue
    spl_test_workspace "$t" && continue
    printf '%s ' "$t"
  done
}

# spl_fleet_mirror_out <role> <holder>: write <holder> into every copy (read
# its gen, then compare-and-set). A failure is logged once per tenant until it
# clears and ends this tick's copies, so a hung hub stalls the tick by ONE
# timeout (LEASE_MIRROR_TIMEOUT, 10 s), never once per tenant.
spl_fleet_mirror_out() {
  local role="$1" holder="$2" t out FH FG FA FW
  for t in $(spl_fleet_mirror_tenants); do
    if out="$(LEASE_AT_TENANT="$t" LEASE_HUB_TIMEOUT="${LEASE_MIRROR_TIMEOUT:-10}" LEASE_HUB_TRIES=1 spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" &&
       spl_fleet_read "$out" &&
       out="$(LEASE_AT_TENANT="$t" LEASE_HUB_TIMEOUT="${LEASE_MIRROR_TIMEOUT:-10}" LEASE_HUB_TRIES=1 spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" --holder "$holder" --if-gen "$FG" 2>&1)" &&
       spl_fleet_read "$out" && [[ "$FW" == true ]]; then
      [[ -f "$LEASE_DIR/fleet.$role.copy.$t" ]] && { rm -f "$LEASE_DIR/fleet.$role.copy.$t"; spl_lease_log "COPY $role in $t: written again ($holder)"; }
      continue
    fi
    spl_fleet_once "$role.copy.$t" "COPY-FAILED $role in $t: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
    return 0
  done
  return 0
}

# spl_fleet_read <json>: sets FH (holder), FG (gen), FA (age_s), FW (won).
spl_fleet_read() {
  local line
  # "|", not @tsv: a tab is IFS whitespace, so an empty holder would collapse
  line="$(jq -r '[.holder // "", .gen // 0, .age_s // -1, .won // false] | map(tostring) | join("|")' <<<"$1" 2>/dev/null)" || return 1
  IFS='|' read -r FH FG FA FW <<<"$line"
  [[ "$FG" =~ ^[0-9]+$ && "$FA" =~ ^-?[0-9]+$ ]]
}

# 0 when FA is a silence to act on: 0..LEASE_AGE_MAX (1 day) s. Below 0 is no
# row; past a day is no data (SPL-2654: an epoch-sized age, 2026-10-20).
spl_fleet_age_known() { [[ "$FA" =~ ^[0-9]+$ ]] && (( FA <= ${LEASE_AGE_MAX:-86400} )); }

# spl_fleet_age_write <role> <now>: <dir>/fleet.<role>.age "<holder> <FA> <now>"
# for the asks tick; an age it cannot be is written as "-", no data, and an
# AGE-UNKNOWN line is logged once (SPL-2654).
spl_fleet_age_write() {
  local fa=-
  if spl_fleet_age_known; then fa="$FA"; rm -f "$LEASE_DIR/fleet.$1.age-unknown"
  elif (( FG > 0 )); then spl_fleet_once "$1.age-unknown" "AGE-UNKNOWN $1: the hub answers ${FH:-none} silent ${FA}s (over ${LEASE_AGE_MAX:-86400}s or below 0): no data"; fi
  printf '%s %s %s\n' "${FH:-none}" "$fa" "$2" > "$LEASE_DIR/fleet.$1.age" 2>/dev/null || true
}

# spl_fleet_rank <machine> <role>: its 0-based rank in the role's ranking
# (LEASE_PRIORITY_ORCH / LEASE_PRIORITY_DISPATCH, else LEASE_PRIORITY);
# unknown = last.
spl_fleet_rank() {
  local i=0 m k="LEASE_PRIORITY_${2^^}" p="LEASE_PIN_BOX_${2^^}"
  # a pinned box (spl_fleet_pin) ranks before every other box of the role
  if [[ -n "${2:-}" && -n "${!p:-}" ]]; then [[ "$1" == "${!p}" ]] && { echo 0; return; }; i=1; fi
  [[ -n "${2:-}" && -n "${!k:-}" ]] || k=LEASE_PRIORITY
  IFS=, read -ra _ms <<<"${!k}"
  for m in "${_ms[@]}"; do [[ "$m" == "$1" ]] && { echo "$i"; return; }; i=$((i + 1)); done
  echo "$i"
}

# ---- a role pinned to a box (SPL-2643, do_spl_role_move) ----------------------
# Owner HUM-10 (csitea 1be68c11, msg f1fd503c): "move the orchestrator to the
# sat box". The ranking lives in each machine's lease.conf, so a move written
# there on one box ping-pongs with the boxes that still rank another first.
# The pin is one more hub lease row, (fleet, "pin-<role>"), holder
# "<seat>@<box>", written by do_spl_role_move: every box reads the same row,
# so every box ranks the pinned box first for that role (spl_fleet_rank), and
# the role moves by the usual handback (LEASE_HOLDDOWN, then one LEASE_PERIOD
# before the new seat is told ACTIVE). An intermittent box that is pinned
# hands back too. Nothing else changes: a pinned box whose seat cannot act
# goes stale and the role fails over as before; the pin brings it back once
# the seat is able again. The pin ends when its row is older than
# LEASE_PIN_TTL on the hub's clock (default 86400 s, 0 = never; env or
# lease.conf) or when do_spl_role_move writes it to box "none" (TO_BOX=none).
# Read every LEASE_PIN_READ s (60), cached in <dir>/fleet.<role>.pin as
# "<read epoch> <holder|-> <age at read>"; a failed read keeps the last one.
# Off with LEASE_PIN=0, and under the LEASE_HUB_CMD stub unless LEASE_PIN=1.

spl_fleet_pin_on() {
  [[ "${LEASE_PIN:-}" != 0 ]] && [[ -z "${LEASE_HUB_CMD:-}" || "${LEASE_PIN:-}" == 1 ]]
}

# spl_fleet_pin <role>: sets LEASE_PIN_BOX_<ROLE> to the box the role is
# pinned to, empty for none; a change (an expiry too) is logged once.
spl_fleet_pin() {
  local role="$1" f="$LEASE_DIR/fleet.$1.pin" now at=0 h=- a=-1 prev out ttl="${LEASE_PIN_TTL:-86400}" box=""
  local FH FG FA FW
  spl_fleet_pin_on || { printf -v "LEASE_PIN_BOX_${role^^}" '%s' ""; return 0; }
  now="$(spl_lease_now)"
  [[ -s "$f" ]] && read -r at h a < "$f"
  [[ "$at" =~ ^[0-9]+$ && "$a" =~ ^-?[0-9]+$ && -n "$h" ]] || { at=0 h=- a=-1; }
  if (( now - at >= ${LEASE_PIN_READ:-60} )) &&
     out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "pin-$role" 2>&1)" && spl_fleet_read "$out"; then
    at="$now" h="${FH:--}" a="$FA"
    (( FG == 0 )) && h=- a=-1
    printf '%s %s %s\n' "$at" "$h" "$a" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  fi
  [[ "$h" == *@* && "${h##*@}" != none ]] && (( a >= 0 )) && { [[ "$ttl" == 0 ]] || (( a + now - at < ttl )); } &&
    box="${h##*@}"
  prev="$(cat "$LEASE_DIR/fleet.$role.pin-box" 2>/dev/null)"
  if [[ "$box" != "$prev" ]]; then
    echo "$box" > "$LEASE_DIR/fleet.$role.pin-box"
    spl_lease_log "PIN $role: ${prev:-none} -> ${box:-none} (row $h, LEASE_PIN_TTL ${ttl}s)"
  fi
  printf -v "LEASE_PIN_BOX_${role^^}" '%s' "$box"
  return 0
}

# ---- the beat-health demotion (t1 3cfc236e, the 2026-10-11 lesson) ----------
# On 2026-10-11 one box's uplink degraded for 3.5 h (beats 60 -> 1..23 per
# 10 min) and dispatch was moved off it by hand. Now a box the hub's beats call
# degraded or recovering (lib/bash/funcs/spl-box-health.func.sh) ranks after
# every healthy box for both roles; a recovering box gets its configured rank
# back only after hold_min (30) of healthy beats. Why 30 min: that night the
# beats never held a healthy 10-min window between 01:50 and 05:20Z, and a role
# handback costs a dispatcher change, so one flap inside half an hour moves
# nothing twice. Every box reads the same hub beats (judged on the hub's
# clock), so the boxes agree; LEASE_PRIORITY_* stays the base order, no file
# is rewritten. The read is cached in <dir>/fleet.health (LEASE_HEALTH_TTL,
# 60 s); a failed read keeps the last good one while it is younger than the
# hold-down, else no box is demoted (the configured order, as before).

# spl_fleet_health_get: prints the verdicts object ({} = none judged).
spl_fleet_health_get() {
  local f="$LEASE_DIR/fleet.health" now at=0 v out ttl="${LEASE_HEALTH_TTL:-60}"
  [[ "${LEASE_HEALTH:-1}" == 0 ]] && { echo '{}'; return 0; }
  [[ -n "${LEASE_HUB_CMD:-}" && -z "${LEASE_BEATS_CMD:-}" ]] && { echo '{}'; return 0; }
  now="$(spl_lease_now)"
  [[ -s "$f" ]] && read -r at v < "$f"
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  # a read in this same second is reused (TTL 0 included): one tick reads the beats once
  (( now - at < ttl || now == at )) && [[ -n "${v:-}" ]] && { echo "$v"; return 0; }
  spl_box_health_cnf
  if out="$(spl_box_health_verdicts "$(spl_fleet_beats --since "$(spl_box_health_since)" 2>&1)")"; then
    printf '%s %s\n' "$now" "$out" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
    rm -f "$LEASE_DIR/fleet.health.unread"
    echo "$out"; return 0
  fi
  spl_fleet_once health.unread "HEALTH-UNREAD: the hub's box beats did not read: the last good read is kept for the hold-down, then the configured order"
  if [[ -n "${v:-}" ]] && (( now - at <= BH_HOLD_S )); then echo "$v"; else echo '{}'; fi
}

# spl_fleet_beats ARGS: `spool box-beat list ARGS` through the lease desk.
spl_fleet_beats() {
  # shellcheck disable=SC2086 # a command line, split on purpose
  if [[ -n "${LEASE_BEATS_CMD:-}" ]]; then $LEASE_BEATS_CMD box-beat list "$@"; return; fi
  local d="$SPL_STATE_DIR/desk/$LEASE_TENANT/$LEASE_DESK_BOX"
  SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$LEASE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$LEASE_TENANT" timeout "${LEASE_HUB_TIMEOUT:-30}" "$SPL_SPOOL" box-beat list "$@"
}

# spl_fleet_eff_rank <machine> <role> <verdicts>: the configured rank, plus
# 1000 while the machine is degraded or recovering (after every healthy box,
# the demoted ones still in their configured order).
spl_fleet_eff_rank() {
  local r st
  r="$(spl_fleet_rank "$1" "$2")"
  st="$(jq -r --arg b "$1" '.[$b].state // "unknown"' <<<"$3" 2>/dev/null)"
  [[ "$st" == degraded || "$st" == recovering ]] && r=$((r + 1000))
  echo "$r"
}

# spl_fleet_outranks <me> <holder> <role>: 0 when me ranks before the holder.
# A demotion that decides it (the configured order says otherwise) is logged
# once per holder until it clears.
spl_fleet_outranks() {
  local me="$1" hm="$2" role="$3" v rm rh
  v="$(spl_fleet_health_get)"
  rm="$(spl_fleet_eff_rank "$me" "$role" "$v")" rh="$(spl_fleet_eff_rank "$hm" "$role" "$v")"
  if (( rm < rh )) && (( $(spl_fleet_rank "$me" "$role") >= $(spl_fleet_rank "$hm" "$role") )); then
    spl_fleet_once "$role.demoted.$hm" "DEMOTED $role: $hm ranks last ($(jq -r --arg b "$hm" '"\(.[$b].state): \(.[$b].why)"' <<<"$v")): $me ranks before it"
  else
    rm -f "$LEASE_DIR/fleet.$role.demoted.$hm"
  fi
  (( rm < rh ))
}

# ---- the bench alert (t1 3cfc236e, HUM-10 "yes", msg 0c2817c5) ----------------
# One line in the lease tenant's #alerts per CHANGE of a box's bench state:
# benched = degraded or recovering (no new lanes, last for the roles), back =
# healthy again after the hold-down. Every box records every box's state in
# <dir>/fleet.bench on every tick, from the same hub beats on the hub's clock,
# so every box sees the same change; only ONE box posts it, the first box of
# the orch order (LEASE_PRIORITY_ORCH, else LEASE_PRIORITY) that is healthy
# and is not the box itself (the box alone in the fleet only for itself). Not
# the orch holder: the demotion moves the orch role in the very tick of the
# change, and the old and the new holder would both post it. A box seen for
# the first time (a new state file, a box not judged before) is recorded, not
# posted. LEASE_ALERT=0 turns it off; LEASE_ALERT_CMD (tests) replaces the
# post (the text on stdin); with the LEASE_HUB_CMD stub and no LEASE_ALERT_CMD
# it is only logged. The real post is do_spl_desk_post from LEASE_ORCH's desk,
# in the background like the owner DM.
# A benched line that never landed (the post failed, or no healthy box could
# post it: both boxes down, 2026-10-11 16:12Z) is not sent again. The one back
# line names that time: "back after N healthy min (benched since <UTC>; the
# benched alert could not be delivered)". Re-sending the bench line at
# recovery would be a second post for a state that has already ended, and it
# can land twice when the first post was only slow. The record is
# <dir>/fleet.bench.sent.<box> ("<UTC> 0|1"), written by the poster, or by
# every box when there is no poster. 1 = this episode's bench line was delivered.
# The benched line names the verdict and its why (spl_box_health_verdicts):
# "Box <box> benched (recovering: healthy for 1260s < hold 1800s; 61 of 60 ...)"
# explains a box that beats fine now but had a bad window inside the hold.

# spl_fleet_bench_tick: record every judged box's bench state, post the
# changes this machine owns. One jq: line 1 the new state, then one
# tab-separated change (kind, box, poster, line). The poster of <box>'s
# change: the first box of the orch order, then
# the other judged boxes, that is healthy and is not <box>; else <box> itself
# when healthy (alone in the fleet); else nobody.
spl_fleet_bench_tick() {
  [[ "${LEASE_ALERT:-1}" == 0 ]] && return 0
  local v f="$LEASE_DIR/fleet.bench" old='{}' out new k="LEASE_PRIORITY_ORCH"
  local line kind box who raw
  v="$(spl_fleet_health_get)"
  [[ "$v" == '{}' || -z "$v" ]] && return 0
  # the same verdicts as the last tick judged (the cached read): nothing can have changed
  [[ -s "$f.v" && "$(<"$f.v")" == "$v" ]] && return 0
  [[ -n "${BH_BEAT_S:-}" ]] || spl_box_health_cnf
  # a hub stall: every box alert held (rc 1), the boxes it explains count healthy
  raw="$v"; v="$(spl_fleet_stall_view "$raw")" || return 0
  [[ -n "${!k:-}" ]] || k=LEASE_PRIORITY
  [[ -s "$f" ]] && old="$(<"$f")"
  out="$(jq -rn --argjson v "$v" --arg old "$old" --arg prio "${!k}" \
    --argjson e "$(( BH_WINDOW_S / BH_BEAT_S ))" --argjson w "$(( BH_WINDOW_S / 60 ))" --argjson h "$(( BH_HOLD_S / 60 ))" '
    ($old | try fromjson catch {} | if type == "object" then . else {} end) as $old
    | ($old + ($v | map_values(if .state == "healthy" then "ok" else "benched" end))) as $new
    | (($prio | split(",") | map(select(. != ""))) + ($v | keys)) as $order
    | def poster($b): [$order[] | select(. != $b and $v[.].state == "healthy")][0]
        // (if $v[$b].state == "healthy" then $b else null end);
    ($new | tojson),
    ($v | keys[] as $b | select($old[$b] != null and $old[$b] != $new[$b])
      | (poster($b) // "-") as $who
      | if $new[$b] == "benched" then
          $v[$b] | "benched\t\($b)\t\($who)\tBox \($b) benched (\(.state // "benched")\(if .why == null then "" else ": \(.why)" end); \(.n) of \($e) heartbeats in \($w) min, last \(if .age == null then "none" else "\(.age) s ago" end)) (no new lanes, last for the roles)"
        else "back\t\($b)\t\($who)\tBox \($b) back after \($h) healthy min" end)')" || return 0
  printf '%s\n' "$raw" > "$f.v"
  { IFS= read -r new; printf '%s\n' "$new" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
    while IFS=$'\t' read -r kind box who line; do
      [[ -n "${kind:-}" ]] && spl_fleet_bench_change "$kind" "$box" "$who" "$line"
    done; } <<<"$out"
  return 0
}

# ---- the common-mode gate (SPL-3196, alerts fix round row 05) ----------------
# Triage B1 (csi-spl-doc/doc/md/alerts-fix-round-plan.md 2.4): one hub stall
# stops every box's beats at once. Every box goes recovering, no healthy box is
# left to post, each bench is recorded as not delivered and comes back as "the
# benched alert could not be delivered", and a seatless holder raises
# NO-LOCAL-AGENT: one hub fault read as a failure of every box, posted through
# the hub that caused it. The GCP policies already page a hub stall. A stall
# episode starts when
#  - the watchdog's <dir>/wd/held marker exists (the hub answers, its beat path
#    fails), or spl_wd_hub_reachable fails (asked only while a box is not
#    healthy, and only where the watchdog is loaded and has a hub to ask), or
#  - every judged box (2 or more) is degraded or recovering and their last
#    beat gaps (> max_gap_s) start within max_gap_s of each other and overlap,
#    measured on one more beats read per episode.
# Its record is <dir>/fleet.hub-stall, "<start> <end> <src> <posted>" (epochs;
# src l = a live signal, b = the beats). A box whose last bad time (degraded:
# its last beat; recovering: the end of its bad window, from its why) lies in
# start..end widened by max_gap_s is explained by the stall: while one is still
# silent every box alert is held; one that beats again counts as healthy. When
# no box is silent any more the stall posts its one line, "Hub stall
# <start>..<end>: box alerts held", from one box (the first of the orch order
# that beats, else the first judged; a live-signal stall from this box). The
# record goes when no box is explained any more. One box degraded alone is
# benched as before.

spl_fleet_utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# spl_fleet_hub_stalled: 0 while this box sees the hub stall live.
spl_fleet_hub_stalled() {
  [[ -e "$LEASE_DIR/wd/held" ]] && return 0
  declare -F spl_wd_hub_reachable >/dev/null || return 1
  [[ -n "${WD_HUB_PROBE_CMD:-}" || ( -n "${SPL_HUB_URL:-}" && -z "${LEASE_HUB_CMD:-}" ) ]] || return 1
  ! spl_wd_hub_reachable
}

# spl_fleet_stall_gaps VERDICTS NOW: "<start> <end>", the window that every
# judged box's last beat gap (an open one ends at NOW) shares; rc != 0 = none.
spl_fleet_stall_gaps() {
  local b
  b="$(spl_fleet_beats --since "$(spl_box_health_since)" 2>/dev/null)" || return 1
  jq -er --argjson v "$1" --argjson now "$2" --argjson gap "$BH_MAX_GAP_S" '
    def epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch null);
    [(.rows // [])[] | select(type == "object" and (.box | type) == "string")
      | {box, t: (.beat_at | tostring | epoch)} | select(.t != null)]
    | (group_by(.box) | map({key: .[0].box, value: (map(.t) | sort)}) | from_entries) as $ts
    | [$v | keys[] | ($ts[.] // []) as $t
        | if ($t | length) == 0 then null
          elif $now - $t[-1] > $gap then [$t[-1], $now]
          else ([range(1; $t | length) | select($t[.] - $t[. - 1] > $gap) | [$t[. - 1], $t[.]]] | last) end] as $g
    | select(($g | length) >= 2 and all($g[]; . != null))
    | ([$g[][0]] | max) as $s | ([$g[][1]] | min) as $e
    | select($s < $e and $s - ([$g[][0]] | min) <= $gap) | "\($s) \($e)"' <<<"$b"
}

# spl_fleet_stall_marks VERDICTS NOW START END: the verdicts, each box the stall
# explains marked .stall = "silent" (degraded since it) or "beats" (recovering from it).
spl_fleet_stall_marks() {
  jq -c --argjson now "$2" --argjson lo "$(( $3 - BH_MAX_GAP_S ))" --argjson hi "$(( $4 + BH_MAX_GAP_S ))" 'map_values(
    (if .state == "degraded" then (if .age == null then null else $now - .age end)
     elif .state == "recovering" then ((.why // "") | (capture("healthy for (?<x>[0-9]+)s").x // null)
       | if . == null then null else $now - tonumber end)
     else null end) as $lb
    | if $lb != null and $lb >= $lo and $lb <= $hi then . + {stall: (if .state == "degraded" then "silent" else "beats" end)} else . end)' <<<"$1"
}

# spl_fleet_stall_line MARKS START END SRC: the stall's one line, from one box.
spl_fleet_stall_line() {
  local k=LEASE_PRIORITY_ORCH who="$LEASE_MACHINE"
  [[ "${LEASE_ALERT:-1}" == 0 ]] && return 0
  [[ -n "${!k:-}" ]] || k=LEASE_PRIORITY
  [[ "$4" == l ]] || who="$(jq -r --arg p "${!k:-}" '. as $v | (($p | split(",") | map(select(. != "" and $v[.] != null))) + keys) as $o
    | ([$o[] | select($v[.].state == "healthy" or $v[.].stall == "beats")][0]) // $o[0]' <<<"$1")"
  [[ "$who" == "$LEASE_MACHINE" ]] || return 0
  spl_fleet_alert_post "Hub stall $(spl_fleet_utc "$2")..$(spl_fleet_utc "$3"): box alerts held" || true
}

# spl_fleet_stall_write START END SRC POSTED: the episode record.
spl_fleet_stall_write() {
  local f="$LEASE_DIR/fleet.hub-stall"
  printf '%s %s %s %s\n' "$@" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# spl_fleet_stall_view VERDICTS: the verdicts the box alerts judge, every box
# the stall explains counted healthy; rc 1 = a stall holds every box alert now.
spl_fleet_stall_view() {
  local v="$1" f="$LEASE_DIR/fleet.hub-stall" now s="" e="" src="" posted=0 w m
  [[ -n "${BH_MAX_GAP_S:-}" ]] || spl_box_health_cnf
  now="$(spl_lease_now)"
  [[ -s "$f" ]] && read -r s e src posted < "$f"
  if jq -e 'any(.[]; .state != "healthy")' >/dev/null 2>&1 <<<"$v" && spl_fleet_hub_stalled; then
    [[ -n "$s" ]] || { s="$now" src=l posted=0; spl_lease_log "HUB-STALL from $(spl_fleet_utc "$now"), live (wd/held or the hub probe): box alerts held"; }
    spl_fleet_stall_write "$s" "$now" "$src" "$posted"; return 1
  fi
  if [[ -z "$s" ]] && jq -e 'length >= 2 and all(.[]; .state != "healthy")' >/dev/null 2>&1 <<<"$v" &&
      w="$(spl_fleet_stall_gaps "$v" "$now")"; then
    read -r s e <<<"$w"; src=b posted=0
    spl_lease_log "HUB-STALL $(spl_fleet_utc "$s")..$(spl_fleet_utc "$e"): every box's beats stopped together; box alerts held"
  fi
  [[ -n "$s" ]] || { echo "$v"; return 0; }
  m="$(spl_fleet_stall_marks "$v" "$now" "$s" "$e")" || { echo "$v"; return 0; }
  if jq -e 'any(.[]; .stall == "silent")' >/dev/null <<<"$m"; then spl_fleet_stall_write "$s" "$e" "$src" "$posted"; return 1; fi
  [[ "$posted" == 1 ]] || { spl_fleet_stall_line "$m" "$s" "$e" "$src"; posted=1; }
  if ! jq -e 'any(.[]; .stall != null)' >/dev/null <<<"$m"; then
    rm -f "$f"; spl_lease_log "HUB-STALL over: $(spl_fleet_utc "$s")..$(spl_fleet_utc "$e"), every box judged on its own beats again"
    echo "$v"; return 0
  fi
  spl_fleet_stall_write "$s" "$e" "$src" "$posted"
  jq -c 'map_values(if .stall != null then .state = "healthy" else . end)' <<<"$m"
}

# spl_fleet_bench_sent_write BOX SINCE OK: this episode's bench delivery (1 = landed).
spl_fleet_bench_sent_write() {
  local f="$LEASE_DIR/fleet.bench.sent.$1"
  printf '%s %s\n' "$2" "$3" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# spl_fleet_bench_sent_ok BOX SINCE: the background post landed for this episode only.
spl_fleet_bench_sent_ok() {
  local f="$LEASE_DIR/fleet.bench.sent.$1" cur ok
  [[ -s "$f" ]] || return 0
  read -r cur _ < "$f" || return 0
  [[ "$cur" == "$2" ]] || return 0
  spl_fleet_bench_sent_write "$1" "$2" 1
}

spl_fleet_bench_sent_clear() { rm -f "$LEASE_DIR/fleet.bench.sent.$1"; }

# spl_fleet_back_line BOX LINE: the short back line, plus the bench time when
# that post never landed.
spl_fleet_back_line() {
  local since ok f="$LEASE_DIR/fleet.bench.sent.$1"
  [[ -s "$f" ]] || { printf '%s\n' "$2"; return 0; }
  read -r since ok < "$f" || { printf '%s\n' "$2"; return 0; }
  if [[ "$ok" == 0 && -n "$since" ]]; then
    printf '%s (benched since %s; the benched alert could not be delivered)\n' "$2" "$since"
  else
    printf '%s\n' "$2"
  fi
}

# spl_fleet_bench_change KIND BOX WHO LINE: post when this machine is the
# poster; remember a bench that did not land. KIND is benched or back.
spl_fleet_bench_change() {
  local kind="$1" box="$2" who="$3" line="$4" since rc
  if [[ "$kind" == benched ]]; then
    since="$(date -u -d "@$(spl_lease_now)" +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$who" == "-" ]]; then spl_fleet_bench_sent_write "$box" "$since" 0; return 0; fi
    [[ "$who" == "$LEASE_MACHINE" ]] || { spl_fleet_bench_sent_clear "$box"; return 0; }
    spl_fleet_bench_sent_write "$box" "$since" 0
    rc=0
    spl_fleet_alert_post "$line" "$box" "$since" || rc=$?
    (( rc == 0 )) && spl_fleet_bench_sent_write "$box" "$since" 1
    return 0
  fi
  if [[ "$who" == "$LEASE_MACHINE" ]]; then
    line="$(spl_fleet_back_line "$box" "$line")"
    spl_fleet_alert_post "$line" || true
  fi
  spl_fleet_bench_sent_clear "$box"
}

# spl_fleet_alert_post TEXT [BOX SINCE]: one post in LEASE_TENANT's #alerts.
# Returns 0 when delivered, 1 when the attempt failed, 2 when the real post
# is still in flight (it marks BOX/SINCE delivered if that episode is current).
spl_fleet_alert_post() {
  local text="$1" box="${2:-}" since="${3:-}"
  if [[ -n "${LEASE_ALERT_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    if $LEASE_ALERT_CMD <<<"$text" >/dev/null 2>&1; then
      spl_lease_log "ALERT #alerts: $text"
      return 0
    fi
    spl_lease_log "WARN #alerts post failed (LEASE_ALERT_CMD)"
    return 1
  fi
  if [[ -n "${LEASE_HUB_CMD:-}" ]]; then
    spl_lease_log "ALERT #alerts (not posted, stub hub): $1"
    return 0
  fi
  spl_lease_log "ALERT #alerts: $text"
  (
    if ENV="$LEASE_ENV" TENANT_ID="$LEASE_TENANT" DESK_BOX="$LEASE_DESK_BOX" DESK_AGENT="$LEASE_ORCH" DESK_CHANNEL=alerts \
        DESK_KIND=note DESK_BODY="$text" DRY_RUN=0 timeout "${LEASE_OWNER_TIMEOUT:-120}" "${LEASE_ASKS_RUN:-$PROJ_PATH/run}" \
        -a do_spl_desk_post </dev/null >>"$LEASE_DIR/alert-post.out" 2>&1 7>&- 8>&-; then
      [[ -n "$box" && -n "$since" ]] && spl_fleet_bench_sent_ok "$box" "$since"
    fi
  ) 2>/dev/null &
  return 2
}

# This machine's live candidate for a role (empty = none): the local order
# (spl_fleet_role_agents).
spl_fleet_candidate() {
  local id desk
  # the dispatcher is the seat that posts: no desk that can post, no candidate (spec 092 FR-002)
  if [[ "$1" == dispatch ]] && ! desk="$(spl_fleet_desk_able)"; then
    for id in $(spl_fleet_role_agents dispatch); do spl_lease_able_write "$id" "$desk"; done
    return 0
  fi
  for id in $(spl_fleet_role_agents "$1"); do spl_fleet_try "$id" && return 0; done
  return 0
}

# spl_fleet_try <id>: prints <id> when it is live, able and not stuck;
# non-zero otherwise, the why left in able.<id>.
spl_fleet_try() {
  [[ -n "$(spl_lease_agent_able "$1" fleet)" ]] || return 1
  echo "$1"
}

# ---- the vendor fallback (SPL-2521, SPL-2544; owner HUM-10 t1 b3e90079) -------
# 2026-10-19: "there was login on the claude and ... grok should have been able
# to take over the orchestration, but it did not". The candidates were the
# claude ids of lease.conf only (LEASE_ORCH; LEASE_MASTER, LEASE_FAILOVER), so
# a box whose claude seats could not act had no candidate at all, and grok
# came in only through the hourly rotation (spl_rotate_role_vendor). Owner,
# msg dfe76b16: "if the leading orchestrator is having logi isseus or whatever
# error the backup orchestrator should kick - in , and the order is claude ->
# grok -> agy". Now:
# - the role's seat SWITCHES VENDOR IN PLACE (SPL-2544): one seat, one real
#   spool dir, one inbox (role-seat-switch.sh, SPL-1685). SPL-2521/2532 ran
#   separate standby seats g-001, a-001, ... instead; on the boxes those ids
#   are links to the claude seats' dirs, so a standby start wrote over a
#   claude seat's prompt (2026-10-19 09:5xZ) and, refused since SPL-2541,
#   none could start. Now no second process: when no seat of the role on
#   this machine can act (the able + stuck test) and the holder is silent
#   past the next vendor's wait (below), the lease launches
#   do_spl_role_failover, which starts that vendor IN the seat under the
#   rotation's lock (spl-role-failover.func.sh). LEASE_ORCH_FALLBACK /
#   LEASE_DISPATCH_FALLBACK list the vendors (default LEASE_VENDOR_ORDER);
# - a holder's vendor (its id letter) ranks before the machine rank
#   (LEASE_VENDOR_ORDER, default claude,grok,agy): an able claude seat on any
#   box takes the role back from a grok or agy holder (the handback, with its
#   LEASE_HOLDDOWN), and a seat of a worse vendor never takes it from a better one;
# - a seat switches to the next vendor (and a worse-vendor seat takes a role)
#   only when the holder has been silent LEASE_STALE + LEASE_FALLBACK_WAIT
#   (60 s) per step down the order: grok at 240 s, agy at 300 s. So an able
#   claude seat on another box, which takes at LEASE_STALE, comes first. A
#   machine holding a role with a better vendor than its best able seat stops
#   renewing and waits the same way (FALLBACK-WAIT, logged once).
# From the last renewal of a seat that cannot act to the switch: LEASE_STALE
# + LEASE_FALLBACK_WAIT + one LEASE_PERIOD = 300 s (defaults); the new
# vendor's start (do_spl_role_failover: ROTATE_START_WAIT, the start check,
# ROLE_FAILOVER_SETTLE) and one more tick follow.

# spl_fleet_fallback <role>: the vendors the role's seat may switch to, in
# order, space-separated: LEASE_<ROLE>_FALLBACK, else LEASE_VENDOR_ORDER; an id
# in the list (the SPL-2521 form, g-001) reads as its letter's vendor; "none"
# = no switch.
spl_fleet_fallback() {
  local k="LEASE_${1^^}_FALLBACK" v x out=" "
  v="${!k:-${LEASE_VENDOR_ORDER:-claude,grok,agy,claude2}}"
  [[ "$v" == none ]] && return 0
  for x in ${v//,/ }; do
    [[ "$x" =~ ^[a-z]-[0-9]+$|^(CLE|GRK|AGY|QWN)-[0-9]+$ ]] && x="$(spl_fleet_vendor "$x")"
    [[ "$x" =~ ^(claude|grok|agy|mistral|qwen|claude2)$ && "$out" != *" $x "* ]] && out+="$x "
  done
  out="${out# }"; echo "${out% }"
}

# spl_fleet_switch_next <role> <seat>: the first vendor of spl_fleet_fallback
# ranked after <seat>'s vendor as it runs now (spl_fleet_seat_vendor,
# LEASE_VENDOR_ORDER); nothing = none left.
spl_fleet_switch_next() {
  local st v
  st="$(spl_fleet_vtier "$(spl_fleet_seat_vendor "$2")")"
  for v in $(spl_fleet_fallback "$1"); do
    (( $(spl_fleet_vtier "$v") > st )) && { echo "$v"; return 0; }
  done
  return 0
}

# spl_fleet_vendor_id <vendor>: a probe id in its letter (claude -> c-0, ...;
# claude2, claude under the second login, runs a claude id too).
spl_fleet_vendor_id() {
  case "$1" in claude|claude2) echo c-0 ;; grok) echo g-0 ;; agy) echo a-0 ;; mistral) echo m-0 ;; qwen) echo q-0 ;; *) echo x-0 ;; esac
}

# ---- the second claude login (SPL-2943; owner HUM-10 t1 678d29e2) ---------
# On 2026-10-22 10:23..11:01Z claude and grok sat on the weekly limit on every
# box and no seat could act for 38 min. The last vendor step, after grok and
# agy, is claude2: claude under a SECOND account, run by the same agent user
# from its own config folder (CLAUDE_CONFIG_DIR; owner poll 0e7422ba: no new
# OS user). The folder is ONE setting, CLAUDE2_CONFIG_DIR (default
# <agent home>/.claude-2); the step stays dormant until that folder holds a
# login (spl_role_failover_guard). Which login a claude seat runs is read from
# its live process: a non-empty CLAUDE_CONFIG_DIR in its environ = claude2
# (no launcher sets it for the main login).

# spl_fleet_vtier <vendor>: its 0-based place in LEASE_VENDOR_ORDER (default
# claude,grok,agy,claude2); a vendor not listed comes after all of them.
spl_fleet_vtier() {
  local i=0 m
  local -a vs
  IFS=, read -ra vs <<<"${LEASE_VENDOR_ORDER:-claude,grok,agy,claude2}"
  for m in "${vs[@]}"; do [[ "$m" == "$1" ]] && { echo "$i"; return; }; i=$((i + 1)); done
  echo "$i"
}

# spl_fleet_seat_vendor <seat>: the vendor the seat runs now: its letter's,
# claude2 for a claude process whose environ carries CLAUDE_CONFIG_DIR.
spl_fleet_seat_vendor() {
  local v pid root="${LEASE_PROC_ROOT:-/proc}" cfg=""
  v="$(spl_fleet_vendor "${1%@*}")"
  [[ "$v" == claude ]] || { echo "$v"; return 0; }
  pid="$(spl_lease_agent_pid "${1%@*}")"
  if [[ -n "$pid" && -r "$root/$pid/environ" ]]; then
    cfg="$(tr '\0' '\n' < "$root/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | sed -n 1p)"
  elif [[ -n "$pid" ]] && declare -F spool_proc_env_get >/dev/null; then
    cfg="$(spool_proc_env_get "$root" CLAUDE_CONFIG_DIR "$pid" 2>/dev/null | awk '{print $2; exit}')"
  fi
  if [[ -n "$cfg" ]]; then echo claude2; else echo claude; fi
}

# spl_fleet_role_seat <role>: the seat a switch moves, as it runs now
# (spl_fleet_seat_id): orch LEASE_ORCH, dispatch LEASE_MASTER.
spl_fleet_role_seat() {
  case "$1" in orch) spl_fleet_seat_id "$LEASE_ORCH" ;; dispatch) spl_fleet_seat_id "$LEASE_MASTER" ;; esac
}

# spl_fleet_switch_tick <role>: no seat of the role can act on this machine.
# Past the next vendor's wait (the holder silent > LEASE_STALE + its tier x
# LEASE_FALLBACK_WAIT; a role never held is a setup, not a stall), launch the
# in-place switch. The silence counts from this machine's last failed hub call
# at the latest (fleet.<role>.hub-down, spl_fleet_unreachable; SPL-2865): while
# the hub is down nobody renews, so on 2026-10-22 09:54Z the first read after
# the store_unavailable outage found the holder "silent 331s" and switched a
# live seat. The rest: launch the
# in-place switch of the role's seat (do_spl_role_failover), at most once per
# LEASE_SWITCH_RETRY s per seat. A dispatch desk that cannot post is no
# vendor's fault: no switch.
spl_fleet_switch_tick() {
  local role="$1" seat next wait f at="" was="" now
  spl_fleet_switch_on || return 0
  (( FG > 0 )) || return 0
  [[ "$role" != dispatch ]] || spl_fleet_desk_able >/dev/null || return 0
  seat="$(spl_fleet_role_seat "$role")"
  [[ "$seat" =~ ^${SPL_ROLE_SEAT_RX}$ ]] || return 0
  next="$(spl_fleet_switch_next "$role" "$seat")"
  if [[ -z "$next" ]]; then
    spl_fleet_once "$role.switch-none" "SWITCH $role: $seat ($(spl_fleet_vendor "$seat")) cannot act and no vendor is left after it (fallback: '$(spl_fleet_fallback "$role")')"
    return 0
  fi
  wait=$(( LEASE_STALE + $(spl_fleet_vtier "$next") * ${LEASE_FALLBACK_WAIT:-60} ))
  spl_fleet_age_known && (( FA > wait )) || return 0
  now="$(spl_lease_now)"; f="$LEASE_DIR/fleet.$role.switch"
  local sil="$FA" down=""
  read -r down _ < "$LEASE_DIR/fleet.$role.hub-down" 2>/dev/null || down=""
  [[ "$down" =~ ^[0-9]+$ ]] && (( now - down < sil )) && sil=$(( now - down ))
  if (( sil <= wait )); then
    spl_fleet_once "$role.switch-hubwait" "SWITCH-WAIT $role: ${FH:-the holder} silent ${FA}s, but the hub was unreachable from here $((now - down))s ago: no renewal could land; $seat switches only past ${wait}s of silence with the hub up"
    return 0
  fi
  rm -f "$LEASE_DIR/fleet.$role.switch-hubwait"
  [[ -s "$f" ]] && read -r at was _ < "$f"
  [[ "$at" =~ ^[0-9]+$ && "$was" == "$seat" ]] && (( now - at < ${LEASE_SWITCH_RETRY:-120} )) && return 0
  echo "$now $seat $next" > "$f"
  spl_lease_log "SWITCH $role: $seat ($(spl_fleet_seat_vendor "$seat")) cannot act ($(cat "$LEASE_DIR/able.$seat" 2>/dev/null | tr '\n' ' ' | cut -c1-160)) and ${FH:-the holder} is silent ${sil}s > ${wait}s: $seat switches to $next in place (do_spl_role_failover)"
  spl_fleet_switch_start "$role" "$seat" "$sil" "$next"
}

# 0 when this loop may launch a switch: LEASE_ROLE_SWITCH (default 1); a
# sandbox (SPOOL_TEST=1, a fake LEASE_PROC_ROOT) only with a LEASE_SWITCH_RUN stub.
spl_fleet_switch_on() {
  [[ "${LEASE_ROLE_SWITCH:-1}" == 1 ]] || return 1
  [[ -n "${LEASE_SWITCH_RUN:-}" ]] && return 0
  [[ "${SPOOL_TEST:-0}" != 1 && -z "${LEASE_PROC_ROOT:-}" ]]
}

# spl_fleet_switch_start <role> <seat> <silent> <next>: do_spl_role_failover in its
# own process (a start waits minutes; the lease tick never does), the lease's
# ids dropped from its env so it reads lease.conf as it is now.
spl_fleet_switch_start() {
  local -a cmd=(env -u LEASE_ORCH -u LEASE_MASTER -u LEASE_FAILOVER SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
    ROLE_FAILOVER_ROLE="$1" ROLE_FAILOVER_SEAT="$2" ROLE_FAILOVER_SILENT="$3" ROLE_FAILOVER_NEXT="${4:-}" DRY_RUN=0
    timeout "${LEASE_SWITCH_TIMEOUT:-1800}" "${LEASE_SWITCH_RUN:-$PROJ_PATH/run}" -a do_spl_role_failover)
  if [[ "${LEASE_SWITCH_SYNC:-0}" == 1 ]]; then
    "${cmd[@]}" >>"$LEASE_DIR/role-failover.out" 2>&1 7>&- 8>&- </dev/null || true
    return 0
  fi
  ( "${cmd[@]}" >>"$LEASE_DIR/role-failover.out" 2>&1 7>&- 8>&- </dev/null & ) 2>/dev/null
  return 0
}

# spl_fleet_vendor <id>: the vendor its letter names (c- and the legacy CLE- claude).
spl_fleet_vendor() {
  case "$1" in c-*|CLE-*) echo claude ;; g-*) echo grok ;; a-*) echo agy ;; m-*) echo mistral ;; q-*) echo qwen ;; *) echo unknown ;; esac
}

# spl_fleet_tier <id-or-holder>: its vendor's 0-based place in
# LEASE_VENDOR_ORDER; a vendor not listed comes after all of them.
spl_fleet_tier() {
  spl_fleet_vtier "$(spl_fleet_vendor "${1%@*}")"
}

# Can this box's desk post (spec 092 FR-002)? 0 = yes; else prints why. On
# 2026-10-05 a box back from a power cut took dispatch 51 s before its desk
# sidecar was up. Able = the LEASE_TENANT desk's `spool hub-run` sidecar lives
# AND its current session's last word is `hub session up`: the last session
# line of hub-run.log, stamped no earlier than the pid file (an `up` of the
# sidecar before a restart is not this session's). The gate is off with
# LEASE_DESK_GATE=0 or when no desk dir is known (the tests' stub hub).
spl_fleet_desk_able() {
  [[ "${LEASE_DESK_GATE:-1}" == 0 ]] && return 0
  local d="${LEASE_DESK_DIR:-}" h pid line ts at started
  [[ -z "$d" && -n "${SPL_STATE_DIR:-}" && -n "${LEASE_TENANT:-}" && -n "${LEASE_DESK_BOX:-}" ]] &&
    d="$SPL_STATE_DIR/desk/$LEASE_TENANT/$LEASE_DESK_BOX"
  [[ -n "$d" ]] || return 0
  h="$d/spool/.hub"
  pid="$(cat "$h/hub-run.pid" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' <"${LEASE_PROC_ROOT:-/proc}/$pid/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null ||
    { echo "desk: no hub-run sidecar in $d"; return 1; }
  line="$(tail -n "${LEASE_DESK_LOG_TAIL:-5000}" "$h/hub-run.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' |
    grep -aE 'hub session (up|down)|so the session reconnects' | tail -1)"
  [[ "$line" == *"hub session up"* ]] || { echo "desk: session not up (last: ${line:-none})"; return 1; }
  ts="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})' <<<"$line" | sed -n 1p)"
  started="$(stat -c %Y "$h/hub-run.pid" 2>/dev/null)"
  # an unstamped line cannot be dated: the order check above stands alone
  [[ -n "$ts" && -n "$started" ]] && at="$(date -d "$ts" +%s 2>/dev/null)" && (( at < started )) &&
    { echo "desk: sidecar pid=$pid (re)started, no session up since"; return 1; }
  return 0
}

# spl_fleet_seat_id <id>: the id that runs <id>'s role seat now. A role seat
# has ONE real spool dir; the other letters link to it (role-seat-switch.sh,
# SPL-1685): <id> a link to a sibling letter of the same seat = that letter.
# Anything else is <id> itself. So the lease follows an in-place switch at its
# next tick, before lease.conf (read once per loop) catches up.
spl_fleet_seat_id() {
  local id="$1" r="${SPOOL_ROOT:-/var/spool-hub}" t
  [[ "$id" =~ ^${SPL_ROLE_SEAT_RX}$ && -L "$r/$id" ]] || { echo "$id"; return 0; }
  t="$(readlink "$r/$id")"; t="${t##*/}"
  [[ "$t" =~ ^${SPL_ROLE_SEAT_RX}$ && "${t#*-}" == "${id#*-}" && -d "$r/$t" && ! -L "$r/$t" ]] && { echo "$t"; return 0; }
  echo "$id"
}

# Is <box> listed in LEASE_INTERMITTENT (a box that loses power routinely)?
spl_fleet_intermittent() { [[ ",${LEASE_INTERMITTENT:-}," == *",$1,"* ]]; }

# Take-over condition 2 (owner, 27f01e16, 2026-10-02): an orchestrator (and,
# since t1 865b7a05, a dispatch seat) that is alive and able but STUCK - idle while a message waits. On 2026-10-02
# 16:37Z-18:27Z a stray character in its input box stopped every poke: 93
# unread, and nothing failed over because the lease follows the process.
# Stuck = the oldest inbox message that arrived AFTER the agent's last activity
# is older than LEASE_UNREAD_MAX s (600; 0 = off) and no turn is in progress.
# - last activity: the newest mtime of a transcript (*.jsonl) in the agent's
#   project dir (<HOME>/.claude/projects/<cwd, non-alphanumerics as ->), which
#   grows with every prompt, tool call and tool result;
# - a turn in progress: the spinner "…(12s · ↓ 214 tokens)" in the pane footer,
#   or grok's "[stop]" at the end of its spinner line (SPL-1696); a long tool
#   call writes nothing to the transcript but shows the spinner (a frozen
#   spinner is spl_lease_stall's case, not this one);
# - a message read and handled earlier is older than the last activity, so an
#   inbox nobody archives never counts against an agent that is working.
# Prints why when stuck. Fails OPEN: no transcript or no pane = not stuck.
# The stuck orchestrator is no candidate, so its machine stops renewing and the
# standby machine takes over by rule 1 (silent > LEASE_STALE).
spl_fleet_stuck() {
  local id="$1" pid="$2" max="${LEASE_UNREAD_MAX:-600}" act text now oldest
  [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )) || return 0
  act="$(spl_lease_activity "$pid" 2>/dev/null)"
  [[ "$act" =~ ^[0-9]+$ ]] || return 0
  oldest="$(find "${SPOOL_ROOT:-/var/spool-hub}/$id/inbox" -maxdepth 1 -type f -name '*.json' -newermt "@$act" \
    -printf '%T@\n' 2>/dev/null | sort -n | sed -n 1p)"
  oldest="${oldest%.*}"
  [[ "$oldest" =~ ^[0-9]+$ ]] || return 0
  now="$(spl_lease_now)"
  (( now - oldest > max )) || return 0
  text="$(spl_lease_pane_text "$pid" 2>/dev/null)" || return 0
  grep -v '^[[:space:]]*$' <<<"$text" | tail -n "${LEASE_PANE_TAIL:-12}" |
    grep -E -- '…[[:space:]]*\([0-9][^)]*\)|….*\[stop\][[:space:]]*$' >/dev/null && return 0
  echo "oldest unread $((now - oldest))s > ${max}s, idle $((now - act))s"
}

# The epoch of <pid>'s last ACTIVITY: the newest transcript entry that proves
# the model produced something (a reply that is not an API error, or a tool
# result). A prompt (a poke), an attachment, a queue or system entry and an
# isApiErrorMessage reply are not activity (spec 093 FR-000: on 2026-10-05
# every poke wrote its prompt and its "Login expired" reply, so a dead login
# looked active). With no such entry in the last LEASE_TRANSCRIPT_TAIL lines,
# the oldest entry there (the activity is older still); empty when unknown.
# LEASE_ACTIVITY_CMD (called with the pid) replaces it in the tests.
spl_lease_activity() {
  local pid="$1"
  # shellcheck disable=SC2086 # a command line, split on purpose
  [[ -n "${LEASE_ACTIVITY_CMD:-}" ]] && { $LEASE_ACTIVITY_CMD "$pid"; return; }
  spl_lease_transcript_tail "$pid" | jq -Rrn '
    def ts: (.timestamp // "") | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch null);
    [inputs | fromjson? // empty | select(type == "object")] as $e
    | ([$e[] | select((.type == "assistant" and .isApiErrorMessage != true)
        or (.type == "user" and (.message.content | type) == "array"
            and any(.message.content[]; type == "object" and .type == "tool_result")))
        | ts | select(. != null)] | max) as $m
    | if $m != null then $m else ([$e[] | ts | select(. != null)] | min // empty) end
    | floor' 2>/dev/null
}

# "ok" when <pid>'s last assistant entry is a real reply, "error" when it is
# an isApiErrorMessage one (Login expired, usage limit), empty when unknown.
# A grok session's entries (.grok, SPL-1696) carry no API error, so they stay
# unknown here: a banner over a grok pane is judged as before.
spl_lease_last_turn() {
  spl_lease_transcript_tail "$1" | jq -Rrn '
    [inputs | fromjson? // empty | select(type == "object" and .type == "assistant" and .grok == null)] | last
    | if . == null then empty elif .isApiErrorMessage == true then "error" else "ok" end' 2>/dev/null
}

# The last LEASE_TRANSCRIPT_TAIL (400) lines of <pid>'s transcript: the
# session file named by <HOME>/.claude/sessions/<pid>.json, else the newest
# *.jsonl of its project dir (<HOME>/.claude/projects/<cwd, non-alphanumerics
# as ->), which agents sharing a cwd also write. A grok pid (comm grok,
# SPL-1696) reads its own session instead, never a claude transcript of its
# cwd: <HOME>/.grok/sessions/<cwd, url-encoded>/<sid>/updates.jsonl, sid from
# <HOME>/.grok/active_sessions.json by pid, else the cwd's newest session.
# Its lines come out in the claude shape the readers know: a message, thought
# or tool call is an "assistant" entry, a finished tool call a "user"
# tool_result, a prompt a "user" text, the rest "system". Read through the
# owner when it is another user's. LEASE_TRANSCRIPT_CMD (called with the pid)
# replaces it in the tests.
spl_lease_transcript_tail() {
  local pid="$1" root="${LEASE_PROC_ROOT:-/proc}" n="${LEASE_TRANSCRIPT_TAIL:-400}" home cwd comm
  # shellcheck disable=SC2086 # a command line, split on purpose
  [[ -n "${LEASE_TRANSCRIPT_CMD:-}" ]] && { $LEASE_TRANSCRIPT_CMD "$pid"; return 0; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=400
  declare -F spool_proc_environ >/dev/null || return 0
  home="$(spool_proc_environ "$root" "$pid" 2>/dev/null | tr '\0' '\n' | sed -n 's/^HOME=//p' | sed -n 1p)"
  cwd="$(readlink "$root/$pid/cwd" 2>/dev/null)"
  [[ -z "$cwd" ]] && cwd="$(spool_proc_as_owner "$root" "$pid" readlink "$root/$pid/cwd")"
  [[ -n "$home" && -n "$cwd" ]] || return 0
  comm="$(cat "$root/$pid/comm" 2>/dev/null)"
  # shellcheck disable=SC2016 # expanded by the inner shell
  local -a q=(bash -c '
    if [ "$5" = grok ]; then
      g="$1/.grok" cwd="$2" sid="" f=""
      if [ -r "$g/active_sessions.json" ]; then
        sid="$(jq -r --argjson p "$3" "[.[]? | select(.pid == \$p)] | last | .session_id // empty" "$g/active_sessions.json" 2>/dev/null)"
        c="$(jq -r --argjson p "$3" "[.[]? | select(.pid == \$p)] | last | .cwd // empty" "$g/active_sessions.json" 2>/dev/null)"
        [ -n "$c" ] && cwd="$c"
      fi
      d="$g/sessions/$(jq -rn --arg c "$cwd" "\$c | @uri")"
      [ -n "$sid" ] && [ -f "$d/$sid/updates.jsonl" ] && f="$d/$sid/updates.jsonl"
      [ -n "$f" ] || f="$(find "$d" -mindepth 2 -maxdepth 2 -name updates.jsonl -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d" " -f2-)"
      [ -n "$f" ] || exit 0
      tail -n "$4" "$f" | jq -Rc "
        fromjson? // empty | select(type == \"object\" and (.timestamp | type) == \"number\")
        | (.timestamp | floor | todateiso8601) as \$t | (.params.update // {}) as \$u | (\$u.sessionUpdate // \"\") as \$k
        | {timestamp: \$t, grok: \$k} + (
            if \$k == \"agent_message_chunk\" or \$k == \"agent_thought_chunk\" or \$k == \"tool_call\" then {type: \"assistant\"}
            elif \$k == \"tool_call_update\" and (\$u.status == \"completed\" or \$u.status == \"failed\") then
              {type: \"user\", message: {content: [{type: \"tool_result\", tool_use_id: (\$u.toolCallId // \"\")}]}}
            elif \$k == \"user_message_chunk\" then {type: \"user\", message: {content: \"\"}}
            else {type: \"system\"} end)" 2>/dev/null
      exit 0
    fi
    s="$1/.claude/sessions/$3.json" sid="" cwd="$2" f=""
    if [ -r "$s" ]; then
      sid="$(jq -r ".sessionId // empty" "$s" 2>/dev/null)"
      c="$(jq -r ".cwd // empty" "$s" 2>/dev/null)"; [ -n "$c" ] && cwd="$c"
    fi
    d="$1/.claude/projects/$(printf "%s" "$cwd" | sed "s/[^A-Za-z0-9]/-/g")"
    [ -n "$sid" ] && [ -f "$d/$sid.jsonl" ] && f="$d/$sid.jsonl"
    [ -n "$f" ] || f="$(find "$d" -maxdepth 1 -name "*.jsonl" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d" " -f2-)"
    [ -n "$f" ] && tail -n "$4" "$f"' _ "$home" "$cwd" "$pid" "$n" "$comm")
  # the agent user's projects and sessions are its own (0700): nothing read
  # directly is read through the owner
  local out
  out="$("${q[@]}" 2>/dev/null)"
  [[ -n "$out" ]] || out="$(spool_proc_as_owner "$root" "$pid" "${q[@]}")"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# ONE notice per orchestrator take-over (27f01e16), posted by the new
# holder's desk as a new topic of the fleet's ops channel (do_spl_fleet_notice,
# cnf env.fleet_notices.channel), never a DM to the owner (SPL-2584, t1
# 4b49e47d msg 6c089b4a; how-to-post.md rule 18). LEASE_OWNER_CMD replaces the
# post (the text on stdin). In the background: a slow hub must not stall the
# tick.
spl_fleet_owner_dm() {
  local who="$1" text="$2"
  if [[ -n "${LEASE_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $LEASE_OWNER_CMD <<<"$text" >/dev/null 2>&1 || spl_lease_log "WARN ops notice failed (LEASE_OWNER_CMD)"
    spl_lease_log "OPS-NOTICE orch take-over: $who"; return 0
  fi
  ( ENV="${LEASE_ENV:-}" TENANT_ID="${LEASE_TENANT:-}" DESK_BOX="${LEASE_DESK_BOX:-}" DESK_AGENT="${who%@*}" \
      DESK_KIND=note DESK_BODY="$text" DRY_RUN=0 \
      timeout "${LEASE_OWNER_TIMEOUT:-120}" "${LEASE_ASKS_RUN:-$PROJ_PATH/run}" -a do_spl_fleet_notice \
      >>"$LEASE_DIR/owner-dm.out" 2>&1 7>&- 8>&- & ) 2>/dev/null
  spl_lease_log "OPS-NOTICE orch take-over: $who -> the ops channel"
}

# Why each local agent of a role is not a candidate: "<id>: <why>; ...".
spl_fleet_why() {
  local id out=""
  for id in $(spl_fleet_role_agents "$1"); do out+="${out:+; }$id: $(cat "$LEASE_DIR/able.$id" 2>/dev/null)"; done
  echo "$out"
}

# The local agents of a role, in order (who hears ACTIVE / STANDBY): its own
# ids, each as its seat runs it now (spl_fleet_seat_id: c-001 switched in
# place to grok is g-001). No separate fallback seats (SPL-2544).
spl_fleet_role_agents() {
  case "$1" in
    orch) spl_fleet_seat_id "$LEASE_ORCH" ;;
    dispatch) echo "$(spl_fleet_seat_id "$LEASE_MASTER") $(spl_fleet_seat_id "$LEASE_FAILOVER")" ;;
  esac
}

spl_fleet_mirror_file() { [[ "$1" == dispatch ]] && echo "$LEASE_FILE" || echo "$LEASE_FILE.$1"; }

# One role's tick: read, decide, compare-and-set, mirror, tell.
spl_fleet_role_tick() {
  local role="$1" me="$LEASE_MACHINE" cand out hm want="" handback=false ok now since sincef hold="${LEASE_HOLDDOWN:-300}"
  local ct=0 ht=0 wait
  ok="$LEASE_DIR/fleet.$role.ok"
  now="$(spl_lease_now)"
  spl_fleet_pin "$role"
  local pinv="LEASE_PIN_BOX_${role^^}"
  cand="$(spl_fleet_candidate "$role")"
  [[ -n "$cand" ]] && ct="$(spl_fleet_tier "$cand")"
  # the hold-down clock (spec 092): "<first> <last> <tier>", the first and the
  # last tick of this unbroken run with a candidate of that vendor tier. A gap
  # over LEASE_STALE (the box was off: the file outlives a power cut) breaks the
  # run like a tick with none; so does a change of tier (SPL-2521: a claude seat
  # able again starts its own hold-down).
  local last="" stier=""; since=""
  sincef="$LEASE_DIR/fleet.$role.able-since"
  [[ -s "$sincef" ]] && read -r since last stier < "$sincef"
  [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] && (( now - last <= LEASE_STALE )) &&
    [[ -z "$stier" || "$stier" == "$ct" ]] || since="$now"
  if [[ -z "$cand" ]]; then rm -f "$sincef"; else echo "$since $now $ct" > "$sincef"; fi
  if ! out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" || ! spl_fleet_read "$out"; then
    spl_fleet_unreachable "$role" "$now" "$out"; return 0
  fi
  hm=""; [[ "$FH" == *@* ]] && hm="${FH##*@}"
  # the hub's silence of the holder, for the asks tick's no-orchestrator alert
  spl_fleet_age_write "$role" "$now"
  [[ -n "$FH" ]] && ht="$(spl_fleet_tier "$FH")"
  wait=$(( LEASE_STALE + ct * ${LEASE_FALLBACK_WAIT:-60} ))
  if [[ -z "$cand" ]]; then
    spl_fleet_nocand "$role" "$hm" "$now"; want="$FWANT"
  elif (( FG == 0 )) || { [[ "$hm" == "$me" ]] && (( ct <= ht )); }; then
    want="$(spl_fleet_seat_move "$role" "$cand" "$ct" "$ht")"
  elif [[ "$hm" == "$me" ]] || (( FA > LEASE_STALE )); then
    # stale, or ours with only a worse vendor left (SPL-2521): a fallback
    # seat waits LEASE_FALLBACK_WAIT per vendor step, a claude seat does not
    if (( FA > wait )); then
      want="$cand@$me"
    else
      spl_fleet_once "$role.fallback-wait" "FALLBACK-WAIT $role: $FH silent ${FA}s and this machine's best able seat is $cand ($(spl_fleet_vendor "$cand")): it takes $role at ${wait}s unless an able seat of a better vendor on any box does first ($(spl_fleet_why "$role"))"
    fi
  elif (( ct < ht )) || { (( ct == ht )) && spl_fleet_outranks "$me" "$hm" "$role"; }; then
    # the handback (spec 092 FR-001): a returning box takes nothing back until
    # proven healthy; a better vendor (SPL-2521) outranks any machine rank
    if (( ct == ht )) && spl_fleet_intermittent "$me" && [[ "$me" != "${!pinv:-}" ]]; then
      spl_fleet_once "$role.hold-int" "HOLD $role: $me is intermittent (LEASE_INTERMITTENT): it takes $role only when $FH goes stale"
    elif (( now - since < hold )); then
      spl_fleet_once "$role.hold" "HOLD $role: $me able $((now - since))s < LEASE_HOLDDOWN ${hold}s: $FH keeps it"
    else
      want="$cand@$me" handback=true
    fi
  fi
  [[ -n "$want" || -z "$cand" ]] && rm -f "$LEASE_DIR/fleet.$role.hold" "$LEASE_DIR/fleet.$role.hold-int" "$LEASE_DIR/fleet.$role.fallback-wait"
  [[ "$hm" == "$me" ]] || rm -f "$LEASE_DIR/fleet.$role.nolocal"
  [[ "$hm" == "$me" && -z "$cand" ]] || rm -f "$LEASE_DIR/fleet.$role.nolocal-alert"
  local won=false
  if [[ -n "$want" ]]; then
    local before="$FH" age="$FA"
    if out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" --holder "$want" --if-gen "$FG" 2>&1)" && spl_fleet_read "$out"; then
      [[ "$FW" == true ]] && { echo "$now" > "$ok"; won=true; }
      [[ "$FW" == true && -n "$before" && "${before##*@}" != "$me" ]] &&
        spl_lease_log "FLEET $role: $me takes over from $before (silent ${age}s, rank $(spl_fleet_rank "${before##*@}" "$role") -> $(spl_fleet_rank "$me" "$role"))"
      [[ "$FW" == true && -n "$before" && "$before" != "$want" ]] && (( ct != ht )) &&
        spl_lease_log "VENDOR $role: $before ($(spl_fleet_vendor "${before%@*}")) -> $want ($(spl_fleet_vendor "$cand")), silent ${age}s"
      # a failover (not a priority handback) of the orchestrator: tell the owner
      # once; a switch to a fallback vendor on the same machine is one too
      [[ "$FW" == true && "$role" == orch && -n "$before" ]] && { [[ "${before##*@}" != "$me" ]] || (( ct != ht )); } && (( age > LEASE_STALE )) &&
        spl_fleet_owner_dm "$want" "Orchestrator failover: $want took over from $before, silent ${age}s - its process is gone, stalled, or it sat idle with an unread message older than $(( ${LEASE_UNREAD_MAX:-600} / 60 )) min. $want acts for the fleet now and hands back when $before is able again."
    else
      spl_fleet_unreachable "$role" "$now" "$out"; return 0
    fi
  fi
  rm -f "$LEASE_DIR/fleet.$role.unreachable"
  [[ "$won" == true && "$handback" == true ]] && spl_fleet_handback_start "$role" "$want" "$before" "$now"
  spl_fleet_apply "$role" "$(spl_fleet_shown "$role" "$now")" "$now"
  # the holder (this machine, just written) copies it into every served tenant
  [[ "$won" == true ]] && spl_fleet_mirror_out "$role" "$FH"
  return 0
}

# ---- a same-box seat move waits out a blip (SPL-3069) ------------------------
# 2026-10-23 13:32:34Z-13:36:42Z on sat, no rotation: dispatch went c-002 ->
# c-003 -> c-002 -> c-003 -> c-002, each move telling one seat ACTIVE and the
# other STANDBY. Each move away followed a watchdog S5 HIT on c-002 (wd.log
# 13:31:45Z and 13:34:15Z, "the same call with the same result 5 times", OK
# again 90 s and 60 s later): a fresh HIT is not able (spl_lease_agent_why),
# the next able seat of the role took the row on that tick, and c-002's next
# able tick took it back. Now a move between two seats of this box at the
# same vendor tier is made only once it was wanted LEASE_SEAT_HOLD (2) ticks
# in a row, the move back too; until then the holder keeps the row
# (SEAT-HOLD, logged once). A holder that cannot act for good moves at once
# (spl_fleet_seat_gone): no live process, a rotation hold, a watchdog S2
# (limit) HIT, a stalled pane, a stuck unread. A vendor switch (another tier)
# and a cross-box move keep their own rules.

# spl_fleet_seat_gone <id>: 0 + why when <id> cannot act for good: no live
# process, a rotation hold, or a verdict in able.<id> (this tick's, when <id>
# was tried) other than "able" or a fresh watchdog HIT that is no S2 limit: a
# stalled pane (a limit, a lost login) or an unread over LEASE_UNREAD_MAX
# lasts. Files only, no pane read.
spl_fleet_seat_gone() {
  local why=""
  [[ -n "$(spl_lease_agent_pid "$1")" ]] || { echo "no live process"; return 0; }
  why="$(spl_lease_held "$1")"
  [[ -n "$why" ]] && { echo "$why"; return 0; }
  read -r why 2>/dev/null < "$LEASE_DIR/able.$1" || true
  [[ -z "$why" || "$why" == able ]] && return 1
  [[ "$why" == "wd "* && "$why" != "wd S2:"* ]] && return 1
  echo "$why"
}

# spl_fleet_seat_move <role> <cand> <cand tier> <holder tier>: the holder to
# write on a tick that may write <cand>@<this box>: that, or FH (the holder
# keeps it) while a same-box move between seats of one tier waits.
spl_fleet_seat_move() {
  local role="$1" me="$LEASE_MACHINE" f="$LEASE_DIR/fleet.$1.seat-move" from="" to="" n=0 at=0 now
  local hold="${LEASE_SEAT_HOLD:-2}"
  now="$(spl_lease_now)"
  if (( FG == 0 || $3 != $4 )) || [[ "${FH##*@}" != "$me" || "$FH" == "$2@$me" ]] ||
    [[ " $(spl_fleet_role_agents "$role") " != *" ${FH%@*} "* ]] || spl_fleet_seat_gone "${FH%@*}" >/dev/null; then
    rm -f "$f"; echo "$2@$me"; return 0
  fi
  [[ -s "$f" ]] && read -r from to n at < "$f"
  [[ "$from $to" == "$FH $2@$me" && "$n" =~ ^[0-9]+$ && "$at" =~ ^[0-9]+$ ]] && (( now - at <= LEASE_STALE )) || n=0
  n=$((n + 1))
  (( n >= hold )) && { rm -f "$f"; echo "$2@$me"; return 0; }
  echo "$FH $2@$me $n $now" > "$f"
  (( n == 1 )) && rm -f "$LEASE_DIR/fleet.$role.seat-hold"
  spl_fleet_once "$role.seat-hold" "SEAT-HOLD $role: $FH keeps it, $2 takes it only if wanted $hold ticks in a row (LEASE_SEAT_HOLD; $(spl_fleet_why "$role"))"
  echo "$FH"
}

# ---- a far-off limit hands the role over at once (SPL-2892) ------------------
# 2026-10-22 10:23:39Z: the orch seat's claude hit its weekly limit (reset 2
# days away), grok was on its limit and agy is barred from the role by the
# data rule, so the holder box had no vendor left and retried its in-place
# switch every 2 min. Another box took the role only once the row went stale
# AND one of its seats was able (11:01:51Z, 38 min). A limit with a known
# reset is final, so waiting LEASE_STALE for the row to age buys nothing:
# when every seat of the role on the holder box sits on a watchdog S2
# kind=limit verdict (able.<id> "wd S2: HIT", <wd dir>/<id>.limit) that resets
# more than LEASE_STALE from now, the holder box writes the hub row over to
# the role's seat on the next box of the role's ranking (LEASE_ORCH /
# LEASE_MASTER: ids 001-003 exist on every box). That box's able seat renews
# it on its next tick, as its own row; a box whose seat cannot act lets it go
# stale as before. ONE hop only: a box hands off only a row its own last write
# made (fleet.<role>.ok), never one handed to it, so two limited boxes never
# ping-pong. A shorter limit, a stall or a dead process keep the stale path.
# LEASE_HANDOFF=0 turns it off.

# spl_fleet_nocand <role> <holder box> <now>: no seat of the role can act
# here. Sets FWANT to the holder to write (a handoff), else empty after the
# NO-LOCAL-AGENT line (a role held here) and the in-place vendor switch.
spl_fleet_nocand() {
  FWANT=""
  [[ "$2" == "$LEASE_MACHINE" ]] && FWANT="$(spl_fleet_handoff "$1" "$3")" && return 0
  FWANT=""
  [[ "$2" == "$LEASE_MACHINE" ]] && spl_fleet_nolocal "$1"
  spl_fleet_switch_tick "$1"
}

# spl_fleet_handoff <role> <now>: prints the new holder and returns 0 when
# this machine hands <role> over; 1 when it does not.
spl_fleet_handoff() {
  local role="$1" now="$2" id why r until="" won="" box="" k="LEASE_PRIORITY_${1^^}" seat m
  [[ "${LEASE_HANDOFF:-1}" == 1 ]] || return 1
  read -r won < "$LEASE_DIR/fleet.$role.ok" 2>/dev/null || return 1
  [[ "$won" =~ ^[0-9]+$ ]] && spl_fleet_age_known && (( now - FA - won <= LEASE_PERIOD / 2 )) || return 1
  for id in $(spl_fleet_role_agents "$role"); do
    why="$(cat "$LEASE_DIR/able.$id" 2>/dev/null)"
    [[ "$why" == "wd S2: HIT"* ]] || return 1
    read -r r < "${WD_STATE_DIR:-$LEASE_DIR/wd}/$id.limit" 2>/dev/null || return 1
    [[ "$r" =~ ^[0-9]+$ ]] && (( r - now > LEASE_STALE )) || return 1
    [[ -z "$until" ]] || (( r < until )) && until="$r"
  done
  [[ -n "$until" ]] || return 1
  [[ -n "${!k:-}" ]] || k=LEASE_PRIORITY
  IFS=, read -ra _ranked <<<"${!k:-}"
  for m in "${_ranked[@]}"; do [[ -n "$m" && "$m" != "$LEASE_MACHINE" ]] && { box="$m"; break; }; done
  [[ -n "$box" ]] || return 1
  case "$role" in orch) seat="$LEASE_ORCH" ;; dispatch) seat="$LEASE_MASTER" ;; *) return 1 ;; esac
  spl_lease_log "HANDOFF $role: $(spl_fleet_role_seat "$role") cannot act until $(date -u -d "@$until" +%FT%TZ) (watchdog S2 kind=limit) and no seat of $role here can: the hub row goes to $seat@$box now, not after LEASE_STALE"
  echo "$seat@$box"
}

# ---- a rank handback names ONE holder (2026-10-11, two holders for 54 s) ------
# Every box reads the hub row once per tick. A handback takes the row from a
# holder that is alive and renewing (07:59:55Z: "silent 19s"), and that box
# sees it only on its next read, up to one LEASE_PERIOD later (sat: 54 s).
# Mirrored at once, the claimant told its seat ACTIVE while the old seat was
# still ACTIVE. Now the claimant keeps naming the old holder locally for one
# LEASE_PERIOD after its win (fleet.<role>.handback = "<epoch> <old> <new>"),
# by which time the old box has read the row and stood its seat down; then it
# names itself and tells its seat ACTIVE. The hub row (the post routing) moves
# at once. A take-over from a stale or absent holder waits for nobody.
# The wait ends on a tick that cannot read the hub too (SPL-2246,
# 2026-10-16 19:15-19:18Z: every dial after the win hung, the claimant kept
# naming the old box while the old box read the claimant from the hub, both
# seats STANDBY): see spl_fleet_unreachable.

# spl_fleet_handback_start <role> <new> <old> <now>: start the wait, log it once.
spl_fleet_handback_start() {
  echo "$4 $3 $2" > "$LEASE_DIR/fleet.$1.handback"
  spl_lease_log "HANDBACK $1: $2 holds it on the hub; this machine names $3 until ${3##*@} has read it (one LEASE_PERIOD, ${LEASE_PERIOD}s), then tells its seat ACTIVE"
}

# spl_fleet_shown <role> <now>: the holder this machine mirrors, FH unless a
# handback of ours is still inside its wait. A row no longer ours ends it.
spl_fleet_shown() {
  local f="$LEASE_DIR/fleet.$1.handback" at="" old="" new=""
  [[ -s "$f" ]] && read -r at old new < "$f"
  if [[ "$at" =~ ^[0-9]+$ && -n "$old" && "${FH##*@}" == "$LEASE_MACHINE" ]] && (( $2 - at < LEASE_PERIOD )); then
    echo "$old"; return 0
  fi
  rm -f "$f"
  echo "$FH"
}

# A hub call failed. Holding on past LEASE_STALE without a renewal means the
# other machine may already act: demote locally rather than act twice.
# A handback of ours past its wait ends here too: inside LEASE_STALE of our
# last won write the hub row is still ours, so this machine names itself.
spl_fleet_unreachable() {
  local role="$1" now="$2" last=0 mine hb="$LEASE_DIR/fleet.$1.handback" at="" old="" new=""
  spl_fleet_once "$role.unreachable" "HUB-UNREACHABLE $role: $(tr '\n' ' ' <<<"$3" | cut -c1-200)"
  # the holder's silence counts from here at the most (spl_fleet_switch_tick)
  echo "$now" > "$LEASE_DIR/fleet.$role.hub-down" 2>/dev/null || true
  [[ -f "$LEASE_DIR/fleet.$role.ok" ]] && last="$(cat "$LEASE_DIR/fleet.$role.ok")"
  [[ -s "$hb" ]] && read -r at old new < "$hb"
  if [[ "$at" =~ ^[0-9]+$ && "$new" == *@"$LEASE_MACHINE" ]] && (( now - at >= LEASE_PERIOD && now - last <= LEASE_STALE )); then
    rm -f "$hb"; spl_fleet_apply "$role" "$new" "$now"
  fi
  mine="$(cat "$LEASE_DIR/fleet.$role.holder" 2>/dev/null)"
  [[ "${mine##*@}" == "$LEASE_MACHINE" ]] && (( now - last > LEASE_STALE )) &&
    spl_fleet_apply "$role" "none@unreachable" "$now"
  return 0
}

# Log a condition once until it clears (the marker is removed by the caller).
spl_fleet_once() {
  [[ -f "$LEASE_DIR/fleet.$1" ]] && return 0
  touch "$LEASE_DIR/fleet.$1"; spl_lease_log "$2"
}

# ---- NO-LOCAL-AGENT with nowhere to fall (sat-alone plan row 10) -------------
# This machine holds <role> and no local seat can act. The lease log line
# alone was the whole signal: on 2026-10-18 01:35:46Z sat's weekly reboot left
# dispatch with no seat, and the role fell to the PC box. With the PC box off
# (the owner's absence windows) a stale lease has no other box to go to, so
# nobody dispatches until a seat is restarted by hand. Now, when no OTHER box
# of the role's ranking is healthy by the hub's beats (spl_fleet_health_get;
# degraded, recovering, or with no beat at all), ONE alert per episode: a post
# in #alerts (spl_fleet_alert_post) and a spool note to the orch holder
# (<dir>/fleet.orch.age, else LEASE_ORCH). The marker fleet.<role>.nolocal-alert
# clears when a local candidate is back or the role leaves this machine. No
# verdicts at all (LEASE_HEALTH=0, an unread beats list) = no judgement: the
# log line only, as before.

# spl_fleet_fresh_other <role>: prints the first OTHER box of the role's
# ranking whose beat verdict is healthy; rc 1 when there is none, rc 2 when
# the beats judged nobody (no verdicts: unknown) or a hub stall holds the box
# alerts (spl_fleet_stall_view: a box it explains counts healthy).
spl_fleet_fresh_other() {
  local role="$1" v k="LEASE_PRIORITY_${1^^}" m
  v="$(spl_fleet_health_get)"
  [[ -n "$v" && "$v" != '{}' ]] || return 2
  # a hub stall judges nobody (SPL-3196): no NO-LOCAL alert while it holds
  v="$(spl_fleet_stall_view "$v")" || return 2
  [[ -n "${!k:-}" ]] || k=LEASE_PRIORITY
  IFS=, read -ra _ranked <<<"${!k}"
  for m in "${_ranked[@]}"; do
    [[ -n "$m" && "$m" != "$LEASE_MACHINE" ]] || continue
    [[ "$(jq -r --arg b "$m" '.[$b].state // "none"' <<<"$v" 2>/dev/null)" == healthy ]] && { echo "$m"; return 0; }
  done
  return 1
}

# spl_fleet_nolocal <role>: the NO-LOCAL-AGENT line (once), and the alert when
# no other box can take the role.
spl_fleet_nolocal() {
  local role="$1" me="$LEASE_MACHINE" rc=0 to v others text k="LEASE_PRIORITY_${1^^}"
  [[ -n "${!k:-}" ]] || k=LEASE_PRIORITY
  spl_fleet_once "$role.nolocal" "NO-LOCAL-AGENT $role: this machine holds it ($FH) but has no live candidate able to act ($(spl_fleet_why "$role")); it goes stale in ${LEASE_STALE}s"
  [[ -f "$LEASE_DIR/fleet.$role.nolocal-alert" ]] && return 0
  spl_fleet_fresh_other "$role" >/dev/null || rc=$?
  (( rc == 1 )) || return 0
  v="$(spl_fleet_health_get)"
  others="$(jq -r --arg me "$me" --arg p "${!k:-}" '. as $v | [$p | split(",")[] | select(. != "" and . != $me)]
    | map("\(.): \($v[.].state // "no beats")") | join(", ")' <<<"$v" 2>/dev/null)"
  [[ -n "$others" ]] || others="no other box ranked"
  touch "$LEASE_DIR/fleet.$role.nolocal-alert"
  text="NO-LOCAL-AGENT $role on $me: it holds $role ($FH) with no seat able to act ($(spl_fleet_why "$role")), and no other box can take it ($others). Nobody acts as $role until a $role seat on $me is restarted."
  spl_lease_log "NO-LOCAL-ALERT $role: no other fresh box ($others)"
  spl_fleet_alert_post "$text" || true
  to=""; [[ -r "$LEASE_DIR/fleet.orch.age" ]] && read -r to _ < "$LEASE_DIR/fleet.orch.age"
  [[ "$to" == *@* && "$to" != none* ]] || to="$LEASE_ORCH"
  [[ "${to##*@}" == "$me" ]] && to="${to%@*}"
  spl_lease_tell "$to" "FLEET LEASE ALERT: $text"
  return 0
}

# Mirror the holder locally and tell the agents a change moves.
spl_fleet_apply() {
  local role="$1" holder="$2" now="$3" f prev id
  f="$(spl_fleet_mirror_file "$role")"
  # always <ID>@<box>: ids 001-003 exist on EVERY box, a bare id cannot tell them apart
  printf '%s %s\n' "$holder" "$now" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  prev="$(cat "$LEASE_DIR/fleet.$role.holder" 2>/dev/null)"
  [[ "$prev" == "$holder" ]] && return 0
  echo "$holder" > "$LEASE_DIR/fleet.$role.holder"
  spl_lease_log "FLEET $role: ${prev:-none} -> $holder"
  for id in $(spl_fleet_role_agents "$role"); do
    if [[ "$holder" == "$id@$LEASE_MACHINE" ]]; then
      # the asks to the orchestrator are the orchestrator's alone: a
      # dispatcher must never ack or close them (CLE-002 refused, msg ee1b0942)
      local asks=""
      [[ "$role" == orch ]] && asks=" and every open ask to the orchestrator (do_spl_orch_inbox: ack, then close each)"
      spl_lease_tell "$id" "FLEET LEASE $role: you are now ACTIVE (fleet $LEASE_FLEET, was ${prev:-none}). Act for the whole fleet until told STANDBY; pick up what the previous holder left unanswered (do_spl_unanswered_sweep)$asks."
    elif [[ "$prev" == "$id@$LEASE_MACHINE" ]]; then
      spl_lease_tell "$id" "FLEET LEASE $role: STANDBY - $holder holds it now. Finish the message in hand, then do not route, spawn or post; read and stay ready."
    fi
  done
  [[ "$role" == dispatch && "$holder" != "$LEASE_ORCH@$LEASE_MACHINE" ]] &&
    spl_lease_tell "$LEASE_ORCH" "FLEET LEASE dispatch: ${prev:-none} -> $holder."
  return 0
}

spl_lease_fleet_tick() {
  spl_fleet_role_tick orch
  spl_fleet_role_tick dispatch
  spl_fleet_bench_tick
  spl_lease_asks_tick
  spl_lease_agent_run_tick
  return 0
}

# The asks timer (CLE-77929, SPEC-spool-fleet-roles.md 4.3): every machine
# pushes its journal asks to the hub, and the orch holder's machine re-raises
# what nobody acked (do_spl_asks_tick). Its own process, so it runs the
# current code and can never stall or kill the lease; it serialises itself.
# LEASE_ASKS=0 turns it off (the tests' default, under SPOOL_TEST=1).
spl_lease_asks_tick() {
  local on="${LEASE_ASKS:-1}"
  [[ "${SPOOL_TEST:-0}" == 1 ]] && on="${LEASE_ASKS:-0}"
  [[ "$on" == 1 ]] || return 0
  ( SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" timeout "${LEASE_ASKS_TIMEOUT:-120}" "${LEASE_ASKS_RUN:-$PROJ_PATH/run}" \
      -a do_spl_asks_tick >>"$LEASE_DIR/asks.out" 2>&1 7>&- 8>&- & ) 2>/dev/null
  return 0
}

# fleet-show: one line per role, "<role> <holder> <age-seconds> <gen>", from the hub.
spl_fleet_show() {
  local role out
  for role in orch dispatch; do
    out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" && spl_fleet_read "$out" ||
      { echo "$role ERROR $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; continue; }
    echo "$role ${FH:-none} $FA $FG"
  done
}
