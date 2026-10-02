#!/bin/bash
# @description The orchestrator's one-command view of its work (CLE-77929;
# @description SPEC-spool-fleet-roles.md 4.3). Its inbox held 954 messages and
# @description 0 archived on 2026-10-02: nothing ever marked a message handled,
# @description so it read by poke lines and two escalations sank under the
# @description notes that followed them. This prints, in this order:
# @description   1. OPEN ASKS - do_spl_asks_open: every ask still waiting on the
# @description      orchestrator, oldest first, from the hub and the journal
# @description   2. UNTRACKED - blocker / task messages in the inbox that are
# @description      not in the ask book (sent before it existed, or with
# @description      --no-ask), newest first
# @description   3. FYI - notes, results, rejects and msgs collapsed to ONE row
# @description      per sender: count, newest time, newest first line
# @description ORCH_INBOX_ARCHIVE=1 makes the state real: it moves to
# @description <inbox>/../archive/ every FYI message older than
# @description ORCH_INBOX_KEEP_MIN minutes and every blocker / task whose ask is
# @description closed. Without it, it only says how many it would move.
# @description An open ask's message is never archived.
# @param ORCH_ID (optional) - whose inbox; default this machine's orchestrator (LEASE_ORCH, else SPOOL_ORCHESTRATOR_ID)
# @param ORCH_INBOX_ARCHIVE (optional) - 1 moves the handled messages to archive/
# @param ORCH_INBOX_KEEP_MIN (optional) - FYI messages younger than this stay, default 60
# @param ORCH_INBOX_UNTRACKED (optional) - how many untracked asks to list, default 20
# @param ASKS_FLEET ASKS_ENV ASKS_TENANT ASKS_DESK_BOX ASKS_HUB_CMD (optional) - as do_spl_asks_open
# @example ./run -a do_spl_orch_inbox
# @example ORCH_INBOX_ARCHIVE=1 ./run -a do_spl_orch_inbox

do_spl_orch_inbox() {
  spl_asks_init || return 1
  local id="${ORCH_ID:-${LEASE_ORCH:-${SPOOL_ORCHESTRATOR_ID:-}}}" dir msgs rows
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_participant_id "$id" || { do_log "FATAL ORCH_ID must be an agent id, got '$id'"; return 1; }
  dir="$(spl_orch_inbox_dir "$id")" || { do_log "FATAL no inbox for $id under $SPOOL_ROOT"; return 1; }
  spl_asks_sync_pending
  spl_asks_load || return 1
  rows="$ASKS_ROWS"
  msgs="$(spl_orch_inbox_msgs "$dir")"

  echo "== 1. OPEN ASKS (do_spl_asks_open) =="
  spl_asks_table "$(jq -c '[.[] | select(.state == "open" or .state == "acked")]' <<<"$rows")"
  echo
  echo "== 2. UNTRACKED blocker/task in $dir (not in the ask book), newest first =="
  jq -r --argjson asks "$rows" --argjson n "${ORCH_INBOX_UNTRACKED:-20}" '
    ($asks | map({key: .ask_id, value: true}) | from_entries) as $known
    | [.[] | select((.kind == "blocker" or .kind == "task") and (($known[.msg_id] // false) | not))]
    | sort_by(.ts) | reverse | .[0:$n][]
    | [.ts, .kind, .from, (.task_id[0:8]), .msg_id[0:8], .line] | @tsv' <<<"$msgs" | column -t -s $'\t'
  echo
  echo "== 3. FYI (note/result/reject/msg), one row per sender =="
  jq -r '
    [.[] | select(.kind != "blocker" and .kind != "task")] | group_by(.from)
    | map(sort_by(.ts) | {from: .[0].from, n: length, last: .[-1]}) | sort_by(.last.ts) | reverse | .[]
    | [.from, "\(.n)x", .last.ts, .last.kind, .last.line] | @tsv' <<<"$msgs" | column -t -s $'\t'
  echo
  spl_orch_inbox_archive "$dir" "$msgs" "$rows"
}

# <root>/<ID>/inbox, or the qualified <root>/<ID>@<box>/inbox (specs/058 6).
spl_orch_inbox_dir() {
  local d
  for d in "$SPOOL_ROOT/$1/inbox" "$SPOOL_ROOT/$1@$ASKS_BOX/inbox"; do
    [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# The inbox as a JSON array of {file, msg_id, ts, kind, from, task_id, line}.
spl_orch_inbox_msgs() {
  find "$1" -maxdepth 1 -name '*.json' -print0 2>/dev/null |
    xargs -0 -r jq -c '{file: input_filename, msg_id: (.msg_id // ""), ts: (.ts // ""), kind: (.kind // ""),
      from: (.from // ""), task_id: (.task_id // ""),
      line: ((.body // "") | split("\n") | map(select(test("\\S"))) | (.[0] // "") | gsub("\\*\\*"; "") | .[0:70])}' 2>/dev/null |
    jq -s -c '.'
}

# The handled messages: FYI older than ORCH_INBOX_KEEP_MIN, and blocker/task
# whose ask is closed. Moved only with ORCH_INBOX_ARCHIVE=1.
spl_orch_inbox_archive() {
  local dir="$1" files n f moved=0
  files="$(jq -r --argjson asks "$3" --argjson keep "$(( ${ORCH_INBOX_KEEP_MIN:-60} * 60 ))" --argjson now "$(date -u +%s)" '
    ($asks | map({key: .ask_id, value: .state}) | from_entries) as $st
    | .[] | select(
        (.kind != "blocker" and .kind != "task" and ($now - ((.ts | sub("\\.[0-9]+"; "") | fromdateiso8601? ) // $now)) >= $keep)
        or (($st[.msg_id] // "") | IN("done", "declined", "dead")))
    | .file' <<<"$2")"
  n="$(grep -c . <<<"$files")"
  if [[ "${ORCH_INBOX_ARCHIVE:-0}" != 1 ]]; then
    do_log "INFO $n handled message(s) can move to archive/ (FYI older than ${ORCH_INBOX_KEEP_MIN:-60} min, closed asks): ORCH_INBOX_ARCHIVE=1 moves them"
    return 0
  fi
  mkdir -p "${dir%/inbox}/archive" || return 1
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] && mv -f "$f" "${dir%/inbox}/archive/" && moved=$((moved + 1))
  done <<<"$files"
  do_log "OK archived $moved handled message(s); $(find "$dir" -maxdepth 1 -name '*.json' | wc -l) left in the inbox"
}
