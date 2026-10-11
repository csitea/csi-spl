#!/bin/bash
#------------------------------------------------------------------------------
# @description The agent login self-heal (owner HUM-10, 2026-10-11: "it has one
# @description script to execute"): ONE action, the same on every box, run by
# @description the box cron every minute (row agent-login-check of
# @description cnf/box-crons/box-crons.manifest, do_install_box_crons). A tick:
# @description   1. scan: every live claude agent of the identity map whose pane
# @description      footer shows a dead login ("Login expired", "Please run
# @description      /login") or a usage-limit screen ("hit your ... limit") AND
# @description      whose transcript's last answer is an API error is STUCK.
# @description   2. probe: `claude -p` as the agent user (agent-login-cred.sh
# @description      probe): ok | expired | limited | unknown. Every
# @description      LOGIN_PROBE_EVERY s (300), and at once when a pane is stuck.
# @description   3. peers (SPOOL_LOGIN_PEERS in box.env, "<tag>=<ssh dest>,...",
# @description      set with box-config.sh; empty = none): the box that names
# @description      peers is the ONE refresher. When its credential's sha
# @description      prefix differs from a peer's and it probes ok here, it is
# @description      pushed (temp + mv, the old one kept as .bak-login-<UTC>,
# @description      mode 600). A NEWER peer credential is reported, never
# @description      overwritten or pulled. Limited = no push, alert only.
# @description   4. repair, only while the probe says ok: stop each stuck
# @description      agent - its pane (and the wrapper that would relaunch
# @description      claude in it), then ITS OWN claude pid (TERM, KILL after
# @description      LOGIN_STOP_WAIT s) - then do_spl_agent_identity_restore
# @description      for that seat alone, seat by seat, at most once per tick.
# @description      A seat is stopped only when the restore can bring it back
# @description      (session, worktree, adapter, transcript) and it is still
# @description      stuck at the moment of the stop; a seat restored, or whose
# @description      claude started, under the cool-down (cnf
# @description      env.box.login_check.cooldown_min, 10 min) ago is left
# @description      alone. No /login step (owner a7499dc2). A dead login on
# @description      disk is never restored into.
# @description   5. expiry (spec 132 section 3): this box's credential sample
# @description      goes to <state>/cred.log when it changed ("<UTC> <sha12>
# @description      <expiresAt ms> peers=<n>", read by do_spl_agent_login_proof),
# @description      and an expiry under LOGIN_EXPIRY_WARN_MIN (60) minutes,
# @description      not renewed, is an early warning: the refresher is silent.
# @description   6. alert: one spool message to the dispatch lease holder with
# @description      the counts before and after, when it acted or when a
# @description      problem first shows (deduplicated by its state: an early
# @description      warning once per credential, an unreachable peer once).
# @description Never prints credential content: sha256 prefixes (12) only.
# @description A healthy box: 0 actions, one summary line. One tick at a time
# @description (flock). Dry run unless DRY_RUN=0: plans, probes, no change.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param LOGIN_PROBE_EVERY (optional) - s between probes on a healthy box, default 300 (0 = every tick)
# @param LOGIN_STOP_WAIT (optional) - s a stopped claude gets before KILL, default 15
# @param LOGIN_COOLDOWN_MIN (optional) - minutes a just restored or started seat is left alone; default cnf env.box.login_check.cooldown_min (10)
# @param LOGIN_STATE_DIR (optional) - default /var/csi/csi-spl/agent-login-check
# @param LOGIN_PEERS (optional) - overrides SPOOL_LOGIN_PEERS of box.env
# @param LOGIN_ALERT_TO (optional) - default the dispatch lease holder
# @param LOGIN_EXPIRY_WARN_MIN (optional) - early warning under this many minutes to expiry, default 60 (0 = off)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_agent_login_check
# @example DRY_RUN=0 ./run -a do_spl_agent_login_check
#------------------------------------------------------------------------------
LC_FOOT_LOGIN_RE='login expired|please run /login|oauth (session|token) (has )?expired|could not be refreshed'
LC_FOOT_LIMIT_RE='(you[^[:space:]]* )?hit your ([a-z]+ )?limit|usage limit reached'

do_spl_agent_login_check() {
  local dry="${DRY_RUN:-1}" every="${LOGIN_PROBE_EVERY:-300}" wait="${LOGIN_STOP_WAIT:-15}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$every" =~ ^[0-9]+$ && "$wait" =~ ^[0-9]+$ ]] || { do_log "FATAL LOGIN_PROBE_EVERY and LOGIN_STOP_WAIT must be seconds"; return 1; }
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  local feat="$PROJ_PATH/src/bash/features/spawn-agents"
  # shellcheck source=../features/spawn-agents/lib/agent-identity.inc.sh
  source "$feat/lib/agent-identity.inc.sh" || return 1
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then spool_test_guard || return 96; fi
  LC_STATE="${LOGIN_STATE_DIR:-/var/csi/csi-spl/agent-login-check}"
  LC_CRED="${LOGIN_CRED_CMD:-bash $PROJ_PATH/src/bash/scripts/agent-login-cred.sh}"
  mkdir -p "$LC_STATE" 2>/dev/null || { do_log "FATAL cannot create $LC_STATE"; return 1; }
  exec 8>>"$LC_STATE/tick.lock" || return 1
  flock -n 8 || { echo "login-check: another tick holds $LC_STATE/tick.lock - skipped"; return 0; }
  LC_TAG="$(ai_tag)"; LC_DRY="$dry"
  LC_COOL="$(_lc_cooldown_min)" || return 1; LC_COOL=$((LC_COOL * 60))
  [[ -n "${SPOOL_AGENT_USER:-}" ]] || SPOOL_AGENT_USER="$(SPOOL_AGENT_USER=''; _spool_box_env_load; printf '%s' "${SPOOL_AGENT_USER:-}")"
  LC_NOTE=() ; LC_WARN=() ; LC_WKEY="" ; LC_COPIED=0 ; LC_STOPPED=0 ; LC_RESTORED=0 ; LC_FAILED=0

  local stuck0 verdict0 verdict stuck1="" alerted=0
  stuck0="$(_lc_scan)"
  verdict0="$(_lc_probe "$every" "$stuck0")"
  verdict="$verdict0"
  _lc_peers verdict
  [[ -n "$stuck0" ]] && _lc_repair "$verdict" "$stuck0" "$wait"
  _lc_expiry
  if (( LC_STOPPED + LC_COPIED > 0 )) && [[ "$dry" == 0 ]]; then stuck1="$(_lc_scan)"; else stuck1="$stuck0"; fi
  _lc_alert "$verdict0" "$verdict" "$stuck0" "$stuck1" && alerted=1
  echo "login-check@${LC_TAG:-box}: probe=${verdict%% *} stuck_login=$(_lc_n login "$stuck0") stuck_limit=$(_lc_n limit "$stuck0") copied=$LC_COPIED stopped=$LC_STOPPED restored=$LC_RESTORED failed=$LC_FAILED alerted=$alerted$([[ "$dry" == 1 ]] && echo ' (DRY_RUN)')"
  exec 8>&-
  (( LC_FAILED == 0 ))
}

# The cool-down in minutes: LOGIN_COOLDOWN_MIN, else cnf
# env.box.login_check.cooldown_min, else 10.
_lc_cooldown_min() {
  local m="${LOGIN_COOLDOWN_MIN:-}" oa cnf
  if [[ -z "$m" ]]; then
    oa="$(basename "$PROJ_PATH")"; oa="${oa%-orc}"
    cnf="${LOGIN_CNF:-$PROJ_PATH/../$oa-cnf/$oa/all.env.yaml}"
    m="$(yq -r '.env.box.login_check.cooldown_min // ""' "$cnf" 2>/dev/null)"
  fi
  m="${m:-10}"
  [[ "$m" =~ ^[0-9]+$ ]] || { do_log "FATAL the login check cool-down must be whole minutes, got: '$m'"; return 1; }
  echo "$m"
}

# How many lines of the scan carry WHAT (login | limit).
_lc_n() { [[ -z "$2" ]] && { echo 0; return; }; awk -v w="$1" '$4 == w' <<<"$2" | wc -l; }

# Every live claude agent: "<id> <pid> <pane>" (LOGIN_AGENTS_CMD in the tests).
_lc_agents() {
  if [[ -n "${LOGIN_AGENTS_CMD:-}" ]]; then bash -c "$LOGIN_AGENTS_CMD"; return 0; fi
  local id pid pane live
  live="$(ai_tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    # ai_alive_fast fills AI_REC in its own subshell here: read the kind apart
    [[ "$(ai_field "$id" kind)" =~ ^(claude|)$ ]] || continue
    pid="$(ai_alive_fast "$id")" || continue
    pane="$(ai_pane_of "$id" "$live")" || continue
    echo "$id $pid $pane"
  done < <(ai_live_ids)
}

# The stuck agents: "<id> <pid> <pane> login|limit". Two signals each: the
# pane's footer AND the transcript's last answer being an API error, so a
# pane that merely shows the words (an agent discussing them) is not stuck.
_lc_scan() {
  local id pid pane what
  while read -r id pid pane; do
    [[ -n "$pane" ]] || continue
    what="$(_lc_stuck_now "$pid" "$pane")" || continue
    echo "$id $pid $pane $what"
  done < <(_lc_agents)
}

# login | limit when PANE's footer shows the banner AND PID's last transcript
# answer is an API error; non-zero otherwise.
_lc_stuck_now() {
  local pid="$1" pane="$2" foot what
  foot="$(_lc_capture "$pane" | grep -v '^[[:space:]]*$' | tail -n "${LOGIN_PANE_TAIL:-8}")"
  if grep -qiE "$LC_FOOT_LOGIN_RE" <<<"$foot"; then what=login
  elif grep -qiE "$LC_FOOT_LIMIT_RE" <<<"$foot"; then what=limit
  else return 1; fi
  [[ "$(_lc_turn "$pid")" == error ]] || return 1
  echo "$what"
}

_lc_capture() {
  if [[ -n "${LOGIN_CAPTURE_CMD:-}" ]]; then bash -c "$LOGIN_CAPTURE_CMD \"\$1\"" _ "$1"; return 0; fi
  ai_tmux capture-pane -p -t "$1" 2>/dev/null || true
}

# ok | error | "" for PID's last transcript answer (spl_lease_last_turn).
_lc_turn() {
  if [[ -n "${LOGIN_TURN_CMD:-}" ]]; then bash -c "$LOGIN_TURN_CMD \"\$1\"" _ "$1"; return 0; fi
  declare -F spl_lease_last_turn >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"
  spl_lease_last_turn "$1" || true
}

# This box's probe verdict line, fresh when EVERY s passed or a pane is stuck,
# else the cached one (<state>/probe: "<epoch> <verdict line>").
_lc_probe() {
  local every="$1" stuck="$2" now at line
  now="$(date +%s)"
  if [[ -z "$stuck" && "$every" -gt 0 && -r "$LC_STATE/probe" ]]; then
    read -r at line <"$LC_STATE/probe"
    if [[ "$at" =~ ^[0-9]+$ ]] && (( now - at < every )) && [[ -n "$line" ]]; then echo "$line"; return 0; fi
  fi
  line="$($LC_CRED probe 2>/dev/null | sed -n 1p)"
  [[ -n "$line" ]] || line="unknown no probe output"
  printf '%s %s\n' "$now" "$line" >"$LC_STATE/probe" 2>/dev/null || true
  echo "$line"
}

# One credential op on box DEST ("" = this box): stat | probe | get | put.
_lc_cred_at() {
  local dest="$1" op="$2" script
  if [[ -z "$dest" ]]; then $LC_CRED "$op"; return; fi
  if [[ -n "${LOGIN_PEER_CMD:-}" ]]; then bash -c "$LOGIN_PEER_CMD \"\$1\" \"\$2\"" _ "$dest" "$op"; return; fi
  script="$(cat "$PROJ_PATH/src/bash/scripts/agent-login-cred.sh")" || return 1
  ssh -o BatchMode=yes -o ConnectTimeout="${LOGIN_SSH_TIMEOUT:-30}" "$dest" "bash -c $(printf '%q' "$script") _ $op"
}

# The peers, "<tag>=<ssh dest>" separated by commas or blanks: LOGIN_PEERS,
# else box.env's SPOOL_LOGIN_PEERS (box-config.sh SPOOL_LOGIN_PEERS=sat=satellite).
_lc_peer_list() {
  if [[ -n "${LOGIN_PEERS+x}" ]]; then echo "${LOGIN_PEERS//,/ }"; return 0; fi
  sed -n 's/^SPOOL_LOGIN_PEERS=//p' "${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}" 2>/dev/null | tail -1 | tr -d "\"'" | tr ',' ' '
}

# Bring every peer's credential in line with the newest one that works.
# VAR names the caller's verdict, refreshed when this box's credential changed.
_lc_peers() {
  local -n _v="$1"
  local p tag dest
  for p in $(_lc_peer_list); do
    tag="${p%%=*}"; dest="${p#*=}"
    [[ "$tag" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && -n "$dest" && "$dest" != "$p" ]] || { LC_NOTE+=("peer '$p' is no <tag>=<dest>"); continue; }
    _lc_peer_one "$tag" "$dest" "$1" || true
  done
}

# Push this box's credential to peer TAG when their sha prefixes differ and
# this one works (g-839 / owner 09e6331e: the box that names peers is the one
# refresher). A peer whose credential is NEWER, or differs with the same
# expiry, is reported (LC_WARN), never overwritten and never pulled.
_lc_peer_one() {
  local tag="$1" dest="$2" vname="$3" ls ps lsha lexp psha pexp got
  local -n _pv="$vname"
  ls="$(_lc_cred_at "" stat 2>/dev/null)"; ps="$(_lc_cred_at "$dest" stat 2>/dev/null)"
  read -r lsha lexp _ <<<"$ls"; read -r psha pexp _ <<<"$ps"
  if [[ ! "$lsha" =~ ^[0-9a-f]{12}$ || ! "$psha" =~ ^[0-9a-f]{12}$ ]]; then
    LC_WARN+=("peer $tag: no credential to compare (here ${lsha:-none}, there ${psha:-unreachable})"); LC_WKEY+=" peer-nocred:$tag"; return 1
  fi
  [[ "$lsha" == "$psha" ]] && return 0
  if (( pexp > lexp )); then LC_WARN+=("peer $tag holds a NEWER credential ($psha there, $lsha here): reported, not overwritten"); return 1; fi
  if (( pexp == lexp )); then LC_WARN+=("peer $tag: credentials differ ($lsha here, $psha there) with the same expiry: not copied"); return 1; fi
  if [[ "${_pv%% *}" != ok ]]; then LC_WARN+=("peer $tag: this box's newer credential does not work (${_pv%% *}): not pushed"); return 1; fi
  if [[ "$LC_DRY" == 1 ]]; then LC_NOTE+=("PLAN push the credential here -> $tag ($lsha here, $psha there)"); return 0; fi
  got="$(_lc_cred_at "" get | _lc_cred_at "$dest" put 2>/dev/null | tail -n 1)"
  if [[ "$got" == "$lsha" ]]; then
    LC_COPIED=$((LC_COPIED + 1)); LC_NOTE+=("pushed the credential here -> $tag (now $got there; was $psha)")
  else
    LC_FAILED=$((LC_FAILED + 1)); LC_NOTE+=("FAILED to push the credential here -> $tag")
  fi
}

# This box's credential, spec 132 section 3: a sample line in <state>/cred.log
# when it changed since the last one ("<UTC> <sha12> <expiresAt ms>
# peers=<n>", the proof's input; DRY_RUN=0 only), and the early warning when it
# expires in under LOGIN_EXPIRY_WARN_MIN minutes: a renewal moves expiresAt
# about 8 h on, so a credential that close to its end was not renewed (the
# refresher is silent). The warning keys on the sha: one alert per credential.
_lc_expiry() {
  local warn="${LOGIN_EXPIRY_WARN_MIN:-60}" now sha exp peers line last left
  [[ "$warn" =~ ^[0-9]+$ ]] || warn=60
  now="${LOGIN_NOW:-$(date +%s)}"
  read -r sha exp _ <<<"$($LC_CRED stat 2>/dev/null | sed -n 1p)"
  [[ "$sha" =~ ^[0-9a-f]{12}$ && "$exp" =~ ^[0-9]+$ ]] || return 0
  if [[ "$LC_DRY" == 0 ]]; then
    peers="$(_lc_peer_list | wc -w)"
    line="$sha $exp peers=$peers"
    last="$(tail -n 1 "$LC_STATE/cred.log" 2>/dev/null | cut -d' ' -f2-)"
    [[ "$line" == "$last" ]] || printf '%s %s\n' "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LC_STATE/cred.log" 2>/dev/null || true
  fi
  (( warn > 0 && exp > 0 && exp / 1000 - now < warn * 60 )) || return 0
  left=$(( (exp / 1000 - now) / 60 ))
  LC_WARN+=("early warning: this box's credential $sha expires in $left min and was not renewed (refresher silent?): a person runs the vendor's login on this box (claude /login)")
  LC_WKEY+=" expiry:$sha"
  echo "WARN login-check@${LC_TAG:-box}: credential $sha expires in $left min, not renewed"
}

# Stop the stuck agents and restore them, only while this box's login works.
_lc_repair() {
  local verdict="$1" stuck="$2" wait="$3" id pid pane what why
  if [[ "${verdict%% *}" != ok ]]; then
    LC_NOTE+=("$(wc -l <<<"$stuck") stuck agent(s) left as they are: this box's login is ${verdict%% *} (a restart would come back dead)")
    return 0
  fi
  # One seat at a time, each at most once per tick: never stop a seat this run
  # cannot restore, nor one that is no longer stuck (c-002 ece2ab8a: a pass
  # that stopped all, then restored all, left two seats stopped).
  while read -r id pid pane what; do
    if why="$(_lc_cooling "$id" "$pid")"; then LC_NOTE+=("$id left alone: $why"); continue; fi
    if ! why="$(_lc_restorable "$id")"; then LC_WARN+=("$id is stuck ($what) but cannot be restored: $why; not stopped"); continue; fi
    if [[ "$LC_DRY" == 1 ]]; then LC_NOTE+=("PLAN stop $id (pane $pane, pid $pid, $what) and restore it"); continue; fi
    # the pane re-read right before the stop: still on the banner = stop and
    # restore; its claude gone and a bare shell left = restore, nothing to
    # stop; anything else recovered = left alone
    if ! _lc_stuck_now "$pid" "$pane" >/dev/null; then
      if _lc_bare "$pid" "$pane"; then
        LC_NOTE+=("$id: its claude exited, pane $pane is a bare shell; restored without a stop")
        _lc_restore "$id"; date +%s >"$LC_STATE/restored.$id" 2>/dev/null || true
      else LC_NOTE+=("$id recovered before the stop; left alone"); fi
      continue
    fi
    if _lc_stop "$id" "$pid" "$pane" "$wait"; then
      LC_STOPPED=$((LC_STOPPED + 1))
      _lc_restore "$id"
      date +%s >"$LC_STATE/restored.$id" 2>/dev/null || true
    else
      LC_FAILED=$((LC_FAILED + 1)); LC_NOTE+=("FAILED to stop $id (pid $pid)")
    fi
  done <<<"$stuck"
}

# 0 when PID is gone and PANE runs only a shell (the adapter's fallback).
_lc_bare() {
  local pid="$1" pane="$2" cmd
  if [[ -n "${LOGIN_GONE_CMD:-}" ]]; then bash -c "$LOGIN_GONE_CMD \"\$1\"" _ "$pid" || return 1
  else [[ ! -d "/proc/$pid" ]] || return 1; fi
  if [[ -n "${LOGIN_PANECMD_CMD:-}" ]]; then cmd="$(bash -c "$LOGIN_PANECMD_CMD \"\$1\"" _ "$pane")"
  else cmd="$(ai_tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"; fi
  [[ "$cmd" =~ ^-?(bash|sh|zsh|dash)$ ]]
}

# Why ID is left alone this tick, when it is: this action restored it, or its
# claude started, less than the cool-down ago - a resumed session still shows
# the old banner and error until it answers its kick.
_lc_cooling() {
  local id="$1" pid="$2" cool="$LC_COOL" at age
  at="$(cat "$LC_STATE/restored.$id" 2>/dev/null)"
  if [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < cool )); then echo "restored by this check $(( $(date +%s) - at ))s ago"; return 0; fi
  age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [[ "$age" =~ ^[0-9]+$ ]] && (( age < cool )); then echo "its claude started ${age}s ago"; return 0; fi
  return 1
}

# 0 when the restore can bring ID back: its record names a session and a
# worktree that exists, an adapter for its kind exists, and (claude) the
# transcript is in the agent user's home. Else prints why, non-zero.
_lc_restorable() {
  local id="$1" sid wt kind home slug own
  sid="$(ai_field "$id" session_id)"; wt="$(ai_field "$id" worktree)"; kind="$(ai_field "$id" kind)"
  kind="${kind:-claude}"
  [[ -n "$sid" ]] || { echo "its session is unknown"; return 1; }
  [[ -n "$wt" && -d "$wt" ]] || { echo "its worktree ${wt:-?} is gone"; return 1; }
  [[ -r "${IDENTITY_RESTORE_ADAPTER_DIR:-$PROJ_PATH/src/bash/features/spawn-agents/scripts}/restore-$kind.sh" ]] || { echo "no restore adapter for $kind"; return 1; }
  [[ "$kind" == claude ]] || return 0
  home="${LOGIN_AGENT_HOME:-$(getent passwd "${SPOOL_AGENT_USER:-$(id -un)}" | cut -d: -f6)}"
  slug="$(sed 's/[^A-Za-z0-9]/-/g' <<<"$wt")"
  own="$(stat -c %U "$home" 2>/dev/null)"
  if [[ -z "$own" || "$own" == "$(id -un)" ]]; then test -f "$home/.claude/projects/$slug/$sid.jsonl"
  else sudo -n -u "$own" test -f "$home/.claude/projects/$slug/$sid.jsonl"; fi || { echo "its transcript $sid is not in the agent user's home"; return 1; }
}

# Stop ONE agent: its pane first (the restore-claude.sh wrapper in it would
# relaunch claude in place, restore-core's kick fallback, so the restore then
# SKIPs "already running"; g-839), then its own claude pid, TERM and KILL
# after WAIT s. Never a pattern. The pid must still be that agent
# (ai_alive_fast) unless the tests stub the kill.
_lc_stop() {
  local id="$1" pid="$2" pane="$3" wait="$4" i
  if [[ -n "${LOGIN_KILL_CMD:-}" ]]; then
    bash -c "$LOGIN_KILL_CMD pane \"\$1\"; $LOGIN_KILL_CMD TERM \"\$2\"" _ "$pane" "$pid"; return
  fi
  [[ "$(ai_alive_fast "$id")" == "$pid" ]] || { LC_NOTE+=("$id: pid $pid is no longer that agent"); return 1; }
  ai_tmux kill-pane -t "$pane" 2>/dev/null || LC_NOTE+=("$id: pane $pane was already gone")
  _lc_kill TERM "$pid" || return 1
  for ((i = 0; i < wait; i++)); do [[ -d "/proc/$pid" ]] || return 0; sleep 1; done
  _lc_kill KILL "$pid"; sleep 1; [[ ! -d "/proc/$pid" ]]
}

_lc_kill() {  # SIG PID - as the pid's owner when that is another user
  local own; own="$(stat -c %U "/proc/$2" 2>/dev/null)" || return 0
  if [[ "$own" == "$(id -un)" ]]; then kill "-$1" "$2"; else sudo -n -u "$own" kill "-$1" "$2"; fi
}

_lc_restore() {
  local ids="$1" out rc
  if [[ -n "${LOGIN_RESTORE_CMD:-}" ]]; then out="$(IDENTITY_RESTORE_IDS="$ids" DRY_RUN=0 bash -c "$LOGIN_RESTORE_CMD" 2>&1)"; rc=$?
  else out="$(IDENTITY_RESTORE_IDS="$ids" DRY_RUN=0 IDENTITY_RESTORE_PAUSE="${LOGIN_RESTORE_PAUSE:-3}" do_spl_agent_identity_restore 2>&1)"; rc=$?; fi
  printf '%s\n' "$out" | sed 's/^/  restore: /'
  LC_RESTORED=$((LC_RESTORED + $(grep -c '^STARTED ' <<<"$out")))
  (( rc == 0 )) || { LC_FAILED=$((LC_FAILED + 1)); LC_NOTE+=("the restore of $ids exited $rc"); }
  return 0
}

# One message to the dispatch lease holder when the tick acted, or when a
# problem (a stuck pane, a login that is not ok) first shows or changes.
# Returns 0 when it sent.
_lc_alert() {
  local v0="$1" v1="$2" s0="$3" s1="$4" sig last="" body to acted=$((LC_COPIED + LC_STOPPED + LC_FAILED))
  sig="${v1%% *} $(_lc_n login "$s1") $(_lc_n limit "$s1") ${#LC_WARN[@]}${LC_WKEY}"
  [[ -r "$LC_STATE/alert" ]] && last="$(cat "$LC_STATE/alert")"
  if (( acted == 0 )); then
    [[ "${v1%% *}" == unknown ]] && return 1
    [[ "$sig" == "ok 0 0 0" || "$sig" == "$last" ]] && { [[ "$sig" == "ok 0 0 0" && "$LC_DRY" == 0 ]] && printf '%s' "$sig" >"$LC_STATE/alert"; return 1; }
  fi
  to="$(_lc_alert_to)"
  body="$(_lc_alert_body "$v0" "$v1" "$s0" "$s1")"
  if [[ "$LC_DRY" == 1 ]]; then echo "PLAN alert to $to:"; printf '%s\n' "$body" | sed 's/^/  /'; return 1; fi
  printf '%s' "$sig" >"$LC_STATE/alert" 2>/dev/null || true
  local send="${LOGIN_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="$SPOOL_ROOT" SPOOL_ASKS=0 bash "$send" --from "$(_lc_alert_from)" --to "$to" --kind note \
    --task "${LOGIN_ALERT_TASK:-dispatch-sat-login}" --no-ask --body "$body" >/dev/null 2>&1 ||
    { do_log "WARN the alert to $to was not sent"; return 1; }
  echo "ALERT sent to $to"
}

_lc_alert_body() {
  local v0="$1" v1="$2" s0="$3" s1="$4" n sha
  sha="$($LC_CRED stat 2>/dev/null | cut -d' ' -f1)"
  printf '**login-check@%s**: claude login %s -> %s; stuck panes before: %s login, %s limit; after: %s login, %s limit; copied %s, stopped %s, restored %s, failed %s; credential sha %s.\n' \
    "${LC_TAG:-box}" "${v0%% *}" "${v1%% *}" "$(_lc_n login "$s0")" "$(_lc_n limit "$s0")" "$(_lc_n login "$s1")" "$(_lc_n limit "$s1")" \
    "$LC_COPIED" "$LC_STOPPED" "$LC_RESTORED" "$LC_FAILED" "${sha:-?}"
  [[ -n "$s0" ]] && printf -- '- stuck: %s\n' "$(awk '{printf "%s%s (%s)", (NR>1?", ":""), $1, $4}' <<<"$s0")"
  for n in "${LC_NOTE[@]}" "${LC_WARN[@]}"; do printf -- '- %s\n' "$n"; done
  [[ "${v1%% *}" == ok ]] || printf -- '- probe: %s\n' "${v1#* }"
}

# The dispatch lease holder ("<ID>@<box> <epoch>"); bare when on this box.
_lc_alert_to() {
  [[ -n "${LOGIN_ALERT_TO:-}" ]] && { echo "$LOGIN_ALERT_TO"; return 0; }
  local h=""
  read -r h _ <"$SPOOL_ROOT/dispatch/lease" 2>/dev/null || true
  [[ "$h" =~ ^${SPOOL_AGENT_ID_RX}(@[a-z0-9][a-z0-9-]*)?$ ]] || { echo orchestrator; return 0; }
  [[ "${h#*@}" == "$LC_TAG" ]] && h="${h%@*}"
  echo "$h"
}

_lc_alert_from() {
  local o
  o="$(sed -n 's/^LEASE_ORCH=//p' "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null | tail -1)"
  [[ "$o" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || o=c-001
  echo "${LOGIN_FROM:-$o}"
}
