#!/usr/bin/env bash
# tmux-close-window.sh — close a tmux window (immediate or deferred after agent exit).
# Ported from the frozen box engine (specs/048-agent-harness-parity); the
# server owner, socket, box tag and registry come from lib/spool-env.inc.sh.
#
# Used by /kill-your-self and /exit-clean (always --defer so the agent can /exit
# with status 0 first) and by /tmux-close-window (immediate human tidy-up).
#
# ---------------------------------------------------------------------------
# SAFETY INVARIANT — this helper NEVER guesses which window it owns.
# ---------------------------------------------------------------------------
# An earlier revision fell through to `tmux display-message -p '#{pane_id}'`
# (no -t), which resolves to whatever pane is CURRENTLY ACTIVE — i.e. the
# window the human happens to be looking at. Every invocation that crosses a
# `sudo` hop hit that fallback, because `Defaults env_reset` in /etc/sudoers
# strips TMUX_PANE / CLE_TMUX_PANE / MCP_BOT_AGENT_ID from the environment:
#
#   $ CLE_TMUX_PANE=%999 sudo -u <owner> bash -c 'echo ${CLE_TMUX_PANE:-<STRIPPED>}'
#   <STRIPPED>
#
# The result was a teardown helper that closed a DIFFERENT, still-running
# agent's window. The fallback is gone. If ownership cannot be PROVEN, the
# script exits non-zero and closes nothing.
#
# Ownership is proven by exactly one of (checked in this order):
#   1. --pane %N          explicit pane id, verified to exist on the server
#   2. --agent CLE-07     explicit agent id -> registry.tsv and/or window-name
#                         scan; the resolved window name MUST carry that id
#   3. <target> positional  explicit `session:index` / `%N` typed by a human
#   4. $TMUX_PANE         real tmux var; only ever set when genuinely inside
#                         that pane (never survives sudo, so never misleads)
#   5. $CLE_TMUX_PANE / $GRK_TMUX_PANE / $AGY_TMUX_PANE / $QWN_TMUX_PANE
#                         exported into the agent by its spawn launcher
#   6. $MCP_BOT_AGENT_ID  agent id in the environment -> same check as (2)
# ...and nothing else. No "active pane", no "current window".
#
# When an agent id is known AND the pane came from the environment, the two are
# cross-checked against the window name; a mismatch is a refusal, not a warning.
#
# IMPORTANT: tmux only accepts clients whose uid matches the server owner
# ($SPOOL_BOX_USER, from lib/spool-env.inc.sh). When invoked by another user
# (e.g. an agent running as $SPOOL_AGENT_USER) we transparently `sudo -u $BOX_USER`. Because THIS script self-elevates only
# its tmux calls, callers must invoke it WITHOUT an outer sudo, so that the
# pane/agent env vars above are still visible. Better still: pass --agent.
#
# Never SIGKILL agent binaries; --defer waits for claude|grok|agy|qwen to leave the
# pane, then kill-window.
#
# Usage:
#   tmux-close-window.sh --agent CLE-07 --defer     # the teardown path
#   tmux-close-window.sh --agent CLE-07             # close it now
#   tmux-close-window.sh --pane %123 --defer
#   tmux-close-window.sh main:5                     # explicit target, now
#   tmux-close-window.sh --agent CLE-07 --dry-run   # resolve + report, kill nothing
#   tmux-close-window.sh --help
#
# Exit codes:
#   0  closed (or deferred close scheduled, or --dry-run resolved)
#   1  tmux/kill failure
#   2  usage error
#   3  REFUSED: ownership could not be established — nothing was closed
#   4  REFUSED: resolved window does not belong to the named agent
set -uo pipefail

# The tmux server owner, its socket, the box tag and the spool root (which
# holds the spawn registry) come from the one resolver; explicit env vars win.
_sp_lib="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)/spool-env.inc.sh"
# shellcheck source=../lib/spool-env.inc.sh
. "$_sp_lib" || { echo "tmux-close-window: cannot load $_sp_lib" >&2; exit 2; }
SPOOL_ENV_NO_BINS=1 spool_env_resolve
BOX_USER="$SPOOL_BOX_USER" BOX_TMUX_SOCKET="$SPOOL_TMUX_SOCKET" BOX_TAG="${SPOOL_BOX_TAG:-}"
DEFER=0
DRY_RUN=0
TIMEOUT=180
TARGET_ARG=""
PANE_ARG=""
AGENT_ARG=""
HELP=0

usage() {
  cat <<'EOF'
Usage:
  tmux-close-window.sh --agent CLE-07 --defer   # teardown: close AFTER the agent exits
  tmux-close-window.sh --agent CLE-07           # close that agent's window now
  tmux-close-window.sh --pane %123 [--defer]    # close the window owning that pane
  tmux-close-window.sh main:5                   # close explicit target immediately
  tmux-close-window.sh --agent CLE-07 --dry-run # resolve and report, kill nothing
  tmux-close-window.sh --help

Options:
  --agent ID         Agent id (CLE-07 / GRK-2 / AGY-03 / QWN-01). Resolved via
                     $SPOOL_ROOT/registry.tsv and the tmux window names; the
                     resolved window MUST carry that id or the run is refused.
                     THIS IS THE ONLY FORM THAT SURVIVES A sudo HOP.
  --pane %N          Explicit tmux pane id. Verified to exist.
  --defer            Fork a background closer that waits for claude|grok|agy|qwen in
                     the resolved pane to exit (or --timeout), then kill-window.
                     Parent exits 0 immediately so the agent can /exit.
  --timeout SECONDS  Max wait in --defer mode (default: 180)
  --dry-run          Print the resolution and exit; never kills anything.
  --help             Show this help

Ownership sources (in order; there is NO "active window" fallback):
  --pane, --agent, positional target, $TMUX_PANE,
  $CLE_TMUX_PANE / $GRK_TMUX_PANE / $AGY_TMUX_PANE / $QWN_TMUX_PANE, $MCP_BOT_AGENT_ID
If none of them resolves, the script exits 3 and closes nothing.

Env:
  SPOOL_BOX_USER  tmux server owner (default: resolved by lib/spool-env.inc.sh)
  SPOOL_ROOT      the spool root holding registry.tsv (default: /var/spool-hub)
  CLOSE_LOG_DIR  where --defer writes its log (default: /tmp)
  TMUX / CLE_TMUX_SOCK / GRK_TMUX_SOCK  socket; else /tmp/tmux-<box-uid>/default
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --defer) DEFER=1; shift ;;
    --dry-run|--dry) DRY_RUN=1; shift ;;
    --agent)
      AGENT_ARG="${2:?tmux-close-window: --agent requires an agent id}"
      shift 2
      ;;
    --agent=*) AGENT_ARG="${1#*=}"; shift ;;
    --pane)
      PANE_ARG="${2:?tmux-close-window: --pane requires a pane id}"
      shift 2
      ;;
    --pane=*) PANE_ARG="${1#*=}"; shift ;;
    --timeout)
      TIMEOUT="${2:?tmux-close-window: --timeout requires seconds}"
      shift 2
      ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    -h|--help) HELP=1; shift ;;
    -*)
      echo "tmux-close-window: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$TARGET_ARG" ]]; then
        echo "tmux-close-window: unexpected extra arg: $1" >&2
        usage >&2
        exit 2
      fi
      TARGET_ARG="$1"
      shift
      ;;
  esac
done

if [[ "$HELP" -eq 1 ]]; then
  usage
  exit 0
fi

# --- socket + tmux-as-BOX_USER ---------------------------------------------
sock="${TMUX:-}"
sock="${sock%%,*}"
if [[ -z "$sock" ]]; then
  sock="${CLE_TMUX_SOCK:-${GRK_TMUX_SOCK:-${AGY_TMUX_SOCK:-${QWN_TMUX_SOCK:-}}}}"
  sock="${sock%%,*}"
fi
[[ -n "$sock" ]] || sock="$BOX_TMUX_SOCKET"

# -u: LC_ALL=C would turn every non-ASCII -F field and TAB into "_".
TM=(tmux -u -S "$sock")
if [[ "$(id -un)" != "$BOX_USER" ]]; then
  TM=(sudo -u "$BOX_USER" tmux -u -S "$sock")
fi

# --- helpers ---------------------------------------------------------------

# Normalise an agent id: cle-7 -> CLE-07. Pad a SHORT number up to 2 digits, but
# NEVER reformat the width of an id that is already >=2 digits -- CLE-001 and
# CLE-01 are DIFFERENT ids, and re-parsing "001" as a decimal (10#001=1) then
# printing %02d gave "CLE-01", so an agent like CLE-001 closing its own window
# resolved the wrong (or no) target.
norm_id() {
  local t p n
  t="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  if printf '%s' "$t" | grep -qE '^[A-Z]+-?[0-9]+$'; then
    p="$(printf '%s' "$t" | grep -oE '^[A-Z]+')"
    n="$(printf '%s' "$t" | grep -oE '[0-9]+$')"
    while [ "${#n}" -lt 2 ]; do n="0$n"; done
    printf '%s-%s' "$p" "$n"
    return 0
  fi
  return 1
}

# CAREFUL: `tmux display-message -t <bogus>` exits 0 and prints EMPTY fields
# rather than failing, so an unresolvable target silently degrades into ":" —
# which kill-window then resolves to the CURRENT window. That is the same
# guessing defect one layer down. Every lookup below therefore reads the real
# pane list and matches exactly, and every result is validated before use.

pane_row() {
  # echo "<pane_id>|<session>|<window_index>|<window_name>" for an exact pane id
  [[ -n "${1:-}" ]] || return 1
  "${TM[@]}" list-panes -a -F '#{pane_id}|#{session_name}|#{window_index}|#{window_name}' 2>/dev/null \
    | awk -F'|' -v want="$1" '$1 == want { print; found = 1 } END { exit !found }'
}

pane_exists() { pane_row "${1:-}" >/dev/null 2>&1; }

pane_window_name() { pane_row "${1:-}" 2>/dev/null | cut -d'|' -f4- ; }

# Box tag ("bx1: CLE-07 wip") is DISPLAY only — strip it before reading an id
# out of a window name. No-op on an untagged box / undeployed helper.
# BOX_TAG is SPOOL_BOX_TAG; BOX_TAGS (optional) lists every tag a box may show.
an_strip() {
  local n="${1-}" head rest id tail
  case "$n" in
    '> '*|'? '*|'! '*)
      rest="$(an_strip "${n:2}")"
      if printf '%s' "$rest" | grep -qE '^(CLE|GRK|AGY|QWN)-[0-9]+([[:space:]]|$)'; then
        id="${rest%% *}"; tail="${rest#"$id"}"; tail="${tail# }"
        case "$tail" in '>'|'?'|'!') tail="" ;; '> '*|'? '*|'! '*) tail="${tail:2}" ;; esac
        printf '%s %s%s' "$id" "${n:0:1}" "${tail:+ $tail}"; return 0
      fi ;;
  esac
  case "$n" in *": "*) ;; *) printf '%s' "$n"; return 0 ;; esac
  head="${n%%": "*}"; rest="${n#*": "}"
  printf '%s' "$head" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' || { printf '%s' "$n"; return 0; }
  if [ -n "${BOX_TAG:-}" ] && [ "$head" = "$BOX_TAG" ]; then an_strip "$rest"; return 0; fi
  if [ -n "${BOX_TAGS:-}" ]; then
    case " $BOX_TAGS " in *" $head "*) an_strip "$rest"; return 0 ;; esac
  elif printf '%s' "$head" | LC_ALL=C grep -qE '^[a-z][a-z0-9]{2}$'; then
    an_strip "$rest"; return 0
  fi
  printf '%s' "$n"
}

pane_window_target() {
  local row
  row="$(pane_row "${1:-}" 2>/dev/null)" || return 1
  printf '%s:%s\n' "$(printf '%s' "$row" | cut -d'|' -f2)" "$(printf '%s' "$row" | cut -d'|' -f3)"
}

# A usable window target is "<session>:<index>" with BOTH halves present.
valid_window_target() {
  [[ "${1:-}" =~ ^[^:]+:[0-9]+$ ]]
}

# ...and it must actually exist. `tmux kill-window -t main:99` on a missing
# index degrades to the CURRENT window, so a typo'd explicit target is just as
# destructive as the old active-pane fallback. Match against the real list.
window_row() {
  [[ -n "${1:-}" ]] || return 1
  "${TM[@]}" list-windows -a -F '#{session_name}:#{window_index}|#{window_name}' 2>/dev/null \
    | awk -F'|' -v want="$1" '$1 == want { print; found = 1 } END { exit !found }'
}

window_exists() { window_row "${1:-}" >/dev/null 2>&1; }

# Does a window name carry AGENT_ID as its leading whole token?
# "CLE-07 wip" and "CLE-07" match; "CLE-070 wip" does not.
name_is_agent() {
  local name id
  name="$(an_strip "$1")"; id="$2"
  case "$name" in
    "$id"|"$id "*|"$id-"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve an agent id to a pane id, PROVING ownership via the window name.
# Registry rows are consulted newest-first; a window-name scan is the backstop.
resolve_pane_for_agent() {
  local id="$1" registry="${SPOOL_ROOT}/registry.tsv" p
  # The identity map first: the pane of the process that carries the id,
  # proven live (pid, start time, env) - never a window name a sort or a
  # restart may have moved onto another agent.
  if [[ -r "${SPOOL_ROOT}/agents/$id.json" ]]; then
    # shellcheck source=../lib/agent-identity.inc.sh
    type ai_pane_of >/dev/null 2>&1 || . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/agent-identity.inc.sh" 2>/dev/null
    if p="$(ai_pane_of "$id" "$("${TM[@]}" list-panes -a -F '#{pane_id}' 2>/dev/null)" 2>/dev/null)" && [[ -n "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  if [[ -f "$registry" ]]; then
    while read -r p; do
      [[ -n "$p" ]] || continue
      pane_exists "$p" || continue
      if name_is_agent "$(pane_window_name "$p")" "$id"; then
        printf '%s\n' "$p"
        return 0
      fi
    done < <(awk -F'\t' -v id="$id" '$1 == id && $3 != "" { print $3 }' "$registry" 2>/dev/null | tac)
  fi
  # Backstop: the window names on the server are themselves the ownership record.
  while IFS='|' read -r pid wname; do
    if name_is_agent "$wname" "$id"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <("${TM[@]}" list-panes -a -F '#{pane_id}|#{window_name}' 2>/dev/null)
  return 1
}

# --- resolve ownership -----------------------------------------------------
PANE=""
SOURCE=""
AGENT_ID=""

if [[ -n "$AGENT_ARG" ]]; then
  if ! AGENT_ID="$(norm_id "$AGENT_ARG")"; then
    echo "tmux-close-window: --agent must look like CLE-07 / GRK-2 / AGY-03 / QWN-01, got: $AGENT_ARG" >&2
    exit 2
  fi
elif [[ -n "${MCP_BOT_AGENT_ID:-}" ]]; then
  AGENT_ID="$(norm_id "$MCP_BOT_AGENT_ID" || true)"
fi

if [[ -n "$PANE_ARG" ]]; then
  if ! pane_exists "$PANE_ARG"; then
    echo "tmux-close-window: REFUSED — --pane $PANE_ARG does not exist on $sock; closed nothing" >&2
    exit 3
  fi
  PANE="$PANE_ARG"; SOURCE="--pane"
elif [[ -n "$AGENT_ARG" ]]; then
  if ! PANE="$(resolve_pane_for_agent "$AGENT_ID")"; then
    echo "tmux-close-window: REFUSED — no live window named '$AGENT_ID' on $sock" >&2
    echo "                   (checked ${SPOOL_ROOT}/registry.tsv and every window name); closed nothing" >&2
    exit 3
  fi
  SOURCE="--agent $AGENT_ID"
elif [[ -n "$TARGET_ARG" ]]; then
  SOURCE="explicit target"
elif [[ -n "${TMUX_PANE:-}" ]]; then
  PANE="$TMUX_PANE"; SOURCE="\$TMUX_PANE"
elif [[ -n "${CLE_TMUX_PANE:-}" ]]; then
  PANE="$CLE_TMUX_PANE"; SOURCE="\$CLE_TMUX_PANE"
elif [[ -n "${GRK_TMUX_PANE:-}" ]]; then
  PANE="$GRK_TMUX_PANE"; SOURCE="\$GRK_TMUX_PANE"
elif [[ -n "${AGY_TMUX_PANE:-}" ]]; then
  PANE="$AGY_TMUX_PANE"; SOURCE="\$AGY_TMUX_PANE"
elif [[ -n "${QWN_TMUX_PANE:-}" ]]; then
  PANE="$QWN_TMUX_PANE"; SOURCE="\$QWN_TMUX_PANE"
elif [[ -n "$AGENT_ID" ]]; then
  if ! PANE="$(resolve_pane_for_agent "$AGENT_ID")"; then
    echo "tmux-close-window: REFUSED — no live window named '$AGENT_ID' on $sock" >&2
    echo "                   (from \$MCP_BOT_AGENT_ID); closed nothing" >&2
    exit 3
  fi
  SOURCE="\$MCP_BOT_AGENT_ID ($AGENT_ID)"
else
  cat >&2 <<EOF
tmux-close-window: REFUSED — cannot prove which window to close; closed nothing.

  No --pane, no --agent, no explicit target, and none of \$TMUX_PANE /
  \$CLE_TMUX_PANE / \$GRK_TMUX_PANE / \$AGY_TMUX_PANE / \$QWN_TMUX_PANE / \$MCP_BOT_AGENT_ID is
  set. This helper deliberately has NO "close the active window" fallback:
  guessing here closes a bystander agent's window.

  If you invoked this through 'sudo', that is why the env is empty
  (sudoers has 'Defaults env_reset'). Re-run WITHOUT the outer sudo, or
  name the target explicitly:

      tmux-close-window.sh --agent CLE-07 --defer
EOF
  exit 3
fi

# Verify the pane still exists (env-sourced panes can be stale).
if [[ -n "$PANE" ]] && ! pane_exists "$PANE"; then
  echo "tmux-close-window: REFUSED — pane $PANE (from $SOURCE) is gone; closed nothing" >&2
  exit 3
fi

# Cross-check: when we know the agent id AND took the pane from the environment,
# the window must actually be that agent's. A mismatch means the env lied.
if [[ -n "$AGENT_ID" && -n "$PANE" && "$SOURCE" == \$* ]]; then
  _wname="$(pane_window_name "$PANE")"
  if [[ -n "$_wname" ]] && ! name_is_agent "$_wname" "$AGENT_ID"; then
    echo "tmux-close-window: REFUSED — $SOURCE points at pane $PANE in window '$_wname'," >&2
    echo "                   which is not agent $AGENT_ID; closed nothing" >&2
    exit 4
  fi
fi

resolve_window_target() {
  local pane="$1" explicit="$2"
  if [[ -n "$explicit" ]]; then
    if [[ "$explicit" == %* ]]; then
      pane_window_target "$explicit" || true
    else
      printf '%s\n' "$explicit"
    fi
    return 0
  fi
  [[ -n "$pane" ]] || return 0
  pane_window_target "$pane" || true
}

WINDOW_TARGET="$(resolve_window_target "$PANE" "$TARGET_ARG")"

if ! valid_window_target "$WINDOW_TARGET"; then
  echo "tmux-close-window: REFUSED — $SOURCE does not map to a <session>:<index> window" >&2
  echo "                   (got '${WINDOW_TARGET}'); closed nothing" >&2
  exit 3
fi

if ! window_exists "$WINDOW_TARGET"; then
  echo "tmux-close-window: REFUSED — window '$WINDOW_TARGET' (from $SOURCE) does not exist" >&2
  echo "                   on $sock; closed nothing (tmux would have hit the current window)" >&2
  exit 3
fi

if [[ -n "$PANE" ]]; then
  WINDOW_NAME="$(pane_window_name "$PANE")"
else
  WINDOW_NAME="$(window_row "$WINDOW_TARGET" | cut -d'|' -f2-)"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "tmux-close-window: [dry-run] would close window ${WINDOW_TARGET} ('${WINDOW_NAME}') pane=${PANE:-none} via ${SOURCE}"
  exit 0
fi

# --- agent PID discovery (claude|grok|agy|qwen under pane tree) -----------------
# Never kill -9 these; only wait for them to leave, then kill-window.
collect_agent_pids_for_pane() {
  local pane="$1"
  local pane_pid
  [[ -n "$pane" ]] || return 0
  pane_pid=$("${TM[@]}" display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
  [[ -n "$pane_pid" ]] || return 0

  local -a queue=("$pane_pid")
  local -a seen=()
  local p c cmd already
  while ((${#queue[@]} > 0)); do
    p="${queue[0]}"
    queue=("${queue[@]:1}")
    already=0
    for s in "${seen[@]+"${seen[@]}"}"; do
      if [[ "$s" == "$p" ]]; then already=1; break; fi
    done
    [[ "$already" -eq 1 ]] && continue
    seen+=("$p")

    cmd="$(ps -p "$p" -o args= 2>/dev/null || true)"
    # Match agent binaries only (not this script / wrappers with the words in path)
    if printf '%s' "$cmd" | grep -qE '(^|[[:space:]/])(claude|grok|agy|qwen)([[:space:]]|$)'; then
      printf '%s\n' "$p"
    fi

    while read -r c; do
      [[ -n "$c" ]] && queue+=("$c")
    done < <(pgrep -P "$p" 2>/dev/null || true)
  done
}

pid_alive() {
  # Cross-user safe (kill -0 EPERM on other uids)
  [[ -n "${1:-}" && -d "/proc/$1" ]]
}

do_kill_window() {
  local target="$1"
  # Last line of defence: an unqualified target (":" , "" , "5") would let tmux
  # fall back to the CURRENT window. Never hand it one.
  if ! valid_window_target "$target" || ! window_exists "$target"; then
    echo "tmux-close-window: REFUSED — '$target' is not a live <session>:<index> window; closed nothing" >&2
    return 3
  fi
  if "${TM[@]}" kill-window -t "$target" 2>/dev/null; then
    echo "tmux-close-window: killed window $target ('${WINDOW_NAME}')"
    return 0
  fi
  # Single-pane fallback if window target already gone but pane remains.
  # Guarded by an exact-match existence check: `kill-pane -t <bogus>` degrades
  # to the current pane exactly the way kill-window does.
  if [[ -n "${PANE:-}" ]] && pane_exists "$PANE" && "${TM[@]}" kill-pane -t "$PANE" 2>/dev/null; then
    echo "tmux-close-window: killed pane $PANE (window kill failed for $target)"
    return 0
  fi
  echo "tmux-close-window: failed to kill window $target" >&2
  return 1
}

# --- immediate mode --------------------------------------------------------
if [[ "$DEFER" -eq 0 ]]; then
  do_kill_window "$WINDOW_TARGET"
  exit $?
fi

# --- --defer mode: schedule closer, parent returns immediately -------------
# These logs are the only durable record of what each teardown TARGETED, which
# is what made it possible to audit the mis-targeting bug after the fact. Keep
# the production set clean: the test suites point CLOSE_LOG_DIR at a scratch
# dir so their runs do not inflate the count or dilute the real entries.
LOG="${CLOSE_LOG_DIR:-/tmp}/kill-your-self-close-$$.log"
AGENT_PIDS=()
if [[ -n "$PANE" ]]; then
  while read -r _pid; do
    [[ -n "$_pid" ]] && AGENT_PIDS+=("$_pid")
  done < <(collect_agent_pids_for_pane "$PANE")
fi

# The window may be renamed or replaced while we wait. Re-verify at kill time
# that the target still holds the pane we were given, so a deferred close can
# never land on a window that took over the index in the meantime.
GUARD_PANE="$PANE"

# Subshell inherits functions/vars; re-inlines wait then kill-window.
(
  exec >>"$LOG" 2>&1
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) defer-close start target=$WINDOW_TARGET name='${WINDOW_NAME}' pane=${PANE:-} source=${SOURCE} sock=$sock box=$BOX_USER timeout=${TIMEOUT}s pids=${AGENT_PIDS[*]:-none}"

  deadline=$((SECONDS + TIMEOUT))

  if ((${#AGENT_PIDS[@]} > 0)); then
    while (( SECONDS < deadline )); do
      alive=0
      for pid in "${AGENT_PIDS[@]}"; do
        if pid_alive "$pid"; then
          alive=1
          break
        fi
      done
      (( alive == 0 )) && break
      sleep 0.5
    done
    if (( SECONDS >= deadline )); then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) timeout waiting for agent PIDs; closing anyway"
    else
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) agent PIDs gone"
    fi
  else
    # No agent binary found at schedule time — poll pane tree, then short grace
    # so /exit can complete if agents appear briefly / were already leaving.
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) no agent PIDs at schedule; polling pane tree"
    while (( SECONDS < deadline )); do
      remaining=""
      if [[ -n "${PANE:-}" ]]; then
        remaining="$(collect_agent_pids_for_pane "$PANE" 2>/dev/null || true)"
      fi
      [[ -z "$remaining" ]] && break
      sleep 0.5
    done
    sleep 2
  fi

  sleep 0.3

  # Re-verify ownership before the destructive call.
  if [[ -n "$GUARD_PANE" ]]; then
    if ! pane_exists "$GUARD_PANE"; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) pane $GUARD_PANE already gone; nothing to close"
      exit 0
    fi
    now_target="$(pane_window_target "$GUARD_PANE" 2>/dev/null || true)"
    if valid_window_target "$now_target" && [[ "$now_target" != "$WINDOW_TARGET" ]]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) window moved: $WINDOW_TARGET -> $now_target; retargeting to the pane we own"
      WINDOW_TARGET="$now_target"
    fi
  fi

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) closing window $WINDOW_TARGET"
  do_kill_window "$WINDOW_TARGET"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) done"
) &
disown 2>/dev/null || true

echo "tmux-close-window: scheduled defer-close of $WINDOW_TARGET ('${WINDOW_NAME}') via ${SOURCE} (log=$LOG timeout=${TIMEOUT}s agent_pids=${AGENT_PIDS[*]:-none})"
exit 0
