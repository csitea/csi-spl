#!/bin/bash
#------------------------------------------------------------------------------
# @description The sender audit (SPL-5136, spec 165 3.3.1): every agent has
# @description sudo to the box user, so a lane can run `spool send --from <any
# @description seat>` past spool-send.sh's guard, and the hub trusts the box,
# @description not the seat. Prevention is not possible; this detects it. Each
# @description CLI send journals its message id, from and ancestor pids
# @description (action.AuditSender); this action names the agent running each
# @description chain the way send_from_guard does and sends the orchestrator
# @description ONE note on task fleet-anomaly listing the posts whose from is
# @description not that agent. Not flagged: a chain with no agent (cron, a
# @description human's shell, a process already gone), a role seat as the
# @description caller, and a relayed line whose from_agent names the caller.
# @description Dry run unless DRY_RUN=0: the report only, the journal is kept.
# @description A failed send keeps the batch for the next run.
# @param SPOOL_SENDER_AUDIT (optional) - the journal, default /var/spool-hub/dispatch/sender-audit.jsonl
# @param SENDER_AUDIT_TO (optional) - who gets the note, default orchestrator
# @param SENDER_AUDIT_FROM (optional) - the sender, default role seat 1
# @param SENDER_AUDIT_SEND (optional) - the spool sender script (tests)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DRY_RUN=0 ./run -a do_spl_sender_audit
#------------------------------------------------------------------------------
_spl_sa_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib"
declare -F spl_role_seat >/dev/null || source "$_spl_sa_lib/spool-env.inc.sh"
declare -F send_chain_caller >/dev/null || source "$_spl_sa_lib/spool-caller.inc.sh"

do_spl_sender_audit() {
  local dry="${DRY_RUN:-1}" tmp rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SA_JOURNAL="${SPOOL_SENDER_AUDIT:-/var/spool-hub/dispatch/sender-audit.jsonl}"
  do_require_bin jq || return 1
  tmp="$(mktemp -d)" || return 1
  if (( dry )); then
    [[ ! -e "$SA_JOURNAL" ]] || { spl_sa_scan "$SA_JOURNAL" >"$tmp/rows" && spl_sa_report "$tmp/rows"; } || rc=1
  else
    ( flock -n 9 || { do_log "INFO another sender audit holds the lock - skipped"; exit 0; }
      spl_sa_run "$tmp" ) 9>"$SA_JOURNAL.lock" || rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# spl_sa_run <tmp>: take the journal (or a batch a failed send left), alarm.
spl_sa_run() {
  local work="$SA_JOURNAL.work"
  [[ -e "$work" || ! -e "$SA_JOURNAL" ]] || mv "$SA_JOURNAL" "$work" || { do_log "FATAL cannot take $SA_JOURNAL"; return 1; }
  [[ -e "$work" ]] || { do_log "OK no sends journalled"; return 0; }
  spl_sa_scan "$work" >"$1/rows" || return 1
  spl_sa_report "$1/rows"
  if [[ -s "$1/rows" ]]; then
    spl_sa_body "$1/rows" >"$1/body"
    spl_sa_send "$1/body" || return 1
  fi
  rm -f "$work"
}

# spl_sa_root: the /proc to read (a fake one under SPOOL_TEST=1).
spl_sa_root() {
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then echo "${SPOOL_FROM_GUARD_PROC:-}"; else echo /proc; fi
}

# spl_sa_scan <journal>: "msg_id from caller how" for each flagged line. A
# malformed line, or one whose values are not ids, is skipped.
spl_sa_scan() {
  local root msg from chain claim caller how
  root="$(spl_sa_root)"
  [[ -n "$root" ]] || return 0
  while IFS=$'\t' read -r msg from chain claim; do
    [[ "$msg" =~ ^[0-9a-f-]{8,64}$ && "$from" =~ ^[A-Za-z0-9._-]+(@[A-Za-z0-9._-]+)?$ ]] || continue
    from="${from%%@*}"
    caller="" how=""
    [[ "$chain" == - ]] || read -r caller how < <(send_chain_caller "$root" "$chain")
    [[ -n "$caller" && "$caller" != "$from" && "$caller" != "$claim" ]] || continue
    send_role_seat "$caller" && continue
    printf '%s %s %s %s\n' "$msg" "$from" "$caller" "$how"
  done < <(jq -Rr 'fromjson? | select(type == "object") | [(.msg_id // ""), (.from // ""),
      (if ((.chain // []) | length) > 0 then (.chain | map(tostring) | join(" ")) else "-" end),
      (if (.claim // "") != "" then .claim else "-" end)] | @tsv' "$1")
}

# spl_sa_report <rows>: one line a run; the rows on stdout.
spl_sa_report() {
  do_log "OK sender audit: $(wc -l <"$1") flagged"
  cat "$1"
}

# spl_sa_body <rows>: the note, at most 20 rows.
spl_sa_body() {
  local n
  n="$(wc -l <"$1")"
  echo "**Sender audit on $(hostname -s) (SPL-5136):** $n post(s) whose \`from\` is not the agent that ran the send. Detection only, the posts were delivered."
  echo
  echo "| msg_id | from | caller |"
  echo "|---|---|---|"
  head -20 "$1" | awk '{ print "| " $1 " | " $2 " | " $3 " (by its " $4 ") |" }'
  (( n <= 20 )) || { echo; echo "and $((n - 20)) more."; }
}

# spl_sa_send <body file>: one note on task fleet-anomaly (spec 165 3.4).
spl_sa_send() {
  local send="${SENDER_AUDIT_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  local to="${SENDER_AUDIT_TO:-orchestrator}" from="${SENDER_AUDIT_FROM:-$(spl_role_seat 1)}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$from" --to "$to" \
    --kind note --task fleet-anomaly --body-file "$1" >/dev/null 2>&1 9>&- ||
    { do_log "WARN could not send the sender audit to $to: the batch is kept"; return 1; }
}
