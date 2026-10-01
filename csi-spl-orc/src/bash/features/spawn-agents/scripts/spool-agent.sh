#!/usr/bin/env bash
# spool-agent.sh — start claude, grok, agy or qwen as a SEATED, MIRRORED spool agent
# (specs/036-spool-terminal-mirror, "the wrapper").
#
#   spool-agent.sh [options] [--] claude|grok|agy|qwen [cli args...]
#
# What a session started through it gets, before the CLI starts:
#   1. an agent id: --as, else $MCP_BOT_AGENT_ID (the box spawner sets it),
#      else the next free CLE-n / GRK-n / AGY-n / QWN-n on the desk (next-agent-id.sh, a claim)
#   2. this tmux window carries the id, so the desk can find the pane
#   3. a desk seat (do_spl_desk_up): a human's web UI DM to the id is typed
#      into this terminal, and its notice strip shows on the right
#   4. the mirror hooks for THIS session: claude gets `--settings <file>`, so
#      it does not depend on anyone's ~/.claude/settings.json; grok has no
#      such flag and reads ~/.grok/hooks/, which gets one idempotent file;
#      qwen reads claude-shaped hooks from ~/.qwen/settings.json, where the
#      mirror entries are merged in (every other key and hook kept).
#      Neither is added when ~/.claude/settings.json already carries the
#      mirror hook (both CLIs read that file): one copy per session.
#      Every prompt typed here and every final answer is posted into the id's
#      DM with the human (spool-mirror.py); the web UI's own words never echo
#   5. MCP_BOT_AGENT_ID / SPOOL_AGENT_ID exported, then the CLI
#
# Options:
#   --as <ID>          the agent id (^[A-Z]{2,4}-[0-9]+$)
#   --env dev|prd|dev,prd|self  default: every env with this desk on the box
#                      (self: a self-hosted hub, seated by install.sh --env self)
#   --tenant <slug>    default t1
#   --box <box>        default box-desk
#   --no-mirror        seat the agent but post nothing (<seat>/.no-mirror)
#   --operator HUM-n   the human typing at this terminal: its prompts are posted
#                      AS that human (typed_by, hub-verified; spec 036 FR-012)
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
# Exit codes before the CLI starts: 2 usage or no CLI binary, 3 not in tmux, 4 no id, 5 seat
# failed. Afterwards: the CLI's own (exec), or with --backfill its exit code.
set -uo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FEAT="$(cd "$_here/.." && pwd)"
ORC="$(cd "$FEAT/../../../.." && pwd)"
RUN="${SPOOL_AGENT_RUN:-$ORC/run}"
MIRROR_PY="$_here/spool-mirror.py"

OPERATOR="" AS="" ENVN="${SPOOL_AGENT_ENVS:-}" TENANT="t1" BOX="box-desk" MIRROR=1 SEAT=1 BACKFILL=0 DRY=0
usage() { sed -n '/^#   spool-agent.sh/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --as)        [ "$#" -ge 2 ] || usage; AS="$2"; shift 2 ;;
    --env)       [ "$#" -ge 2 ] || usage; ENVN="$2"; shift 2 ;;
    --tenant)    [ "$#" -ge 2 ] || usage; TENANT="$2"; shift 2 ;;
    --box)       [ "$#" -ge 2 ] || usage; BOX="$2"; shift 2 ;;
    --no-mirror) MIRROR=0; shift ;;
    --operator)  [ "$#" -ge 2 ] || usage; OPERATOR="$2"; shift 2 ;;
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
  agy)    PREFIX=AGY; KIND=agy ;;
  qwen)   PREFIX=QWN; KIND=qwen ;;
  *) echo "spool-agent: the CLI must be claude, grok, agy or qwen, got '$CLI'" >&2; exit 2 ;;
esac
[ -z "$OPERATOR" ] || [[ "$OPERATOR" =~ ^HUM-[A-Za-z0-9_-]{1,64}$ ]] || { echo "spool-agent: --operator must be a HUM-n id" >&2; exit 2; }
[ -z "$ENVN" ] || [[ "$ENVN" =~ ^(dev|prd|self|dev,prd|prd,dev)$ ]] || { echo "spool-agent: --env must be dev, prd, dev,prd or self (a self-hosted hub)" >&2; exit 2; }
[[ "$TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "spool-agent: bad --tenant '$TENANT'" >&2; exit 2; }
[[ "$BOX" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$BOX" != box-wui ]] || { echo "spool-agent: bad --box '$BOX'" >&2; exit 2; }
if [ "$BACKFILL" = 1 ] && [ "$KIND" != claude ]; then
  echo "spool-agent: --backfill is claude only (grok has no session id flag)" >&2; exit 2
fi

BOX_USER="${SPOOL_BOX_USER:-$(stat -c %U "$ORC")}"
ME="$(id -un)"
BOX_HOME="$(getent passwd "$BOX_USER" | cut -d: -f6)"
# The envs to seat on: --env, else every env that has this desk on the box
# (the agent is then online wherever the humans are), else dev.
# SPOOL_AGENT_DESK_ROOT (tests) may name the env as %ENV%; without it there is
# one root, so only dev is discovered.
seat_root_of() {
  if [ -n "${SPOOL_AGENT_DESK_ROOT:-}" ]; then printf '%s' "${SPOOL_AGENT_DESK_ROOT//%ENV%/$1}"
  else printf '%s' "$BOX_HOME/.local/share/csi-spl/cloud/$1/desk/$TENANT/$BOX"; fi
}
if [ -z "$ENVN" ]; then
  _envs="dev prd self"
  [ -n "${SPOOL_AGENT_DESK_ROOT:-}" ] && [[ "$SPOOL_AGENT_DESK_ROOT" != *%ENV%* ]] && _envs=dev
  for e in $_envs; do
    if [ "$(id -un)" = "$BOX_USER" ]; then test -d "$(seat_root_of $e)" && ENVN="${ENVN:+$ENVN,}$e"
    else sudo -n -u "$BOX_USER" test -d "$(seat_root_of $e)" 2>/dev/null && ENVN="${ENVN:+$ENVN,}$e"; fi
  done
  ENVN="${ENVN:-dev}"
fi
ENVS=(${ENVN//,/ })
SEAT_ROOT="$(seat_root_of "${ENVS[0]}")"
TMUX_SOCK="${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$BOX_USER")/default}"
say() { echo "spool-agent: $*" >&2; }
as_box() {  # CMD... as the box user, env passed explicitly (sudo drops it)
  if [ "$ME" = "$BOX_USER" ]; then "$@"; else sudo -n -u "$BOX_USER" "$@"; fi
}
# The seat dir exists, the box sidecar is alive, and the roster already
# names this agent. Reconnecting then skips do_spl_desk_up, which is the
# hub pin and the roster wait. A missing piece falls through to the full seat.
seat_is_live() {
  local root="$1" id="$2" pidf roster pid
  pidf="$root/spool/.hub/hub-run.pid"
  roster="$root/spool/.hub/roster.json"
  as_box test -d "$root/spool/$id/inbox" || return 1
  as_box test -r "$pidf" || return 1
  as_box test -r "$roster" || return 1
  pid="$(as_box cat "$pidf" 2>/dev/null | tr -cd '0-9')"
  [ -n "$pid" ] || return 1
  as_box kill -0 "$pid" 2>/dev/null || return 1
  as_box grep -q "\"$id\"" "$roster" || return 1
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
# The box spawner exports <PREFIX>_TMUX_PANE: `su -` to the agent user drops
# TMUX_PANE. This CLI's own prefix wins: a CLE_TMUX_PANE inherited from a
# parent claude session names THAT session's pane, not this one.
kind_pane_var="${PREFIX}_TMUX_PANE"
PANE="${TMUX_PANE:-${!kind_pane_var:-${CLE_TMUX_PANE:-${GRK_TMUX_PANE:-${AGY_TMUX_PANE:-${QWN_TMUX_PANE:-}}}}}}"
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
# The hook writers are the shared lib's (spool-harness.sh --mirror uses the
# same ones): agy gets the named hook "spool-mirror" merged into
# ~/.gemini/config/hooks.json, qwen the mirror entries merged into
# ~/.qwen/settings.json; every other hook and key is kept.
# shellcheck source=../lib/spool-mirror-hooks.inc.sh
. "$FEAT/lib/spool-mirror-hooks.inc.sh"
AGY_HOOK="${SPOOL_AGENT_AGY_HOOKS:-$HOME/.gemini/config/hooks.json}"
agy_hooks_merge() { smh_agy_merge "$AGY_HOOK" "$MIRROR_PY"; }
QWEN_SETTINGS="${SPOOL_AGENT_QWEN_SETTINGS:-$HOME/.qwen/settings.json}"
qwen_hooks_merge() { smh_qwen_merge "$QWEN_SETTINGS" "$MIRROR_PY"; }
hooks_json() { smh_hooks_json "$MIRROR_PY"; }

SESSION_ID=""
[ "$BACKFILL" = 1 ] && SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
# Hooks already in the user's ~/.claude/settings.json (claude AND grok read
# it) are not added a second time: two copies fire twice per prompt, and when
# they run different checkouts of spool-mirror.py the dedup of one cannot see
# the other (measured: two posts per prompt, in two topics).
USER_HOOKS=0
case "$KIND" in
  claude|grok) grep -q 'spool-mirror\.py' "${SPOOL_AGENT_USER_SETTINGS:-$HOME/.claude/settings.json}" 2>/dev/null && USER_HOOKS=1 ;;
  qwen) grep -q 'spool-mirror\.py' "$QWEN_SETTINGS" 2>/dev/null && USER_HOOKS=1 ;;
esac
USE_SETTINGS=0
[ "$MIRROR" = 1 ] && [ "$KIND" = claude ] && [ "$USER_HOOKS" = 0 ] && USE_SETTINGS=1
# The CLI binary: CLAUDE_BIN / GROK_BIN, else PATH, else ~/.local/bin/<cli>
# (where both installers put it; a sudo hop resets PATH and loses it).
bin_var="$(printf '%s_BIN' "$KIND" | tr '[:lower:]' '[:upper:]')"
CLI_BIN="${!bin_var:-}"
[ -n "$CLI_BIN" ] || CLI_BIN="$(command -v "$CLI" 2>/dev/null || true)"
[ -n "$CLI_BIN" ] || { [ -x "$HOME/.local/bin/$CLI" ] && CLI_BIN="$HOME/.local/bin/$CLI"; }
if [ -z "$CLI_BIN" ] && [ "$DRY" = 0 ]; then say "cannot find the $CLI binary (set $bin_var)"; exit 2; fi
CLI_BIN="${CLI_BIN:-$CLI}"
build_argv() {
  ARGV=("$CLI_BIN")
  [ "$USE_SETTINGS" = 1 ] && ARGV+=(--settings "$HOOKS_JSON")
  [ -n "$SESSION_ID" ] && ARGV+=(--session-id "$SESSION_ID")
  ARGV+=("$@")
}
build_argv "$@"

if [ "$DRY" = 1 ]; then
  say "DRY RUN - nothing changed"
  echo "id: $ID"
  echo "window: ${PANE:-none} '${WNAME}'${NEWNAME:+ -> rename to '$NEWNAME'}"
  if [ "$SEAT" = 1 ]; then
    for e in "${ENVS[@]}"; do
      if seat_is_live "$(seat_root_of "$e")" "$ID"; then echo "seat: already live on $e, skip do_spl_desk_up"
      else echo "seat: $RUN -a do_spl_desk_up ENV=$e TENANT_ID=$TENANT DESK_BOX=$BOX DESK_AGENT=$ID (as $BOX_USER)"; fi
    done
    echo "strip: the notice strip is split before $CLI paints"
  else echo "seat: skipped"; fi
  echo "mirror: $([ "$MIRROR" = 1 ] && echo on || echo off)${OPERATOR:+ (prompts typed by $OPERATOR)}"
  if [ "$MIRROR" = 1 ] && [ "$USER_HOOKS" = 1 ] && [ "$KIND" = qwen ]; then echo "hooks: already in $QWEN_SETTINGS (merged again, idempotent)"
  elif [ "$MIRROR" = 1 ] && [ "$USER_HOOKS" = 1 ]; then echo "hooks: already in ~/.claude/settings.json (not added again)"
  elif [ "$MIRROR" = 1 ] && [ "$KIND" = claude ]; then echo "hooks: $HOOKS_JSON"
  elif [ "$MIRROR" = 1 ] && [ "$KIND" = grok ]; then echo "hooks: $GROK_HOOK"
  elif [ "$MIRROR" = 1 ] && [ "$KIND" = qwen ]; then echo "hooks: $QWEN_SETTINGS (merged spool-mirror entries)"
  elif [ "$MIRROR" = 1 ]; then echo "hooks: $AGY_HOOK (named hook spool-mirror)"; fi
  [ "$BACKFILL" = 1 ] && echo "backfill: session $SESSION_ID on exit"
  printf 'argv:'; printf ' %q' "${ARGV[@]}"; echo
  exit 0
fi

[ -n "${NEWNAME:-}" ] && { tm rename-window -t "$PANE" "$NEWNAME" 2>/dev/null || say "WARN could not rename the window to '$NEWNAME'"; }

# ── 3. the seat ──────────────────────────────────────────────────────────────
if [ "$SEAT" = 1 ]; then
  seated=0
  for e in "${ENVS[@]}"; do
    if seat_is_live "$(seat_root_of "$e")" "$ID"; then
      say "$ID is already seated on $BOX in $TENANT ($e); skipping do_spl_desk_up"
      seated=$((seated + 1))
      continue
    fi
    out="$(as_box env ENV="$e" TENANT_ID="$TENANT" DESK_BOX="$BOX" DESK_AGENT="$ID" DRY_RUN=0 "$RUN" -a do_spl_desk_up 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && ! as_box test -d "$(seat_root_of "$e")/spool/$ID"; then
      say "WARN the $e desk seat failed (rc $rc):"; printf '%s\n' "$out" | grep -E 'FATAL|FAIL' | tail -3 >&2; continue
    fi
    seated=$((seated + 1))
    [ "$rc" -eq 0 ] && say "$ID is seated on $BOX in $TENANT ($e)" || say "WARN $ID has a $e seat but the roster did not confirm it yet (rc $rc)"
  done
  [ "$seated" -gt 0 ] || { say "no desk seat could be made"; exit 5; }
  # The strip, split NOW - before the CLI paints, so no live TUI is resized -
  # and for every CLI: the desk adds it only to a pane on the alternate
  # screen, and at this moment the pane is still a shell (agy never is).
  # agy paints on the NORMAL screen: the pane says it is a TUI (@spool_strip),
  # so the notifier never writes a notice into its tty. One call per env: the
  # second finds the strip and respawns it tailing both envs' logs.
  [ "$KIND" = agy ] && tm set-option -p -t "$PANE" @spool_strip 1 2>/dev/null
  strip=""
  for e in "${ENVS[@]}"; do
    as_box test -d "$(seat_root_of "$e")/spool/$ID" || continue
    strip="$(as_box env SPOOL_ROOT="$(seat_root_of "$e")/spool" SPOOL_TMUX_SOCKET="$TMUX_SOCK" bash -c '
      F="$1"; . "$F/lib/spool-env.inc.sh" && . "$F/lib/spool-notify.inc.sh" && . "$F/lib/spool-poke-queue.inc.sh" &&
      spool_env_resolve && spool_show_notice_pane "$2" "$3"' _ "$FEAT" "$ID" "$PANE" 2>/dev/null)"
  done
  [ -n "$strip" ] || say "WARN no notice strip for $ID (the desk cron retries)"
fi
for e in "${ENVS[@]}"; do
  sr="$(seat_root_of "$e")"
  as_box test -d "$sr/spool/$ID" || continue
  if [ -n "$OPERATOR" ]; then
    as_box python3 "$MIRROR_PY" operator "$sr/spool/$ID" "$OPERATOR" >/dev/null ||
      say "WARN could not record $OPERATOR as the operator of $ID ($e)"
  fi
  if [ "$MIRROR" = 0 ]; then
    as_box touch "$sr/spool/$ID/.no-mirror" 2>/dev/null || say "WARN could not write $ID's .no-mirror ($e)"
  elif as_box test -e "$sr/spool/$ID/.no-mirror"; then
    as_box rm -f "$sr/spool/$ID/.no-mirror" 2>/dev/null
  fi
done

if [ "$MIRROR" = 1 ] && [ "$USER_HOOKS" = 0 ]; then
  if [ "$KIND" = claude ]; then
    mkdir -p "$HOOKS_DIR" && hooks_json >"$HOOKS_JSON.tmp.$$" && mv -f "$HOOKS_JSON.tmp.$$" "$HOOKS_JSON" ||
      { say "WARN cannot write $HOOKS_JSON: this session is not mirrored"; USE_SETTINGS=0; build_argv "$@"; }
  elif [ "$KIND" = grok ]; then
    mkdir -p "${GROK_HOOK%/*}" && hooks_json >"$GROK_HOOK.tmp.$$" && mv -f "$GROK_HOOK.tmp.$$" "$GROK_HOOK" ||
      say "WARN cannot write $GROK_HOOK: this session is not mirrored"
  fi
fi
if [ "$MIRROR" = 1 ] && [ "$KIND" = agy ]; then
  agy_hooks_merge || say "WARN cannot write $AGY_HOOK: this session is not mirrored"
fi
# qwen: merged on every start, so a moved checkout's hook path is replaced.
if [ "$MIRROR" = 1 ] && [ "$KIND" = qwen ]; then
  qwen_hooks_merge || say "WARN cannot write $QWEN_SETTINGS: this session is not mirrored"
fi

# ── 5. the CLI ───────────────────────────────────────────────────────────────
export MCP_BOT_AGENT_ID="$ID" SPOOL_AGENT_ID="$ID"
say "$ID: starting $CLI (mirror $([ "$MIRROR" = 1 ] && echo on || echo off); DM it at the web UI as $ID@$BOX)"
if [ "$BACKFILL" = 0 ]; then exec "${ARGV[@]}"; fi
"${ARGV[@]}"; rc=$?
as_box env ENV="${ENVS[0]}" TENANT_ID="$TENANT" DESK_BOX="$BOX" DESK_AGENT="$ID" SESSION_TOKEN="$SESSION_ID" \
  SESSION_AGENT_USER="$ME" DRY_RUN=0 "$RUN" -a do_spl_desk_session_upload 2>&1 | grep -E '^\{|FATAL' >&2
exit "$rc"
