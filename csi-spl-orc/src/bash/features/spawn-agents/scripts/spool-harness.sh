#!/usr/bin/env bash
# spool-harness.sh — the standard box launcher (SPEC-spool-box-api.md §2.1,
# specs/012-spool-box-api). Prepares one agent's spool surface, then exec-s the
# agent CLI in its place:
#
#   spool-harness --as <agent_id> [--to-box <box_id>] [--mirror] [--] <agent-cli-command...>
#
#   1. dirs      $SPOOL_ROOT/<agent_id>/{inbox,outbox,archive} and the shared
#                $SPOOL_ROOT/{files,pins}, mode 0775; umask 0002 so the files
#                the agent writes later are 0664
#   2. identity  $SPOOL_BOX_ID and the box key $SPOOL_KEYS_DIR/box-<box_id>.key
#                (default $HOME/.spool/keys), mode 0600. Local mode (no
#                $SPOOL_HUB_URL): both optional. Hub mode: both required
#   3. sidecar   hub mode only: a live `spool hub-run` for this $SPOOL_ROOT
#                (started when absent, one per root under a lock), and the
#                agent seen under this box in its roster cache
#   4. env       exports SPOOL_ROOT, SPOOL_BOX_ID (when set), SPOOL_AGENT_ID
#                and SPOOL_NOTIFY_CMD (the terminal leg, specs/028)
#   5. mirror    --mirror only: the terminal mirror's hooks for THIS session
#                (specs/036, lib/spool-mirror-hooks.inc.sh): claude gets
#                `--settings <file>` inserted after the binary, grok / agy / qwen
#                get their hook file written or merged. Skipped when the user's
#                own settings already carry the hook, and for every launch while
#                $SPOOL_ROOT/.mirror-off exists (the box-wide kill switch). The
#                hook posts each typed prompt and each final answer into the
#                agent's web UI DM, from its desk seat; no seat, no post
#   6. exec      replaces itself with the agent command
#
# --to-box <box_id> names the box this session is attached to: it sets
# $SPOOL_BOX_ID for the session and wins over an inherited value.
#
# Env (all optional):
#   SPOOL_ROOT                  default /var/spool-hub
#   SPOOL_BOX_ID                box id, ^[a-z0-9][a-z0-9-]{0,31}$
#   SPOOL_KEYS_DIR              default $HOME/.spool/keys
#   SPOOL_HUB_URL               set = hub mode
#   SPOOL_BIN                   the spool binary (see lib/spool-env.inc.sh)
#   SPOOL_NOTIFY_CMD            the terminal leg (specs/028): the command the
#                               spool binary runs after a message lands in a
#                               local agent's inbox. Default: this feature's
#                               scripts/spool-notify.sh; `off` disables it
#   SPOOL_HARNESS_SIDECAR       auto (start when absent) | external (a service
#                               owns it: only wait for the roster) | off
#   SPOOL_HARNESS_WAIT_SECS     roster wait, default 25 (hub-run rescans every 10s)
#   SPOOL_HARNESS_STRICT        1 = an unconfirmed sidecar/roster is fatal (69);
#                               default: warn and start the agent anyway, since
#                               sends queue in $SPOOL_ROOT/.hub while the hub is down
#
# Exit codes (before the exec; afterwards the agent's own):
#   2   usage
#   69  hub mode: no spool binary to start the sidecar; or, strict, the
#       sidecar is not running or the agent is not announced
#   73  a spool dir cannot be created or is not writable
#   78  verify/refuse: bad agent or box id; hub mode without a box id or a
#       0600 box key (same code as `spool` verify/refuse, spec §4)
#   127 the agent command is not found
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$HARNESS_DIR/../lib/spool-env.inc.sh"

BOX_ID_RE='^[a-z0-9][a-z0-9-]{0,31}$'

say()  { echo "spool-harness: $*" >&2; }
die()  { local rc="$1"; shift; say "$*"; exit "$rc"; }
usage() {
  echo "usage: spool-harness --as <agent_id> [--to-box <box_id>] [--mirror] [--] <agent-cli-command...>" >&2
  exit 2
}

agent="" to_box="" mirror=0
while [ $# -gt 0 ]; do
  case "$1" in
    --as)       [ $# -ge 2 ] || usage; agent="$2"; shift 2 ;;
    --as=*)     agent="${1#--as=}"; shift ;;
    --to-box)   [ $# -ge 2 ] || usage; to_box="$2"; shift 2 ;;
    --to-box=*) to_box="${1#--to-box=}"; shift ;;
    --mirror)   mirror=1; shift ;;
    -h|--help)  usage ;;
    --)         shift; break ;;
    -*)         say "unknown option '$1'"; usage ;;
    *)          break ;;
  esac
done
[ -n "$agent" ] || { say "--as <agent_id> is required"; usage; }
[ $# -gt 0 ] || { say "no agent command given"; usage; }

spool_valid_id "$agent" || exit 78
[ -n "$to_box" ] && SPOOL_BOX_ID="$to_box"
SPOOL_BOX_ID="${SPOOL_BOX_ID:-}"
if [ -n "$SPOOL_BOX_ID" ] && ! [[ "$SPOOL_BOX_ID" =~ $BOX_ID_RE ]]; then
  die 78 "'$SPOOL_BOX_ID' is not a box id (want $BOX_ID_RE)"
fi

spool_env_resolve
hub_mode=0; [ -n "${SPOOL_HUB_URL:-}" ] && hub_mode=1

# ── 1. directories ─────────────────────────────────────────────────────────
umask 0002
ensure_dir() {  # DIR
  local d="$1"
  mkdir -p "$d" 2>/dev/null || die 73 "cannot create $d"
  if [ -O "$d" ]; then
    chmod 0775 "$d" || die 73 "cannot chmod 0775 $d"
  elif [ ! -w "$d" ]; then
    die 73 "$d exists, is owned by $(stat -c %U "$d"), and is not writable here"
  fi
}
for d in "$SPOOL_ROOT/$agent/inbox" "$SPOOL_ROOT/$agent/outbox" "$SPOOL_ROOT/$agent/archive" \
         "$SPOOL_ROOT/$agent" "$SPOOL_ROOT/files" "$SPOOL_ROOT/pins"; do
  ensure_dir "$d"
done

# ── 2. identity ────────────────────────────────────────────────────────────
keys_dir="${SPOOL_KEYS_DIR:-$HOME/.spool/keys}"
if [ -n "$SPOOL_BOX_ID" ]; then
  key="$keys_dir/box-$SPOOL_BOX_ID.key"
  if [ -f "$key" ]; then
    kmode="$(stat -c %a "$key")"
    if [ "$kmode" != 600 ]; then
      [ "$hub_mode" = 1 ] && die 78 "box key $key has mode $kmode, want 600"
      say "warning: box key $key has mode $kmode, want 600 (unused in local mode)"
    fi
  elif [ "$hub_mode" = 1 ]; then
    die 78 "hub mode needs the box key $key (mint it once: SPOOL_BOX_ID=$SPOOL_BOX_ID spool keygen)"
  fi
elif [ "$hub_mode" = 1 ]; then
  die 78 "hub mode (SPOOL_HUB_URL set) needs SPOOL_BOX_ID or --to-box"
fi

# ── 3. sidecar (hub mode) ──────────────────────────────────────────────────
# 0 when the roster cache lists AGENT under BOX. The sidecar writes the cache
# from the hub's welcome/roster frames as compact JSON {"<box>":["<id>",...]}.
roster_has() {  # FILE BOX AGENT
  [ -r "$1" ] || return 1
  grep -oE "\"$2\":\[[^]]*\]" "$1" 2>/dev/null | grep "\"$3\"" >/dev/null
}
sidecar_alive() {  # PIDFILE
  local pid
  pid="$(cat "$1" 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
    && tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null
}
sidecar() {
  local mode="${SPOOL_HARNESS_SIDECAR:-auto}" hub="$SPOOL_ROOT/.hub"
  local pidf="$hub/hub-run.pid" logf="$hub/hub-run.log" roster="$hub/roster.json"
  local wait="${SPOOL_HARNESS_WAIT_SECS:-25}" started=0 t0 i
  case "$mode" in
    off) say "sidecar: SPOOL_HARNESS_SIDECAR=off, not checked"; return 0 ;;
    auto|external) ;;
    *) die 2 "SPOOL_HARNESS_SIDECAR must be auto, external or off (got '$mode')" ;;
  esac
  [[ "$wait" =~ ^[0-9]+$ ]] || die 2 "SPOOL_HARNESS_WAIT_SECS must be a whole number (got '$wait')"
  mkdir -p "$hub" 2>/dev/null || die 73 "cannot create $hub"
  t0="$(date +%s)"
  if [ "$mode" = auto ]; then
    exec 9>"$hub/hub-run.lock" || die 73 "cannot open $hub/hub-run.lock"
    flock 9
    if ! sidecar_alive "$pidf"; then
      command -v "$SPOOL_BIN" >/dev/null 2>&1 || die 69 "spool binary '$SPOOL_BIN' not found (set SPOOL_BIN)"
      # specs/028 FR-001: the sidecar is what writes cross-box mail and a
      # signed-in human's WUI task into a local inbox, so it is the process
      # that has to carry the terminal leg.
      SPOOL_ROOT="$SPOOL_ROOT" SPOOL_BOX_ID="$SPOOL_BOX_ID" \
      SPOOL_NOTIFY_CMD="$SPOOL_NOTIFY_CMD" \
        setsid "$SPOOL_BIN" hub-run >>"$logf" 2>&1 </dev/null 9>&- &
      echo "$!" >"$pidf"
      started=1
      say "sidecar: started spool hub-run (pid $!, log $logf)"
    fi
    flock -u 9; exec 9>&-
  fi
  for ((i = 0; i < wait * 5; i++)); do
    # A roster written before a fresh start may be stale: require a newer one.
    if roster_has "$roster" "$SPOOL_BOX_ID" "$agent" \
       && { [ "$started" = 0 ] || [ "$(stat -c %Y "$roster")" -ge "$t0" ]; }; then
      say "sidecar: $agent announced on $SPOOL_BOX_ID"
      return 0
    fi
    if [ "$mode" = auto ] && ! sidecar_alive "$pidf"; then
      say "sidecar: spool hub-run is not running; last log lines:"
      tail -n 5 "$logf" >&2 2>/dev/null || true
      break
    fi
    sleep 0.2
  done
  [ "${SPOOL_HARNESS_STRICT:-0}" = 1 ] && die 69 "sidecar: $agent not announced on $SPOOL_BOX_ID within ${wait}s"
  say "warning: $agent not yet announced on $SPOOL_BOX_ID; starting the agent anyway (sends queue until the hub is back)"
}
[ "$hub_mode" = 1 ] && sidecar

# ── 4. env ─────────────────────────────────────────────────────────────────
export SPOOL_ROOT SPOOL_AGENT_ID="$agent"
[ -n "$SPOOL_BOX_ID" ] && export SPOOL_BOX_ID
# The agent's own sends go out through this process tree, so the RECIPIENT's
# pane is rung whether the agent used the `spool send` verb or the spool_send
# MCP tool (specs/012 FR-001: one API, so one terminal leg too).
[ -n "$SPOOL_NOTIFY_CMD" ] && export SPOOL_NOTIFY_CMD

# ── 5. mirror ──────────────────────────────────────────────────────────────
command -v "$1" >/dev/null 2>&1 || die 127 "agent command '$1' not found"
if [ "$mirror" = 1 ]; then
  kind="$(basename "$1")"
  if [ -e "$SPOOL_ROOT/.mirror-off" ]; then
    say "mirror: off for every launch ($SPOOL_ROOT/.mirror-off exists)"
  else
    case "$kind" in
      claude|grok|agy|qwen)
        # shellcheck source=../lib/spool-mirror-hooks.inc.sh
        . "$HARNESS_DIR/../lib/spool-mirror-hooks.inc.sh"
        if smh_install "$kind" "$agent" "${SPOOL_MIRROR_PY:-$HARNESS_DIR/spool-mirror.py}"; then
          [ "${#SMH_ARGS[@]}" -gt 0 ] && set -- "$1" "${SMH_ARGS[@]}" "${@:2}"
        else
          say "warning: cannot write the mirror hooks ($kind): this session is not mirrored"
        fi ;;
      *) say "mirror: '$kind' has no hook mechanism; not mirrored" ;;
    esac
  fi
fi

# ── 6. exec ────────────────────────────────────────────────────────────────
exec "$@"
