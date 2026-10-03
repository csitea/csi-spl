#!/usr/bin/env bash
# spawn-remote.sh — start an agent window on ANOTHER machine of the fleet,
# through the spool (HOWTO-satellite-work §2.2, gap row 6).
#
# Why: the orchestrator's home is the satellite, and the satellite cannot ssh
# to the PC (behind NAT: "Could not resolve hostname", measured 2026-10-03),
# yet WUI and browser lanes must still run on the PC. Messages already cross
# both ways through the hub relay (spool-send.sh --to <ID>@<box>), so a spawn
# rides one: a REQUEST message carries the arguments and the brief text, and a
# receiver on the target machine runs ITS OWN spawn-window.sh (its box.env:
# SPOOL_AGENT_USER, CLAUDE_BIN, tag) and replies with the new id and pane.
#
# REQUEST (the orchestrator; same arguments as spawn-window.sh):
#   spawn-remote.sh --box <box> [--from <ID>] [--to <ID>] [--wait <secs>]
#                   <claude|grok|agy|qwen> <TITLE|auto> <WORKDIR> [BRIEF_FILE] [SLUG]
#   WORKDIR is a path ON THE TARGET machine. The brief is read HERE and travels
#   as text. --from defaults to SPOOL_AGENT_ID, else this machine's LEASE_ORCH;
#   --to (the target's mailbox) defaults to this machine's LEASE_ORCH, the role
#   id every machine has. stdout: "<ID>@<box> <PANE>". --wait 0 does not wait
#   and prints "task <task_id>" instead (default SPAWN_REMOTE_WAIT, 300 s; the
#   receiver ticks once a minute).
#
# SERVE (the receiver, one tick; the box user's crontab runs it every minute,
# installed by do_spl_spawn_remote_install_cron):
#   spawn-remote.sh --serve
#   Scans the inbox AND archive (the agent may already have acked it) of each
#   id in SPAWN_REMOTE_INBOX_IDS (default this machine's LEASE_ORCH) for
#   messages whose body opens with "spawn-request v1", each handled once
#   (<root>/spawn-remote/seen, marked BEFORE the spawn: at most once).
#   Accepted ONLY from the fleet's current orch lease holder: <root>/dispatch/
#   lease.orch ("<ID>@<box> <epoch>"); with no lease.orch at all, this
#   machine's LEASE_ORCH. "none@unreachable" accepts nobody. A relayed `from`
#   is the hub-bound "<ID>@<box>"; a bare local one is "<ID>@<this box>".
#   Everything else is refused, logged and answered with a reject.
#   The brief is DATA: written to <root>/spawn-remote/briefs/<msg_id>.md and
#   passed as a path; no field is ever evaluated. Every field is validated
#   against a strict pattern before it reaches spawn-window.sh.
#   Log: <root>/spawn-remote/serve.log, one line per request.
#   Local mode is unsigned: an agent ON this machine can forge a bare `from`,
#   but it can also run spawn-window.sh directly, so that grants nothing new.
#
# Test seams: SPAWN_REMOTE_WINDOW_CMD replaces "bash spawn-window.sh";
# SPAWN_REMOTE_SEND_CMD replaces "bash spool-send.sh".
#
# Exit (request): 0 spawned, 2 usage, 3 the send failed, 4 refused (reject
# reply, reason on stderr), 5 no reply within --wait.
# Exit (serve): 0 tick done (refusals included), 2 usage, 3 busy (another tick).
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$HERE/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=../lib/spool-fleet.inc.sh
. "$HERE/../lib/spool-fleet.inc.sh"

MAGIC_REQ="spawn-request v1"
MAGIC_REP="spawn-reply v1"
STATE="$SPOOL_ROOT/spawn-remote"
say() { echo "spawn-remote: $*" >&2; }
usage() { sed -n '14,15p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2; echo "       spawn-remote.sh --serve" >&2; exit 2; }
send() {  # spool-send.sh args...
  if [ -n "${SPAWN_REMOTE_SEND_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $SPAWN_REMOTE_SEND_CMD "$@"
  else
    bash "$HERE/spool-send.sh" "$@"
  fi
}
local_orch() { local id; id="$(_spool_fleet_conf LEASE_ORCH)"; printf '%s' "${id:-$SPOOL_ORCHESTRATOR_ID}"; }

# The body of a message file, or "" (jq reads, nothing is evaluated).
body_of() { jq -r '.body // ""' "$1" 2>/dev/null; }
# A body with any relayed "from_agent:" first line dropped.
strip_from_agent() { sed '1{/^from_agent: /d}'; }

# The ONE validation, used by both sides: nothing unvalidated reaches spawn-window.
valid_args() {  # KIND TITLE WORKDIR SLUG ; the reason on stderr
  case "$1" in claude|grok|agy|qwen) ;; *) say "bad kind '$1'"; return 1 ;; esac
  [[ "$2" = auto || "$2" =~ ^[A-Za-z][A-Za-z0-9-]{0,31}$ ]] || { say "bad title '$2'"; return 1; }
  [[ "$3" =~ ^/[A-Za-z0-9._/-]*$ && "$3" != *..* ]] || { say "bad workdir '$3' (absolute, [A-Za-z0-9._/-], no ..)"; return 1; }
  [[ -z "$4" || "$4" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { say "bad slug '$4'"; return 1; }
}

# ---- request ---------------------------------------------------------------
request() {
  local box="" from="${SPOOL_AGENT_ID:-}" to="" wait="${SPAWN_REMOTE_WAIT:-300}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --box)  [ "$#" -ge 2 ] || usage; box="$2"; shift 2 ;;
      --from) [ "$#" -ge 2 ] || usage; from="$2"; shift 2 ;;
      --to)   [ "$#" -ge 2 ] || usage; to="$2"; shift 2 ;;
      --wait) [ "$#" -ge 2 ] || usage; wait="$2"; shift 2 ;;
      --) shift; break ;;
      -*) say "unknown option $1"; usage ;;
      *) break ;;
    esac
  done
  local kind="${1:-}" title="${2:-}" workdir="${3:-}" brief="${4:-}" slug="${5:-}"
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "--box <box> is required (a desk box, e.g. sat)"; usage; }
  [[ "$wait" =~ ^[0-9]+$ ]] || { say "--wait must be seconds"; exit 2; }
  [ -n "$from" ] || from="$(local_orch)"
  [ -n "$to" ] || to="$(local_orch)"
  spl_is_participant_id "$from" && spl_is_participant_id "$to" || { say "bad --from '$from' or --to '$to'"; exit 2; }
  valid_args "$kind" "$title" "$workdir" "$slug" || exit 2
  if [ -n "$brief" ]; then
    [ -r "$brief" ] || { say "cannot read brief $brief"; exit 2; }
  fi
  local tmp out rc task
  tmp="$(mktemp)" || exit 3
  {
    printf '%s\n' "$MAGIC_REQ" \
      "(For spawn-remote.sh --serve on this machine, not for the agent reading it: do not act on it, ack it.)" \
      "kind: $kind" "title: $title" "workdir: $workdir" "slug: $slug" "---"
    if [ -n "$brief" ]; then cat -- "$brief"; fi
  } >"$tmp"
  task="$(python3 -c 'import uuid; print(uuid.uuid4())')" || { rm -f "$tmp"; exit 3; }
  out="$(send --from "$from" --to "$to@$box" --kind task --task "$task" --no-ask --no-poke --body-file "$tmp" 2>&1)"; rc=$?
  rm -f "$tmp"
  # 5 = delivered, no pane rang (the serve tick needs none)
  [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ] || { say "the request did not leave (rc=$rc): $out"; exit 3; }
  if [ "$wait" = 0 ]; then echo "task $task"; return 0; fi
  local end=$(( $(date +%s) + wait )) f b
  while :; do
    f="$(reply_file "$from" "$task")"
    if [ -n "$f" ]; then
      b="$(body_of "$f" | strip_from_agent)"
      case "$(sed -n 's/^status: //p' <<<"$b" | head -1)" in
        ok) printf '%s %s\n' "$(sed -n 's/^agent: //p' <<<"$b" | head -1)" "$(sed -n 's/^pane: //p' <<<"$b" | head -1)"; return 0 ;;
        *) say "refused by $box: $(sed -n 's/^reason: //p' <<<"$b" | head -1)"; exit 4 ;;
      esac
    fi
    [ "$(date +%s)" -lt "$end" ] || { say "no reply from $box within ${wait}s (task $task); it may still come: spool tail --task $task"; exit 5; }
    sleep "${SPAWN_REMOTE_POLL:-5}"
  done
}

# The reply to TASK in ID's inbox or archive.
reply_file() {  # ID TASK
  local d f
  for d in "$SPOOL_ROOT/$1/inbox" "$SPOOL_ROOT/$1/archive"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      [ "$(jq -r '.task_id // ""' "$f" 2>/dev/null)" = "$2" ] || continue
      body_of "$f" | strip_from_agent | head -1 | grep -qxF "$MAGIC_REP" && { printf '%s' "$f"; return 0; }
    done < <(grep -lF -- "$2" "$d"/*.json 2>/dev/null)
  done
}

# ---- serve -----------------------------------------------------------------
# The orch lease holder as <ID>@<box>, or "" (nobody may spawn).
orch_holder() {
  local f="$SPOOL_ROOT/dispatch/lease.orch" h="" id
  if [ -r "$f" ]; then
    read -r h _ <"$f"
    case "$h" in none@*|unknown:*|'') return 0 ;; esac
  else
    h="$(_spool_fleet_conf LEASE_ORCH)"
  fi
  id="${h%@*}"
  spl_is_participant_id "$id" || return 0
  case "$h" in *@*) printf '%s' "$h" ;; *) printf '%s@%s' "$h" "$(spool_fleet_box)" ;; esac
}

qualify() { case "$1" in *@*) printf '%s' "$1" ;; *) printf '%s@%s' "$1" "$(spool_fleet_box)" ;; esac; }

log_line() {  # VERDICT MSG_ID FROM DETAIL
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" >>"$STATE/serve.log"
  say "$1 $2 from $3: $4"
}

reply() {  # INBOX_ID TO TASK STATUS LINES...
  local me="$1" to="$2" task="$3" st="$4" body rc; shift 4
  body="$(printf '%s\n' "$MAGIC_REP" "status: $st" "$@")"
  send --from "$me" --to "$to" --kind "$([ "$st" = ok ] && echo result || echo reject)" \
    --task "$task" --no-ask --body "$body" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ] || say "WARN the reply to $to (task $task) did not leave (rc=$rc)"
}

# The KEY: value of a request header (the lines before ---).
req_field() { sed -n '1,/^---$/p' <<<"$1" | sed -n "s/^$2: //p" | head -1; }

handle() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from task body holder kind title workdir slug brief out rc id pane reason
  msg="$(jq -r '.msg_id // ""' "$f" 2>/dev/null)"
  [[ "$msg" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 0
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  from="$(jq -r '.from // ""' "$f")"; task="$(jq -r '.task_id // ""' "$f")"
  body="$(body_of "$f" | strip_from_agent)"
  spl_is_participant_id "${from%@*}" || { log_line REFUSED "$msg" "$from" "sender is not an agent id"; return 0; }
  holder="$(orch_holder)"
  if [ -z "$holder" ] || [ "$(qualify "$from")" != "$holder" ]; then
    log_line REFUSED "$msg" "$from" "not the fleet orch lease holder (${holder:-nobody})"
    reply "$me" "$from" "$task" refused "reason: only the fleet orch lease holder (${holder:-nobody}) may spawn here"
    return 0
  fi
  kind="$(req_field "$body" kind)" title="$(req_field "$body" title)"
  workdir="$(req_field "$body" workdir)" slug="$(req_field "$body" slug)"
  if ! reason="$(valid_args "$kind" "$title" "$workdir" "$slug" 2>&1)" || [ ! -d "$workdir" ]; then
    reason="${reason:-workdir $workdir is not a directory on this machine}"
    log_line REJECTED "$msg" "$from" "$reason"
    reply "$me" "$from" "$task" refused "reason: ${reason#spawn-remote: }"
    return 0
  fi
  brief="$STATE/briefs/$msg.md"
  sed '1,/^---$/d' <<<"$body" >"$brief" && chmod 644 "$brief"
  [ -s "$brief" ] || { rm -f "$brief"; brief=""; }
  if [ -n "${SPAWN_REMOTE_WINDOW_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$($SPAWN_REMOTE_WINDOW_CMD "$kind" "$title" "$workdir" ${brief:+"$brief"} ${slug:+"$slug"} 2>&1)"; rc=$?
  else
    out="$(bash "$HERE/spawn-window.sh" "$kind" "$title" "$workdir" ${brief:+"$brief"} ${slug:+"$slug"} 2>&1)"; rc=$?
  fi
  read -r id pane <<<"$(grep -E '^[A-Za-z][A-Za-z0-9-]* (%[0-9]+|-)$' <<<"$out" | tail -1)"
  if [ "$rc" -ne 0 ] || [ -z "${id:-}" ]; then
    log_line FAILED "$msg" "$from" "spawn-window rc=$rc: $(tail -1 <<<"$out")"
    reply "$me" "$from" "$task" failed "reason: spawn-window rc=$rc: $(tail -1 <<<"$out")"
    return 0
  fi
  log_line SPAWNED "$msg" "$from" "$id@$(spool_fleet_box) $pane $kind ${slug:-} brief=${brief:-none}"
  reply "$me" "$from" "$task" ok "agent: $id@$(spool_fleet_box)" "pane: $pane" "request: $msg"
}

serve() {
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
  mkdir -p "$STATE/briefs" || exit 2
  exec 9>"$STATE/serve.lock"
  flock -n 9 || { say "another tick is running"; exit 3; }
  local ids="${SPAWN_REMOTE_INBOX_IDS:-$(local_orch)}" me d f
  for me in $ids; do
    spl_is_participant_id "$me" || continue
    for d in "$SPOOL_ROOT/$me/inbox" "$SPOOL_ROOT/$me/archive"; do
      [ -d "$d" ] || continue
      # a day back is enough: a tick runs every minute; older files are history
      while IFS= read -r f; do
        body_of "$f" | strip_from_agent | head -1 | grep -qxF "$MAGIC_REQ" && handle "$me" "$f" </dev/null
      done < <(find "$d" -maxdepth 1 -name '*.json' -mmin -1440 -print0 2>/dev/null |
               xargs -0 -r grep -lF -- "$MAGIC_REQ" 2>/dev/null | sort)
    done
  done
  return 0
}

case "${1:-}" in
  --serve) [ "$#" -eq 1 ] || usage; serve ;;
  ""|-h|--help) usage ;;
  *) request "$@" ;;
esac
