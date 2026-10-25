#!/bin/bash
#------------------------------------------------------------------------------
# The shared pieces of the hourly role rotation (spec 060, plan section 1):
# do_spl_orch_rotate (CLE-77939) and do_spl_dispatch_rotate (CLE-77940) both
# source this file. No action lives here. Mechanical only (FR-001): every input
# is a file, a run action, /proc or tmux; nothing calls a model.
#
#   spl_rotate_conf                         settings: env > rotate.conf > defaults (FR-074, FR-090)
#   spl_rotate_role_vendor [FAMILY]         ROTATE_ROLE_VENDOR: the role successor's vendor (claude|grok; agy for dispatch), guarded
#   spl_rotate_grok_out                     why grok is out: the newest watchdog verdict of all grok seats is its limit (SPL-1820, SPL-2555)
#   spl_rotate_claude_out                   why claude cannot act: no CLI, its newest verdict a limit, a silent lease (SPL-1869)
#   spl_rotate_grok_why                     why grok cannot take a role seat (lane-mix, its limit, the lease); nothing = it can
#   spl_rotate_agy_why                      why agy cannot take a dispatch seat (lane-mix: CLI, sign-in, limit; the lease) (SPL-3395)
#   spl_rotate_vendor_id ID                 the seat id the successor's vendor gives it (SPL-1685), when it differs
#   spl_rotate_seat_switch OLD NEW          role-seat-switch.sh: the seat's spool dir to NEW, the other letters link to it
#   spl_rotate_failover_vendor ID           a seat do_spl_role_failover moved: claude once claude can act, else it stays (SPL-2544)
#   spl_rotate_failover_due ID              that seat, and claude can act again: the handback is due
#   spl_rotate_conf_flip KEY OLD NEW        lease.conf KEY=OLD -> NEW and the shell's KEY
#   spl_rotate_log RID PHASE RESULT DETAIL  one rotate.log line + the .state file (FR-002)
#   spl_agent_id_lock ID [ACTOR] [RID] [WAIT] the id lock of every start/stop actor (spec 102 4.2), 4 when held
#   spl_agent_id_unlock ID                  lets an id lock this shell holds go before the shell ends
#   spl_rotate_stale                        a gone run's pre-spawn ctx starts clean, never resumed (SPL-1837)
#   spl_rotate_detach_if_inside FAM ID PANE.. a run inside a pane it quiesces re-runs itself detached (SPL-1837)
#   spl_rotate_quiesce PANE                 grace, Escape, re-wait; prints idle|interrupted|busy-rotated (FR-011)
#   spl_rotate_handoff ROLE ID RID OUT      the handoff file, spec section 6 (FR-012, FR-025)
#   spl_rotate_spawn ID SEED                rename the old window, spawn under the same id, adopt it in the map (FR-006, FR-007, FR-013)
#   spl_rotate_start_check PANE             a known dialog on the new pane fails the start at once (ROTATE_ERR names it)
#   spl_rotate_restore ID OLD_PANE NEW_PANE the failure path: new closed, old name and map entry back (FR-013, FR-014, FR-027)
#   spl_rotate_retire PANE PID              /exit-clean, /exit once its turn ends, wait, TERM, wait, KILL (FR-015)
#   spl_rotate_ack_wait ID RID TIMEOUT      the new session's result on task <role>-rotate-<rid> in <ID>/outbox (FR-041)
#   spl_rotate_ack_send ROLE ID             the ROTATE_CMD=ack sender, run by the new session (FR-041)
#   spl_rotate_alert ROLE RID PHASE REASON  an ask (blocker) + an immediate owner DM (FR-075); <id>/lifetime/alerts.open
#   spl_rotate_recovered ID RID ACTION PID  that seat healthy again: its open alert asks closed, one line to the owner
#
# The globals a rotation sets and these read: ROTATE_RID, ROTATE_OLD_PID,
# ROTATE_OLD_PANE, ROTATE_OLD_NAME, ROTATE_NEW_PID, ROTATE_NEW_PANE,
# ROTATE_QUIESCE, ROTATE_HANDOFF (spl_rotate_ctx_save / _load keep them for a
# resume). The outside world is replaceable for the tests: ROTATE_TMUX (tmux),
# ROTATE_SPAWN (spawn-window.sh), ROTATE_RUN (./run), ROTATE_SEND
# (spool-send.sh), ROTATE_KILL (kill), ROTATE_AI (the identity-map calls),
# LEASE_PROC_ROOT (/proc).
#
# NOTE ./run runs every action under `set -E` and an ERR trap that exits: a
# plain command that fails ends the whole action. Every probe here that may
# fail sits in a condition or an `||`, or prints nothing and returns 0.
#------------------------------------------------------------------------------
# the one lease.conf writer (SPL-1713: keeps the other keys, leaves a .bak)
declare -F spl_lease_conf_write >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-lease-conf.func.sh"
declare -F spl_lease_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

SPL_ROTATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -F spool_start_check >/dev/null ||
  source "$SPL_ROTATE_LIB_DIR/../features/spawn-agents/lib/start-check.inc.sh"
# the truth rule that leads both rotation heads (SPL-2097)
declare -F spool_truth_rule >/dev/null ||
  source "$SPL_ROTATE_LIB_DIR/../features/spawn-agents/lib/spool-env.inc.sh"

# ---- settings ----------------------------------------------------------------

# spl_rotate_conf: the libs, the lease settings, and every ROTATE_* knob:
# the environment wins, then <spool root>/dispatch/rotate.conf (KEY=value,
# read, never sourced), then the defaults named in the spec.
spl_rotate_conf() {
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  ROTATE_FEAT="$(cd "$SPL_ROTATE_LIB_DIR/../features/spawn-agents" && pwd)"
  declare -F spool_env_resolve >/dev/null || source "$ROTATE_FEAT/lib/spool-env.inc.sh"
  declare -F classify_screen >/dev/null || source "$ROTATE_FEAT/lib/agent-state.inc.sh"
  SPOOL_ENV_NO_BINS=1 spool_env_resolve
  spl_lease_init || return 1
  spl_lease_conf
  ROTATE_CONF="$LEASE_DIR/rotate.conf"
  local k v
  if [[ -f "$ROTATE_CONF" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v"
    done < <(grep -E '^ROTATE[A-Z_]*=[A-Za-z0-9._/@:-]*$' "$ROTATE_CONF")
  fi
  : "${ROTATE:=1}" "${ROTATE_ORCH:=1}" "${ROTATE_DISPATCH:=1}"
  : "${ROTATE_MIN_AGE:=3300}" "${ROTATE_IDLE_SEC:=10}" "${ROTATE_IDLE_GRACE:=60}" "${ROTATE_ESC_WAIT:=30}"
  : "${ROTATE_START_WAIT:=120}" "${ROTATE_ACK_TIMEOUT:=900}" "${ROTATE_EXIT_WAIT:=300}" "${ROTATE_TERM_WAIT:=30}"
  : "${ROTATE_NEW_EXIT_WAIT:=30}" "${ROTATE_EXIT_SETTLE:=10}" "${ROTATE_POLL:=5}" "${ROTATE_BOOT_GRACE:=900}" "${ROTATE_HANDOFF_KEEP_DAYS:=7}"
  : "${ROTATE_START_CHECK_WAIT:=45}"
  for k in ROTATE ROTATE_ORCH ROTATE_DISPATCH ROTATE_MIN_AGE ROTATE_IDLE_SEC ROTATE_IDLE_GRACE ROTATE_ESC_WAIT \
           ROTATE_START_WAIT ROTATE_ACK_TIMEOUT ROTATE_EXIT_WAIT ROTATE_TERM_WAIT ROTATE_NEW_EXIT_WAIT ROTATE_EXIT_SETTLE ROTATE_POLL \
           ROTATE_BOOT_GRACE ROTATE_HANDOFF_KEEP_DAYS ROTATE_START_CHECK_WAIT; do
    [[ "${!k}" =~ ^[0-9]+$ ]] || { do_log "FATAL $k must be a whole number, got: '${!k}'"; return 1; }
  done
  (( ROTATE_POLL > 0 )) || { do_log "FATAL ROTATE_POLL must be at least 1"; return 1; }
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  ROTATE_LOG="$LEASE_DIR/rotate.log"
  ROTATE_HANDOFF_DIR="${ROTATE_HANDOFF_DIR:-$LEASE_DIR/handoff}"
  ROTATE_HOLD_DIR="${ROTATE_HOLD_DIR:-/var/tmp/CLE-parent-level/dispatch/hold}"
  ROTATE_BOX="${LEASE_MACHINE:-$(spl_desk_box_default)}"
  ROTATE_AGENT_HOME="$(getent passwd "${SPOOL_AGENT_USER:-$USER}" 2>/dev/null | cut -d: -f6 || true)"
  ROTATE_AGENT_HOME="${ROTATE_AGENT_HOME:-$HOME}"
  ROTATE_MEMORY_DIR="${ROTATE_MEMORY_DIR:-$ROTATE_AGENT_HOME/.claude/projects/-opt/memory}"
  local app; app="$(basename "$PROJ_PATH")"; app="${app%-orc}"
  ROTATE_SPEC="${ROTATE_SPEC:-$(cd "$PROJ_PATH/.." && pwd)/$app-doc/doc/md/SPEC-spool-fleet-roles.md}"
  ROTATE_SPAWN="${ROTATE_SPAWN:-$ROTATE_FEAT/scripts/spawn-window.sh}"
  ROTATE_RUN="${ROTATE_RUN:-$PROJ_PATH/run}"
  ROTATE_SEND="${ROTATE_SEND:-$ROTATE_FEAT/scripts/spool-send.sh}"
  return 0
}

# The id that holds a role on this machine (lease.conf).
spl_rotate_role_id() {
  case "$1" in orch) echo "${LEASE_ORCH:-}" ;; master) echo "${LEASE_MASTER:-}" ;; failover) echo "${LEASE_FAILOVER:-}" ;; esac
}

# spl_rotate_role_vendor -> ROTATE_KIND, ROTATE_VENDOR_WHY from
# ROTATE_ROLE_VENDOR (env > rotate.conf): the successor's vendor for the orch
# AND both dispatch seats, ahead of ROTATE_ORCH_SPLIT. Owner HUM-10 (t1
# ee1e58d5, msgs f93e7f2a, edd7c810, c43b98f1): Grok as orchestrator and
# dispatcher for a test. claude; or grok through the split's guards
# (spl_rotate_grok_why). Any other value = claude. Non-zero when it is
# unset: the caller's own rule (today's behaviour).
# claude = claude active, grok standby (SPL-1869, owner HUM-10 t1 e799211c,
# poll a4d166a9 answer A): the successor is grok ONLY while claude cannot act
# (spl_rotate_claude_out) and grok passes the same guards; else claude, both
# reasons named. The first rotation after claude is able again is claude.
# ROTATE_GROK_STANDBY=0 keeps claude whatever its state.
# agy = the dispatch seats only (FAMILY dispatch; the orch, FAMILY orch or
# none, stays claude|grok), for the owner's "live with a net" training (HUM-10
# t1 2144cff4, poll aed5a733 answer C, SPL-3395): agy through
# spl_rotate_agy_why, else claude with its reason.
# shellcheck disable=SC2034 # ROTATE_KIND / ROTATE_VENDOR_WHY are read by the caller
spl_rotate_role_vendor() {
  local v="${ROTATE_ROLE_VENDOR:-}" why cwhy
  [[ -n "$v" ]] || return 1
  ROTATE_KIND=claude
  case "$v" in
    agy)
      if [[ "${1:-orch}" != dispatch ]]; then
        ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=agy is for the dispatch seats only, not the ${1:-orch} seat: claude"; return 0
      fi
      why="$(spl_rotate_agy_why)"
      if [[ -n "$why" ]]; then
        ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=agy, but $why: claude"; return 0
      fi
      ROTATE_KIND=agy ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=agy: agy"; return 0 ;;
    claude)
      ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=claude: claude"
      [[ "${ROTATE_GROK_STANDBY:-1}" == 1 ]] || { ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=claude, ROTATE_GROK_STANDBY=0: claude"; return 0; }
      cwhy="$(spl_rotate_claude_out)"
      [[ -n "$cwhy" ]] || return 0
      why="$(spl_rotate_grok_why)"
      if [[ -n "$why" ]]; then
        ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=claude, claude cannot act ($cwhy), but the grok standby cannot either ($why): claude"; return 0
      fi
      ROTATE_KIND=grok ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=claude, claude cannot act ($cwhy): the grok standby"; return 0 ;;
    grok) ;;
    *) ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR='$v' is not claude, grok or agy: claude"; return 0 ;;
  esac
  why="$(spl_rotate_grok_why)"
  if [[ -n "$why" ]]; then
    ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=grok, but $why: claude"; return 0
  fi
  ROTATE_KIND=grok ROTATE_VENDOR_WHY="ROTATE_ROLE_VENDOR=grok: grok"
}

# spl_rotate_grok_why: why grok cannot take a role seat, nothing when it can:
# do_spl_lane_mix with a grok=100 row (no CLI, no sign-in or a limit = its
# skip reason), spl_rotate_grok_out (the weekly limit lane-mix forgets), and a
# fleet lease that counts a grok holder (spl_rotate_lease_sees).
spl_rotate_grok_why() {
  local out pick why
  out="$(env LANE_MIX_KIND=orchestration LANE_MIX_SPLIT_KIND="claude=0 grok=100 agy=0 qwen=0 mistral=0 backup=claude" \
    timeout "${ROTATE_SRC_TIMEOUT:-120}" "$ROTATE_RUN" -a do_spl_lane_mix 2>&1 7>&- 8>&- 9>&-)" || true
  pick="$(grep -m1 -oE '^pick=[a-z]+' <<<"$out" | cut -d= -f2 || true)"
  if [[ "$pick" != grok ]]; then
    why="$(sed -nE 's/^grok .* skip \((.*)\); share to .*/\1/p' <<<"$out")"; why="${why%%$'\n'*}"
    echo "${why:-lane-mix gave '${pick:-no pick}'}"; return 0
  fi
  why="$(spl_rotate_grok_out)"
  [[ -z "$why" ]] || { echo "grok is on its limit ($why)"; return 0; }
  spl_rotate_lease_sees grok || echo "the fleet lease does not count a grok process as the holder"
  return 0
}

# spl_rotate_agy_why: why agy cannot take a dispatch seat, nothing when it
# can (SPL-3395): do_spl_lane_mix with an agy=100 row of a kind agy may take
# (specs_and_docs: orchestration refuses agy by the data rule), whose skip
# reason names no agy CLI, no sign-in or a fresh limit verdict; and a fleet
# lease that counts an agy holder (spl_rotate_lease_sees).
spl_rotate_agy_why() {
  local out pick why
  out="$(env LANE_MIX_KIND=specs_and_docs LANE_MIX_SPLIT_KIND="claude=0 grok=0 agy=100 qwen=0 mistral=0 backup=claude" \
    timeout "${ROTATE_SRC_TIMEOUT:-120}" "$ROTATE_RUN" -a do_spl_lane_mix 2>&1 7>&- 8>&- 9>&-)" || true
  pick="$(grep -m1 -oE '^pick=[a-z]+' <<<"$out" | cut -d= -f2 || true)"
  if [[ "$pick" != agy ]]; then
    why="$(sed -nE 's/^agy .* skip \((.*)\); share to .*/\1/p' <<<"$out")"; why="${why%%$'\n'*}"
    echo "${why:-lane-mix gave '${pick:-no pick}'}"; return 0
  fi
  spl_rotate_lease_sees agy || echo "the fleet lease does not count an agy process as the holder"
  return 0
}

# spl_rotate_claude_out: why claude cannot act on this box, nothing when it
# can (SPL-1869). File reads, no model call, no lane-mix (to lane-mix claude
# is always there):
# - no claude CLI: ROTATE_CLAUDE_BIN, else CLAUDE_BIN, else the agent user's
#   ~/.local/bin/claude (the binary the spawn would start) is not executable,
#   asked as the agent user too (its home is 0700 to the box user on sat:
#   asked as the box user alone, a live claude read as "no claude cli");
# - a limit: among the claude seats of this box (registry kind claude, else a
#   c- or CLE- id), the newest watchdog verdict (ctx*/<id>/out.s2, newest per
#   seat) within ROTATE_CLAUDE_LIMIT_FRESH s (default 21600, lane-mix's limit
#   window) that says S2 kind=limit or kind=auth is not older than every
#   clean one. A claude seat that works again writes a newer clean verdict:
#   claude is back;
# - silence: this box's dispatch lease is held by a claude seat that has not
#   renewed it for more than LEASE_STALE s (180): no claude seat of the box,
#   the failover included, keeps it fresh.
spl_rotate_claude_out() {
  local wd="${LANE_MIX_WD_DIR:-$SPOOL_ROOT/dispatch/wd}" bin f id t now hit hitt=-1 hitl="" clean=-1 age
  local -A newest=() newf=()
  bin="${ROTATE_CLAUDE_BIN:-${CLAUDE_BIN:-${ROTATE_AGENT_HOME:-$HOME}/.local/bin/claude}}"
  [[ "$bin" == /* ]] || bin="$(command -v "$bin" 2>/dev/null || true)"
  [[ -n "$bin" ]] && { [[ -x "$bin" ]] || spl_rotate_as_agent test -x "$bin" 2>/dev/null; } ||
    { echo "no claude cli${bin:+ at $bin}"; return 0; }
  for f in "$wd"/ctx*/*/out.s2; do
    [[ -f "$f" ]] || continue
    id="$(basename "$(dirname "$f")")"
    [[ "$(spl_rotate_id_kind "$id")" == claude ]] || continue
    t="$(stat -c %Y "$f" 2>/dev/null)" || continue
    (( t > ${newest[$id]:--1} )) || continue
    newest[$id]="$t" newf[$id]="$f"
  done
  now="$(date +%s)"
  for id in "${!newest[@]}"; do
    t="${newest[$id]}"
    (( now - t <= ${ROTATE_CLAUDE_LIMIT_FRESH:-21600} )) || continue
    hit="$(grep -m1 -E '^HIT S2 kind=(limit|auth)( |$)' "${newf[$id]}" 2>/dev/null || true)"
    if [[ -z "$hit" ]]; then
      (( t <= clean )) || clean="$t"
      continue
    fi
    (( t > hitt )) || continue
    hit="${hit#HIT S2 }"
    hitt="$t" hitl="$id S2 ${hit%% *} $(( (now - t) / 60 ))m ago: ${hit#* }"
  done
  (( hitt < 0 || hitt < clean )) || { echo "$hitl"; return 0; }
  spl_lease_read
  (( LT > 0 )) || return 0
  ! spl_lease_remote || return 0
  id="$(spl_lease_holder_id)"
  [[ "$(spl_rotate_id_kind "$id")" == claude ]] || return 0
  age=$(( $(spl_lease_now) - LT ))
  (( age <= LEASE_STALE )) || echo "the dispatch lease holder $id (claude) is silent ${age}s, past LEASE_STALE ${LEASE_STALE}s"
  return 0
}

# spl_rotate_id_kind ID: the vendor of a seat id: its registry kind, else
# its letter (a legacy CLE- id is claude).
spl_rotate_id_kind() {
  local k
  k="$(awk -F'\t' -v i="$1" '$1 == i {k = $2} END {print k}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true)"
  [[ -n "$k" ]] && { echo "$k"; return 0; }
  case "$1" in c-*|CLE-*) echo claude ;; g-*) echo grok ;; a-*) echo agy ;; m-*) echo mistral ;; q-*) echo qwen ;; esac
  return 0
}

# spl_rotate_grok_out: "<id> S2 kind=limit <age>m ago: <evidence>" when the
# NEWEST watchdog verdict (any instance, ctx*/<id>/out.s2) of ALL grok seats
# of this box (registry kind grok, else a g- id) is S2 kind=limit within
# ROTATE_GROK_LIMIT_FRESH s (default 604800: grok's limit is weekly); nothing
# otherwise. lane-mix's own check is no guard here: its hub pause and its
# verdict window (LANE_MIX_LIMIT_FRESH, 6 h) run out together while the
# weekly quota is still out (SPL-1820, sat 2026-10-14 0805Z: paused until
# 08:05:01Z, grok picked 56 s later, g-001 opened on grok's limit menu). The
# limit is the account's, not a seat's: a seat that hit it and never ran
# again keeps it in its last verdict, so a newer clean verdict of ANY grok
# seat clears it (SPL-2555, sat 10-18: g-178's of 10-15 while g-002 and g-003
# wrote clean ones). A tie in the same second counts the limit. A file read,
# no model call. The boot restore reads it too (_ai_grok_why, SPL-2507).
spl_rotate_grok_out() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" f id k t hit best=-1 bestf="" besthit=""
  local wd="${LANE_MIX_WD_DIR:-$root/dispatch/wd}"
  for f in "$wd"/ctx*/*/out.s2; do
    [[ -f "$f" ]] || continue
    id="$(basename "$(dirname "$f")")"
    k="$(awk -F'\t' -v i="$id" '$1 == i {k = $2} END {print k}' "$root/registry.tsv" 2>/dev/null || true)"
    [[ "$k" == grok || ( -z "$k" && "$id" == g-* ) ]] || continue
    t="$(stat -c %Y "$f" 2>/dev/null)" || continue
    (( t >= best )) || continue
    hit="$(grep -m1 -E '^HIT S2 kind=limit( |$)' "$f" 2>/dev/null || true)"
    (( t > best )) || [[ -n "$hit" && -z "$besthit" ]] || continue
    best="$t" bestf="$f" besthit="$hit"
  done
  [[ -n "$besthit" ]] || return 0
  t="$(( $(date +%s) - best ))"
  (( t <= ${ROTATE_GROK_LIMIT_FRESH:-604800} )) || return 0
  echo "$(basename "$(dirname "$bestf")") S2 kind=limit $(( t / 60 ))m ago: ${besthit#HIT S2 kind=limit }"
  return 0
}

# spl_rotate_lease_sees KIND: 0 when spl_lease_agent_pid finds a KIND
# process (a probe in a throwaway proc dir). Since spec 134 P0 it counts
# claude, grok and vibe; the probe keeps the rotation honest if that changes.
# ROTATE_LEASE_KINDS (tests) names the kinds it counts instead.
spl_rotate_lease_sees() {
  local d got="" comm="$1"
  if [[ -n "${ROTATE_LEASE_KINDS:-}" ]]; then [[ " $ROTATE_LEASE_KINDS " == *" $1 "* ]]; return; fi
  [[ "$comm" == mistral ]] && comm=vibe
  d="$(mktemp -d)" || return 1
  mkdir -p "$d/7" && echo "$comm" > "$d/7/comm" && printf 'SPOOL_AGENT_ID=probe-%s\0' "$1" > "$d/7/environ" &&
    got="$(LEASE_PROC_ROOT="$d" spl_lease_agent_pid "probe-$1" 2>/dev/null || true)"
  rm -rf "$d"
  [[ "$got" == 7 ]]
}

# The .state / .lock / task family of a role: orch -> orch, master|failover -> dispatch;
# ROTATE_FAMILY overrides it (the lane rotation: lane, its files in ROTATE_STATE_DIR).
spl_rotate_family() {
  [[ -n "${ROTATE_FAMILY:-}" ]] && { echo "$ROTATE_FAMILY"; return 0; }
  [[ "$1" == orch ]] && echo orch || echo dispatch
}

# spl_rotate_vendor_id ID: SPL-1685 (owner t1 ee1e58d5, msg 10e31037: "why
# is it called c-001@<box> .. should be g-001@<box>"): a role seat's id is the
# letter of the vendor that runs it, so a rotation to another vendor starts
# the successor as spl_role_seat_id ROTATE_KIND <seat>. Prints that id when
# ID is a bare role seat in the new form and the vendor's id differs; nothing
# otherwise (the id stays). ROTATE_ROLE_ID_FOLLOWS_VENDOR=0 (env >
# rotate.conf; default 1) turns it off: every vendor keeps the claude id.
spl_rotate_vendor_id() {
  local id="$1" n new
  [[ "${ROTATE_ROLE_ID_FOLLOWS_VENDOR:-1}" == 1 && "$id" =~ ^${SPL_ROLE_SEAT_RX}$ ]] || return 0
  n="$(spl_role_seat_num "$id")" || return 0
  new="$(spl_role_seat_id "${ROTATE_KIND:-claude}" "$n")" || return 0
  [[ "$new" != "$id" ]] && echo "$new"
  return 0
}

# spl_rotate_seat_switch OLD NEW: role-seat-switch.sh --apply (spool dir,
# links for every other letter, registry, identity, the dev+prd desks);
# ROTATE_SEAT_SWITCH replaces it in tests. Non-zero = failed, ROTATE_ERR.
# shellcheck disable=SC2034 # ROTATE_ERR / ROTATE_SWITCH_OUT are read by the caller
spl_rotate_seat_switch() {
  local out
  out="$(${ROTATE_SEAT_SWITCH:-bash "$ROTATE_FEAT/scripts/role-seat-switch.sh"} --apply --desk-envs "${ROTATE_SWITCH_DESK_ENVS-dev prd}" "$1" "$2" 2>&1 7>&- 8>&- 9>&-)" ||
    { ROTATE_ERR="the seat switch $1 -> $2 failed: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"; return 1; }
  ROTATE_SWITCH_OUT="$(grep -c '^DO ' <<<"$out" || true) step(s)"
}

# ---- the in-place vendor failover (SPL-2544) ------------------------------------
# do_spl_role_failover (spl-role-failover.func.sh) switches a role seat that
# cannot act to the next vendor IN PLACE and records it in
# <lease dir>/role-failover/seat.<NNN>: "<from> <to> <vendor> <rid> <epoch>".
# The hourly rotation hands the seat back: its successor is claude once
# claude can act again (spl_rotate_claude_out says nothing), else the seat
# keeps its vendor, so a rotation never hands a role to a claude that still
# cannot act. The record goes once the seat runs as a claude id again.

# spl_rotate_failover_seat ID: 0 and the record when ID is the id a failover
# switched its seat to and ID still runs it. A record whose seat is a claude
# id again is removed (the handback is done).
spl_rotate_failover_seat() {
  local id="${1%%@*}" n f from to rest
  n="$(spl_role_seat_num "$id" 2>/dev/null)" || return 1
  f="$LEASE_DIR/role-failover/seat.$n"
  [[ -s "$f" ]] || return 1
  read -r from to rest < "$f" || return 1
  if [[ "$to" != "$id" ]]; then
    [[ "$(spl_fleet_vendor "$id")" == claude ]] && rm -f "$f"
    return 1
  fi
  # claude2 (SPL-2943) keeps the claude id: the handback is done once the
  # seat's live process runs the main login again (no CLAUDE_CONFIG_DIR)
  if [[ "${rest%% *}" == claude2 && "$(spl_fleet_seat_vendor "$id")" == claude ]]; then
    rm -f "$f"; return 1
  fi
  echo "$from $to $rest"
}

# spl_rotate_failover_vendor ID -> ROTATE_KIND, ROTATE_VENDOR_WHY for a seat
# a failover moved (spl_rotate_failover_seat); non-zero for any other seat.
# shellcheck disable=SC2034 # ROTATE_KIND / ROTATE_VENDOR_WHY are read by the caller
spl_rotate_failover_vendor() {
  local rec cwhy kind
  rec="$(spl_rotate_failover_seat "$1")" || return 1
  cwhy="$(spl_rotate_claude_out)"
  ROTATE_CLAUDE_CONFIG_DIR=""
  if [[ -z "$cwhy" ]]; then
    ROTATE_KIND=claude ROTATE_VENDOR_WHY="failover seat $1 (switched from ${rec%% *}): claude can act again: the handback"
    return 0
  fi
  kind="$(spl_fleet_vendor "${1%%@*}")"
  # a seat on the second login stays on it (SPL-2943)
  if [[ "$(cut -d' ' -f3 <<<"$rec")" == claude2 ]]; then
    kind=claude2 ROTATE_CLAUDE_CONFIG_DIR="${CLAUDE2_CONFIG_DIR:-${ROTATE_AGENT_HOME:-$HOME}/.claude-2}"
  fi
  ROTATE_KIND="${kind%2}" ROTATE_VENDOR_WHY="failover seat $1: claude still cannot act ($cwhy): $kind stays"
}

# spl_rotate_failover_due ID: 0 when ID is a failover seat and claude can act again.
spl_rotate_failover_due() {
  spl_rotate_failover_seat "$1" >/dev/null || return 1
  [[ -z "$(spl_rotate_claude_out)" ]]
}

# spl_rotate_conf_flip KEY OLD NEW: lease.conf KEY=OLD -> KEY=NEW (a backup
# first) and the shell's KEY with it. Non-zero = lease.conf did not take it.
# shellcheck disable=SC2034 # ROTATE_ERR is read by the caller
spl_rotate_conf_flip() {
  spl_lease_conf_flip "$LEASE_CONF" "$ROTATE_RID" "$1" "$2" "$3" ||
    { ROTATE_ERR="lease.conf did not take $1=$3"; return 1; }
  printf -v "$1" '%s' "$3"
}

# A new run id: <UTC yyyymmddThhmmZ>-<role> (spec section 2).
spl_rotate_new_rid() { echo "$(date -u +%Y%m%dT%H%MZ)-$1"; }

# ---- the log -----------------------------------------------------------------

# spl_rotate_log RID PHASE RESULT DETAIL: one line
# "<UTC ts> <rid> <PHASE> <RESULT> <detail>" to rotate.log and stdout; a
# result other than SKIP / PLAN also records "<rid> <phase> <epoch>" in
# rotate.<orch|dispatch>.state. A dry run (DRY_RUN=1, not an ack) and PLAN
# lines only print: "nothing touched" (FR-005).
spl_rotate_log() {
  local rid="$1" phase="$2" res="$3" line
  line="$(date -u +%FT%TZ) $rid $phase $res ${4:-}"
  printf '%s\n' "$line"
  [[ "$res" == PLAN ]] && return 0
  [[ "${DRY_RUN:-1}" == 1 && "${ROTATE_CMD:-auto}" == auto ]] && return 0
  echo "$line" >> "$ROTATE_LOG"
  [[ "$res" == SKIP ]] && return 0
  local sf; sf="${ROTATE_STATE_DIR:-$LEASE_DIR}/rotate.$(spl_rotate_family "${rid##*-}").state"
  # a DONE OK ends the alert streak (spl_rotate_alert_repeat, SPL-2898)
  [[ "$phase $res" == "DONE OK" ]] && rm -f "${sf%.state}.alert-streak"
  printf '%s %s %s\n' "$rid" "$phase" "$(date +%s)" > "$sf.tmp.$$" && mv -f "$sf.tmp.$$" "$sf"
  return 0
}

# ---- the id lock (spec 102 section 4.2) ----------------------------------------

# spl_agent_id_lock ID [ACTOR] [RID] [WAIT]: the one lock every actor that
# starts or stops a session of ID takes for its whole run (the takeover, the
# lane restart, both rotations, the peer restart, the identity restore, the
# reaper): flock on <spool root>/<id>/lifetime/restart.lock, held by a holder
# process (flock -o ... tail --pid) that ends within 0.2 s of the calling
# shell. Not an fd of the caller: a tmux server or any other child the actor
# starts would inherit that and hold the id for ever. 0 = held, also when
# this shell already holds it; 4 = another actor holds it (WAIT seconds,
# default 0 = flock -n): SPL_ID_LOCK_WHY names the holder
# (lifetime/restart.holder) and one IDLOCK REFUSED line goes to rotate.log
# under a run id of its own (<ts>-idlock), so it never reads as the end of
# the holder's run in spl_wd_rotating; 1 = the lock cannot be taken. Needs
# nothing but SPOOL_ROOT, so a script outside ./run sources it too. Never
# call it in $( ): the lock would end with the subshell.
spl_agent_id_lock() {
  local id="$1" actor="${2:-${FUNCNAME[1]:-?}}" rid="${3:--}" wait="${4:-0}" dir lock tok hp t0 rc held mode=-n me="$BASHPID"
  SPL_ID_LOCK_WHY=""
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { SPL_ID_LOCK_WHY="not an agent id: '$id'"; return 1; }
  [[ "$wait" =~ ^[0-9]+$ ]] || { SPL_ID_LOCK_WHY="WAIT must be whole seconds, got '$wait'"; return 1; }
  dir="${SPOOL_ROOT:-/var/spool-hub}/$id/lifetime"
  lock="$dir/restart.lock"
  hp="$(sed -n "s/.* $id:\([0-9][0-9]*\) .*/\1/p" <<<" ${SPL_ID_LOCKS:-} ")"
  if [[ -n "$hp" ]] && kill -0 "$hp" 2>/dev/null; then return 0; fi
  if ! { [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null; } ||
     ! { [[ -e "$lock" ]] || ( umask 0002; : >> "$lock" ) 2>/dev/null; } || [[ ! -w "$lock" ]]; then
    SPL_ID_LOCK_WHY="cannot open $lock"; return 1
  fi
  tok="$me.$RANDOM.$SECONDS"
  [[ "$wait" == 0 ]] || mode="-w$wait"
  # the holder: closes every inherited fd it may keep (stdout of a $( ), the
  # callers' 6..9 locks), writes restart.holder once it has the lock
  flock "$mode" -o -E 4 "$lock" bash -c 'printf "%s\n" "$2" > "$3"; exec tail --pid="$1" -s 0.2 -f /dev/null' \
    _ "$me" "$actor $rid pid $me since $(date -u +%FT%TZ) [$tok]" "$dir/restart.holder" \
    </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
  hp=$!
  t0=$SECONDS
  while (( SECONDS - t0 < wait + 5 )); do
    if grep -qF "[$tok]" "$dir/restart.holder" 2>/dev/null; then SPL_ID_LOCKS="${SPL_ID_LOCKS:-} $id:$hp "; return 0; fi
    if ! kill -0 "$hp" 2>/dev/null; then
      rc=0; wait "$hp" 2>/dev/null || rc=$?
      if (( rc != 4 )); then SPL_ID_LOCK_WHY="flock on $lock exited $rc"; return 1; fi
      # the winner writes restart.holder just AFTER its flock: refused in that
      # gap the file is still empty (wf 10 38537641629, "held by another
      # actor"), so give it a second to name itself
      for _ in {1..20}; do [[ -s "$dir/restart.holder" ]] && break; sleep 0.05; done
      held="$(head -c 300 "$dir/restart.holder" 2>/dev/null | sed 's/ \[[^]]*\]$//' || true)"
      # the actor that holds it has ended and its holder follows within
      # 0.2 s: one more try, waiting a second
      if [[ "$mode" == -n && "$held" =~ \ pid\ ([0-9]+)\  ]] && ! kill -0 "${BASH_REMATCH[1]}" 2>/dev/null; then
        spl_agent_id_lock "$id" "$actor" "$rid" 1; return
      fi
      SPL_ID_LOCK_WHY="the id lock of $id is held by ${held:-another actor}"
      printf '%s %s IDLOCK REFUSED %s: %s (%s) refused, held by %s\n' "$(date -u +%FT%TZ)" "$(date -u +%Y%m%dT%H%M%SZ)-idlock" \
        "$id" "$actor" "$rid" "${held:-another actor}" >> "${ROTATE_LOG:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/rotate.log}" 2>/dev/null || true
      return 4
    fi
    sleep 0.05
  done
  kill "$hp" 2>/dev/null || true
  # shellcheck disable=SC2034 # read by the callers
  SPL_ID_LOCK_WHY="the holder of $lock did not report within $((wait + 5))s"
  return 1
}

# spl_agent_id_unlock ID: the id lock this shell took on ID goes now, not when
# the shell ends: its holder is stopped and waited for. A rotation holds an
# id only around that id's own swap (spawn .. retire): holding the master's and
# the failover's for the whole run refused the watchdog's restart of c-003 12
# times while the master phase swapped c-002 (2026-10-07 17:33..17:39Z).
# Nothing held: 0.
spl_agent_id_unlock() {
  local id="$1" hp
  hp="$(sed -n "s/.* $id:\([0-9][0-9]*\) .*/\1/p" <<<" ${SPL_ID_LOCKS:-} ")"
  [[ -n "$hp" ]] || return 0
  kill "$hp" 2>/dev/null || true
  wait "$hp" 2>/dev/null || true
  SPL_ID_LOCKS="$(sed "s/ $id:$hp / /g" <<<" ${SPL_ID_LOCKS:-} ")"
  return 0
}

# The resume context: rotate.<family>.ctx, KEY=value, read, never sourced.
# ROTATE_RUN_PID / ROTATE_RUN_START: the run that writes it (spl_rotate_run_mark).
ROTATE_CTX_KEYS=(ROTATE_RID ROTATE_PHASE ROTATE_OLD_PID ROTATE_OLD_PANE ROTATE_OLD_NAME ROTATE_NEW_PID ROTATE_NEW_PANE ROTATE_QUIESCE ROTATE_HANDOFF ROTATE_SWITCH_FROM ROTATE_SWITCH_TO ROTATE_RUN_PID ROTATE_RUN_START)
spl_rotate_ctx_save() {  # FAMILY
  local k f="${ROTATE_STATE_DIR:-$LEASE_DIR}/rotate.$1.ctx"
  { for k in "${ROTATE_CTX_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k:-}"; done; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}
spl_rotate_ctx_load() {  # FAMILY -> non-zero when there is none
  local k v f="${ROTATE_STATE_DIR:-$LEASE_DIR}/rotate.$1.ctx"
  for k in "${ROTATE_CTX_KEYS[@]}"; do printf -v "$k" '%s' ""; done
  [[ -f "$f" ]] || return 1
  while IFS='=' read -r k v; do
    [[ " ${ROTATE_CTX_KEYS[*]} " == *" $k "* ]] && printf -v "$k" '%s' "$v"
  done < "$f"
  return 0
}

# spl_rotate_run_mark: this process is the run that owns the ctx from here
# (its pid and start tick, so a reused pid never reads as the same run).
spl_rotate_run_mark() {
  ROTATE_RUN_PID="$$"
  ROTATE_RUN_START="$(spl_rotate_start "$$")"
}

# spl_rotate_run_alive: 0 while the run recorded in the loaded ctx is alive.
# A ctx with no run pid (written before SPL-1837) never is.
spl_rotate_run_alive() {
  local st
  [[ "${ROTATE_RUN_PID:-}" =~ ^[0-9]+$ ]] || return 1
  st="$(spl_rotate_start "$ROTATE_RUN_PID")"
  [[ -n "$st" && "$st" == "${ROTATE_RUN_START:-}" ]]
}

# spl_rotate_stale: 0 when the loaded ctx belongs to a run that is gone and
# nothing was spawned yet (GATE, HOLD, QUIESCE, HANDOFF, REFRESH, no new
# pid): there is nothing to finish, so the next run starts clean instead of
# resuming it into a FAIL and an owner alert. SPL-1837: a run killed by its
# own QUIESCE left GATE, and the forced run after it logged "FAIL GATE:
# resumed with no live new session" + ALERT (rotate.log 2026-10-14T09:15:39Z).
spl_rotate_stale() {
  spl_rotate_run_alive && return 1
  [[ -z "${ROTATE_NEW_PID:-}" ]] || return 1
  case "${ROTATE_PHASE:-}" in GATE|HOLD|QUIESCE|HANDOFF|REFRESH) return 0 ;; esac
  return 1
}

# spl_rotate_detach_if_inside FAMILY ID PANE...: QUIESCE sends Escape to the
# old pane; a run started from a tool call IN that pane is interrupted and
# killed by it (SPL-1837, 20261014T0914Z-orch died at GATE). So such a run
# re-runs itself detached (setsid, its own session, the same environment),
# logs where, and returns 3: the caller ends with 0. A re-exec, not a refusal: the
# caller wanted a rotation now, and the detached run is exactly what
# succeeded by hand (20261014T0923Z-orch DONE OK). It lets the rotation lock
# (fd 7) and the id lock of ID go first, so the detached run takes them.
# A run that is ALREADY detached (ROTATE_DETACHED=1) and still in the pane
# refuses (1): never a loop. 0 = not inside any of the panes: go on.
spl_rotate_detach_if_inside() {
  local fam="$1" id="$2" me pane log
  shift 2
  me="$(spl_rotate_pane_of_pid "${ROTATE_SELF_PID:-$$}")"
  [[ -n "$me" ]] || return 0
  for pane in "$@"; do [[ "$me" == "$pane" ]] && break; pane=""; done
  [[ -n "$pane" ]] || return 0
  if [[ "${ROTATE_DETACHED:-0}" == 1 ]]; then
    spl_rotate_log "$ROTATE_RID" GATE SKIP "inside: this detached run is still in $pane, which QUIESCE would interrupt; run it from outside that pane"
    return 1
  fi
  log="${ROTATE_DETACH_LOG:-$LEASE_DIR/rotate.$fam.detached.log}"
  exec 7>&-
  spl_agent_id_unlock "$id"
  if ! ( cd "$PROJ_PATH" && ${ROTATE_SETSID:-setsid -f} env ROTATE_DETACHED=1 "$ROTATE_RUN" -a "do_spl_${fam}_rotate" \
      >>"$log" 2>&1 </dev/null 7>&- 8>&- 9>&- ); then
    spl_rotate_log "$ROTATE_RID" GATE SKIP "inside: this run is in $pane, which QUIESCE would interrupt, and the detached re-run did not start"
    return 1
  fi
  spl_rotate_log "$ROTATE_RID" GATE SKIP "inside: this run is in $pane, which QUIESCE would interrupt; re-run detached (setsid), log $log"
  return 3
}

# ---- processes and panes -------------------------------------------------------

spl_rotate_tmux() {
  if [[ -n "${ROTATE_TMUX:-}" ]]; then "$ROTATE_TMUX" "$@"; return; fi
  spool_tmux_argv
  "${SPOOL_TM[@]}" "$@"
}

# spl_rotate_cli DIR COMM: 0 when the process in DIR (<proc>/<pid>) is the
# CLI of ROTATE_KIND (default claude: its comm). Another kind is read as
# agent-identity's kind_of does: argv[0], or argv[1] behind a node/python
# loader; vibe ("Vibe CLI") is mistral. A tool child (bash, git) never is.
# ROTATE_CLI_KINDS (a list, e.g. "claude grok mistral") matches any of them:
# a role rotation whose old and new session may be different vendors.
spl_rotate_cli() {
  if [[ -n "${ROTATE_CLI_KINDS:-}" ]]; then
    local ck
    for ck in $ROTATE_CLI_KINDS; do ROTATE_CLI_KINDS="" ROTATE_KIND="$ck" spl_rotate_cli "$1" "$2" && return 0; done
    return 1
  fi
  local k="${ROTATE_KIND:-claude}" a0="" a1=""
  [[ "$k" == claude ]] && { [[ "$2" == claude ]]; return; }
  case "$2" in "Vibe CLI"|vibe) [[ "$k" == mistral ]]; return ;; "$k") return 0 ;;
    node|nodejs|bun|deno|python|python[0-9]*) ;; *) return 1 ;; esac
  { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } < "$1/cmdline" 2>/dev/null || true
  a0="${a0##*/}"; a1="${a1##*/}"
  case "$a0" in node|nodejs|bun|deno|python|python[0-9]*) a0="$a1" ;; esac
  [[ "$a0" == "$k" || ( "$k" == mistral && "$a0" == vibe ) ]]
}

# spl_rotate_pids ID: every live claude (ROTATE_KIND) pid whose environment carries
# SPOOL_AGENT_ID=<ID>, ascending (spl_lease_agent_pid gives only the lowest).
spl_rotate_pids() {
  local id="$1" d pid comm root="${LEASE_PROC_ROOT:-/proc}"
  local -a other=()
  {
    for d in "$root"/[0-9]*; do
      pid="${d##*/}"
      comm=""; { read -r comm < "$d/comm"; } 2>/dev/null || true
      spl_rotate_cli "$d" "$comm" || continue
      if [[ -r "$d/environ" ]]; then
        if grep -zx "SPOOL_AGENT_ID=$id" "$d/environ" >/dev/null 2>&1; then echo "$pid"; fi
      else
        other+=("$pid")
      fi
    done
    if (( ${#other[@]} )) && declare -F spool_proc_env_get >/dev/null; then
      spool_proc_env_get "$root" SPOOL_AGENT_ID "${other[@]}" | awk -v id="$id" '$2 == id {print $1}'
    fi
  } | sort -n
}

# spl_rotate_alive PID: 0 while it is a live claude (ROTATE_KIND) process. Not `kill -0`:
# the box user may not signal the agent user's process (EPERM reads as dead).
spl_rotate_alive() {
  local comm=""
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  { read -r comm < "${LEASE_PROC_ROOT:-/proc}/$1/comm"; } 2>/dev/null || true
  spl_rotate_cli "${LEASE_PROC_ROOT:-/proc}/$1" "$comm"
}

# spl_rotate_start PID: its start time in clock ticks since boot; empty when it is gone.
spl_rotate_start() {
  awk '{sub(/^.*\) /, ""); print $20}' "${LEASE_PROC_ROOT:-/proc}/$1/stat" 2>/dev/null || true
}

# spl_rotate_age PID: its age in seconds; empty when it is gone.
spl_rotate_age() {
  local start now root="${LEASE_PROC_ROOT:-/proc}"
  start="$(awk '{sub(/^.*\) /, ""); print $20}' "$root/$1/stat" 2>/dev/null || true)"
  [[ "$start" =~ ^[0-9]+$ ]] || return 0
  now="$(awk '{print int($1)}' "$root/uptime" 2>/dev/null || awk '{print int($1)}' /proc/uptime)"
  echo $(( now - start / $(getconf CLK_TCK) ))
}

# spl_rotate_booted_after RID: 0 + why when the box booted after rotation
# RID's GATE (<proc>/stat btime > the RID's minute, which is when GATE minted
# it): that rotation was cut off by the reboot, not failed. 20261008T1815Z-master
# GATEd at 18:15:07Z, the box rebooted at 18:18:02Z, and its resume raised a false
# "ROTATION FAILED ... no live new session" naming the pre-reboot pid.
spl_rotate_booted_after() {
  local r="${1%%-*}" gt bt
  [[ "$r" =~ ^([0-9]{8})T([0-9]{2})([0-9]{2})Z$ ]] || return 1
  gt="$(date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]} UTC" +%s 2>/dev/null)" || return 1
  bt="$(awk '$1 == "btime" {print $2}' "${LEASE_PROC_ROOT:-/proc}/stat" 2>/dev/null || true)"
  [[ "$bt" =~ ^[0-9]+$ && "$gt" =~ ^[0-9]+$ ]] && (( bt > gt )) || return 1
  echo "the box booted after its GATE (btime $bt > $gt)"
}

# spl_rotate_uptime: seconds since boot (FR-052).
spl_rotate_uptime() { awk '{print int($1)}' "${LEASE_PROC_ROOT:-/proc}/uptime" 2>/dev/null || awk '{print int($1)}' /proc/uptime; }

# spl_rotate_user PID: the user that runs it; empty when it is gone.
spl_rotate_user() {
  local uid
  uid="$(awk '/^Uid:/ {print $2}' "${LEASE_PROC_ROOT:-/proc}/$1/status" 2>/dev/null || true)"
  [[ -n "$uid" ]] && getent passwd "$uid" | cut -d: -f1
  return 0
}

# spl_rotate_pane_of_pid PID: the tmux pane whose process tree holds it; empty when none.
spl_rotate_pane_of_pid() {
  local p="$1" panes pane
  panes="$(spl_rotate_tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)" || return 0
  for _ in $(seq 1 64); do
    pane="$(awk -v p="$p" '$1 == p {print $2; exit}' <<<"$panes")"
    [[ -n "$pane" ]] && { echo "$pane"; return 0; }
    p="$(awk '{sub(/^.*\) /, ""); print $2}' "${LEASE_PROC_ROOT:-/proc}/$p/stat" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || return 0
  done
  return 0
}

# spl_rotate_claude_ancestor: the nearest claude process above this shell
# (the session that ran the ack command), or ROTATE_NEW_PID when that is
# above it (a grok / vibe / agy / qwen session); empty when there is none.
spl_rotate_claude_ancestor() {
  local p="$$" comm
  for _ in $(seq 1 32); do
    comm=""; { read -r comm < "/proc/$p/comm"; } 2>/dev/null || true
    [[ "$comm" == claude || ( -n "${ROTATE_NEW_PID:-}" && "$p" == "$ROTATE_NEW_PID" ) ]] && { echo "$p"; return 0; }
    p="$(awk '{sub(/^.*\) /, ""); print $2}' "/proc/$p/stat" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || return 0
  done
  return 0
}

# spl_rotate_pane_why PANE: why no CLI pid showed in PANE, for ROTATE_ERR:
# the pane is gone, died (its exit status and last screen lines; the spawn
# set remain-on-exit) or is up with no CLI process in it (its screen).
spl_rotate_pane_why() {
  local st
  st="$(spl_rotate_tmux display-message -p -t "$1" '#{pane_dead} #{pane_dead_status}' 2>/dev/null)" || { echo "the pane is gone"; return 0; }
  if [[ "$st" == 1* ]]; then echo "the pane died (exit ${st#1 }): $(spl_rotate_screen_tail "$1")"
  else echo "the pane is up, no ${ROTATE_KIND:-claude} process in it: $(spl_rotate_screen_tail "$1")"; fi
}

spl_rotate_screen() { spl_rotate_tmux capture-pane -p -t "$1" 2>/dev/null || true; }

# spl_rotate_idle PANE: 0 when the screen reads idle (classify_screen) AND is
# byte-identical over ROTATE_IDLE_SEC (spec section 2, "idle pane"). The
# finished-turn line ("✻ Crunched for 4s · done 12.34") is dropped first:
# classify_screen's spinner words match its past tense, so every pane that
# had finished a turn read busy (QUIESCE busy-rotated, and RETIRE never saw
# the /exit-clean turn end; measured 2026-10-02 1005Z). A running turn keeps
# its "(12s · " spinner and "esc to interrupt" footer.
spl_rotate_idle_screen() {
  spl_rotate_screen "$1" | grep -vE '^[^[:alnum:][:space:]]+ [[:upper:]][^ ]* for [0-9]+(m|s)' || true
}
spl_rotate_idle() {
  local a b
  a="$(spl_rotate_idle_screen "$1")"
  [[ -n "$a" && "$(classify_screen "$a")" == idle ]] || return 1
  sleep "$ROTATE_IDLE_SEC"
  b="$(spl_rotate_idle_screen "$1")"
  [[ "$a" == "$b" ]]
}

# spl_rotate_human_hold ID [NOW]: "human hold for N min" while
# <spool root>/<ID>/.human-hold (do_spl_wd_hold) holds an epoch after NOW
# (default: now), nothing otherwise; an expired or garbage hold is no hold.
# The GC and lane rotation read it here (SPL-2431).
spl_rotate_human_hold() {
  local h now="${2:-$(date +%s)}"
  h="$(cat "$SPOOL_ROOT/$1/.human-hold" 2>/dev/null || true)"
  if [[ "$h" =~ ^[0-9]+$ ]] && (( h > now )); then echo "human hold for $(( (h - now + 59) / 60 )) min"; fi
  return 0
}

# spl_rotate_stalled PANE: the CLE-77935 footer text when the pane is stalled
# (usage limit, login, trust screen ...), nothing otherwise (FR-009).
spl_rotate_stalled() {
  spl_rotate_screen "$1" | grep -v '^[[:space:]]*$' | tail -n "${LEASE_PANE_TAIL:-8}" |
    grep -oiE -- "${LEASE_STALL_RE:-${LEASE_STALL_RE_DEFAULT:-usage limit reached}}" | sed -n 1p
  return 0
}

# ---- QUIESCE (FR-011) --------------------------------------------------------

# spl_rotate_quiesce PANE: wait up to ROTATE_IDLE_GRACE for an idle pane;
# still busy (or a dialog on screen): Escape, wait up to ROTATE_ESC_WAIT.
# Prints idle (it was idle), interrupted (Escape stopped a turn) or
# busy-rotated (still not idle: the rotation goes on anyway, owner D1).
spl_rotate_quiesce() {
  local pane="$1" t0
  t0=$SECONDS
  while (( SECONDS - t0 < ROTATE_IDLE_GRACE )); do
    [[ "$(classify_screen "$(spl_rotate_screen "$pane")")" == dialog ]] && break
    spl_rotate_idle "$pane" && { echo idle; return 0; }
    sleep "$ROTATE_POLL"
  done
  spl_rotate_tmux send-keys -t "$pane" Escape 2>/dev/null || true
  t0=$SECONDS
  while (( SECONDS - t0 < ROTATE_ESC_WAIT )); do
    spl_rotate_idle "$pane" && { echo interrupted; return 0; }
    sleep "$ROTATE_POLL"
  done
  echo busy-rotated
}

# ---- HANDOFF (spec section 6) --------------------------------------------------

# spl_rotate_handoff ROLE ID RID OUT: the handoff file. The old session is
# ROTATE_OLD_PID / ROTATE_OLD_PANE when set, else the id's lowest live pid.
# Every section is capped; a source that fails prints "UNAVAILABLE: <why>"
# and blocks nothing. OUT "-" prints instead of writing.
spl_rotate_handoff() {
  local role="$1" id="$2" rid="$3" out="$4" pid="${ROTATE_OLD_PID:-}" pane="${ROTATE_OLD_PANE:-}" asks lanes tr age
  [[ -n "$pid" ]] || pid="$(spl_rotate_pids "$id" | sed -n 1p)"
  [[ -n "$pane" || -z "$pid" ]] || pane="$(spl_rotate_pane_of_pid "$pid")"
  age="$(spl_rotate_age "$pid")"
  asks="$(spl_rotate_json "ASKS_ROLE=${ROTATE_ASKS_ROLE:-orch}" ASKS_FORMAT=json -a do_spl_asks_open)"
  lanes="$(spl_rotate_json LANE_FORMAT=json -a do_spl_lane_map)"
  tr="$(spl_rotate_transcript "$id")"
  # "-" prints: never `> /dev/stdout`, which truncates a stdout that is a file
  if [[ "$out" == - ]]; then spl_rotate_handoff_body; else spl_rotate_handoff_body > "$out"; fi
  return 0
}

# The body of spl_rotate_handoff; reads its locals (bash dynamic scope).
spl_rotate_handoff_body() {
  {
    echo "# $id@$ROTATE_BOX handoff, rotation $rid (role $role)"
    echo
    echo "Written by the rotation script from files, /proc and tmux (spec 060 section 6); no model wrote it."
    echo "- old session: pid ${pid:-?}, $(( ${age:-0} / 60 )) min old, pane ${pane:-?}; quiesce: ${ROTATE_QUIESCE:-not run}"
    echo "- transcript: ${tr:-UNAVAILABLE: no session id in the identity map}"
    echo "- lease (dispatch): $(cat "$LEASE_FILE" 2>/dev/null || echo none)"
    echo "- lease.orch: $(cat "$LEASE_FILE.orch" 2>/dev/null || echo none)"
    echo "- role: $ROTATE_SPEC section 1 (+ 1.2 rotation, 4.1 fleet lease, 4.3 asks)"
    echo
    echo "## 2. In flight: the old pane's last terminal lines (after quiesce)"
    if [[ -n "$pane" ]]; then
      echo '```text'
      spl_rotate_tmux capture-pane -p -J -S -300 -t "$pane" 2>/dev/null | grep -v '^[[:space:]]*$' |
        tail -n "${ROTATE_SCREEN_LINES:-60}" | sed -E 's/^(.{200}).*/\1/' || true
      echo '```'
    else echo "UNAVAILABLE: no pane"; fi
    echo
    echo "## 3. Open asks, oldest first (ack: do_spl_ask_ack, close: do_spl_ask_close)"
    spl_rotate_handoff_asks "$asks"
    echo
    echo "## 4. Sent by the old session in its last hour (its outbox)"
    spl_rotate_msgs "$SPOOL_ROOT/$id/outbox" to 60 40 160
    echo
    echo "## 5. Unread inbox: $(find "$SPOOL_ROOT/$id/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l) message(s), the 20 newest"
    spl_rotate_msgs "$SPOOL_ROOT/$id/inbox" from "" 20 120
    echo
    echo "## 6. Live lanes (do_spl_lane_map)"
    if [[ -n "$lanes" ]]; then
      jq -r 'def dur: if . == null then "-" elif . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
        [.lanes[] | select((.state // "live") == "live")] | if length == 0 then "none" else (.[0:60][] |
        "- \(.agent_id)@\(.agent_box // "?") \(.branch // "-") (\(.age_s | dur)): \(.scope // "" | .[0:80])") end' \
        <<<"$lanes" 2>/dev/null || echo "UNAVAILABLE: unreadable lane map"
    else echo "UNAVAILABLE: do_spl_lane_map failed (run it yourself)"; fi
    echo
    echo "## 7. Hold notes ($ROTATE_HOLD_DIR)"
    spl_rotate_holds
    echo
    echo "## 8. Session tail (the old transcript: last 10 user lines, last 10 assistant texts)"
    spl_rotate_transcript_tail "$tr"
    echo
    echo "## 9. Memory files (names only; read them in $ROTATE_MEMORY_DIR, MEMORY.md is the index)"
    spl_rotate_as_agent find "$ROTATE_MEMORY_DIR" -maxdepth 1 -name '*.md' ! -name MEMORY.md -printf '%f\n' 2>/dev/null |
      sort | sed 's/\.md$//' | tr '\n' ' ' | fold -s -w 110 || true
    echo
  }
  return 0
}

spl_rotate_handoff_asks() {
  [[ -n "$1" ]] || { echo "UNAVAILABLE: do_spl_asks_open failed (run it yourself)"; return 0; }
  jq -r 'def dur: if . == null then "-" elif . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
    [.asks[] | select(.state == "open" or .state == "acked")] | sort_by(-(.age_s // 0)) |
    if length == 0 then "none" else (.[0:40][] |
    "- \(.ask_id[0:8]) \(.kind) from \(.from), \(.age_s | dur), \(.state)\(if .state == "acked" then " by \(.acked_by // "?")" else "" end), topic \(.topic // "-" | .[0:12]): \(.summary // "" | .[0:120])") end' \
    <<<"$1" 2>/dev/null || echo "UNAVAILABLE: unreadable ask book"
  return 0
}

# spl_rotate_json VAR=value... -a <action>: that action's JSON line (its
# do_log lines dropped), or nothing.
spl_rotate_json() {
  local -a kv=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do kv+=("$1"); shift; done
  local out
  out="$(env "${kv[@]}" timeout "${ROTATE_SRC_TIMEOUT:-120}" "$ROTATE_RUN" "$@" 2>/dev/null 7>&- 8>&- 9>&- | grep -m1 '^{')" || true
  jq -e . >/dev/null 2>&1 <<<"$out" && printf '%s' "$out"
  return 0
}

# Run as the agent user (its home is not readable by the box user).
spl_rotate_as_agent() {
  if [[ -z "${SPOOL_AGENT_USER:-}" || "$(id -un)" == "$SPOOL_AGENT_USER" || -n "${ROTATE_AS_AGENT_DIRECT:-}" ]]; then "$@"
  else sudo -n -u "$SPOOL_AGENT_USER" "$@"; fi
}

# spl_rotate_msgs DIR to|from MINUTES|"" MAX WIDTH: the spool messages in a
# dir (only the last MINUTES when given), the newest MAX, oldest first.
spl_rotate_msgs() {
  local lines age=()
  [[ -n "$3" ]] && age=(-mmin "-$3")
  lines="$(find "$1" -maxdepth 1 -name '*.json' "${age[@]}" -print0 2>/dev/null |
    xargs -0 -r jq -r --arg who "$2" --argjson w "$5" '[.ts // "", (if $who == "to" then "-> " + (.to // "") else "<- " + (.from // "") end),
      .kind // "", (.task_id // "" | .[0:12]),
      ((.body // "") | split("\n") | map(select(test("\\S"))) | join(" ") | .[0:$w])]
      | "- \(.[0][5:16]) \(.[1]) \(.[2]) [\(.[3])] \(.[4])"' 2>/dev/null |
    sort | tail -n "$4")"
  printf '%s\n' "${lines:-none}"
}

# The hold notes touched in the last ROTATE_HOLD_DAYS (3) days: name, age,
# title line, up to three NEXT lines; at most 20 topics.
spl_rotate_holds() {
  local d f n=0 head next
  [[ -d "$ROTATE_HOLD_DIR" ]] || { echo "UNAVAILABLE: $ROTATE_HOLD_DIR not found"; return 0; }
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    f="$d"
    [[ -d "$d" ]] && f="$(ls -t "$d"/notes.md "$d"/runbook.md "$d"/*.md 2>/dev/null | sed -n 1p)"
    head="" next=""
    if [[ -f "$f" && "$f" == *.md ]]; then
      head="$(grep -m1 -E '^#+ ' "$f" 2>/dev/null | sed -E 's/^#+ +//' | cut -c1-100)"
      next="$(grep -m3 -iE '(^|[^a-z])next( step)?:' "$f" 2>/dev/null | sed -E 's/^[-* ]+//' | cut -c1-140 | sed 's/^/    /')"
    fi
    echo "- $(basename "$d") ($(( ( $(date +%s) - $(stat -c %Y "$d" 2>/dev/null || date +%s) ) / 3600 ))h ago): ${head:-no notes}"
    [[ -n "$next" ]] && echo "$next"
    n=$((n + 1)); (( n < 20 )) || break
  done < <(find "$ROTATE_HOLD_DIR" -mindepth 1 -maxdepth 1 -mtime "-${ROTATE_HOLD_DAYS:-3}" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  (( n )) || echo "none touched in ${ROTATE_HOLD_DAYS:-3} days"
  return 0
}

# spl_rotate_transcript ID: the old session's transcript path, from its
# identity-map record (session_id + worktree): <agent home>/.claude/projects/
# <worktree with every non-alphanumeric as '-'>/<session_id>.jsonl.
# ROTATE_TRANSCRIPT overrides it.
spl_rotate_transcript() {
  [[ -n "${ROTATE_TRANSCRIPT:-}" ]] && { echo "$ROTATE_TRANSCRIPT"; return 0; }
  local rec="$SPOOL_ROOT/agents/$1.json" sid wt
  sid="$(jq -r '.session_id // empty' "$rec" 2>/dev/null || true)"
  wt="$(jq -r '.worktree // empty' "$rec" 2>/dev/null || true)"
  [[ "$sid" =~ ^[0-9a-f-]{36}$ && -n "$wt" ]] || return 0
  echo "$ROTATE_AGENT_HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")/$sid.jsonl"
}

# The last 10 user lines and 10 assistant text blocks, in order, 300 chars
# each; tool calls and tool results skipped.
spl_rotate_transcript_tail() {
  [[ -n "$1" ]] || { echo "UNAVAILABLE: no transcript path"; return 0; }
  local out
  out="$(spl_rotate_as_agent tail -n "${ROTATE_TRANSCRIPT_LINES:-4000}" "$1" 2>/dev/null | jq -c -R 'fromjson? //empty |
      if .type == "user" and (.message.content | type) == "string" then {r: "user", t: .message.content}
      elif .type == "assistant" and (.message.content | type) == "array" then
        ([.message.content[] | select(.type == "text") | .text] | join(" ") | select(length > 0) | {r: "assistant", t: .})
      else empty end' 2>/dev/null |
    jq -s -r 'to_entries | map(.value + {i: .key}) | ([.[] | select(.r == "user")][-10:] + [.[] | select(.r == "assistant")][-10:])
      | sort_by(.i)[] | "- \(.r): \(.t | gsub("\\s+"; " ") | .[0:300])"' 2>/dev/null)" || true
  printf '%s\n' "${out:-UNAVAILABLE: $1 is unreadable or empty}"
}

# Drop handoffs older than ROTATE_HANDOFF_KEEP_DAYS.
spl_rotate_handoff_prune() {
  find "$ROTATE_HANDOFF_DIR" -maxdepth 1 -name '*.md' -mtime "+$ROTATE_HANDOFF_KEEP_DAYS" -delete 2>/dev/null || true
}

# ---- SPAWN / RESTORE (FR-006, FR-007, FR-013) -----------------------------------

# The identity-map calls (agent-identity.inc.sh); ROTATE_AI replaces them in
# tests: "$ROTATE_AI adopt <ID> <PID>" / "$ROTATE_AI pane-of <ID>".
spl_rotate_ai() {
  if [[ -n "${ROTATE_AI:-}" ]]; then "$ROTATE_AI" "$@"; return; fi
  declare -F ai_adopt >/dev/null || source "$ROTATE_FEAT/lib/agent-identity.inc.sh"
  case "$1" in
    adopt) ai_adopt "$2" "$3" ;;
    pane-of) ai_pane_of "$2" ;;
    retire) ai_py retire "$2" "$3" </dev/null ;;
  esac
}

# The retiring name (FR-007): <ID>-<UTC hhmm>Z-retiring; SPOOL_ID_RE fails on it.
spl_rotate_retiring_name() { echo "$1-${ROTATE_RID:9:4}Z-retiring"; }

# spl_rotate_spawn ID SEED: rename the old window (ROTATE_OLD_PANE) to its
# retiring name, start a new session under the same id with SEED (a brief
# file) through spawn-window.sh (SPAWN_REUSE_ID=1: same spool dir, same
# inbox) in the old window's tmux session, wait ROTATE_START_WAIT for its
# pid, check it runs as the agent user and is not parked on a dialog
# (spl_rotate_start_check), adopt it in the identity map, and check
# ai_pane_of <ID> is the new pane. Sets ROTATE_NEW_PANE / ROTATE_NEW_PID.
# Non-zero = failed, the reason in ROTATE_ERR; the caller runs spl_rotate_restore.
# shellcheck disable=SC2034 # ROTATE_ERR is read by the caller
spl_rotate_spawn() {
  local id="$1" seed="$2" sess out pid user t0 got tag bin wd
  ROTATE_ERR="" ROTATE_NEW_PANE="" ROTATE_NEW_PID="" ROTATE_NEW_DIALOG="" ROTATE_OLD_GONE=""
  # no old window (a seat whose process is gone, do_spl_role_failover): no
  # rename, and spawn-window picks the session (SPOOL_SESSION, else the attached one)
  sess="${SPOOL_SESSION:-}"
  if [[ -n "${ROTATE_OLD_PANE:-}" ]]; then
    spl_rotate_rename_old "$id" || return 1
    sess="$(spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{session_id}' 2>/dev/null || true)"
  fi
  # the box tag the old window showed (<ID>@<tag>), so the new one is named alike
  tag="${SPOOL_BOX_TAG:-}"
  # (named for the old id when the rotation switched it: ROTATE_SWITCH_FROM)
  [[ -z "$tag" && "${ROTATE_OLD_NAME:-}" =~ ^($id|${ROTATE_SWITCH_FROM:-$id})@([a-z0-9][a-z0-9-]*) ]] && tag="${BASH_REMATCH[2]}"
  # the agent user's own claude, not whatever `claude` a login PATH finds
  bin="${ROTATE_CLAUDE_BIN:-${CLAUDE_BIN:-}}"
  [[ -z "$bin" && -x "$ROTATE_AGENT_HOME/.local/bin/claude" ]] && bin="$ROTATE_AGENT_HOME/.local/bin/claude"
  [[ "${ROTATE_KIND:-claude}" == claude ]] || bin=""
  # the second login (SPL-2943): a claude start under CLAUDE_CONFIG_DIR
  local cfg="${ROTATE_CLAUDE_CONFIG_DIR:-}"
  [[ "${ROTATE_KIND:-claude}" == claude ]] || cfg=""
  wd="$(spl_rotate_workdir "$id")" || { ROTATE_ERR="$(spl_rotate_workdir_why "$id")"; return 1; }
  # SPAWN_START_CHECK=0: the dialog check runs here, once the pid is known
  out="$(env SPOOL_SESSION="$sess" SPAWN_REUSE_ID=1 SPAWN_START_CHECK=0 SPOOL_ORCHESTRATOR_ID="${LEASE_ORCH:-}" SPOOL_BOX_TAG="$tag" ${bin:+"CLAUDE_BIN=$bin"} ${cfg:+"SPAWN_CLAUDE_CONFIG_DIR=$cfg"} \
    SPAWN_LANE_SCOPE="${ROTATE_LANE_SCOPE:-role $id (rotation $ROTATE_RID)}" \
    bash "$ROTATE_SPAWN" "${ROTATE_KIND:-claude}" "$id" "$wd" "$seed" rotate 2>&1 7>&- 8>&- 9>&-)" || true
  ROTATE_NEW_PANE="$(grep -m1 -oE "^$id %[0-9]+" <<<"$out" | cut -d' ' -f2)"
  [[ -n "$ROTATE_NEW_PANE" ]] || { ROTATE_ERR="spawn printed no pane: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; return 1; }
  spl_rotate_log "$ROTATE_RID" SPAWN WAIT "spawn-window: $(tr '\n' '|' <<<"$out" | tail -c 400)"
  # a CLI that exits at once must leave its last words: keep the pane until a pid shows
  spl_rotate_tmux set-option -p -t "$ROTATE_NEW_PANE" remain-on-exit on 2>/dev/null || true
  t0=$SECONDS
  while (( SECONDS - t0 < ROTATE_START_WAIT )); do
    for pid in $(spl_rotate_pids "$id"); do
      [[ "$pid" != "${ROTATE_OLD_PID:-}" && "$(spl_rotate_pane_of_pid "$pid")" == "$ROTATE_NEW_PANE" ]] && { ROTATE_NEW_PID="$pid"; break 2; }
    done
    sleep "$ROTATE_POLL"
  done
  [[ -n "$ROTATE_NEW_PID" ]] || { ROTATE_ERR="no ${ROTATE_KIND:-claude} carrying $id started in $ROTATE_NEW_PANE within ${ROTATE_START_WAIT}s; $(spl_rotate_pane_why "$ROTATE_NEW_PANE")"; return 1; }
  spl_rotate_tmux set-option -p -t "$ROTATE_NEW_PANE" remain-on-exit off 2>/dev/null || true
  # the ack sender reads the new pid from the ctx: record it at once
  ROTATE_PHASE=SPAWN spl_rotate_ctx_save "$(spl_rotate_family "${ROTATE_RID##*-}")"
  # agents run as the agent user, never as the box user (FR-006)
  user="$(spl_rotate_user "$ROTATE_NEW_PID")"
  if [[ -n "${SPOOL_AGENT_USER:-}" && "$user" != "$SPOOL_AGENT_USER" ]]; then
    ROTATE_ERR="the new session runs as '$user', not the agent user $SPOOL_AGENT_USER"; return 1
  fi
  spl_rotate_start_check "$ROTATE_NEW_PANE" || return 1
  # pokes must reach the NEW pane from here on (FR-006, FR-018): the map
  # beats window names in spool_pane_of, and with two live processes on one
  # id the plain record keeps the old one, so the new pid is adopted
  spl_rotate_ai adopt "$id" "$ROTATE_NEW_PID" >/dev/null 2>&1 || true
  got="$(spl_rotate_ai pane-of "$id" 2>/dev/null || true)"
  [[ "$got" == "$ROTATE_NEW_PANE" ]] ||
    { ROTATE_ERR="the identity map routes $id to '${got:-nothing}', not the new pane $ROTATE_NEW_PANE"; return 1; }
  return 0
}

# spl_rotate_rename_old ID: the old window gets its retiring name. Non-zero =
# tmux refused; ROTATE_ERR keeps tmux's own words (SPL-2898, row 5 of
# rotation-failures-2026-10-22.md: they went to /dev/null) and
# ROTATE_OLD_GONE=1 when the old pane or the old pid is already gone, which
# the caller ends with spl_rotate_gone_end, not with an alert.
# shellcheck disable=SC2034 # ROTATE_OLD_GONE is read by the callers
spl_rotate_rename_old() {
  local err gone=""
  err="$(spl_rotate_tmux rename-window -t "$ROTATE_OLD_PANE" "$(spl_rotate_retiring_name "$1")" 2>&1 >/dev/null)" && return 0
  err="$(tr '\n' ' ' <<<"$err" | cut -c1-200)"
  spl_rotate_tmux display-message -p -t "$ROTATE_OLD_PANE" '#{pane_id}' >/dev/null 2>&1 || gone="pane $ROTATE_OLD_PANE is gone"
  [[ -z "$gone" && -n "${ROTATE_OLD_PID:-}" ]] && ! spl_rotate_alive "$ROTATE_OLD_PID" && gone="old pid $ROTATE_OLD_PID is gone"
  ROTATE_ERR="tmux refused to rename $ROTATE_OLD_PANE (${err:-no message})${gone:+; $gone}"
  [[ -n "$gone" ]] && ROTATE_OLD_GONE=1
  return 1
}

# spl_rotate_gone_end FAMILY: the end of a run whose SPAWN found the old
# window already gone (ROTATE_OLD_GONE, SPL-2898 fix E): ctx ABORT, one
# "SPAWN SKIP retired" line, no alert. The caller says who is told.
spl_rotate_gone_end() {
  ROTATE_PHASE=ABORT
  spl_rotate_ctx_save "$1"
  spl_rotate_log "$ROTATE_RID" SPAWN SKIP "retired: $ROTATE_ERR; nothing spawned, no alert"
}

# spl_rotate_lease_to FILE: where a note to that lease's holder goes: <id>
# on this box, <id>@<box> on another, orchestrator when it names nobody.
spl_rotate_lease_to() {
  local h=""
  [[ -s "$1" ]] && read -r h _ < "$1"
  spl_is_agent_id "${h%@*}" || { echo orchestrator; return 0; }
  [[ "${h#*@}" == "$ROTATE_BOX" ]] && h="${h%@*}"
  echo "$h"
}

# spl_rotate_prompt_head ID ACK SEED: the head of a role session's FIRST
# prompt (spawn-core SPAWN_PROMPT_HEAD_FILE), the ack line itself, as the lane
# rotation does (spl_lane_rotate_prompt_head): a pointer to the seed was not
# enough, n=4 new sessions on 2026-10-11 never opened it and never acked.
spl_rotate_prompt_head() {
  printf '%s\n\nROTATION %s: you are the new %s session. Run the ack, exactly; run it before anything else (even the rename):\nACK-COMMAND: %s\nThen read your rotation seed %s (your role brief and the handoff) and continue.' \
    "$(spool_truth_rule)" "$ROTATE_RID" "$1" "$2" "$3"
}

# spl_rotate_spawn_head ID SEED ACK: spl_rotate_spawn with the ack line in
# the first prompt: <SEED minus .seed.md>.head.md as SPAWN_PROMPT_HEAD_FILE.
spl_rotate_spawn_head() {
  local head="${2%.seed.md}.head.md"
  spl_rotate_prompt_head "$1" "$3" "$2" > "$head"
  chmod 0644 "$head" 2>/dev/null || true
  SPAWN_PROMPT_HEAD_FILE="$head" spl_rotate_spawn "$1" "$2"
}

# spl_rotate_start_check PANE: up to ROTATE_START_CHECK_WAIT (45 s) for the
# new session's input box (spool_start_check). A known dialog (Settings
# Warning, trust prompt, auth/login, usage limit, auto-mode offer) = 1 at
# once, ROTATE_ERR naming it; the dialog is never answered, so a human fixes
# its cause. Neither within the wait = one WAIT line, 0: a slow start still
# gets its ack window. 2026-10-07: the failover's new session sat on a
# Settings Warning for the whole 600 s ack wait.
# ROTATE_NEW_DIALOG keeps the name: spl_rotate_restore then signals the new
# session and types nothing (an Enter there picks "1. Continue").
# shellcheck disable=SC2034 # ROTATE_ERR / ROTATE_NEW_DIALOG are read by the caller
spl_rotate_start_check() {
  local pane="$1" out rc=0
  out="$(spool_start_check "$pane" "${ROTATE_START_CHECK_WAIT:-45}" spl_rotate_capture_e)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) ROTATE_NEW_DIALOG="$out"
       ROTATE_ERR="the new session in $pane is stopped on a '$out' dialog (not answered: fix its cause$(spool_start_hint "$out"))"
       return 1 ;;
  esac
  spl_rotate_log "${ROTATE_RID:--}" SPAWN WAIT "$pane: $out and no known dialog; screen: $(spl_rotate_screen_tail "$pane")"
  return 0
}

# spl_rotate_workdir ID: the new session's working dir, the first usable of:
# ROTATE_WORKDIR; the id's newest registry rundir (on a seat switch, the other
# end's too: ROTATE_SWITCH_FROM / ROTATE_SWITCH_TO); the old process's cwd,
# read as root (ROTATE_PRIV, default sudo -n) when the caller cannot (the old
# pid runs as the agent user); for a role id (LEASE_ORCH / _MASTER /
# _FAILOVER or a seat switch end) the role's checkout, ROTATE_ROLE_WORKDIR,
# else the tree this code runs from. Never a home dir (spl_rotate_is_home):
# there Claude loads <home>/.claude/settings.json as PROJECT settings; on
# 2026-10-20 (one box, rid 20261020T0905Z-orch) its failing hook denied every
# Bash call and the successor never acked (SPL-2715). Nothing usable =
# prints nothing, exit 1: the caller fails the step (spl_rotate_workdir_why).
spl_rotate_workdir() {
  local id="$1" d c
  for c in "${ROTATE_WORKDIR:-}" "$(spl_rotate_registry_dir "$id")" \
           "$(spl_rotate_registry_dir "${ROTATE_SWITCH_FROM:-}")" "$(spl_rotate_registry_dir "${ROTATE_SWITCH_TO:-}")" \
           "$(spl_rotate_old_cwd)"; do
    spl_rotate_workdir_ok "$c" && { echo "$c"; return 0; }
  done
  if spl_rotate_is_role "$id"; then
    d="${ROTATE_ROLE_WORKDIR:-}"
    [[ -n "$d" || -z "${PROJ_PATH:-}" ]] || d="$(cd "$PROJ_PATH/.." 2>/dev/null && pwd || true)"
    spl_rotate_workdir_ok "$d" && { echo "$d"; return 0; }
  fi
  return 1
}

# The refusal reason for a step whose spl_rotate_workdir printed nothing.
spl_rotate_workdir_why() {
  local role=""
  spl_rotate_is_role "$1" && role=", no role checkout"
  echo "no working dir for $1: no registry rundir, the old pid's cwd (pid ${ROTATE_OLD_PID:-none}) unreadable or a home dir$role; a new session never starts in a home dir (SPL-2715)"
}

# The newest registry rundir of ID (nothing for an empty ID).
spl_rotate_registry_dir() {
  [[ -n "${1:-}" ]] || return 0
  awk -F'\t' -v id="$1" '$1 == id {r = $4} END {print r}' "$SPOOL_ROOT/registry.tsv" 2>/dev/null || true
}

# The old process's cwd: read plainly, else as root (ROTATE_PRIV).
spl_rotate_old_cwd() {
  local f="${LEASE_PROC_ROOT:-/proc}/${ROTATE_OLD_PID:-}/cwd"
  [[ -n "${ROTATE_OLD_PID:-}" ]] || return 0
  readlink "$f" 2>/dev/null || ${ROTATE_PRIV:-sudo -n} readlink "$f" 2>/dev/null || true
}

# 0 when DIR is an existing dir and not a home dir.
spl_rotate_workdir_ok() { [[ -n "$1" && -d "$1" ]] && ! spl_rotate_is_home "$1"; }

# 0 when DIR is $HOME, the agent user's home or any account's home (passwd).
spl_rotate_is_home() {
  local d h
  d="$(cd "$1" 2>/dev/null && pwd -P || echo "$1")"
  for h in "${HOME:-}" "${ROTATE_AGENT_HOME:-}"; do
    [[ -n "$h" && "$d" == "$(cd "$h" 2>/dev/null && pwd -P || echo "$h")" ]] && return 0
  done
  getent passwd 2>/dev/null | cut -d: -f6 | grep -xF -- "$d" >/dev/null
}

# 0 when ID holds a role here (lease.conf), is one end of a seat switch or
# a role seat id (<letter>-001..004, spec 102 section 2).
spl_rotate_is_role() {
  [[ -n "$1" ]] || return 1
  [[ "$1" =~ ^[a-z]-00[1-4]$ ]] && return 0
  case "$1" in
    "${LEASE_ORCH:-/}"|"${LEASE_MASTER:-/}"|"${LEASE_FAILOVER:-/}"|"${ROTATE_SWITCH_FROM:-/}"|"${ROTATE_SWITCH_TO:-/}") return 0 ;;
  esac
  return 1
}

# spl_rotate_restore ID OLD_PANE NEW_PANE: the failure path. The new session
# (ROTATE_NEW_PID, if any) gets /exit and is killed after
# ROTATE_NEW_EXIT_WAIT (a session parked on a dialog, ROTATE_NEW_DIALOG: TERM,
# KILL, nothing typed), its window is closed by pane id, the old window gets
# its name back (ROTATE_OLD_NAME), and the identity map points at the old pid
# again, so pokes reach the session that keeps the role.
spl_rotate_restore() {
  local id="$1" old="$2" new="$3" t0
  if [[ -n "${ROTATE_NEW_PID:-}" && -n "${ROTATE_NEW_DIALOG:-}" ]]; then
    ${ROTATE_KILL:-sudo -n kill} -TERM "$ROTATE_NEW_PID" 2>/dev/null || true
    t0=$SECONDS; while (( SECONDS - t0 < 5 )) && spl_rotate_alive "$ROTATE_NEW_PID"; do sleep 1; done
    if spl_rotate_alive "$ROTATE_NEW_PID"; then ${ROTATE_KILL:-sudo -n kill} -KILL "$ROTATE_NEW_PID" 2>/dev/null || true; fi
  elif [[ -n "${ROTATE_NEW_PID:-}" && -n "$new" ]]; then
    spl_rotate_end "$new" "$ROTATE_NEW_PID" /exit "$ROTATE_NEW_EXIT_WAIT" 5 || true
  fi
  [[ -n "$new" ]] && { spl_rotate_tmux kill-window -t "$new" 2>/dev/null || true; }
  if [[ -n "$old" ]]; then
    spl_rotate_tmux rename-window -t "$old" "${ROTATE_OLD_NAME:-$(spool_decorate "$id")}" 2>/dev/null || true
  fi
  if [[ -n "${ROTATE_OLD_PID:-}" ]] && spl_rotate_alive "$ROTATE_OLD_PID"; then
    spl_rotate_ai adopt "$id" "$ROTATE_OLD_PID" >/dev/null 2>&1 || true
  fi
  return 0
}

# ---- RETIRE (FR-015) -----------------------------------------------------------

# spl_rotate_input PANE: the text in the CLI's input box, one line per row,
# blank rows dropped: the rows between the last two ─ rules, with the ❯
# marker, the indent and the DIM ghost suggestion cut away (the ghost cut is
# spool_notify_strip_ghost's). Exit 1 when no box is on screen. Measured on a
# throwaway claude 2026-10-02: an empty box is "❯<NBSP>ESC[2mTry ...", three
# typed rows are "❯ a" / "  b" / "  c", and the slash menu draws ABOVE it.
spl_rotate_input() { spl_rotate_capture_e "$1" | spool_screen_input_box; }
spl_rotate_capture_e() { spl_rotate_tmux capture-pane -p -e -t "$1" 2>/dev/null; }

# spl_rotate_type PANE CMD: the WHOLE input box emptied, CMD typed, 0 only
# when the box then reads exactly CMD; what it read is left in
# ROTATE_INPUT_READ. C-u empties one row only: CLE-77939's QUIESCE Escape put
# a multi-row poke back into the box and /exit-clean was sent appended to it.
# C-c empties every row, and is sent only to a box that holds text: on an
# empty box it arms "Press Ctrl-C again to exit" (both measured 2026-10-02).
spl_rotate_type() {
  local pane="$1" cmd="$2"
  ROTATE_INPUT_READ="$(spl_rotate_input "$pane")" || { ROTATE_INPUT_READ="(no input box)"; return 1; }
  if [[ -n "$ROTATE_INPUT_READ" ]]; then
    spl_rotate_tmux send-keys -t "$pane" C-c 2>/dev/null || true
    sleep 1
    ROTATE_INPUT_READ="$(spl_rotate_input "$pane")" || { ROTATE_INPUT_READ="(no input box)"; return 1; }
    [[ -z "$ROTATE_INPUT_READ" ]] || return 1
  fi
  spl_rotate_tmux send-keys -t "$pane" -l "$cmd" 2>/dev/null || true
  sleep 1
  ROTATE_INPUT_READ="$(spl_rotate_input "$pane")" || { ROTATE_INPUT_READ="(no input box)"; return 1; }
  [[ "$ROTATE_INPUT_READ" == "$cmd" ]]
}

# spl_rotate_end PANE PID CMD WAIT TERM_WAIT [THEN]: CMD typed into the
# emptied input box and Enter only once the box reads exactly CMD (one retry;
# a busy session queues it), then SIGTERM after WAIT s, SIGKILL after
# TERM_WAIT s more. A box that never reads CMD gets no Enter and goes straight
# to SIGTERM. THEN (once): typed the same way when the pid is still alive
# ROTATE_EXIT_SETTLE s after the Enter and the pane reads idle, i.e. CMD's
# turn has ended without ending the process. A session with background work
# answers the last /exit typed (THEN, or CMD when there is no THEN) with a
# "Background work is running" picker: its highlighted "1. Exit and stop
# tasks" gets one Enter (1105Z, 2026-10-02: the old orchestrator's dispatcher
# refresh shell held it open until SIGTERM, which stops those tasks anyway;
# 2026-10-11 19:52Z: a lane's bare /exit waited 120 s for the same SIGTERM). Each fallback logged, the
# SIGTERM one with the pane's last rows. 0 once gone.
spl_rotate_end() {
  local pane="$1" pid="$2" cmd="$3" wait="$4" twait="$5" then="${6:-}" t0 try typed=0 stop_asked=0
  spl_rotate_alive "$pid" || return 0
  for try in 1 2; do
    spl_rotate_type "$pane" "$cmd" && { typed=1; break; }
    spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "try $try: input box of $pane reads '$(printf '%s' "$ROTATE_INPUT_READ" | tr '\n' '|' | cut -c1-120)', not '$cmd'"
  done
  if (( typed )); then
    spl_rotate_tmux send-keys -t "$pane" Enter 2>/dev/null || true
    t0=$SECONDS; while (( SECONDS - t0 < wait )); do
      spl_rotate_alive "$pid" || return 0
      if (( stop_asked == 0 )) && [[ -z "$then" ]] && spl_rotate_screen "$pane" | grep -E '❯ 1\. Exit and stop tasks' >/dev/null; then
        spl_rotate_tmux send-keys -t "$pane" Enter 2>/dev/null || true
        spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid: '${6:-$cmd}' asked about running background work: 'Exit and stop tasks' confirmed"
        stop_asked=1
      fi
      if [[ -n "$then" ]] && (( SECONDS - t0 >= ${ROTATE_EXIT_SETTLE:-10} )) && spl_rotate_idle "$pane"; then
        spl_rotate_alive "$pid" || return 0
        if spl_rotate_type "$pane" "$then"; then
          spl_rotate_tmux send-keys -t "$pane" Enter 2>/dev/null || true
          spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid idle and alive $((SECONDS - t0))s after '$cmd': '$then' typed"
        else
          spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid idle after '$cmd', but its box reads '$(printf '%s' "$ROTATE_INPUT_READ" | tr '\n' '|' | cut -c1-120)', not '$then'"
        fi
        then=""
      fi
      sleep 1
    done
    spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid alive ${wait}s after '$cmd': SIGTERM; screen: $(spl_rotate_screen_tail "$pane")"
  else
    spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid: '$cmd' never read back, no Enter: SIGTERM"
  fi
  # ROTATE_PRE_TERM PANE PID: the caller's last step before the signal (the
  # lane rotation stops a restore wrapper that would relaunch the session)
  [[ -n "${ROTATE_PRE_TERM:-}" ]] && { "$ROTATE_PRE_TERM" "$pane" "$pid" || true; }
  ${ROTATE_KILL:-sudo -n kill} -TERM "$pid" 2>/dev/null || true
  t0=$SECONDS; while (( SECONDS - t0 < twait )); do spl_rotate_alive "$pid" || return 0; sleep 1; done
  spl_rotate_log "${ROTATE_RID:--}" RETIRE WAIT "pid $pid alive ${twait}s after SIGTERM: SIGKILL"
  ${ROTATE_KILL:-sudo -n kill} -KILL "$pid" 2>/dev/null || true
  t0=$SECONDS; while (( SECONDS - t0 < 5 )); do spl_rotate_alive "$pid" || return 0; sleep 1; done
  return 1
}

# spl_rotate_screen_tail PANE: the pane's last 4 non-blank rows on one line
# (rules and the box marker dropped), so a SIGTERM line says what was on screen.
spl_rotate_screen_tail() {
  spl_rotate_screen "$1" | grep -vE '^[[:space:]]*$|^─+$|^❯[[:space:]]*$' | tail -n 4 |
    sed -E 's/^[[:space:]]+//' | tr '\n' '|' | cut -c1-240 || true
}

# spl_rotate_retire PANE PID: /exit-clean; then /exit once its turn ends with
# the process alive (a model cannot run the built-in /exit, so the skill's
# last step never ends the session: 0805Z and 0905Z on 2026-10-02 were
# SIGTERMed 300 s later, 0605Z and 0705Z were closed by the skill's deferred
# window-close timeout); ROTATE_EXIT_WAIT (300 s), TERM, ROTATE_TERM_WAIT
# (30 s), KILL. Non-zero = it survived SIGKILL. `no-close`: the CLOSE step
# closes the old window by pane id; the skill's own deferred close of the
# same id killed the fresh seat (c-002 %589, 2026-10-07 09:22:21Z).
spl_rotate_retire() { spl_rotate_end "$1" "$2" "/exit-clean no-close" "$ROTATE_EXIT_WAIT" "$ROTATE_TERM_WAIT" /exit; }

# ---- ACK (FR-041) ----------------------------------------------------------------

spl_rotate_ack_task() { echo "$(spl_rotate_family "${1##*-}")-rotate-$1"; }

# spl_rotate_ack_wait ID RID TIMEOUT: 0 once <ID>/outbox holds a result from
# <ID> on task <family>-rotate-<rid>; 2 when the new session
# (ROTATE_NEW_PID) dies first; 1 on the timeout. Only the outbox counts: an
# inbox copy may be drained by someone else (FR-041).
spl_rotate_ack_wait() {
  local id="$1" rid="$2" timeout="$3" task t0
  task="$(spl_rotate_ack_task "$rid")"
  t0=$SECONDS
  while (( SECONDS - t0 < timeout )); do
    spl_rotate_ack_seen "$id" "$task" && return 0
    [[ -n "${ROTATE_NEW_PID:-}" ]] && ! spl_rotate_alive "$ROTATE_NEW_PID" && return 2
    sleep "$ROTATE_POLL"
  done
  spl_rotate_ack_seen "$id" "$task"
}

# A role seat's ack may come from any of its ids (SPL-1685): the new session
# acks as the lease.conf id, still the old letter until the switch flips it,
# and the old id's outbox is a link to the new one.
spl_rotate_ack_seen() {  # ID TASK
  local ids
  ids="$(spl_role_seat_ids "$1" 2>/dev/null || echo "$1")"
  find "$SPOOL_ROOT/$1/outbox" -maxdepth 1 -name '*.json' -mmin -120 -print0 2>/dev/null |
    xargs -0 -r jq -r --arg ids "$ids" --arg t "$2" 'select(.kind == "result" and .task_id == $t and (((.from // "") | sub("@.*"; "")) as $f | $ids | split("\n") | any(. == $f))) | .msg_id' 2>/dev/null |
    grep . >/dev/null
}

# spl_rotate_ack_send ROLE ID: the new session's ack (ROTATE_CMD=ack
# ROTATE_ID=<rid>). Refused with exit 3 unless ROTATE_ID is the rotation in
# flight, its phase waits for the ack, and the claude process that ran the
# command (the nearest claude above this shell; ROTATE_CALLER_PID in tests)
# is that rotation's NEW pid. Then one `result` from <ID> on task
# <family>-rotate-<rid>, which lands in <ID>/outbox.
spl_rotate_ack_send() {
  local role="$1" id="$2" fam caller rc=0
  fam="$(spl_rotate_family "$role")"
  [[ "${ROTATE_ID:-}" =~ ^[0-9]{8}T[0-9]{4}Z-[a-z]+(-[a-z]-[0-9]{3})?$ ]] || { do_log "FATAL ROTATE_ID must be the rotation id from your seed"; return 3; }
  if ! spl_rotate_ctx_load "$fam" || [[ "$ROTATE_RID" != "$ROTATE_ID" ]]; then
    spl_rotate_log "$ROTATE_ID" ACK FAIL "refused: not the rotation in flight (${ROTATE_RID:-none})"; return 3
  fi
  # a quick new session may ack before the rotation has recorded its pid
  local t0=$SECONDS
  while [[ ( "$ROTATE_PHASE" == HANDOFF || -z "$ROTATE_NEW_PID" ) && "$ROTATE_RID" == "$ROTATE_ID" ]] && (( SECONDS - t0 < ${ROTATE_ACK_EARLY_WAIT:-60} )); do
    sleep 1; spl_rotate_ctx_load "$fam" || true
  done
  [[ "$ROTATE_PHASE" == SPAWN || "$ROTATE_PHASE" == ACK ]] ||
    { spl_rotate_log "$ROTATE_ID" ACK FAIL "refused: rotation is at $ROTATE_PHASE, not waiting for an ack"; return 3; }
  caller="${ROTATE_CALLER_PID:-$(spl_rotate_claude_ancestor)}"
  [[ -n "$caller" && "$caller" == "$ROTATE_NEW_PID" ]] ||
    { spl_rotate_log "$ROTATE_ID" ACK FAIL "refused: caller pid '${caller:-none}' is not the new session $ROTATE_NEW_PID"; return 3; }
  SPOOL_ROOT="$SPOOL_ROOT" bash "$ROTATE_SEND" --from "$id" --to "$id" --kind result --task "$(spl_rotate_ack_task "$ROTATE_ID")" \
    --no-ask --no-poke --body "ACK rotation $ROTATE_ID: $id pid $caller read the handoff and the inbox." >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  (( rc < 10 && rc != 2 )) || { spl_rotate_log "$ROTATE_ID" ACK FAIL "spool-send exit $rc"; return 1; }
  spl_rotate_log "$ROTATE_ID" ACK OK "sent by pid $caller"
}

# ---- ALERT (FR-075) ----------------------------------------------------------------

# spl_rotate_alert ROLE RID PHASE REASON [STATE]: an ask in the ask book (kind
# blocker, topic <family>-rotate-<rid>) and, at once, a notice in the fleet's
# ops channel (spl_rotate_owner_say). No hub setting: one WARN, the ask alone. Best effort, logged. The ask is
# also recorded in <spool root>/<id>/lifetime/alerts.open ("<ask> <rid>
# <phase>"), so the seat's next healthy start can say it recovered
# (spl_rotate_recovered).
spl_rotate_alert() {
  local role="$1" rid="$2" phase="$3" reason="$4" id body ask
  id="$(spl_rotate_role_id "$role")"
  spl_rotate_alert_repeat "$role $id $phase ${ROTATE_OLD_PID:-}" "$rid" && return 0
  # a 5th argument replaces "old session kept" once RETIRE OK has run
  body="ROTATION FAILED $role $phase $reason; ${5:-old session kept: $id@$ROTATE_BOX pid ${ROTATE_OLD_PID:-?}}"
  ask="$(cat /proc/sys/kernel/random/uuid)"
  if env ASK_ID="$ask" ASK_KIND=blocker ASK_FROM="$id" ASK_TO="${LEASE_ORCH:-}" ASK_TOPIC="$(spl_rotate_ack_task "$rid")" \
      ASK_SUMMARY="$body" timeout 120 "$ROTATE_RUN" -a do_spl_ask_put >/dev/null 2>&1 7>&- 8>&- 9>&-; then
    spl_rotate_log "$rid" ALERT OK "ask ${ask:0:8} in the ask book"
    spl_rotate_alert_streak "$role $id $phase ${ROTATE_OLD_PID:-}" "$rid" "$ask"
    if spl_is_agent_id "$id" && mkdir -p "$SPOOL_ROOT/$id/lifetime" 2>/dev/null; then
      echo "$ask $rid $phase" >> "$SPOOL_ROOT/$id/lifetime/alerts.open" 2>/dev/null || true
    fi
  else spl_rotate_log "$rid" ALERT FAIL "do_spl_ask_put failed"; fi
  spl_rotate_owner_say "$rid" "$id" "$ask" "**$body**" blocker
  return 0
}

# One alert per streak (SPL-2898, rotation-failures-2026-10-22.md section 2:
# one cause gave 20 FAIL runs on the same old pid in 19 h, and 12 notices).
# The streak is rotate.<family>.alert-streak, one line "<role> <id> <phase>
# <old pid> <ask> <n>"; a DONE OK removes it (spl_rotate_log). Only a numeric
# old pid makes a key: with none every failure alerts, as before.
# spl_rotate_alert_repeat KEY RID: 0 = KEY is the open streak: its count goes
# up and one "ALERT SKIP repeat <n> of ask <id8>" line is logged.
spl_rotate_alert_repeat() {
  local key="$1" rid="$2" f r i p o ask n
  [[ "$key" =~ \ [0-9]+$ ]] || return 1
  f="$(spl_rotate_alert_streak_file "$rid")"
  [[ -s "$f" ]] && read -r r i p o ask n < "$f" || return 1
  [[ "$r $i $p $o" == "$key" && "$n" =~ ^[0-9]+$ ]] || return 1
  n=$((n + 1))
  echo "$key $ask $n" > "$f" 2>/dev/null || true
  spl_rotate_log "$rid" ALERT SKIP "repeat $n of ask ${ask:0:8} ($key): no new ask, no notice"
  return 0
}
# spl_rotate_alert_streak KEY RID ASK: a new streak starts at ASK.
spl_rotate_alert_streak() {
  [[ "$1" =~ \ [0-9]+$ ]] || return 0
  echo "$1 $3 1" > "$(spl_rotate_alert_streak_file "$2")" 2>/dev/null || true
}
spl_rotate_alert_streak_file() { echo "${ROTATE_STATE_DIR:-$LEASE_DIR}/rotate.$(spl_rotate_family "${1##*-}").alert-streak"; }

# spl_rotate_owner_say RID ID ASK BODY KIND [PHASE]: the people leg of an
# alert: a new topic in the fleet's ops channel (do_spl_fleet_notice, cnf
# env.fleet_notices.channel), never a DM to the owner (SPL-2584, t1 4b49e47d;
# how-to-post.md rule 18). ASKS_OWNER_CMD replaces it (tests). Logged under
# PHASE (ALERT); no LEASE_ENV / LEASE_TENANT: one WARN.
spl_rotate_owner_say() {
  local rid="$1" id="$2" ask="$3" body="$4" kind="$5" ph="${6:-ALERT}"
  if [[ -n "${ASKS_OWNER_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    if ASK_JSON="{\"ask_id\":\"$ask\"}" $ASKS_OWNER_CMD <<<"$body" >/dev/null 2>&1 7>&- 8>&- 9>&-; then
      spl_rotate_log "$rid" "$ph" OK "owner told (ASKS_OWNER_CMD)"
    else spl_rotate_log "$rid" "$ph" FAIL "ASKS_OWNER_CMD failed"; fi
  elif [[ -n "${LEASE_ENV:-}" && -n "${LEASE_TENANT:-}" ]]; then
    if env ENV="$LEASE_ENV" TENANT_ID="$LEASE_TENANT" DESK_AGENT="$id" DESK_KIND="$kind" \
        DESK_BODY="$body" DRY_RUN=0 timeout 120 "$ROTATE_RUN" -a do_spl_fleet_notice >/dev/null 2>&1 7>&- 8>&- 9>&-; then
      spl_rotate_log "$rid" "$ph" OK "ops channel notice (ask ${ask:0:8})"
    else spl_rotate_log "$rid" "$ph" FAIL "the ops channel notice failed"; fi
  else
    spl_rotate_log "$rid" "$ph" WARN "no ops notice (ASKS_OWNER_CMD, or LEASE_ENV + LEASE_TENANT in $LEASE_CONF): the ask alone"
  fi
  return 0
}

# spl_rotate_recovered ID RID ACTION PID: ID had a FAIL alert (lifetime/alerts.open)
# and is healthy again (a rotation's ACK OK, a restart's DONE OK): every ask
# in it is closed in the ask book, and ONE line goes to the owner on the
# newest ask's thread: "<ID>@<box> recovered at <ts> by <ACTION>, now pid
# <PID>". Then the file goes. No alert open: nothing. 2026-10-07: c-003's
# failed rotation was alerted at 17:39Z, rs-c-003 restarted it at 17:40Z, and
# no post ever said so. Best effort, logged as RECOVERED under RID, the run
# that found it healthy (never the failed run's id: its .state would read the
# failed rotation as in flight again).
spl_rotate_recovered() {
  local id="$1" rid="$2" action="$3" pid="$4" f ask arid last="" line ts n=0 rc
  f="$SPOOL_ROOT/$id/lifetime/alerts.open"
  [[ -s "$f" ]] || return 0
  ts="$(date -u +%FT%TZ)"
  line="$id@$ROTATE_BOX recovered at $ts by $action, now pid ${pid:-?}"
  while read -r ask arid _; do
    [[ "$ask" =~ ^[0-9a-f-]{36}$ ]] || continue
    n=$((n + 1)); last="$ask"
    rc=0
    env ASK_ID="$ask" ASK_STATE=done ASK_REASON="$line" ASK_BY="$id@$ROTATE_BOX" \
      timeout 120 "$ROTATE_RUN" -a do_spl_ask_close >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
    # exit 3 = another holder closed it first (SPL-1890: all 6 "RECOVERED
    # FAIL" lines of 10-11..10-14 were asks the orchestrator had closed)
    case "$rc" in
      0) spl_rotate_log "$rid" RECOVERED OK "ask ${ask:0:8} of $arid closed: $line" ;;
      3) spl_rotate_log "$rid" RECOVERED OK "ask ${ask:0:8} of $arid was already closed: $line" ;;
      *) spl_rotate_log "$rid" RECOVERED FAIL "ask ${ask:0:8} of $arid: do_spl_ask_close failed, exit $rc ($line)" ;;
    esac
  done < "$f"
  rm -f "$f"
  (( n )) || return 0
  spl_rotate_owner_say "$rid" "$id" "$last" "$line" note RECOVERED
  return 0
}

# spl_rotate_note TO TASK BODY: a spool note (FR-073: FAILs, stalls, DONE).
spl_rotate_note() {
  local from="${LEASE_ORCH:-$1}" kind="${4:-note}" rc=0
  SPOOL_ROOT="$SPOOL_ROOT" bash "$ROTATE_SEND" --from "$from" --to "$1" --kind "$kind" --task "$2" --no-ask --body "$3" \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || rc=$?
  return 0
}
