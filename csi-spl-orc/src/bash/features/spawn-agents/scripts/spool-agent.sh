#!/usr/bin/env bash
# spool-agent.sh — start claude or grok as a SEATED, MIRRORED spool agent
# (specs/036-spool-terminal-mirror, "the wrapper").
#
#   spool-agent.sh [options] [--] claude|grok [cli args...]
#
# What a session started through it gets, before the CLI starts:
#   1. an agent id: --as, else $MCP_BOT_AGENT_ID (the box spawner sets it),
#      else the next free CLE-n / GRK-n on the desk (next-agent-id.sh, a claim)
#   2. this tmux window carries the id, so the desk can find the pane
#   3. a desk seat (do_spl_desk_up): a human's web UI DM to the id is typed
#      into this terminal, and its notice strip shows on the right
#   4. the mirror hooks for THIS session: claude gets `--settings <file>`, so
#      it does not depend on anyone's ~/.claude/settings.json; grok has no
#      such flag and reads ~/.grok/hooks/, which gets one idempotent file.
#      Every prompt typed here and every final answer is posted into the id's
#      DM with the human (spool-mirror.py); the web UI's own words never echo
#   5. MCP_BOT_AGENT_ID / SPOOL_AGENT_ID exported, then the CLI
#
# Options:
#   --as <ID>          the agent id (^[A-Z]{2,4}-[0-9]+$)
#   --env dev|prd      default dev
#   --tenant <slug>    default t1
#   --box <box>        default box-desk
#   --no-mirror        seat the agent but post nothing (<seat>/.no-mirror)
#   --no-seat          skip the desk seat (the mirror then has no seat to post
#                      from, so this is for a session that is seated already)
#   --backfill         claude only: when the CLI exits, attach the session's
#                      transcript, redacted, to the DM (do_spl_desk_session_upload)
#   --dry-run          print the plan and the final argv; change nothing
#
# Env: SPOOL_AGENT_REGISTRY_DIR - a box spawner's registry dir whose ids are
#      never reissued (see "the id" below); SPOOL_BOX_TAG / BOX_TAG - the window
#      tag, else the one the window already carries
#
# Runs as the box user (the owner of this checkout, who owns the desk state)
# or as any user that may `sudo -n -u <box user>`: the desk steps hop.
# It must run inside tmux on the box user's server: a seat without a live
# window is retired by the desk reconcile, and the web UI leg types into the
# pane. Outside tmux it refuses (exit 3) unless --no-seat.
#
# Exit codes before the CLI starts: 2 usage, 3 not in tmux, 4 no id, 5 seat
# failed. Afterwards: the CLI's own (exec), or with --backfill its exit code.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FEAT="$(cd "$_here/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
RUN="${SPOOL_AGENT_RUN:-$ORC/run}"
MIRROR_PY="$_here/spool-mirror.py"

AS="" ENVN="dev" TENANT="t1" BOX="box-desk" MIRROR=1 SEAT=1 BACKFILL=0 DRY=0
usage() { sed -n '/^#   spool-agent.sh/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --as)        [ "$#" -ge 2 ] || usage; AS="$2"; shift 2 ;;
    --env)       [ "$#" -ge 2 ] || usage; ENVN="$2"; shift 2 ;;
    --tenant)    [ "$#" -ge 2 ] || usage; TENANT="$2"; shift 2 ;;
    --box)       [ "$#" -ge 2 ] || usage; BOX="$2"; shift 2 ;;
    --no-mirror) MIRROR=0; shift ;;
    --no-seat)   SEAT=0; shift ;;
    --backfill)  BACKFILL=1; shift ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage ;;
    --)          shift; break ;;
    -*)          echo "spool-agent: unknown option $1" >&2; usage ;;
    *)           break ;;
  esac
done
[ "$#" -ge 1 ] || usage
CLI="$1"; shift
case "$CLI" in
  claude) PREFIX=CLE; KIND=claude ;;
  grok)   PREFIX=GRK; KIND=grok ;;
  *) echo "spool-agent: the CLI must be claude or grok, got '$CLI'" >&2; exit 2 ;;
esac
[[ "$ENVN" =~ ^(dev|prd)$ ]] || { echo "spool-agent: --env must be dev or prd" >&2; exit 2; }
[[ "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "spool-agent: bad --tenant '$TENANT'" >&2; exit 2; }
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui ]] || { echo "spool-agent: bad --box '$BOX'" >&2; exit 2; }
if [ "$BACKFILL" = 1 ] && [ "$KIND" != claude ]; then
  echo "spool-agent: --backfill is claude only (grok has no session id flag)" >&2; exit 2
fi

BOX_USER="${SPOOL_BOX_USER:-$(stat -c %U "$ORC")}"
ME="$(id -un)"
BOX_HOME="$(getent passwd "$BOX_USER" | cut -d: -f6)"
SEAT_ROOT="${SPOOL_AGENT_DESK_ROOT:-$BOX_HOME/.local/share/csi-spl/cloud/$ENVN/desk/$TENANT/$BOX}"
TMUX_SOCK="${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$BOX_USER")/default}"
say() { echo "spool-agent: $*" >&2; }
as_box() {  # CMD... as the box user, env passed explicitly (sudo drops it)
  if [ "$ME" = "$BOX_USER" ]; then "$@"; else sudo -n -u "$BOX_USER" "$@"; fi
}
tm() { as_box tmux -S "$TMUX_SOCK" "$@"; }

# ── 1. the id ────────────────────────────────────────────────────────────────
# The desk's allocator (next-agent-id.sh) sees the desk registry, its seat dirs
# and the live windows. A box spawner may keep a registry of its own: name its
# dir in SPOOL_AGENT_REGISTRY_DIR (a registry.tsv and one dir per id; no
# default) and an id it once gave out is never reissued - a reissued id would
# read the old agent's mail. The floor is the higher of the two, and the id is
# CLAIMED (mkdir), never guessed.
REG_DIR="${SPOOL_AGENT_REGISTRY_DIR:-}"
engine_max() {
  [ -n "$REG_DIR" ] || return 0
  { cut -f1 "$REG_DIR/registry.tsv" 2>/dev/null; ls -1 "$REG_DIR" 2>/dev/null; } |
    sed -nE "s/^(.*: )?$PREFIX-([0-9]+)\b.*/\2/p" | sort -n | tail -1
}
pick_id() {
  local a n e i try
  a="$(as_box env SPOOL_ROOT="$SEAT_ROOT/spool" SPOOL_TMUX_SOCKET="$TMUX_SOCK" \
        bash "$_here/next-agent-id.sh" --kind "$KIND" --no-reserve 2>/dev/null)" || return 1
  n="${a#*-}"; e="$(engine_max)"; e="${e:-0}"
  (( 10#$e >= 10#$n )) && n=$((10#$e + 1))
  if [ "$DRY" = 1 ]; then printf '%s-%02d\n' "$PREFIX" "$((10#$n))"; return 0; fi
  for ((i = 0; i < 20; i++)); do
    try="$(printf '%s-%02d' "$PREFIX" "$((10#$n + i))")"
    as_box env SPOOL_ROOT="$SEAT_ROOT/spool" SPOOL_TMUX_SOCKET="$TMUX_SOCK" \
      bash "$_here/next-agent-id.sh" --claim "$try" >/dev/null 2>&1 && { echo "$try"; return 0; }
  done
  return 1
}
ID="${AS:-${MCP_BOT_AGENT_ID:-}}"
if [ -n "$ID" ]; then
  [[ "$ID" =~ ^[A-Z]{2,4}-[0-9]+$ && "${ID%%-*}" != BOX ]] || { say "not an agent id: '$ID'"; exit 2; }
else
  ID="$(pick_id)" || { say "no free $PREFIX id on $SEAT_ROOT"; exit 4; }
fi

# ── 2. the window ────────────────────────────────────────────────────────────
PANE="${TMUX_PANE:-${CLE_TMUX_PANE:-${GRK_TMUX_PANE:-}}}"
if [ "$SEAT" = 1 ] && [ -z "$PANE" ]; then
  say "not inside tmux: a desk seat needs a live window (run it in a tmux pane, or pass --no-seat)"; exit 3
fi
WNAME=""
if [ -n "$PANE" ]; then
  WNAME="$(tm display-message -p -t "$PANE" '#{window_name}' 2>/dev/null || true)"
  case " $WNAME " in
    *" $ID "*|*" $ID:"*|*": $ID "*|*": $ID") NEWNAME="" ;;
    *) tag="${SPOOL_BOX_TAG:-${BOX_TAG:-}}"
       [ -n "$tag" ] || tag="$(printf '%s' "$WNAME" | sed -nE 's/^([a-z0-9][a-z0-9-]*): .*/\1/p')"
       NEWNAME="${tag:+$tag: }$ID" ;;
  esac
fi

# ── 4. the hooks ─────────────────────────────────────────────────────────────
HOOKS_DIR="${SPOOL_AGENT_HOOKS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/spool-agent}"
HOOKS_JSON="$HOOKS_DIR/mirror-hooks.json"
GROK_HOOK="$HOME/.grok/hooks/spool-mirror.json"
hooks_json() {
  python3 - "$MIRROR_PY" <<'EOF_PY'
import json, shlex, sys
p = shlex.quote(sys.argv[1])
cmd = f"[ -r {p} ] && exec python3 {p} hook; exit 0"
h = [{"hooks": [{"type": "command", "command": cmd, "timeout": 10}]}]
print(json.dumps({"hooks": {"UserPromptSubmit": h, "Stop": h}}, indent=2, sort_keys=True))
EOF_PY
}

SESSION_ID=""
[ "$BACKFILL" = 1 ] && SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
USE_SETTINGS=0
[ "$MIRROR" = 1 ] && [ "$KIND" = claude ] && USE_SETTINGS=1
build_argv() {
  ARGV=("$CLI")
  [ "$USE_SETTINGS" = 1 ] && ARGV+=(--settings "$HOOKS_JSON")
  [ -n "$SESSION_ID" ] && ARGV+=(--session-id "$SESSION_ID")
  ARGV+=("$@")
}
build_argv "$@"

if [ "$DRY" = 1 ]; then
  say "DRY RUN - nothing changed"
  echo "id: $ID"
  echo "window: ${PANE:-none} '${WNAME}'${NEWNAME:+ -> rename to '$NEWNAME'}"
  if [ "$SEAT" = 1 ]; then echo "seat: $RUN -a do_spl_desk_up ENV=$ENVN TENANT_ID=$TENANT DESK_BOX=$BOX DESK_AGENT=$ID (as $BOX_USER)"; else echo "seat: skipped"; fi
  echo "mirror: $([ "$MIRROR" = 1 ] && echo on || echo off)"
  [ "$MIRROR" = 1 ] && [ "$KIND" = claude ] && echo "hooks: $HOOKS_JSON"
  [ "$MIRROR" = 1 ] && [ "$KIND" = grok ] && echo "hooks: $GROK_HOOK"
  [ "$BACKFILL" = 1 ] && echo "backfill: session $SESSION_ID on exit"
  printf 'argv:'; printf ' %q' "${ARGV[@]}"; echo
  exit 0
fi

[ -n "${NEWNAME:-}" ] && { tm rename-window -t "$PANE" "$NEWNAME" 2>/dev/null || say "WARN could not rename the window to '$NEWNAME'"; }

# ── 3. the seat ──────────────────────────────────────────────────────────────
if [ "$SEAT" = 1 ]; then
  out="$(as_box env ENV="$ENVN" TENANT_ID="$TENANT" DESK_BOX="$BOX" DESK_AGENT="$ID" DRY_RUN=0 "$RUN" -a do_spl_desk_up 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! as_box test -d "$SEAT_ROOT/spool/$ID"; then
    say "the desk seat failed (rc $rc):"; printf '%s\n' "$out" | grep -E 'FATAL|FAIL' | tail -3 >&2; exit 5
  fi
  [ "$rc" -eq 0 ] && say "$ID is seated on $BOX in $TENANT ($ENVN)" || say "WARN $ID has a seat but the roster did not confirm it yet (rc $rc)"
fi
if [ "$MIRROR" = 0 ]; then
  as_box touch "$SEAT_ROOT/spool/$ID/.no-mirror" 2>/dev/null || say "WARN could not write $ID's .no-mirror"
elif as_box test -e "$SEAT_ROOT/spool/$ID/.no-mirror"; then
  as_box rm -f "$SEAT_ROOT/spool/$ID/.no-mirror" 2>/dev/null
fi

if [ "$MIRROR" = 1 ]; then
  if [ "$KIND" = claude ]; then
    mkdir -p "$HOOKS_DIR" && hooks_json >"$HOOKS_JSON.tmp.$$" && mv -f "$HOOKS_JSON.tmp.$$" "$HOOKS_JSON" ||
      { say "WARN cannot write $HOOKS_JSON: this session is not mirrored"; USE_SETTINGS=0; build_argv "$@"; }
  else
    mkdir -p "${GROK_HOOK%/*}" && hooks_json >"$GROK_HOOK.tmp.$$" && mv -f "$GROK_HOOK.tmp.$$" "$GROK_HOOK" ||
      say "WARN cannot write $GROK_HOOK: this session is not mirrored"
  fi
fi

# ── 5. the CLI ───────────────────────────────────────────────────────────────
export MCP_BOT_AGENT_ID="$ID" SPOOL_AGENT_ID="$ID"
say "$ID: starting $CLI (mirror $([ "$MIRROR" = 1 ] && echo on || echo off); DM it at the web UI as $ID@$BOX)"
if [ "$BACKFILL" = 0 ]; then exec "${ARGV[@]}"; fi
"${ARGV[@]}"; rc=$?
as_box env ENV="$ENVN" TENANT_ID="$TENANT" DESK_BOX="$BOX" DESK_AGENT="$ID" SESSION_TOKEN="$SESSION_ID" \
  SESSION_AGENT_USER="$ME" DRY_RUN=0 "$RUN" -a do_spl_desk_session_upload 2>&1 | grep -E '^\{|FATAL' >&2
exit "$rc"
