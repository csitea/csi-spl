#!/usr/bin/env bash
# mcp-start-chrome.sh — stdio entrypoint for a Playwright MCP server driving
# Google Chrome / Chromium, with ONE BROWSER PROFILE PER AGENT.
#
# Ported from the box engine's mcp-bot feature (the engine is frozen for
# harness work; this copy is canonical). Design points:
#
#   1. NO BASE-PROFILE CLONE. A Firefox sibling of this wrapper rsynced a
#      ~175 MB base profile (extensions + logins) for every new agent id; 461
#      of those clones had accumulated to 80 GB by 2026-09-09. Chrome here
#      starts from an EMPTY user-data-dir unless a base profile is explicitly
#      provisioned at $MCP_BOT_HOME/cr-profile, so a fresh agent costs a few MB.
#   2. IT REAPS. Every start prunes cr-profile-* dirs older than
#      $MCP_BOT_CHROME_TTL_DAYS (default 14) that no live browser is holding,
#      so the directory cannot grow without bound.
#   3. HEADLESS BY DEFAULT, so it works from any agent with no dependency on
#      a Wayland/X11 session. MCP_BOT_CHROME_HEADLESS=0 opens a window.
#   4. IDLE TIMEOUT. A browser nobody drives for MCP_BOT_CHROME_IDLE_MIN
#      minutes (default 15) is closed; the next tool call starts a new one.
#      See section 8.
#
# Typical harness entry (the agent user runs it as the desktop user):
#   "chrome": {"type": "stdio", "command": "sudo",
#              "args": ["-u", "<BOX_USER>", "-H", "--preserve-env=MCP_BOT_AGENT_ID",
#                       "<MCP_BOT_HOME>/mcp-start-chrome.sh"]}
#
# Profile selection (first match wins):
#   1. $MCP_BOT_CHROME_PROFILE   — explicit profile dir (absolute path).
#   2. $MCP_BOT_AGENT_ID         — agent id, e.g. c-416 →
#                                  $MCP_BOT_HOME/cr-profile-c-416
#                                  (the harness MCP entry must forward it
#                                  through sudo: --preserve-env=MCP_BOT_AGENT_ID)
#   3. process ancestry          — an ancestor `claude --name <ID>` or
#                                  `spawn-{claude,grok,agy,qwen}*.sh <ID>`.
#   4. fallback                  — cr-profile-pid<PID>, ephemeral: removed when
#                                  this server exits.
#   MCP_BOT_AGENT_ID=base selects $MCP_BOT_HOME/cr-profile itself.
#
# Browser selection: the base config's launchOptions.channel (default
# "chrome" → the distro google-chrome).
set -euo pipefail
MCP_BOT_HOME="${MCP_BOT_HOME:-$HOME/.local/mcp-bot}"
BASE_PROFILE="${MCP_BOT_CHROME_BASE_PROFILE:-$MCP_BOT_HOME/cr-profile}"
BASE_CONFIG="${MCP_BOT_CHROME_CONFIG:-$MCP_BOT_HOME/mcp-config-chrome.json}"
RUN_DIR="$MCP_BOT_HOME/run"
PLAYWRIGHT_MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-0.0.79}"
TTL_DAYS="${MCP_BOT_CHROME_TTL_DAYS:-14}"

# stdout is the MCP stdio channel — nothing may be echoed to it. Diagnostics go
# to stderr (Claude shows them in the MCP server log).
log() { printf '[mcp-start-chrome] %s\n' "$*" >&2; }

# ── 1. work out which agent we serve ────────────────────────────────────────
_id_from_ancestry() {
  # Walk up the process tree; /proc/<pid>/cmdline is world-readable so this
  # works across the sudo user switch. Returns the first agent id found.
  local pid=$$ ppid tok prev
  for _ in $(seq 1 25); do
    ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || return 1
    [ -n "$ppid" ] && [ "$ppid" != 0 ] && [ "$ppid" != 1 ] || return 1
    pid=$ppid
    [ -r "/proc/$pid/cmdline" ] || continue
    prev=""
    while IFS= read -r -d '' tok; do
      if [ "$prev" = "--name" ] && printf '%s' "$tok" | grep -qE '^[A-Za-z][A-Za-z0-9._-]{0,63}$'; then
        printf '%s' "$tok"; return 0
      fi
      if printf '%s' "$prev" | grep -qE '(^|/)spawn-[a-z-]+\.sh$' \
         && printf '%s' "$tok" | grep -qE '^[A-Za-z][A-Za-z0-9._-]{0,63}$'; then
        printf '%s' "$tok"; return 0
      fi
      prev="$tok"
    done < "/proc/$pid/cmdline"
  done
  return 1
}

AGENT_ID="${MCP_BOT_AGENT_ID:-}"
# a literal, unexpanded "${…}" means the harness did not substitute — ignore it
case "$AGENT_ID" in \$*) AGENT_ID="" ;; esac
[ -n "$AGENT_ID" ] || AGENT_ID="$(_id_from_ancestry || true)"

EPHEMERAL=0
if [ -n "${MCP_BOT_CHROME_PROFILE:-}" ]; then
  PROFILE="$MCP_BOT_CHROME_PROFILE"
elif [ -z "$AGENT_ID" ]; then
  AGENT_ID="pid$$"; EPHEMERAL=1
  PROFILE="$MCP_BOT_HOME/cr-profile-$AGENT_ID"
elif [ "$AGENT_ID" = "base" ]; then
  PROFILE="$BASE_PROFILE"
else
  # sanitise: the id becomes a path component
  AGENT_ID=$(printf '%s' "$AGENT_ID" | tr -c 'A-Za-z0-9._-' '_')
  PROFILE="$MCP_BOT_HOME/cr-profile-$AGENT_ID"
fi
log "agent=${AGENT_ID:-?} profile=$PROFILE"

# ── 2. is a user-data-dir held by a LIVE browser? ───────────────────────────
# Chrome takes an exclusive lock on its user-data-dir, so this is both the
# "can I launch" test and the "is this dir safe to reap" test.
_dir_in_use() {
  local dir="$1" d pid
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ -r "/proc/$pid/cmdline" ] || continue
    if { tr '\0' '\n' < "/proc/$pid/cmdline"; } 2>/dev/null \
       | grep -qxF -- "--user-data-dir=$dir"; then
      printf '%s' "$pid"; return 0
    fi
  done
  return 1
}

# ── 3. reap: this is the anti-leak difference from the Firefox wrapper ──────
# Prune per-agent profiles nobody has used in TTL_DAYS and nobody is holding.
# Never touches the base profile, never touches THIS agent's profile.
_reap_old_profiles() {
  local d holder
  [ -d "$MCP_BOT_HOME" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$d" = "$PROFILE" ] && continue
    [ "$d" = "$BASE_PROFILE" ] && continue
    if holder=$(_dir_in_use "$d"); then
      log "reap: skipping $(basename "$d") — held by live pid $holder"
      continue
    fi
    log "reap: removing stale $(basename "$d") (unused > ${TTL_DAYS}d)"
    rm -rf "$d" "$RUN_DIR/mcp-config-chrome-$(basename "$d" | sed 's/^cr-profile-//').json"
  done < <(find "$MCP_BOT_HOME" -maxdepth 1 -type d -name 'cr-profile-*' \
             -mtime "+$TTL_DAYS" 2>/dev/null)
}

mkdir -p "$RUN_DIR"
_reap_old_profiles || true

# ── 4. create the profile on first use ──────────────────────────────────────
# Deliberately NOT an rsync of a fat base profile — see the header. A base
# profile is used only when one has been provisioned by hand.
if [ ! -d "$PROFILE" ]; then
  if [ -d "$BASE_PROFILE" ] && [ "$PROFILE" != "$BASE_PROFILE" ]; then
    log "cloning $BASE_PROFILE → $PROFILE (first use)"
    TMP="$PROFILE.tmp-$$"
    rm -rf "$TMP"
    rsync -a \
      --exclude 'Default/Cache/' --exclude 'Default/Code Cache/' \
      --exclude 'Default/Service Worker/CacheStorage/' \
      --exclude 'GrShaderCache/' --exclude 'ShaderCache/' \
      --exclude 'GraphiteDawnCache/' --exclude 'component_crx_cache/' \
      --exclude 'Crash Reports/' --exclude 'SingletonLock' \
      --exclude 'SingletonSocket' --exclude 'SingletonCookie' \
      --exclude 'Default/Sessions/' --exclude 'Default/Session Storage/' \
      "$BASE_PROFILE/" "$TMP/"
    mv "$TMP" "$PROFILE"   # atomic: a half-copied dir never becomes the profile
  else
    log "creating empty profile $PROFILE (no base profile at $BASE_PROFILE)"
    mkdir -p "$PROFILE"
  fi
  chmod g+rwX "$PROFILE" 2>/dev/null || true
fi
touch "$PROFILE"   # refresh mtime so an in-use profile is never reaped

# ── 5. clear a STALE singleton lock; never touch a live one ─────────────────
# Chrome writes SingletonLock as a symlink → "<hostname>-<pid>".
if [ -L "$PROFILE/SingletonLock" ] || [ -e "$PROFILE/SingletonLock" ]; then
  if HOLDER=$(_dir_in_use "$PROFILE"); then
    log "profile is held by live chrome pid $HOLDER — not touching it (launch will fail)"
  else
    log "removing stale SingletonLock/Socket/Cookie (holder is gone)"
    rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"
  fi
fi

# ── 6. per-agent MCP config (base config with this profile substituted) ─────
if [ "$PROFILE" = "$BASE_PROFILE" ]; then
  CONFIG="$BASE_CONFIG"
else
  CONFIG="$RUN_DIR/mcp-config-chrome-$AGENT_ID.json"
  python3 - "$BASE_CONFIG" "$CONFIG" "$PROFILE" "${MCP_BOT_CHROME_HEADLESS:-1}" <<'PY'
import json, sys
src, dst, profile, headless = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cfg = json.load(open(src))
b = cfg.setdefault("browser", {})
b["userDataDir"] = profile
lo = b.setdefault("launchOptions", {})
lo["headless"] = headless not in ("0", "false", "no", "")
json.dump(cfg, open(dst, "w"), indent=2)
PY
fi

# ── 7. session env, then run the server ─────────────────────────────────────
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ "${MCP_BOT_CHROME_HEADLESS:-1}" = "0" ]; then
  # headed: Chrome needs a display. Xwayland (:0) works for the desktop user;
  # find the mutter Xauthority cookie rather than hard-coding its random name.
  export DISPLAY="${DISPLAY:-:0}"
  if [ -z "${XAUTHORITY:-}" ]; then
    XAUTHORITY=$(ls -1t "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* 2>/dev/null | head -1 || true)
    [ -n "$XAUTHORITY" ] && export XAUTHORITY
  fi
  log "headed mode: DISPLAY=$DISPLAY XAUTHORITY=${XAUTHORITY:-<none>}"
else
  unset DISPLAY
fi
# the caller's cwd may be unreadable for this user (npx spawns `sh` there)
cd "$MCP_BOT_HOME"

# ── 8. idle timeout: close a browser nobody is driving ──────────────────────
# 2026-10-01: an agent's headless Chrome was left on a page with a WebGL
# animation for 3h43m after its last tool call. It rendered in software
# (swiftshader) on ~5 cores, 19.6 CPU-hours, and the box crawled at load 159.
# The browser is only needed while the agent makes browser_* calls, so a relay
# in front of the server stamps every client request, and a watchdog kills
# this profile's browser after IDLE_SEC without one. The MCP server stays up
# and launches a fresh browser on the next tool call: the profile (cookies,
# logins) survives, open tabs and page state do not.
#   MCP_BOT_CHROME_IDLE_MIN       idle minutes before the browser is closed
#                                 (default 15; 0 disables the watchdog)
#   MCP_BOT_CHROME_IDLE_SEC       same in seconds, wins over _MIN (tests)
#   MCP_BOT_CHROME_IDLE_POLL_SEC  watchdog poll interval (default 60)
IDLE_SEC="${MCP_BOT_CHROME_IDLE_SEC:-$(( ${MCP_BOT_CHROME_IDLE_MIN:-15} * 60 ))}"
IDLE_POLL="${MCP_BOT_CHROME_IDLE_POLL_SEC:-60}"
STAMP="$RUN_DIR/chrome-activity-$$"

# main browser processes on THIS profile. Child processes carry --type=, and
# Chrome rewrites their cmdline into one space-joined string, so match it
# anywhere rather than as a whole argv element.
_browser_pids() {
  local pid
  for pid in $(pgrep -u "$(id -u)" -f -- "--user-data-dir=$PROFILE( |$)"); do
    { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null \
      | grep -q -- '--type=' && continue
    printf '%s\n' "$pid"
  done
}

# copy client→server bytes unchanged; refresh the stamp at most every 5 s
_relay() {
  exec python3 -c '
import os, sys, time
stamp, last = sys.argv[1], 0.0
while True:
    try:
        buf = os.read(0, 65536)
    except InterruptedError:
        continue
    if not buf:
        break
    now = time.time()
    if now - last > 5:
        try:
            os.utime(stamp)
        except OSError:
            open(stamp, "a").close()
        last = now
    view = memoryview(buf)
    try:
        while view:
            view = view[os.write(1, view):]
    except BrokenPipeError:
        break
' "$STAMP"
}

_watchdog() {
  local age pid
  while sleep "$IDLE_POLL"; do
    kill -0 "$WRAPPER_PID" 2>/dev/null || exit 0   # wrapper gone: stop
    age=$(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || date +%s) ))
    [ "$age" -ge "$IDLE_SEC" ] || continue
    for pid in $(_browser_pids); do
      log "idle ${age}s >= ${IDLE_SEC}s: closing browser pid $pid (a new one starts on the next tool call)"
      kill -TERM "$pid" 2>/dev/null || true
    done
  done
}

WRAPPER_PID=$$
WATCHDOG=""
CHILD=""
touch "$STAMP"
cleanup() {
  if [ -n "$WATCHDOG" ]; then kill "$WATCHDOG" 2>/dev/null || true; fi
  # the relay outlives a killed server while the client keeps stdin open
  pkill -TERM -P "$WRAPPER_PID" 2>/dev/null || true
  rm -f "$STAMP"
  # no agent id → keep nothing behind
  if [ "$EPHEMERAL" = 1 ]; then rm -rf "$PROFILE" "$CONFIG"; fi
}
trap 'cleanup' EXIT
# stop relay, server and watchdog together: `wait` on the server waits for the
# whole pipeline, and the relay only ends when the client closes stdin
trap 'pkill -TERM -P "$WRAPPER_PID" 2>/dev/null' TERM INT HUP
if [ "$IDLE_SEC" -gt 0 ]; then
  _watchdog </dev/null >/dev/null &
  WATCHDOG=$!
fi
# A background job in a NON-INTERACTIVE shell gets its stdin redirected to
# /dev/null. This server speaks MCP over stdio, so that EOF made it exit 0
# immediately and the client saw CONNECTION_CLOSED. Hand the real stdin to
# the relay explicitly via fd 3.
exec 3<&0
_relay <&3 | npx -y "@playwright/mcp@$PLAYWRIGHT_MCP_VERSION" --config "$CONFIG" &
CHILD=$!
exec 3<&-
rc=0
wait "$CHILD" || rc=$?
# a trapped signal interrupts wait (rc > 128): wait again for the real exit
if [ "$rc" -gt 128 ]; then rc=0; wait "$CHILD" || rc=$?; fi
exit "$rc"
