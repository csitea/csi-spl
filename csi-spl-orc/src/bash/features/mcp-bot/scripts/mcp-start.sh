#!/usr/bin/env bash
# mcp-start.sh — stdio entrypoint for the Playwright MCP server that drives the
# dedicated "mcp-bot" Firefox, with ONE FIREFOX PROFILE PER AGENT.
#
# Ported from the box engine's mcp-bot feature (spec 069 lane Y1; the engine is
# frozen for harness work, this copy is canonical). Sibling of
# mcp-start-chrome.sh; reap-profiles.sh beside it reaps the retired clones.
#
# Typical harness entry (the agent user runs it as the desktop user):
#   "firefox": {"type": "stdio", "command": "sudo",
#               "args": ["-u", "<BOX_USER>", "-H", "--preserve-env=MCP_BOT_AGENT_ID",
#                        "<MCP_BOT_HOME>/mcp-start.sh"]}
#
# Why this wrapper exists:
#   * The AI harness runs as the agent user, but the graphical session belongs
#     to the desktop user. The browser must be spawned inside that Wayland
#     session, so the MCP server is launched via `sudo -u <desktop-user> -H`
#     and re-establishes the env here.
#   * X11 :0 on this box has no auth cookie for the harness user — Firefox MUST
#     go through Wayland. Same gotcha as wa-bot.
#   * The distro Firefox ESR is too old for the Playwright BiDi channel; a
#     private Firefox under $MCP_BOT_HOME/firefox is used instead.
#   * A Firefox profile can be held by ONE browser process at a time. With many
#     agents (c-0nn / g-0nn / a-0nn) running in parallel, a single shared
#     profile made the browser MCP first-come-first-served: every other agent
#     got "Failed to launch the browser process … exitCode=0". Hence each agent
#     gets its own profile dir, cloned from the base profile on first use.
#
# Profile selection (first match wins):
#   1. $MCP_BOT_PROFILE           — explicit profile dir (absolute path).
#   2. $MCP_BOT_AGENT_ID          — agent id, e.g. c-007 →
#                                   $MCP_BOT_HOME/ff-profile-c-007
#                                   (spawn-claude.sh exports it; the harness
#                                   MCP entry must forward it through sudo:
#                                   sudo -u <user> -H --preserve-env=MCP_BOT_AGENT_ID …)
#   3. process ancestry           — an ancestor `claude --name <ID>` or
#                                   `spawn-{claude,grok,agy,qwen}*.sh <ID>` (works
#                                   even when sudo strips the env).
#   4. fallback                   — ff-profile-pid<PID>, ephemeral: removed when
#                                   this server exits.
#   MCP_BOT_AGENT_ID=base (or MCP_BOT_PROFILE=<base dir>) selects the shared
#   base profile itself (legacy behaviour, e.g. for mcp-open.py).
#
# Per-agent profile = rsync clone of $MCP_BOT_HOME/ff-profile minus caches and
# lock files (extensions, prefs, cookies and logins are kept). A stale lock
# (lock/.parentlock left by a dead Firefox) is removed before launch; a lock
# held by a LIVE process is never touched — no other agent's browser is killed.
#
# Marionette: the base profile pins port 2929 (wa-bot owns 2828) so the SAME
# live browser can be driven by hand:
#   geckodriver --connect-existing --marionette-port <port>
# Per-agent profiles get a port derived from the agent id (30000-30999); the
# port is written to $MCP_BOT_HOME/run/<ID>.marionette-port.
set -euo pipefail
MCP_BOT_HOME="${MCP_BOT_HOME:-$HOME/.local/mcp-bot}"
BASE_PROFILE="${MCP_BOT_BASE_PROFILE:-$MCP_BOT_HOME/ff-profile}"
BASE_CONFIG="${MCP_BOT_CONFIG:-$MCP_BOT_HOME/mcp-config.json}"
RUN_DIR="$MCP_BOT_HOME/run"
PLAYWRIGHT_MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-0.0.79}"

# stdout is the MCP stdio channel — nothing may be echoed to it. Diagnostics go
# to stderr (Claude shows them in the MCP server log).
log() { printf '[mcp-start] %s\n' "$*" >&2; }

# ── 1. work out which agent we serve ────────────────────────────────────────
_id_from_ancestry() {
  # Walk up the process tree; /proc/<pid>/cmdline is world-readable so this
  # works across the sudo user switch. Returns the first agent id found.
  local pid=$$ ppid tok prev _
  for _ in $(seq 1 25); do
    ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || return 1
    [ -n "$ppid" ] && [ "$ppid" != 0 ] && [ "$ppid" != 1 ] || return 1
    pid=$ppid
    [ -r "/proc/$pid/cmdline" ] || continue
    prev=""
    while IFS= read -r -d '' tok; do
      # `claude --name <ID>` (spawn-claude.sh launches the harness this way)
      if [ "$prev" = "--name" ] && printf '%s' "$tok" | grep -qE '^[A-Za-z][A-Za-z0-9._-]{0,63}$'; then
        printf '%s' "$tok"; return 0
      fi
      # `spawn-<kind>.sh <TITLE> …` — the launcher itself is an ancestor
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
if [ -n "${MCP_BOT_PROFILE:-}" ]; then
  PROFILE="$MCP_BOT_PROFILE"
elif [ -z "$AGENT_ID" ]; then
  AGENT_ID="pid$$"; EPHEMERAL=1
  PROFILE="$MCP_BOT_HOME/ff-profile-$AGENT_ID"
elif [ "$AGENT_ID" = "base" ]; then
  PROFILE="$BASE_PROFILE"
else
  # sanitise: the id becomes a path component
  AGENT_ID=$(printf '%s' "$AGENT_ID" | tr -c 'A-Za-z0-9._-' '_')
  PROFILE="$MCP_BOT_HOME/ff-profile-$AGENT_ID"
fi
log "agent=${AGENT_ID:-?} profile=$PROFILE"

mkdir -p "$RUN_DIR"

# ── 1b. reap retired clones ─────────────────────────────────────────────────
# Every spawn mints a new agent id and every id gets a ~170M clone of the base
# profile, which nothing removed: 657 clones / 108G filled / on 2026-09-27.
# reap-profiles.sh (master guard, liveness, age from birth time — see its
# header) runs on every start, in the background so the launch is not delayed,
# under flock so parallel starts run it once. stdout is the MCP stdio channel,
# so its report goes to run/reap.log. MCP_BOT_REAP=0 turns it off.
REAPER="$(dirname "$(readlink -f "$0")")/reap-profiles.sh"
if [ "${MCP_BOT_REAP:-1}" != 0 ] && [ -x "$REAPER" ] && command -v flock >/dev/null 2>&1; then
  REAP_LOG="$RUN_DIR/reap.log"
  if [ "$(stat -c %s "$REAP_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then : > "$REAP_LOG"; fi
  REAP_KEEP=()
  if [ -n "$AGENT_ID" ]; then REAP_KEEP=(--keep "$AGENT_ID"); fi
  (
    flock -n 9 || exit 0
    printf '== %s agent=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${AGENT_ID:-?}"
    "$REAPER" --delete --quiet-skips --home "$MCP_BOT_HOME" \
      --days "${MCP_BOT_REAP_DAYS:-14}" ${REAP_KEEP[@]+"${REAP_KEEP[@]}"}
  ) 9>"$RUN_DIR/reap.lock" </dev/null >>"$REAP_LOG" 2>&1 &
fi

# ── 2. clone the base profile on first use ──────────────────────────────────
if [ ! -d "$PROFILE" ]; then
  if [ ! -d "$BASE_PROFILE" ]; then
    log "base profile $BASE_PROFILE missing — starting with an empty profile"
    mkdir -p "$PROFILE"
  else
    log "cloning $BASE_PROFILE → $PROFILE (first use)"
    TMP="$PROFILE.tmp-$$"
    rm -rf "$TMP"
    # keep extensions/prefs/cookies/logins; drop caches, session state, locks
    rsync -a \
      --exclude 'cache2/' --exclude 'startupCache/' --exclude 'shader-cache/' \
      --exclude 'thumbnails/' --exclude 'crashes/' --exclude 'minidumps/' \
      --exclude 'sessionstore-backups/' --exclude 'sessionstore.jsonlz4' \
      --exclude 'sessionCheckpoints.json' \
      --exclude 'lock' --exclude '.parentlock' \
      --exclude 'Telemetry.FailedProfileLocks.txt' \
      --exclude '*.sqlite-wal' --exclude '*.sqlite-shm' \
      "$BASE_PROFILE/" "$TMP/"
    mv "$TMP" "$PROFILE"   # atomic: a half-copied dir never becomes the profile
  fi
  # same group/mode as the base so both the desktop and the agent user can use it
  chmod g+rwX "$PROFILE" 2>/dev/null || true
fi

# ── 3. clear a STALE lock; never touch a live one ───────────────────────────
# Firefox writes `lock` (symlink → "<ip>:+<pid>") and an empty `.parentlock`.
if [ -L "$PROFILE/lock" ] || [ -e "$PROFILE/.parentlock" ]; then
  LOCK_PID=$(readlink "$PROFILE/lock" 2>/dev/null | sed -n 's/.*:+\([0-9]\+\)$/\1/p' || true)
  if [ -n "$LOCK_PID" ] && [ -d "/proc/$LOCK_PID" ] \
     && tr '\0' ' ' < "/proc/$LOCK_PID/cmdline" 2>/dev/null | grep -qF -- "$PROFILE"; then
    log "profile is held by live firefox pid $LOCK_PID — not touching it (launch will fail)"
  else
    log "removing stale profile lock (pid ${LOCK_PID:-?} is gone)"
    rm -f "$PROFILE/lock" "$PROFILE/.parentlock"
  fi
fi

# ── 4. per-agent MCP config (base config with the profile + a free marionette port) ─
if [ "$PROFILE" = "$BASE_PROFILE" ]; then
  CONFIG="$BASE_CONFIG"
else
  CONFIG="$RUN_DIR/mcp-config-$AGENT_ID.json"
  # deterministic port per id in 30000-30999 (base keeps 2929, wa-bot 2828)
  PORT=$(( 30000 + $(printf '%s' "$AGENT_ID" | cksum | cut -d' ' -f1) % 1000 ))
  python3 - "$BASE_CONFIG" "$CONFIG" "$PROFILE" "$PORT" <<'PY'
import json, sys
src, dst, profile, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
cfg = json.load(open(src))
b = cfg.setdefault("browser", {})
b["userDataDir"] = profile
lo = b.setdefault("launchOptions", {})
prefs = lo.setdefault("firefoxUserPrefs", {})
if "marionette.port" in prefs:
    prefs["marionette.port"] = port
json.dump(cfg, open(dst, "w"), indent=2)
PY
  printf '%s\n' "$PORT" > "$RUN_DIR/$AGENT_ID.marionette-port"
fi

# ── 5. desktop session env, then run the server ─────────────────────────────
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export MOZ_ENABLE_WAYLAND=1
unset DISPLAY
# the caller's cwd may be unreadable for this user (npx spawns `sh` there)
cd "$MCP_BOT_HOME"

if [ "$EPHEMERAL" = 1 ]; then
  # no agent id → keep nothing behind: run as a child, clean up on exit
  cleanup() { rm -rf "$PROFILE" "$CONFIG" "$RUN_DIR/$AGENT_ID.marionette-port"; }
  trap 'cleanup' EXIT
  trap 'kill -TERM "$CHILD" 2>/dev/null' TERM INT HUP
  # A background job in a NON-INTERACTIVE shell gets its stdin redirected to
  # /dev/null. This server speaks MCP over stdio, so that EOF made it exit 0
  # immediately and the client saw CONNECTION_CLOSED. Hand the real stdin to
  # the child explicitly via fd 3.
  exec 3<&0
  npx -y "@playwright/mcp@$PLAYWRIGHT_MCP_VERSION" --config "$CONFIG" <&3 &
  CHILD=$!
  exec 3<&-
  wait "$CHILD" || true
  exit 0
fi
exec npx -y "@playwright/mcp@$PLAYWRIGHT_MCP_VERSION" --config "$CONFIG"
