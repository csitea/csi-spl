#!/usr/bin/env bash
# sessions-boot.sh — bring the box's tmux workspace back after a reboot, from
# the state save-sessions.sh keeps (spec 069 C2, the csi-spl copy of the
# engine's claude-sessions-boot). Runs @reboot from the box user's crontab, as
# the tmux owner. Every step is logged; the verdict is a file, because cron
# throws an @reboot job's exit code away.
#
#   0. the tmux socket dir: tmux does not create it for an explicit -S, prints
#      "error creating <socket>" and still exits 0, and /tmp is empty at boot.
#      Created 0700, owned by this user; waited for up to BOX_SESSIONS_SOCKET_WAIT.
#   1. the landing session BOX_SESSIONS_LANDING (default main), when no server
#      runs, with a placeholder window that goes once anything else is there.
#   2. every saved `shell` window that is not there, by session + name, in its
#      cwd ($HOME when that is gone). Nothing is typed into it.
#   3. the agent seats: BOX_SESSIONS_AGENT_RESTORE_CMD, default
#      do_spl_agent_boot_restore DRY_RUN=0 from this orc checkout (the identity
#      map: each agent's own session, worktree and user). Empty = skipped.
#   4. VERIFY: every saved shell window and every saved `agent` seat (by its id
#      in a window name) is present, re-checked for BOX_SESSIONS_VERIFY_SEC.
#      `exited` rows are not expected back.
# Exit 0 only when 4 passes; else non-zero and <state dir>/boot-FAILED naming
# what is missing. A run that passes removes the marker.
#
# Settings (env): BOX_SESSIONS_DIR, BOX_SESSIONS_TMUX_SOCKET (as save-sessions.sh),
#   BOX_SESSIONS_LANDING (main), BOX_SESSIONS_SOCKET_WAIT (30), BOX_SESSIONS_LOCK_WAIT (60),
#   BOX_SESSIONS_VERIFY_SEC (60), BOX_SESSIONS_AGENT_RESTORE_CMD.
#
# Usage: sessions-boot.sh [--foreground] [--state <state.tsv>]
#   --foreground  log to stdout, not <state dir>/boot.log
#   --state       restore this snapshot (e.g. one under archive/) instead of state.tsv
set -uo pipefail

BS_SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BS_ORC="$(cd "$BS_SELF/../../../../.." && pwd)"
# shellcheck source=../../spawn-agents/lib/spool-env.inc.sh
. "$BS_SELF/../../spawn-agents/lib/spool-env.inc.sh" || exit 2

bs_org_app="$(basename "$BS_ORC")"; bs_org_app="${bs_org_app%-orc}"
BS_DIR="${BOX_SESSIONS_DIR:-/var/${bs_org_app%%-*}/$bs_org_app/box-sessions}"
BS_SOCK="${BOX_SESSIONS_TMUX_SOCKET:-${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}}"
BS_LANDING="${BOX_SESSIONS_LANDING:-main}"
BS_PLACEHOLDER="box-sessions-placeholder"
BS_SOCKET_WAIT="${BOX_SESSIONS_SOCKET_WAIT:-30}"
BS_LOCK_WAIT="${BOX_SESSIONS_LOCK_WAIT:-60}"
BS_VERIFY_SEC="${BOX_SESSIONS_VERIFY_SEC:-60}"
if [[ -v BOX_SESSIONS_AGENT_RESTORE_CMD ]]; then BS_AGENT_CMD="$BOX_SESSIONS_AGENT_RESTORE_CMD"
else BS_AGENT_CMD="cd $(printf '%q' "$BS_ORC") && DRY_RUN=0 ./run -a do_spl_agent_boot_restore"; fi
BS_STATE="$BS_DIR/state.tsv"
BS_MARKER="$BS_DIR/boot-FAILED"
TAG="box-sessions boot"

FG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --foreground) FG=1 ;;
    --state) BS_STATE="${2:?sessions-boot: --state needs a file}"; shift ;;
    *) echo "sessions-boot: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
for v in BS_SOCKET_WAIT BS_LOCK_WAIT BS_VERIFY_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "sessions-boot: $v must be seconds, got '${!v}'" >&2; exit 2; }
done

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
# 9>&-: a server this starts must not inherit the lock fd and hold it forever.
btmux() { tmux -u -S "$BS_SOCK" "$@" 9>&-; }

mkdir -p "$BS_DIR" 2>/dev/null || { echo "$TAG: cannot create $BS_DIR" >&2; exit 1; }
[ "$FG" = 1 ] || exec >> "$BS_DIR/boot.log" 2>&1
log "=== $TAG starting as $(id -un), socket $BS_SOCK, state $BS_STATE ==="
FAIL=""

# ── 0. the socket dir ───────────────────────────────────────────────────────
sock_dir="${BS_SOCK%/*}"
deadline=$((SECONDS + BS_SOCKET_WAIT))
while :; do
  mkdir -p "$sock_dir" 2>/dev/null
  [ -O "$sock_dir" ] && [ "$(stat -c %a "$sock_dir" 2>/dev/null)" != 700 ] && chmod 0700 "$sock_dir" 2>/dev/null
  [ -O "$sock_dir" ] && [ "$(stat -c %a "$sock_dir" 2>/dev/null)" = 700 ] && break
  [ "$SECONDS" -lt "$deadline" ] || { FAIL="tmux socket dir $sock_dir is not this user's with mode 0700"; break; }
  sleep 1
done
[ -z "$FAIL" ] && log "tmux socket dir $sock_dir ready"

exec 9>>"$BS_DIR/.lock" || { log "ERROR cannot open $BS_DIR/.lock"; exit 1; }
flock -w "$BS_LOCK_WAIT" 9 || log "WARN the lock stayed held for ${BS_LOCK_WAIT}s - going on without it"

# ── 1. the landing session ──────────────────────────────────────────────────
if [ -z "$FAIL" ] && ! btmux has-session 2>/dev/null; then
  btmux new-session -d -s "$BS_LANDING" -n "$BS_PLACEHOLDER" -c "$HOME" 2>/dev/null
  if btmux has-session -t "=$BS_LANDING" 2>/dev/null; then log "created landing session '$BS_LANDING'"
  else FAIL="no tmux server and the landing session '$BS_LANDING' could not be created"; fi
fi

# ── 2. the shell windows ────────────────────────────────────────────────────
win_present() { btmux list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | grep -qxF -- "$2"; }
declare -a WANT_WIN=() WANT_ID=()
shells=0; made=0
if [ ! -r "$BS_STATE" ]; then
  log "WARN no saved state at $BS_STATE - only the agent seats come back"
elif [ -z "$FAIL" ]; then
  while IFS=$'\t' read -r s _i nm c _a kind id; do
    case "$s" in ""|"#"*) continue ;; esac
    case "$kind" in
      agent) WANT_ID+=("$id"); continue ;;
      shell) ;;
      *) continue ;;
    esac
    shells=$((shells + 1)); WANT_WIN+=("$s"$'\t'"$nm")
    win_present "$s" "$nm" && continue
    [ -d "$c" ] || c="$HOME"
    if btmux has-session -t "=$s" 2>/dev/null; then btmux new-window -d -t "=$s:" -n "$nm" -c "$c" 2>/dev/null
    else btmux new-session -d -s "$s" -n "$nm" -c "$c" 2>/dev/null; fi
    if win_present "$s" "$nm"; then made=$((made + 1)); log "window $s:$nm in $c"
    else log "WARN window $s:$nm could not be created"; fi
  done < "$BS_STATE"
  log "shell windows: $shells saved, $made created, $((shells - made)) already there or failed"
fi

# The save may now trust this server: no grace wait on it.
srv="$(btmux display -p '#{pid} #{start_time}' 2>/dev/null)"
[ -n "$srv" ] && touch "$BS_DIR/.restored.${srv%% *}.${srv##* }"

# ── 3. the agent seats ──────────────────────────────────────────────────────
if [ -z "$FAIL" ] && [ -n "$BS_AGENT_CMD" ]; then
  log "agent seats (${#WANT_ID[@]} saved): $BS_AGENT_CMD"
  SPOOL_TMUX_SOCKET="$BS_SOCK" bash -c "$BS_AGENT_CMD" 9>&- 2>&1 | grep -vE '\[(DEBUG|INFO)\]' | sed 's/^/  agents: /'
  arv="${PIPESTATUS[0]}"
  [ "$arv" = 0 ] || log "WARN the agent restore exited rv=$arv"
elif [ -z "$BS_AGENT_CMD" ]; then
  log "agent seats skipped: BOX_SESSIONS_AGENT_RESTORE_CMD is empty"
fi

# The placeholder goes once its session holds anything else.
if [ "$(btmux list-windows -t "=$BS_LANDING" -F '#{window_name}' 2>/dev/null | grep -cvxF "$BS_PLACEHOLDER")" -gt 0 ]; then
  btmux kill-window -t "=$BS_LANDING:$BS_PLACEHOLDER" 2>/dev/null
fi

# ── 4. verify ───────────────────────────────────────────────────────────────
missing=""
if [ -z "$FAIL" ]; then
  vdead=$((SECONDS + BS_VERIFY_SEC))
  while :; do
    missing=""
    live_ids=" "
    while IFS= read -r nm; do
      spool_id_of_window_var lid "$nm"; [ -n "$lid" ] && live_ids="$live_ids$lid "
    done < <(btmux list-windows -a -F '#{window_name}' 2>/dev/null)
    for w in "${WANT_WIN[@]}"; do win_present "${w%%$'\t'*}" "${w#*$'\t'}" || missing="$missing window ${w%%$'\t'*}:${w#*$'\t'};"; done
    for id in "${WANT_ID[@]}"; do [[ "$live_ids" == *" $id "* ]] || missing="$missing seat $id;"; done
    [ -z "$missing" ] || [ "$SECONDS" -ge "$vdead" ] && break
    sleep 5
  done
  btmux has-session -t "=$BS_LANDING" 2>/dev/null || btmux has-session 2>/dev/null || missing="$missing the tmux server;"
  [ -n "$missing" ] && FAIL="not back after ${BS_VERIFY_SEC}s:$missing"
fi

if [ -n "$FAIL" ]; then
  printf '[%s] %s FAILED: %s\n  socket %s\n  state  %s\n  log    %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$TAG" "$FAIL" "$BS_SOCK" "$BS_STATE" "$BS_DIR/boot.log" > "$BS_MARKER" 2>/dev/null
  log "!!! $TAG FAILED: $FAIL - marker $BS_MARKER"
  log "=== $TAG done (rv=1) ==="
  exit 1
fi
rm -f "$BS_MARKER"
log "verify: ${#WANT_WIN[@]} shell windows and ${#WANT_ID[@]} agent seats present"
log "=== $TAG done (rv=0) ==="
