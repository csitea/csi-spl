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
# @description            back from a machine later in LEASE_PRIORITY (handback).
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
# @param LEASE_FLEET (optional) - fleet mode: the fleet's name on the hub (else lease.conf)
# @param LEASE_MACHINE (optional) - fleet mode: this machine's box, default its desk box id (spl_desk_box_default)
# @param LEASE_PRIORITY (optional) - fleet mode: machines, comma-separated, preferred first
# @param LEASE_PRIORITY_ORCH / LEASE_PRIORITY_DISPATCH (optional) - fleet mode: that role's own machine ranking, same form as LEASE_PRIORITY (env or lease.conf); unset = LEASE_PRIORITY
# @param LEASE_UNREAD_MAX (optional) - fleet mode: an orchestrator idle while an inbox message newer than its last transcript write is older than this many s is stuck, no candidate (take-over condition 2), default 600, 0 = off
# @param LEASE_OWNER (optional) - fleet mode: the owner's HUM id DMed once per orch take-over (else lease.conf ASKS_OWNER); LEASE_OWNER_CMD replaces the DM
# @param LEASE_MIRROR_TENANTS (optional) - fleet mode: the tenants the holder copies the lease into, space-separated (default: every tenant this machine's desk box is pinned in, minus LEASE_TENANT and the test workspaces); LEASE_MIRROR_TIMEOUT (default 10 s) bounds each copy call
# @param LEASE_HOLDDOWN (optional) - fleet mode: a rank handback waits until this machine's candidate has been able this many s without a break (spec 092), default 300, 0 = at once
# @param LEASE_INTERMITTENT (optional) - fleet mode: boxes, comma-separated, that lose power routinely (a laptop): a listed box never hands back by rank, it takes a role only when empty or stale (env or lease.conf)
# @param LEASE_DESK_GATE / LEASE_DESK_DIR (optional) - fleet mode: 0 turns off the desk gate of the dispatch role (spec 092 FR-002); LEASE_DESK_DIR replaces the desk dir it reads (default <state>/desk/LEASE_TENANT/LEASE_DESK_BOX)
# @param LEASE_ENV / LEASE_TENANT / LEASE_DESK_BOX (optional) - fleet mode: the hub env, the tenant holding the lease, the pinned desk box whose key signs the calls (default spl_desk_box_default: SPOOL_DESK_BOX, else box-desk)
# @example LEASE_CMD=show ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=ensure ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=watch LEASE_MASTER=CLE-002 LEASE_FAILOVER=CLE-003 ./run -a do_spl_dispatch_lease
# @example LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease
#------------------------------------------------------------------------------
# this machine's desk box id (specs/058), also when sourced on its own
declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"

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
      LEASE_MASTER|LEASE_FAILOVER|LEASE_ORCH|LEASE_FLEET|LEASE_MACHINE|LEASE_PRIORITY|LEASE_PRIORITY_ORCH|LEASE_PRIORITY_DISPATCH|LEASE_ENV|LEASE_TENANT|LEASE_DESK_BOX|LEASE_INTERMITTENT|LEASE_HOLDDOWN)
        [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v" ;;
    esac
  done < <(grep -E '^LEASE_(MASTER|FAILOVER|ORCH)=[A-Za-z0-9_-]+$|^LEASE_(FLEET|MACHINE|ENV|TENANT|DESK_BOX)=[a-z0-9][a-z0-9-]*$|^LEASE_PRIORITY(_ORCH|_DISPATCH)?=[a-z0-9][a-z0-9,-]*$|^LEASE_INTERMITTENT=[a-z0-9][a-z0-9,-]*$|^LEASE_HOLDDOWN=[0-9]+$' "$LEASE_CONF")
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
. "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/proc-owner.inc.sh" 2>/dev/null || true

# The pid of a live claude process whose environment carries
# SPOOL_AGENT_ID=<id>; empty when there is none. The lowest pid wins, so two
# reads in a row agree. A claude of another user (the agent user) is read
# through its owner, one hop for all of them.
spl_lease_agent_pid() {
  local id="$1" root="${LEASE_PROC_ROOT:-/proc}" d pid comm
  local -a other=()
  {
    for d in "$root"/[0-9]*; do
      pid="${d##*/}"
      # `read`, not $(cat): a builtin, so the walk forks only for the few
      # claude processes (measured 2026-10-01: one fork per pid made a tick 26 s)
      comm=""; { read -r comm < "$d/comm"; } 2>/dev/null
      [[ "$comm" == claude ]] || continue
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
# For the dead-subscription REPORT; the lease itself keeps the claude-only rule.
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
LEASE_STALL_RE_DEFAULT='usage limit reached|limit reached[[:space:]]*·|limit resets|please run /login|invalid api key|oauth token (has )?expired'

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
# changes nothing.
spl_lease_agent_able() {
  local id="$1" pid why
  pid="$(spl_lease_agent_pid "$id")"
  if [[ -z "$pid" ]]; then why="no live process"
  else why="$(spl_lease_agent_why "$id" "$pid" dismiss)"
  fi
  printf '%s\n' "${why:-able}" > "$LEASE_DIR/able.$id" 2>/dev/null
  [[ -z "$why" ]] && echo "$pid"
  return 0
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
spl_lease_agent_run_report() {
  local out="$LEASE_DIR/agent-run.tsv" id pid why
  {
    echo "# agent-run v1 $(spl_lease_now)"
    while IFS= read -r id; do
      [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
      pid="$(spl_lease_agent_pid "$id")"
      why=""
      [[ -n "$pid" ]] && why="$(spl_lease_agent_why "$id" "$pid")"
      if [[ -z "$why" ]]; then printf '%s\trun\n' "$id"; else printf '%s\tstop\t%s\n' "$id" "${why//$'\t'/ }"; fi
    done < <(spl_lease_live_ids)
  } > "$out.$$" && mv -f "$out.$$" "$out"
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
  age=$(( $(spl_lease_now) - LT ))
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
  age=$(( $(spl_lease_now) - LT ))
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
    sleep "$LEASE_PERIOD"
  done
}

# This file, as the loops run it; its hash is the code version. It also
# hashes lease.conf and this machine's desk box id: a loop reads them once at
# its start, so a changed priority, fleet or box name (the box-desk -> <box>
# rename of spec 058) makes ensure replace it on the next tick, with no manual
# restart and no loop left acting on the old settings.
SPL_LEASE_SRC="${BASH_SOURCE[0]}"
spl_lease_code_ver() {
  { cat "$SPL_LEASE_SRC"; cat "${LEASE_CONF:-/dev/null}" 2>/dev/null; spl_desk_box_default; } | sha1sum | cut -c1-12
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
  else
    spl_lease_running fleet && { spl_lease_log "ensure stops fleet (no LEASE_FLEET)"; spl_lease_stop_one fleet || return 1; }
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

# The call goes to LEASE_TENANT, or to LEASE_AT_TENANT (the copies below)
# through this machine's desk pinned THERE; the stub gets it as LEASE_HUB_TENANT.
spl_fleet_hub() {
  local t="${LEASE_AT_TENANT:-${LEASE_TENANT:-}}"
  if [[ -n "${LEASE_HUB_CMD:-}" ]]; then LEASE_HUB_TENANT="${LEASE_AT_TENANT:-}" "$LEASE_HUB_CMD" lease "$@"; return; fi
  local d="$SPL_STATE_DIR/desk/$t/$LEASE_DESK_BOX"
  # spl_desk_spool's environment, under a timeout: a hung dial must not stall the tick
  SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$LEASE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$t" timeout "${LEASE_HUB_TIMEOUT:-30}" "$SPL_SPOOL" lease "$@"
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
    if out="$(LEASE_AT_TENANT="$t" LEASE_HUB_TIMEOUT="${LEASE_MIRROR_TIMEOUT:-10}" spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" &&
       spl_fleet_read "$out" &&
       out="$(LEASE_AT_TENANT="$t" LEASE_HUB_TIMEOUT="${LEASE_MIRROR_TIMEOUT:-10}" spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" --holder "$holder" --if-gen "$FG" 2>&1)" &&
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

# spl_fleet_rank <machine> <role>: its 0-based rank in the role's ranking
# (LEASE_PRIORITY_ORCH / LEASE_PRIORITY_DISPATCH, else LEASE_PRIORITY);
# unknown = last.
spl_fleet_rank() {
  local i=0 m k="LEASE_PRIORITY_${2^^}"
  [[ -n "${2:-}" && -n "${!k:-}" ]] || k=LEASE_PRIORITY
  IFS=, read -ra _ms <<<"${!k}"
  for m in "${_ms[@]}"; do [[ "$m" == "$1" ]] && { echo "$i"; return; }; i=$((i + 1)); done
  echo "$i"
}

# This machine's live candidate for a role (empty = none): the local order.
spl_fleet_candidate() {
  local id
  case "$1" in
    orch)
      local pid why
      pid="$(spl_lease_agent_able "$LEASE_ORCH")"
      [[ -n "$pid" ]] || return 0
      why="$(spl_fleet_stuck "$LEASE_ORCH" "$pid")"
      [[ -z "$why" ]] && { echo "$LEASE_ORCH"; return 0; }
      printf 'stuck pid=%s: %s\n' "$pid" "$why" > "$LEASE_DIR/able.$LEASE_ORCH" 2>/dev/null ;;
    dispatch)
      local pid why desk
      # the dispatcher is the seat that posts: no desk that can post, no candidate (spec 092 FR-002)
      if ! desk="$(spl_fleet_desk_able)"; then
        for id in "$LEASE_MASTER" "$LEASE_FAILOVER"; do printf '%s\n' "$desk" > "$LEASE_DIR/able.$id" 2>/dev/null; done
        return 0
      fi
      for id in "$LEASE_MASTER" "$LEASE_FAILOVER"; do
        pid="$(spl_lease_agent_able "$id")"
        [[ -n "$pid" ]] || continue
        why="$(spl_fleet_stuck "$id" "$pid")"
        [[ -z "$why" ]] && { echo "$id"; return 0; }
        printf 'stuck pid=%s: %s\n' "$pid" "$why" > "$LEASE_DIR/able.$id" 2>/dev/null
      done ;;
  esac
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
# - a turn in progress: the spinner "…(12s · ↓ 214 tokens)" in the pane footer;
#   a long tool call writes nothing to the transcript but shows the spinner
#   (a frozen spinner is spl_lease_stall's case, not this one);
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
  grep -v '^[[:space:]]*$' <<<"$text" | tail -n "${LEASE_PANE_TAIL:-12}" | grep -E -- '…[[:space:]]*\([0-9][^)]*\)' >/dev/null && return 0
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
spl_lease_last_turn() {
  spl_lease_transcript_tail "$1" | jq -Rrn '
    [inputs | fromjson? // empty | select(type == "object" and .type == "assistant")] | last
    | if . == null then empty elif .isApiErrorMessage == true then "error" else "ok" end' 2>/dev/null
}

# The last LEASE_TRANSCRIPT_TAIL (400) lines of <pid>'s transcript: the
# session file named by <HOME>/.claude/sessions/<pid>.json, else the newest
# *.jsonl of its project dir (<HOME>/.claude/projects/<cwd, non-alphanumerics
# as ->), which agents sharing a cwd also write. Read through the owner when
# it is another user's. LEASE_TRANSCRIPT_CMD (called with the pid) replaces it
# in the tests.
spl_lease_transcript_tail() {
  local pid="$1" root="${LEASE_PROC_ROOT:-/proc}" n="${LEASE_TRANSCRIPT_TAIL:-400}" home cwd
  # shellcheck disable=SC2086 # a command line, split on purpose
  [[ -n "${LEASE_TRANSCRIPT_CMD:-}" ]] && { $LEASE_TRANSCRIPT_CMD "$pid"; return 0; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=400
  declare -F spool_proc_environ >/dev/null || return 0
  home="$(spool_proc_environ "$root" "$pid" 2>/dev/null | tr '\0' '\n' | sed -n 's/^HOME=//p' | sed -n 1p)"
  cwd="$(readlink "$root/$pid/cwd" 2>/dev/null)"
  [[ -z "$cwd" ]] && cwd="$(spool_proc_as_owner "$root" "$pid" readlink "$root/$pid/cwd")"
  [[ -n "$home" && -n "$cwd" ]] || return 0
  # shellcheck disable=SC2016 # expanded by the inner shell
  local -a q=(bash -c '
    s="$1/.claude/sessions/$3.json" sid="" cwd="$2" f=""
    if [ -r "$s" ]; then
      sid="$(jq -r ".sessionId // empty" "$s" 2>/dev/null)"
      c="$(jq -r ".cwd // empty" "$s" 2>/dev/null)"; [ -n "$c" ] && cwd="$c"
    fi
    d="$1/.claude/projects/$(printf "%s" "$cwd" | sed "s/[^A-Za-z0-9]/-/g")"
    [ -n "$sid" ] && [ -f "$d/$sid.jsonl" ] && f="$d/$sid.jsonl"
    [ -n "$f" ] || f="$(find "$d" -maxdepth 1 -name "*.jsonl" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d" " -f2-)"
    [ -n "$f" ] && tail -n "$4" "$f"' _ "$home" "$cwd" "$pid" "$n")
  # the agent user's projects and sessions are its own (0700): nothing read
  # directly is read through the owner
  local out
  out="$("${q[@]}" 2>/dev/null)"
  [[ -n "$out" ]] || out="$(spool_proc_as_owner "$root" "$pid" "${q[@]}")"
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# The owner hears ONE message per orchestrator take-over (27f01e16): a DM
# from the new holder's desk to LEASE_OWNER, else lease.conf ASKS_OWNER (the
# owner leg of the asks, 4.3). LEASE_OWNER_CMD replaces the DM (the text on
# stdin). In the background: a slow hub must not stall the tick.
spl_fleet_owner_dm() {
  local who="$1" text="$2" owner="${LEASE_OWNER:-${ASKS_OWNER:-}}"
  if [[ -n "${LEASE_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $LEASE_OWNER_CMD <<<"$text" >/dev/null 2>&1 || spl_lease_log "WARN owner DM failed (LEASE_OWNER_CMD)"
    spl_lease_log "OWNER-DM orch take-over: $who"; return 0
  fi
  [[ -n "$owner" ]] || owner="$(sed -n 's/^ASKS_OWNER=\(HUM-[0-9][0-9]*\)$/\1/p' "$LEASE_CONF" 2>/dev/null | sed -n 1p)"
  [[ "$owner" =~ ^HUM-[0-9]+$ ]] ||
    { spl_lease_log "WARN orch take-over by $who: no owner to tell (LEASE_OWNER, or ASKS_OWNER in lease.conf)"; return 0; }
  ( ENV="$LEASE_ENV" TENANT_ID="$LEASE_TENANT" DESK_BOX="$LEASE_DESK_BOX" DESK_AGENT="${who%@*}" DESK_TO="$owner" \
      DESK_TASK="$(cat /proc/sys/kernel/random/uuid)" DESK_KIND=note DESK_BODY="$text" DRY_RUN=0 \
      timeout "${LEASE_OWNER_TIMEOUT:-120}" "${LEASE_ASKS_RUN:-$PROJ_PATH/run}" -a do_spl_desk_reply \
      >>"$LEASE_DIR/owner-dm.out" 2>&1 7>&- 8>&- & ) 2>/dev/null
  spl_lease_log "OWNER-DM orch take-over: $who -> $owner"
}

# Why each local agent of a role is not a candidate: "<id>: <why>; ...".
spl_fleet_why() {
  local id out=""
  for id in $(spl_fleet_role_agents "$1"); do out+="${out:+; }$id: $(cat "$LEASE_DIR/able.$id" 2>/dev/null)"; done
  echo "$out"
}

# The local agents of a role (who hears ACTIVE / STANDBY).
spl_fleet_role_agents() {
  case "$1" in orch) echo "$LEASE_ORCH" ;; dispatch) echo "$LEASE_MASTER $LEASE_FAILOVER" ;; esac
}

spl_fleet_mirror_file() { [[ "$1" == dispatch ]] && echo "$LEASE_FILE" || echo "$LEASE_FILE.$1"; }

# One role's tick: read, decide, compare-and-set, mirror, tell.
spl_fleet_role_tick() {
  local role="$1" me="$LEASE_MACHINE" cand out hm want="" ok now since sincef hold="${LEASE_HOLDDOWN:-300}"
  ok="$LEASE_DIR/fleet.$role.ok"
  now="$(spl_lease_now)"
  cand="$(spl_fleet_candidate "$role")"
  # the hold-down clock (spec 092): "<first> <last>", the first and the last
  # tick of this unbroken run with a candidate. A gap over LEASE_STALE (the box
  # was off: the file outlives a power cut) breaks the run like a tick with none.
  local last=""; since=""
  sincef="$LEASE_DIR/fleet.$role.able-since"
  [[ -s "$sincef" ]] && read -r since last < "$sincef"
  [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] && (( now - last <= LEASE_STALE )) || since="$now"
  if [[ -z "$cand" ]]; then rm -f "$sincef"; else echo "$since $now" > "$sincef"; fi
  if ! out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" 2>&1)" || ! spl_fleet_read "$out"; then
    spl_fleet_unreachable "$role" "$now" "$out"; return 0
  fi
  hm=""; [[ "$FH" == *@* ]] && hm="${FH##*@}"
  if [[ -z "$cand" ]]; then
    [[ "$hm" == "$me" ]] && spl_fleet_once "$role.nolocal" "NO-LOCAL-AGENT $role: this machine holds it ($FH) but has no live candidate able to act ($(spl_fleet_why "$role")); it goes stale in ${LEASE_STALE}s"
  elif (( FG == 0 )) || [[ "$hm" == "$me" ]] || (( FA > LEASE_STALE )); then
    want="$cand@$me"
  elif (( $(spl_fleet_rank "$me" "$role") < $(spl_fleet_rank "$hm" "$role") )); then
    # the handback (spec 092 FR-001): a returning box takes nothing back until proven healthy
    if spl_fleet_intermittent "$me"; then
      spl_fleet_once "$role.hold-int" "HOLD $role: $me is intermittent (LEASE_INTERMITTENT): it takes $role only when $FH goes stale"
    elif (( now - since < hold )); then
      spl_fleet_once "$role.hold" "HOLD $role: $me able $((now - since))s < LEASE_HOLDDOWN ${hold}s: $FH keeps it"
    else
      want="$cand@$me"
    fi
  fi
  [[ -n "$want" || -z "$cand" ]] && rm -f "$LEASE_DIR/fleet.$role.hold" "$LEASE_DIR/fleet.$role.hold-int"
  [[ "$hm" == "$me" ]] || rm -f "$LEASE_DIR/fleet.$role.nolocal"
  local won=false
  if [[ -n "$want" ]]; then
    local before="$FH" age="$FA"
    if out="$(spl_fleet_hub --fleet "$LEASE_FLEET" --role "$role" --holder "$want" --if-gen "$FG" 2>&1)" && spl_fleet_read "$out"; then
      [[ "$FW" == true ]] && { echo "$now" > "$ok"; won=true; }
      [[ "$FW" == true && -n "$before" && "${before##*@}" != "$me" ]] &&
        spl_lease_log "FLEET $role: $me takes over from $before (silent ${age}s, rank $(spl_fleet_rank "${before##*@}" "$role") -> $(spl_fleet_rank "$me" "$role"))"
      # a failover (not a priority handback) of the orchestrator: tell the owner once
      [[ "$FW" == true && "$role" == orch && -n "$before" && "${before##*@}" != "$me" ]] && (( age > LEASE_STALE )) &&
        spl_fleet_owner_dm "$want" "Orchestrator failover: $want took over from $before, silent ${age}s - its process is gone, stalled, or it sat idle with an unread message older than $(( ${LEASE_UNREAD_MAX:-600} / 60 )) min. $want acts for the fleet now and hands back when $before is able again."
    else
      spl_fleet_unreachable "$role" "$now" "$out"; return 0
    fi
  fi
  rm -f "$LEASE_DIR/fleet.$role.unreachable"
  spl_fleet_apply "$role" "$FH" "$now"
  # the holder (this machine, just written) copies it into every served tenant
  [[ "$won" == true ]] && spl_fleet_mirror_out "$role" "$FH"
  return 0
}

# A hub call failed. Holding on past LEASE_STALE without a renewal means the
# other machine may already act: demote locally rather than act twice.
spl_fleet_unreachable() {
  local role="$1" now="$2" last=0 mine
  spl_fleet_once "$role.unreachable" "HUB-UNREACHABLE $role: $(tr '\n' ' ' <<<"$3" | cut -c1-200)"
  [[ -f "$LEASE_DIR/fleet.$role.ok" ]] && last="$(cat "$LEASE_DIR/fleet.$role.ok")"
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
