#!/bin/bash
#------------------------------------------------------------------------------
# @description Move ALL the work of one channel to another box in one action
# @description (spec 167). Row B1 builds the read-only `plan` and the caller
# @description check (D1): the owner or the orch lease holder only, decided
# @description from the caller's process ancestry and tmux pane, never from
# @description its environment; DRY_RUN=0 by the owner also needs an
# @description owner-signed directive over the command's own text (C22, C24).
# @description The plan prints every manifest line (derived + declared) with
# @description its size and time at the uplink, secrets by kind only, and the
# @description target checks; it moves, copies, stops or seats nothing. The
# @description other commands (move, status, resume, back, clean, ack) run the
# @description hook cm_cmd_<command> when a later row defines it, else exit 4.
# @param CHANNEL (required) - <tenant>/<channel>
# @param TO (required for plan) - the box the channel moves to
# @param MOVE_CMD (optional) - plan (default), move, status, resume, back, clean, ack
# @param DRY_RUN (optional) - default 1; a changing command without DRY_RUN=0 prints the plan
# @param MOVE_ID (optional) - the move (resume, back, clean, ack, status)
# @param SEAT (optional) - the new seat's id, for MOVE_CMD=ack
# @param MOVE_UPLINK_KBPS (optional) - the uplink in kB/s; default a 1 MB probe over ssh, else 75 assumed
# @param MOVE_SSH (optional) - the ssh command prefix to the target, default ssh -o BatchMode=yes
# @example CHANNEL=t1/general TO=box-b ./run -a do_spl_channel_move
# @example MOVE_CMD=ack MOVE_ID=20261105T120000Z-1a2b3c SEAT=c-123 ./run -a do_spl_channel_move
#------------------------------------------------------------------------------

# Outside SPOOL_TEST the action runs in a fresh process (c-715 W4, W5): bash
# imports every function the caller exports, named after a tool (awk, tmux,
# sudo) or a builtin ([, builtin, local, return, exec), so no check in the
# caller's shell may run a command before this one. The entry and the fresh
# script's top use only [[ ]], assignments, $(<) and commands named by an
# absolute path (a name with a / cannot be imported). cm_has_exported_func:
# 0 when this process started with an exported function (its environ holds a
# BASH_FUNC_ entry); defined here, so a caller's function by the same name is
# overwritten when this file is sourced.
cm_has_exported_func() {
  { CM_ENVIRON="$(< "/proc/$$/environ")"; } 2>/dev/null
  [[ "${CM_ENVIRON:-}" == *BASH_FUNC_* ]]
}

# Refuse (3) from a process the caller cannot shadow.
cm_refuse_exported_func() {
  /bin/sh -c 'echo "channel-move REFUSED: the caller exports a function (an environment BASH_FUNC_ entry); D1 trusts no exported function. Nothing was read." >&2; exit 3'
}

# Run this file under env -i with an allow-list only: the fixed PATH (the lib's
# CM_SAFE_PATH; the test holds the two equal), HOME, USER, LOGNAME, LANG, TERM,
# SUDO_USER (cm_owner_process reads it) and the action's parameters.
cm_fresh_run() {
  CM_SELF="${BASH_SOURCE[0]}"
  [[ "$CM_SELF" == /* ]] || CM_SELF="$PWD/$CM_SELF"
  /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME="${HOME:-/nonexistent}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" \
    SUDO_USER="${SUDO_USER:-}" CHANNEL="${CHANNEL:-}" TO="${TO:-}" MOVE_CMD="${MOVE_CMD:-}" DRY_RUN="${DRY_RUN:-}" \
    MOVE_ID="${MOVE_ID:-}" SEAT="${SEAT:-}" MOVE_UPLINK_KBPS="${MOVE_UPLINK_KBPS:-}" MOVE_SSH="${MOVE_SSH:-}" \
    /bin/bash --noprofile --norc "$CM_SELF"
}

cm_action_load() {
  local sa
  sa="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents"
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  declare -F spool_env_resolve >/dev/null || . "$sa/lib/spool-env.inc.sh" || return 1
  # shellcheck source=../features/spawn-agents/lib/channel-move.inc.sh
  declare -F cm_caller_check >/dev/null || . "$sa/lib/channel-move.inc.sh" || return 1
  # shellcheck source=../../../lib/bash/funcs/spl-box-state-mounts.func.sh
  declare -F spl_box_state_upload_scan >/dev/null || . "$sa/../../../../lib/bash/funcs/spl-box-state-mounts.func.sh" || return 1
  SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null || return 1
}

do_spl_channel_move() {
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then cm_main
  elif cm_has_exported_func; then cm_refuse_exported_func
  else cm_fresh_run
  fi
}

cm_main() {
  local cmd="${MOVE_CMD:-plan}" peer="" rc
  case "$cmd" in plan|move|status|resume|back|clean|ack) ;;
    *) echo "channel-move: MOVE_CMD must be plan, move, status, resume, back, clean or ack, got '$cmd'" >&2; return 2 ;;
  esac
  cm_action_load || { echo "channel-move: cannot load the spool env" >&2; return 1; }
  if [[ " move resume back clean " == *" $cmd "* && "${DRY_RUN:-1}" != 0 ]]; then
    echo "channel-move: dry run (DRY_RUN=0 runs MOVE_CMD=$cmd); the plan:"
    cmd=plan
  fi
  if [ "$cmd" != plan ] && ! declare -F "cm_cmd_$cmd" >/dev/null; then
    echo "channel-move: MOVE_CMD=$cmd is not built yet (spec 167 rows B4, B5); nothing was done" >&2
    return 4
  fi
  cm_caller_check "$cmd" || return 3
  [ "$cmd" = plan ] && { cm_plan; return $?; }
  if [ "$CM_CALLER" = owner ] && [[ " move resume back clean " == *" $cmd "* ]]; then
    [ "$cmd" = move ] && MOVE_ID="${MOVE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')}"
    [ -n "${MOVE_ID:-}" ] || { echo "channel-move: MOVE_ID is required for MOVE_CMD=$cmd" >&2; return 2; }
    cm_ssh "${TO:-}" true >/dev/null 2>&1 </dev/null || peer="${TO:-}"
    cm_owner_directive "$cmd" "$MOVE_ID" "$peer" || return 3
  fi
  "cm_cmd_$cmd"; rc=$?
  [ -n "${CM_ENVELOPES:-}" ] && rm -rf "$CM_ENVELOPES"
  return "$rc"
}

# ---- plan (S0): read only --------------------------------------------------

# One printed manifest line: "<kind> <what> <size> <time>", a secret by kind
# only. Adds to CM_TOTAL / CM_SECRETS / CM_BLOCKED and to CM_SECRET_PATHS and
# CM_REPOS (for the target checks).
cm_plan_line() {  # KBPS KIND PATH [EXTRA...]
  local k="$1" kind="$2" p="${3:-}" b mode; shift 3
  if [[ " $CM_KINDS_DECLARED " == *" $kind "* ]] && [ "$kind" != marker ] && [ "$kind" != tests-not-run ] && ! cm_allowed_path "$p"; then
    CM_BLOCKED=$((CM_BLOCKED + 1)); echo "  REFUSED $kind: a path outside the allowed roots (spec 167 4.2)"; return 0
  fi
  if [ "$kind" = secret ] || { [[ " data config binary " == *" $kind "* ]] && cm_is_secret "$p"; }; then
    CM_SECRETS=$((CM_SECRETS + 1)); CM_SECRET_PATHS+=("$p")
    mode="$(stat -c %a "$p" 2>/dev/null || echo '?')"; b="$(cm_bytes "$p")"
    echo "  secret #$CM_SECRETS (a $kind line; path withheld), mode $mode, ${b:-0} B: never moved without the owner's GO (4.5)"
    return 0
  fi
  case "$kind" in
    seat)        echo "  seat $p: ball pass (handoff, seed, ack)" ;;
    repo)        cm_plan_repo "$k" "$p" "${1:--}" ;;
    uncommitted) b="$(cm_uncommitted_bytes "$p")"; CM_TOTAL=$((CM_TOTAL + b)); echo "  uncommitted $p: patch + untracked tar ~$b B, ~$(cm_eta "$b" "$k")" ;;
    data|config) b="$(cm_bytes "$p")"; CM_TOTAL=$((CM_TOTAL + ${b:-0}))
                 echo "  $kind $p: ${b:-missing} B, ~$(cm_eta "${b:-0}" "$k")$([ -e "$p" ] || echo ' (MISSING on this box)')" ;;
    binary)      b="$(cm_bytes "$p")"
                 if [ $# -gt 0 ]; then echo "  binary $p: rebuilt on the target: $*"
                 else CM_TOTAL=$((CM_TOTAL + ${b:-0})); echo "  binary $p: copied (no build command), ${b:-0} B, ~$(cm_eta "${b:-0}" "$k")"; fi ;;
    marker)      echo "  marker: 1 word (not moved; the cleanup report greps for it)" ;;
    tests-not-run) echo "  tests-not-run: $p $* (into the move block; the target seat runs it after its ack)" ;;
    scratch)     echo "  scratch $p: not moved, deleted by clean" ;;
    transcript)  echo "  transcript $p: not moved, deleted by clean (D3)" ;;
    spool)       echo "  spool $p: unread inbox travels in the handoff; retired with the id" ;;
    *)           CM_BLOCKED=$((CM_BLOCKED + 1)); echo "  REFUSED unknown kind '$kind'" ;;
  esac
}

# Bytes of a worktree's uncommitted work: the binary diff + the untracked files.
cm_uncommitted_bytes() {  # WORKTREE
  local d u
  d="$(git -C "$1" diff --binary HEAD 2>/dev/null | wc -c)"
  u="$(cd "$1" 2>/dev/null && git ls-files -oz --exclude-standard 2>/dev/null | xargs -0r du -cb 2>/dev/null | awk 'END { print $1 + 0 }')"
  echo $(( ${d:-0} + ${u:-0} ))
}

cm_plan_repo() {  # KBPS WORKTREE REMOTE
  local k="$1" wt="$2" base b shown
  base="$(cm_repo_base "$wt" "$3")"; shown="${base:0:12}"; [ -n "$base" ] || shown="none (a full bundle)"
  b="$(cm_repo_bytes "$wt" "$base")"; CM_TOTAL=$((CM_TOTAL + ${b:-0}))
  [ -n "$base" ] && CM_REPOS+=("$base:$wt")
  echo "  repo $wt ($3): branch $(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) on base $shown, bundle ~${b:-0} B, ~$(cm_eta "${b:-0}" "$k")"
}

# The target checks (S0), read only, over ssh; without ssh, which box drives.
cm_plan_target() {  # TO REACHABLE
  local to="$1" out line n
  if [ "$2" != yes ]; then
    echo "  no ssh path to $to: base, desk and ceiling NOT checked; a secret cannot move from this box (4.5), $to must drive it"
    return 0
  fi
  out="$(cm_target_script "$CM_TENANT" "${CM_REPOS[@]}" | cm_ssh "$to" bash -s 2>/dev/null)"
  while read -r line; do
    case "$line" in
      "desk no")  echo "  desk in $CM_TENANT on $to: no (S6 seats one before the switch)" ;;
      "desk yes") echo "  desk in $CM_TENANT on $to: yes" ;;
      agents\ *)  n="${line#agents }"; echo "  agent windows on $to: $n of 40"
                  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 40 ] && { CM_BLOCKED=$((CM_BLOCKED + 1)); echo "  REFUSED: $to is at the 40-agent ceiling (R4)"; } ;;
      base\ *)    echo "  target has base ${line:5:12}: ${line##* }$([ "${line##* }" = no ] && echo ' (the target clones from the remote, else a full bundle)')" ;;
    esac
  done <<<"$out"
  echo "  vendor usage limit on $to: not checked by plan (S6 places on the backup vendor)"
}

# Whether each secret's copy on the target is the same (sha256 yes/no).
# The path travels in the script on stdin, never on the ssh command line (N2).
cm_plan_secrets() {  # TO REACHABLE
  local i=0 p mine theirs need=0
  [ "$CM_SECRETS" -gt 0 ] || { echo "  secrets: none found (the scan sees only declared paths)"; return 0; }
  for p in "${CM_SECRET_PATHS[@]}"; do
    i=$((i + 1)); mine="$(sha256sum <"$p" 2>/dev/null | cut -c1-64)"
    if [ "$2" = yes ]; then theirs="$(printf 'sha256sum <%q 2>/dev/null | cut -c1-64\n' "$p" | cm_ssh "$1" bash -s 2>/dev/null)"
      if [ -n "$theirs" ] && [ "$theirs" = "$mine" ]; then echo "  secret #$i same copy on $1: yes"
      else need=$((need + 1)); echo "  secret #$i same copy on $1: no"; fi
    else need=$((need + 1)); echo "  secret #$i same copy on $1: not checked (no ssh)"; fi
  done
  if [ "$need" = 0 ]; then echo "  owner GO: not needed (every secret already on $1)"
  else echo "  owner GO: needed for $need secret(s), asked once as a (GO) Go poll (4.5)"; fi
}

cm_plan() {
  local to="${TO:-}" reach=no kbps how line
  local -a f
  cm_parse_channel "${CHANNEL:-}" || return 2
  [[ "$to" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "channel-move: TO must be a box tag, got '$to'" >&2; return 2; }
  export GIT_OPTIONAL_LOCKS=0
  CM_TOTAL=0 CM_SECRETS=0 CM_BLOCKED=0 CM_SECRET_PATHS=() CM_REPOS=()
  cm_ssh "$to" true >/dev/null 2>&1 </dev/null && reach=yes
  read -r kbps how < <(cm_uplink "$to" "$reach")
  echo "channel-move plan $CM_TENANT/$CM_CHANNEL: $(cm_box) -> $to (read only: nothing is moved, copied, stopped or seated)"
  echo "caller: $CM_CALLER"
  echo "S0 manifest (derived lines, then declared; an undeclared path is not found):"
  while read -r line; do
    [ -n "$line" ] || continue
    read -r -a f <<<"$line"
    if [ "${#f[@]}" -lt 2 ]; then CM_BLOCKED=$((CM_BLOCKED + 1)); echo "  REFUSED a manifest line with fewer than 2 fields: '${f[0]:-}'"; continue; fi
    cm_plan_line "$kbps" "${f[@]}"
  done < <(cm_manifest "$CM_TENANT" "$CM_CHANNEL")
  echo "target $to (transport: $([ "$reach" = yes ] && echo ssh || echo 'the hub (B3)')):"
  cm_plan_target "$to" "$reach"
  echo "secrets:"
  cm_plan_secrets "$to" "$reach"
  echo "total to ship ~$CM_TOTAL B at $kbps kB/s ($how): ~$(cm_eta "$CM_TOTAL" "$kbps"); S6 spawn + S7 ack add minutes (4.3)"
  [ "$CM_BLOCKED" = 0 ] || { echo "plan: $CM_BLOCKED blocker(s) above"; return 5; }
  echo "plan: OK"
}

# The fresh process of cm_fresh_run: refuse an exported function again (a
# caller can run this file directly), then the action.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if cm_has_exported_func; then cm_refuse_exported_func
  else PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH; cm_main
  fi
fi
