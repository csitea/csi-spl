# shellcheck shell=bash
# spool-notify-take.inc.sh — the take line by code (grade fix A, SPL-3517).
#
# spool-notify.sh calls spool_notify_take_auto for every delivery. For a
# human's post delivered by the desk sidecar to the seat that holds this box's
# dispatch lease, it starts `./run -a do_spl_take_auto` in the background:
# that action checks the topic on the hub and, when no agent owns it yet,
# posts the take line at once (SPEC-spool-fleet-roles.md 3). Everything else
# returns at once. The notifier is on a latency budget (CLE-3435): the gate
# here is pure bash, the hub read and the post run detached, and nothing here
# can fail the delivery.

# The orc ./run next to this lib (<orc>/src/bash/features/spawn-agents/lib).
SPOOL_NOTIFY_TAKE_RUN_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." 2>/dev/null && pwd)/run"

spool_notify_take_auto() {  # TO FROM KIND TASK MSGID BODY
  local to="${1:-}" from="${2:-}" kind="${3:-}" task="${4:-}" msgid="${5:-}" body="${6:-}" d held=""
  local run="${SPOOL_TAKE_AUTO_RUN:-$SPOOL_NOTIFY_TAKE_RUN_DEFAULT}"
  local desk="${SPOOL_ROOT:-}"
  [ -n "${SPOOL_FLEET_ROOT:-}" ] && [ -n "${SPOOL_BOX_ID:-}" ] || return 0
  [[ "$from" =~ ^HUM-[0-9]+$ ]] || return 0
  [[ "${task,,}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 0
  case "$kind" in task|note|msg) ;; *) return 0 ;; esac
  spool_notify_is_probe "$body" && return 0
  spool_notify_dispatch_dir_var d
  [ -e "$d/take-auto.off" ] && return 0
  [ -r "$d/lease" ] && read -r held _ <"$d/lease"
  [ "$held" = "$to@$SPOOL_BOX_ID" ] || return 0
  [ -x "$run" ] || return 0
  ( cd / && TAKE_AUTO_TO="$to" TAKE_AUTO_FROM="$from" TAKE_AUTO_TASK="$task" TAKE_AUTO_MSGID="$msgid" \
      TAKE_AUTO_BODY="${body:0:2000}" TAKE_AUTO_DESK_ROOT="$desk" SPOOL_ROOT="${d%/dispatch}" \
      DRY_RUN=0 setsid "$run" -a do_spl_take_auto </dev/null >>"$d/take-auto.out" 2>&1 & ) 2>/dev/null
  return 0
}
