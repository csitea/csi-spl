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
#                   <claude|grok|agy|qwen|mistral> <TITLE|auto> <WORKDIR> [BRIEF_FILE] [SLUG]
#   WORKDIR is a path ON THE TARGET machine. The brief is read HERE and travels
#   as text. --from defaults to SPOOL_AGENT_ID, else this machine's LEASE_ORCH;
#   --to (the target's mailbox) defaults to this machine's LEASE_ORCH, the role
#   id every machine has. stdout: "<ID>@<box> <PANE>". --wait 0 does not wait
#   and prints "task <task_id>" instead (default SPAWN_REMOTE_WAIT, 300 s; the
#   receiver ticks once a minute). A waiting request carries "expires: <epoch>"
#   = now + wait - SPAWN_REMOTE_MARGIN (default 60 s, at most half the wait):
#   the receiver starts nothing after it, so a request the relay delivers late
#   is refused there instead of racing this side's local fallback (SPL-2801:
#   on 2026-10-21 the relay took 4 min each way and one ask became two lanes).
#   The lane row's fields travel too (spec 153 3.23, SPL-5007): "topic:" from
#   SPAWN_LANE_TOPIC, else LANE_ISSUE_TOPIC, "scope:" from SPAWN_LANE_SCOPE,
#   "files:" from SPAWN_LANE_FILES, each only when set, each one line. The env
#   of this box does not reach the far launcher, which would fall back to the
#   brief and, when that names no discussion, lose its row (rdb 0264).
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
#   A request with no topic, scope or files line (an older sender) launches as
#   it did: the launcher reads the brief. A receiver that predates those lines
#   ignores them. The ok reply adds "warn: <line>" when this spawn wrote
#   <id>/lane-unlinked.log, and the requester prints it on stderr: the only
#   other trace is on this box. Best effort: a launcher that has not reached
#   its put when spawn-window returns (no start check: every kind but claude)
#   and a refusal only the hub sees (<id>/lane.log) are not reported.
#   Local mode is unsigned: an agent ON this machine can forge a bare `from`,
#   but it can also run spawn-window.sh directly, so that grants nothing new.
#
# ISSUE (SPL-5093): a lane whose workspace desk is on another box gets its
# issue from that box, the only one the hub lets act as that desk:
#   spawn-remote.sh --issue-end --box <desk box> --id <lane id> --key <KEY> --tenant <workspace>
#                   --life <lifetime dir> --status <diss|onhold|blocked|done> [--reason ..] [--repo ..] [--sha ..] [--evidence ..]
#   ends it the same way and writes the reply's issue-end into --life. A request
#   carries a retry token, kept on the placing box from the send until a reply
#   gives the key: a retry after a lost reply sends the same token and links
#   the key already filed, only while the hub still says wip. A lane placed
#   after a delivered key, or beside a request still waiting, has its own token.
#   An end is served only for the key this box placed for that lane id
#   (<state>/issue-lane/<id>): it stops a wrong or edited key ending another
#   issue. It is a consistency check, not a security boundary.
#   spawn-remote.sh --issue --box <desk box> --id <lane id> [--key <KEY>]
#                   [--topic <id>] [--from <ID>] [--to <ID>] [--wait <secs>] <BRIEF>
#   writes <root>/<lane id>/lifetime/issue (and issue-tenant, origin-issue), as
#   do_spl_lane_issue does, and prints the key. "issue-request v1" rides the
#   same relay and tick. The receiver runs its own do_spl_lane_issue in a
#   throwaway SPOOL_ROOT, so a lane of the same id on that box is untouched.
#   Accepted only from a role seat (spl_is_role_seat) of another box, a relayed
#   "<ID>@<box>", not only the orch holder: spawn-window runs on the placing box
#   under that box's own seat. It starts nothing; it files or links one issue,
#   and only in a workspace whose map row here names this box as the desk's.
#   Exit: 0 placed, 2 usage, 3 the send failed, 4 refused, 5 no reply in time.
#
# Test seams: SPAWN_REMOTE_WINDOW_CMD replaces "bash spawn-window.sh";
# SPAWN_REMOTE_SEND_CMD replaces "bash spool-send.sh";
# SPAWN_REMOTE_ISSUE_CMD replaces do_spl_lane_issue on the receiver.
#
# --cancel --box <box> --task <task_id> withdraws a request this sender filed
# and will not use. The target's --serve then does not spawn it.
# Exit (request): 0 spawned, 2 usage, 3 the send failed, 4 refused (reject
# reply, reason on stderr), 5 no reply within --wait (stdout: `task <id>`).
# Exit (cancel): 0 the cancel left, 2 usage, 3 the send failed.
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
MAGIC_CANCEL="spawn-cancel v1"
MAGIC_ISSUE="issue-request v1"
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
  case "$1" in claude|grok|agy|qwen|mistral) ;; *) say "bad kind '$1'"; return 1 ;; esac
  [[ "$2" = auto || "$2" =~ ^[A-Za-z][A-Za-z0-9-]{0,31}$ ]] || { say "bad title '$2'"; return 1; }
  [[ "$3" =~ ^/[A-Za-z0-9._/-]*$ && "$3" != *..* ]] || { say "bad workdir '$3' (absolute, [A-Za-z0-9._/-], no ..)"; return 1; }
  [[ -z "$4" || "$4" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { say "bad slug '$4'"; return 1; }
}

# The lane row's fields, the hub's own limits (store/fleet_lane.go), used by
# both sides. The scope and files are data: never evaluated, one header line.
valid_lane_fields() {  # TOPIC SCOPE FILES ; the reason on stderr
  [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { say "bad topic '$1' ([A-Za-z0-9_-], up to 64)"; return 1; }
  [ "$(printf '%s' "$2" | wc -c)" -le 500 ] || { say "bad scope (over 500 bytes)"; return 1; }
  [[ "$2$3" != *[[:cntrl:]]* ]] || { say "bad scope or files (a control character)"; return 1; }
}
one_line() { printf '%s' "$1" | tr '\t\r\n' '   ' | tr -d '\000-\037\177'; }
# Bytes, in any locale, and never half a character: the JSON step turns a broken
# byte into 3 bytes of U+FFFD, which would put the scope back over the limit.
cut_bytes() {  # MAX ; stdin to stdout
  python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read()[:int(sys.argv[1])].decode("utf-8", "ignore").encode("utf-8"))' "$1"
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
  local topic="${SPAWN_LANE_TOPIC:-${LANE_ISSUE_TOPIC:-}}" scope files
  scope="$(one_line "${SPAWN_LANE_SCOPE:-}" | cut_bytes 500)"
  files="$(one_line "${SPAWN_LANE_FILES:-}")"
  valid_lane_fields "$topic" "$scope" "$files" || exit 2
  if [ -n "$brief" ]; then
    [ -r "$brief" ] || { say "cannot read brief $brief"; exit 2; }
  fi
  local tmp out rc task margin="${SPAWN_REMOTE_MARGIN:-60}" expires=""
  [[ "$margin" =~ ^[0-9]+$ ]] || { say "SPAWN_REMOTE_MARGIN must be seconds"; exit 2; }
  [ "$margin" -le $(( wait / 2 )) ] || margin=$(( wait / 2 ))
  [ "$wait" = 0 ] || expires="expires: $(( $(date +%s) + wait - margin ))"
  tmp="$(mktemp)" || exit 3
  {
    printf '%s\n' "$MAGIC_REQ" \
      "(For spawn-remote.sh --serve on this machine, not for the agent reading it: do not act on it, ack it.)" \
      "kind: $kind" "title: $title" "workdir: $workdir" "slug: $slug" ${expires:+"$expires"} \
      ${topic:+"topic: $topic"} ${scope:+"scope: $scope"} ${files:+"files: $files"} "---"
    if [ -n "$brief" ]; then cat -- "$brief"; fi
  } >"$tmp"
  task="$(python3 -c 'import uuid; print(uuid.uuid4())')" || { rm -f "$tmp"; exit 3; }
  out="$(send --from "$from" --to "$to@$box" --kind task --task "$task" --no-ask --no-poke --body-file "$tmp" 2>&1)"; rc=$?
  rm -f "$tmp"
  # 5 = delivered, no pane rang (the serve tick needs none)
  [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ] || { say "the request did not leave (rc=$rc): $out"; exit 3; }
  if [ "$wait" = 0 ]; then echo "task $task"; return 0; fi
  local end=$(( $(date +%s) + wait )) f b w
  while :; do
    f="$(reply_file "$from" "$task")"
    if [ -n "$f" ]; then
      b="$(body_of "$f" | strip_from_agent)"
      case "$(sed -n 's/^status: //p' <<<"$b" | sed -n 1p)" in
        ok) w="$(sed -n 's/^warn: //p' <<<"$b" | sed -n 1p)"; [ -z "$w" ] || say "$box: $w"
            printf '%s %s\n' "$(sed -n 's/^agent: //p' <<<"$b" | sed -n 1p)" "$(sed -n 's/^pane: //p' <<<"$b" | sed -n 1p)"; return 0 ;;
        *) say "refused by $box: $(sed -n 's/^reason: //p' <<<"$b" | sed -n 1p)"; exit 4 ;;
      esac
    fi
    [ "$(date +%s)" -lt "$end" ] || { say "no reply from $box within ${wait}s (task $task); it may still come: spool tail --task $task"; printf 'task %s\n' "$task"; exit 5; }
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
      body_of "$f" | strip_from_agent | sed -n 1p | grep -xF "$MAGIC_REP" >/dev/null && { printf '%s' "$f"; return 0; }
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
req_field() { sed -n '1,/^---$/p' <<<"$1" | sed -n "s/^$2: //p" | sed -n 1p; }

# The line ID's launcher logged since EPOCH: a line of a former holder of the
# id is not this spawn's. "" for none.
lane_refused_line() {  # ID EPOCH
  local log="$SPOOL_ROOT/$1/lane-unlinked.log"
  [ -r "$log" ] && [ "$(stat -c %Y "$log" 2>/dev/null || echo 0)" -ge "$2" ] && tail -1 "$log"
  return 0
}

handle() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from task body holder kind title workdir slug brief out rc id pane reason requester expires
  local topic scope files started warn lane
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
  topic="$(req_field "$body" topic)" scope="$(req_field "$body" scope)" files="$(req_field "$body" files)"
  if ! reason="$({ valid_args "$kind" "$title" "$workdir" "$slug" && valid_lane_fields "$topic" "$scope" "$files"; } 2>&1)" || [ ! -d "$workdir" ]; then
    reason="${reason:-workdir $workdir is not a directory on this machine}"
    log_line REJECTED "$msg" "$from" "$reason"
    reply "$me" "$from" "$task" refused "reason: ${reason#spawn-remote: }"
    return 0
  fi
  brief="$STATE/briefs/$msg.md"
  # 600 before a byte lands (the dir's default ACL beats a umask); an agent
  # CLI of another OS user gets a named read entry, the group none (spec 136 P5).
  : >"$brief" && chmod 600 "$brief" && sed '1,/^---$/d' <<<"$body" >"$brief"
  if [ "${SPOOL_AGENT_USER:-}" != "$(id -un)" ] && [ -n "${SPOOL_AGENT_USER:-}" ] && [ -s "$brief" ]; then
    setfacl -m "u:${SPOOL_AGENT_USER}:r,g::-,o::-" "$brief" 2>/dev/null \
      || say "WARN brief $brief: no read entry for agent user ${SPOOL_AGENT_USER} (setfacl failed)"
  fi
  [ -s "$brief" ] || { rm -f "$brief"; brief=""; }
  # The cron tick has no agent id. The verified `from` is who asked; the
  # target's spawn-window records it (a bare id; "@<box>" is the relay).
  requester="${from%%@*}"
  if task_cancelled "$me" "$task"; then
    log_line CANCELLED "$msg" "$from" "task $task withdrawn before spawn"
    return 0
  fi
  expires="$(req_field "$body" expires)"
  if [[ "$expires" =~ ^[0-9]+$ ]] && [ "$(date +%s)" -gt "$expires" ]; then
    log_line EXPIRED "$msg" "$from" "arrived after its expiry $expires: the requester starts it elsewhere"
    reply "$me" "$from" "$task" refused "reason: expired at $expires before this box could start it"
    return 0
  fi
  lane=("SPAWN_REQUESTER=$requester" ${topic:+"SPAWN_LANE_TOPIC=$topic"} ${scope:+"SPAWN_LANE_SCOPE=$scope"} ${files:+"SPAWN_LANE_FILES=$files"})
  started="$(date +%s)"
  if [ -n "${SPAWN_REMOTE_WINDOW_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(env "${lane[@]}" $SPAWN_REMOTE_WINDOW_CMD "$kind" "$title" "$workdir" ${brief:+"$brief"} ${slug:+"$slug"} 2>&1)"; rc=$?
  else
    out="$(env "${lane[@]}" bash "$HERE/spawn-window.sh" "$kind" "$title" "$workdir" ${brief:+"$brief"} ${slug:+"$slug"} 2>&1)"; rc=$?
  fi
  read -r id pane <<<"$(grep -E '^[A-Za-z][A-Za-z0-9-]* (%[0-9]+|-)$' <<<"$out" | tail -1)"
  if [ "$rc" -ne 0 ] || [ -z "${id:-}" ]; then
    log_line FAILED "$msg" "$from" "spawn-window rc=$rc: $(tail -1 <<<"$out")"
    reply "$me" "$from" "$task" failed "reason: spawn-window rc=$rc: $(tail -1 <<<"$out")"
    return 0
  fi
  log_line SPAWNED "$msg" "$from" "$id@$(spool_fleet_box) $pane $kind ${slug:-} brief=${brief:-none}"
  warn="$(lane_refused_line "$id" "$started")"
  reply "$me" "$from" "$task" ok "agent: $id@$(spool_fleet_box)" "pane: $pane" "request: $msg" ${warn:+"warn: $warn"}
}

# ---- issue -----------------------------------------------------------------
# Ask BOX to place a lane's issue; writes the lane's lifetime files from the reply.
issue_request() {
  local box="" from="${SPOOL_AGENT_ID:-}" to="" wait="${SPAWN_ISSUE_REMOTE_WAIT:-150}" id="" key="" topic=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --box|--from|--to|--wait|--id|--key|--topic) [ "$#" -ge 2 ] || usage
        case "$1" in --box) box="$2" ;; --from) from="$2" ;; --to) to="$2" ;; --wait) wait="$2" ;;
          --id) id="$2" ;; --key) key="$2" ;; --topic) topic="$2" ;; esac; shift 2 ;;
      -*) say "unknown option $1"; usage ;;
      *) break ;;
    esac
  done
  local brief="${1:-}" tmp task margin="${SPAWN_REMOTE_MARGIN:-60}" expires=""
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$wait" =~ ^[0-9]+$ && "$margin" =~ ^[0-9]+$ ]] || { say "FATAL --issue needs --box <box> and a numeric --wait"; exit 2; }
  [ -n "$from" ] || from="$(local_orch)"
  [ -n "$to" ] || to="$(local_orch)"
  spl_is_participant_id "$from" && spl_is_participant_id "$to" && issue_fields_ok "$id" "$key" "$topic" || { say "FATAL bad --from, --to, --id, --key or --topic"; exit 2; }
  [ -r "$brief" ] || { say "FATAL cannot read brief $brief"; exit 2; }
  [ "$margin" -le $(( wait / 2 )) ] || margin=$(( wait / 2 ))
  [ "$wait" = 0 ] || expires="expires: $(( $(date +%s) + wait - margin ))"
  [ -n "$key" ] || [ "$wait" = 0 ] || issue_token_take "$brief"
  tmp="$(mktemp)" || exit 3
  { printf '%s\n' "$MAGIC_ISSUE" \
      "(For spawn-remote.sh --serve on this machine, not for the agent reading it: do not act on it, ack it.)" \
      "id: $id" "key: $key" "topic: $topic" ${ISSUE_TOKEN:+"token: $ISSUE_TOKEN"} ${expires:+"$expires"} "---"
    cat -- "$brief"; } >"$tmp"
  task="$(issue_send "$from" "$to" "$box" "$tmp")" || exit $?
  if [ "$wait" = 0 ]; then echo "task $task"; return 0; fi
  issue_await "$box" "$from" "$task" "$wait" "$id"
}

# ISSUE_TOKEN for BRIEF: the one a retry of an unanswered request kept
# (<state>/issue-pending/<brief sha>), else a new one. A request for the same
# brief still waiting holds the lock, and this one gets a token of its own.
# Fd 9 stays open until this process exits. No state dir: no token, no reuse.
issue_token_take() {  # BRIEF
  local d="$STATE/issue-pending" sha
  ISSUE_TOKEN="" ISSUE_PENDING=""
  mkdir -p "$d" 2>/dev/null && sha="$(sha256sum <"$1" | cut -d' ' -f1)" && touch "$d/$sha.lock" 2>/dev/null || return 0
  find "$d" -type f -mmin +"${SPAWN_REMOTE_ISSUE_REUSE_MIN:-360}" -delete 2>/dev/null
  touch "$d/$sha.lock" 2>/dev/null || return 0
  exec 9>>"$d/$sha.lock"
  if flock -n 9; then
    ISSUE_PENDING="$d/$sha"
    ISSUE_TOKEN="$(cat "$ISSUE_PENDING" 2>/dev/null)"
  fi
  [ -n "$ISSUE_TOKEN" ] && return 0
  ISSUE_TOKEN="$(python3 -c 'import uuid; print(uuid.uuid4())')" || return 0
  [ -z "$ISSUE_PENDING" ] || printf '%s\n' "$ISSUE_TOKEN" >"$ISSUE_PENDING"
}

# Send an issue request's body file (removed here); stdout: the task id.
issue_send() {  # FROM TO BOX FILE
  local task out rc
  task="$(python3 -c 'import uuid; print(uuid.uuid4())')" || { rm -f "$4"; exit 3; }
  out="$(send --from "$1" --to "$2@$3" --kind task --task "$task" --no-ask --no-poke --body-file "$4" 2>&1)"; rc=$?
  rm -f "$4"
  [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ] || { say "FATAL the issue request did not leave (rc=$rc): $out"; exit 3; }
  printf '%s' "$task"
}

# Ask BOX to end a lane's issue; writes the reply's issue-end into --life.
issue_end_request() {
  local box="" id="" key="" tenant="" life="" status="" reason="" repo="" sha="" evidence="" wait="${SPAWN_ISSUE_REMOTE_WAIT:-150}"
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --box) box="$2" ;; --id) id="$2" ;; --key) key="$2" ;; --tenant) tenant="$2" ;; --life) life="$2" ;; --status) status="$2" ;;
      --reason) reason="$2" ;; --repo) repo="$2" ;; --sha) sha="$2" ;; --evidence) evidence="$2" ;; --wait) wait="$2" ;;
      *) say "unknown option $1"; usage ;;
    esac
    shift 2
  done
  reason="$(tr '\t\n\r' '   ' <<<"$reason" | sed 's/^ *//; s/ *$//' | cut -c1-500)"
  local from="${SPOOL_AGENT_ID:-}" orch tmp task b line margin="${SPAWN_REMOTE_MARGIN:-60}"
  orch="$(local_orch)"; [ -n "$from" ] || from="$orch"
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$wait" =~ ^[1-9][0-9]*$ && "$margin" =~ ^[0-9]+$ && "$tenant" =~ ^[A-Za-z0-9_-]+$ && -n "$key" && -d "$life" ]] && issue_fields_ok "$id" "$key" "" &&
    issue_end_fields_ok "$status" "$repo" "$sha" "$evidence" || { say "FATAL --issue-end: bad --box, --id, --key, --tenant, --life, --status, --repo, --sha or --evidence"; exit 2; }
  [ "$margin" -le $(( wait / 2 )) ] || margin=$(( wait / 2 ))
  tmp="$(mktemp)" || exit 3
  printf '%s\n' "$MAGIC_ISSUE" "(For spawn-remote.sh --serve on this machine, not for the agent reading it: do not act on it, ack it.)" \
    "op: end" "id: $id" "key: $key" "topic: " "status: $status" "reason: $reason" "repo: $repo" "sha: $sha" "evidence: $evidence" \
    "expires: $(( $(date +%s) + wait - margin ))" "---" "Workspace: $tenant" >"$tmp"
  task="$(issue_send "$from" "$orch" "$box" "$tmp")" || exit $?
  b="$(issue_reply "$box" "$from" "$task" "$wait")" || exit $?
  line="$(sed -n 's/^issue-end: //p' <<<"$b" | sed -n 1p | base64 -d 2>/dev/null)"
  [ -n "$line" ] || { say "FATAL $box answered no issue-end"; exit 4; }
  printf '%s\n' "$line" >"$life/issue-end" || { say "FATAL cannot write $life/issue-end"; exit 4; }
}

# The end fields of an issue request; one validation for both sides.
issue_end_fields_ok() {  # STATUS REPO SHA EVIDENCE
  [[ "$1" =~ ^(diss|onhold|blocked|done)$ && "$2" =~ ^[A-Za-z0-9._-]*$ && "$3" =~ ^([0-9a-f]{7,40})?$ ]] || return 1
  [[ -z "$4" || "$4" =~ ^owner=[0-9a-f-]{36}\ accepted=[0-9a-f-]{36}$ ]]
}

# The lane fields of an issue request; one validation for both sides.
issue_fields_ok() {  # ID KEY TOPIC
  [[ "$1" =~ ^[A-Za-z]{1,3}-[0-9]{2,5}$ ]] || return 1
  [[ -z "$2" || "$2" =~ ^[A-Z][A-Z0-9]{0,9}-[1-9][0-9]*$ ]] || return 1
  valid_lane_fields "$3" "" "" 2>/dev/null
}

# Wait for the reply; stdout its body. Not ok, or none in time: exit 4 or 5.
issue_reply() {  # BOX FROM TASK WAIT
  local end=$(( $(date +%s) + $4 )) f b
  while :; do
    f="$(reply_file "$2" "$3")"
    [ -z "$f" ] || break
    [ "$(date +%s)" -lt "$end" ] || { say "FATAL no reply from $1 within $4 s to the issue request (task $3): its desk's box may be down"; exit 5; }
    sleep "${SPAWN_REMOTE_POLL:-5}"
  done
  b="$(body_of "$f" | strip_from_agent)"
  [ "$(sed -n 's/^status: //p' <<<"$b" | sed -n 1p)" = ok ] || { say "FATAL refused by $1: $(sed -n 's/^reason: //p' <<<"$b" | sed -n 1p)"; exit 4; }
  printf '%s' "$b"
}

# On an ok reply, the lane's files as do_spl_lane_issue writes them.
issue_await() {  # BOX FROM TASK WAIT ID
  local b key tenant env origin life="$SPOOL_ROOT/$5/lifetime"
  b="$(issue_reply "$1" "$2" "$3" "$4")" || exit $?
  key="$(sed -n 's/^key: //p' <<<"$b" | sed -n 1p)" tenant="$(sed -n 's/^tenant: //p' <<<"$b" | sed -n 1p)"
  env="$(sed -n 's/^env: //p' <<<"$b" | sed -n 1p)" origin="$(sed -n 's/^origin: //p' <<<"$b" | sed -n 1p)"
  issue_fields_ok "$5" "$key" "" && [ -n "$key" ] || { say "FATAL $1 answered no usable key: '$key'"; exit 4; }
  mkdir -p "$life" && printf '%s\n' "$key" >"$life/issue" || { say "FATAL cannot write $life/issue"; exit 4; }
  chmod 0664 "$life/issue" 2>/dev/null
  if [[ "$tenant" =~ ^[A-Za-z0-9_-]+$ && "$env" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\t%s\n' "$tenant" "$env" >"$life/issue-tenant"; chmod 0664 "$life/issue-tenant" 2>/dev/null
  fi
  if [ -n "$origin" ]; then printf '%s\n' "$origin" >"$life/origin-issue"; chmod 0664 "$life/origin-issue" 2>/dev/null; fi
  [ -z "${ISSUE_PENDING:-}" ] || rm -f "$ISSUE_PENDING"
  printf '%s\n' "$key"
}

# Receiver: one issue request, once.
handle_issue() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from task body id key topic expires brief t row op token
  msg="$(jq -r '.msg_id // ""' "$f" 2>/dev/null)"
  [[ "$msg" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 0
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  from="$(jq -r '.from // ""' "$f")"; task="$(jq -r '.task_id // ""' "$f")"
  body="$(body_of "$f" | strip_from_agent)"
  if [[ "$from" != *@* ]] || ! spl_is_role_seat "$from"; then
    log_line REFUSED "$msg" "$from" "issue request: not a role seat of another box"
    reply "$me" "$from" "$task" refused "reason: only a role seat of another box may ask for an issue here"
    return 0
  fi
  id="$(req_field "$body" id)" key="$(req_field "$body" key)" topic="$(req_field "$body" topic)" expires="$(req_field "$body" expires)"
  op="$(req_field "$body" op)"
  if ! issue_fields_ok "$id" "$key" "$topic" || { [ "$op" = end ] && { [ -z "$key" ] || ! issue_end_fields_ok "$(req_field "$body" status)" "$(req_field "$body" repo)" "$(req_field "$body" sha)" "$(req_field "$body" evidence)"; }; }; then
    log_line REJECTED "$msg" "$from" "issue request: bad id, key or topic"
    reply "$me" "$from" "$task" refused "reason: bad id, key or topic"
    return 0
  fi
  if [[ "$expires" =~ ^[0-9]+$ ]] && [ "$(date +%s)" -gt "$expires" ]; then
    log_line EXPIRED "$msg" "$from" "issue request for $id arrived after its expiry $expires"
    reply "$me" "$from" "$task" refused "reason: expired at $expires before this box could place it"
    return 0
  fi
  # shellcheck source=../lib/lane-issue.inc.sh
  . "$HERE/../lib/lane-issue.inc.sh"
  brief="$(mktemp)" || return 0
  sed '1,/^---$/d' <<<"$body" >"$brief"
  if ! t="$(wr_tenant_of_brief "$brief")" || ! row="$(wr_row "$t" 2>/dev/null)" || [ "$(wr_field "$row" 7)" != "$(spool_fleet_box)" ]; then
    rm -f "$brief"
    log_line REJECTED "$msg" "$from" "issue request for $id: no Workspace row with its desk on this box (${t:-none})"
    reply "$me" "$from" "$task" refused "reason: this box holds no desk for the brief's workspace (${t:-no Workspace line})"
    return 0
  fi
  if [ "$op" = end ]; then
    if ! issue_end_bound "$me" "$msg" "$from" "$task" "$id" "$key"; then rm -f "$brief"; return 0; fi
    issue_end_run "$me" "$msg" "$from" "$task" "$id" "$key" "$brief" "$t	$(wr_field "$row" 1)" "$body"
  else
    token="$(req_field "$body" token)"; [[ "$token" =~ ^[0-9a-f-]{36}$ ]] || token=""
    if [ -z "$key" ] && [ -n "$token" ] && ! key="$(issue_retry_key "$token" "$row" "$t")"; then
      rm -f "$brief"
      log_line FAILED "$msg" "$from" "issue for $id: retry token $token, the hub's status of its key could not be read"
      reply "$me" "$from" "$task" failed "reason: the hub's status of the key this retry filed could not be read; nothing changed"
      return 0
    fi
    issue_run "$me" "$msg" "$from" "$task" "$id" "$key" "$topic" "$brief" "$token"
  fi
  rm -f "$brief"
}

# A throwaway root (the box's own lease, map and box.env, no lane dir of the
# same id) with the brief in it; stdout: the root.
issue_root() {  # ID BRIEF
  local e n
  e="$(mktemp -d "$STATE/issue.XXXXXX")" || return 1
  mkdir -p "$e/$1/lifetime"
  cp -- "$2" "$e/brief.md"
  for n in dispatch box.env workspace-repos.tsv; do [ ! -e "$SPOOL_ROOT/$n" ] || ln -s "$SPOOL_ROOT/$n" "$e/$n"; done
  printf '%s' "$e"
}

# Run do_spl_lane_issue with VAR=VALUE... on this box's desk; stdout its output.
issue_exec() {  # ROOT VAR=VALUE...
  local e="$1"; shift
  local -a hop=() where=()
  if [ -n "${SPAWN_REMOTE_ISSUE_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    env "$@" $SPAWN_REMOTE_ISSUE_CMD 2>&1
    return
  fi
  read -r -a where <<<"$(li_desk_where "$e/brief.md")"
  li_desk_hop hop "${where[@]}"
  # The desk's user writes the lifetime files; this user reads and removes them.
  [ "${#hop[@]}" -eq 0 ] || setfacl -R -m "u:${hop[3]}:rwX" "$e" 2>/dev/null || say "WARN $e: no entry for ${hop[3]} (setfacl failed)"
  timeout "${SPAWN_ISSUE_TIMEOUT:-120}" "${hop[@]}" env "$@" bash "$HERE/../../../../../run" -a do_spl_lane_issue 2>&1
}

# The key an earlier request with this retry token filed, kept for
# SPAWN_REMOTE_ISSUE_REUSE_MIN (default 360) minutes: its reply was lost, and
# the retry links that issue instead of filing a second. Only while the hub
# says wip: linking sets wip, and would reopen one that was closed since.
# Nothing printed: no such key, or not wip. rc 1: the status could not be read.
issue_retry_key() {  # TOKEN MAP_ROW TENANT
  local d="$STATE/issue-placed" k st
  [ -d "$d" ] || return 0
  find "$d" -type f -mmin +"${SPAWN_REMOTE_ISSUE_REUSE_MIN:-360}" -delete 2>/dev/null
  k="$(cat "$d/$1" 2>/dev/null)"
  [ -n "$k" ] || return 0
  st="$(LI_WS_ROW="$2" LI_WS_TENANT="$3" li_hub_status "$k")"
  [ -n "$st" ] || return 1
  if [ "$st" = wip ]; then printf '%s' "$k"; else rm -f "$d/$1"; fi
}

# 0 when KEY is the key this box placed for lane ID; else refuses, rc 1.
issue_end_bound() {  # INBOX_ID MSG FROM TASK ID KEY
  local placed why
  placed="$(cat "$STATE/issue-lane/$5" 2>/dev/null)"
  [ "$placed" = "$6" ] && return 0
  why="this box has no record of placing an issue for lane $5"
  [ -z "$placed" ] || why="$6 is not the issue this box placed for lane $5 ($placed)"
  log_line REFUSED "$2" "$3" "issue end: $why"
  reply "$1" "$3" "$4" refused "reason: $why"
  return 1
}

# End a lane's issue in a throwaway root that holds its key and workspace.
issue_end_run() {  # INBOX_ID MSG FROM TASK ID KEY BRIEF TENANT_LINE BODY
  local me="$1" msg="$2" from="$3" task="$4" id="$5" key="$6" e rc=0 out line
  e="$(issue_root "$id" "$7")" || return 0
  printf '%s\n' "$key" >"$e/$id/lifetime/issue"; printf '%s\n' "$8" >"$e/$id/lifetime/issue-tenant"
  out="$(issue_exec "$e" SPOOL_ROOT="$e" AGENT_ID="$id" LANE_ISSUE_OP=end LANE_ISSUE_STATUS="$(req_field "$9" status)" LANE_ISSUE_REASON="$(req_field "$9" reason)" \
    LANE_LANDED_REPO="$(req_field "$9" repo)" LANE_LANDED_SHA="$(req_field "$9" sha)" LANE_APPLIED_EVIDENCE="$(req_field "$9" evidence)" DRY_RUN=0)" || rc=$?
  line="$(sed -n 1p "$e/$id/lifetime/issue-end" 2>/dev/null)"
  rm -rf "${e:?}"
  if [ "$rc" -ne 0 ] || [ -z "$line" ]; then
    out="$(grep -E 'FATAL|WARN' <<<"$out" | grep -v 'failed at line' | tail -1 | cut -c1-400)"
    log_line FAILED "$msg" "$from" "issue end for $id $key rc=$rc: $out"
    reply "$me" "$from" "$task" failed "reason: rc=$rc: $out"
    return 0
  fi
  log_line ENDED "$msg" "$from" "$id $key"
  reply "$me" "$from" "$task" ok "key: $key" "issue-end: $(printf '%s' "$line" | base64 -w0)" "request: $msg"
}

# Run the action in a throwaway root and answer with what it wrote.
issue_run() {  # INBOX_ID MSG FROM TASK ID KEY TOPIC BRIEF [TOKEN]
  local me="$1" msg="$2" from="$3" task="$4" id="$5" key="$6" topic="$7" src="$8" token="${9:-}" e rc=0 out placed tenant env origin
  e="$(issue_root "$id" "$src")" || return 0
  out="$(issue_exec "$e" SPOOL_ROOT="$e" AGENT_ID="$id" BRIEF="$e/brief.md" LANE_ISSUE_KEY="$key" LANE_ISSUE_TOPIC="$topic" DRY_RUN=0)" || rc=$?
  placed="$(li_key_of_agent "$e" "$id")"
  if [ "$rc" -ne 0 ] || [ -z "$placed" ]; then
    out="$(grep -E 'FATAL|WARN' <<<"$out" | grep -v 'failed at line' | tail -1 | cut -c1-400)"
    rm -rf "${e:?}"
    log_line FAILED "$msg" "$from" "issue for $id rc=$rc: $out"
    reply "$me" "$from" "$task" failed "reason: rc=$rc: $out"
    return 0
  fi
  IFS=$'\t' read -r tenant env _ <"$e/$id/lifetime/issue-tenant" 2>/dev/null
  origin="$(sed -n 1p "$e/$id/lifetime/origin-issue" 2>/dev/null)"
  rm -rf "${e:?}"
  mkdir -p "$STATE/issue-lane" && printf '%s\n' "$placed" >"$STATE/issue-lane/$id"
  [ -z "$token" ] || { mkdir -p "$STATE/issue-placed" && printf '%s\n' "$placed" >"$STATE/issue-placed/$token"; }
  log_line PLACED "$msg" "$from" "$id -> $placed in ${tenant:-?}"
  reply "$me" "$from" "$task" ok "key: $placed" "tenant: ${tenant:-}" "env: ${env:-}" "origin: ${origin:-}" "request: $msg"
}

# 0 when the orch holder has withdrawn TASK (spawn-remote/cancelled, or a
# spawn-cancel v1 from the holder in ID's inbox or archive).
task_cancelled() {  # INBOX_ID TASK
  local id="$1" task="$2" d f b from holder
  [ -n "$task" ] || return 1
  grep -qxF -- "$task" "$STATE/cancelled" 2>/dev/null && return 0
  holder="$(orch_holder)"
  [ -n "$holder" ] || return 1
  for d in "$SPOOL_ROOT/$id/inbox" "$SPOOL_ROOT/$id/archive"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b="$(body_of "$f" | strip_from_agent)"
      [ "$(printf '%s\n' "$b" | sed -n 1p)" = "$MAGIC_CANCEL" ] || continue
      [ "$(req_field "$b" task)" = "$task" ] || continue
      from="$(jq -r '.from // ""' "$f" 2>/dev/null)"
      [ "$(qualify "$from")" = "$holder" ] && return 0
    done < <(grep -lF -- "$task" "$d"/*.json 2>/dev/null || true)
  done
  return 1
}

note_cancel() {  # INBOX_ID FILE
  local me="$1" f="$2" msg from body task holder
  msg="$(jq -r '.msg_id // ""' "$f" 2>/dev/null)"
  [[ "$msg" =~ ^[0-9A-Za-z-]{8,64}$ ]] || return 0
  grep -qxF -- "$msg" "$STATE/seen" 2>/dev/null && return 0
  echo "$msg" >>"$STATE/seen"
  from="$(jq -r '.from // ""' "$f" 2>/dev/null)"
  holder="$(orch_holder)"
  body="$(body_of "$f" | strip_from_agent)"
  task="$(req_field "$body" task)"
  if [ -z "$holder" ] || [ "$(qualify "$from")" != "$holder" ] || [[ ! "$task" =~ ^[0-9A-Za-z-]{8,64}$ ]]; then
    log_line CANCELLED "$msg" "$from" "ignored (not the holder, or a bad task)"
    return 0
  fi
  grep -qxF -- "$task" "$STATE/cancelled" 2>/dev/null || echo "$task" >>"$STATE/cancelled"
  log_line CANCELLED "$msg" "$from" "task $task"
}

serve() {
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
  mkdir -p "$STATE/briefs" || exit 2
  exec 9>"$STATE/serve.lock"
  flock -n 9 || { say "another tick is running"; exit 3; }
  local ids="${SPAWN_REMOTE_INBOX_IDS:-$(local_orch)}" me d f first
  for me in $ids; do
    spl_is_participant_id "$me" || continue
    for d in "$SPOOL_ROOT/$me/inbox" "$SPOOL_ROOT/$me/archive"; do
      [ -d "$d" ] || continue
      # a day back is enough: a tick runs every minute; older files are history
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        first="$(body_of "$f" | strip_from_agent | sed -n 1p)"
        case "$first" in
          "$MAGIC_CANCEL") note_cancel "$me" "$f" </dev/null ;;
          "$MAGIC_REQ") handle "$me" "$f" </dev/null ;;
          "$MAGIC_ISSUE") handle_issue "$me" "$f" </dev/null ;;
        esac
      done < <(find "$d" -maxdepth 1 -name '*.json' -mmin -1440 -print0 2>/dev/null |
               xargs -0 -r grep -lF -e "$MAGIC_REQ" -e "$MAGIC_CANCEL" -e "$MAGIC_ISSUE" 2>/dev/null | sort)
    done
  done
  return 0
}

# Tell BOX to drop the request TASK. Same --from / --to rules as a request.
cancel() {
  local box="" from="${SPOOL_AGENT_ID:-}" to="" task=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --box)  [ "$#" -ge 2 ] || usage; box="$2"; shift 2 ;;
      --from) [ "$#" -ge 2 ] || usage; from="$2"; shift 2 ;;
      --to)   [ "$#" -ge 2 ] || usage; to="$2"; shift 2 ;;
      --task) [ "$#" -ge 2 ] || usage; task="$2"; shift 2 ;;
      *) say "unknown option $1"; usage ;;
    esac
  done
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { say "--cancel needs --box <box>"; usage; }
  [[ "$task" =~ ^[0-9A-Za-z-]{8,64}$ ]] || { say "--cancel needs --task <task id>"; exit 2; }
  [ -n "$from" ] || from="$(local_orch)"
  [ -n "$to" ] || to="$(local_orch)"
  spl_is_participant_id "$from" && spl_is_participant_id "$to" || { say "bad --from '$from' or --to '$to'"; exit 2; }
  local tmp out rc
  tmp="$(mktemp)" || exit 3
  printf '%s\n' "$MAGIC_CANCEL" \
    "(For spawn-remote.sh --serve on this machine, not for the agent reading it: do not act on it, ack it.)" \
    "task: $task" "---" >"$tmp"
  out="$(send --from "$from" --to "$to@$box" --kind note --task "$task" --no-ask --no-poke --body-file "$tmp" 2>&1)"; rc=$?
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ] || { say "the cancel did not leave (rc=$rc): $out"; exit 3; }
  printf 'cancelled %s\n' "$task"
}

case "${1:-}" in
  --serve) [ "$#" -eq 1 ] || usage; serve ;;
  --cancel) shift; cancel "$@" ;;
  --issue) shift; issue_request "$@" ;;
  --issue-end) shift; issue_end_request "$@" ;;
  ""|-h|--help) usage ;;
  *) request "$@" ;;
esac
